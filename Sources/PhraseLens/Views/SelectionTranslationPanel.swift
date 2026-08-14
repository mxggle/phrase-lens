import AppKit
import SwiftUI

private final class SelectionPopoverPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  override func cancelOperation(_: Any?) {
    Task { @MainActor in
      SelectionPanelCoordinator.shared.close()
    }
  }
}

@MainActor
final class SelectionPanelCoordinator {
  static let shared = SelectionPanelCoordinator()

  /// The height covers the action tab strip on top of what the panel showed
  /// before it, so adding the strip did not come out of the result area.
  private let contentSize = CGSize(width: 480, height: 440)
  private var panel: SelectionPopoverPanel?
  private var outsideClickMonitor: Any?
  private var escapeKeyMonitor: Any?
  private var resignObserver: NSObjectProtocol?
  private var deactivateObserver: NSObjectProtocol?
  private var moveObserver: NSObjectProtocol?
  private weak var settingsStore: SettingsStore?

  private init() {}

  func show(model: AppModel) {
    close()

    let rootView = SelectionTranslationPanelView()
      .environmentObject(model)
      .environmentObject(model.settingsStore)
      .frame(width: contentSize.width, height: contentSize.height)
    let hostingController = NSHostingController(rootView: rootView)
    let panel = SelectionPopoverPanel(
      contentRect: NSRect(origin: .zero, size: contentSize),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.contentViewController = hostingController
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.setAccessibilityRole(NSAccessibility.Role.window)
    panel.setAccessibilitySubrole(NSAccessibility.Subrole.floatingWindow)
    panel.setAccessibilityLabel("Selection translation")
    panel.isMovableByWindowBackground = true
    panel.isReleasedWhenClosed = false
    panel.isFloatingPanel = true
    panel.becomesKeyOnlyIfNeeded = false
    panel.hidesOnDeactivate = false
    panel.level = .floating
    panel.animationBehavior = .utilityWindow
    panel.collectionBehavior = [
      .canJoinAllSpaces,
      .fullScreenAuxiliary,
      .transient,
      .ignoresCycle,
    ]

    let settings = model.settingsStore.settings
    let pointer = NSEvent.mouseLocation
    let targetFrame: NSRect
    switch settings.selectionPanelPlacement {
    case .nearPointer:
      let visibleFrame = Self.screen(containing: pointer)?.visibleFrame ?? Self.fallbackVisibleFrame
      targetFrame = SelectionPanelGeometry.frameNearPointer(
        size: contentSize,
        pointer: pointer,
        visibleFrame: visibleFrame
      )
    case .fixed:
      if let remembered = settings.selectionPanelPosition {
        let origin = CGPoint(x: remembered.x, y: remembered.y)
        let intendedFrame = NSRect(origin: origin, size: contentSize)
        let visibleFrame = Self.screen(intersecting: intendedFrame)?.visibleFrame
          ?? NSScreen.main?.visibleFrame
          ?? Self.fallbackVisibleFrame
        targetFrame = SelectionPanelGeometry.frameAtRememberedOrigin(
          size: contentSize,
          origin: origin,
          visibleFrame: visibleFrame
        )
      } else {
        let visibleFrame = Self.screen(containing: pointer)?.visibleFrame ?? Self.fallbackVisibleFrame
        targetFrame = SelectionPanelGeometry.frameNearPointer(
          size: contentSize,
          pointer: pointer,
          visibleFrame: visibleFrame
        )
      }
    }
    panel.setFrame(targetFrame, display: false)
    self.panel = panel
    settingsStore = model.settingsStore
    rememberCurrentPosition()
    installDismissalObservers(for: panel)

    NSApp.setActivationPolicy(settings.showDockIcon ? .regular : .accessory)
    panel.makeKeyAndOrderFront(nil)
  }

  func close() {
    if let outsideClickMonitor {
      NSEvent.removeMonitor(outsideClickMonitor)
      self.outsideClickMonitor = nil
    }
    if let escapeKeyMonitor {
      NSEvent.removeMonitor(escapeKeyMonitor)
      self.escapeKeyMonitor = nil
    }
    if let resignObserver {
      NotificationCenter.default.removeObserver(resignObserver)
      self.resignObserver = nil
    }
    if let deactivateObserver {
      NotificationCenter.default.removeObserver(deactivateObserver)
      self.deactivateObserver = nil
    }
    if let moveObserver {
      NotificationCenter.default.removeObserver(moveObserver)
      self.moveObserver = nil
    }
    panel?.orderOut(nil)
    panel?.contentViewController = nil
    panel = nil
    settingsStore = nil
  }

  private func installDismissalObservers(for panel: NSPanel) {
    outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown]
    ) { _ in
      Task { @MainActor in
        SelectionPanelCoordinator.shared.close()
      }
    }
    escapeKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
      guard event.keyCode == 53 else { return }
      Task { @MainActor in
        SelectionPanelCoordinator.shared.close()
      }
    }
    resignObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didResignKeyNotification,
      object: panel,
      queue: .main
    ) { _ in
      Task { @MainActor in
        SelectionPanelCoordinator.shared.close()
      }
    }
    deactivateObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didResignActiveNotification,
      object: NSApp,
      queue: .main
    ) { _ in
      Task { @MainActor in
        SelectionPanelCoordinator.shared.close()
      }
    }
    moveObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didMoveNotification,
      object: panel,
      queue: .main
    ) { _ in
      Task { @MainActor in
        SelectionPanelCoordinator.shared.rememberCurrentPosition()
      }
    }
  }

  private func rememberCurrentPosition() {
    guard let origin = panel?.frame.origin, let settingsStore else { return }
    let position = SelectionPanelPosition(x: origin.x, y: origin.y)
    guard settingsStore.settings.selectionPanelPosition != position else { return }
    settingsStore.settings.selectionPanelPosition = position
  }

  private static func screen(containing point: CGPoint) -> NSScreen? {
    NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
  }

  private static func screen(intersecting frame: CGRect) -> NSScreen? {
    NSScreen.screens.max { first, second in
      first.visibleFrame.intersection(frame).area < second.visibleFrame.intersection(frame).area
    }.flatMap { $0.visibleFrame.intersects(frame) ? $0 : nil }
  }

  private static var fallbackVisibleFrame: CGRect {
    NSScreen.main?.visibleFrame
      ?? CGRect(origin: .zero, size: CGSize(width: 480, height: 440))
  }
}

