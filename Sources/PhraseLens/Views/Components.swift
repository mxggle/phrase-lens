import AppKit
import SwiftUI

// MARK: - Surfaces

extension View {
  /// A raised content surface: fill, hairline, and the radius that goes with
  /// it. Everything that holds content sits on one of these, so the canvas
  /// behind them stays empty and the hierarchy is legible without decoration.
  func cardSurface(
    _ palette: AppPalette,
    radius: CGFloat = AppRadius.xl,
    fill: Color? = nil,
    stroke: Color? = nil,
    elevated: Bool = false
  ) -> some View {
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    return background(fill ?? palette.surface, in: shape)
      .overlay {
        shape.strokeBorder(stroke ?? palette.border, lineWidth: 1)
      }
      .clipShape(shape)
      .shadow(
        color: elevated ? palette.shadowStrong : palette.shadow,
        radius: elevated ? 18 : 2,
        y: elevated ? 8 : 1
      )
  }

  /// Keyboard focus indicator. A ring outside the control's own border, so it
  /// reads at a glance without changing the control's metrics.
  func focusRing(_ palette: AppPalette, isFocused: Bool, radius: CGFloat) -> some View {
    overlay {
      RoundedRectangle(cornerRadius: radius + 2, style: .continuous)
        .strokeBorder(palette.ring, lineWidth: 3)
        .padding(-2)
        .opacity(isFocused ? 1 : 0)
    }
  }

  /// Swaps the pointer while it is over a control that resizes something.
  func resizeCursor(horizontal: Bool) -> some View {
    onHover { inside in
      if inside {
        (horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
      } else {
        NSCursor.pop()
      }
    }
  }
}

/// A one-pixel rule in the palette's border color. `Divider()` picks up an
/// AppKit separator color that does not belong to this ramp.
struct Hairline: View {
  @Environment(\.palette) private var palette
  var axis: Axis = .horizontal

  var body: some View {
    Rectangle()
      .fill(palette.border)
      .frame(
        width: axis == .vertical ? 1 : nil,
        height: axis == .horizontal ? 1 : nil
      )
      .accessibilityHidden(true)
  }
}

// MARK: - Buttons

enum AppButtonVariant {
  /// The one command that runs the view's work.
  case primary
  /// A filled but unaccented command.
  case secondary
  /// A bordered command on a content surface.
  case outline
  /// Chrome-free command, for bars and rows.
  case ghost
  case destructive
  /// Chrome-free destructive command.
  case destructiveGhost
}

enum AppControlSize {
  case xs
  case sm
  case md
  case lg
  /// Square, icon-only.
  case icon
  /// Square, icon-only, bar sized.
  case iconSmall

  var height: CGFloat {
    switch self {
    case .xs: 22
    case .sm: AppMetrics.controlHeightSmall
    case .md: AppMetrics.controlHeight
    case .lg: AppMetrics.controlHeightLarge
    case .icon: AppMetrics.controlHeight
    case .iconSmall: AppMetrics.controlHeightSmall
    }
  }

  var horizontalPadding: CGFloat {
    switch self {
    case .xs: 7
    case .sm: 10
    case .md: 13
    case .lg: 17
    case .icon, .iconSmall: 0
    }
  }

  var font: Font {
    switch self {
    case .xs: AppFont.captionMedium
    case .sm, .iconSmall: AppFont.label
    case .md, .icon: AppFont.bodyMedium
    case .lg: Font.system(size: 14, weight: .medium)
    }
  }

  var radius: CGFloat {
    switch self {
    case .xs: AppRadius.sm
    case .sm, .iconSmall: AppRadius.md
    case .md, .icon: AppRadius.md
    case .lg: AppRadius.lg
    }
  }

  var isSquare: Bool { self == .icon || self == .iconSmall }
}

/// The app's only button chrome.
///
/// Variants map to intent, not to appearance: a view picks `.primary` because
/// the command is the point of the view, not because it wants a dark button.
struct AppButtonStyle: ButtonStyle {
  var variant: AppButtonVariant = .secondary
  var size: AppControlSize = .md
  var fullWidth = false

  func makeBody(configuration: Configuration) -> some View {
    Chrome(
      configuration: configuration,
      variant: variant,
      size: size,
      fullWidth: fullWidth
    )
  }

  private struct Chrome: View {
    let configuration: Configuration
    let variant: AppButtonVariant
    let size: AppControlSize
    let fullWidth: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
      configuration.label
        .font(size.font)
        .lineLimit(1)
        .foregroundStyle(foreground)
        .padding(.horizontal, size.horizontalPadding)
        .frame(height: size.height)
        .frame(width: size.isSquare ? size.height : nil)
        .frame(maxWidth: fullWidth ? .infinity : nil)
        .background(background, in: shape)
        .overlay {
          if let border {
            shape.strokeBorder(border, lineWidth: 1)
          }
        }
        .contentShape(shape)
        .opacity(isEnabled ? 1 : 0.42)
        .scaleEffect(configuration.isPressed && isEnabled ? 0.975 : 1)
        .animation(AppMotion.hover(reduceMotion: reduceMotion), value: isHovering)
        .animation(AppMotion.hover(reduceMotion: reduceMotion), value: configuration.isPressed)
        .onHover { isHovering = $0 && isEnabled }
    }

