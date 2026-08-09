# NextAI Translator macOS design system

The interface follows the macOS design system: the window toolbar and sidebar
form the navigation layer (Liquid Glass, applied by the system on macOS 26),
while source text and the generated result stay on calm, solid content-layer
surfaces separated by their own chrome bars.

## Principles

- Use native SwiftUI controls so macOS can supply the correct material, focus, contrast, and control metrics for each OS version.
- Keep window-level commands in the **real window toolbar**: the one button that runs the work. Anything scoped to one side of the translation belongs in that pane's own header or footer.
- A choice the user switches between constantly is a flat tab strip, not a menu. The strip shows every option and the armed one at a glance, and costs one click instead of two.
- Keep the content layer calm. Panes are solid text surfaces with no strokes; hierarchy comes from the header and footer bars, spacing, and typography — not decoration.
- Every control has a visible label or, when icon-only, a `help` tooltip *and* an accessibility label derived from the same string.
- Tint is reserved for functional meaning: the single primary action, and transient activity state.
- Never let content clip. Result areas grow with the window instead of being pinned to a fixed height.
- Preserve keyboard workflows; global shortcuts are recorded, not typed as text.
- Use short, state-driven springs scoped to the value that changed. Respect the system Reduce Motion preference.
- State changes are communicated with SF Symbol transitions (replace/bounce) rather than custom indicator UI.

## Tokens

Shared spacing, metrics, colors, motion, and reusable chrome live in
`Sources/NextAITranslatorNative/Views/DesignSystem.swift`.

- `AppSpacing` — 4-pt grid steps (`xxs`…`xxl`). Nothing hard-codes a spacing value.
- `AppMetrics` — bar heights, split-pane widths, reading insets, corner radii.
- `AppDesign` — semantic AppKit colors, so everything stays legible in Light, Dark, and Increased Contrast.
- `PaneBar(.header/.footer)` — the bar material plus a single hairline on the edge facing the content.
- `ActionTabBar(size: .regular/.compact)` — horizontally scrolling action tab strip with a sliding underline. The underline is `.primary`, not tint, because selection is not a functional accent.
- `BarButton` — icon-only bar command with matched tooltip and accessibility label.
- `StatusDot` — provider reachability and translation state.
- `floatingPanelBackground()` — glass on macOS 26, `regularMaterial` before it.
- `AppMotion.state` / `AppMotion.interactive` — standard springs; both return `nil` under Reduce Motion.

## Layout

**Main window.** Standard titled window with a unified toolbar. The title shows
the current section and the language pair as its subtitle.

1. Sidebar: section navigation, with a footer that reports the active provider and model and opens Settings.
2. Toolbar: the prominent Translate/Stop button.
3. Action tabs: a full-width strip under the toolbar. It spans the window because the action applies to the whole translation, not to one pane.
4. Content: an `HSplitView` of a source pane and a result pane. Each pane owns its language pop-up in its header and its commands in its footer, so the language is attached to the text it applies to.
5. Status bar: one line of state across the bottom.

**Selection pop-up.** A borderless floating panel: one line of header chrome, a
compact action tab strip, the captured text, the result filling the remaining
height, and a footer whose prominent action is Copy — the thing a pop-up is
opened to do. Switching the action re-runs the captured text through it, the
same contract the footer's target-language menu follows.

**Actions.** A source list with an add/remove bar beneath it (where macOS puts
list editing) and a form on the right. Edits save automatically, so there is no
Save button and no way to lose a draft by switching sections.

## Availability

The package targets macOS 14 and builds with the macOS 26 SDK
(`scripts/toolchain-env.sh` selects it). APIs introduced in macOS 26 — the glass
button style, `glassEffect` — are gated with `#available(macOS 26.0, *)` and
fall back to standard styles on older systems.

## Known AppKit workarounds

- **Split-view autosave.** `NavigationSplitView` writes subview frames that do
  not add up to the window's width. Restoring them clips the sidebar on the left
  and the detail column on the right, so `clearCorruptSplitViewState` purges the
  `NSSplitView Subview Frames …` defaults at launch. Window frame memory is
  unaffected.
- **Restored frames on a missing display.** A window restored onto a display
  that no longer exists is resized *after* the split view has laid out, leaving
  both columns clipped until the user resizes the window.
  `WindowCoordinator.revalidateMainWindowLayout` re-applies the frame once at
  launch to force a correct layout pass.
- **Ideal widths propagate.** An `HSplitView` reports the sum of its children's
  ideal widths to its container, and `NavigationSplitView` will overflow the
  window rather than compress it. The translator panes therefore pin
  `idealWidth` to `minWidth`.
- **Toolbar labels.** A `Label` in a toolbar item collapses to its icon unless
  `.labelStyle(.titleAndIcon)` is explicit.
- **Fixed panel height.** The selection pop-up is a borderless panel with a
  hard-coded content size, so anything added to it has to be added to that size
  too, or it is taken out of the result area.

Remove each workaround once the corresponding OS fix ships.

## References

- [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos)
- [Get to know the new design system](https://developer.apple.com/videos/play/wwdc2025/356/)
- [Build an AppKit app with the new design](https://developer.apple.com/videos/play/wwdc2025/310/)
- [Adopting Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass)
