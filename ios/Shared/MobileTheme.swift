import SwiftUI

/// `DesignSystem.swift` is shared with the macOS app, whose `ThemedContainer`
/// names the switch style that lives in its AppKit-era `Components.swift`.
/// The phone uses the system switch, so the name resolves to that here.
struct AppSwitchStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    Toggle(configuration).toggleStyle(.switch)
  }
}

/// Publishes the shared palette to a subtree without the desktop type scale
/// `ThemedContainer` applies, which reads too small on a phone.
struct MobilePalette: ViewModifier {
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var contrast

  func body(content: Content) -> some View {
    let palette = AppPalette.resolve(colorScheme, contrast: contrast)
    content
      .environment(\.palette, palette)
      .tint(palette.foreground)
  }
}

extension View {
  func mobilePalette() -> some View { modifier(MobilePalette()) }
}