    private var shape: RoundedRectangle {
      RoundedRectangle(cornerRadius: size.radius, style: .continuous)
    }

    /// Hover and press are one ramp: press reuses the hover fill so a click
    /// never flashes a third color.
    private var isActive: Bool { isEnabled && (isHovering || configuration.isPressed) }

    private var background: Color {
      switch variant {
      case .primary: isActive ? palette.primaryHover : palette.primary
      case .secondary: isActive ? palette.mutedHover : palette.muted
      case .outline: isActive ? palette.muted : palette.surface
      case .ghost: isActive ? palette.muted : .clear
      case .destructive: palette.destructive.opacity(isActive ? 0.86 : 1)
      case .destructiveGhost: isActive ? palette.destructiveFill : .clear
      }
    }

    private var foreground: Color {
      switch variant {
      case .primary: palette.primaryForeground
      case .secondary, .outline: palette.foreground
      case .ghost: isActive ? palette.foreground : palette.secondaryForeground
      case .destructive: palette.destructiveForeground
      case .destructiveGhost: palette.destructive
      }
    }

    private var border: Color? {
      switch variant {
      case .outline: isActive ? palette.borderStrong : palette.border
      case .primary, .secondary, .ghost, .destructive, .destructiveGhost: nil
      }
    }
  }
}

extension View {
  func appButton(
    _ variant: AppButtonVariant = .secondary,
    size: AppControlSize = .md,
    fullWidth: Bool = false
  ) -> some View {
    buttonStyle(AppButtonStyle(variant: variant, size: size, fullWidth: fullWidth))
  }
}

/// Icon-only command. An icon-only control needs a name for VoiceOver and a
/// tooltip for pointer users, so both come from the same title.
struct IconButton: View {
  let title: String
  let symbol: String
  var variant: AppButtonVariant = .ghost
  var size: AppControlSize = .iconSmall
  var isDisabled = false
  var isOn = false
  let action: () -> Void

  @Environment(\.palette) private var palette

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: size == .icon ? 14 : 12.5, weight: .medium))
        .contentTransition(.symbolEffect(.replace))
    }
    .appButton(isOn ? .secondary : variant, size: size)
    .disabled(isDisabled)
    .help(title)
    .accessibilityLabel(title)
    .accessibilityAddTraits(isOn ? [.isSelected] : [])
  }
}

/// A command label that drops its title when the bar it sits in runs out of
/// room. The accessibility label and tooltip stay on the button, so the
/// command keeps its name even when the glyph is all that is drawn.
struct AdaptiveLabel: View {
  let title: String
  let symbol: String
  var iconOnly = false

  var body: some View {
    HStack(spacing: AppSpacing.xs + 1) {
      Image(systemName: symbol)
        .font(.system(size: 11, weight: .medium))
      if !iconOnly {
        Text(title)
      }
    }
    .accessibilityHidden(true)
  }
}

// MARK: - Badge

enum AppBadgeVariant {
  case neutral
  case solid
  case outline
  case success
  case warning
  case danger
}

/// A small state label. Carries meaning that would otherwise need a sentence.
struct Badge: View {
  let text: String
  var variant: AppBadgeVariant = .neutral
  var symbol: String?

  @Environment(\.palette) private var palette

  var body: some View {
    HStack(spacing: 3) {
      if let symbol {
        Image(systemName: symbol)
          .font(.system(size: 9, weight: .bold))
      }
      Text(text)
        .font(AppFont.captionMedium)
        .lineLimit(1)
    }
    .foregroundStyle(foreground)
    .padding(.horizontal, symbol == nil ? 7 : 6)
    .padding(.vertical, 2.5)
    .background(background, in: Capsule(style: .continuous))
    .overlay {
      if variant == .outline {
        Capsule(style: .continuous).strokeBorder(palette.border, lineWidth: 1)
      }
    }
    .fixedSize()
  }

  private var background: Color {
    switch variant {
    case .neutral: palette.muted
    case .solid: palette.primary
    case .outline: .clear
    case .success: palette.success.opacity(0.14)
    case .warning: palette.warning.opacity(0.16)
    case .danger: palette.destructiveFill
    }
  }

  private var foreground: Color {
    switch variant {
    case .neutral: palette.mutedForeground
    case .solid: palette.primaryForeground
    case .outline: palette.mutedForeground
    case .success: palette.success
    case .warning: palette.warning
    case .danger: palette.destructive
    }
  }
}

/// A single key or key combination, drawn as keycaps.
struct KeyCombo: View {
  let combination: String
  var size: CGFloat = 10

  @Environment(\.palette) private var palette

