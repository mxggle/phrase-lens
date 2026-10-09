#if DEBUG
import AppKit

/// Drives the real capture and write-back code against a running app from a
/// shell, so the route each kind of control takes can be checked without a
/// provider or the pop-up. Debug builds only.
///
///     PhraseLens --write-back-probe <pid> <replace|after> <text>
@MainActor
enum WriteBackProbe {
  static func run(arguments: [String]) async -> Int32 {
    guard
      let index = arguments.firstIndex(of: "--write-back-probe"),
      arguments.count > index + 3,
      let processIdentifier = pid_t(arguments[index + 1])
    else {
      print("usage: --write-back-probe <pid> <replace|after> <text>")
      return 2
    }
    let placement: InsertionPlacement = arguments[index + 2] == "after" ? .after : .replace
    let text = arguments[index + 3]
    let service = AccessibilityService()
    do {
      let snapshot = try await service.currentSelection(from: processIdentifier, allowCopyFallback: false)
      print("PROBE selection=\(snapshot.text.debugDescription) role=\(snapshot.diagnostics?.focusedRole ?? "nil")")
      // The app never offers a write for an empty capture; neither does this.
      guard !snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        print("PROBE selection is empty")
        return 1
      }
      guard let target = service.insertionTarget(for: processIdentifier, selectedText: snapshot.text) else {
        print("PROBE target=nil")
        return 1
      }
      let range = target.selectedRange.map { "\($0.location),\($0.length)" } ?? "nil"
      print("PROBE target app=\(target.applicationName ?? "?") editable=\(target.isEditable) web=\(target.isWebContent) range=\(range)")
      guard target.isEditable else { return 0 }
      let method = try await service.write(text, placement: placement, into: target)
      print("PROBE method=\(method)")
      try? await Task.sleep(for: .milliseconds(300))
      print("PROBE value=\(service.debugValue(of: target)?.debugDescription ?? "nil")")
      return 0
    } catch {
      print("PROBE error=\(error.localizedDescription)")
      return 1
    }
  }
}
#endif
