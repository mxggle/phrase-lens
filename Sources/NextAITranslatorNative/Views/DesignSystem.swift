import SwiftUI

/// Layout rhythm. Every value is a multiple of the 4-pt grid that AppKit
/// control metrics are laid out on, so custom containers align with the
/// system controls they hold.
enum AppSpacing {
  static let xxs: CGFloat = 2
  static let xs: CGFloat = 4
  static let sm: CGFloat = 8
  static let md: CGFloat = 12
  static let lg: CGFloat = 16
  static let xl: CGFloat = 20
  static let xxl: CGFloat = 28
}

enum AppMetrics {
  /// Height of a pane's header strip. Sized to hold a regular pop-up button.
  static let headerBarHeight: CGFloat = 40
  /// Height of a pane's command strip. Sized to hold small borderless buttons.
  static let footerBarHeight: CGFloat = 34
  /// Height of the window-wide status strip.
  static let statusBarHeight: CGFloat = 26

  /// Narrowest the main window can be dragged.
  static let windowMinWidth: CGFloat = 820
  /// Shortest the main window can be dragged.
  static let windowMinHeight: CGFloat = 540

  static let sidebarMinWidth: CGFloat = 176
  static let sidebarIdealWidth: CGFloat = 196
  static let sidebarMaxWidth: CGFloat = 240
  /// The sidebar floats over the detail column rather than sitting beside it,
  /// so its width is charged to the window's minimum twice: once as its own
  /// column, and once as the leading safe-area inset it pushes onto the detail
  /// column underneath. `+ 8` is the sidebar's outer margin, `- 5` the divider
  /// inside a detail column that is itself split.
  ///
  /// Whatever is left is all the minimum widths in one section may add up to.
  /// A section that asks for more does not shrink — SwiftUI centers the
  /// oversized layout in the window and clips it at both edges, which reads as
  /// a sidebar cut off on the left and detail content cut off on the right.
  /// `SelfTestRunner` enforces this, so raising a column minimum without room
  /// for it fails the self-test rather than shipping a clipped window.
  static let splitColumnBudget: CGFloat = windowMinWidth - 2 * (sidebarIdealWidth + 8) - 5

  /// Smallest usable width for one half of the translator split.
  static let paneMinWidth: CGFloat = 200
  /// Preferred width for one half of the translator split. Deliberately equal
  /// to the minimum, so the two panes open at an even split.
  static let paneIdealWidth: CGFloat = paneMinWidth

  /// Smallest usable widths for the two columns of the Actions editor.
  static let actionListMinWidth: CGFloat = 160
  static let actionListIdealWidth: CGFloat = 200
  static let actionListMaxWidth: CGFloat = 320
  static let actionEditorMinWidth: CGFloat = 240

  /// Every detail section that splits into columns, measured against
  /// `splitColumnBudget`.
  static let splitColumnMinimums: [(String, [CGFloat])] = [
    ("Translator", [paneMinWidth, paneMinWidth]),
    ("Actions", [actionListMinWidth, actionEditorMinWidth]),
  ]

  /// Height of the action tab strip. The regular strip carries a full-size
  /// label; the compact one is sized for the selection pop-up.
  static let actionTabBarHeight: CGFloat = 38
  static let compactActionTabBarHeight: CGFloat = 30

  /// Text inset inside editors and result views. Matches `NSTextView` insets.
  static let readingInset: CGFloat = 16
  static let cardRadius: CGFloat = 10
  static let panelRadius: CGFloat = 16
}

enum AppDesign {
  /// Chrome layer — window and sidebar backgrounds.
  static let canvas = Color(nsColor: .windowBackgroundColor)
  /// Content layer — anything holding editable or generated text.
  static let editorSurface = Color(nsColor: .textBackgroundColor)
  /// Low-contrast fill for inline groupings inside the content layer.
  static let subtleFill = Color.primary.opacity(0.05)
}

enum AppMotion {
  /// Short, state-driven layout transition. `nil` under Reduce Motion.
  static func state(reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : .snappy(duration: 0.24, extraBounce: 0.02)
  }

  /// Brief spring for user-initiated control feedback. `nil` under Reduce Motion.
  static func interactive(reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : .spring(duration: 0.36, bounce: 0.2)
  }
}

// MARK: - Pane chrome

/// A header or footer strip attached to a content pane.
///
/// The strip carries the system bar material and a single hairline on the edge
/// facing the content, which is how AppKit separates chrome from a text view.
struct PaneBar<Content: View>: View {
  enum Placement {
    case header
    case footer

    var height: CGFloat {
      switch self {
      case .header: AppMetrics.headerBarHeight
      case .footer: AppMetrics.footerBarHeight
      }
    }
  }

  let placement: Placement
  @ViewBuilder var content: Content