enum SelectionPanelGeometry {
  private static let gap: CGFloat = 12
  private static let inset: CGFloat = 10

  static func frameNearPointer(size: CGSize, pointer: CGPoint, visibleFrame: CGRect) -> CGRect {
    var x = pointer.x + gap
    if x + size.width > visibleFrame.maxX - inset {
      x = pointer.x - size.width - gap
    }

    // Prefer below the pointer in screen-reading order, then flip above it.
    var y = pointer.y - size.height - gap
    if y < visibleFrame.minY + inset {
      y = pointer.y + gap
    }
    return clampedFrame(size: size, origin: CGPoint(x: x, y: y), visibleFrame: visibleFrame)
  }

  static func frameAtRememberedOrigin(
    size: CGSize,
    origin: CGPoint,
    visibleFrame: CGRect
  ) -> CGRect {
    clampedFrame(size: size, origin: origin, visibleFrame: visibleFrame)
  }

  private static func clampedFrame(
    size: CGSize,
    origin: CGPoint,
    visibleFrame: CGRect
  ) -> CGRect {
    let minX = visibleFrame.minX + inset
    let minY = visibleFrame.minY + inset
    let maxX = max(minX, visibleFrame.maxX - size.width - inset)
    let maxY = max(minY, visibleFrame.maxY - size.height - inset)
    return CGRect(
      origin: CGPoint(
        x: min(max(origin.x, minX), maxX),
        y: min(max(origin.y, minY), maxY)
      ),
      size: size
    )
  }
}

private extension CGRect {
  var area: CGFloat {
    guard !isNull, !isInfinite else { return 0 }
    return width * height
  }
}

private struct SelectionTranslationPanelView: View {
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var settingsStore: SettingsStore

