import SwiftUI

struct TranslatorView: View {
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var settingsStore: SettingsStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @FocusState private var inputFocused: Bool
  @State private var swapAngle = 0.0
  @State private var didCopy = false
  @State private var copyResetTask: Task<Void, Never>?

  private var motion: Animation? {
    AppMotion.state(reduceMotion: reduceMotion)
  }

  /// Selection captures stay read-only until the user asks to edit them, so an
  /// accidental keystroke cannot destroy text that was grabbed from another app.
  private var showsSelectionPreview: Bool {
    model.inputSource == .selection
      && settingsStore.settings.useCompactSelectionPreview
      && !model.isSelectionExpanded
  }

  var body: some View {
    VStack(spacing: 0) {
      ActionTabBar(actions: model.allActions, selection: actionSelection)
      HSplitView {
        // An explicit ideal width keeps the split proportional. Without it the
        // panes size to whatever their content asks for, and a wide result —
        // a Markdown table, a long code line — pushes text past the window.
        sourcePane
          .frame(
            minWidth: AppMetrics.paneMinWidth,
            idealWidth: AppMetrics.paneIdealWidth,
            maxWidth: .infinity
          )
        resultPane
          .frame(
            minWidth: AppMetrics.paneMinWidth,
            idealWidth: AppMetrics.paneIdealWidth,
            maxWidth: .infinity
          )
      }
      statusBar
    }
    .background(AppDesign.canvas)
    .toolbar { translatorToolbar }
    .navigationSubtitle(languagePairSummary)
    .animation(motion, value: model.isTranslating)
    .animation(motion, value: model.outputText.isEmpty)
    .animation(motion, value: showsSelectionPreview)
  }

  private var languagePairSummary: String {
    let source = settingsStore.settings.sourceLanguage.displayName
    let target = settingsStore.settings.targetLanguage.displayName
    return "\(source) → \(target)"
  }

  // MARK: - Toolbar

  /// The toolbar carries the single command that runs the window's work. Which
  /// action runs is a flat tab strip under the toolbar, so every action is one
  /// click away; everything scoped to one side of the translation lives in that
  /// pane's own header instead.
  @ToolbarContentBuilder
  private var translatorToolbar: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      translateButton
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

