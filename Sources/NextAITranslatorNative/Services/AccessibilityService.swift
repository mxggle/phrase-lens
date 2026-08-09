@preconcurrency import ApplicationServices
import AppKit
import Foundation

struct AccessibilityService: Sendable {
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
    // Static text selections in browsers and WebKit-based apps do not always
    // expose kAXFocusedUIElementAttribute. Treat AX lookup as the preferred
    // path, not a prerequisite: the guarded Command-C fallback can still read
    // the user's selection from the source application in that case.
    let sourceElement = try? focusedElement(in: processIdentifier)
    let accessibilitySnapshot = sourceElement.flatMap(selectionSnapshot)
    let selectedText = accessibilitySnapshot?.text ?? ""
    let fallbackText =
      selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && allowCopyFallback
      ? await copiedSelectionPreservingClipboard(from: processIdentifier)
      : nil
    let resolvedText = fallbackText ?? selectedText
    let resolvedContext =
      accessibilitySnapshot?.surroundingText
      ?? fallbackText.flatMap { copiedText in
        sourceElement.flatMap {
          surroundingText(matching: copiedText, from: $0)
        }
      }
    return SelectionSnapshot(
      text: resolvedText,
      surroundingText: resolvedContext,
      screenRect: accessibilitySnapshot?.screenRect
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

    return try focusedElement(
      in: unsafeDowncast(application, to: AXUIElement.self)
    )
  }

  private func focusedElement(in processIdentifier: pid_t?) throws -> AXUIElement {
    guard let processIdentifier else {
      return try focusedElement()
    }
    return try focusedElement(
      in: AXUIElementCreateApplication(processIdentifier)
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
      throw TranslationError.provider("No focused text control is available.")
    }
    return unsafeDowncast(element, to: AXUIElement.self)
  }

  private func stringAttribute(_ name: String, from element: AXUIElement) -> String? {
    var result: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else {
      return nil
    }
    return result as? String
  }

  private func selectedRange(from element: AXUIElement) -> CFRange? {
    var result: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        element,
        kAXSelectedTextRangeAttribute as CFString,
        &result
      ) == .success,
      let value = result,
      CFGetTypeID(value) == AXValueGetTypeID()
    else {
      return nil
    }
    let axValue = unsafeDowncast(value, to: AXValue.self)
    guard AXValueGetType(axValue) == .cfRange else { return nil }
    var range = CFRange()
    guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
    return range
  }

  private func selectionSnapshot(from focusedElement: AXUIElement) -> SelectionSnapshot? {
    var element: AXUIElement? = focusedElement
    var fallbackSnapshot: SelectionSnapshot?

    // Browser content commonly exposes selection through an AXWebArea ancestor rather
    // than through the focused leaf. Walk only upward so unrelated page text cannot be
    // mistaken for the user's selection.
    for _ in 0..<8 {
      guard let current = element else { break }
      if let snapshot = rangeSelectionSnapshot(from: current) {
        if hasUsefulContext(snapshot) { return snapshot }
        fallbackSnapshot = fallbackSnapshot ?? snapshot
      }
      if let snapshot = textMarkerSelectionSnapshot(from: current) {
        if hasUsefulContext(snapshot) { return snapshot }
        fallbackSnapshot = fallbackSnapshot ?? snapshot
      }
      element = parent(of: current)
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
      selectedText = substring(value, range: range)
    } else {
      return nil
    }

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
        let text = parameterizedString(
          "AXStringForRange",
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

  private func surroundingText(
    matching selectedText: String,
    from focusedElement: AXUIElement
  ) -> String? {
    var element: AXUIElement? = focusedElement
    for _ in 0..<8 {
      guard let current = element else { break }
      if let value = stringAttribute(kAXValueAttribute, from: current),
        value.range(of: selectedText, options: [.caseInsensitive, .diacriticInsensitive]) != nil
      {
        return PromptBuilder.boundedContext(value, around: selectedText)
      }
      element = parent(of: current)
    }
    return nil
  }

  private func textMarkerSelectionSnapshot(from element: AXUIElement) -> SelectionSnapshot? {
    guard
      let selectedMarkerRange = attribute("AXSelectedTextMarkerRange", from: element),
      CFGetTypeID(selectedMarkerRange) == AXTextMarkerRangeGetTypeID()
    else {
      return nil
    }

    let selectedText =
      parameterizedString(
        "AXStringForTextMarkerRange",
        parameter: selectedMarkerRange,
        from: element
      )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !selectedText.isEmpty else { return nil }

    let markerRange = unsafeDowncast(selectedMarkerRange, to: AXTextMarkerRange.self)
    let selectedStart = AXTextMarkerRangeCopyStartMarker(markerRange)
    let selectedEnd = AXTextMarkerRangeCopyEndMarker(markerRange)
    let contextStart =
      parameterizedTextMarker(
        "AXPreviousParagraphStartTextMarkerForTextMarker",
        parameter: selectedStart,
        from: element
      ) ?? selectedStart
    let contextEnd =
      parameterizedTextMarker(
        "AXNextParagraphEndTextMarkerForTextMarker",
        parameter: selectedEnd,
        from: element
      ) ?? selectedEnd
    let contextRange = AXTextMarkerRangeCreate(nil, contextStart, contextEnd)
    let context =
      parameterizedString(
        "AXStringForTextMarkerRange",
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
      "AXBoundsForTextMarkerRange",
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

  private func parameterizedString(
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
    return result as? String
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