  var body: some View {
    HStack(spacing: 2) {
      ForEach(Array(combination.enumerated()), id: \.offset) { _, character in
        Text(String(character))
          .font(.system(size: size, weight: .semibold))
          .foregroundStyle(palette.mutedForeground)
          .frame(minWidth: size + 7, minHeight: size + 7)
          .padding(.horizontal, 2)
          .background(palette.muted, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
          .overlay {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
              .strokeBorder(palette.border, lineWidth: 1)
          }
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(combination)
  }
}

// MARK: - State indicators

/// Small live-state dot. A halo, not an animation, carries "active", so the
/// indicator stays readable under Reduce Motion.
struct StatusDot: View {
  let color: Color
  var isActive = false
  var size: CGFloat = 7

  var body: some View {
    Circle()
      .fill(color)
      .frame(width: size, height: size)
      .overlay {
        Circle()
          .strokeBorder(color.opacity(isActive ? 0.28 : 0), lineWidth: 3.5)
          .padding(-3.5)
      }
      .accessibilityHidden(true)
  }
}

/// Indeterminate progress that matches the type ramp instead of the system
/// spinner's fixed metrics. Falls back to a static ring under Reduce Motion.
struct Spinner: View {
  var size: CGFloat = 14
  var lineWidth: CGFloat = 1.8

  @Environment(\.palette) private var palette
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isSpinning = false

  var body: some View {
    Circle()
      .trim(from: 0, to: 0.72)
      .stroke(palette.mutedForeground, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
      .frame(width: size, height: size)
      .rotationEffect(.degrees(isSpinning ? 360 : 0))
      .animation(
        reduceMotion ? nil : .linear(duration: 0.85).repeatForever(autoreverses: false),
        value: isSpinning
      )
      .onAppear { isSpinning = true }
      .accessibilityHidden(true)
  }
}

// MARK: - Section headings

/// Small tracked-out heading above a group. Used in the sidebar and in
/// settings, where a full-weight title would outrank the content it labels.
struct Eyebrow: View {
  let text: String

  @Environment(\.palette) private var palette

  var body: some View {
    Text(text.uppercased())
      .font(AppFont.overline)
      .tracking(0.7)
      .foregroundStyle(palette.faintForeground)
      .accessibilityLabel(text)
  }
}

// MARK: - Empty state

/// The one shape for "there is nothing here yet". A glyph tile, a title, a
/// sentence that says what would put something here, and at most one command.
struct EmptyState<Actions: View>: View {
  let symbol: String
  let title: String
  let message: String
  @ViewBuilder var actions: Actions

  @Environment(\.palette) private var palette

  init(
    symbol: String,
    title: String,
    message: String,
    @ViewBuilder actions: () -> Actions = { EmptyView() }
  ) {
    self.symbol = symbol
    self.title = title
    self.message = message
    self.actions = actions()
  }

  var body: some View {
    // An empty state is the tallest thing a pane can hold while holding
    // nothing, so it is what overflows first when the panes stack in a short
    // window. Each rung drops the least useful part — the glyph, then the
    // sentence — rather than letting the pane push past the window edge.
    ViewThatFits(in: .vertical) {
      stack(showsGlyph: true, padding: AppSpacing.xxl)
      stack(showsGlyph: true, padding: AppSpacing.md)
      stack(showsGlyph: false, padding: AppSpacing.md)
      stack(showsGlyph: false, padding: AppSpacing.sm, showsMessage: false)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(title). \(message)")
  }

  private func stack(
    showsGlyph: Bool,
    padding: CGFloat,
    showsMessage: Bool = true
  ) -> some View {
    VStack(spacing: showsGlyph ? AppSpacing.md : AppSpacing.sm) {
      if showsGlyph {
        Image(systemName: symbol)
          .font(.system(size: 20, weight: .regular))
          .foregroundStyle(palette.mutedForeground)
          .frame(width: 52, height: 52)
          .background(
            palette.muted,
            in: RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
          )
          .overlay {
            RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
              .strokeBorder(palette.border, lineWidth: 1)
          }
          .accessibilityHidden(true)
      }

      VStack(spacing: AppSpacing.xs) {
        Text(title)
          .font(AppFont.title)
          .foregroundStyle(palette.foreground)
        if showsMessage {
          Text(message)
            .font(AppFont.labelRegular)
            .foregroundStyle(palette.mutedForeground)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 320)
        }
      }

      actions
    }
    .padding(padding)
    .frame(maxWidth: .infinity)
  }
}

// MARK: - Inputs

/// Text field chrome. The field itself stays a plain `TextField`, so macOS
/// keeps supplying selection, dictation, and the correct input behavior.
struct AppTextField: View {
  let placeholder: String
  @Binding var text: String
  var symbol: String?
  var isSecure = false
  var size: AppControlSize = .md
  var monospaced = false
  var onSubmit: (() -> Void)?

  @Environment(\.palette) private var palette
  @Environment(\.isEnabled) private var isEnabled
  @FocusState private var isFocused: Bool

  var body: some View {
    HStack(spacing: AppSpacing.sm) {
      if let symbol {
        Image(systemName: symbol)
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(isFocused ? palette.secondaryForeground : palette.faintForeground)
          .accessibilityHidden(true)
      }

      Group {
        if isSecure {
          SecureField(placeholder, text: $text)
        } else {
          TextField(placeholder, text: $text)
        }
      }
      .textFieldStyle(.plain)
      .font(monospaced ? AppFont.mono : size.font)
      .foregroundStyle(palette.foreground)
      .focused($isFocused)
      .onSubmit { onSubmit?() }

      if !text.isEmpty, symbol != nil {
        Button {
          text = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 11))
            .foregroundStyle(palette.faintForeground)
        }
        .buttonStyle(.plain)
        .help("Clear")
        .accessibilityLabel("Clear \(placeholder)")
      }
    }
    .padding(.horizontal, AppSpacing.sm + 2)
    .frame(height: size.height)
    .background(palette.surface, in: shape)
    .overlay { shape.strokeBorder(isFocused ? palette.borderStrong : palette.border, lineWidth: 1) }
    .focusRing(palette, isFocused: isFocused, radius: AppRadius.md)
    .opacity(isEnabled ? 1 : 0.5)
    .animation(.easeOut(duration: 0.12), value: isFocused)
  }

  private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
  }
}

/// Multi-line input with the same chrome as `AppTextField`.
struct AppTextEditor: View {
  @Binding var text: String
  var placeholder: String = ""
  var minHeight: CGFloat = 96
  var monospaced = true
  var fontSize: Double = 12

