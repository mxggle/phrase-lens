@preconcurrency import ApplicationServices
import AppKit
import Carbon.HIToolbox
import Foundation
import os

/// Where a captured selection lives, kept so an answer can be written back
/// over it or after it.
///
/// `AXUIElement` is a CF reference the accessibility API accepts from any
/// thread, which is what the unchecked conformance vouches for.
struct InsertionTarget: @unchecked Sendable {
  let processIdentifier: pid_t
  let applicationName: String?
  /// The focused control when the selection was read.
  let element: AXUIElement?
  /// The selection inside that control, when the control reports ranges.
  /// Electron editors and most web views do not, and there the live
  /// selection is the only record of where the text was.
  let selectedRange: CFRange?
  let selectedText: String
  /// Whether the control said its text can be written. Web pages, PDFs, and
  /// labels answer no, and there is nothing for Replace or Insert to do.
  let isEditable: Bool
  /// Whether the control sits in a web area — a browser page, or an app such
  /// as VS Code built on one. Its offsets are not trusted for placing a caret.
  let isWebContent: Bool
}

enum InsertionPlacement: Sendable {
  case replace
  case after
}

/// How an answer reached the source application.
enum InsertionMethod: Sendable {
  /// Written into the control directly; the clipboard was never touched.
  case accessibility
  /// Pasted, with the reader's clipboard put back afterwards.
  case paste
}

/// Everything one pass over the accessibility tree produced. Sendable so the
/// traversal can run off the main thread and hand its result back.
private struct AccessibilityCapture: Sendable {
  var snapshot: SelectionSnapshot?
  var textSegments: [String] = []
  var diagnostics = SelectionDiagnostics()
}

struct AccessibilityService: Sendable {
  /// Hard ceiling on how many elements one window walk will look at. Real
  /// pages in a browser or an Electron app run to tens of thousands of nodes,
  /// so this is a stop, not a plan — the budgets below are what normally ends
  /// the search.
  private static let maximumCandidateCount = 4_000
  /// How deep below the window text is still worth looking for. A paragraph
  /// in a web view commonly sits fifteen to twenty levels under the window,
  /// which is why this is not the dozen a native view hierarchy needs.
  private static let maximumCandidateDepth = 25
  private static let maximumParentDepth = 12
  /// How many text blocks are collected before the scan stops early. Enough
  /// to rebuild the passage around a selection, far short of the whole window.
  private static let maximumTextSegmentCount = 400
  /// How many are collected even after the selection has already been found
  /// with its own context — the reserve that covers the case where the
  /// clipboard later disagrees with what accessibility reported.
  private static let minimumTextSegmentCount = 60
  private static let maximumSegmentCorpusLength = 100_000
  /// How long the whole traversal may take before it returns what it has. An
  /// unresponsive application would otherwise hold the capture for as long as
  /// its slowest reply, once per element.
  private static let traversalBudget = Duration.milliseconds(1_200)
  /// How long any single request to another application may take. Without
  /// this the accessibility API waits its own default of several seconds, and
  /// a walk of a few thousand elements inherits that per element.
  private static let messagingTimeout: Float = 0.4

  /// Subtrees that never hold the text a reader selected, and that cost the
  /// budget the content needs. Menus are excluded for the same reason plus
  /// one more: reading them can dismiss them.
  private static let skippedDescendantRoles: Set<String> = [
    kAXMenuBarRole,
    kAXMenuBarItemRole,
    kAXMenuRole,
    kAXMenuItemRole,
    kAXToolbarRole,
    kAXScrollBarRole,
    "AXSecureTextField",
  ]

  /// Roles whose value is prose worth searching. `AXHeading` and `AXWebArea`
  /// answer with a level or nothing at all in most applications; they cost a
  /// nil and are kept because the ones that do answer are exactly the readers
  /// this feature exists for.
  private static let readableTextRoles: Set<String> = [
    kAXStaticTextRole,
    kAXTextAreaRole,
    kAXTextFieldRole,
    kAXCellRole,
    "AXHeading",
    "AXLink",
    "AXParagraph",
    "AXWebArea",
  ]

