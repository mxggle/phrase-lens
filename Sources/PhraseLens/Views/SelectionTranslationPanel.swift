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
  /// Where the panel grew from, in the content layer's unit space, so that it
  /// collapses back into the same point on the way out.
  private var anchor = PanelMotion.centreAnchor
  private weak var settingsStore: SettingsStore?
  /// The model whose request this panel is displaying, so dismissing the panel
  /// can call that request off.
  private weak var model: AppModel?

  private init() {}

  func show(model: AppModel) {
    // A replacement pop-up should not cross-fade with the one it replaces:
    // two stacked panels at the same spot read as a flicker, not a transition.
    // This is a hand-off, not a dismissal — the request the new panel is about
    // to display is usually already running — so it keeps the translation.
    close(animated: false, cancelsTranslation: false)

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
    // The shadow is derived from the window rect until the rounded card has
    // drawn, which is the frame that appeared a beat before the content. It is
    // switched on in `present` once there is a shape to cast it.
    panel.hasShadow = false
    panel.setAccessibilityRole(NSAccessibility.Role.window)
    panel.setAccessibilitySubrole(NSAccessibility.Subrole.floatingWindow)
    panel.setAccessibilityLabel("Selection translation")
    panel.isMovableByWindowBackground = true
    panel.isReleasedWhenClosed = false
    panel.isFloatingPanel = true
    panel.becomesKeyOnlyIfNeeded = false
    panel.hidesOnDeactivate = false
    panel.level = .floating
    // The entrance and exit are driven by `PanelMotion` below, so the system
    // must not layer its own generic window fade on top of them.
    panel.animationBehavior = .none
    panel.collectionBehavior = [
      .canJoinAllSpaces,
      .fullScreenAuxiliary,
      .transient,
      .ignoresCycle,
    ]

    let settings = model.settingsStore.settings
    let pointer = NSEvent.mouseLocation
    let targetFrame: NSRect
    /// A remembered position has no relationship to the pointer, so the panel
    /// grows from its own centre there instead of out of a corner the cursor
    /// is nowhere near.
    var growsFromPointer = true
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
        growsFromPointer = false
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
    self.model = model
    settingsStore = model.settingsStore
    rememberCurrentPosition()
    installDismissalObservers(for: panel)

    NSApp.setActivationPolicy(settings.showDockIcon ? .regular : .accessory)
    present(
      panel,
      anchor: PanelMotion.anchor(
        panelFrame: targetFrame,
        pointer: pointer,
        followsPointer: growsFromPointer
      )
    )
  }

  /// Takes the pop-up down.
  ///
  /// Dismissing it abandons the work it was showing: a request left running
  /// would keep streaming into a window the user has already waved away and
  /// would still file itself in history when it finished. A hand-off is not a
  /// dismissal, though — `show` closes the panel it replaces, and the main
  /// window carries on displaying the same request — so those callers pass
  /// `cancelsTranslation: false`.
  func close(animated: Bool = true, cancelsTranslation: Bool = true) {
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
    if cancelsTranslation, model?.isTranslating == true {
      model?.stopTranslation()
    }
    model = nil
    guard let panel else {
      settingsStore = nil
      return
    }
    self.panel = nil
    settingsStore = nil
    dismiss(panel, animated: animated)
  }

  // MARK: - Presentation

  /// Puts the panel on screen growing out of the edge the pointer is at.
  ///
  /// The card is drawn into the backing store *before* the panel is visible.
  /// Ordering it in first showed the window's own chrome and shadow for a beat
  /// while SwiftUI was still laying out — the frame that arrived ahead of its
  /// contents. The motion itself has to live here rather than in SwiftUI,
  /// because the exit runs after the view tree is gone.
  private func present(_ panel: SelectionPopoverPanel, anchor: CGPoint) {
    self.anchor = anchor
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

    let start = PanelMotion.transform(
      scale: PanelMotion.entryScale,
      anchor: anchor,
      size: panel.frame.size
    )
    // Set the start state on the layer before the panel is visible, so the
    // first frame on screen is already the small one.
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.transform = start
    CATransaction.commit()

    panel.alphaValue = 0
    panel.hasShadow = true
    panel.makeKeyAndOrderFront(nil)

    let settle = CASpringAnimation(
      perceptualDuration: PanelMotion.springDuration,
      bounce: PanelMotion.springBounce
    )
    settle.keyPath = "transform"
    settle.fromValue = NSValue(caTransform3D: start)
    settle.toValue = NSValue(caTransform3D: CATransform3DIdentity)
    // A spring is otherwise clipped at the default 0.25s, which lands the panel
    // with a visible step instead of letting it settle.
    settle.duration = settle.settlingDuration

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.transform = CATransform3DIdentity
    layer.add(settle, forKey: PanelMotion.transformKey)
    CATransaction.commit()

    // The fade is short enough that the card is solid while it is still
    // growing: it should read as one object arriving, not as two effects.
    NSAnimationContext.runAnimationGroup { context in
      context.duration = PanelMotion.openDuration
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      panel.animator().alphaValue = 1
    }

    // The shadow is captured from the content as it is ordered in, so it has to
    // be recomputed once the panel has settled at full size.
    let settled = settle.settlingDuration
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(settled))
      panel.invalidateShadow()
    }
  }

  /// Collapses the panel back towards its anchor, then releases its view tree.
  ///
  /// The panel is kept alive by the task rather than by `self`, so a pop-up
  /// that is dismissed and immediately re-shown never fights with its successor.
  private func dismiss(_ panel: SelectionPopoverPanel, animated: Bool) {
    guard animated, !PanelMotion.prefersReducedMotion else {
      panel.orderOut(nil)
      panel.contentViewController = nil
      return
    }

    if let layer = panel.contentView?.layer {
      // Dismissing mid-entrance is common — a hotkey pressed twice, a click
      // straight through the panel — so pick up wherever the spring got to
      // rather than snapping to full size first.
      let current = layer.presentation()?.transform ?? layer.transform
      layer.removeAnimation(forKey: PanelMotion.transformKey)
      let exit = CABasicAnimation(keyPath: "transform")
      exit.fromValue = NSValue(caTransform3D: current)
      exit.toValue = NSValue(
        caTransform3D: PanelMotion.transform(
          scale: PanelMotion.exitScale,
          anchor: anchor,
          size: panel.frame.size
        )
      )
      exit.duration = PanelMotion.closeDuration
      exit.timingFunction = CAMediaTimingFunction(name: .easeIn)
      exit.fillMode = .forwards
      exit.isRemovedOnCompletion = false
      layer.add(exit, forKey: PanelMotion.transformKey)
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

/// Timing and transforms for the pop-up's entrance and exit.
///
/// One gesture, not a stack of effects: the card grows out of the edge the
/// pointer is on and snaps to size. Nothing slides, and nothing moves apart
/// from the scale — a translation on top of the fade was what made the panel
/// look like it was assembling itself out of a frame.
enum PanelMotion {
  static let transformKey = "selectionPanelTransform"
  static let centreAnchor = CGPoint(x: 0.5, y: 0.5)

  /// Quick and lightly sprung: enough overshoot to feel physical, not enough
  /// to wobble.
  static let springDuration: TimeInterval = 0.22
  static let springBounce: CGFloat = 0.16
  /// The fade is only there to stop the first frame being a hard cut; the
  /// scale carries the entrance, so this ends well before the spring does.
  static let openDuration: TimeInterval = 0.09
  /// Dismissal is faster than arrival — the pop-up should get out of the way.
  static let closeDuration: TimeInterval = 0.1

  /// A big enough jump to be worth watching. The card grows from a corner, so
  /// the travel reads at roughly twice what a centred scale would give.
  static let entryScale: CGFloat = 0.9
  static let exitScale: CGFloat = 0.94

  static var prefersReducedMotion: Bool {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }

  /// The point the panel grows from, in the content layer's unit space.
  ///
  /// The pointer sits just outside the panel, so clamping it into unit space
  /// lands exactly on the nearest corner or edge — the side the pop-up was
  /// invoked from.
  static func anchor(panelFrame: CGRect, pointer: CGPoint, followsPointer: Bool) -> CGPoint {
    guard followsPointer, panelFrame.width > 0, panelFrame.height > 0 else { return centreAnchor }
    return CGPoint(
      x: min(max((pointer.x - panelFrame.minX) / panelFrame.width, 0), 1),
      y: min(max((pointer.y - panelFrame.minY) / panelFrame.height, 0), 1)
    )
  }

  /// Scales about `anchor` without touching the layer's own anchor point,
  /// which AppKit owns for a layer-backed view and resets on layout.
  static func transform(scale: CGFloat, anchor: CGPoint, size: CGSize) -> CATransform3D {
    let dx = (anchor.x - 0.5) * size.width
    let dy = (anchor.y - 0.5) * size.height
    var transform = CATransform3DMakeTranslation(dx, dy, 0)
    transform = CATransform3DScale(transform, scale, scale, 1)
    return CATransform3DTranslate(transform, -dx, -dy, 0)
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
  @Environment(\.openSettings) private var openSettings
  @State private var didCopy = false
  @State private var copyResetTask: Task<Void, Never>?
  @State private var isSourceExpanded = false

  /// The captured text is clamped at rest so the pop-up always opens at the
  /// same height, and capped when expanded because the panel cannot grow —
  /// anything past the cap belongs in the full translator window.
  private static let collapsedSourceLines = 2
  private static let expandedSourceLines = 10

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
        // The strip sizes to its content now, so pin it to the leading edge
        // rather than letting the stack centre a half-width track.
        .frame(maxWidth: .infinity, alignment: .leading)
        sourceSummary
      }
      .padding(.horizontal, AppSpacing.md)
      .padding(.top, AppSpacing.sm + 2)
      .padding(.bottom, AppSpacing.sm)
      Hairline()
      // A failure sits above the result instead of replacing it: an error that
      // takes the Translate button off screen leaves nothing to recover with.
      // The accessibility case keeps the whole area, because its own recovery
      // route is already the only thing worth showing there.
      if !model.isAccessibilityPermissionError, let error = model.errorMessage {
        failureNotice(error)
        Hairline()
      }
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
    .animation(AppMotion.state(reduceMotion: reduceMotion), value: model.errorMessage)
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

        // Closing the pop-up also calls the request off, but that costs the
        // user the result so far. Stopping is the cheaper half of it.
        IconButton(title: "Stop translating (⌘.)", symbol: "stop.fill") {
          model.stopTranslation()
        }
        .keyboardShortcut(".", modifiers: [.command])
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
          model.inputText.isEmpty ? palette.mutedForeground : palette.secondaryForeground
        )
        .lineLimit(isSourceExpanded ? Self.expandedSourceLines : Self.collapsedSourceLines)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
      Spacer(minLength: 0)
      if !model.inputText.isEmpty {
        expandSourceButton
      }
    }
    .padding(AppSpacing.sm)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(palette.muted, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
    .animation(AppMotion.state(reduceMotion: reduceMotion), value: isSourceExpanded)
  }

  /// Capture is lossy — accessibility reads can come back partial and fall back
  /// to the clipboard — so the user has to be able to read back everything that
  /// was actually captured, not the first two lines of it.
  private var expandSourceButton: some View {
    let title = isSourceExpanded
      ? "Show less of the captured text"
      : "Show all of the captured text"
    return Button {
      isSourceExpanded.toggle()
    } label: {
      Image(systemName: isSourceExpanded ? "chevron.up" : "chevron.down")
        .font(.system(size: 9, weight: .semibold))
        .contentTransition(.symbolEffect(.replace))
        .foregroundStyle(palette.mutedForeground)
        // Sized against the quote glyph rather than against a control, so a
        // one-line capture keeps the height it rests at today.
        .frame(width: AppSpacing.md, height: AppSpacing.md)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(.top, 1)
    .help(title)
    .accessibilityLabel(title)
    .accessibilityAddTraits(isSourceExpanded ? [.isSelected] : [])
  }

  // MARK: - Result

  /// The result takes every point the panel has left. A fixed height clipped
  /// generated text mid-line, which read as a rendering fault.
  @ViewBuilder
  private var result: some View {
    Group {
      if model.isAccessibilityPermissionError {
        accessibilityPermissionMessage
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
        FollowingScrollView(isFollowing: model.isTranslating, trigger: model.outputText.utf8.count) {
          Group {
            if model.outputUsesMarkdown {
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
          .overlayScrollers()
        }
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

  /// A failure and the commands that recover from it, in the shape the
  /// accessibility notice above already uses: say what went wrong, then offer
  /// the way out. It is a strip rather than a pane so the result it sits over
  /// keeps whatever it was showing.
  private func failureNotice(_ error: String) -> some View {
    VStack(alignment: .leading, spacing: AppSpacing.sm) {
      Label(error, systemImage: "exclamationmark.triangle.fill")
        .font(AppFont.body)
        .foregroundStyle(palette.warning)
        // Provider messages run long and the panel's height is fixed, so the
        // notice gives back the space it does not need.
        .lineLimit(3)
        .fixedSize(horizontal: false, vertical: true)
        .help(error)

      HStack(spacing: AppSpacing.sm) {
        Button("Retry") {
          model.translate()
        }
        .appButton(.secondary, size: .sm)
        .disabled(normalizedInputText.isEmpty)

        // Retrying a misconfigured provider only reproduces the error, so a
        // configuration failure also needs the route that fixes it — and from
        // this pop-up, Settings is otherwise unreachable.
        if model.isConfigurationError {
          Button("Open Settings") {
            WindowCoordinator.prepareForSettings()
            openSettings()
          }
          .appButton(.secondary, size: .sm)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, AppSpacing.md)
    .padding(.vertical, AppSpacing.sm)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Translation problem")
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
          ? "Remove from Vocabulary"
          : "Save selected word or phrase to Vocabulary",
        symbol: isCurrentTextCollected ? "bookmark.fill" : "bookmark",
        isDisabled: !isCurrentTextCollected && !canCollectCurrentText,
        isOn: isCurrentTextCollected
      ) {
        model.toggleCollectCurrentWord()
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
    model.vocabularyEntry(matching: normalizedInputText) != nil
  }
}
