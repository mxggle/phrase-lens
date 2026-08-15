import SwiftUI

struct TranslatorView: View {
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var settingsStore: SettingsStore
  @Environment(\.palette) private var palette
  @Environment(\.layoutWidth) private var layoutWidth
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @FocusState private var inputFocused: Bool
  @State private var swapAngle = 0.0
  @State private var didCopy = false
  @State private var copyResetTask: Task<Void, Never>?
  @State private var splitFraction = 0.5

  private var motion: Animation? {
    AppMotion.state(reduceMotion: reduceMotion)
  }

  /// Selection captures stay read-only until the user asks to edit them, so an
  /// accidental keystroke cannot destroy text grabbed from another app.
  private var showsSelectionPreview: Bool {
    model.inputSource == .selection
      && settingsStore.settings.useCompactSelectionPreview
      && !model.isSelectionExpanded
  }

  var body: some View {
    VStack(spacing: AppSpacing.md) {
      commandStrip

      ResizableSplit(
        fraction: $splitFraction,
        leadingMin: AppMetrics.paneMinWidth,
        trailingMin: AppMetrics.paneMinWidth,
        // The split sits inside the section's horizontal padding, so its own
        // breakpoint has to be narrower by that much for the panes to stack at
        // the same window width that turns the section compact.
        stacksBelow: AppBreakpoints.regular - 2 * AppSpacing.lg
      ) {
        sourcePane
          .padding(.trailing, layoutWidth.isCompact ? 0 : AppSpacing.xs)
          .padding(.bottom, layoutWidth.isCompact ? AppSpacing.xs : 0)
      } trailing: {
        resultPane
          .padding(.leading, layoutWidth.isCompact ? 0 : AppSpacing.xs)
          .padding(.top, layoutWidth.isCompact ? AppSpacing.xs : 0)
      }

      statusBar
    }
    .padding(.horizontal, AppSpacing.lg)
    .padding(.top, AppSpacing.md)
    .padding(.bottom, AppSpacing.md)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(palette.background)
    .animation(motion, value: model.isTranslating)
    .animation(motion, value: model.outputText.isEmpty)
    .animation(motion, value: showsSelectionPreview)
  }

  // MARK: - Command strip

  /// Which action runs, and the pair of languages it runs between. Both apply
  /// to the whole translation, so both sit above the split rather than inside
  /// one of its panes.
  private var commandStrip: some View {
    HStack(spacing: AppSpacing.sm) {
      ActionTabBar(
        actions: model.visibleActions,
        selection: actionSelection
      )
      .layoutPriority(1)

      if !layoutWidth.isCompact {
        Spacer(minLength: AppSpacing.sm)
        languageControls
      }
    }
  }

  private var languageControls: some View {
    HStack(spacing: AppSpacing.xs + 2) {
      AppSelect(
        title: "Source language",
        selection: $settingsStore.settings.sourceLanguage,
        options: model.visibleSourceLanguages,
        label: { $0.displayName },
        symbol: "globe"
      )
      swapButton
      AppSelect(
        title: "Target language",
        selection: $settingsStore.settings.targetLanguage,
        options: model.visibleTargetLanguages,
        label: { $0.displayName }
      )
    }
  }

  private var actionSelection: Binding<UUID> {
    Binding(
      get: { model.selectedActionID },
      set: { id in
        model.selectedActionID = id
        if settingsStore.settings.autoTranslate, !model.inputText.isEmpty {
          model.translate()
        }
      }
    )
  }

  private var swapButton: some View {
    Button {
      model.swapLanguages()
      if let animation = AppMotion.interactive(reduceMotion: reduceMotion) {
        withAnimation(animation) { swapAngle += 180 }
      }
    } label: {
      Image(systemName: "arrow.left.arrow.right")
        .font(.system(size: 11, weight: .semibold))
        .rotationEffect(.degrees(swapAngle))
    }
    .appButton(.ghost, size: .iconSmall)
    .disabled(settingsStore.settings.sourceLanguage == .auto)
    .help(
      settingsStore.settings.sourceLanguage == .auto
        ? "Choose a source language to swap"
        : "Swap the source and target languages"
    )
    .accessibilityLabel("Swap languages")
  }

  // MARK: - Source pane