  private static let log = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.phraselens.app",
    category: "selection"
  )

  func isTrusted(prompt: Bool = false) -> Bool {
    guard prompt else { return AXIsProcessTrusted() }
    let options =
      [
        kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
      ] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
  }

  @MainActor
  func currentSelection(
    from processIdentifier: pid_t? = nil,
    allowCopyFallback: Bool
  ) async throws -> SelectionSnapshot {
    guard isTrusted() else {
      throw TranslationError.accessibilityPermissionRequired
    }
    // Read the workspace here: it is main-actor state, and the traversal that
    // needs it runs off the main thread so a slow application cannot freeze
    // the interface while it is being asked what is selected.
    let frontmostProcessIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let capture = try await Task.detached(priority: .userInitiated) { [self] in
      try self.captureAccessibilityState(
        from: processIdentifier,
        frontmostProcessIdentifier: frontmostProcessIdentifier
      )
    }.value

    // A broad content traversal is useful for finding context, but some
    // readers expose the same selection range on several static-text
    // descendants. A range from one paragraph can therefore produce a
    // plausible substring in another paragraph. When clipboard access is
    // enabled, use Copy as the selection anchor even when accessibility
    // returned non-empty text; accessibility remains the fallback for
    // controls that cannot copy their selection.
    let copiedText =
      allowCopyFallback
      ? await copiedSelectionPreservingClipboard(from: processIdentifier)
      : nil
    let evidence = SelectionEvidenceResolver.resolve(
      accessibilityText: capture.snapshot?.text ?? "",
      copiedText: copiedText
    )
    let resolvedText = evidence.text

    var diagnostics = capture.diagnostics
    diagnostics.accessibilityTextLength = (capture.snapshot?.text ?? "").count
    diagnostics.accessibilityContextLength = (capture.snapshot?.surroundingText ?? "").count
    diagnostics.copiedTextLength = copiedText?.count ?? 0

    // What qualifies the accessibility context is that it holds the text
    // being explained — not that the two reads of the selection came back
    // byte for byte identical. An application that copies with a normalized
    // dash, a stripped soft hyphen, or a bullet in front of a list item
    // disagrees with its own accessibility tree without either read being
    // wrong, and the paragraph is right either way.
    var resolvedContext: String?
    if !resolvedText.isEmpty {
      if let accessibilityContext = capture.snapshot?.surroundingText,
        PromptBuilder.hasMeaningfulContext(accessibilityContext, for: resolvedText)
      {
        resolvedContext = accessibilityContext
        diagnostics.contextSource = .accessibility
      } else if let matched = SelectionContextMatcher.context(
        matching: resolvedText,
        in: capture.textSegments
      ) {
        resolvedContext = matched
        diagnostics.contextSource = .surroundingSegments
      }
    }

    Self.log.info(
      "capture role=\(diagnostics.focusedRole ?? "none", privacy: .public) elements=\(diagnostics.candidateCount, privacy: .public) blocks=\(diagnostics.textSegmentCount, privacy: .public) axText=\(diagnostics.accessibilityTextLength, privacy: .public) axContext=\(diagnostics.accessibilityContextLength, privacy: .public) copied=\(diagnostics.copiedTextLength, privacy: .public) resolved=\(resolvedText.count, privacy: .public) context=\(diagnostics.contextSource.rawValue, privacy: .public) traversal=\(diagnostics.traversalMilliseconds, privacy: .public)ms truncated=\(diagnostics.traversalTruncated, privacy: .public)"
    )

    return SelectionSnapshot(
      text: resolvedText,
      surroundingText: resolvedContext,
      // The rectangle says where the selection is on screen. It survives a
      // disagreement the two reads can still both be describing — one text
      // containing the other — and is dropped when they are unrelated, since
      // then it points somewhere the reader is not looking.
      screenRect: evidence.accessibilityOverlaps ? capture.snapshot?.screenRect : nil,
      diagnostics: diagnostics
    )
  }

  // MARK: - Traversal

  /// One pass over the source application: what is selected, and the text
  /// blocks around it.
  ///
  /// Both answers come out of a single walk because they are read from the
  /// same elements. Splitting them would double the number of requests sent
  /// to an application that may already be the reason this is slow.
  private func captureAccessibilityState(
    from processIdentifier: pid_t?,
    frontmostProcessIdentifier: pid_t?
  ) throws -> AccessibilityCapture {
    let clock = ContinuousClock()
    let started = clock.now
    let deadline = started.advanced(by: Self.traversalBudget)

    // The focused element is often only a container. Readers such as Apple
    // Books keep the actual WebArea and static text below that container,
    // while browsers and native editors may expose selection on the focused
    // element or one of its ancestors. Search the active window by capability
    // instead of assuming a particular application or tree direction.
    let application = try applicationElement(
      for: processIdentifier,
      frontmostProcessIdentifier: frontmostProcessIdentifier
    )
    let sourceElement = try? focusedElement(in: application)
    if let sourceElement, isWithinSecureTextElement(sourceElement) {
      throw TranslationError.selectionUnavailable
    }

    var capture = AccessibilityCapture()
    capture.diagnostics.focusedRole = sourceElement.flatMap {
      stringAttribute(kAXRoleAttribute, from: $0)
    }

    var truncated = false
    let candidates = selectionCandidates(
      focusedElement: sourceElement,
      window: contentWindow(of: application),
      deadline: deadline,
      truncated: &truncated
    )
    capture.diagnostics.candidateCount = candidates.count

    var snapshot: SelectionSnapshot?
    var fallbackSnapshot: SelectionSnapshot?
    var segments: [String] = []
    var segmentLength = 0

    for element in candidates {
      guard clock.now < deadline else {
        truncated = true
        break
      }
      // Read once, use twice: the role decides whether this element's text
      // belongs in the corpus, and the value is both that text and the
      // context a ranged selection is cut out of.
      let role = stringAttribute(kAXRoleAttribute, from: element)
      let value = stringAttribute(kAXValueAttribute, from: element)

      // Text markers are asked first because of what they return, not because
      // they are more likely to answer: a marker range is expanded to the
      // paragraph around the selection, while an element's value is its whole
      // document. On a web page both succeed, and taking the value first is
      // how "context" came back as the entire page — navigation, heading, and
      // every paragraph — run together without so much as a space between
      // blocks. Native text areas expose no markers and still take the value.
      if snapshot == nil {
        if let found = textMarkerSelectionSnapshot(from: element) {
          if hasUsefulContext(found) {
            snapshot = found
          } else {
            fallbackSnapshot = fallbackSnapshot ?? found
          }
        }
        if snapshot == nil, let found = rangeSelectionSnapshot(from: element, value: value) {
          if hasUsefulContext(found) {
            snapshot = found
          } else {
            fallbackSnapshot = fallbackSnapshot ?? found
          }
        }
      }

      if segments.count < Self.maximumTextSegmentCount,
        segmentLength < Self.maximumSegmentCorpusLength,
        let segment = readableTextSegment(role: role, value: value)
      {
        segments.append(segment)
        segmentLength += segment.count
      }

      // Once the owning control has answered with a usable context, the
      // corpus is only insurance against the clipboard disagreeing with it.
      // Collect enough for that and stop walking the rest of the window.
      if snapshot != nil, segments.count >= Self.minimumTextSegmentCount {
        break
      }
    }

    capture.snapshot = snapshot ?? fallbackSnapshot
    capture.textSegments = segments
    capture.diagnostics.textSegmentCount = segments.count
    capture.diagnostics.traversalTruncated = truncated
    let elapsed = started.duration(to: clock.now).components
    capture.diagnostics.traversalMilliseconds = Int(
      elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
    )
    return capture
  }

  private func applicationElement(
    for processIdentifier: pid_t?,
    frontmostProcessIdentifier: pid_t?
  ) throws -> AXUIElement {
    if let processIdentifier {
      return prepared(AXUIElementCreateApplication(processIdentifier))
    }

    let systemWide = AXUIElementCreateSystemWide()
    var focusedApplication: CFTypeRef?
    if AXUIElementCopyAttributeValue(
      systemWide,
      kAXFocusedApplicationAttribute as CFString,
      &focusedApplication
    ) == .success,
      let application = focusedApplication,
      CFGetTypeID(application) == AXUIElementGetTypeID()
    {
      return prepared(unsafeDowncast(application, to: AXUIElement.self))
    }

    // The system-wide focused application is empty whenever no window owns
    // keyboard focus: while a menu is tracking, or while PhraseLens runs as an
    // accessory with only a non-activating panel on screen. That is exactly
    // when the menu routes into selection capture, and it is a missing
    // selection rather than a failure worth an alert, so fall back to the
    // frontmost application and let the caller treat an empty read as "nothing
    // selected".
    guard let frontmostProcessIdentifier else {
      throw TranslationError.selectionUnavailable
    }
    return prepared(AXUIElementCreateApplication(frontmostProcessIdentifier))
  }

  /// Bounds what one application can cost us, and asks the ones that build
  /// their accessibility tree on demand to build it.
  ///
  /// Chromium and everything shipped on top of it — Chrome, Slack, VS Code,
  /// Discord, Notion — expose a stub tree until an assistive client sets
  /// `AXManualAccessibility`. Without it the walk below finds a window with
  /// no text under it, which is indistinguishable from nothing being
  /// selected. Applications that do not recognize the attribute return an
  /// error and are unaffected.
  private func prepared(_ application: AXUIElement) -> AXUIElement {
    AXUIElementSetMessagingTimeout(application, Self.messagingTimeout)
    AXUIElementSetAttributeValue(
      application,
      "AXManualAccessibility" as CFString,
      kCFBooleanTrue
    )
    return application
  }

  /// The window whose text the reader is looking at.
  ///
  /// A source application that is no longer frontmost — which is every
  /// capture started from the menu bar — often reports no focused window at
  /// all. Falling through to the main window, and then to whatever window it
  /// has, is the difference between a walk over the content and no walk.
  private func contentWindow(of application: AXUIElement) -> AXUIElement? {
    if let focused = uiElementAttribute(kAXFocusedWindowAttribute, from: application) {
      return focused
    }
    if let main = uiElementAttribute(kAXMainWindowAttribute, from: application) {
      return main
    }
    guard let windows = attribute(kAXWindowsAttribute, from: application) as? [AnyObject] else {
      return nil
    }
    return
      windows
      .lazy
      .compactMap { window -> AXUIElement? in
        let value: CFTypeRef = window
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
      }
      .first
  }

  private func focusedElement() throws -> AXUIElement {
    try focusedElement(
      in: applicationElement(
        for: nil,
        frontmostProcessIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier
      )
    )
  }

  private func focusedElement(in application: AXUIElement) throws -> AXUIElement {
    var focusedElement: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        application,
        kAXFocusedUIElementAttribute as CFString,
        &focusedElement
      ) == .success,
      let element = focusedElement,
      CFGetTypeID(element) == AXUIElementGetTypeID()
    else {
      throw TranslationError.focusedInputUnavailable
    }
    return unsafeDowncast(element, to: AXUIElement.self)
  }

  private func selectionCandidates(
    focusedElement: AXUIElement?,
    window: AXUIElement?,
    deadline: ContinuousClock.Instant,
    truncated: inout Bool
  ) -> [AXUIElement] {
    var candidates: [AXUIElement] = []
    var candidateBuckets: [CFHashCode: [AXUIElement]] = [:]

    if let focusedElement {
      appendUnique(focusedElement, to: &candidates, buckets: &candidateBuckets)
      var current = parent(of: focusedElement)
      for _ in 0..<Self.maximumParentDepth {
        guard let element = current else { break }
        appendUnique(element, to: &candidates, buckets: &candidateBuckets)
        current = parent(of: element)
      }
      appendDescendants(
        of: focusedElement,
        to: &candidates,
        buckets: &candidateBuckets,
        deadline: deadline,
        truncated: &truncated
      )
    }

    if let window, candidates.count < Self.maximumCandidateCount {
      appendUnique(window, to: &candidates, buckets: &candidateBuckets)
      appendDescendants(
        of: window,
        to: &candidates,
        buckets: &candidateBuckets,
        deadline: deadline,
        truncated: &truncated
      )
    }
    return candidates
  }

  private func appendDescendants(
    of root: AXUIElement,
    to candidates: inout [AXUIElement],
    buckets: inout [CFHashCode: [AXUIElement]],
    deadline: ContinuousClock.Instant,
    truncated: inout Bool
  ) {
    let clock = ContinuousClock()
    var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
    var queueIndex = 0
    var traversalBuckets: [CFHashCode: [AXUIElement]] = [:]
    insertUnique(root, into: &traversalBuckets)

    while queueIndex < queue.count, candidates.count < Self.maximumCandidateCount {
      guard clock.now < deadline else {
        truncated = true
        return
      }
      let item = queue[queueIndex]
      queueIndex += 1
      guard item.depth < Self.maximumCandidateDepth else { continue }

      for child in children(of: item.element) {
        guard
          insertUnique(child, into: &traversalBuckets),
          !shouldSkipDescendants(of: child)
        else {
          continue
        }
        appendUnique(child, to: &candidates, buckets: &buckets)
        queue.append((child, item.depth + 1))
        if candidates.count >= Self.maximumCandidateCount {
          truncated = true
          break
        }
      }
    }
  }

  @discardableResult
  private func appendUnique(
    _ element: AXUIElement,
    to elements: inout [AXUIElement],
    buckets: inout [CFHashCode: [AXUIElement]]
  ) -> Bool {
    guard insertUnique(element, into: &buckets) else { return false }
    elements.append(element)
    return true
  }

  @discardableResult
  private func insertUnique(
    _ element: AXUIElement,
    into buckets: inout [CFHashCode: [AXUIElement]]
  ) -> Bool {
    let hash = CFHash(element)
    if buckets[hash]?.contains(where: { CFEqual($0, element) }) == true {
      return false
    }
    buckets[hash, default: []].append(element)
    return true
  }

  private func children(of element: AXUIElement) -> [AXUIElement] {
    guard let rawChildren = attribute(kAXChildrenAttribute, from: element) as? [AnyObject] else {
      return []
    }
    return rawChildren.compactMap { child in
      let value: CFTypeRef = child
      guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
      return unsafeDowncast(value, to: AXUIElement.self)
    }
  }

  private func shouldSkipDescendants(of element: AXUIElement) -> Bool {
    guard let role = stringAttribute(kAXRoleAttribute, from: element) else { return false }
    return Self.skippedDescendantRoles.contains(role)
  }

  private func isWithinSecureTextElement(_ element: AXUIElement) -> Bool {
    var current: AXUIElement? = element
    for _ in 0..<Self.maximumParentDepth {
      guard let candidate = current else { break }
      if stringAttribute(kAXRoleAttribute, from: candidate) == "AXSecureTextField" {
        return true
      }
      current = parent(of: candidate)
    }
    return false
  }

  // MARK: - Editable text

  func currentEditableText() throws -> String {
    guard isTrusted() else {
      throw TranslationError.accessibilityPermissionRequired
    }
    let element = try focusedElement()
    guard !isWithinSecureTextElement(element) else {
      throw TranslationError.provider(L10n.isChinese ? "不能翻译或替换安全文本字段中的内容。" : "Secure text fields cannot be translated or replaced.")
    }
    // A readable value can belong to static text or a read-only control. Check
    // editability before spending a provider request on an unusable target.
    try requireEditableValue(in: element)
    guard let value = stringAttribute(kAXValueAttribute, from: element),
      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw TranslationError.noInput
    }
    return value
  }

  func replaceCurrentEditableText(with replacement: String) throws {
    guard isTrusted() else {
      throw TranslationError.accessibilityPermissionRequired
    }
    let element = try focusedElement()
    guard !isWithinSecureTextElement(element) else {
      throw TranslationError.provider(L10n.isChinese ? "不能翻译或替换安全文本字段中的内容。" : "Secure text fields cannot be translated or replaced.")
    }
    guard let value = stringAttribute(kAXValueAttribute, from: element) else {
      throw TranslationError.focusedInputUnavailable
    }
    let range = selectedRange(from: element)
    let nextValue: String
    let cursorOffset: Int
    if let range, range.length > 0 {
      let nsValue = value as NSString
      guard range.location >= 0, range.location + range.length <= nsValue.length else {
        throw TranslationError.provider(L10n.isChinese ? "当前获得焦点的控件返回了无效选区。" : "The focused control returned an invalid selection.")
      }
      nextValue = nsValue.replacingCharacters(
        in: NSRange(location: range.location, length: range.length),
        with: replacement
      )
      cursorOffset = range.location + (replacement as NSString).length
    } else {
      nextValue = replacement
      cursorOffset = (replacement as NSString).length
    }

    try requireEditableValue(in: element)
    let status = AXUIElementSetAttributeValue(
      element,
      kAXValueAttribute as CFString,
      nextValue as CFString
    )
    guard status == .success else {
      throw TranslationError.provider(L10n.isChinese ? "无法替换当前获得焦点的控件中的文本。" : "Could not replace text in the focused control.")
    }

    var cursorRange = CFRange(location: cursorOffset, length: 0)
    if let value = AXValueCreate(.cfRange, &cursorRange) {
      AXUIElementSetAttributeValue(
        element,
        kAXSelectedTextRangeAttribute as CFString,
        value
      )
    }
  }

  private func requireEditableValue(in element: AXUIElement) throws {
    var settable = DarwinBoolean(false)
    let settableStatus = AXUIElementIsAttributeSettable(
      element,
      kAXValueAttribute as CFString,
      &settable
    )
    guard settableStatus == .success, settable.boolValue else {
      throw TranslationError.focusedInputUnavailable
    }
  }

  // MARK: - Writing back

  /// Records the control a selection was just read from, so a later command
  /// can write an answer over the selection or after it.
  ///
  /// Cheap on purpose — the focused control and a few of its attributes —
  /// and kept out of the capture traversal, which is built to find text
  /// rather than the control that would accept it.
  @MainActor
  func insertionTarget(for processIdentifier: pid_t?, selectedText: String) -> InsertionTarget? {
    guard
      isTrusted(),
      let processIdentifier = processIdentifier
        ?? NSWorkspace.shared.frontmostApplication?.processIdentifier,
      processIdentifier != ProcessInfo.processInfo.processIdentifier
    else { return nil }
    let application = prepared(AXUIElementCreateApplication(processIdentifier))
    guard
      let element = try? focusedElement(in: application),
      !isWithinSecureTextElement(element)
    else { return nil }
    return InsertionTarget(
      processIdentifier: processIdentifier,
      applicationName: NSRunningApplication(processIdentifier: processIdentifier)?.localizedName,
      element: element,
      selectedRange: selectedRange(from: element).flatMap { $0.length > 0 ? $0 : nil },
      selectedText: selectedText,
      isEditable: isWritable(element),
      isWebContent: isWithinWebArea(element)
    )
  }

  /// Writes `text` over the captured selection, or after it.
  ///
  /// Accessibility goes first because it touches nothing but the control: no
  /// clipboard and no keystrokes. Plenty of controls accept that call and
  /// ignore it, though, so the value is read back, and only a control that
  /// did not change falls through to a paste — the one route every
  /// application understands.
  @MainActor
  func write(
    _ text: String,
    placement: InsertionPlacement,
    into target: InsertionTarget
  ) async throws -> InsertionMethod {
    guard isTrusted() else { throw TranslationError.accessibilityPermissionRequired }
    guard
      target.isEditable,
      !target.selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { throw TranslationError.focusedInputUnavailable }
    let appName = target.applicationName ?? (L10n.isChinese ? "原应用" : "the source app")
    guard
      let application = NSRunningApplication(processIdentifier: target.processIdentifier),
      !application.isTerminated
    else {
      throw TranslationError.provider(
        L10n.isChinese ? "\(appName) 已退出。" : "\(appName) is no longer running."
      )
    }

    // While the reader clicks, the pop-up or the main window holds key focus.
    // The source application has to take it back before its control will
    // accept a paste, and a held modifier would turn ⌘V into something else.
    await waitForShortcutModifiersToLift()
    guard await bringToFront(application) else {
      throw TranslationError.provider(
        L10n.isChinese ? "无法切换回 \(appName)。" : "Could not bring \(appName) back to the front."
      )
    }

    let plan = try writePlan(for: text, placement: placement, target: target)
    if let element = target.element, let range = plan.range {
      if plan.payload == plan.replacedText { return .accessibility }
      if writeThroughAccessibility(plan.payload, over: range, in: element) {
        return .accessibility
      }
    }

    // Put the caret where the answer belongs. A plan with a range is placed
    // there directly. Without one, the live selection is the reader's own and
    // a replacement simply pastes over it, while an insertion collapses it to
    // its end with → and then moves by arrow keys, which every control
    // resolves against its own text.
    var caretKeys: [CGKeyCode] = []
    if let element = target.element, let range = plan.range {
      select(range, in: element)
    } else if placement == .after {
      let step: CGKeyCode = plan.caretOffset > 0 ? 124 : 123  // → or ←
      caretKeys = [124] + Array(repeating: step, count: abs(plan.caretOffset))
    }
    let valueBefore = target.element.flatMap { stringAttribute(kAXValueAttribute, from: $0) }
    try await paste(
      plan.payload,
      to: target.processIdentifier,
      caretKeys: caretKeys
    ) {
      // A control whose value can be read can also say whether the paste
      // landed. One that cannot is given the benefit of the doubt.
      guard let element = target.element, let valueBefore else { return true }
      return stringAttribute(kAXValueAttribute, from: element) != valueBefore
    }
    return .paste
  }

  private static var selectionChanged: TranslationError {
    .provider(
      L10n.isChinese
        ? "选中的文字已经改变，未写入任何内容。"
        : "The selected text has changed since it was read, so nothing was written."
    )
  }

  private struct WritePlan {
    /// Where to write, in the control's own offsets, or nil to work from the
    /// live selection instead.
    var range: CFRange?
    var payload: String
    /// What the selection holds now, for skipping a replace that changes
    /// nothing. Only known when the control reads its range back.
    var replacedText: String?
    /// For an insertion placed from the live selection: how many characters
    /// from the selection's end it goes, negative for back.
    var caretOffset = 0
  }

  private func writePlan(
    for text: String,
    placement: InsertionPlacement,
    target: InsertionTarget
  ) throws -> WritePlan {
    func matches(_ text: String) -> Bool {
      SelectionContextMatcher.normalize(text) == SelectionContextMatcher.normalize(target.selectedText)
    }
    // Web content is never placed by offset. Chrome counts offsets without
    // its paragraph breaks and resolves one on a boundary to the start of the
    // next paragraph, which put a replacement across the break and an
    // insertion in front of the wrong text. There the live selection decides.
    //
    // Everywhere else, what the captured range holds now: the reader may have
    // kept typing with the pop-up pinned, so write only where the captured
    // text still is, never over whatever replaced it.
    let rangeText = target.isWebContent ? nil : target.element.flatMap { element in
      target.selectedRange.flatMap { range in
        string(for: range, from: element)
          ?? stringAttribute(kAXValueAttribute, from: element).map { substring($0, range: range) }
      }
    }
    if let rangeText, !matches(rangeText) { throw Self.selectionChanged }

    // Without a usable range the live selection is what gets written over or
    // after, so it has to still be the captured one.
    let usesOffsets = rangeText != nil
    let liveText = target.element.flatMap { stringAttribute(kAXSelectedTextAttribute, from: $0) }
    if !usesOffsets, let liveText, !matches(liveText) { throw Self.selectionChanged }

    let selection = rangeText ?? liveText ?? target.selectedText
    switch placement {
    case .replace:
      return WritePlan(
        range: usesOffsets ? target.selectedRange : nil,
        payload: WriteBackComposer.replacement(for: text, over: selection),
        replacedText: rangeText
      )
    case .after:
      let following = target.element.flatMap { element in
        target.selectedRange.flatMap {
          textFollowing(selection, near: $0, in: element, isWebContent: target.isWebContent)
        }
      }
      let insertion = WriteBackComposer.insertion(of: text, after: selection, followedBy: following)
      let range = target.selectedRange.map {
        CFRange(location: $0.location + $0.length + insertion.utf16Offset, length: 0)
      }
      return WritePlan(
        range: usesOffsets ? range : nil,
        payload: insertion.text,
        caretOffset: insertion.characterOffset
      )
    }
  }

  /// The character right after the selection: empty at the very end of the
  /// text, nil when the control will not say.
  ///
  /// Read from the control's value, finding the selected text itself from
  /// its reported offset onwards, rather than by asking for the range after
  /// it. Chrome's ranges skip its paragraph breaks, so the character "after"
  /// a paragraph there is the first letter of the next one, while its value
  /// has the breaks and runs one offset ahead per paragraph above.
  ///
  /// A web editor whose value ends in nothing but line breaks is at its end:
  /// Safari reports breaks after the last paragraph that no arrow key can
  /// move past.
  private func textFollowing(
    _ selection: String,
    near range: CFRange,
    in element: AXUIElement,
    isWebContent: Bool
  ) -> String? {
    guard !selection.isEmpty, let value = stringAttribute(kAXValueAttribute, from: element) else { return nil }
    let text = value as NSString
    let start = min(max(range.location, 0), text.length)
    let found = text.range(of: selection, range: NSRange(location: start, length: text.length - start))
    guard found.location != NSNotFound else { return nil }
    let end = found.location + found.length
    let rest = text.substring(from: end)
    if rest.isEmpty || (isWebContent && rest.allSatisfy(\.isWhitespace)) { return "" }
    return text.substring(with: NSRange(location: end, length: 1))
  }

  private func isWithinWebArea(_ element: AXUIElement) -> Bool {
    var current: AXUIElement? = element
    for _ in 0..<Self.maximumParentDepth * 2 {
      guard let candidate = current else { return false }
      if stringAttribute(kAXRoleAttribute, from: candidate) == "AXWebArea" { return true }
      current = parent(of: candidate)
    }
    return false
  }

  private func isWritable(_ element: AXUIElement) -> Bool {
    [kAXSelectedTextAttribute, kAXValueAttribute].contains { name in
      var settable = DarwinBoolean(false)
      return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success
        && settable.boolValue
    }
  }

  /// Moves the selection to `range` unless it is already there.
  ///
  /// Setting a range the control already holds is not a no-op everywhere:
  /// Chrome maps the offsets back onto the DOM and, at a paragraph boundary,
  /// can come back with a selection that also takes the break.
  @discardableResult
  private func select(_ range: CFRange, in element: AXUIElement) -> Bool {
    if let current = selectedRange(from: element),
      current.location == range.location, current.length == range.length
    {
      return true
    }
    var range = range
    guard let value = AXValueCreate(.cfRange, &range) else { return false }
    return AXUIElementSetAttributeValue(
      element, kAXSelectedTextRangeAttribute as CFString, value
    ) == .success
  }

  private func writeThroughAccessibility(
    _ payload: String,
    over range: CFRange,
    in element: AXUIElement
  ) -> Bool {
    var settable = DarwinBoolean(false)
    guard
      AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
        == .success,
      settable.boolValue,
      select(range, in: element)
    else { return false }
    let before = stringAttribute(kAXValueAttribute, from: element)
    guard
      AXUIElementSetAttributeValue(
        element, kAXSelectedTextAttribute as CFString, payload as CFString
      ) == .success
    else { return false }
    // Accepting the call is not the same as acting on it.
    guard before == nil || stringAttribute(kAXValueAttribute, from: element) != before else {
      return false
    }
    select(CFRange(location: range.location + (payload as NSString).length, length: 0), in: element)
    return true
  }

  @MainActor
  private func bringToFront(_ application: NSRunningApplication) async -> Bool {
    // The pop-up never activates PhraseLens, so the source is usually still
    // the active application and only needs its key window back, which it
    // gets when the pop-up closes. The main window did activate PhraseLens,
    // and activation has to be handed over explicitly since macOS 14.
    if NSWorkspace.shared.frontmostApplication?.processIdentifier != application.processIdentifier {
      NSApp.yieldActivation(to: application)
      application.activate(from: .current, options: [])
    }
    for _ in 0..<40 {
      if NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier {
        // Being frontmost comes a beat before having a key window again.
        try? await Task.sleep(for: .milliseconds(80))
        return true
      }
      try? await Task.sleep(for: .milliseconds(25))
    }
    return false
  }

  @MainActor
  private func paste(
    _ payload: String,
    to processIdentifier: pid_t,
    caretKeys: [CGKeyCode],
    landed: @MainActor () -> Bool
  ) async throws {
    let pasteboard = NSPasteboard.general
    let savedItems = pasteboardSnapshot()
    pasteboard.clearContents()
    let item = NSPasteboardItem()
    item.setString(payload, forType: .string)
    // Asks clipboard managers to leave this out of their history: it is a
    // delivery, and the reader's own clipboard comes back below.
    item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
    item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
    pasteboard.writeObjects([item])
    let written = pasteboard.changeCount

    for key in caretKeys {
      await postKey(key, flags: [], to: processIdentifier)
    }
    await postKey(KeyboardLayoutKeys.keyCode(for: "v", fallback: 9), flags: .maskCommand, to: processIdentifier)

    // Applications read a paste asynchronously — Electron and web views well
    // after the key event — so the clipboard is handed back only once they
    // have had time to take it, and not at all if something else wrote since.
    try? await Task.sleep(for: .milliseconds(400))
    guard landed() else {
      // Leave the answer on the clipboard: it is the reader's fallback now.
      throw TranslationError.provider(
        L10n.isChinese
          ? "目标应用没有接受粘贴。结果已拷贝，可手动按 ⌘V 粘贴。"
          : "The app did not accept the paste. The result is on the clipboard — press ⌘V to paste it."
      )
    }
    if pasteboard.changeCount == written {
      restorePasteboard(savedItems)
    }
  }

  @MainActor
  private func postKey(_ code: CGKeyCode, flags: CGEventFlags, to processIdentifier: pid_t) async {
    let eventSource = CGEventSource(stateID: .combinedSessionState)
    guard
      let keyDown = CGEvent(keyboardEventSource: eventSource, virtualKey: code, keyDown: true),
      let keyUp = CGEvent(keyboardEventSource: eventSource, virtualKey: code, keyDown: false)
    else { return }
    keyDown.flags = flags
    keyUp.flags = flags
    postCopyEvent(keyDown, to: processIdentifier)
    try? await Task.sleep(for: .milliseconds(24))
    postCopyEvent(keyUp, to: processIdentifier)
    try? await Task.sleep(for: .milliseconds(24))
  }

  @MainActor
  private func pasteboardSnapshot() -> [NSPasteboardItem] {
    (NSPasteboard.general.pasteboardItems ?? []).map { item in
      let copy = NSPasteboardItem()
      for type in item.types {
        if let data = item.data(forType: type) {
          copy.setData(data, forType: type)
        }
      }
      return copy
    }
  }

  #if DEBUG
  /// The target control's whole value, for the write-back probe.
  func debugValue(of target: InsertionTarget) -> String? {
    target.element.flatMap { stringAttribute(kAXValueAttribute, from: $0) }
  }
  #endif

  // MARK: - Clipboard anchor

  @MainActor
  private func copiedSelectionPreservingClipboard(from expectedProcessIdentifier: pid_t?) async
    -> String?
  {
    // A global shortcut is delivered on key-down, while Option (or another
    // shortcut modifier) can still be physically held. Injecting Command-C at
    // that moment becomes Command-Option-C in some apps, so wait briefly for
    // the triggering shortcut to be released before asking the source app to
    // copy its selection.
    await waitForShortcutModifiersToLift()

    // Never copy from a different application if focus changed while the
    // shortcut modifiers were being released. Besides returning the wrong
    // text, that could expose unrelated clipboard data to a translation.
    if let expectedProcessIdentifier,
      NSWorkspace.shared.frontmostApplication?.processIdentifier != expectedProcessIdentifier
    {
      return nil
    }

    let pasteboard = NSPasteboard.general
    let savedItems = pasteboardSnapshot()

    let clearedChangeCount = pasteboard.clearContents()
    defer {
      restorePasteboard(savedItems)
    }

    let eventSource = CGEventSource(stateID: .combinedSessionState)
    let copyKey = KeyboardLayoutKeys.keyCode(for: "c", fallback: 8)
    guard
      let keyDown = CGEvent(keyboardEventSource: eventSource, virtualKey: copyKey, keyDown: true),
      let keyUp = CGEvent(keyboardEventSource: eventSource, virtualKey: copyKey, keyDown: false)
    else { return nil }
    keyDown.flags = .maskCommand
    keyUp.flags = .maskCommand
    postCopyEvent(keyDown, to: expectedProcessIdentifier)
    try? await Task.sleep(for: .milliseconds(24))
    postCopyEvent(keyUp, to: expectedProcessIdentifier)

    // Browsers, PDF viewers, and Electron apps can update the pasteboard well
    // after the keyboard event. Keep the original clipboard intact, but allow
    // enough time for those apps to respond.
    for _ in 0..<40 {
      try? await Task.sleep(for: .milliseconds(25))
      if pasteboard.changeCount != clearedChangeCount {
        let copied = pasteboard.string(forType: .string)?
          .trimmingCharacters(in: .whitespacesAndNewlines)
        return copied?.isEmpty == false ? copied : nil
      }
    }
    return nil
  }

  private func postCopyEvent(_ event: CGEvent, to processIdentifier: pid_t?) {
    if let processIdentifier {
      // Keep Copy bound to the application that owned the selection when the
      // Carbon shortcut fired. Posting to the global HID stream can be lost
      // when Electron/WebKit focus changes during the async actor hop.
      event.postToPid(processIdentifier)
    } else {
      event.post(tap: .cgSessionEventTap)
    }
  }

  @MainActor
  private func waitForShortcutModifiersToLift() async {
    let shortcutModifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
    for _ in 0..<20 {
      let flags = CGEventSource.flagsState(.combinedSessionState)
      if flags.intersection(shortcutModifiers).isEmpty {
        return
      }
      try? await Task.sleep(for: .milliseconds(25))
    }
  }

  @MainActor
  private func restorePasteboard(_ items: [NSPasteboardItem]) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    if !items.isEmpty {
      let writableItems: [any NSPasteboardWriting] = items
      pasteboard.writeObjects(writableItems)
    }
  }

  // MARK: - Reading one element

  private func rangeSelectionSnapshot(
    from element: AXUIElement,
    value: String?
  ) -> SelectionSnapshot? {
    let selectedAttribute =
      stringAttribute(kAXSelectedTextAttribute, from: element)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let range = selectedRange(from: element)
    let value = value ?? ""

    let selectedText: String
    if !selectedAttribute.isEmpty {
      selectedText = selectedAttribute
    } else if let range, range.length > 0 {
      let rangedValue = substring(value, range: range)
      selectedText = !rangedValue.isEmpty ? rangedValue : string(for: range, from: element) ?? ""
    } else {
      return nil
    }
    guard !selectedText.isEmpty else { return nil }

    var context = value
    if context.isEmpty, let range {
      context = stringAroundRange(range, from: element) ?? ""
    }
    let boundedContext =
      context.isEmpty ? nil : PromptBuilder.boundedContext(context, around: selectedText)
    return SelectionSnapshot(
      text: selectedText,
      surroundingText: boundedContext,
      screenRect: range.flatMap { bounds(for: $0, from: element) }
    )
  }

  private func stringAroundRange(_ selectedRange: CFRange, from element: AXUIElement) -> String? {
    let radius = PromptBuilder.maximumSelectionContextLength / 2
    let start = max(0, selectedRange.location - radius)
    let minimumLength = selectedRange.location + selectedRange.length - start
    var contextRange = CFRange(
      location: start,
      length: minimumLength + radius
    )

    // Some controls reject a range extending beyond their content. Shrink the
    // trailing side until the request succeeds while preserving the selection.
    while contextRange.length >= minimumLength {
      if let rangeValue = AXValueCreate(.cfRange, &contextRange),
        let text = parameterizedText(
          kAXStringForRangeParameterizedAttribute,
          fallbackName: kAXAttributedStringForRangeParameterizedAttribute,
          parameter: rangeValue,
          from: element
        ),
        !text.isEmpty
      {
        return text
      }
      let excess = contextRange.length - minimumLength
      guard excess > 0 else { break }
      contextRange.length = minimumLength + excess / 2
    }
    return nil
  }

  private func string(for range: CFRange, from element: AXUIElement) -> String? {
    var range = range
    guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
    return parameterizedText(
      kAXStringForRangeParameterizedAttribute,
      fallbackName: kAXAttributedStringForRangeParameterizedAttribute,
      parameter: rangeValue,
      from: element
    )
  }

  private func readableTextSegment(role: String?, value: String?) -> String? {
    guard let role, Self.readableTextRoles.contains(role) else { return nil }
    guard
      let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    else {
      return nil
    }
    return value
  }

  private func textMarkerSelectionSnapshot(from element: AXUIElement) -> SelectionSnapshot? {
    guard
      let selectedMarkerRange = attribute("AXSelectedTextMarkerRange", from: element),
      CFGetTypeID(selectedMarkerRange) == AXTextMarkerRangeGetTypeID()
    else {
      return nil
    }

    let selectedText =
      parameterizedText(
        kAXStringForTextMarkerRangeParameterizedAttribute,
        fallbackName: kAXAttributedStringForTextMarkerRangeParameterizedAttribute,
        parameter: selectedMarkerRange,
        from: element
      )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !selectedText.isEmpty else { return nil }

    let markerRange = unsafeDowncast(selectedMarkerRange, to: AXTextMarkerRange.self)
    let selectedStart = AXTextMarkerRangeCopyStartMarker(markerRange)
    let selectedEnd = AXTextMarkerRangeCopyEndMarker(markerRange)
    let contextStart =
      parameterizedTextMarker(
        kAXPreviousParagraphStartTextMarkerForTextMarkerParameterizedAttribute,
        parameter: selectedStart,
        from: element
      )
      ?? parameterizedTextMarker(
        kAXPreviousSentenceStartTextMarkerForTextMarkerParameterizedAttribute,
        parameter: selectedStart,
        from: element
      )
      ?? parameterizedTextMarker(
        kAXPreviousLineStartTextMarkerForTextMarkerParameterizedAttribute,
        parameter: selectedStart,
        from: element
      ) ?? selectedStart
    let contextEnd =
      parameterizedTextMarker(
        kAXNextParagraphEndTextMarkerForTextMarkerParameterizedAttribute,
        parameter: selectedEnd,
        from: element
      )
      ?? parameterizedTextMarker(
        kAXNextSentenceEndTextMarkerForTextMarkerParameterizedAttribute,
        parameter: selectedEnd,
        from: element
      )
      ?? parameterizedTextMarker(
        kAXNextLineEndTextMarkerForTextMarkerParameterizedAttribute,
        parameter: selectedEnd,
        from: element
      ) ?? selectedEnd
    let contextRange = AXTextMarkerRangeCreate(nil, contextStart, contextEnd)
    let context =
      parameterizedText(
        kAXStringForTextMarkerRangeParameterizedAttribute,
        fallbackName: kAXAttributedStringForTextMarkerRangeParameterizedAttribute,
        parameter: contextRange,
        from: element
      ) ?? ""
    let boundedContext =
      context.isEmpty ? nil : PromptBuilder.boundedContext(context, around: selectedText)
    return SelectionSnapshot(
      text: selectedText,
      surroundingText: boundedContext,
      screenRect: bounds(forTextMarkerRange: selectedMarkerRange, from: element)
    )
  }

  private func hasUsefulContext(_ snapshot: SelectionSnapshot) -> Bool {
    PromptBuilder.hasMeaningfulContext(snapshot.surroundingText, for: snapshot.text)
  }

  // MARK: - Attribute plumbing

  private func uiElementAttribute(_ name: String, from element: AXUIElement) -> AXUIElement? {
    guard let value = attribute(name, from: element), CFGetTypeID(value) == AXUIElementGetTypeID()
    else {
      return nil
    }
    return unsafeDowncast(value, to: AXUIElement.self)
  }

  /// A text attribute, whether the application answers with a plain or an
  /// attributed string.
  ///
  /// Rich editors and several web views return `AXValue` as an attributed
  /// string. Reading only plain strings left those elements looking empty —
  /// to the selection read and to the text search alike.
  private func stringAttribute(_ name: String, from element: AXUIElement) -> String? {
    guard let result = attribute(name, from: element) else { return nil }
    if let string = result as? String { return string }
    return (result as? NSAttributedString)?.string
  }

  private func selectedRange(from element: AXUIElement) -> CFRange? {
    if let value = attribute(kAXSelectedTextRangeAttribute, from: element),
      let range = cfRange(from: value)
    {
      return range
    }

    guard
      let values = attribute(kAXSelectedTextRangesAttribute, from: element) as? [AnyObject]
    else { return nil }
    return values.lazy.compactMap { value -> CFRange? in
      let reference: CFTypeRef = value
      return cfRange(from: reference)
    }.first(where: { $0.length > 0 })
  }

  private func cfRange(from value: CFTypeRef) -> CFRange? {
    guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    let axValue = unsafeDowncast(value, to: AXValue.self)
    guard AXValueGetType(axValue) == .cfRange else { return nil }
    var range = CFRange()
    guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
    return range
  }

  private func bounds(for range: CFRange, from element: AXUIElement) -> CGRect? {
    var range = range
    guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
    return parameterizedRect(
      kAXBoundsForRangeParameterizedAttribute,
      parameter: rangeValue,
      from: element
    )
  }

  private func bounds(forTextMarkerRange range: CFTypeRef, from element: AXUIElement) -> CGRect? {
    parameterizedRect(
      kAXBoundsForTextMarkerRangeParameterizedAttribute,
      parameter: range,
      from: element
    )
  }

  private func parameterizedRect(
    _ name: String,
    parameter: CFTypeRef,
    from element: AXUIElement
  ) -> CGRect? {
    var result: CFTypeRef?
    guard
      AXUIElementCopyParameterizedAttributeValue(
        element,
        name as CFString,
        parameter,
        &result
      ) == .success,
      let result,
      CFGetTypeID(result) == AXValueGetTypeID()
    else {
      return nil
    }
    let value = unsafeDowncast(result, to: AXValue.self)
    guard AXValueGetType(value) == .cgRect else { return nil }
    var rect = CGRect.zero
    guard AXValueGetValue(value, .cgRect, &rect), rect.width.isFinite, rect.height.isFinite,
      rect.width > 0, rect.height > 0
    else {
      return nil
    }
    return rect
  }

  private func parent(of element: AXUIElement) -> AXUIElement? {
    guard
      let value = attribute(kAXParentAttribute, from: element),
      CFGetTypeID(value) == AXUIElementGetTypeID()
    else {
      return nil
    }
    return unsafeDowncast(value, to: AXUIElement.self)
  }

  private func attribute(_ name: String, from element: AXUIElement) -> CFTypeRef? {
    var result: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success
    else {
      return nil
    }
    return result
  }

  private func parameterizedText(
    _ name: String,
    fallbackName: String? = nil,
    parameter: CFTypeRef,
    from element: AXUIElement
  ) -> String? {
    if let value = parameterizedTextValue(name, parameter: parameter, from: element) {
      return value
    }
    guard let fallbackName else { return nil }
    return parameterizedTextValue(fallbackName, parameter: parameter, from: element)
  }

  private func parameterizedTextValue(
    _ name: String,
    parameter: CFTypeRef,
    from element: AXUIElement
  ) -> String? {
    var result: CFTypeRef?
    guard
      AXUIElementCopyParameterizedAttributeValue(
        element,
        name as CFString,
        parameter,
        &result
      ) == .success
    else {
      return nil
    }
    if let string = result as? String {
      return string
    }
    return (result as? NSAttributedString)?.string
  }

  private func parameterizedTextMarker(
    _ name: String,
    parameter: AXTextMarker,
    from element: AXUIElement
  ) -> AXTextMarker? {
    var result: CFTypeRef?
    guard
      AXUIElementCopyParameterizedAttributeValue(
        element,
        name as CFString,
        parameter,
        &result
      ) == .success,
      let result,
      CFGetTypeID(result) == AXTextMarkerGetTypeID()
    else {
      return nil
    }
    return unsafeDowncast(result, to: AXTextMarker.self)
  }

  private func substring(_ value: String, range: CFRange) -> String {
    let nsValue = value as NSString
    guard range.location >= 0, range.length >= 0,
      range.location + range.length <= nsValue.length
    else {
      return ""
    }
    return nsValue.substring(with: NSRange(location: range.location, length: range.length))
  }
}

