import SwiftUI

extension AppTheme {
  /// The explicit SwiftUI override for this setting. Keeping the conversion
  /// beside the window-level design system lets every window observe the same
  /// live value instead of taking a one-time snapshot when it is created.
  var preferredColorScheme: ColorScheme? {
    switch self {
    case .system: nil
    case .light: .light
    case .dark: .dark
    }
  }
}

// MARK: - Color primitives

extension Color {
  /// Builds a color from a packed 24-bit sRGB literal, so palette values can be
  /// written the same way the design tokens they came from are written.
  init(hex: UInt32, opacity: Double = 1) {
    self.init(
      .sRGB,
      red: Double((hex >> 16) & 0xFF) / 255,
      green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255,
      opacity: opacity
    )
  }
}

// MARK: - Palette

/// Semantic colors for one appearance.
///
/// Every surface, line, and glyph in the app resolves to one of these roles
/// rather than to a raw color, so a change to the neutral ramp moves the whole
/// interface at once and Light, Dark, and Increased Contrast stay in step.
///
/// The ramp is deliberately achromatic. Hue is spent only where it carries
/// meaning: destructive commands, and the three live-state colors.
struct AppPalette: Equatable, Sendable {
  /// Window canvas, behind every pane.
  let background: Color
  /// Raised content surface: cards, editors, result panes.
  let surface: Color
  /// A surface sitting on top of another surface — popovers, active tabs.
  let surfaceElevated: Color
  /// Navigation chrome: sidebar and top bar.
  let chrome: Color
  /// Low-contrast fill for inline groupings and tracks.
  let muted: Color
  /// The same fill under a pointer.
  let mutedHover: Color
  /// Selected-row and pressed-control fill.
  let accentFill: Color

  /// Primary text.
  let foreground: Color
  /// Supporting text that is still content.
  let secondaryForeground: Color
  /// Labels, metadata, and captions. The lightest tone that still carries
  /// words: anything a reader has to read stops here.
  let mutedForeground: Color
  /// Ornament only — chevrons, drag handles, quote marks, and the glyphs that
  /// accompany a label rather than replace it. Held at or above 3:1 for
  /// non-text contrast, which is *not* enough for text, so text never uses it.
  let faintForeground: Color

  /// Hairline between regions and around resting controls.
  let border: Color
  /// Hairline that has to survive against a busy surface.
  let borderStrong: Color
  /// Keyboard focus ring.
  let ring: Color

  /// Filled default action.
  let primary: Color
  let primaryHover: Color
  let primaryForeground: Color

  let destructive: Color
  let destructiveForeground: Color
  let destructiveFill: Color

  let success: Color
  let warning: Color

  /// Card and popover drop shadows. Near-invisible in Dark, where elevation is
  /// carried by the surface ramp instead.
  let shadow: Color
  let shadowStrong: Color
}

extension AppPalette {
  static let light = AppPalette(
    background: Color(hex: 0xF7F7F8),
    surface: Color(hex: 0xFFFFFF),
    surfaceElevated: Color(hex: 0xFFFFFF),
    chrome: Color(hex: 0xFAFAFA),
    muted: Color(hex: 0xF4F4F5),
    mutedHover: Color(hex: 0xECECEE),
    accentFill: Color(hex: 0xE4E4E7),
    foreground: Color(hex: 0x09090B),
    secondaryForeground: Color(hex: 0x3F3F46),
    mutedForeground: Color(hex: 0x71717A),
    faintForeground: Color(hex: 0x85858E),
    border: Color(hex: 0xE4E4E7),
    borderStrong: Color(hex: 0xD4D4D8),
    ring: Color(hex: 0x09090B, opacity: 0.22),
    primary: Color(hex: 0x18181B),
    primaryHover: Color(hex: 0x27272A),
    primaryForeground: Color(hex: 0xFAFAFA),
    destructive: Color(hex: 0xDC2626),
    destructiveForeground: Color(hex: 0xFEF2F2),
    destructiveFill: Color(hex: 0xDC2626, opacity: 0.10),
    success: Color(hex: 0x16A34A),
    warning: Color(hex: 0xD97706),
    shadow: Color(hex: 0x09090B, opacity: 0.06),
    shadowStrong: Color(hex: 0x09090B, opacity: 0.14)
  )

