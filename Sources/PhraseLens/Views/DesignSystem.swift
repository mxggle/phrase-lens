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
/// The ramp is a near-neutral with a faint warm cast, taken from the cream and
/// charcoal of the app icon. Hue is spent only where it carries meaning: the
/// brand lime on the one command that runs the view's work, destructive
/// commands, and the live-state colors.
struct AppPalette: Equatable, Sendable {
  /// The window frame: sidebar, top bar, and the gutter around the content
  /// panel. Everything the user works *in* sits on `background` instead.
  let canvas: Color
  /// The inset content panel, behind every section's own layout.
  let background: Color
  /// Raised content surface: cards, editors, result panes.
  let surface: Color
  /// A surface sitting on top of another surface — popovers, active tabs.
  let surfaceElevated: Color
  /// Bars that belong to a pane inside the content panel. Matches the panel,
  /// so a pane's header and footer read as part of the pane rather than as
  /// bands of chrome; hairlines and spacing carry the separation instead.
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

  /// The brand lime. A fill for the single command that runs a view's work —
  /// Translate, Send — and nothing else, so it always marks where to go next.
  let brand: Color
  let brandHover: Color
  /// Glyphs and text on a `brand` fill.
  let brandForeground: Color
  /// The brand hue tuned to read as a glyph or text on `background`: live
  /// state, the armed tab's mark, links.
  let accent: Color
  /// A wash of the brand hue for highlights and selected chips.
  let accentSoft: Color

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
    canvas: Color(hex: 0xF2F2EF),
    background: Color(hex: 0xFFFFFF),
    surface: Color(hex: 0xFFFFFF),
    surfaceElevated: Color(hex: 0xFFFFFF),
    chrome: Color(hex: 0xFFFFFF),
    muted: Color(hex: 0xF3F3F0),
    mutedHover: Color(hex: 0xEAEAE6),
    accentFill: Color(hex: 0xE6E6E1),
    foreground: Color(hex: 0x1A1A18),
    secondaryForeground: Color(hex: 0x3D3D39),
    mutedForeground: Color(hex: 0x6B6B65),
    faintForeground: Color(hex: 0x8C8C85),
    border: Color(hex: 0xE6E6E1),
    borderStrong: Color(hex: 0xD3D3CD),
    ring: Color(hex: 0x1A1A18, opacity: 0.13),
    primary: Color(hex: 0x1F1F1D),
    primaryHover: Color(hex: 0x353532),
    primaryForeground: Color(hex: 0xFAFAF7),
    brand: Color(hex: 0xC6EE36),
    brandHover: Color(hex: 0xB9E21F),
    brandForeground: Color(hex: 0x1A1A18),
    accent: Color(hex: 0x4D7C0F),
    accentSoft: Color(hex: 0xC6EE36, opacity: 0.22),
    destructive: Color(hex: 0xDC2626),
    destructiveForeground: Color(hex: 0xFEF2F2),
    destructiveFill: Color(hex: 0xDC2626, opacity: 0.09),
    success: Color(hex: 0x3F8A12),
    warning: Color(hex: 0xC2680A),
    shadow: Color(hex: 0x1A1A18, opacity: 0.05),
    shadowStrong: Color(hex: 0x1A1A18, opacity: 0.14)
  )

  static let dark = AppPalette(
    canvas: Color(hex: 0x0D0D0C),
    background: Color(hex: 0x171716),
    surface: Color(hex: 0x1C1C1B),
    surfaceElevated: Color(hex: 0x252523),
    chrome: Color(hex: 0x171716),
    muted: Color(hex: 0x232321),
    mutedHover: Color(hex: 0x2C2C2A),
    accentFill: Color(hex: 0x30302D),
    foreground: Color(hex: 0xEDEDE8),
    secondaryForeground: Color(hex: 0xCBCBC4),
    mutedForeground: Color(hex: 0x9C9C95),
    faintForeground: Color(hex: 0x6E6E68),
    border: Color(hex: 0x2A2A28),
    borderStrong: Color(hex: 0x3B3B38),
    ring: Color(hex: 0xEDEDE8, opacity: 0.20),
    primary: Color(hex: 0xEDEDE8),
    primaryHover: Color(hex: 0xD7D7D1),
    primaryForeground: Color(hex: 0x141413),
    brand: Color(hex: 0xC6EE36),
    brandHover: Color(hex: 0xD3F562),
    brandForeground: Color(hex: 0x141413),
    accent: Color(hex: 0xC6EE36),
    accentSoft: Color(hex: 0xC6EE36, opacity: 0.12),
    destructive: Color(hex: 0xF87171),
    destructiveForeground: Color(hex: 0x1F0A0A),
    destructiveFill: Color(hex: 0xF87171, opacity: 0.13),
    success: Color(hex: 0x9BD34A),
    warning: Color(hex: 0xF5B942),
    shadow: Color(hex: 0x000000, opacity: 0.30),
    shadowStrong: Color(hex: 0x000000, opacity: 0.55)
  )

  /// Increased Contrast pushes lines and secondary text toward the ends of the
  /// ramp. Surfaces stay put, so layout and weight do not shift with the
  /// setting — only legibility does.
  static let lightHighContrast = AppPalette(
    canvas: Color(hex: 0xE9E9E5),
    background: Color(hex: 0xFFFFFF),
    surface: Color(hex: 0xFFFFFF),
    surfaceElevated: Color(hex: 0xFFFFFF),
    chrome: Color(hex: 0xFFFFFF),
    muted: Color(hex: 0xECECE8),
    mutedHover: Color(hex: 0xE0E0DB),
    accentFill: Color(hex: 0xD3D3CD),
    foreground: Color(hex: 0x000000),
    secondaryForeground: Color(hex: 0x262624),
    mutedForeground: Color(hex: 0x4F4F4A),
    faintForeground: Color(hex: 0x6E6E68),
    border: Color(hex: 0xC2C2BB),
    borderStrong: Color(hex: 0x9C9C94),
    ring: Color(hex: 0x000000, opacity: 0.35),
    primary: Color(hex: 0x000000),
    primaryHover: Color(hex: 0x1F1F1D),
    primaryForeground: Color(hex: 0xFFFFFF),
    brand: Color(hex: 0xB4E01C),
    brandHover: Color(hex: 0xA5D00F),
    brandForeground: Color(hex: 0x000000),
    accent: Color(hex: 0x3F6212),
    accentSoft: Color(hex: 0xB4E01C, opacity: 0.30),
    destructive: Color(hex: 0xB91C1C),
    destructiveForeground: Color(hex: 0xFFFFFF),
    destructiveFill: Color(hex: 0xB91C1C, opacity: 0.14),
    success: Color(hex: 0x2F6B0C),
    warning: Color(hex: 0xA14F06),
    shadow: Color(hex: 0x000000, opacity: 0.10),
    shadowStrong: Color(hex: 0x000000, opacity: 0.22)
  )

  static let darkHighContrast = AppPalette(
    canvas: Color(hex: 0x000000),
    background: Color(hex: 0x141413),
    surface: Color(hex: 0x1A1A19),
    surfaceElevated: Color(hex: 0x242422),
    chrome: Color(hex: 0x141413),
    muted: Color(hex: 0x252523),
    mutedHover: Color(hex: 0x31312E),
    accentFill: Color(hex: 0x3A3A36),
    foreground: Color(hex: 0xFFFFFF),
    secondaryForeground: Color(hex: 0xE6E6E1),
    mutedForeground: Color(hex: 0xB8B8B0),
    faintForeground: Color(hex: 0x8E8E87),
    border: Color(hex: 0x42423E),
    borderStrong: Color(hex: 0x5C5C57),
    ring: Color(hex: 0xFFFFFF, opacity: 0.45),
    primary: Color(hex: 0xFFFFFF),
    primaryHover: Color(hex: 0xE6E6E1),
    primaryForeground: Color(hex: 0x000000),
    brand: Color(hex: 0xD3F562),
    brandHover: Color(hex: 0xE0F98E),
    brandForeground: Color(hex: 0x000000),
    accent: Color(hex: 0xD3F562),
    accentSoft: Color(hex: 0xD3F562, opacity: 0.18),
    destructive: Color(hex: 0xFCA5A5),
    destructiveForeground: Color(hex: 0x000000),
    destructiveFill: Color(hex: 0xFCA5A5, opacity: 0.18),
    success: Color(hex: 0xB5E67A),
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
  static let xl: CGFloat = 12
  static let xxl: CGFloat = 16
  static let pill: CGFloat = 999
}

/// The one type scale. Sizes are fixed rather than semantic (`.body`,
/// `.caption`) because the interface sets its own density, and the system
/// scale steps too far between adjacent roles at this size.
enum AppFont {
  static let display = Font.system(size: 22, weight: .semibold)
  static let title = Font.system(size: 15, weight: .semibold)
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

  /// Gutter between the window frame and the inset content panel.
  static let panelInset: CGFloat = 8

  static let windowMinWidth: CGFloat = 560
  static let windowMinHeight: CGFloat = 460

  static let sidebarWidth: CGFloat = 236
  /// Wide enough to hold the traffic lights, so the rail's icons and the
  /// lights share one centre line instead of the lights spilling into the
  /// top bar.
  static let sidebarRailWidth: CGFloat = 76

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
      // Every on/off setting is a switch. A bare `Toggle` would otherwise fall
      // back to the system checkbox, which belongs to a different ramp.
      .toggleStyle(AppSwitchStyle())
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