  init(_ placement: Placement, @ViewBuilder content: () -> Content) {
    self.placement = placement
    self.content = content()
  }

  var body: some View {
    VStack(spacing: 0) {
      if placement == .footer { Divider() }
      HStack(spacing: AppSpacing.sm) {
        content
      }
      .padding(.horizontal, AppSpacing.md)
      .frame(height: placement.height)
      if placement == .header { Divider() }
    }
    .background(.bar)
  }
}

/// Flat, single-row action switcher.
///
/// A tab strip keeps every action one click away and shows which one is armed
/// without opening a menu. The row scrolls horizontally, so custom actions
/// extend the strip instead of squeezing the labels, and the selected tab is
/// scrolled into view whenever it changes from elsewhere.
struct ActionTabBar: View {
  enum Size {
    /// Window chrome under the toolbar.
    case regular
    /// Selection pop-up chrome, where vertical space belongs to the result.
    case compact

    var height: CGFloat {
      switch self {
      case .regular: AppMetrics.actionTabBarHeight
      case .compact: AppMetrics.compactActionTabBarHeight
      }
    }

    var font: Font {
      switch self {
      case .regular: .subheadline
      case .compact: .caption
      }
    }

    var horizontalPadding: CGFloat {
      switch self {
      case .regular: AppSpacing.md
      case .compact: AppSpacing.sm
      }
    }
  }

  let actions: [TranslationAction]
  @Binding var selection: UUID
  var size: Size = .regular

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Namespace private var indicatorNamespace

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 0) {
          ForEach(actions) { action in
            tab(action).id(action.id)
          }
        }
        .padding(.horizontal, AppSpacing.sm)
        .animation(AppMotion.state(reduceMotion: reduceMotion), value: selection)
      }
      .frame(height: size.height)
      .onAppear { proxy.scrollTo(selection, anchor: .center) }
      .onChange(of: selection) { _, newValue in
        withAnimation(AppMotion.state(reduceMotion: reduceMotion)) {
          proxy.scrollTo(newValue, anchor: .center)
        }
      }
    }
    .background(.bar)
    .overlay(alignment: .bottom) { Divider() }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Action")
  }

  private func tab(_ action: TranslationAction) -> some View {
    let isSelected = action.id == selection
    return Button {
      guard action.id != selection else { return }
      selection = action.id
    } label: {
      VStack(spacing: 0) {
        Label(action.name, systemImage: action.mode?.symbol ?? "sparkles")
          .labelStyle(.titleAndIcon)
          .font(size.font.weight(isSelected ? .semibold : .regular))
          .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
          .lineLimit(1)
          .fixedSize()
          .padding(.horizontal, size.horizontalPadding)
          .frame(maxHeight: .infinity)
        indicator(isSelected: isSelected)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(action.name)
    .accessibilityLabel(action.name)
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
  }

  /// The moving underline is one view handed between tabs, so it slides rather
  /// than blinking out of one label and into the next.
  @ViewBuilder
  private func indicator(isSelected: Bool) -> some View {
    ZStack {
      Color.clear.frame(height: 2)
      if isSelected {
        Capsule()
          .fill(.primary)
          .frame(height: 2)
          .matchedGeometryEffect(id: "selectedActionTab", in: indicatorNamespace)
      }
    }
    .padding(.horizontal, size.horizontalPadding - AppSpacing.xs)
  }
}

/// Small live-state dot. Used for provider reachability and translation state.
struct StatusDot: View {
  let color: Color
  var isActive = false

  var body: some View {
    Circle()
      .fill(color)
      .frame(width: 7, height: 7)
      .opacity(isActive ? 1 : 0.85)
  }
}

/// Icon-only bar command. Icon-only controls need a name for VoiceOver and a
/// tooltip for pointer users, so both are derived from the same title.
struct BarButton: View {
  let title: String
  let symbol: String
  var isDisabled = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol)
        .contentTransition(.symbolEffect(.replace))
        .frame(width: 18, height: 18)
    }
    .buttonStyle(.borderless)
    .disabled(isDisabled)
    .help(title)
    .accessibilityLabel(title)
  }
}

extension View {
  /// Content-layer pane: solid text surface, no stroke. Hierarchy inside the
  /// pane comes from the bars above and below it, not from decoration.
  func contentPane() -> some View {
    background(AppDesign.editorSurface)
  }

  /// Floating panel background. macOS 26 draws the system glass material;
  /// earlier systems fall back to the standard window material.
  @ViewBuilder
  func floatingPanelBackground(radius: CGFloat = AppMetrics.panelRadius) -> some View {
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    if #available(macOS 26.0, *) {
      glassEffect(.regular, in: shape)
        .clipShape(shape)
    } else {
      background(.regularMaterial, in: shape)
        .clipShape(shape)
        .overlay {
          shape.stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
        }
    }
  }
}
