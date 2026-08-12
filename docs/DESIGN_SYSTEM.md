# PhraseLens macOS design system

The interface is built from one token set and one component library, both owned
by the app rather than inherited from AppKit's default control appearance. The
palette is achromatic — a neutral ramp from near-white to near-black — and hue
is spent only where it carries meaning.

The vocabulary is deliberately shadcn/ui's: semantic color roles rather than
literal colors, a shared radius and spacing scale, and the same component set
(Button variants, Card, Tabs, Select, Switch, Badge, Input, Empty State). None
of shadcn's code is used or usable here — it is React, Tailwind, and Radix, and
this is a native SwiftUI app. What carries over is the design language, rebuilt
as real SwiftUI views so macOS still supplies text input, menus, focus, and
accessibility.

## Principles

- Nothing floats on the canvas. Every region of content sits on a card with an
  edge, so hierarchy is legible without decoration.
- Color is semantic. A view asks for `palette.mutedForeground`, never a gray.
  One change to the ramp moves the whole interface, and Light, Dark, and
  Increased Contrast stay in step by construction.
- Variants map to intent, not appearance. A view picks `.primary` because the
  command is the point of the view, not because it wants a dark button.
- Every layout is a function of the width it was given, not of the window. A
  section behaves the same at a given width whether the sidebar is expanded,
  collapsed, or absent.
- Content never clips and never overflows its window. Where a layout cannot
  fit, it changes shape — stacks, drops labels, or sheds ornament — rather than
  spilling.
- Every control has a visible label or, when icon-only, a `help` tooltip *and*
  an accessibility label derived from the same string.
- Short, state-driven springs scoped to the value that changed. Every animation
  helper returns `nil` under Reduce Motion.

## Tokens

`Sources/NextAITranslatorNative/Views/DesignSystem.swift`

- `AppPalette` — the semantic color roles, in four resolved variants (Light,
  Dark, and an Increased Contrast pair). Published through
  `EnvironmentValues.palette` by `ThemedContainer`, which resolves the effective
  appearance once per window, below `preferredColorScheme`, so the Light/Dark
  override in Settings reaches the tokens.
- `AppSpacing` — 4-pt grid steps. Nothing hard-codes a spacing value.
- `AppRadius` — controls, cards, and panels each keep their own step, so nesting
  reads as a hierarchy rather than as a rounding accident.
- `AppFont` — one type scale, sized in points rather than semantic styles,
  because the interface sets its own density.
- `AppMetrics` — bar heights, column minimums, reading insets, control heights.
- `AppMotion.state` / `.interactive` / `.hover` — the three motion roles.

## Components

`Sources/NextAITranslatorNative/Views/Components.swift`

| Component | Role |
| --- | --- |
| `cardSurface(_:)` | The content surface: fill, hairline, radius, shadow. |
| `Hairline` | A rule in the palette's border color. `Divider()` uses an AppKit separator that is not on this ramp. |
| `AppButtonStyle` / `.appButton(_:size:)` | Six variants × six sizes, with a shared hover/press ramp. |
| `IconButton` | Icon-only command with matched tooltip and accessibility label. |
| `AdaptiveLabel` | A command label that drops its title when its bar runs out of room. |
| `Badge`, `KeyCombo` | State labels and keycaps. |
| `StatusDot`, `Spinner` | Live state. Both readable under Reduce Motion. |
| `AppTextField`, `AppTextEditor`, `AppSelect`, `AppSwitchStyle`, `ChipToggleStyle` | Inputs. `AppSelect` wraps `Menu`, so the list itself is a real AppKit menu. |
| `ActionTabBar` | Scrolling segmented switcher; the armed pill slides between tabs. |
| `NavRow` | Selectable row, used by both sidebars and the Actions source list. |
| `SettingsCard` / `SettingsRow` / `SettingsBlock` / `InlineNote` | Settings scaffolding, replacing `Form`'s grouped sections. |
| `EmptyState` | "Nothing here yet", in four progressively shorter forms. |
| `ResizableSplit` | Two panes with a draggable divider that stack when too narrow. |
| `WindowChrome` | Applies the main window's chrome from inside the view tree. |

## Responsive layout

Width classes are measured per container by `WidthReader` and published through
`EnvironmentValues.layoutWidth`. `AppBreakpoints` holds the three thresholds.

| Class | Container width | Behavior |
| --- | --- | --- |
| `compact` | `< 640` | One column. Split sections stack; Actions shows list *or* editor with a back button; command labels collapse to glyphs; settings rows stack their control under the label. |
| `regular` | `640…999` | Two columns. |
| `wide` | `≥ 1000` | Two columns plus optional secondary detail — history rows put source and translation side by side. |

The sidebar is measured separately against the window: below
`AppBreakpoints.sidebarRail` (860pt) it collapses to a 64pt icon rail on its
own. Above it, the user's choice wins.

`SelfTestRunner` enforces two invariants: every side-by-side section's column
minimums must fit inside the `regular` breakpoint (otherwise there is a band of
widths where it neither stacks nor fits), and the detail column at the window's
minimum width must still hold one pane.

## Layout

**Main window.** No system title bar. The window uses `fullSizeContentView`, so
the app's own chrome reaches the top edge and the sidebar reserves
`AppMetrics.trafficLightInset` for the traffic lights.

1. Sidebar: brand, sections grouped under eyebrow headings with live counts, and
   a provider card that both reports the active model and opens Settings.
2. Top bar: the section, one line saying what it is for, and the window-level
   commands for that section.
3. Content: each section owns its layout inside the detail column.

**Translator.** An action tab strip and the language pair above a resizable
split of a source card and a result card. Each card carries a title strip and a
command footer.

**Library.** History and Vocabulary share one scaffold — filter bar, then a
collection of selectable cards. History is a single column of rows; vocabulary
tiles into as many columns as the window holds.

**Actions.** A source list with an add/remove bar beneath it and a settings-style
editor beside it. Edits save automatically.

**Settings.** Its own sidebar and scrolling pane of cards, rather than a tab
bar, because there are six panes and they are not peers of equal weight.

**Selection pop-up.** A borderless floating panel reusing the same components at
compact sizes: header, compact tab strip, the captured text, the result filling
the remaining height, and a footer whose primary action is Copy.

## Availability

The package targets macOS 14 and builds with the macOS 26 SDK
(`scripts/toolchain-env.sh` selects it). APIs introduced in macOS 26 —
`glassEffect` on the floating panel — are gated with `#available(macOS 26.0, *)`
and fall back to the palette's own surfaces on older systems.

## Known AppKit workarounds

- **Title-bar safe area.** `fullSizeContentView` makes the content view span the
  title bar, but SwiftUI then insets the content by the bar's height. The root
  view has to `ignoresSafeArea(.container, edges: .top)` or the space the
  sidebar reserves for the traffic lights is paid twice.
- **Style mask timing.** SwiftUI writes the scene's style mask *after*
  `applicationDidFinishLaunching`, so a mask set from the app delegate is
  overwritten before the first frame. `WindowChrome` reaches the window through
  the content view, which runs late enough to survive.
- **Restored frames on a missing display.** A window restored onto a display
  that no longer exists is resized after layout.
  `WindowCoordinator.revalidateMainWindowLayout` re-applies the frame once at
  launch to force a correct pass.
- **Ambiguous main window.** The main window and the Settings window are both
  plain titled windows of similar size, so `tagMainWindowIfNeeded` matches on
  the scene title first and falls back to width.

Remove each workaround once the corresponding OS fix ships.

## References

- [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos)
- [shadcn/ui](https://ui.shadcn.com) — the design language this system borrows.