/// Rebuilds the passage around a selection from the text blocks a window
/// exposes, for the cases where the control that owns the selection cannot
/// describe its own surroundings.
enum SelectionContextMatcher {
  private static let maximumSearchCorpusLength = 100_000

  static func context(matching selection: String, in segments: [String]) -> String? {
    let normalizedSelection = normalize(selection)
    guard !normalizedSelection.isEmpty else { return nil }
    let needle = PromptBuilder.matchKey(normalizedSelection)
    guard !needle.isEmpty else { return nil }

    var corpus: [String] = []
    var corpusLength = 0
    for segment in segments {
      let normalized = normalize(segment)
      guard !normalized.isEmpty, corpus.last != normalized else { continue }
      let additionalLength = normalized.count + (corpus.isEmpty ? 0 : 1)
      guard corpusLength + additionalLength <= maximumSearchCorpusLength else { break }
      corpus.append(normalized)
      corpusLength += additionalLength
    }
    guard !corpus.isEmpty else { return nil }

    // The blocks arrive focused-subtree first, so the earliest one holding
    // the selection is the one nearest what the reader was looking at. This
    // used to demand that the selection appear exactly once anywhere in the
    // window and give up otherwise — which failed precisely on what this
    // action is for, a single common word that also appears in a heading, a
    // link, or three paragraphs further down. A repeat now loses the tie
    // instead of costing the reader the context.
    if let anchor = corpus.firstIndex(where: { PromptBuilder.matchKey($0).contains(needle) }) {
      let context = PromptBuilder.boundedContext(
        expanded(around: anchor, in: corpus),
        around: normalizedSelection
      )
      return PromptBuilder.hasMeaningfulContext(context, for: normalizedSelection) ? context : nil
    }

    // A selection dragged across two text nodes belongs to neither of them
    // alone, and only turns up once the blocks are read as one run of text.
    let joined = corpus.joined(separator: " ")
    guard PromptBuilder.matchKey(joined).contains(needle) else { return nil }
    let context = PromptBuilder.boundedContext(joined, around: normalizedSelection)
    return PromptBuilder.hasMeaningfulContext(context, for: normalizedSelection) ? context : nil
  }