  var body: some View {
    ThemedContainer {
      SelectionPanelBody()
    }
    .preferredColorScheme(settingsStore.settings.theme.preferredColorScheme)
  }
}

/// Split from the panel root so it can read the palette that
/// `ThemedContainer` publishes for the panel's own appearance.
private struct SelectionPanelBody: View {
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var settingsStore: SettingsStore
  @Environment(\.palette) private var palette
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var didCopy = false
  @State private var copyResetTask: Task<Void, Never>?

  var body: some View {
    VStack(spacing: 0) {
      header
      Hairline()
      VStack(spacing: AppSpacing.sm) {
        ActionTabBar(
          actions: model.visibleActions,
          selection: actionSelection,
          size: .compact
        )
        sourceSummary
      }
      .padding(.horizontal, AppSpacing.md)
      .padding(.top, AppSpacing.sm + 2)
      .padding(.bottom, AppSpacing.sm)
      Hairline()
      result
      Hairline()
      footer
    }
    .floatingPanelBackground(palette)
    .onExitCommand {
      SelectionPanelCoordinator.shared.close()
    }
    .animation(AppMotion.state(reduceMotion: reduceMotion), value: model.outputText.isEmpty)
    .animation(AppMotion.state(reduceMotion: reduceMotion), value: model.isTranslating)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Selection translation")
  }

  // MARK: - Header

  /// One line of chrome: what this window is, whether it is working, and how
  /// to dismiss it. Everything else is a command and belongs in the footer.
  private var header: some View {
    HStack(spacing: AppSpacing.sm) {
      AppLogo(size: 20)

      Text("Selection")
        .font(AppFont.bodyMedium)
        .foregroundStyle(palette.foreground)

      Spacer(minLength: AppSpacing.sm)

      if model.isTranslating {
        Spinner(size: 12)
      }

      IconButton(title: "Close (Escape)", symbol: "xmark", size: .iconSmall) {
        SelectionPanelCoordinator.shared.close()
      }
    }
    .padding(.horizontal, AppSpacing.md)
    .frame(height: AppMetrics.paneHeaderHeight)
  }

  // MARK: - Action