  @Environment(\.palette) private var palette
  @FocusState private var isFocused: Bool

  var body: some View {
    ZStack(alignment: .topLeading) {
      TextEditor(text: $text)
        .font(.system(size: fontSize, design: monospaced ? .monospaced : .default))
        .foregroundStyle(palette.foreground)
        .scrollContentBackground(.hidden)
        .focused($isFocused)
        .padding(.horizontal, AppSpacing.sm - 1)
        .padding(.vertical, AppSpacing.sm - 2)

      if text.isEmpty, !placeholder.isEmpty {
        Text(placeholder)
          .font(.system(size: fontSize, design: monospaced ? .monospaced : .default))
          .foregroundStyle(palette.faintForeground)
          .padding(.horizontal, AppSpacing.sm + 4)
          .padding(.vertical, AppSpacing.sm - 2)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
    }
    .frame(minHeight: minHeight, alignment: .topLeading)
    .background(palette.surface, in: shape)
    .overlay { shape.strokeBorder(isFocused ? palette.borderStrong : palette.border, lineWidth: 1) }
    .focusRing(palette, isFocused: isFocused, radius: AppRadius.md)
    .animation(.easeOut(duration: 0.12), value: isFocused)
  }

  private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
  }
}

/// Dropdown built on `Menu`, so the list itself is a real AppKit menu with
/// system keyboard handling, while the trigger matches the app's controls.
struct AppSelect<Value: Hashable>: View {
  let title: String
  @Binding var selection: Value
  let options: [Value]
  let label: (Value) -> String
  var size: AppControlSize = .sm
  var symbol: String?
  var fillsWidth = false

  @Environment(\.palette) private var palette
  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovering = false

  var body: some View {
    Menu {
      ForEach(options, id: \.self) { option in
        Button {
          selection = option
        } label: {
          if option == selection {
            Label(label(option), systemImage: "checkmark")
          } else {
            Text(label(option))
          }
        }
      }
    } label: {
      HStack(spacing: AppSpacing.xs + 2) {
        if let symbol {
          Image(systemName: symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(palette.faintForeground)
        }
        Text(label(selection))
          .font(size.font)
          .foregroundStyle(palette.foreground)
          .lineLimit(1)
        if fillsWidth { Spacer(minLength: AppSpacing.xs) }
        Image(systemName: "chevron.up.chevron.down")
          .font(.system(size: 8, weight: .semibold))
          .foregroundStyle(palette.faintForeground)
      }
      .padding(.horizontal, AppSpacing.sm + 1)
      .frame(height: size.height)
      .frame(maxWidth: fillsWidth ? .infinity : nil)
      .background(isHovering ? palette.muted : palette.surface, in: shape)
      .overlay { shape.strokeBorder(palette.border, lineWidth: 1) }
      .contentShape(shape)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize(horizontal: !fillsWidth, vertical: true)
    .opacity(isEnabled ? 1 : 0.45)
    .onHover { isHovering = $0 && isEnabled }
    .animation(.easeOut(duration: 0.12), value: isHovering)
    .help(title)
    .accessibilityLabel(title)
    .accessibilityValue(label(selection))
  }

  private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
  }
}

/// Switch, for settings that take effect the moment they change.
struct AppSwitchStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    Chrome(configuration: configuration)
  }

  private struct Chrome: View {
    let configuration: Configuration

    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
      Button {
        configuration.isOn.toggle()
      } label: {
        Capsule(style: .continuous)
          .fill(configuration.isOn ? palette.primary : palette.accentFill)
          .frame(width: 38, height: 22)
          .overlay(alignment: configuration.isOn ? .trailing : .leading) {
            Circle()
              .fill(configuration.isOn ? palette.primaryForeground : palette.surface)
              .frame(width: 17, height: 17)
              .shadow(color: palette.shadow, radius: 1, y: 0.5)
              .padding(.horizontal, 2.5)
          }
          .contentShape(Capsule(style: .continuous))
      }
      .buttonStyle(.plain)
      .opacity(isEnabled ? 1 : 0.42)
      .animation(AppMotion.interactive(reduceMotion: reduceMotion), value: configuration.isOn)
      .accessibilityRepresentation {
        Toggle(isOn: configuration.$isOn) { configuration.label }
      }
    }
  }
}

