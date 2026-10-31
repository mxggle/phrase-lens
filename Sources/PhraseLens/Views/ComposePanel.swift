import AppKit
import SwiftUI

private final class ComposePanelWindow: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  override func cancelOperation(_: Any?) {
    Task { @MainActor in
      ComposePanelCoordinator.shared.dismissFromOutside()
    }
  }
}

/// The writing shortcut's pop-up window.
///
/// A non-activating panel, like the selection pop-up: it takes the keyboard
/// while it is open, but the app being written in stays the active one, so
/// closing the panel hands its field the keyboard straight back.
@MainActor
final class ComposePanelCoordinator {
  static let shared = ComposePanelCoordinator()

  static let contentSize = CGSize(width: 460, height: 360)
  /// Only a reason there is nothing to translate, and a way out.
  static let noticeSize = CGSize(width: 380, height: 140)

  private var panel: ComposePanelWindow?
  private weak var model: ComposeModel?
  private var outsideClickMonitor: Any?
  private var resignObserver: NSObjectProtocol?

  private init() {}

  var isVisible: Bool { panel != nil }

  /// Opens the pop-up beside `anchor`, the control the draft was read from,
  /// or by the pointer when there is none.
  func show(model: ComposeModel, anchor: CGRect?) {
    close(animated: false)

    let size = model.hasDraft ? Self.contentSize : Self.noticeSize
    let rootView = ComposePanelView()
      .environmentObject(model)
      .environmentObject(model.settingsStore)
      .frame(width: size.width, height: size.height)
    let panel = ComposePanelWindow(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.contentViewController = NSHostingController(rootView: rootView)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.setAccessibilityRole(NSAccessibility.Role.window)
    panel.setAccessibilitySubrole(NSAccessibility.Subrole.floatingWindow)
    panel.setAccessibilityLabel(ComposePanelBody.title)
    panel.isMovableByWindowBackground = false
    panel.isReleasedWhenClosed = false
    panel.isFloatingPanel = true
    panel.becomesKeyOnlyIfNeeded = false
    panel.hidesOnDeactivate = false
    panel.level = .floating
    panel.animationBehavior = .none
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

    let pointer = NSEvent.mouseLocation
    let reference = anchor ?? CGRect(origin: pointer, size: .zero)
    let centre = CGPoint(x: reference.midX, y: reference.midY)
    let visibleFrame =
      (NSScreen.screens.first { NSMouseInRect(centre, $0.frame, false) } ?? NSScreen.main)?.visibleFrame
      ?? CGRect(origin: .zero, size: size)
    let frame = ComposePanelGeometry.frame(size: size, anchor: reference, visibleFrame: visibleFrame)
    panel.setFrame(frame, display: false)

    self.panel = panel
    self.model = model
    installDismissalObservers(for: panel)
    NSApp.setActivationPolicy(model.settingsStore.settings.showDockIcon ? .regular : .accessory)
    present(
      panel,
      growingFrom: PanelMotion.anchor(
        panelFrame: frame,
        pointer: CGPoint(x: reference.minX, y: reference.midY),
        followsPointer: true
      )
    )
  }

  /// Takes the pop-up down. What it was showing is the model's business:
  /// writing the translation closes it too, and must not cancel anything.
  func close(animated: Bool = true) {
    removeDismissalObservers()
    model = nil
    guard let panel else { return }
    self.panel = nil
    guard animated, !PanelMotion.prefersReducedMotion else {
      panel.orderOut(nil)
      panel.contentViewController = nil
      return
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = PanelMotion.closeDuration
      context.timingFunction = CAMediaTimingFunction(name: .easeIn)
      panel.animator().alphaValue = 0
    }
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(PanelMotion.closeDuration))
      panel.orderOut(nil)
      panel.contentViewController = nil
    }
  }

  /// A click elsewhere, Escape, or another window taking the keyboard.
  func dismissFromOutside() {
    if let model {
      model.cancel()
    } else {
      close()
    }
  }

  /// The same entrance as the selection pop-up: drawn before it is visible,
  /// then grown from the side of the control it belongs to.
  private func present(_ panel: ComposePanelWindow, growingFrom anchor: CGPoint) {
    let content = panel.contentView
    content?.wantsLayer = true
    content?.layoutSubtreeIfNeeded()
    content?.displayIfNeeded()

    guard !PanelMotion.prefersReducedMotion, let layer = content?.layer else {
      panel.alphaValue = 1
      panel.hasShadow = true
      panel.makeKeyAndOrderFront(nil)
      return
    }
    let start = PanelMotion.transform(scale: PanelMotion.entryScale, anchor: anchor, size: panel.frame.size)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.transform = start
    CATransaction.commit()

    panel.alphaValue = 0
    panel.hasShadow = true
    panel.makeKeyAndOrderFront(nil)

    let settle = CASpringAnimation(perceptualDuration: PanelMotion.springDuration, bounce: PanelMotion.springBounce)
    settle.keyPath = "transform"
    settle.fromValue = NSValue(caTransform3D: start)
    settle.toValue = NSValue(caTransform3D: CATransform3DIdentity)
    settle.duration = settle.settlingDuration
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.transform = CATransform3DIdentity
    layer.add(settle, forKey: PanelMotion.transformKey)
    CATransaction.commit()

    NSAnimationContext.runAnimationGroup { context in
      context.duration = PanelMotion.openDuration
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      panel.animator().alphaValue = 1
    }
    let settled = settle.settlingDuration
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(settled))
      panel.invalidateShadow()
    }
  }

  private func installDismissalObservers(for panel: NSPanel) {
    outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
      Task { @MainActor in
        ComposePanelCoordinator.shared.dismissFromOutside()
      }
    }
    resignObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didResignKeyNotification,
      object: panel,
      queue: .main
    ) { _ in
      Task { @MainActor in
        ComposePanelCoordinator.shared.dismissFromOutside()
      }
    }
  }

  private func removeDismissalObservers() {
    if let outsideClickMonitor {
      NSEvent.removeMonitor(outsideClickMonitor)
      self.outsideClickMonitor = nil
    }
    if let resignObserver {
      NotificationCenter.default.removeObserver(resignObserver)
      self.resignObserver = nil
    }
  }
}