  /// Switching the action re-runs the pop-up on the text it already captured,
  /// which is the whole point of picking a different one here — the same
  /// contract the target-language menu in the footer follows.
  private var actionSelection: Binding<UUID> {
    Binding(
      get: { model.selectedActionID },
      set: { id in
        guard id != model.selectedActionID else { return }
        model.selectedActionID = id
        if !model.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          model.translate()
        }
      }
    )
  }

  // MARK: - Captured text

  private var sourceSummary: some View {
    HStack(alignment: .top, spacing: AppSpacing.sm) {
      Image(systemName: "quote.opening")
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(palette.faintForeground)
        .padding(.top, 2)
        .accessibilityHidden(true)
      Text(model.inputText.isEmpty ? "Nothing was selected" : model.inputText)
        .font(AppFont.body)
        .foregroundStyle(
          model.inputText.isEmpty ? palette.faintForeground : palette.secondaryForeground
        )
        .lineLimit(2)
        .textSelection(.enabled)
      Spacer(minLength: 0)
    }
    .padding(AppSpacing.sm)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(palette.muted, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
  }

  // MARK: - Result

  /// The result takes every point the panel has left. A fixed height clipped
  /// generated text mid-line, which read as a rendering fault.
  @ViewBuilder
  private var result: some View {
    Group {
      if model.isAccessibilityPermissionError {
        accessibilityPermissionMessage
      } else if let error = model.errorMessage {
        message(error, symbol: "exclamationmark.triangle.fill", tint: palette.warning)
      } else if model.outputText.isEmpty, model.isTranslating {
        message("Translating…", symbol: "ellipsis", tint: palette.mutedForeground)
      } else if model.outputText.isEmpty {
        VStack(spacing: AppSpacing.md) {
          Text("Ready to translate")
            .font(AppFont.body)
            .foregroundStyle(palette.mutedForeground)
          Button("Translate") {
            model.translate()
          }
          .appButton(.primary, size: .sm)
          .keyboardShortcut(.return, modifiers: [.command])
          .disabled(model.inputText.isEmpty)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          Group {
            if model.outputUsesMarkdown || MarkdownParser.looksLikeMarkdown(model.outputText) {
              MarkdownText(model.outputText, baseFontSize: settingsStore.settings.fontSize)
            } else {
              Text(model.outputText)
                .font(.system(size: settingsStore.settings.fontSize))
                .lineSpacing(3)
                .textSelection(.enabled)
            }
          }
          .frame(maxWidth: .infinity, alignment: .topLeading)
          .padding(.horizontal, AppSpacing.md)
          .padding(.vertical, AppSpacing.md - 2)
        }
        .scrollBounceBehavior(.basedOnSize)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private var accessibilityPermissionMessage: some View {
    VStack(alignment: .leading, spacing: AppSpacing.md) {
      Label(
        "PhraseLens needs Accessibility access to read selected text.",
        systemImage: "exclamationmark.triangle.fill"
      )
      .font(AppFont.body)
      .foregroundStyle(palette.warning)

      Button("Open Accessibility Settings") {
        model.openAccessibilitySettings()
      }
      .appButton(.secondary, size: .sm)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, AppSpacing.md)
    .padding(.vertical, AppSpacing.md - 2)
  }

  private func message(_ text: String, symbol: String, tint: Color) -> some View {
    Label(text, systemImage: symbol)
      .font(AppFont.body)
      .foregroundStyle(tint)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, AppSpacing.md)
      .padding(.vertical, AppSpacing.md - 2)
  }

  // MARK: - Footer

  private var footer: some View {
    HStack(spacing: AppSpacing.xs) {
      AppSelect(
        title: "Target language",
        selection: Binding(
          get: { settingsStore.settings.targetLanguage },
          set: { language in
            guard language != settingsStore.settings.targetLanguage else { return }
            settingsStore.settings.targetLanguage = language
            if !model.inputText.isEmpty {
              model.translate()
            }
          }
        ),
        options: model.visibleTargetLanguages,
        label: { $0.displayName },
        size: .sm
      )

      Spacer(minLength: AppSpacing.xs)

      IconButton(
        title: isCurrentTextCollected
          ? "Saved in Vocabulary"
          : "Save selected word or phrase to Vocabulary",
        symbol: isCurrentTextCollected ? "bookmark.fill" : "bookmark",
        isDisabled: !canCollectCurrentText,
        isOn: isCurrentTextCollected
      ) {
        model.collectCurrentWord()
      }

      IconButton(
        title: model.speech.isSpeaking ? "Stop speaking" : "Speak selected text",
        symbol: model.speech.isSpeaking ? "speaker.slash.fill" : "speaker.wave.2",
        isDisabled: model.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ) {
        model.speakInput()
      }

      IconButton(title: "Open the full translator window", symbol: "macwindow") {
        WindowCoordinator.showMain()
      }

      Button {
        model.copyOutput()
        didCopy = true
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor in
          try? await Task.sleep(for: .seconds(1.6))
          guard !Task.isCancelled else { return }
          didCopy = false
        }
      } label: {
        HStack(spacing: AppSpacing.xs + 1) {
          Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
            .font(.system(size: 11, weight: .medium))
            .contentTransition(.symbolEffect(.replace))
          Text(didCopy ? "Copied" : "Copy")
        }
      }
      .appButton(.primary, size: .sm)
      .symbolEffect(.bounce, value: didCopy)
      .disabled(model.outputText.isEmpty)
      .help("Copy the translation")
      .accessibilityLabel(didCopy ? "Copied" : "Copy the translation")
    }
    .padding(.horizontal, AppSpacing.md)
    .frame(height: AppMetrics.paneFooterHeight + 6)
    .background(palette.chrome)
  }

  private var normalizedInputText: String {
    model.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var canCollectCurrentText: Bool {
    !normalizedInputText.isEmpty
      && !model.outputText.isEmpty
      && normalizedInputText.count <= 80
  }

  private var isCurrentTextCollected: Bool {
    guard !normalizedInputText.isEmpty else { return false }
    return model.vocabulary.contains {
      $0.word.localizedCaseInsensitiveCompare(normalizedInputText) == .orderedSame
    }
  }
}