  /// The matched block plus its neighbours, up to the context limit.
  ///
  /// Neighbours in candidate order are usually neighbours in the tree, so
  /// this grows outwards through the paragraphs around the match. Reading the
  /// whole corpus instead is how a "context" came back as the window's
  /// navigation, sidebar, and button labels with the selected word somewhere
  /// inside it.
  private static func expanded(around anchor: Int, in segments: [String]) -> String {
    var selected = [segments[anchor]]
    var length = segments[anchor].count
    var before = anchor - 1
    var after = anchor + 1

    while length < PromptBuilder.maximumSelectionContextLength,
      before >= 0 || after < segments.count
    {
      if before >= 0 {
        let segment = segments[before]
        selected.insert(segment, at: 0)
        length += segment.count + 1
        before -= 1
      }
      guard length < PromptBuilder.maximumSelectionContextLength else { break }
      if after < segments.count {
        let segment = segments[after]
        selected.append(segment)
        length += segment.count + 1
        after += 1
      }
    }
    return selected.joined(separator: " ")
  }

  static func normalize(_ value: String) -> String {
    PromptBuilder.normalizedWhitespace(value)
  }
}

struct SelectionEvidence: Equatable, Sendable {
  var text: String
  /// The accessibility read and the clipboard read describe the same
  /// selection.
  var accessibilityMatches: Bool
  /// They describe overlapping text — one contains the other. Weaker than a
  /// match, and enough to trust where on screen the selection is.
  var accessibilityOverlaps: Bool
}