  static let dark = AppPalette(
    background: Color(hex: 0x09090B),
    surface: Color(hex: 0x131316),
    surfaceElevated: Color(hex: 0x232329),
    chrome: Color(hex: 0x0C0C0E),
    muted: Color(hex: 0x1C1C20),
    mutedHover: Color(hex: 0x26262B),
    accentFill: Color(hex: 0x2A2A30),
    foreground: Color(hex: 0xFAFAFA),
    secondaryForeground: Color(hex: 0xD4D4D8),
    mutedForeground: Color(hex: 0x9B9BA3),
    faintForeground: Color(hex: 0x6B6B73),
    border: Color(hex: 0x27272B),
    borderStrong: Color(hex: 0x3A3A41),
    ring: Color(hex: 0xFAFAFA, opacity: 0.28),
    primary: Color(hex: 0xFAFAFA),
    primaryHover: Color(hex: 0xE4E4E7),
    primaryForeground: Color(hex: 0x09090B),
    destructive: Color(hex: 0xF87171),
    destructiveForeground: Color(hex: 0x1F0A0A),
    destructiveFill: Color(hex: 0xF87171, opacity: 0.14),
    success: Color(hex: 0x4ADE80),
    warning: Color(hex: 0xFBBF24),
    shadow: Color(hex: 0x000000, opacity: 0.34),
    shadowStrong: Color(hex: 0x000000, opacity: 0.55)
  )

  /// Increased Contrast pushes lines and secondary text toward the ends of the
  /// ramp. Surfaces stay put, so layout and weight do not shift with the
  /// setting — only legibility does.
  static let lightHighContrast = AppPalette(
    background: Color(hex: 0xF2F2F3),
    surface: Color(hex: 0xFFFFFF),
    surfaceElevated: Color(hex: 0xFFFFFF),
    chrome: Color(hex: 0xF7F7F8),
    muted: Color(hex: 0xEDEDEF),
    mutedHover: Color(hex: 0xE1E1E4),
    accentFill: Color(hex: 0xD4D4D8),
    foreground: Color(hex: 0x000000),
    secondaryForeground: Color(hex: 0x27272A),
    mutedForeground: Color(hex: 0x52525B),
    faintForeground: Color(hex: 0x71717A),
    border: Color(hex: 0xC4C4CA),
    borderStrong: Color(hex: 0x9F9FA8),
    ring: Color(hex: 0x000000, opacity: 0.45),
    primary: Color(hex: 0x000000),
    primaryHover: Color(hex: 0x18181B),
    primaryForeground: Color(hex: 0xFFFFFF),
    destructive: Color(hex: 0xB91C1C),
    destructiveForeground: Color(hex: 0xFFFFFF),
    destructiveFill: Color(hex: 0xB91C1C, opacity: 0.14),
    success: Color(hex: 0x15803D),
    warning: Color(hex: 0xB45309),
    shadow: Color(hex: 0x09090B, opacity: 0.10),
    shadowStrong: Color(hex: 0x09090B, opacity: 0.20)
  )

  static let darkHighContrast = AppPalette(
    background: Color(hex: 0x000000),
    surface: Color(hex: 0x141417),
    surfaceElevated: Color(hex: 0x1F1F24),
    chrome: Color(hex: 0x08080A),
    muted: Color(hex: 0x1F1F24),
    mutedHover: Color(hex: 0x2C2C33),
    accentFill: Color(hex: 0x35353D),
    foreground: Color(hex: 0xFFFFFF),
    secondaryForeground: Color(hex: 0xE4E4E7),
    mutedForeground: Color(hex: 0xB4B4BC),
    faintForeground: Color(hex: 0x8A8A93),
    border: Color(hex: 0x3C3C44),
    borderStrong: Color(hex: 0x57575F),
    ring: Color(hex: 0xFFFFFF, opacity: 0.5),
    primary: Color(hex: 0xFFFFFF),
    primaryHover: Color(hex: 0xE4E4E7),
    primaryForeground: Color(hex: 0x000000),
    destructive: Color(hex: 0xFCA5A5),
    destructiveForeground: Color(hex: 0x000000),
    destructiveFill: Color(hex: 0xFCA5A5, opacity: 0.18),
    success: Color(hex: 0x86EFAC),
    warning: Color(hex: 0xFCD34D),
    shadow: Color(hex: 0x000000, opacity: 0.5),
    shadowStrong: Color(hex: 0x000000, opacity: 0.7)
  )