/// Selectable chip, for a set of small on/off choices shown as a group.
struct ChipToggleStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    Chrome(configuration: configuration)
  }

  private struct Chrome: View {
    let configuration: Configuration

    @Environment(\.palette) private var palette
    @State private var isHovering = false

    var body: some View {
      Button {
        configuration.isOn.toggle()
      } label: {
        HStack(spacing: AppSpacing.xs + 1) {
          Image(systemName: configuration.isOn ? "checkmark" : "plus")
            .font(.system(size: 8.5, weight: .bold))
            .foregroundStyle(
              configuration.isOn ? palette.primaryForeground : palette.faintForeground
            )
          configuration.label
            .font(AppFont.label)
            .lineLimit(1)
        }
        .foregroundStyle(
          configuration.isOn ? palette.primaryForeground : palette.secondaryForeground
        )
        .padding(.horizontal, AppSpacing.sm + 1)
        .frame(height: AppMetrics.controlHeightSmall)
        .background(fill, in: Capsule(style: .continuous))
        .overlay {
          if !configuration.isOn {
            Capsule(style: .continuous).strokeBorder(palette.border, lineWidth: 1)
          }
        }
        .contentShape(Capsule(style: .continuous))
      }
      .buttonStyle(.plain)
      .onHover { isHovering = $0 }
      .animation(.easeOut(duration: 0.12), value: isHovering)
      .animation(.easeOut(duration: 0.12), value: configuration.isOn)
      .accessibilityRepresentation {
        Toggle(isOn: configuration.$isOn) { configuration.label }
      }
    }

    private var fill: Color {
      if configuration.isOn {
        return palette.primary
      }
      return isHovering ? palette.muted : .clear
    }
  }
}

// MARK: - Tabs

/// Segmented switcher: a muted track with one raised pill on the armed option.
///
/// The strip never scrolls. A 30-pt scroller has no wheel axis, no visible edge
/// affordance, and clips labels mid-word, so instead the bar renders the widest
/// variant that fits the space it was offered — every label, then the armed
/// label with glyphs for the rest, then glyphs alone — and drops to a pull-down
/// when even glyphs would overflow. Every tab keeps its name in a tooltip and
/// in its accessibility label, so the narrow variants stay identifiable.
struct ActionTabBar: View {
  enum Size {
    /// Window chrome.
    case regular
    /// Selection pop-up chrome, where vertical space belongs to the result.
    case compact

    var height: CGFloat {
      switch self {
      case .regular: 30
      case .compact: 26
      }
    }

    var font: Font {
      switch self {
      case .regular: AppFont.label
      case .compact: AppFont.captionMedium
      }
    }

    var horizontalPadding: CGFloat {
      switch self {
      case .regular: AppSpacing.md - 1
      case .compact: AppSpacing.sm + 1
      }
    }

    var iconSize: CGFloat {
      switch self {
      case .regular: 11
      case .compact: 10
      }
    }
  }

  /// How many names a variant spells out. Ordered widest to narrowest.
  private enum Labels: String {
    case all
    case armedOnly
    case none
  }

  let actions: [TranslationAction]
  @Binding var selection: UUID
  var size: Size = .regular

  @Environment(\.palette) private var palette
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Namespace private var pill