/// The text a write-back puts into the source control. Pure, so the rules
/// that decide what ends up in the reader's document can be tested without
/// another application.
enum WriteBackComposer {
  static func clean(_ answer: String) -> String {
    answer.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Replace: the answer, wearing the whitespace the selection carried. A
  /// triple-clicked paragraph includes its line break, and a bare answer
  /// written over it would run the next paragraph into this one.
  static func replacement(for answer: String, over selection: String) -> String {
    leadingWhitespace(of: selection) + clean(answer) + trailingWhitespace(of: selection)
  }

  /// Where Insert writes an answer and what it writes there.
  struct Insertion: Equatable {
    var text: String
    /// How far from the selection's end the answer goes, in characters for
    /// the arrow keys: negative is back, positive forward.
    var characterOffset: Int
    /// The same distance in UTF-16 units, which accessibility offsets count.
    var utf16Offset: Int
  }

  /// Insert: the answer after `selection`, given the text that follows it in
  /// the document — nil when the control cannot say, empty at the very end.
  ///
  /// A selection that ends a line gets its answer as the next line, written
  /// *after* the line break and ending with one of its own. Writing it before
  /// the break with a leading one instead is what a rich-text editor turns
  /// into an empty paragraph above the answer. A selection with more text
  /// after it on the same line keeps that line flowing: the answer goes right
  /// after the selected words.
  static func insertion(of answer: String, after selection: String, followedBy next: String?) -> Insertion {
    let body = clean(answer)
    let trailing = trailingWhitespace(of: selection)
    if let newline = trailing.firstIndex(where: \.isNewline) {
      let beyond = String(trailing[trailing.index(after: newline)...])
      return Insertion(
        text: body + "\n",
        characterOffset: -beyond.count,
        utf16Offset: -(beyond as NSString).length
      )
    }
    if trailing.isEmpty, let following = next?.first, following.isNewline {
      return Insertion(
        text: body + "\n",
        characterOffset: 1,
        utf16Offset: (String(following) as NSString).length
      )
    }
    let continuesLine = !trailing.isEmpty || next?.isEmpty == false
    let separator = continuesLine
      ? (selection.contains(where: \.isNewline) || body.contains(where: \.isNewline) ? "\n" : " ")
      : separator(after: selection, answer: body)
    return Insertion(
      text: separator + body,
      characterOffset: -trailing.count,
      utf16Offset: -(trailing as NSString).length
    )
  }

  /// The separator when nothing is known about what follows the selection,
  /// or the selection ends the text. A word or a phrase gets its answer
  /// beside it. A sentence, a paragraph, or an answer that runs to several
  /// lines gets a line of its own, which is what a bilingual draft looks
  /// like. A selection holding a line break anywhere was made as a block —
  /// triple-clicked or dragged across lines — and counts as a paragraph.
  static func separator(after selection: String, answer: String) -> String {
    let core = selection.trimmingCharacters(in: .whitespacesAndNewlines)
    let endsSentence = core.last.map { ".!?。！？…".contains($0) } ?? false
    let isPassage = selection.contains(where: \.isNewline) || answer.contains(where: \.isNewline)
    return isPassage || endsSentence || core.count > 40 ? "\n" : " "
  }

  private static func leadingWhitespace(of text: String) -> String {
    String(text.prefix(while: \.isWhitespace))
  }

  private static func trailingWhitespace(of text: String) -> String {
    String(text.reversed().prefix(while: \.isWhitespace).reversed())
  }
}

/// Finds the key that types a character in the current keyboard layout, for
/// the shortcuts posted on the reader's behalf.
///
/// Applications match ⌘C and ⌘V by the character the key produces, so the
/// ANSI key codes alone are ⌘J and ⌘. on Dvorak. The layout is asked with
/// Command held, which is the state "Dvorak – QWERTY ⌘" switches on. A layout
/// with no such key — Cyrillic, Greek — keeps the ANSI position, which is
/// where macOS puts their Command shortcuts.
@MainActor
enum KeyboardLayoutKeys {
  static func keyCode(for character: Character, fallback: CGKeyCode) -> CGKeyCode {
    guard
      let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
      let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
    else { return fallback }
    let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
    guard let bytes = CFDataGetBytePtr(data) else { return fallback }
    let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
    let wanted = String(character).lowercased()
    let commandHeld = UInt32((cmdKey >> 8) & 0xFF)
    for code in 0..<128 {
      var deadKeyState: UInt32 = 0
      var length = 0
      var characters = [UniChar](repeating: 0, count: 4)
      let status = UCKeyTranslate(
        layout,
        UInt16(code),
        UInt16(kUCKeyActionDown),
        commandHeld,
        UInt32(LMGetKbdType()),
        OptionBits(kUCKeyTranslateNoDeadKeysMask),
        &deadKeyState,
        characters.count,
        &length,
        &characters
      )
      if status == noErr, length > 0,
        String(utf16CodeUnits: characters, count: length).lowercased() == wanted
      {
        return CGKeyCode(code)
      }
    }
    return fallback
  }
}

enum SelectionEvidenceResolver {
  static func resolve(accessibilityText: String, copiedText: String?) -> SelectionEvidence {
    let accessibility = accessibilityText.trimmingCharacters(in: .whitespacesAndNewlines)
    let copied = copiedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    guard !copied.isEmpty else {
      return SelectionEvidence(
        text: accessibility,
        accessibilityMatches: !accessibility.isEmpty,
        accessibilityOverlaps: !accessibility.isEmpty
      )
    }
    guard !accessibility.isEmpty else {
      return SelectionEvidence(
        text: copied,
        accessibilityMatches: false,
        accessibilityOverlaps: false
      )
    }

    let accessibilityKey = PromptBuilder.matchKey(accessibility)
    let copiedKey = PromptBuilder.matchKey(copied)
    let matches = accessibilityKey == copiedKey
    return SelectionEvidence(
      text: copied,
      accessibilityMatches: matches,
      accessibilityOverlaps: matches
        || copiedKey.contains(accessibilityKey)
        || accessibilityKey.contains(copiedKey)
    )
  }
}