enum ComposePanelGeometry {
  private static let gap: CGFloat = 8
  private static let inset: CGFloat = 10

  /// Above the control with their left edges lined up, or below it when
  /// there is no room above. A message box sits at the bottom of its window,
  /// and the conversation above it is what the pop-up can afford to cover.
  static func frame(size: CGSize, anchor: CGRect, visibleFrame: CGRect) -> CGRect {
    var y = anchor.maxY + gap
    if y + size.height > visibleFrame.maxY - inset {
      y = anchor.minY - size.height - gap
    }
    let minX = visibleFrame.minX + inset
    let minY = visibleFrame.minY + inset
    let maxX = max(minX, visibleFrame.maxX - size.width - inset)
    let maxY = max(minY, visibleFrame.maxY - size.height - inset)
    return CGRect(
      origin: CGPoint(x: min(max(anchor.minX, minX), maxX), y: min(max(y, minY), maxY)),
      size: size
    )
  }
}

// MARK: - Content

private struct ComposePanelView: View {
  @EnvironmentObject private var settingsStore: SettingsStore

  var body: some View {
    ThemedContainer {
      ComposePanelBody()
    }
    .preferredColorScheme(settingsStore.settings.theme.preferredColorScheme)
    .environment(\.locale, settingsStore.resolvedLocale)
  }
}