  var body: some View {
    ViewThatFits(in: .horizontal) {
      strip(labels: .all)
      strip(labels: .armedOnly)
      strip(labels: .none)
      pullDown
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Action")
  }

  private var armedAction: TranslationAction? {
    actions.first { $0.id == selection } ?? actions.first
  }

  private func select(_ id: UUID) {
    guard id != selection else { return }
    selection = id
  }

  // MARK: - Variants

  private func strip(labels: Labels) -> some View {
    HStack(spacing: 2) {
      ForEach(actions) { action in
        tab(action, labels: labels)
      }
    }
    .padding(3)
    .frame(height: size.height + 6)
    .background(track)
    .animation(AppMotion.state(reduceMotion: reduceMotion), value: selection)
  }

  /// Last resort, for a container too narrow for one glyph per action: the
  /// armed action reads as a pill, and the rest of the list is one click away.
  private var pullDown: some View {
    Menu {
      ForEach(actions) { action in
        Button {
          select(action.id)
        } label: {
          if action.id == selection {
            Label(action.name, systemImage: "checkmark")
          } else {
            Text(action.name)
          }
        }
      }
    } label: {
      HStack(spacing: AppSpacing.xs + 1) {
        Image(systemName: armedAction?.mode?.symbol ?? "sparkles")
          .font(.system(size: size.iconSize, weight: .medium))
          .foregroundStyle(palette.foreground)
        Text(armedAction?.name ?? "Action")
          .font(size.font)
          .foregroundStyle(palette.foreground)
          .lineLimit(1)
          .truncationMode(.tail)
        Image(systemName: "chevron.up.chevron.down")
          .font(.system(size: 8, weight: .semibold))
          .foregroundStyle(palette.faintForeground)
      }
      .padding(.horizontal, size.horizontalPadding)
      .frame(height: size.height)
      .background { armedPill }
      .contentShape(Rectangle())
      .padding(3)
      .frame(height: size.height + 6)
      .background(track)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .help(armedAction.map { "Action: \($0.name)" } ?? "Action")
  }

  // MARK: - Parts

  private var track: some View {
    RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
      .fill(palette.muted)
      .overlay {
        RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
          .strokeBorder(palette.border, lineWidth: 1)
      }
  }

  /// The raised surface under the armed option.
  private var armedPill: some View {
    let shape = RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
    return shape
      .fill(palette.surfaceElevated)
      .overlay { shape.strokeBorder(palette.borderStrong, lineWidth: 1) }
      .shadow(color: palette.shadow, radius: 1.5, y: 1)
  }

  private func tab(_ action: TranslationAction, labels: Labels) -> some View {
    let isSelected = action.id == selection
    let showsName = labels == .all || (labels == .armedOnly && isSelected)
    return Button {
      select(action.id)
    } label: {
      HStack(spacing: AppSpacing.xs + 1) {
        Image(systemName: action.mode?.symbol ?? "sparkles")
          .font(.system(size: size.iconSize, weight: .medium))
        if showsName {
          Text(action.name)
            .font(size.font)
            .lineLimit(1)
        }
      }
      .foregroundStyle(isSelected ? palette.foreground : palette.mutedForeground)
      .fixedSize()
      .padding(.horizontal, size.horizontalPadding)
      .frame(height: size.height)
      .background {
        if isSelected {
          // One geometry group per variant: `ViewThatFits` builds all of them
          // to measure, and a shared id would put several sources in one group.
          armedPill
            .matchedGeometryEffect(id: "armedActionTab-\(labels.rawValue)", in: pill)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(action.name)
    .accessibilityLabel(action.name)
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
  }
}

// MARK: - Rows

/// A selectable row in the sidebar or in a source list.
struct NavRow: View {
  let title: String
  let symbol: String
  let isSelected: Bool
  var subtitle: String?
  var trailing: String?
  var collapsed = false
  let action: () -> Void

  @Environment(\.palette) private var palette
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: AppSpacing.sm + 2) {
        Image(systemName: symbol)
          .font(.system(size: 13, weight: .medium))
          .frame(width: 16)
          .foregroundStyle(isSelected ? palette.foreground : palette.mutedForeground)

        if !collapsed {
          VStack(alignment: .leading, spacing: 1) {
            Text(title)
              .font(AppFont.bodyMedium)
              .foregroundStyle(isSelected ? palette.foreground : palette.secondaryForeground)
              .lineLimit(1)
            if let subtitle {
              Text(subtitle)
                .font(AppFont.caption)
                .foregroundStyle(palette.faintForeground)
                .lineLimit(1)
            }
          }
          Spacer(minLength: AppSpacing.xs)
          if let trailing, !trailing.isEmpty {
            Text(trailing)
              .font(AppFont.caption)
              .monospacedDigit()
              .foregroundStyle(palette.faintForeground)
          }
        }
      }
      .padding(.horizontal, collapsed ? 0 : AppSpacing.sm + 2)
      .frame(height: 34)
      .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
      .background(fill, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
      .contentShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .animation(AppMotion.hover(reduceMotion: reduceMotion), value: isHovering)
    .animation(AppMotion.hover(reduceMotion: reduceMotion), value: isSelected)
    .help(collapsed ? title : "")
    .accessibilityLabel(title)
    .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : [.isButton])
  }

  private var fill: Color {
    if isSelected { return palette.accentFill }
    return isHovering ? palette.muted : .clear
  }
}

// MARK: - Settings scaffolding

/// A titled group of settings. Replaces `Form`'s grouped sections so the
/// rows, dividers, and radii come from this palette.
struct SettingsCard<Content: View>: View {
  let title: String
  var caption: String?
  /// Cards whose whole content is one bordered control drop their own chrome,
  /// so the group does not draw a second outline around the first.
  var showsChrome = true
  @ViewBuilder var content: Content

  @Environment(\.palette) private var palette

  init(
    _ title: String,
    caption: String? = nil,
    showsChrome: Bool = true,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.caption = caption
    self.showsChrome = showsChrome
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: AppSpacing.sm) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(AppFont.heading)
          .foregroundStyle(palette.foreground)
        if let caption {
          Text(caption)
            .font(AppFont.caption)
            .foregroundStyle(palette.mutedForeground)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(.horizontal, AppSpacing.xs)

      Group {
        if showsChrome {
          VStack(spacing: 0) { content }
            .cardSurface(palette)
        } else {
          VStack(spacing: 0) { content }
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(title)
  }
}

/// One labelled control inside a `SettingsCard`. Stacks its label above the
/// control when the card is too narrow to keep them on one line.
struct SettingsRow<Control: View>: View {
  let title: String
  var detail: String?
  var stacksControl = false
  @ViewBuilder var control: Control

  @Environment(\.palette) private var palette
  @Environment(\.layoutWidth) private var layoutWidth

  init(
    _ title: String,
    detail: String? = nil,
    stacksControl: Bool = false,
    @ViewBuilder control: () -> Control
  ) {
    self.title = title
    self.detail = detail
    self.stacksControl = stacksControl
    self.control = control()
  }

  var body: some View {
    Group {
      if stacksControl || layoutWidth.isCompact {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
          labelBlock
          control.frame(maxWidth: .infinity, alignment: .leading)
        }
      } else {
        HStack(alignment: .center, spacing: AppSpacing.lg) {
          labelBlock
          Spacer(minLength: AppSpacing.sm)
          control
        }
      }
    }
    .padding(.horizontal, AppSpacing.md + 2)
    .padding(.vertical, AppSpacing.md - 1)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(title)
  }

  private var labelBlock: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(AppFont.body)
        .foregroundStyle(palette.foreground)
        .fixedSize(horizontal: false, vertical: true)
      if let detail {
        Text(detail)
          .font(AppFont.caption)
          .foregroundStyle(palette.mutedForeground)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

/// Free-form content inside a `SettingsCard`, with the card's own insets.
struct SettingsBlock<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    content
      .padding(.horizontal, AppSpacing.md + 2)
      .padding(.vertical, AppSpacing.md - 1)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// An inline note attached to a control: informational, or a problem to fix.
struct InlineNote: View {
  enum Kind {
    case info
    case success
    case warning
    case error

    var symbol: String {
      switch self {
      case .info: "info.circle"
      case .success: "checkmark.circle"
      case .warning: "exclamationmark.triangle"
      case .error: "exclamationmark.octagon"
      }
    }
  }

  let text: String
  var kind: Kind = .info

  @Environment(\.palette) private var palette

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xs + 2) {
      Image(systemName: kind.symbol)
        .font(.system(size: 10, weight: .semibold))
      Text(text)
        .fixedSize(horizontal: false, vertical: true)
    }
    .font(AppFont.caption)
    .foregroundStyle(tint)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }

  private var tint: Color {
    switch kind {
    case .info: palette.mutedForeground
    case .success: palette.success
    case .warning: palette.warning
    case .error: palette.destructive
    }
  }
}

// MARK: - Split layout

/// Two panes with a draggable divider, which stack when the container is too
/// narrow to give both of them their minimum.
///
/// This replaces `HSplitView`, which reports the sum of its children's ideal
/// widths to its container and cannot switch orientation.
struct ResizableSplit<Leading: View, Trailing: View>: View {
  @Binding var fraction: Double
  var leadingMin: CGFloat
  var trailingMin: CGFloat
  /// Below this container width the panes stack instead of sitting side by side.
  var stacksBelow: CGFloat = AppBreakpoints.regular
  @ViewBuilder var leading: Leading
  @ViewBuilder var trailing: Trailing

  @Environment(\.palette) private var palette
  /// Fraction when the current divider drag began. A drag reports its total
  /// translation on every change, so the running value has to be added to a
  /// fixed origin rather than to itself.
  @State private var dragOrigin: Double?

  var body: some View {
    GeometryReader { proxy in
      let isHorizontal = proxy.size.width >= stacksBelow
      let total = isHorizontal ? proxy.size.width : proxy.size.height
      let minLeading = isHorizontal ? leadingMin : 120
      let minTrailing = isHorizontal ? trailingMin : 120
      let handle = AppMetrics.splitHandleWidth
      let available = max(total - handle, minLeading + minTrailing)
      let leadingSize = min(
        max(available * fraction, minLeading),
        max(minLeading, available - minTrailing)
      )

      if isHorizontal {
        HStack(spacing: 0) {
          leading.frame(width: leadingSize)
          divider(isHorizontal: true, total: available)
          trailing.frame(maxWidth: .infinity)
        }
      } else {
        VStack(spacing: 0) {
          leading.frame(height: leadingSize)
          divider(isHorizontal: false, total: available)
          trailing.frame(maxHeight: .infinity)
        }
      }
    }
  }

  private func divider(isHorizontal: Bool, total: CGFloat) -> some View {
    ZStack {
      Rectangle()
        .fill(palette.border)
        .frame(
          width: isHorizontal ? 1 : nil,
          height: isHorizontal ? nil : 1
        )
    }
    .frame(
      width: isHorizontal ? AppMetrics.splitHandleWidth : nil,
      height: isHorizontal ? nil : AppMetrics.splitHandleWidth
    )
    .contentShape(Rectangle())
    .resizeCursor(horizontal: isHorizontal)
    .gesture(
      DragGesture(minimumDistance: 1, coordinateSpace: .local)
        .onChanged { value in
          guard total > 0 else { return }
          let origin = dragOrigin ?? fraction
          dragOrigin = origin
          let delta = isHorizontal ? value.translation.width : value.translation.height
          fraction = min(max(origin + delta / total, 0.05), 0.95)
        }
        .onEnded { _ in dragOrigin = nil }
    )
    .accessibilityHidden(true)
  }
}

// MARK: - Window chrome

/// Applies the main window's chrome from inside the view tree.
///
/// The scene modifier alone is not enough: SwiftUI writes the window's style
/// mask after `applicationDidFinishLaunching`, so a mask set from the app
/// delegate is overwritten before the first frame is drawn. Reaching the
/// window through the content view runs late enough to survive that.
struct WindowChrome: NSViewRepresentable {
  func makeNSView(context _: Context) -> NSView {
    let view = NSView(frame: .zero)
    DispatchQueue.main.async { apply(to: view.window) }
    return view
  }

  func updateNSView(_ view: NSView, context _: Context) {
    DispatchQueue.main.async { apply(to: view.window) }
  }

  private func apply(to window: NSWindow?) {
    guard let window, !window.styleMask.contains(.fullSizeContentView) else { return }
    WindowCoordinator.configureChrome(of: window)
  }
}

// MARK: - Panel chrome

extension View {
  /// Floating panel background. macOS 26 draws the system glass material;
  /// earlier systems get the palette's elevated surface with a hairline.
  @ViewBuilder
  func floatingPanelBackground(_ palette: AppPalette, radius: CGFloat = AppRadius.xxl) -> some View
  {
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    if #available(macOS 26.0, *) {
      glassEffect(.regular, in: shape)
        .clipShape(shape)
        .overlay { shape.strokeBorder(palette.border, lineWidth: 1) }
    } else {
      background(palette.surface, in: shape)
        .clipShape(shape)
        .overlay { shape.strokeBorder(palette.borderStrong, lineWidth: 1) }
    }
  }
}

// MARK: - Scroller chrome

/// Reaches the enclosing `NSScrollView` from inside its content.
///
/// SwiftUI has no scroller-style API, so a Mac set to "Show scroll bars:
/// Always" hands every pane a legacy scroller: an opaque track that claims
/// layout width and runs straight into a floating panel's rounded corner.
/// Overlay scrollers are drawn on top of the content and fade out when the
/// pane is idle, which is what a reading surface wants.
private struct OverlayScrollerChrome: NSViewRepresentable {
  let insets: NSEdgeInsets

  func makeNSView(context _: Context) -> NSView {
    let view = NSView(frame: .zero)
    DispatchQueue.main.async { apply(from: view) }
    return view
  }

  func updateNSView(_ view: NSView, context _: Context) {
    DispatchQueue.main.async { apply(from: view) }
  }

  private func apply(from view: NSView) {
    guard let scrollView = view.enclosingScrollView else { return }
    scrollView.scrollerStyle = .overlay
    scrollView.autohidesScrollers = true
    scrollView.scrollerInsets = insets
    scrollView.verticalScroller?.controlSize = .small
    scrollView.horizontalScroller?.controlSize = .small
  }
}

extension View {
  /// Gives the surrounding scroll view thin, self-hiding overlay scrollers.
  ///
  /// Apply this to the scroll view's *content*, not to the `ScrollView`
  /// itself: it finds the scroll view by walking up from where it is planted,
  /// and from outside it would find the wrong one, or none.
  func overlayScrollers(
    insets: NSEdgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 4)
  ) -> some View {
    background(
      OverlayScrollerChrome(insets: insets)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    )
  }
}

// MARK: - App Logo

/// Renders the PhraseLens brand application icon.
///
/// Resolves the bundled high-resolution logo resources or falls back to
/// the running application icon (`NSApp.applicationIconImage`).
struct AppLogo: View {
  var size: CGFloat = 26
  var cornerRadius: CGFloat? = nil

  var body: some View {
    if let image = Self.logoImage {
      Image(nsImage: image)
        .resizable()
        .interpolation(.high)
        .aspectRatio(contentMode: .fit)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    } else {
      RoundedRectangle(cornerRadius: cornerRadius ?? (size * 0.22), style: .continuous)
        .fill(Color(nsColor: NSColor(red: 0.14, green: 0.14, blue: 0.14, alpha: 1.0)))
        .frame(width: size, height: size)
        .overlay {
          Image(systemName: "character.bubble.fill")
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.white)
        }
        .accessibilityHidden(true)
    }
  }

  private static let logoImage: NSImage? = {
    // 1. Bundle resources: AppLogo-tight.png (clean squircle without outer shadow padding)
    if let path = Bundle.main.path(forResource: "AppLogo-tight", ofType: "png"),
       let image = NSImage(contentsOfFile: path) {
      return image
    }
    // 2. Bundle resources: AppLogo.png (full icon with shadow)
    if let path = Bundle.main.path(forResource: "AppLogo", ofType: "png"),
       let image = NSImage(contentsOfFile: path) {
      return image
    }
    // 3. Bundle resources: AppIcon.icns
    if let path = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
       let image = NSImage(contentsOfFile: path) {
      return image
    }
    // 4. Running application icon
    if let appIcon = NSApp?.applicationIconImage, appIcon.isValid {
      return appIcon
    }
    return nil
  }()
}