  private var sourcePane: some View {
    PaneContainer {
      PaneHeader(
        title: "Source",
        symbol: "text.alignleft",
        badge: sourceBadge
      ) {
        if layoutWidth.isCompact {
          AppSelect(
            title: "Source language",
            selection: $settingsStore.settings.sourceLanguage,
            options: model.visibleSourceLanguages,
            label: { $0.displayName }
          )
        }
      }

      sourceBody

      PaneFooter {
        IconButton(
          title: model.speech.isSpeaking ? "Stop speaking" : "Speak source text",
          symbol: model.speech.isSpeaking ? "speaker.slash.fill" : "speaker.wave.2",
          isDisabled: model.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ) {
          model.speakInput()
        }

        IconButton(title: "Capture text from the screen", symbol: "viewfinder") {
          model.captureOCR()
        }

        if showsSelectionPreview {
          IconButton(title: "Edit the captured text", symbol: "pencil") {
            model.isSelectionExpanded = true
            inputFocused = true
          }
        }

        IconButton(
          title: "Clear",
          symbol: "eraser",
          isDisabled: model.inputText.isEmpty && model.outputText.isEmpty
        ) {
          model.clear()
        }

        Spacer(minLength: AppSpacing.xs)

        Text("\(model.inputText.count)")
          .font(AppFont.caption)
          .monospacedDigit()
          .foregroundStyle(palette.mutedForeground)
          .accessibilityLabel("\(model.inputText.count) characters in the source text")
      }
    }
  }

  private var sourceBadge: Badge? {
    switch model.inputSource {
    case .selection: Badge(text: "Selection", variant: .outline, symbol: "cursorarrow")
    case .ocr: Badge(text: "Screen", variant: .outline, symbol: "viewfinder")
    case .history: Badge(text: "History", variant: .outline, symbol: "clock")
    case .manual: nil
    }
  }

