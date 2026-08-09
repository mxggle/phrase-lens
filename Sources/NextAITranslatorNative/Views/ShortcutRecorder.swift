import AppKit
import SwiftUI

/// A key-combination well, the control macOS uses wherever a global shortcut is
/// assigned. Typing the shortcut is the whole interaction: there is no text to
/// mistype, and only combinations the hot-key registrar accepts are stored.
struct ShortcutRecorder: View {
  @Binding var value: String
  var accessibilityTitle: String

  @State private var isRecording = false
  @State private var monitor: Any?
  @State private var rejection: String?

  var body: some View {
    HStack(spacing: AppSpacing.xs) {
      if let rejection {
        Text(rejection)
          .font(.caption)
          .foregroundStyle(.orange)
          .transition(.opacity)
      }

      Button {
        isRecording ? stopRecording() : startRecording()
      } label: {
        Text(displayValue)
          .font(.body.monospaced())
          .foregroundStyle(isRecording ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
          .frame(minWidth: 78)
      }
      .buttonStyle(.bordered)
      .help(isRecording ? "Press the key combination, or Escape to cancel" : "Click to record a shortcut")
      .accessibilityLabel("\(accessibilityTitle) shortcut")
      .accessibilityValue(value.isEmpty ? "None" : value)

      Button {
        value = ""
        stopRecording()
      } label: {
        Image(systemName: "xmark.circle.fill")
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.borderless)
      .disabled(value.isEmpty)
      .help("Remove this shortcut")
      .accessibilityLabel("Remove \(accessibilityTitle) shortcut")
    }
    .onDisappear { stopRecording() }
  }

  private var displayValue: String {
    if isRecording { return "Press keys…" }
    return value.isEmpty ? "None" : value
  }

  private func startRecording() {
    guard monitor == nil else { return }
    isRecording = true
    rejection = nil
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
      handle(event)
      return nil
    }
  }

  private func stopRecording() {
    if let monitor {
      NSEvent.removeMonitor(monitor)
      self.monitor = nil
    }
    isRecording = false
  }

  private func handle(_ event: NSEvent) {
    // Escape leaves the previous shortcut untouched.
    if event.keyCode == 53 {
      stopRecording()
      return
    }

    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard let key = HotKeyParser.keyLabel(forKeyCode: UInt32(event.keyCode)) else {
      reject("Unsupported key")
      return
    }

    var symbols = ""
    if flags.contains(.control) { symbols += "⌃" }
    if flags.contains(.option) { symbols += "⌥" }
    if flags.contains(.shift) { symbols += "⇧" }
    if flags.contains(.command) { symbols += "⌘" }

    // A global shortcut without ⌘, ⌥ or ⌃ would swallow ordinary typing.
    guard flags.contains(.command) || flags.contains(.option) || flags.contains(.control) else {
      reject("Add ⌘, ⌥ or ⌃")
      return
    }

    let candidate = symbols + key
    guard (try? HotKeyParser.parse(candidate)) != nil else {
      reject("Unsupported key")
      return
    }

    value = candidate
    rejection = nil
    stopRecording()
  }

  private func reject(_ message: String) {
    rejection = message
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(2))
      if rejection == message { rejection = nil }
    }
  }
}