  static func resolve(_ scheme: ColorScheme, contrast: ColorSchemeContrast) -> AppPalette {
    switch (scheme, contrast) {
    case (.dark, .increased): darkHighContrast
    case (.dark, _): dark
    case (_, .increased): lightHighContrast
    default: light
    }
  }
}

// MARK: - Layout scale

/// Layout rhythm on a 4-pt grid, so custom containers align with the AppKit
/// control metrics they sit next to.
enum AppSpacing {
  static let xxs: CGFloat = 2
  static let xs: CGFloat = 4
  static let sm: CGFloat = 8
  static let md: CGFloat = 12
  static let lg: CGFloat = 16
  static let xl: CGFloat = 20
  static let xxl: CGFloat = 28
  static let xxxl: CGFloat = 40
}

/// Corner radii. Controls, cards, and panels each keep their own step so
/// nesting reads as a hierarchy rather than as a rounding accident.
enum AppRadius {
  static let xs: CGFloat = 4
  static let sm: CGFloat = 6
  static let md: CGFloat = 8
  static let lg: CGFloat = 10
  static let xl: CGFloat = 14
  static let xxl: CGFloat = 18
  static let pill: CGFloat = 999
}

/// The one type scale. Sizes are fixed rather than semantic (`.body`,
/// `.caption`) because the interface sets its own density, and the system
/// scale steps too far between adjacent roles at this size.
enum AppFont {
  static let display = Font.system(size: 20, weight: .semibold)
  static let title = Font.system(size: 16, weight: .semibold)
  static let heading = Font.system(size: 13, weight: .semibold)
  static let body = Font.system(size: 13)
  static let bodyMedium = Font.system(size: 13, weight: .medium)
  static let label = Font.system(size: 12, weight: .medium)
  static let labelRegular = Font.system(size: 12)
  static let caption = Font.system(size: 11)
  static let captionMedium = Font.system(size: 11, weight: .medium)
  /// Section eyebrows in the sidebar and settings. Tracked out and uppercased
  /// at the call site.
  static let overline = Font.system(size: 10, weight: .semibold)
  static let mono = Font.system(size: 12, design: .monospaced)
  static let monoSmall = Font.system(size: 11, design: .monospaced)
}

enum AppMetrics {
  /// Height of the window-wide top bar.
  static let navBarHeight: CGFloat = 52
  /// Height of a pane's header strip.
  static let paneHeaderHeight: CGFloat = 44
  /// Height of a pane's command strip.
  static let paneFooterHeight: CGFloat = 40
  /// Height of the window-wide status strip.
  static let statusBarHeight: CGFloat = 28

  /// Vertical space the window's traffic lights need at the top of the sidebar.
  /// The window has no title bar of its own, so the sidebar owns that gap.
  static let trafficLightInset: CGFloat = 38

  static let windowMinWidth: CGFloat = 560
  static let windowMinHeight: CGFloat = 460

  static let sidebarWidth: CGFloat = 236
  static let sidebarRailWidth: CGFloat = 64

  /// Smallest usable width for one half of the translator split.
  static let paneMinWidth: CGFloat = 260
  /// Smallest usable widths for the two columns of the Actions editor.
  static let actionListMinWidth: CGFloat = 200
  static let actionEditorMinWidth: CGFloat = 320

  /// Grab area of a draggable split divider.
  static let splitHandleWidth: CGFloat = 7

  /// Text inset inside editors and result views.
  static let readingInset: CGFloat = 18