/// Laid out like the selection pop-up, so the two read as one family: the
/// window's name in the header, the actions as tabs above the captured text,
/// the answer, and the commands in the footer. What is particular to writing
/// sits on one row under the text: who the message is for, and the language
/// it goes out in — each only when the action's prompt asks for it.
private struct ComposePanelBody: View {
  @EnvironmentObject private var model: ComposeModel
  @EnvironmentObject private var settingsStore: SettingsStore
  @Environment(\.palette) private var palette
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.openSettings) private var openSettings
  @FocusState private var editorFocused: Bool
  @State private var didCopy = false
  @State private var copyResetTask: Task<Void, Never>?

  static var title: String { L10n.isChinese ? "写作" : "Writing" }

  var body: some View {
    VStack(spacing: 0) {
      header
      Hairline()
      if model.hasDraft {
        VStack(spacing: AppSpacing.sm) {
          ActionTabBar(actions: model.actions, selection: actionSelection, size: .compact)
            .frame(maxWidth: .infinity, alignment: .leading)
          sourceLine
          if !model.options.isEmpty || model.showsLanguages {
            optionsRow
          }
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.top, AppSpacing.sm + 2)
        .padding(.bottom, AppSpacing.sm)
        .background { actionShortcuts }
        Hairline()
        if let error = model.errorMessage ?? model.currentDraft?.error {
          failureNotice(error)
          Hairline()
        }
        editor
        Hairline()
        footer
      } else {
        notice
      }
    }
    .floatingPanelBackground(palette)
    .onExitCommand { model.cancel() }
    .onAppear { focusEditor() }
    .onChange(of: model.sessionID) { _, _ in focusEditor() }
    .onDisappear { copyResetTask?.cancel() }
    .animation(AppMotion.state(reduceMotion: reduceMotion), value: model.currentDraft?.error)
    .animation(AppMotion.state(reduceMotion: reduceMotion), value: model.style.actionID)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Self.title)
  }

  private func focusEditor() {
    guard model.hasDraft else { return }
    // The panel becomes key in the same pass that first lays this out.
    Task { @MainActor in editorFocused = true }
  }

  /// Whether an input method is still composing in the editor. Its Return
  /// and Escape confirm or cancel the composition, never the pop-up.
  private var isComposingText: Bool {
    (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() == true
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: AppSpacing.sm) {
      AppLogo(size: 20)
        .allowsHitTesting(false)
      Text(Self.title)
        .font(AppFont.bodyMedium)
        .foregroundStyle(palette.foreground)
        .allowsHitTesting(false)
      Spacer(minLength: AppSpacing.sm)
      if model.isStreaming {
        Spinner(size: 12, isLive: true)
      }
      IconButton(title: L10n.isChinese ? "取消 (Esc)" : "Cancel (Escape)", symbol: "xmark", size: .iconSmall) {
        model.cancel()
      }
    }
    .padding(.horizontal, AppSpacing.md)
    .frame(height: AppMetrics.paneHeaderHeight)
    .background(WindowDragArea())
  }

  // MARK: - Actions

  private var actionSelection: Binding<UUID> {
    Binding(get: { model.style.actionID }, set: { model.select(action: $0) })
  }

  /// ⌘1 to ⌘9 pick the tabs in order, as in a browser.
  private var actionShortcuts: some View {
    ZStack {
      ForEach(Array(model.actions.prefix(9).enumerated()), id: \.element.id) { index, _ in
        Button("") { model.selectAction(at: index) }
          .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.command])
      }
    }
    .opacity(0)
    .accessibilityHidden(true)
  }

  // MARK: - Draft, options and language

  private var sourceLine: some View {
    HStack(alignment: .top, spacing: AppSpacing.sm) {
      Image(systemName: "quote.opening")
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(palette.faintForeground)
        .padding(.top, 2)
        .accessibilityHidden(true)
      Text(model.sourceText)
        .font(AppFont.body)
        .foregroundStyle(palette.secondaryForeground)
        .lineLimit(2)
        .help(model.sourceText)
      Spacer(minLength: 0)
    }
    .padding(AppSpacing.sm)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(palette.muted, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
  }

  private var optionsRow: some View {
    HStack(spacing: AppSpacing.sm) {
      if !model.options.isEmpty {
        ActionOptionsBar(
          options: model.options,
          selectedID: model.currentOption?.id,
          language: model.showsLanguages ? model.style.language : nil,
          showsTabHint: true,
          toggle: { model.toggle(option: $0) }
        )
      }
      Spacer(minLength: 0)
      if model.showsLanguages {
        languagePicker
      }
    }
    .frame(height: AppMetrics.controlHeightSmall)
  }

  private var languagePicker: some View {
    HStack(spacing: 2) {
      ForEach(model.languageOptions) { language in
        let isOn = language == model.style.language
        Button {
          model.select(language)
        } label: {
          Text(language.displayName)
            .font(AppFont.label)
            .foregroundStyle(isOn ? palette.foreground : palette.mutedForeground)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, AppSpacing.sm)
            .frame(height: 22)
            .background(
              isOn ? palette.surfaceElevated : Color.clear,
              in: RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.isChinese ? "写成\(language.displayName) (⌘L 切换)" : "Write in \(language.displayName) (⌘L to switch)")
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
      }
    }
    .padding(2)
    .background(palette.muted, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
    .fixedSize()
    .background {
      // ⌘L steps through the languages from anywhere in the pop-up.
      Button("") { model.cycleLanguage() }
        .keyboardShortcut("l", modifiers: [.command])
        .opacity(0)
        .accessibilityHidden(true)
    }
  }

  // MARK: - Answer

  private var translationBinding: Binding<String> {
    Binding(get: { model.translation }, set: { model.translation = $0 })
  }

  private var editor: some View {
    ZStack(alignment: .topLeading) {
      TextEditor(text: translationBinding)
        .font(.system(size: settingsStore.settings.fontSize))
        .lineSpacing(3)
        .foregroundStyle(palette.foreground)
        .scrollContentBackground(.hidden)
        .textEditorOverlayScrollers()
        .focused($editorFocused)
        .onKeyPress(keys: [.return], phases: .down) { press in
          // ⇧↩ and ⌥↩ are a line break in the message, as in a chat box.
          guard !isComposingText, !press.modifiers.contains(.shift), !press.modifiers.contains(.option)
          else { return .ignored }
          model.replace()
          return .handled
        }
        .onKeyPress(keys: [.tab], phases: .down) { press in
          // A tab character has no place in a chat message, so Tab is only
          // ever the option switch, and does nothing for an action without any.
          guard !isComposingText else { return .ignored }
          model.cycleOption(backwards: press.modifiers.contains(.shift))
          return .handled
        }
        .onKeyPress(keys: [.escape], phases: .down) { _ in
          guard !isComposingText else { return .ignored }
          model.cancel()
          return .handled
        }
        .accessibilityLabel(L10n.isChinese ? "结果，可修改" : "Result, editable")
        .padding(.horizontal, AppSpacing.md - 5)
        .padding(.vertical, AppSpacing.sm)

      if model.translation.isEmpty, model.isStreaming {
        Text(L10n.isChinese ? "正在写…" : "Writing…")
          .font(.system(size: settingsStore.settings.fontSize))
          .foregroundStyle(palette.mutedForeground)
          .padding(.horizontal, AppSpacing.md)
          .padding(.vertical, AppSpacing.sm)
          .allowsHitTesting(false)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private func failureNotice(_ error: String) -> some View {
    VStack(alignment: .leading, spacing: AppSpacing.xs) {
      Label(error, systemImage: "exclamationmark.triangle.fill")
        .font(AppFont.caption)
        .foregroundStyle(palette.warning)
        .lineLimit(3)
        .fixedSize(horizontal: false, vertical: true)
        .help(error)
      HStack(spacing: AppSpacing.sm) {
        if model.copiedAfterFailure {
          Text(L10n.isChinese ? "结果已拷贝，可以按 ⌘V 手动粘贴。" : "The result is on the clipboard — press ⌘V to paste it.")
            .font(AppFont.caption)
            .foregroundStyle(palette.mutedForeground)
        } else if model.currentDraft?.error != nil {
          Button(L10n.isChinese ? "重试" : "Retry") { model.regenerate() }
            .appButton(.secondary, size: .xs)
          if model.isConfigurationError {
            Button(L10n.isChinese ? "打开设置" : "Open Settings") {
              model.cancel()
              WindowCoordinator.prepareForSettings()
              openSettings()
            }
            .appButton(.secondary, size: .xs)
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, AppSpacing.md)
    .padding(.vertical, AppSpacing.sm)
  }

  // MARK: - Footer

  /// The keys worth knowing, most useful first. Only the ones that do
  /// something for the current action are listed, and the tail is dropped
  /// when the footer runs out of room.
  private var keyHints: [String] {
    var hints = [L10n.isChinese ? "↩ 替换" : "↩ replace"]
    if !model.options.isEmpty { hints.append(L10n.isChinese ? "⇥ 选项" : "⇥ option") }
    if model.showsLanguages { hints.append(L10n.isChinese ? "⌘L 语言" : "⌘L language") }
    if model.actions.count > 1 {
      let last = min(model.actions.count, 9)
      hints.append(L10n.isChinese ? "⌘1–\(last) 动作" : "⌘1–\(last) action")
    }
    hints.append(L10n.isChinese ? "⇧↩ 换行" : "⇧↩ new line")
    return hints
  }

  private var footer: some View {
    HStack(spacing: AppSpacing.sm) {
      let hints = keyHints
      ViewThatFits(in: .horizontal) {
        ForEach(Array(stride(from: hints.count, through: 1, by: -1)), id: \.self) { count in
          Text(hints.prefix(count).joined(separator: L10n.isChinese ? "　" : "  "))
            .lineLimit(1)
            .fixedSize()
        }
      }
      .font(AppFont.caption)
      .foregroundStyle(palette.mutedForeground)
      .accessibilityHidden(true)

      Spacer(minLength: AppSpacing.xs)

      IconButton(
        title: L10n.isChinese ? "换个说法 (⌘R)" : "Try another wording (⌘R)",
        symbol: "arrow.clockwise",
        isDisabled: model.isStreaming || model.currentDraft == nil
      ) {
        model.regenerate()
      }
      .keyboardShortcut("r", modifiers: [.command])

      IconButton(
        title: didCopy ? (L10n.isChinese ? "已拷贝" : "Copied") : (L10n.isChinese ? "拷贝结果" : "Copy the result"),
        symbol: didCopy ? "checkmark" : "doc.on.doc",
        isDisabled: model.isStreaming || model.translation.isEmpty
      ) {
        model.copyTranslation()
        didCopy = true
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor in
          try? await Task.sleep(for: .seconds(1.6))
          guard !Task.isCancelled else { return }
          didCopy = false
        }
      }

      Button {
        model.replace()
      } label: {
        HStack(spacing: AppSpacing.xs + 1) {
          if model.replacesWhenFinished {
            Spinner(size: 11)
            Text(L10n.isChinese ? "写完就替换" : "Replacing when done")
          } else {
            Image(systemName: "arrow.turn.down.left")
              .font(.system(size: 11, weight: .medium))
            Text(L10n.isChinese ? "替换" : "Replace")
          }
        }
      }
      .appButton(.brand, size: .sm, capsule: true)
      .keyboardShortcut(.return, modifiers: [.command])
      .disabled(!model.canReplace)
      .help(replaceHelp)
      .accessibilityLabel(replaceHelp)
    }
    .padding(.horizontal, AppSpacing.md)
    .frame(height: AppMetrics.paneFooterHeight + 4)
  }

  private var replaceHelp: String {
    let app = model.applicationName ?? (L10n.isChinese ? "原应用" : "the app")
    return L10n.isChinese
      ? "用结果替换 \(app) 输入框里的文字 (↩)"
      : "Replace the text in \(app) with the result (Return)"
  }

  // MARK: - Nothing to work on

  private var notice: some View {
    VStack(alignment: .leading, spacing: AppSpacing.md) {
      Text(model.errorMessage ?? "")
        .font(AppFont.body)
        .foregroundStyle(palette.secondaryForeground)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: AppSpacing.sm) {
        Spacer(minLength: 0)
        if model.isAccessibilityPermissionMissing {
          Button(L10n.isChinese ? "打开系统设置" : "Open System Settings") {
            model.openAccessibilitySettings()
          }
          .appButton(.secondary, size: .sm)
        }
        Button(L10n.isChinese ? "知道了" : "OK") { model.cancel() }
          .appButton(.ghost, size: .sm)
          .keyboardShortcut(.cancelAction)
      }
    }
    .padding(.horizontal, AppSpacing.md)
    .padding(.vertical, AppSpacing.sm + 2)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}
