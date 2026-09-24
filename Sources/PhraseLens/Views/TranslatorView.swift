import SwiftUI

struct TranslatorView: View {
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var settingsStore: SettingsStore
  @Environment(\.palette) private var palette
  @Environment(\.layoutWidth) private var layoutWidth
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.openSettings) private var openSettings

  @FocusState private var inputFocused: Bool
  @State private var swapAngle = 0.0
  @State private var didCopy = false
  @State private var copyResetTask: Task<Void, Never>?
  @State private var splitFraction = 0.5

  private var motion: Animation? {
    AppMotion.state(reduceMotion: reduceMotion)
  }

  /// The source box is always editable, whatever the text came from. Captured
  /// text used to arrive read-only behind a pencil button, which cost a click
  /// on the way to the common move: look a word up, then type the next one.
  /// Typing is what makes the text the user's own, so the binding — not a
  /// mode — is where the capture's provenance is dropped.
  private var inputBinding: Binding<String> {
    Binding(
      get: { model.inputText },
      set: { model.editInputText($0) }
    )
  }

  var body: some View {
    VStack(spacing: AppSpacing.md) {
      if !settingsStore.hasBasicProviderConfiguration {
        HStack(spacing: AppSpacing.sm) {
          Image(systemName: "exclamationmark.circle")
            .foregroundStyle(palette.warning)
          Text(L10n.isChinese ? "连接服务商以使用 AI 翻译。离线词典现已就绪。" : "Connect a provider to use AI translation. Offline dictionary lookup is available now.")
            .font(AppFont.caption)
            .foregroundStyle(palette.secondaryForeground)
            .frame(maxWidth: .infinity, alignment: .leading)
          Button(L10n.isChinese ? "配置服务商" : "Set up provider") {
            SettingsNavigation.show(.provider) { openSettings() }
          }
          .appButton(.outline, size: .sm)
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.sm)
        .cardSurface(palette)
      }
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
    .onChange(of: model.selectedResultTab) { _, _ in
      copyResetTask?.cancel()
      didCopy = false
    }
    .onChange(of: model.inputText) { _, _ in
      copyResetTask?.cancel()
      didCopy = false
    }
    .onDisappear { copyResetTask?.cancel() }
    .animation(motion, value: model.isTranslating)
    .animation(motion, value: model.outputText.isEmpty)
    .animation(motion, value: model.followUps.count)
  }

  // MARK: - Language pickers

  /// A language belongs to the pane it describes, so each picker sits in that
  /// pane's own strip rather than in a band of its own above the split. The
  /// swap sits between them, on the edge the two panes share.
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
        ? (L10n.isChinese ? "请选择具体的源语言以切换" : "Choose a source language to swap")
        : (L10n.isChinese ? "切换源语言与目标语言" : "Swap the source and target languages")
    )
    .accessibilityLabel(L10n.isChinese ? "切换语言" : "Swap languages")
  }

  // MARK: - Source pane

  private var sourcePane: some View {
    PaneContainer {
      PaneHeader(label: L10n.isChinese ? "原文" : "Source") {
        AppSelect(
          title: L10n.isChinese ? "源语言" : "Source language",
          selection: $settingsStore.settings.sourceLanguage,
          options: model.visibleSourceLanguages,
          label: { $0.shortDisplayName },
          symbol: "globe"
        )
        swapButton
      } trailing: {
        if let sourceBadge { sourceBadge }
      }

      sourceBody

      PaneFooter {
        IconButton(
          title: L10n.isChinese ? (model.isSpeaking(.source) ? "停止朗读" : "朗读原文") : (model.isSpeaking(.source) ? "Stop speaking" : "Speak source text"),
          symbol: model.isSpeaking(.source) ? "speaker.slash.fill" : "speaker.wave.2",
          isDisabled: model.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ) {
          model.speakInput()
        }

        IconButton(title: L10n.isChinese ? "截屏识别文字 (OCR)" : "Capture text from the screen", symbol: "viewfinder") {
          model.captureOCR()
        }

        IconButton(
          title: L10n.isChinese ? "清空" : "Clear",
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
          .accessibilityLabel(L10n.isChinese ? "原文共 \(model.inputText.count) 个字符" : "\(model.inputText.count) characters in the source text")
      }
    }
  }

  private var sourceBadge: Badge? {
    switch model.inputSource {
    case .selection: Badge(text: L10n.isChinese ? "划选" : "Selection", variant: .outline, symbol: "cursorarrow")
    case .ocr: Badge(text: L10n.isChinese ? "截屏" : "Screen", variant: .outline, symbol: "viewfinder")
    case .history: Badge(text: L10n.isChinese ? "历史" : "History", variant: .outline, symbol: "clock")
    case .manual: nil
    }
  }

  private var sourceBody: some View {
    ZStack(alignment: .topLeading) {
      TextEditor(text: inputBinding)
        .font(.system(size: settingsStore.settings.fontSize))
        .lineSpacing(3)
        .foregroundStyle(palette.foreground)
        .scrollContentBackground(.hidden)
        .focused($inputFocused)
        .padding(.horizontal, AppMetrics.readingInset - 5)
        .padding(.vertical, AppMetrics.readingInset - 8)

      if model.inputText.isEmpty {
        Text(L10n.isChinese ? "在此输入或粘贴文本…" : "Type or paste text here.")
          .font(.system(size: settingsStore.settings.fontSize))
          .foregroundStyle(palette.mutedForeground)
          .padding(.horizontal, AppMetrics.readingInset)
          .padding(.vertical, AppMetrics.readingInset - 8)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: - Result pane

  private var resultPane: some View {
    PaneContainer {
      ResultTabBar()
      PaneHeader(label: L10n.isChinese ? "译文与结果" : "Result") {
        if model.dictionaryVisible {
          Label(L10n.isChinese ? "离线词典" : "Offline", systemImage: "book.closed").font(AppFont.caption)
        } else {
          AppSelect(
            title: L10n.isChinese ? "目标语言" : "Target language",
            selection: $settingsStore.settings.targetLanguage,
            options: model.visibleTargetLanguages,
            label: { $0.shortDisplayName }
          )
        }
        if model.isTranslating {
          Spinner()
            .transition(.opacity)
        }
      } trailing: {
        if model.dictionaryVisible {
          IconButton(title: didCopy ? (L10n.isChinese ? "已拷贝" : "Copied") : (L10n.isChinese ? "拷贝词条释义与出处" : "Copy dictionary entries with sources"), symbol: didCopy ? "checkmark" : "doc.on.doc", isDisabled: !model.canCopyResult) {
            copyOutput()
          }
        } else { resultCommands }
      }

      resultBody

      // The composer belongs to the result, not to the window: it appears
      // once there is an answer to ask about and goes away with it.
      //
      // It is also the pane's only bottom strip. Collect and Copy used to sit
      // in a command bar beneath it, which put three stacked rows of chrome —
      // chips, field, buttons — under every answer. They are commands *on* the
      // result, so they read just as well from the pane's own strip, and the
      // question keeps the foot of the pane to itself.
      if !model.dictionaryVisible && !model.outputText.isEmpty {
        FollowUpComposer()
          .transition(.opacity)
      }
    }
  }

  private var resultCommands: some View {
    HStack(spacing: 0) {
      IconButton(
        title: model.isCurrentWordCollected
          ? (L10n.isChinese ? "从生词本中移除此词" : "Remove this word from Vocabulary")
          : (L10n.isChinese ? "将此词与释义保存至生词本" : "Save this word and its explanation to Vocabulary"),
        symbol: model.isCurrentWordCollected ? "bookmark.fill" : "bookmark",
        isDisabled: !model.isCurrentWordCollected
          && (model.outputText.isEmpty || model.inputText.count > 80)
      ) {
        model.toggleCollectCurrentWord()
      }
      .accessibilityLabel(model.isCurrentWordCollected ? (L10n.isChinese ? "已收藏" : "Collected") : (L10n.isChinese ? "收藏" : "Collect"))

      // The result is what a learner has to say out loud, so it speaks in the
      // target language's voice rather than sharing the source pane's button.
      IconButton(
        title: model.isSpeaking(.result) ? (L10n.isChinese ? "停止朗读" : "Stop speaking") : (L10n.isChinese ? "朗读译文" : "Speak the translation"),
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
      .accessibilityLabel(L10n.isChinese ? "朗读译文" : "Speak translation")

      IconButton(
        title: didCopy ? (L10n.isChinese ? "已拷贝" : "Copied") : (L10n.isChinese ? "拷贝译文 (⇧⌘C)" : "Copy the translation (⇧⌘C)"),
        symbol: didCopy ? "checkmark" : "doc.on.doc",
        isDisabled: model.outputText.isEmpty
      ) {
        copyOutput()
      }
      .accessibilityLabel(didCopy ? (L10n.isChinese ? "已拷贝" : "Copied") : (L10n.isChinese ? "拷贝译文" : "Copy translation"))
    }
  }

  @ViewBuilder
  private var resultBody: some View {
    if model.dictionaryVisible {
      DictionaryResultsView()
    } else if model.outputText.isEmpty {
      EmptyState(
        symbol: model.isTranslating ? "ellipsis" : "character.bubble",
        title: model.isTranslating ? (L10n.isChinese ? "正在翻译…" : "Translating…") : model.isLookingUpDictionary ? (L10n.isChinese ? "正在查词…" : "Checking word…") : (L10n.isChinese ? "暂无翻译内容" : "No translation yet"),
        message: model.inputText.isEmpty
          ? (L10n.isChinese ? "在左侧输入文本，或在其他应用中划选文字后按下 ⌥F。" : "Enter text on the left, or press ⌥F while text is selected in another app.")
          : (L10n.isChinese ? "按下 ⌘↩ 开始翻译。" : "Press ⌘↩ to translate.")
      )
      .transition(.opacity)
    } else {
      // Only the follow-up thread follows its stream. A translation or an
      // analysis is read from the top down, so dragging the view along with
      // the tokens pulls the opening lines away from someone who is still
      // reading them; an answer to a question they just asked is the one
      // thing they are waiting to see appear at the bottom.
      FollowingScrollView(
        isFollowing: model.isAnsweringFollowUp,
        trigger: model.resultLength
      ) {
        VStack(alignment: .leading, spacing: 0) {
          if model.outputUsesMarkdown {
            MarkdownText(model.outputText, baseFontSize: settingsStore.settings.fontSize)
          } else {
            Text(model.outputText)
              .font(.system(size: settingsStore.settings.fontSize))
              .lineSpacing(3)
              .textSelection(.enabled)
          }

          FollowUpThread()
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

      // The language pair used to be repeated here. It is set two rows up, in
      // the pane headers, and a status bar that echoes a control the eye can
      // already see is a line of text nobody reads.
    }
    .font(AppFont.caption)
    .foregroundStyle(palette.mutedForeground)
    .frame(height: AppMetrics.statusBarHeight)
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(L10n.isChinese ? "状态：\(model.statusMessage)" : "Status: \(model.statusMessage)")
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

/// A pane's command strip: the language the pane is in, its state, and the
/// commands scoped to it.
///
/// The strip used to open with the pane's name and a glyph. In a two-pane
/// translator those words are the one thing the layout already says on its
/// own, and they were spending the room the language picker needed — so the
/// picker leads instead, and the name survives where it still does work: in
/// the accessibility label.
struct PaneHeader<Leading: View, Trailing: View>: View {
  let label: String
  @ViewBuilder var leading: Leading
  @ViewBuilder var trailing: Trailing

  @Environment(\.palette) private var palette

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: AppSpacing.xs + 2) {
        leading
        Spacer(minLength: AppSpacing.sm)
        trailing
      }
      .padding(.horizontal, AppSpacing.sm + 2)
      .frame(height: AppMetrics.paneHeaderHeight)
      .background(palette.chrome)
      Hairline()
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(label)
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
