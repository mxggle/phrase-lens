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

  /// How the pop-up is leaving, which decides what becomes of the lookup it
  /// was showing.
  enum Exit {
    /// Waved away: Escape, the close button, a click elsewhere. Its request is
    /// called off, and the main window gets back what the lookup set aside.
    case dismissal
    /// The lookup carries on somewhere else — the main window, or Settings on
    /// the way to fixing it — so it keeps running and becomes the window's.
    case handOff
    /// Taken down by the app itself, to make way for a replacement or to hand
    /// key focus back for a write-back. Nothing is called off or given back;
    /// the caller decides what happens next.
    case suspension
  }

  /// The widths the reader can drag the pop-up between. The height is not
  /// theirs to set: it follows the content.
  static let widthRange: ClosedRange<CGFloat> = 400...760
  /// What the panel opens at before its content has reported a height: about
  /// what the chrome and a one-line status take, so the first measured size
  /// is a small step rather than a jump.
  private static let initialHeight: CGFloat = 260

  private var panel: SelectionPopoverPanel?
  private var outsideClickMonitor: Any?
  private var escapeKeyMonitor: Any?
  private var resignObserver: NSObjectProtocol?
  private var deactivateObserver: NSObjectProtocol?
  private var moveObserver: NSObjectProtocol?
  private var liveResizeObserver: NSObjectProtocol?
  private var tabKeyMonitor: Any?
  /// Where the panel grew from, in the content layer's unit space, so that it
  /// collapses back into the same point on the way out.
  private var growthAnchor = PanelMotion.centreAnchor
  /// Where the panel sits, and which of its edges stays put while its height
  /// follows the content.
  private var placement: SelectionPanelAnchor?
  /// The height the content last asked for, and whether the panel may shrink
  /// to it.
  private var requestedHeight: CGFloat?
  private var allowsShrinking = true
  private var isFitScheduled = false
  /// The frame the coordinator itself last gave the panel, so the move that
  /// causes is not mistaken for the reader dragging it somewhere.
  private var appliedFrame: CGRect?
  private weak var settingsStore: SettingsStore?
  /// The model whose request this panel is displaying, so dismissing the panel
  /// can call that request off.
  private weak var model: AppModel?

  private init() {}

  var isVisible: Bool { panel != nil }

  func show(model: AppModel) {
    // A pop-up that is already on screen for this model just shows the new
    // lookup: its view observes the model, so the content updates in place.
    // Rebuilding it would replay the entrance for a window that never left,
    // and move a panel the user has pinned where they want it.
    if let panel, panel.isVisible, self.model === model {
      panel.makeKeyAndOrderFront(nil)
      return
    }

    // A replacement pop-up should not cross-fade with the one it replaces:
    // two stacked panels at the same spot read as a flicker, not a transition.
    // This is a hand-off, not a dismissal — the request the new panel is about
    // to display is usually already running — so nothing is called off.
    close(animated: false, as: .suspension)

    let settings = model.settingsStore.settings
    let width = Self.clampedWidth(settings.selectionPanelWidth)
    let rootView = SelectionTranslationPanelView()
      .environmentObject(model)
      .environmentObject(model.settingsStore)
      .environmentObject(model.learning)
    let hostingController = NSHostingController(rootView: rootView)
    // The coordinator sizes the panel, from the height the content reports.
    // Left to itself the hosting controller would pin the window to the
    // view's own idea of its size and fight every resize.
    hostingController.sizingOptions = []
    let panel = SelectionPopoverPanel(
      contentRect: NSRect(origin: .zero, size: CGSize(width: width, height: Self.initialHeight)),
      // Resizable for the width alone: `lockHeight` keeps the height the
      // content's.
      styleMask: [.borderless, .nonactivatingPanel, .resizable],
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
    panel.setAccessibilityLabel(L10n.tr("panel.accessibility_label"))
    // The panel is dragged by its header alone (`WindowDragArea`). Moving it
    // by the background would mean every drag over the result moved the window
    // instead of selecting the words it passed over.
    panel.isMovableByWindowBackground = false
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

    let (placement, growsFrom) = Self.initialPlacement(
      for: settings,
      selection: model.selectionAnchorRect,
      pointer: NSEvent.mouseLocation,
      width: width
    )
    let targetFrame = placement.frame(width: width, height: Self.initialHeight)
    panel.setFrame(targetFrame, display: false)
    lockHeight(of: panel, to: targetFrame.height)
    appliedFrame = targetFrame
    self.placement = placement
    requestedHeight = nil
    allowsShrinking = true
    self.panel = panel
    self.model = model
    settingsStore = model.settingsStore
    installFrameObservers(for: panel)
    installTabKeyMonitor()
    if !settings.selectionPanelPinned {
      installDismissalObservers()
    }

    NSApp.setActivationPolicy(settings.showDockIcon ? .regular : .accessory)
    present(
      panel,
      anchor: PanelMotion.anchor(
        panelFrame: targetFrame,
        pointer: growsFrom ?? .zero,
        followsPointer: growsFrom != nil
      )
    )
  }

  /// Takes the pop-up down.
  ///
  /// Dismissing it abandons the work it was showing: a request left running
  /// would keep streaming into a window the user has already waved away and
  /// would still file itself in history when it finished. See `Exit` for the
  /// two ways out that are not a dismissal.
  func close(animated: Bool = true, as exit: Exit = .dismissal) {
    removeDismissalObservers()
    removeFrameObservers()
    removeTabKeyMonitor()
    let model = self.model
    self.model = nil
    settingsStore = nil
    placement = nil
    requestedHeight = nil
    appliedFrame = nil
    if let panel {
      self.panel = nil
      dismiss(panel, animated: animated)
    }
    switch exit {
    case .dismissal:
      if model?.isTranslating == true {
        model?.stopTranslation()
      }
      model?.selectionPopupDidClose(handingOff: false)
    case .handOff:
      model?.selectionPopupDidClose(handingOff: true)
    case .suspension:
      break
    }
  }

  // MARK: - Size

  /// The height the pop-up's content needs, reported whenever it changes.
  ///
  /// Applied on the next turn of the run loop rather than straight away, so a
  /// burst of reports — each streamed chunk, each line the source wraps to —
  /// lands as one resize, and never from inside the layout pass that measured
  /// it. While a request is running the panel only grows: shrinking to a
  /// status line between two long answers and growing straight back would
  /// make it pump.
  func contentHeightDidChange(_ height: CGFloat, allowsShrinking: Bool) {
    guard panel != nil, height > 0 else { return }
    requestedHeight = height
    self.allowsShrinking = allowsShrinking
    guard !isFitScheduled else { return }
    isFitScheduled = true
    Task { @MainActor in
      SelectionPanelCoordinator.shared.applyFit()
    }
  }

  private func applyFit() {
    isFitScheduled = false
    guard let panel, let placement, let requestedHeight else { return }
    // A drag on the panel's edge belongs to the reader; the height catches up
    // when they let go.
    guard !panel.inLiveResize else { return }
    var height = min(requestedHeight.rounded(.up), placement.maxHeight)
    if !allowsShrinking {
      height = max(height, min(panel.frame.height, placement.maxHeight))
    }
    let frame = placement.frame(width: panel.frame.width, height: height)
    guard frame != panel.frame else { return }
    appliedFrame = frame
    panel.setFrame(frame, display: true)
    lockHeight(of: panel, to: frame.height)
    // A borderless window's shadow is cut from what it drew last, which was
    // the old size.
    panel.invalidateShadow()
  }

  /// Only the width is the reader's to drag.
  private func lockHeight(of panel: NSPanel, to height: CGFloat) {
    panel.minSize = CGSize(width: Self.widthRange.lowerBound, height: height)
    panel.maxSize = CGSize(width: Self.widthRange.upperBound, height: height)
  }

  private static func clampedWidth(_ width: CGFloat) -> CGFloat {
    min(max(width, widthRange.lowerBound), widthRange.upperBound)
  }

  // MARK: - Placement

  /// Under the selection when accessibility said where it is, beside the
  /// pointer when it did not, and at the remembered spot when the reader
  /// asked for a fixed one. Returns the point the entrance grows out of,
  /// which is nil when that is the panel's own centre.
  private static func initialPlacement(
    for settings: AppSettings,
    selection: CGRect?,
    pointer: CGPoint,
    width: CGFloat
  ) -> (anchor: SelectionPanelAnchor, growsFrom: CGPoint?) {
    if settings.selectionPanelPlacement == .fixed, let remembered = settings.selectionPanelTopLeft {
      let topLeft = CGPoint(x: remembered.x, y: remembered.y)
      let probe = CGRect(x: topLeft.x, y: topLeft.y - initialHeight, width: width, height: initialHeight)
      let visibleFrame = screen(intersecting: probe)?.visibleFrame
        ?? NSScreen.main?.visibleFrame
        ?? fallbackVisibleFrame
      // A remembered position has no relationship to the pointer, so the
      // panel grows from its own centre there instead of out of a corner the
      // cursor is nowhere near.
      return (SelectionPanelGeometry.anchor(topLeft: topLeft, width: width, visibleFrame: visibleFrame), nil)
    }
    if let selection,
      let visibleFrame = screen(containing: CGPoint(x: selection.midX, y: selection.midY))?.visibleFrame,
      SelectionPanelGeometry.canAnchor(to: selection, in: visibleFrame)
    {
      let anchor = SelectionPanelGeometry.anchor(below: selection, width: width, visibleFrame: visibleFrame)
      // It grows out of the words it is about, from the side it opened on.
      let growsFrom = CGPoint(x: selection.minX, y: anchor.edge == .top ? selection.minY : selection.maxY)
      return (anchor, growsFrom)
    }
    let visibleFrame = screen(containing: pointer)?.visibleFrame ?? fallbackVisibleFrame
    return (SelectionPanelGeometry.anchor(nearPointer: pointer, width: width, visibleFrame: visibleFrame), pointer)
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
    growthAnchor = anchor
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
          anchor: growthAnchor,
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

  /// Turns the pop-up's auto-dismissal on and off while it is open.
  ///
  /// Pinned, the panel outlives a click elsewhere: the whole point is to keep
  /// a result readable while the user works in the app it came from. Escape
  /// and the close button still take it down, and so does the next pop-up.
  func setPinned(_ isPinned: Bool) {
    guard panel != nil else { return }
    if isPinned {
      removeDismissalObservers()
    } else if outsideClickMonitor == nil {
      installDismissalObservers()
    }
  }

  private func installDismissalObservers() {
    guard let panel else { return }
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

  private func installFrameObservers(for panel: NSPanel) {
    moveObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didMoveNotification,
      object: panel,
      queue: .main
    ) { _ in
      Task { @MainActor in
        SelectionPanelCoordinator.shared.panelDidMove()
      }
    }
    liveResizeObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didEndLiveResizeNotification,
      object: panel,
      queue: .main
    ) { _ in
      Task { @MainActor in
        SelectionPanelCoordinator.shared.panelDidEndLiveResize()
      }
    }
  }

  /// Tab and ⇧Tab step through the action's options, as in the writing
  /// pop-up and the main window. Read before the window sees the key, so it
  /// works wherever focus is in the panel — the field included, where Tab
  /// would otherwise only move focus — and is left alone for an action with
  /// no options, or while an input method is composing.
  private func installTabKeyMonitor() {
    tabKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      guard event.keyCode == 48,
        event.modifierFlags.intersection([.command, .option, .control]).isEmpty
      else { return event }
      let backwards = event.modifierFlags.contains(.shift)
      let windowNumber = event.windowNumber
      let handled = MainActor.assumeIsolated {
        SelectionPanelCoordinator.shared.cycleOption(inWindow: windowNumber, backwards: backwards)
      }
      return handled ? nil : event
    }
  }

  private func removeTabKeyMonitor() {
    if let tabKeyMonitor {
      NSEvent.removeMonitor(tabKeyMonitor)
      self.tabKeyMonitor = nil
    }
  }

  private func cycleOption(inWindow windowNumber: Int, backwards: Bool) -> Bool {
    guard let panel, let model, panel.windowNumber == windowNumber,
      (panel.firstResponder as? NSTextView)?.hasMarkedText() != true
    else { return false }
    return model.cycleOption(backwards: backwards)
  }

  private func removeFrameObservers() {
    if let moveObserver {
      NotificationCenter.default.removeObserver(moveObserver)
      self.moveObserver = nil
    }
    if let liveResizeObserver {
      NotificationCenter.default.removeObserver(liveResizeObserver)
      self.liveResizeObserver = nil
    }
  }

  /// The reader dragged the panel. It hangs from where they left it now,
  /// whichever side of the selection it opened on, and that spot is the one a
  /// fixed pop-up returns to.
  private func panelDidMove() {
    guard let panel, panel.frame != appliedFrame else { return }
    let frame = panel.frame
    appliedFrame = frame
    let visibleFrame = (panel.screen ?? NSScreen.main)?.visibleFrame ?? Self.fallbackVisibleFrame
    placement = SelectionPanelGeometry.anchor(draggedFrame: frame, visibleFrame: visibleFrame)
    guard let settingsStore else { return }
    let topLeft = SelectionPanelPosition(x: frame.minX, y: frame.maxY)
    // Every write to settings re-renders every window, so only a change is one.
    guard settingsStore.settings.selectionPanelTopLeft != topLeft else { return }
    settingsStore.settings.selectionPanelTopLeft = topLeft
  }

  /// The reader let go of the panel's edge: the width is theirs to keep, and
  /// the height catches up with the content at the new width.
  private func panelDidEndLiveResize() {
    guard let panel else { return }
    placement?.x = panel.frame.minX
    let width = Double(Self.clampedWidth(panel.frame.width))
    if let settingsStore, settingsStore.settings.selectionPanelWidth != width {
      settingsStore.settings.selectionPanelWidth = width
    }
    applyFit()
  }

  private func removeDismissalObservers() {
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

/// Where the pop-up sits, and which of its edges stays put while its height
/// follows the content.
struct SelectionPanelAnchor: Equatable {
  enum Edge: Equatable {
    /// Hangs from its top edge: the panel opened below what it describes,
    /// and grows downwards.
    case top
    /// Stands on its bottom edge: it opened above, for want of room below,
    /// and grows upwards, away from the words.
    case bottom
  }

  var x: CGFloat
  var edge: Edge
  /// The y of the edge that stays put.
  var edgeY: CGFloat
  /// The tallest the panel can grow from that edge and stay on screen.
  var maxHeight: CGFloat

  func frame(width: CGFloat, height: CGFloat) -> CGRect {
    let height = min(height, maxHeight)
    switch edge {
    case .top: return CGRect(x: x, y: edgeY - height, width: width, height: height)
    case .bottom: return CGRect(x: x, y: edgeY, width: width, height: height)
    }
  }
}

enum SelectionPanelGeometry {
  /// Clear space between the panel and the words it describes.
  static let selectionGap: CGFloat = 8
  static let pointerGap: CGFloat = 12
  private static let inset: CGFloat = 10
  /// Under the selection is where the eye goes next, so the panel opens there
  /// unless less than this is left below and there is more room above.
  static let comfortableHeight: CGFloat = 320
  /// The least room the panel is given: its chrome and a line of result.
  static let minimumHeight: CGFloat = 200

  /// The tallest the panel grows on a display, however much the content asks
  /// for. Past this a long answer scrolls, and the panel stays a pop-up
  /// rather than turning into a window.
  static func heightCap(for visibleFrame: CGRect) -> CGFloat {
    max(minimumHeight, min(640, (visibleFrame.height * 0.7).rounded(.down)))
  }

  /// Whether the rectangle accessibility reported for a selection is one to
  /// open against: on screen, and no taller than half of it. A selection that
  /// spans most of a document leaves no room on either side, and some apps
  /// report a rectangle that is not where the text is at all.
  static func canAnchor(to selection: CGRect, in visibleFrame: CGRect) -> Bool {
    selection.width > 0
      && selection.height > 0
      && selection.height <= visibleFrame.height / 2
      && visibleFrame.intersects(selection)
  }

  /// Under `target`, left-aligned with it, or above it when there is not
  /// enough room below and more above.
  static func anchor(
    below target: CGRect,
    width: CGFloat,
    gap: CGFloat = selectionGap,
    visibleFrame: CGRect
  ) -> SelectionPanelAnchor {
    let cap = heightCap(for: visibleFrame)
    let x = clampedX(target.minX, width: width, visibleFrame: visibleFrame)
    let lowest = visibleFrame.minY + inset
    let highest = visibleFrame.maxY - inset
    let roomBelow = target.minY - gap - lowest
    let roomAbove = highest - (target.maxY + gap)
    if roomBelow >= min(comfortableHeight, cap) || roomBelow >= roomAbove {
      let top = min(max(target.minY - gap, lowest + minimumHeight), highest)
      return SelectionPanelAnchor(x: x, edge: .top, edgeY: top, maxHeight: min(cap, top - lowest))
    }
    let bottom = max(min(target.maxY + gap, highest - minimumHeight), lowest)
    return SelectionPanelAnchor(x: x, edge: .bottom, edgeY: bottom, maxHeight: min(cap, highest - bottom))
  }

  /// Beside the pointer, for a selection whose position could not be read.
  /// Off to its right, so the panel does not cover the words the pointer is
  /// resting on, or to its left when the right is out of room.
  static func anchor(nearPointer pointer: CGPoint, width: CGFloat, visibleFrame: CGRect) -> SelectionPanelAnchor {
    var x = pointer.x + pointerGap
    if x + width > visibleFrame.maxX - inset {
      x = pointer.x - width - pointerGap
    }
    return anchor(
      below: CGRect(x: x, y: pointer.y, width: 0, height: 0),
      width: width,
      gap: pointerGap,
      visibleFrame: visibleFrame
    )
  }

  /// At a remembered spot, hanging from its top-left corner, moved back on
  /// screen if the display it was left on has gone or shrunk.
  static func anchor(topLeft: CGPoint, width: CGFloat, visibleFrame: CGRect) -> SelectionPanelAnchor {
    let lowest = visibleFrame.minY + inset
    let highest = visibleFrame.maxY - inset
    let top = min(max(topLeft.y, lowest + minimumHeight), highest)
    return SelectionPanelAnchor(
      x: clampedX(topLeft.x, width: width, visibleFrame: visibleFrame),
      edge: .top,
      edgeY: top,
      maxHeight: min(heightCap(for: visibleFrame), top - lowest)
    )
  }

  /// Where the reader dragged it, exactly. Not moved back on screen: doing
  /// that under the pointer, mid-drag, would fight the drag.
  static func anchor(draggedFrame frame: CGRect, visibleFrame: CGRect) -> SelectionPanelAnchor {
    SelectionPanelAnchor(
      x: frame.minX,
      edge: .top,
      edgeY: frame.maxY,
      maxHeight: max(
        minimumHeight,
        min(heightCap(for: visibleFrame), frame.maxY - visibleFrame.minY - inset)
      )
    )
  }

  private static func clampedX(_ x: CGFloat, width: CGFloat, visibleFrame: CGRect) -> CGFloat {
    let minX = visibleFrame.minX + inset
    let maxX = max(minX, visibleFrame.maxX - width - inset)
    return min(max(x, minX), maxX)
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
    .environment(\.locale, settingsStore.resolvedLocale)
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
  /// The source is a field to type into rather than a quote of what was
  /// captured: when nothing was selected, or when the reader chose to change
  /// what was.
  @State private var isEditingSource = false
  @FocusState private var isSourceFieldFocused: Bool
  /// The three parts of the panel, measured at the height each would like,
  /// so the panel can be sized to fit them rather than to a fixed guess.
  @State private var topChromeHeight: CGFloat = 0
  @State private var resultHeight: CGFloat = 0
  @State private var bottomChromeHeight: CGFloat = 0

  /// The captured text is clamped at rest so a long selection does not push
  /// the answer it was captured for off the bottom of the panel.
  private static let collapsedSourceLines = 2
  private static let expandedSourceLines = 10

  var body: some View {
    VStack(spacing: 0) {
      // Fixed at their own height, so a panel that is still too short for
      // them clips them rather than squeezing them — a squeezed part would
      // report the squeezed height, and the panel would never grow to fit it.
      VStack(spacing: 0) {
        header
        Hairline()
        controls
        Hairline()
        // A failure sits above the result instead of replacing it: an error
        // that takes the result off screen leaves nothing to recover with.
        // The accessibility case keeps the whole area, because its own
        // recovery route is already the only thing worth showing there.
        if !model.isAccessibilityPermissionError, let error = model.errorMessage {
          failureNotice(error)
          Hairline()
        }
      }
      .fixedSize(horizontal: false, vertical: true)
      .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { topChromeHeight = $0 }

      result
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

      VStack(spacing: 0) {
        Hairline()
        footer
      }
      .fixedSize(horizontal: false, vertical: true)
      .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bottomChromeHeight = $0 }
    }
    .floatingPanelBackground(palette)
    .background { keyboardShortcuts }
    .onChange(of: preferredHeight) { _, _ in reportHeight() }
    .onChange(of: model.isTranslating) { _, _ in reportHeight() }
    .onAppear(perform: startLookup)
    .onChange(of: model.selectionPopupSessionID) { _, _ in startLookup() }
    .onChange(of: model.inputText) { _, _ in
      copyResetTask?.cancel()
      didCopy = false
    }
    .onDisappear { copyResetTask?.cancel() }
    .onExitCommand {
      SelectionPanelCoordinator.shared.close()
    }
    .animation(AppMotion.state(reduceMotion: reduceMotion), value: model.outputText.isEmpty)
    .animation(AppMotion.state(reduceMotion: reduceMotion), value: model.isTranslating)
    .animation(AppMotion.state(reduceMotion: reduceMotion), value: model.errorMessage)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(L10n.tr("panel.accessibility_label"))
  }

  // MARK: - Size

  /// What the panel needs to show everything without scrolling, or zero until
  /// all three parts have been measured.
  private var preferredHeight: CGFloat {
    guard topChromeHeight > 0, resultHeight > 0, bottomChromeHeight > 0 else { return 0 }
    return topChromeHeight + resultHeight + bottomChromeHeight
  }

  private func reportHeight() {
    SelectionPanelCoordinator.shared.contentHeightDidChange(
      preferredHeight,
      allowsShrinking: !model.isTranslating
    )
  }

  // MARK: - Lookup

  /// A new lookup in this panel, whether it just opened or was already on
  /// screen for the last one.
  private func startLookup() {
    isSourceExpanded = false
    // Typed lookups — the shortcut with nothing selected — open on the field,
    // with the caret already in it.
    isEditingSource = model.inputSource == .manual
    if isEditingSource { focusSourceField() }
  }

  private func beginEditingSource() {
    isEditingSource = true
    focusSourceField()
  }

  /// The field joins the view tree in the same update that asks for it, and
  /// focus can only land on it once it is there.
  private func focusSourceField() {
    Task { @MainActor in
      isSourceFieldFocused = true
    }
  }

  private func submitTypedSource() {
    guard !normalizedInputText.isEmpty, model.selectedAction != nil else { return }
    model.translate()
  }

  // MARK: - Keyboard

  /// The keys every surface shares, bound here because the main menu does
  /// not reach a pop-up over another app: ⌘1–9 pick an action, ⌘L steps the
  /// language, ⌘R asks again, ⇧⌘C copies. Tab is the coordinator's, and ⌘.
  /// sits on the stop button while there is something to stop.
  private var keyboardShortcuts: some View {
    ZStack {
      ForEach(Array(model.popupActions.prefix(9).enumerated()), id: \.element.id) { index, action in
        Button("") { actionSelection.wrappedValue = action.id }
          .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.command])
      }
      Button("") { model.cycleTargetLanguage() }
        .keyboardShortcut("l", modifiers: [.command])
      Button("") { model.regenerate() }
        .keyboardShortcut("r", modifiers: [.command])
      Button("") {
        guard model.canCopyResult else { return }
        perform(.copy)
      }
      .keyboardShortcut("c", modifiers: [.command, .shift])
    }
    .opacity(0)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  /// The keys worth knowing right now, most useful first; the footer drops
  /// the tail when it runs out of room.
  private var keyHints: [String] {
    let zh = L10n.isChinese
    var hints: [String] = []
    if !model.outputText.isEmpty {
      let primary = model.primaryResultCommand.title
      hints.append(isSourceFieldFocused ? "⌘↩ \(primary)" : "↩ \(primary)")
    } else if let action = model.selectedAction, !normalizedInputText.isEmpty {
      hints.append("↩ \(action.displayName)")
    }
    if model.selectedAction?.availableOptions.isEmpty == false {
      hints.append(zh ? "⇥ 选项" : "⇥ option")
    }
    if model.selectedAction?.usesTargetLanguage == true, model.visibleTargetLanguages.count > 1 {
      hints.append(zh ? "⌘L 语言" : "⌘L language")
    }
    if model.popupActions.count > 1 {
      let last = min(model.popupActions.count, 9)
      hints.append(zh ? "⌘1–\(last) 动作" : "⌘1–\(last) action")
    }
    if !model.outputText.isEmpty, !model.isTranslating {
      hints.append(zh ? "⌘R 重新生成" : "⌘R again")
    }
    return hints
  }

  // MARK: - Header

  /// One line of chrome: where the text came from, whether the panel is
  /// working, and the ways out of it. Commands on the text belong in the footer.
  private var header: some View {
    HStack(spacing: AppSpacing.sm) {
      // The mark and the title are labels, not controls: waving them through
      // hands their share of the header to the drag handle behind them, so the
      // strip grabs as one piece rather than only where it happens to be bare.
      AppLogo(size: 20)
        .allowsHitTesting(false)

      Text(title)
        .font(AppFont.bodyMedium)
        .foregroundStyle(palette.foreground)
        .lineLimit(1)
        .allowsHitTesting(false)

      // A term the reader keeps coming back to says so where they are reading
      // it, which is the moment knowing it helps.
      LearningLookupBadge()

      Spacer(minLength: AppSpacing.sm)

      if model.isTranslating {
        Spinner(size: 12)

        // Closing the pop-up also calls the request off, but that costs the
        // user the result so far. Stopping is the cheaper half of it.
        IconButton(title: L10n.isChinese ? "停止 (⌘.)" : "Stop (⌘.)", symbol: "stop.fill") {
          model.stopTranslation()
        }
        .keyboardShortcut(".", modifiers: [.command])
      }

      // Where the lookup goes to grow into more than a pop-up: follow-up
      // questions, history, a longer read. It takes the lookup with it.
      IconButton(
        title: L10n.isChinese ? "在主窗口中继续" : "Continue in the main window",
        symbol: "arrow.up.left.and.arrow.down.right",
        size: .iconSmall
      ) {
        WindowCoordinator.showMain()
      }

      // Reading a result often means working next to it — looking something up
      // in the source app, switching windows — and unpinned that costs the
      // result. Pinned, only Escape or the close button takes the pop-up down.
      IconButton(
        title: isPinned
          ? (L10n.isChinese ? "取消固定：点击其他窗口时关闭浮窗" : "Unpin: close the pop-up when you click elsewhere")
          : (L10n.isChinese ? "固定浮窗：点击其他地方时保持显示" : "Keep the pop-up open when you click elsewhere"),
        symbol: isPinned ? "pin.fill" : "pin",
        size: .iconSmall,
        isOn: isPinned
      ) {
        let pinned = !isPinned
        settingsStore.settings.selectionPanelPinned = pinned
        SelectionPanelCoordinator.shared.setPinned(pinned)
      }

      IconButton(title: L10n.isChinese ? "关闭 (Escape)" : "Close (Escape)", symbol: "xmark", size: .iconSmall) {
        SelectionPanelCoordinator.shared.close()
      }
    }
    .padding(.horizontal, AppSpacing.md)
    .frame(height: AppMetrics.paneHeaderHeight)
    .background(WindowDragArea())
  }

  /// Where the text came from, which is also where Replace would write: the
  /// reader should not have to remember which window they pressed the
  /// shortcut in.
  private var title: String {
    if model.inputSource == .selection, let app = model.selectionApplicationName, !app.isEmpty {
      return L10n.isChinese ? "来自 \(app)" : "From \(app)"
    }
    return L10n.isChinese ? "查词" : "Look Up"
  }

  // MARK: - Action and source

  private var controls: some View {
    VStack(spacing: AppSpacing.sm) {
      ActionTabBar(
        actions: model.popupActions,
        selection: actionSelection,
        size: .compact,
        // The pop-up's own default, set here and nowhere else.
        defaultActionID: model.popupDefaultAction?.id,
        setDefault: { settingsStore.settings.popupDefaultActionID = $0 }
      )
      // The strip sizes to its content, so pin it to the leading edge rather
      // than letting the stack centre a half-width track.
      .frame(maxWidth: .infinity, alignment: .leading)
      if let options = model.selectedAction?.availableOptions, !options.isEmpty {
        ActionOptionsBar(
          options: options,
          selectedID: model.selectedOption?.id,
          language: model.selectedAction?.usesTargetLanguage == true
            ? settingsStore.settings.targetLanguage : nil,
          toggle: { model.toggleOption($0) }
        )
        .frame(height: AppMetrics.controlHeightSmall)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      if isEditingSource {
        sourceField
      } else {
        sourceSummary
      }
    }
    .padding(.horizontal, AppSpacing.md)
    .padding(.top, AppSpacing.sm + 2)
    .padding(.bottom, AppSpacing.sm)
  }

  /// Switching the action re-runs the pop-up on the text it already captured,
  /// which is the whole point of picking a different one here — the same
  /// contract the target-language menu in the footer follows.
  private var actionSelection: Binding<UUID> {
    Binding(
      get: { model.selectedActionID },
      set: { id in
        guard id != model.selectedActionID else { return }
        model.selectedActionID = id
        if !normalizedInputText.isEmpty {
          model.translate()
        }
      }
    )
  }

  private var sourceSummary: some View {
    HStack(alignment: .top, spacing: AppSpacing.sm) {
      Image(systemName: "quote.opening")
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(palette.faintForeground)
        .padding(.top, 2)
        .accessibilityHidden(true)
      Text(model.inputText.isEmpty ? (L10n.isChinese ? "未捕获到选中文本" : "Nothing was selected") : model.inputText)
        .font(AppFont.body)
        .foregroundStyle(
          model.inputText.isEmpty ? palette.mutedForeground : palette.secondaryForeground
        )
        .lineLimit(isSourceExpanded ? Self.expandedSourceLines : Self.collapsedSourceLines)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
      Spacer(minLength: 0)
      contextBadge
      if !model.inputText.isEmpty {
        expandSourceButton
      }
      editSourceButton
    }
    .padding(AppSpacing.sm)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(palette.muted, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
    .animation(AppMotion.state(reduceMotion: reduceMotion), value: isSourceExpanded)
  }

  /// The text to look up, typed. Return runs the action on it.
  private var sourceField: some View {
    HStack(alignment: .top, spacing: AppSpacing.sm) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(palette.faintForeground)
        .padding(.top, 2)
        .accessibilityHidden(true)
      TextField(
        sourcePlaceholder,
        text: Binding(
          get: { model.inputText },
          set: { model.editInputText($0) }
        ),
        axis: .vertical
      )
      .textFieldStyle(.plain)
      .font(AppFont.body)
      .foregroundStyle(palette.foreground)
      .lineLimit(1...Self.expandedSourceLines)
      .focused($isSourceFieldFocused)
      .onSubmit { submitTypedSource() }
      .accessibilityLabel(L10n.isChinese ? "要查的文字" : "Text to look up")
      if !model.inputText.isEmpty {
        Button {
          model.editInputText("")
          isSourceFieldFocused = true
        } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 11))
            .foregroundStyle(palette.faintForeground)
            .frame(width: AppSpacing.md, height: AppSpacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 1)
        .help(L10n.isChinese ? "清空" : "Clear")
        .accessibilityLabel(L10n.isChinese ? "清空要查的文字" : "Clear the text to look up")
      }
    }
    .padding(AppSpacing.sm)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(palette.muted, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
        .strokeBorder(isSourceFieldFocused ? palette.ring : Color.clear, lineWidth: 1)
    )
  }

  /// Says why the field is empty when the shortcut found nothing selected,
  /// so an empty pop-up does not read as a capture that broke.
  private var sourcePlaceholder: String {
    if model.selectionWasEmpty, model.inputText.isEmpty {
      return L10n.isChinese ? "没有读到选中的文字，可以直接输入要查的内容" : "Nothing was selected. Type what to look up"
    }
    return L10n.isChinese ? "输入要查的单词或句子" : "Type a word or a sentence"
  }

  /// Whether the sentence around the selection came along.
  ///
  /// Explain in Context answers a different question when it did not, and
  /// silently: the result reads like an ordinary explanation, and nothing on
  /// screen says the reading is of the words alone rather than of the words
  /// where they stand. This is that missing line.
  @ViewBuilder
  private var contextBadge: some View {
    switch model.selectionContextState {
    case .unused:
      EmptyView()
    case .captured:
      Badge(text: L10n.isChinese ? "语境" : "Context", variant: .success, symbol: "text.alignleft")
        .help(L10n.isChinese ? "已自动捕获选区周围上下文。" : "The surrounding text was captured.")
        .accessibilityLabel(L10n.isChinese ? "已自动捕获选区周围上下文。" : "Surrounding text captured")
    case .missing:
      Badge(text: L10n.isChinese ? "无语境" : "No context", variant: .warning, symbol: "exclamationmark.triangle.fill")
        .help(L10n.isChinese ? "未能捕获上下文" : model.selectionCaptureSummary)
        .accessibilityLabel(L10n.isChinese ? "未能捕获上下文" : "No surrounding text was captured")
    }
  }

  /// Capture is lossy — accessibility reads can come back partial and fall back
  /// to the clipboard — so the user has to be able to read back everything that
  /// was actually captured, not the first two lines of it.
  private var expandSourceButton: some View {
    let title = isSourceExpanded
      ? (L10n.isChinese ? "收起捕获文本" : "Show less of the captured text")
      : (L10n.isChinese ? "展开查看全部捕获文本" : "Show all of the captured text")
    return sourceGlyphButton(
      symbol: isSourceExpanded ? "chevron.up" : "chevron.down",
      title: title,
      isOn: isSourceExpanded
    ) {
      isSourceExpanded.toggle()
    }
  }

  /// Capture can pick up a word too many, or the reader wants a different
  /// form of it. Editing turns the quote into the field a typed lookup uses.
  private var editSourceButton: some View {
    sourceGlyphButton(
      symbol: "pencil",
      title: L10n.isChinese ? "修改要查的文字" : "Edit the text to look up"
    ) {
      beginEditingSource()
    }
  }

  private func sourceGlyphButton(
    symbol: String,
    title: String,
    isOn: Bool = false,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 9, weight: .semibold))
        .contentTransition(.symbolEffect(.replace))
        .foregroundStyle(palette.mutedForeground)
        // Sized against the quote glyph rather than against a control, so a
        // one-line capture keeps the height it rests at.
        .frame(width: AppSpacing.md, height: AppSpacing.md)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(.top, 1)
    .help(title)
    .accessibilityLabel(title)
    .accessibilityAddTraits(isOn ? [.isSelected] : [])
  }

  // MARK: - Result

  /// Every state of the result lives in the one scroll view, measured at its
  /// full height: the panel grows to fit it, and scrolls only past the
  /// tallest a pop-up should be.
  private var result: some View {
    ScrollView {
      resultContent
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { resultHeight = $0 }
        .overlayScrollers()
    }
    .scrollBounceBehavior(.basedOnSize)
  }

  @ViewBuilder
  private var resultContent: some View {
    if model.isAccessibilityPermissionError {
      accessibilityPermissionMessage
    } else if model.popupActions.isEmpty {
      NoActionsView()
        .padding(.vertical, AppSpacing.lg)
    } else if model.outputText.isEmpty, model.isTranslating {
      message(
        model.selectedAction?.progressTitle ?? (L10n.isChinese ? "正在处理…" : "Working…"),
        symbol: "ellipsis",
        tint: palette.mutedForeground
      )
    } else if model.outputText.isEmpty {
      readyState
    } else {
      // The panel has no follow-up thread: everything it streams is a result
      // read from the top down, so the view stays where the reader put it
      // rather than chasing the tail.
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
    }
  }

  /// Nothing has run yet. A typed lookup is run from its field, so the hint
  /// says how; a captured one waiting for the reader gets the button.
  private var readyState: some View {
    VStack(spacing: AppSpacing.sm) {
      Text(readyHint)
        .font(AppFont.body)
        .foregroundStyle(palette.mutedForeground)
      Button(model.selectedAction?.displayName ?? (L10n.isChinese ? "运行" : "Run")) {
        model.translate()
      }
      .appButton(isEditingSource ? .secondary : .brand, size: .sm, capsule: true)
      // Return belongs to the field while it is there; both would run it.
      .keyboardShortcut(isEditingSource ? nil : KeyboardShortcut(.return, modifiers: []))
      .disabled(normalizedInputText.isEmpty || model.selectedAction == nil)
    }
    .frame(maxWidth: .infinity)
    .padding(.horizontal, AppSpacing.md)
    .padding(.vertical, AppSpacing.lg)
  }

  private var readyHint: String {
    guard isEditingSource else {
      let name = model.selectedAction?.displayName ?? (L10n.isChinese ? "运行" : "run")
      return L10n.isChinese ? "按 ↩ 开始\(name)" : "Press ↩ to run \(name)"
    }
    return normalizedInputText.isEmpty
      ? (L10n.isChinese ? "输入后按 ↩ 查询" : "Type, then press ↩")
      : (L10n.isChinese ? "按 ↩ 查询" : "Press ↩ to look it up")
  }

  private var accessibilityPermissionMessage: some View {
    VStack(alignment: .leading, spacing: AppSpacing.sm) {
      Label(
        L10n.isChinese ? "需要“辅助功能”权限" : "Accessibility permission required",
        systemImage: "exclamationmark.triangle.fill"
      )
      .font(AppFont.body)
      .foregroundStyle(palette.warning)

      Text(
        L10n.isChinese
          ? "PhraseLens 需要辅助功能权限以读取其他应用中的划选文字。"
          : "PhraseLens needs accessibility permission to read selected text from other apps."
      )
      .font(AppFont.caption)
      .foregroundStyle(palette.secondaryForeground)
      .fixedSize(horizontal: false, vertical: true)

      Button(L10n.isChinese ? "打开系统设置" : "Open System Settings") {
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
        // Provider messages run long, and the answer under the notice is what
        // the reader came for.
        .lineLimit(3)
        .fixedSize(horizontal: false, vertical: true)
        .help(error)

      HStack(spacing: AppSpacing.sm) {
        Button(L10n.tr("panel.retry")) {
          model.translateWithAI()
        }
        .appButton(.secondary, size: .sm)
        .disabled(normalizedInputText.isEmpty)

        // Retrying a misconfigured provider only reproduces the error, so a
        // configuration failure also needs the route that fixes it — and from
        // this pop-up, Settings is otherwise unreachable.
        if model.isConfigurationError {
          Button(L10n.tr("panel.open_settings")) {
            WindowCoordinator.prepareForSettings()
            SettingsNavigation.show(.provider) { openSettings() }
          }
          .appButton(.secondary, size: .sm)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, AppSpacing.md)
    .padding(.vertical, AppSpacing.sm)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(L10n.tr("panel.problem_label"))
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

  /// Two groups, told apart by where they sit: what reads into the answer and
  /// acts on the text that was looked up on the left; what acts on the answer
  /// on the right, ending in its primary command.
  private var footer: some View {
    HStack(spacing: AppSpacing.xs) {
      AppSelect(
        title: L10n.isChinese ? "目标语言" : "Target language",
        selection: Binding(
          get: { settingsStore.settings.targetLanguage },
          set: { language in
            guard language != settingsStore.settings.targetLanguage else { return }
            settingsStore.settings.targetLanguage = language
            if !normalizedInputText.isEmpty {
              model.translateWithAI()
            }
          }
        ),
        options: model.visibleTargetLanguages,
        label: { $0.displayName },
        size: .sm
      )

      IconButton(
        title: model.isSpeaking(.source)
          ? (L10n.isChinese ? "停止朗读" : "Stop speaking")
          : (L10n.isChinese ? "朗读原文" : "Speak the original"),
        symbol: model.isSpeaking(.source) ? "speaker.slash.fill" : "speaker.wave.2",
        isDisabled: normalizedInputText.isEmpty
      ) {
        model.speakInput()
      }
      .accessibilityLabel(L10n.isChinese ? "朗读原文" : "Speak the original")

      IconButton(
        title: isCurrentTextCollected
          ? (L10n.isChinese ? "从生词本中移除此词" : "Remove from Vocabulary")
          : (L10n.isChinese ? "保存至生词本" : "Save this word to Vocabulary"),
        symbol: isCurrentTextCollected ? "bookmark.fill" : "bookmark",
        isDisabled: !isCurrentTextCollected && !canCollectCurrentText,
        isOn: isCurrentTextCollected
      ) {
        model.toggleCollectCurrentWord()
      }

      // The hints take the room between the two groups, and give it up first.
      footerHints
        .padding(.horizontal, AppSpacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)

      IconButton(
        title: model.isSpeaking(.result)
          ? (L10n.isChinese ? "停止朗读" : "Stop speaking")
          : (L10n.isChinese ? "朗读结果" : "Speak the result"),
        // A speaker with a bubble: the answer being spoken, told apart at a
        // glance from the plain speaker that reads the source text.
        symbol: model.isSpeaking(.result) ? "speaker.slash.fill" : "speaker.wave.2.bubble.left",
        // Half an answer is not worth hearing, but audio already playing when
        // the next translation starts still has to be stoppable.
        isDisabled: model.outputText.isEmpty
          || (model.isTranslating && !model.isSpeaking(.result))
      ) {
        model.speakOutput()
      }
      .accessibilityLabel(L10n.isChinese ? "朗读结果" : "Speak the result")

      // The action decides which commands its answer offers, and the source
      // decides which of those can run. The first is the pill; the rest sit
      // beside it as icons.
      ForEach(Array(model.offeredResultCommands.dropFirst())) { command in
        IconButton(
          title: commandHelp(command),
          symbol: command == .copy && didCopy ? "checkmark" : command.symbol,
          isDisabled: !model.canPerform(command)
        ) {
          perform(command)
        }
      }

      let primary = model.primaryResultCommand
      Button {
        perform(primary)
      } label: {
        HStack(spacing: AppSpacing.xs + 1) {
          Image(systemName: primary == .copy && didCopy ? "checkmark" : primary.symbol)
            .font(.system(size: 11, weight: .medium))
            .contentTransition(.symbolEffect(.replace))
          Text(primary == .copy && didCopy ? (L10n.isChinese ? "已拷贝" : "Copied") : primary.title)
        }
      }
      .appButton(.brand, size: .sm, capsule: true)
      .symbolEffect(.bounce, value: didCopy)
      // Return is the pop-up's primary command, as it is the writing
      // pop-up's — once there is an answer, and only while the field is not
      // taking Return to look up what was typed in it; ⌘↩ reaches it from there.
      .keyboardShortcut(primaryShortcut)
      .disabled(!model.canPerform(primary))
      .help(commandHelp(primary))
      .accessibilityLabel(commandHelp(primary))
    }
    .padding(.horizontal, AppSpacing.md)
    .frame(height: AppMetrics.paneFooterHeight + 6)
  }

  private var primaryShortcut: KeyboardShortcut? {
    guard !model.outputText.isEmpty else { return nil }
    return KeyboardShortcut(.return, modifiers: isSourceFieldFocused ? [.command] : [])
  }

  /// The key hints, as many as fit between the two button groups, in the
  /// writing pop-up's form.
  private var footerHints: some View {
    let hints = keyHints
    return ViewThatFits(in: .horizontal) {
      ForEach(Array(stride(from: hints.count, through: 1, by: -1)), id: \.self) { count in
        Text(hints.prefix(count).joined(separator: L10n.isChinese ? "　" : "  "))
          .lineLimit(1)
          .fixedSize()
      }
      Color.clear.frame(width: 0, height: 0)
    }
    .font(AppFont.caption)
    .foregroundStyle(palette.faintForeground)
    .accessibilityHidden(true)
  }

  private func perform(_ command: ResultCommand) {
    guard command == .copy else {
      model.perform(command)
      return
    }
    model.copyOutput()
    didCopy = true
    copyResetTask?.cancel()
    copyResetTask = Task { @MainActor in
      try? await Task.sleep(for: .seconds(1.6))
      guard !Task.isCancelled else { return }
      didCopy = false
    }
  }

  private func commandHelp(_ command: ResultCommand) -> String {
    guard command == .copy else {
      return command.help(sourceApplication: model.writableSource?.applicationName)
    }
    if didCopy { return L10n.isChinese ? "已拷贝" : "Copied" }
    return L10n.isChinese ? "拷贝 (⇧⌘C)" : "Copy the result (⇧⌘C)"
  }

  private var isPinned: Bool { settingsStore.settings.selectionPanelPinned }

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
