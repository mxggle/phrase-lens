@preconcurrency import Carbon
import AppKit
import Foundation

enum HotKeyAction: UInt32, CaseIterable, Sendable {
  case translateSelection = 1
  case showWindow = 2
  case screenshotOCR = 3
  case writing = 5
}

@MainActor
final class GlobalHotKeyManager {
  static let shared = GlobalHotKeyManager()

  private var handler: (@MainActor @Sendable (HotKeyAction, pid_t?) -> Void)?
  private var references: [EventHotKeyRef] = []
  private var eventHandler: EventHandlerRef?
  private let signature: OSType = 0x4E_41_54_49

  private init() {
    var specification = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed)
    )
    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, event, _ in
        guard let event else { return noErr }
        var identifier = EventHotKeyID()
        let status = GetEventParameter(
          event,
          EventParamName(kEventParamDirectObject),
          EventParamType(typeEventHotKeyID),
          nil,
          MemoryLayout<EventHotKeyID>.size,
          nil,
          &identifier
        )
        guard status == noErr,
          identifier.signature == GlobalHotKeyManager.shared.signature,
          let action = HotKeyAction(rawValue: identifier.id)
        else {
          return status
        }
        // Capture the source process before hopping to the main actor. The
        // translator can become active between this Carbon callback and the
        // asynchronous selection lookup, which otherwise makes us inspect our
        // own empty editor instead of the app where the shortcut was pressed.
        let sourceProcessIdentifier =
          NSWorkspace.shared.frontmostApplication?.processIdentifier
        Task { @MainActor in
          GlobalHotKeyManager.shared.handler?(action, sourceProcessIdentifier)
        }
        return noErr
      },
      1,
      &specification,
      nil,
      &eventHandler
    )
  }

  func register(
    shortcuts: ShortcutSettings,
    handler: @escaping @MainActor @Sendable (HotKeyAction, pid_t?) -> Void
  ) -> [String] {
    unregisterAll()
    self.handler = handler
    let definitions: [(HotKeyAction, String)] = [
      (.translateSelection, shortcuts.translateSelection),
      (.showWindow, shortcuts.showWindow),
      (.screenshotOCR, shortcuts.screenshotOCR),
      (.writing, shortcuts.writing),
    ]
    var errors: [String] = []
    for (action, shortcut) in definitions {
      do {
        try register(action: action, shortcut: shortcut)
      } catch {
        errors.append("\(shortcut): \(error.localizedDescription)")
      }
    }
    return errors
  }

  func unregisterAll() {
    references.forEach { UnregisterEventHotKey($0) }
    references.removeAll()
  }

  private func register(action: HotKeyAction, shortcut: String) throws {
    let parsed = try HotKeyParser.parse(shortcut)
    let identifier = EventHotKeyID(signature: signature, id: action.rawValue)
    var reference: EventHotKeyRef?
    let status = RegisterEventHotKey(
      parsed.keyCode,
      parsed.modifiers,
      identifier,
      GetApplicationEventTarget(),
      OptionBits(kEventHotKeyExclusive),
      &reference
    )
    guard status == noErr, let reference else {
      throw HotKeyError.registrationFailed(status)
    }
    references.append(reference)
  }
}

enum HotKeyParser {
  static func parse(_ displayValue: String) throws -> (keyCode: UInt32, modifiers: UInt32) {
    let value = displayValue.uppercased()
    var modifiers: UInt32 = 0
    if value.contains("⌘") { modifiers |= UInt32(cmdKey) }
    if value.contains("⌥") { modifiers |= UInt32(optionKey) }
    if value.contains("⌃") { modifiers |= UInt32(controlKey) }
    if value.contains("⇧") { modifiers |= UInt32(shiftKey) }

    let key = value.filter { !"⌘⌥⌃⇧ +".contains($0) }
    guard let keyCode = keyCodes[key] else {
      throw HotKeyError.unsupportedShortcut(displayValue)
    }
    return (keyCode, modifiers)
  }

  /// Reverse lookup for the shortcut recorder: the printed key for a hardware
  /// key code, independent of the modifiers held while pressing it.
  static func keyLabel(forKeyCode keyCode: UInt32) -> String? {
    keyCodes.first { $0.value == keyCode }?.key
  }

  private static let keyCodes: [String: UInt32] = [
    "A": 0, "S": 1, "D": 2, "F": 3, "H": 4, "G": 5, "Z": 6, "X": 7,
    "C": 8, "V": 9, "B": 11, "Q": 12, "W": 13, "E": 14, "R": 15,
    "Y": 16, "T": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
    "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
    "]": 30, "O": 31, "U": 32, "[": 33, "I": 34, "P": 35, "L": 37,
    "J": 38, "'": 39, "K": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
    "N": 45, "M": 46, ".": 47, "SPACE": 49,
  ]
}

enum HotKeyError: LocalizedError {
  case unsupportedShortcut(String)
  case registrationFailed(OSStatus)

  var errorDescription: String? {
    switch self {
    case .unsupportedShortcut(let value): "Unsupported shortcut \(value)"
    case .registrationFailed(let status): "Registration failed (\(status))"
    }
  }
}