  @ViewBuilder
  private var translateButton: some View {
    let button = Button {
      if model.isTranslating {
        model.stopTranslation()
      } else {
        model.translate()
      }
    } label: {
      Label(
        model.isTranslating ? "Stop" : "Translate",
        systemImage: model.isTranslating ? "stop.fill" : "arrow.forward"
      )
      .labelStyle(.titleAndIcon)
    }
    .keyboardShortcut(.return, modifiers: [.command])
    .disabled(
      !model.isTranslating
        && model.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    )
    .help(model.isTranslating ? "Stop translating (⌘.)" : "Translate (⌘↩)")

    if #available(macOS 26.0, *) {
      button.buttonStyle(.glassProminent)
    } else {
      button.buttonStyle(.borderedProminent)
    }
  }

  // MARK: - Source pane

  private var sourcePane: some View {
    VStack(spacing: 0) {
      PaneBar(.header) {
        languagePicker(
          "Source language",
          selection: $settingsStore.settings.sourceLanguage,
          languages: model.visibleSourceLanguages
        )
        Spacer(minLength: AppSpacing.sm)
        swapButton
      }

      sourceBody

      PaneBar(.footer) {
        BarButton(
          title: model.speech.isSpeaking ? "Stop speaking" : "Speak source text",
          symbol: model.speech.isSpeaking ? "speaker.slash.fill" : "speaker.wave.2",
          isDisabled: model.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ) {
          model.speakInput()
        }

        BarButton(title: "Capture text from the screen", symbol: "viewfinder") {
          model.captureOCR()
        }

        if showsSelectionPreview {
          BarButton(title: "Edit the captured text", symbol: "pencil") {
            model.isSelectionExpanded = true
            inputFocused = true
          }
        }

        BarButton(
          title: "Clear",
          symbol: "xmark.circle",
          isDisabled: model.inputText.isEmpty && model.outputText.isEmpty
        ) {
          model.clear()
        }

        Spacer(minLength: AppSpacing.sm)

        Text("\(model.inputText.count) characters")
          .font(.caption)
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .accessibilityLabel("\(model.inputText.count) characters in the source text")
      }
    }
    .contentPane()
  }

  @ViewBuilder
  private var sourceBody: some View {
    if showsSelectionPreview {
      ScrollView {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
          Label("Captured from another app", systemImage: "text.viewfinder")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(model.inputText)
            .font(.system(size: settingsStore.settings.fontSize))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(AppMetrics.readingInset)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .transition(.opacity)
    } else {
      ZStack(alignment: .topLeading) {
        TextEditor(text: $model.inputText)
          .font(.system(size: settingsStore.settings.fontSize))
          .lineSpacing(3)
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
            .foregroundStyle(.tertiary)
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
    VStack(spacing: 0) {
      PaneBar(.header) {
        languagePicker(
          "Target language",
          selection: $settingsStore.settings.targetLanguage,
          languages: model.visibleTargetLanguages
        )
        Spacer(minLength: AppSpacing.sm)
        if model.isTranslating {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel("Translating")
            .transition(.opacity)
        }
      }

      resultBody

      PaneBar(.footer) {
        Button {
          model.collectCurrentWord()
        } label: {
          Label("Collect", systemImage: "bookmark")
        }
        .buttonStyle(.borderless)
        .disabled(model.outputText.isEmpty || model.inputText.count > 80)
        .help("Save this word and its explanation to Vocabulary")

        Spacer(minLength: AppSpacing.sm)

        Button {
          copyOutput()
        } label: {
          Label {
            Text(didCopy ? "Copied" : "Copy")
          } icon: {
            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
              .contentTransition(.symbolEffect(.replace))
          }
        }
        .buttonStyle(.borderless)
        .symbolEffect(.bounce, value: didCopy)
        .disabled(model.outputText.isEmpty)
        .help("Copy the translation (⇧⌘C)")
      }
    }
    .contentPane()
  }

  @ViewBuilder
  private var resultBody: some View {
    if model.outputText.isEmpty {
      ContentUnavailableView {
        Label("No translation yet", systemImage: "character.bubble")
      } description: {
        Text(
          model.inputText.isEmpty
            ? "Enter text on the left, or press ⌥F while text is selected in another app."
            : "Press ⌘↩ to translate."
        )
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .transition(.opacity)
    } else {
      ScrollView {
        Group {
          if model.outputUsesMarkdown || MarkdownParser.looksLikeMarkdown(model.outputText) {
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

  // MARK: - Shared controls

  private func languagePicker(
    _ title: String,
    selection: Binding<LanguageCode>,
    languages: [LanguageCode]
  ) -> some View {
    Picker(title, selection: selection) {
      ForEach(languages) { language in
        Text(language.displayName).tag(language)
      }
    }
    .pickerStyle(.menu)
    .labelsHidden()
    .fixedSize()
    .help(title)
    .accessibilityLabel(title)
  }

  private var swapButton: some View {
    Button {
      model.swapLanguages()
      if let animation = AppMotion.interactive(reduceMotion: reduceMotion) {
        withAnimation(animation) { swapAngle += 180 }
      }
    } label: {
      Image(systemName: "arrow.left.arrow.right")
        .rotationEffect(.degrees(swapAngle))
        .frame(width: 18, height: 18)
    }
    .buttonStyle(.borderless)
    .disabled(settingsStore.settings.sourceLanguage == .auto)
    .help(
      settingsStore.settings.sourceLanguage == .auto
        ? "Choose a source language to swap"
        : "Swap the source and target languages"
    )
    .accessibilityLabel("Swap languages")
  }

  private var statusBar: some View {
    HStack(spacing: AppSpacing.sm) {
      StatusDot(
        color: model.isTranslating ? .accentColor : .secondary.opacity(0.55),
        isActive: model.isTranslating
      )
      Text(model.statusMessage)
      Spacer(minLength: AppSpacing.sm)
      if showsSelectionPreview {
        Label("Read-only capture", systemImage: "lock")
          .labelStyle(.titleAndIcon)
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .padding(.horizontal, AppSpacing.md)
    .frame(height: AppMetrics.statusBarHeight)
    .frame(maxWidth: .infinity)
    .background(.bar)
    .overlay(alignment: .top) { Divider() }
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