  @ViewBuilder
  private var sourceBody: some View {
    if showsSelectionPreview {
      ScrollView {
        Text(model.inputText)
          .font(.system(size: settingsStore.settings.fontSize))
          .lineSpacing(3)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(AppMetrics.readingInset)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .transition(.opacity)
    } else {
      ZStack(alignment: .topLeading) {
        TextEditor(text: $model.inputText)
          .font(.system(size: settingsStore.settings.fontSize))
          .lineSpacing(3)
          .foregroundStyle(palette.foreground)
          .scrollContentBackground(.hidden)
          .focused($inputFocused)
          .padding(.horizontal, AppMetrics.readingInset - 5)
          .padding(.vertical, AppMetrics.readingInset - 8)
          .onTapGesture {
            if model.inputSource == .selection {
              model.inputSource = .manual
            }
          }

        if model.inputText.isEmpty {
          Text("Type or paste text here.")
            .font(.system(size: settingsStore.settings.fontSize))
            .foregroundStyle(palette.mutedForeground)
            .padding(.horizontal, AppMetrics.readingInset)
            .padding(.vertical, AppMetrics.readingInset - 8)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .transition(.opacity)
    }
  }

  // MARK: - Result pane

  private var resultPane: some View {
    PaneContainer {
      PaneHeader(
        title: "Result",
        symbol: "sparkles",
        badge: model.outputUsesMarkdown && !model.outputText.isEmpty
          ? Badge(text: "Markdown", variant: .neutral)
          : nil
      ) {
        if layoutWidth.isCompact {
          AppSelect(
            title: "Target language",
            selection: $settingsStore.settings.targetLanguage,
            options: model.visibleTargetLanguages,
            label: { $0.displayName }
          )
        }
        if model.isTranslating {
          Spinner()
            .transition(.opacity)
        }
      }

      resultBody

      PaneFooter {
        Button {
          model.toggleCollectCurrentWord()
        } label: {
          Label(
            model.isCurrentWordCollected ? "Collected" : "Collect",
            systemImage: model.isCurrentWordCollected ? "bookmark.fill" : "bookmark"
          )
          .labelStyle(.titleAndIcon)
          .contentTransition(.symbolEffect(.replace))
        }
        .appButton(.ghost, size: .sm)
        .disabled(
          !model.isCurrentWordCollected
            && (model.outputText.isEmpty || model.inputText.count > 80)
        )
        .help(
          model.isCurrentWordCollected
            ? "Remove this word from Vocabulary"
            : "Save this word and its explanation to Vocabulary"
        )

        Spacer(minLength: AppSpacing.xs)

        Button {
          copyOutput()
        } label: {
          Label {
            Text(didCopy ? "Copied" : "Copy")
          } icon: {
            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
              .contentTransition(.symbolEffect(.replace))
          }
          .labelStyle(.titleAndIcon)
        }
        .appButton(didCopy ? .secondary : .outline, size: .sm)
        .symbolEffect(.bounce, value: didCopy)
        .disabled(model.outputText.isEmpty)
        .help("Copy the translation (⇧⌘C)")
      }
    }
  }

  @ViewBuilder
  private var resultBody: some View {
    if model.outputText.isEmpty {
      EmptyState(
        symbol: model.isTranslating ? "ellipsis" : "character.bubble",
        title: model.isTranslating ? "Translating…" : "No translation yet",
        message: model.inputText.isEmpty
          ? "Enter text on the left, or press ⌥F while text is selected in another app."
          : "Press ⌘↩ to translate."
      )
      .transition(.opacity)
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
        .padding(AppMetrics.readingInset)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .transition(.opacity)
    }
  }

  // MARK: - Status

  private var statusBar: some View {
    HStack(spacing: AppSpacing.sm) {
      StatusDot(
        color: model.isTranslating ? palette.foreground : palette.faintForeground,
        isActive: model.isTranslating
      )
      Text(model.statusMessage)
        .lineLimit(1)

      Spacer(minLength: AppSpacing.sm)

      if showsSelectionPreview {
        Badge(text: "Read-only capture", variant: .neutral, symbol: "lock.fill")
      }
      if !layoutWidth.isCompact {
        Text(
          "\(settingsStore.settings.sourceLanguage.displayName) → "
            + settingsStore.settings.targetLanguage.displayName
        )
        .lineLimit(1)
      }
    }
    .font(AppFont.caption)
    .foregroundStyle(palette.mutedForeground)
    .frame(height: AppMetrics.statusBarHeight)
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Status: \(model.statusMessage)")
  }

  private func copyOutput() {
    model.copyOutput()
    didCopy = true
    copyResetTask?.cancel()
    copyResetTask = Task { @MainActor in
      try? await Task.sleep(for: .seconds(1.6))
      guard !Task.isCancelled else { return }
      didCopy = false
    }
  }
}

// MARK: - Pane chrome

/// A content pane: one card holding a header, a body, and a command footer.
///
/// The card is the unit of content in this interface. Nothing floats on the
/// canvas directly, so every region has an edge and the eye can find it.
struct PaneContainer<Content: View>: View {
  @ViewBuilder var content: Content

  @Environment(\.palette) private var palette

  var body: some View {
    VStack(spacing: 0) {
      content
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .cardSurface(palette)
  }
}

/// A pane's title strip: what the pane holds, its state, and the controls
/// scoped to it.
struct PaneHeader<Accessory: View>: View {
  let title: String
  let symbol: String
  var badge: Badge?
  @ViewBuilder var accessory: Accessory

  @Environment(\.palette) private var palette

  init(
    title: String,
    symbol: String,
    badge: Badge? = nil,
    @ViewBuilder accessory: () -> Accessory = { EmptyView() }
  ) {
    self.title = title
    self.symbol = symbol
    self.badge = badge
    self.accessory = accessory()
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: AppSpacing.sm) {
        Image(systemName: symbol)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(palette.faintForeground)
          .accessibilityHidden(true)
        Text(title)
          .font(AppFont.label)
          .foregroundStyle(palette.secondaryForeground)
        if let badge { badge }
        Spacer(minLength: AppSpacing.sm)
        accessory
      }
      .padding(.horizontal, AppSpacing.md)
      .frame(height: AppMetrics.paneHeaderHeight)
      Hairline()
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(title)
  }
}

/// A pane's command strip, on a muted fill so it separates from the content
/// above it without a heavy rule.
struct PaneFooter<Content: View>: View {
  @ViewBuilder var content: Content

  @Environment(\.palette) private var palette

  var body: some View {
    VStack(spacing: 0) {
      Hairline()
      HStack(spacing: AppSpacing.xs) {
        content
      }
      .padding(.horizontal, AppSpacing.sm + 2)
      .frame(height: AppMetrics.paneFooterHeight)
      .background(palette.chrome)
    }
  }
}
