import AppKit
import SwiftUI

/// Owns the single armed recorder in the process. An armed well consumes every
/// key-down the app receives, so two of them would both steal typing from the
/// rest of Settings and write one key press into two rows at once.
@MainActor
final class ShortcutRecordingSession: ObservableObject {
  static let shared = ShortcutRecordingSession()

  @Published private(set) var activeRecorder: UUID?
  private var keyMonitor: Any?
  private var dismissMonitor: Any?

  func begin(_ recorder: UUID, onKeyDown: @escaping (NSEvent) -> Void) {
    end()
    activeRecorder = recorder
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
      onKeyDown(event)
      return nil
    }
    // A click elsewhere means the user moved on. Without this the well keeps
    // eating the keystrokes meant for whatever field they clicked into, and the
    // click still has to reach that field, so the event passes through.
    dismissMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
    ) { [weak self] event in
      self?.end(recorder)
      return event
    }
  }

  /// Ending is addressed to one recorder, so a late stop from a row that has
  /// already lost its turn cannot disarm the row that took over.
  func end(_ recorder: UUID? = nil) {
    if let recorder, activeRecorder != recorder { return }
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    if let dismissMonitor { NSEvent.removeMonitor(dismissMonitor) }
    keyMonitor = nil
    dismissMonitor = nil
    activeRecorder = nil
  }
}

/// A key-combination well, the control macOS uses wherever a global shortcut is
/// assigned. Typing the shortcut is the whole interaction: there is no text to
/// mistype, and only combinations the hot-key registrar accepts are stored.
struct ShortcutRecorder: View {
  @Binding var value: String
  var accessibilityTitle: String

  @Environment(\.palette) private var palette
  @ObservedObject private var session = ShortcutRecordingSession.shared
  @State private var recorderID = UUID()
  @State private var rejection: String?
  @FocusState private var isFocused: Bool

  private var isRecording: Bool { session.activeRecorder == recorderID }

  var body: some View {
    HStack(spacing: AppSpacing.sm) {
      if let rejection {
        Text(rejection)
          .font(AppFont.caption)
          .foregroundStyle(palette.warning)
          .transition(.opacity)
      }

      Button {
        startRecording()
      } label: {
        Group {
          if isRecording {
            Text("Press keys…")
              .font(AppFont.label)
              .foregroundStyle(palette.mutedForeground)
          } else if value.isEmpty {
            Text("None")
              .font(AppFont.label)
              .foregroundStyle(palette.mutedForeground)
          } else {
            KeyCombo(combination: value, size: 11)
          }
        }
        .frame(minWidth: 86)
      }
      .appButton(isRecording ? .secondary : .outline, size: .sm)
      .focused($isFocused)
      .help(
        isRecording
          ? "Press the key combination, or Escape to cancel"
          : "Click to record a shortcut"
      )
      .accessibilityLabel("\(accessibilityTitle) shortcut")
      .accessibilityValue(value.isEmpty ? "None" : value)

      IconButton(
        title: "Remove \(accessibilityTitle) shortcut",
        symbol: "xmark",
        isDisabled: value.isEmpty
      ) {
        value = ""
        stopRecording()
      }
    }
    .onChange(of: isFocused) { _, focused in
      if !focused { stopRecording() }
    }
    // Covers the app being deactivated as well: the key window resigns first.
    .onReceive(
      NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)
    ) { _ in
      stopRecording()
    }
    .onDisappear { stopRecording() }
  }

  private func startRecording() {
    rejection = nil
    session.begin(recorderID) { event in handle(event) }
  }

  private func stopRecording() {
    session.end(recorderID)
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

    // Caught here the clash has a name; left to Carbon it would come back as a
    // bare OSStatus, and only after the shortcut was already stored.
    if let owner = GlobalHotKeyManager.shared.conflictingAction(for: candidate, ignoring: value) {
      reject("Already used by \(owner.displayName)")
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
