@preconcurrency import ApplicationServices
import AppKit
import Foundation

struct AccessibilityService: Sendable {
  private static let maximumCandidateCount = 800
  private static let maximumCandidateDepth = 12
  private static let maximumParentDepth = 12

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
    // The focused element is often only a container. Readers such as Apple
    // Books keep the actual WebArea and static text below that container, while
    // browsers and native editors may expose selection on the focused element
    // or one of its ancestors. Search the active window by capability instead
    // of assuming a particular application or accessibility-tree direction.
    let application = try applicationElement(for: processIdentifier)
    let sourceElement = try? focusedElement(in: application)
    if let sourceElement, isWithinSecureTextElement(sourceElement) {
      throw TranslationError.selectionUnavailable
    }
    let focusedWindow = uiElementAttribute(kAXFocusedWindowAttribute, from: application)
    let candidates = selectionCandidates(
      focusedElement: sourceElement,
      focusedWindow: focusedWindow
    )
    let accessibilitySnapshot = selectionSnapshot(from: candidates)
    let selectedText = accessibilitySnapshot?.text ?? ""
    // A broad content traversal is useful for finding context, but some readers
    // expose the same selection range on several static-text descendants. A
    // range from one paragraph can therefore produce a plausible substring in
    // another paragraph. When clipboard access is enabled, use Copy as the
    // selection anchor even when AX returned non-empty text; AX remains the
    // fallback for controls that cannot copy their selection.
    let copiedText =
      allowCopyFallback
      ? await copiedSelectionPreservingClipboard(from: processIdentifier)
      : nil
    let evidence = SelectionEvidenceResolver.resolve(
      accessibilityText: selectedText,
      copiedText: copiedText
    )
    let resolvedText = evidence.text
    let resolvedContext =
      (evidence.accessibilityMatches ? accessibilitySnapshot?.surroundingText : nil)
      ?? (resolvedText.isEmpty ? nil : surroundingText(matching: resolvedText, in: candidates))
    return SelectionSnapshot(
      text: resolvedText,
      surroundingText: resolvedContext,
      screenRect: evidence.accessibilityMatches ? accessibilitySnapshot?.screenRect : nil
    )
  }

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
    let savedItems: [NSPasteboardItem]
    if let currentItems = pasteboard.pasteboardItems {
      savedItems = currentItems.map { item in
        let copy = NSPasteboardItem()
        for type in item.types {
          if let data = item.data(forType: type) {
            copy.setData(data, forType: type)
          }
        }
        return copy
      }
    } else {
      savedItems = []
    }

    let clearedChangeCount = pasteboard.clearContents()
    defer {
      restorePasteboard(savedItems)
    }

    let eventSource = CGEventSource(stateID: .combinedSessionState)
    guard
      let keyDown = CGEvent(keyboardEventSource: eventSource, virtualKey: 8, keyDown: true),
      let keyUp = CGEvent(keyboardEventSource: eventSource, virtualKey: 8, keyDown: false)
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

  func currentEditableText() throws -> String {
    guard isTrusted() else {
      throw TranslationError.accessibilityPermissionRequired
    }
    let element = try focusedElement()
    guard !isWithinSecureTextElement(element) else {
      throw TranslationError.provider("Secure text fields cannot be translated or replaced.")
    }
    guard let value = stringAttribute(kAXValueAttribute, from: element), !value.isEmpty else {
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
      throw TranslationError.provider("Secure text fields cannot be translated or replaced.")
    }
    guard let value = stringAttribute(kAXValueAttribute, from: element) else {
      throw TranslationError.provider("The focused control is not editable.")
    }
    let range = selectedRange(from: element)
    let nextValue: String
    let cursorOffset: Int
    if let range, range.length > 0 {
      let nsValue = value as NSString
      guard range.location >= 0, range.location + range.length <= nsValue.length else {
        throw TranslationError.provider("The focused control returned an invalid selection.")
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

    var settable = DarwinBoolean(false)
    let settableStatus = AXUIElementIsAttributeSettable(
      element,
      kAXValueAttribute as CFString,
      &settable
    )
    guard settableStatus == .success, settable.boolValue else {
      throw TranslationError.provider("The focused control does not allow text replacement.")
    }
    let status = AXUIElementSetAttributeValue(
      element,
      kAXValueAttribute as CFString,
      nextValue as CFString
    )
    guard status == .success else {
      throw TranslationError.provider("Could not replace text in the focused control.")
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

  private func focusedElement() throws -> AXUIElement {
    try focusedElement(in: applicationElement(for: nil))
  }

  private func applicationElement(for processIdentifier: pid_t?) throws -> AXUIElement {
    if let processIdentifier {
      return AXUIElementCreateApplication(processIdentifier)
    }
    let systemWide = AXUIElementCreateSystemWide()
    var focusedApplication: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        systemWide,
        kAXFocusedApplicationAttribute as CFString,
        &focusedApplication
      ) == .success,
      let application = focusedApplication,
      CFGetTypeID(application) == AXUIElementGetTypeID()
    else {
      throw TranslationError.provider("No focused application is available.")
    }

    return unsafeDowncast(application, to: AXUIElement.self)
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
      throw TranslationError.provider("No focused text control is available.")
    }
    return unsafeDowncast(element, to: AXUIElement.self)
  }

  private func selectionCandidates(
    focusedElement: AXUIElement?,
    focusedWindow: AXUIElement?
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
        buckets: &candidateBuckets
      )
    }

    if let focusedWindow, candidates.count < Self.maximumCandidateCount {
      appendUnique(focusedWindow, to: &candidates, buckets: &candidateBuckets)
      appendDescendants(
        of: focusedWindow,
        to: &candidates,
        buckets: &candidateBuckets
      )
    }
    return candidates
  }

  private func appendDescendants(
    of root: AXUIElement,
    to candidates: inout [AXUIElement],
    buckets: inout [CFHashCode: [AXUIElement]]
  ) {
    var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
    var queueIndex = 0
    var traversalBuckets: [CFHashCode: [AXUIElement]] = [:]
    insertUnique(root, into: &traversalBuckets)

    while queueIndex < queue.count, candidates.count < Self.maximumCandidateCount {
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
        if candidates.count >= Self.maximumCandidateCount { break }
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
    switch stringAttribute(kAXRoleAttribute, from: element) {
    case kAXMenuBarRole, kAXMenuRole, kAXMenuItemRole, "AXSecureTextField":
      true
    default:
      false
    }
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

  private func uiElementAttribute(_ name: String, from element: AXUIElement) -> AXUIElement? {
    guard let value = attribute(name, from: element), CFGetTypeID(value) == AXUIElementGetTypeID()
    else {
      return nil
    }
    return unsafeDowncast(value, to: AXUIElement.self)
  }

  private func stringAttribute(_ name: String, from element: AXUIElement) -> String? {
    var result: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else {
      return nil
    }
    return result as? String
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

  private func selectionSnapshot(from candidates: [AXUIElement]) -> SelectionSnapshot? {
    var fallbackSnapshot: SelectionSnapshot?

    for element in candidates {
      if let snapshot = rangeSelectionSnapshot(from: element) {
        if hasUsefulContext(snapshot) { return snapshot }
        fallbackSnapshot = fallbackSnapshot ?? snapshot
      }
      if let snapshot = textMarkerSelectionSnapshot(from: element) {
        if hasUsefulContext(snapshot) { return snapshot }
        fallbackSnapshot = fallbackSnapshot ?? snapshot
      }
    }
    return fallbackSnapshot
  }

  private func rangeSelectionSnapshot(from element: AXUIElement) -> SelectionSnapshot? {
    let selectedAttribute =
      stringAttribute(kAXSelectedTextAttribute, from: element)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let range = selectedRange(from: element)
    let value = stringAttribute(kAXValueAttribute, from: element) ?? ""

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

  private func surroundingText(
    matching selectedText: String,
    in candidates: [AXUIElement]
  ) -> String? {
    let segments = candidates.compactMap(readableTextSegment)
    return SelectionContextMatcher.context(matching: selectedText, in: segments)
  }

  private func readableTextSegment(from element: AXUIElement) -> String? {
    switch stringAttribute(kAXRoleAttribute, from: element) {
    case kAXStaticTextRole, kAXTextAreaRole, kAXTextFieldRole, "AXHeading", "AXLink":
      break
    default:
      return nil
    }
    guard
      let value = stringAttribute(kAXValueAttribute, from: element)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
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

  private func hasUsefulContext(_ snapshot: SelectionSnapshot) -> Bool {
    guard
      let context = snapshot.surroundingText?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !context.isEmpty
    else {
      return false
    }
    return context != snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines)
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

enum SelectionContextMatcher {
  private static let maximumSearchCorpusLength = 100_000

  static func context(matching selection: String, in segments: [String]) -> String? {
    let normalizedSelection = normalize(selection)
    guard !normalizedSelection.isEmpty else { return nil }

    var normalizedSegments: [String] = []
    var corpusLength = 0
    for segment in segments {
      let normalized = normalize(segment)
      guard !normalized.isEmpty, normalizedSegments.last != normalized else { continue }
      let additionalLength = normalized.count + (normalizedSegments.isEmpty ? 0 : 1)
      guard corpusLength + additionalLength <= maximumSearchCorpusLength else { break }
      normalizedSegments.append(normalized)
      corpusLength += additionalLength
    }

    let corpus = normalizedSegments.joined(separator: " ")
    guard let selectionRange = uniqueRange(of: normalizedSelection, in: corpus) else { return nil }
    let matchedSelection = String(corpus[selectionRange])
    let context = PromptBuilder.boundedContext(corpus, around: matchedSelection)
    return PromptBuilder.hasMeaningfulContext(context, for: matchedSelection) ? context : nil
  }

  static func normalize(_ value: String) -> String {
    value
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func uniqueRange(of needle: String, in haystack: String) -> Range<String.Index>? {
    var match: Range<String.Index>?
    var searchStart = haystack.startIndex
    while searchStart < haystack.endIndex,
      let range = haystack.range(
        of: needle,
        options: [.caseInsensitive, .diacriticInsensitive],
        range: searchStart..<haystack.endIndex
      )
    {
      if match != nil { return nil }
      match = range
      searchStart = range.upperBound
    }
    return match
  }
}

struct SelectionEvidence: Equatable, Sendable {
  var text: String
  var accessibilityMatches: Bool
}

enum SelectionEvidenceResolver {
  static func resolve(accessibilityText: String, copiedText: String?) -> SelectionEvidence {
    let accessibility = accessibilityText.trimmingCharacters(in: .whitespacesAndNewlines)
    let copied = copiedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    guard !copied.isEmpty else {
      return SelectionEvidence(
        text: accessibility,
        accessibilityMatches: !accessibility.isEmpty
      )
    }

    return SelectionEvidence(
      text: copied,
      accessibilityMatches:
        !accessibility.isEmpty
        && SelectionContextMatcher.normalize(accessibility)
          == SelectionContextMatcher.normalize(copied)
    )
  }
}