  static let controlHeightSmall: CGFloat = 26
  static let controlHeight: CGFloat = 32
  static let controlHeightLarge: CGFloat = 38

  /// Every section that lays out as side-by-side columns, measured by
  /// `SelfTestRunner` against the width at which the app stops stacking them.
  static let splitColumnMinimums: [(String, [CGFloat])] = [
    ("Translator", [paneMinWidth, paneMinWidth]),
    ("Actions", [actionListMinWidth, actionEditorMinWidth]),
  ]
}

// MARK: - Responsive layout

/// Width classes for the *container being laid out*, not for the window.
///
/// The shell measures the window to choose a sidebar mode; each section
/// measures the space it was actually given. A section therefore behaves the
/// same at a given width whether the sidebar is expanded, collapsed to a rail,
/// or absent — which is what makes the selection pop-up reuse section views
/// unchanged.
enum LayoutWidth: Int, Comparable, Sendable {
  /// One column. Side-by-side layouts stack.
  case compact = 0
  /// Two columns fit.
  case regular = 1
  /// Two columns plus room for secondary detail.
  case wide = 2

  init(_ width: CGFloat) {
    if width < AppBreakpoints.regular {
      self = .compact
    } else if width < AppBreakpoints.wide {
      self = .regular
    } else {
      self = .wide
    }
  }

  var isCompact: Bool { self == .compact }

  static func < (lhs: LayoutWidth, rhs: LayoutWidth) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

enum AppBreakpoints {
  /// Below this, a two-column section stacks into one column.
  static let regular: CGFloat = 640
  /// At or above this, a section may show optional secondary detail.
  static let wide: CGFloat = 1000
  /// Below this window width the sidebar collapses to an icon rail on its own.
  static let sidebarRail: CGFloat = 860
}

// MARK: - Motion

enum AppMotion {
  /// Short, state-driven layout transition. `nil` under Reduce Motion.
  static func state(reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : .snappy(duration: 0.24, extraBounce: 0.02)
  }

  /// Brief spring for user-initiated control feedback. `nil` under Reduce Motion.
  static func interactive(reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : .spring(duration: 0.34, bounce: 0.18)
  }

  /// Pointer-driven hover and press tints. Always fast, never bouncy.
  static func hover(reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : .easeOut(duration: 0.12)
  }
}

// MARK: - Environment

private struct AppPaletteKey: EnvironmentKey {
  static let defaultValue = AppPalette.light
}

private struct LayoutWidthKey: EnvironmentKey {
  static let defaultValue = LayoutWidth.regular
}

extension EnvironmentValues {
  var palette: AppPalette {
    get { self[AppPaletteKey.self] }
    set { self[AppPaletteKey.self] = newValue }
  }

  /// Width class of the nearest container that measured itself.
  var layoutWidth: LayoutWidth {
    get { self[LayoutWidthKey.self] }
    set { self[LayoutWidthKey.self] = newValue }
  }
}

/// Resolves the palette from the effective appearance and publishes it to the
/// subtree. Applied once per window, below `preferredColorScheme`, so a manual
/// Light/Dark override in Settings reaches the tokens.
struct ThemedContainer<Content: View>: View {
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var contrast
  @ViewBuilder var content: Content

  var body: some View {
    let palette = AppPalette.resolve(colorScheme, contrast: contrast)
    content
      .environment(\.palette, palette)
      .tint(palette.foreground)
      .foregroundStyle(palette.foreground)
      .font(AppFont.body)
  }
}

/// Measures its own width and publishes the matching class to its content.
/// Uses `GeometryReader` rather than a preference key so the class is a pure
/// function of the proposed size, with no state to fall out of date.
struct WidthReader<Content: View>: View {
  @ViewBuilder var content: (LayoutWidth, CGFloat) -> Content

  var body: some View {
    GeometryReader { proxy in
      let width = proxy.size.width
      content(LayoutWidth(width), width)
        .environment(\.layoutWidth, LayoutWidth(width))
        .frame(width: proxy.size.width, height: proxy.size.height)
    }
  }
}
