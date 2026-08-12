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

  private init() {}

  func show(model: AppModel, anchorScreenRect: CGRect? = nil) {
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

    let anchor =
      anchorScreenRect.flatMap(Self.appKitScreenRect(from:))
      ?? NSRect(origin: NSEvent.mouseLocation, size: .zero)
    panel.setFrame(Self.frame(for: contentSize, near: anchor), display: false)
    self.panel = panel
    installDismissalObservers(for: panel)

    let settings = model.settingsStore.settings
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
    panel?.orderOut(nil)
    panel?.contentViewController = nil
    panel = nil
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
  }

  private static func frame(for size: CGSize, near anchor: NSRect) -> NSRect {
    let screen =
      NSScreen.screens.first(where: { $0.frame.intersects(anchor) })
      ?? NSScreen.screens.first(where: { $0.frame.contains(anchor.origin) })
      ?? NSScreen.main
    let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: size.width, height: size.height)
    let gap: CGFloat = 12
    let horizontalInset: CGFloat = 10
    let verticalInset: CGFloat = 10

    var x = anchor.midX - size.width / 2
    var y = anchor.maxY + gap
    if y + size.height > visible.maxY - verticalInset {
      y = anchor.minY - size.height - gap
    }
    if y < visible.minY + verticalInset {
      y = min(
        max(anchor.midY - size.height / 2, visible.minY + verticalInset),
        visible.maxY - size.height - verticalInset)
    }
    x = min(max(x, visible.minX + horizontalInset), visible.maxX - size.width - horizontalInset)
    return NSRect(origin: CGPoint(x: x, y: y), size: size)
  }

  /// Accessibility rectangles use the Core Graphics top-left coordinate system.
  /// Convert within the matching display so multi-monitor placement stays correct.
  private static func appKitScreenRect(from accessibilityRect: CGRect) -> CGRect? {
    for screen in NSScreen.screens {
      guard
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
          as? NSNumber
      else { continue }
      let displayBounds = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
      guard displayBounds.intersects(accessibilityRect) else { continue }
      return CGRect(
        x: screen.frame.minX + accessibilityRect.minX - displayBounds.minX,
        y: screen.frame.maxY - (accessibilityRect.maxY - displayBounds.minY),
        width: accessibilityRect.width,
        height: accessibilityRect.height
      )
    }
    return nil
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
      RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
        .fill(palette.primary)
        .frame(width: 20, height: 20)
        .overlay {
          Image(systemName: "character.bubble.fill")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(palette.primaryForeground)
        }
        .accessibilityHidden(true)

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
      if let error = model.errorMessage {
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
}
