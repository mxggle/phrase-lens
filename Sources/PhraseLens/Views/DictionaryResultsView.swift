import SwiftUI

/// One dictionary surface for the workspace and the selected-text popup.
struct DictionaryResultsView: View {
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var settingsStore: SettingsStore
  @Environment(\.palette) private var palette

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: AppSpacing.md) {
          content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.md)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  @ViewBuilder
  private var content: some View {
    switch model.dictionaryState {
    case .idle:
      Text(L10n.isChinese ? "划选或输入单词以查词。" : "Select or enter a word to look it up.")
    case .loading:
      HStack { ProgressView().controlSize(.small); Text(L10n.isChinese ? "正在检索词典…" : "Looking up dictionary…") }
    case .failed(let message):
      Text(message).foregroundStyle(palette.mutedForeground)
      HStack(spacing: AppSpacing.sm) {
        Button(L10n.isChinese ? "重试" : "Try again") { model.lookupDictionary() }.appButton(.secondary, size: .sm)
        translationButton
      }
    case .result(let result):
      if result.languages.count > 1 {
        Text(L10n.isChinese
          ? "可能所属语言：" + result.languages.map(DictionaryLanguages.name).joined(separator: " · ") + "。可在语言菜单中指定。"
          : "Possible languages: " + result.languages.map(DictionaryLanguages.name).joined(separator: " · ") + ". Use the language menu to choose.")
          .font(AppFont.caption).foregroundStyle(palette.mutedForeground)
      }
      if result.matches.isEmpty {
        Text(L10n.isChinese
          ? (result.supportsPair ? "未找到 \(DictionaryLanguages.name(result.request.definitionLanguage)) 释义的词条。" : "未安装支持该语言及 \(DictionaryLanguages.name(result.request.definitionLanguage)) 释义的离线词典。")
          : (result.supportsPair ? "No entry with definitions in \(DictionaryLanguages.name(result.request.definitionLanguage)) was found." : "No installed dictionary supports this word language and \(DictionaryLanguages.name(result.request.definitionLanguage)) definitions."))
          .fixedSize(horizontal: false, vertical: true)
        Text(L10n.isChinese ? "请尝试输入单词原型，或指定语言。您亦可直接查看 AI 翻译。" : "Try the dictionary form or choose the word language. You can also view an AI translation.")
          .font(AppFont.caption).foregroundStyle(palette.mutedForeground)
        translationButton
      }
      ForEach(result.notices, id: \.self) { Text($0).font(AppFont.caption).foregroundStyle(palette.warning) }
      ForEach(result.matches) { match in
        entryCard(match)
      }
    }
  }

  private var translationButton: some View {
    Button(L10n.isChinese ? "查看 AI 翻译" : "View translation", systemImage: "character.bubble") { model.selectResultTab(.translation) }
      .appButton(.secondary, size: .sm)
  }

  private func entryCard(_ match: DictionaryMatch) -> some View {
    VStack(alignment: .leading, spacing: AppSpacing.sm) {
      HStack(alignment: .firstTextBaseline) {
        Text(match.entry.headword).font(AppFont.title).textSelection(.enabled)
        Spacer(minLength: 0)
        IconButton(title: L10n.isChinese ? "朗读词头" : "Speak dictionary headword", symbol: "speaker.wave.2") {
          model.speakDictionaryEntry(match)
        }
        IconButton(title: L10n.isChinese ? "拷贝词条释义与出处" : "Copy dictionary entry with source", symbol: "doc.on.doc", isDisabled: !match.dictionary.canPersist) {
          model.copyDictionaryEntry(match)
        }
        IconButton(title: L10n.isChinese ? "保存词条到生词本" : "Save dictionary entry", symbol: model.isDictionaryEntrySaved(match) ? "bookmark.fill" : "bookmark", isDisabled: !match.dictionary.canPersist) {
          model.saveDictionaryEntry(match)
        }
      }
      if !match.entry.readings.isEmpty {
        Text(match.entry.readings.joined(separator: " · ")).textSelection(.enabled)
      }
      Text([DictionaryLanguages.name(match.entry.sourceLanguage), match.entry.partOfSpeech]
        .compactMap { $0 }.joined(separator: " · "))
        .font(AppFont.caption).foregroundStyle(palette.mutedForeground)
      if match.entry.headword != model.inputText.trimmingCharacters(in: .whitespacesAndNewlines) {
        Text("\(model.inputText) → \(match.entry.headword)")
          .font(AppFont.caption).foregroundStyle(palette.mutedForeground)
      }
      ForEach(Array(match.entry.senses.enumerated()), id: \.element.id) { index, sense in
        HStack(alignment: .top, spacing: AppSpacing.sm) {
          Text("\(index + 1).").foregroundStyle(palette.mutedForeground)
          VStack(alignment: .leading, spacing: AppSpacing.xxs) {
            Text(sense.glosses.joined(separator: "; "))
              .font(.system(size: settingsStore.settings.fontSize)).textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
            if !sense.labels.isEmpty {
              Text(sense.labels.joined(separator: " · "))
                .font(AppFont.caption).foregroundStyle(palette.mutedForeground)
            }
          }
          Spacer(minLength: 0)
          IconButton(title: L10n.isChinese ? "收藏第 \(index + 1) 条释义" : "Save meaning \(index + 1)", symbol: model.isDictionaryEntrySaved(match, sense: sense) ? "bookmark.fill" : "bookmark", isDisabled: !match.dictionary.canPersist) {
            model.saveDictionaryEntry(match, sense: sense)
          }
        }
      }
      HStack {
        if let url = URL(string: match.entry.sourceURL), url.scheme == "https" {
          Link(match.dictionary.name, destination: url)
        }
        if let url = URL(string: match.dictionary.licenseURL), url.scheme == "https" {
          Link(match.dictionary.license, destination: url)
        }
      }.font(AppFont.caption)
      Text(match.dictionary.attribution)
        .font(AppFont.caption).foregroundStyle(palette.mutedForeground)
    }
    .padding(AppSpacing.md)
    .cardSurface(palette)
  }
}

/// Result navigation is distinct from the action strip: both tabs describe
/// the same source text and keep their own result when the user switches.
struct ResultTabBar: View {
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var settingsStore: SettingsStore
  @State private var showingLanguages = false

  var body: some View {
    if model.dictionaryAvailable {
      HStack(spacing: AppSpacing.sm) {
        Picker("Result type", selection: Binding(
          get: { model.dictionaryVisible ? ResultTab.dictionary : .translation },
          set: { model.selectResultTab($0) }
        )) {
          Text(L10n.isChinese ? "AI 翻译" : "Translation").tag(ResultTab.translation)
          Text(L10n.isChinese ? "离线词典" : "Dictionary").tag(ResultTab.dictionary)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help(L10n.isChinese ? "AI 翻译使用大模型实时解析。离线词典提供权威本地释义。" : "Translation uses AI. Dictionary shows sourced offline definitions.")

        Spacer(minLength: 0)

        if model.dictionaryVisible {
          Button {
            showingLanguages.toggle()
          } label: {
            HStack(spacing: AppSpacing.xs) {
              Text("\(DictionaryLanguages.name(model.dictionarySourceOverride)) → \(DictionaryLanguages.name(settingsStore.settings.dictionaryDefinitionLanguage))")
                .lineLimit(1)
              Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
          }
          .appButton(.ghost, size: .sm)
          .accessibilityLabel(L10n.isChinese ? "词典语言" : "Dictionary languages")
          .help(L10n.isChinese ? "选择词条语言和释义语言" : "Choose the word language and definition language")
          .popover(isPresented: $showingLanguages, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
              Text(L10n.isChinese ? "词条语言" : "Word language").font(AppFont.caption)
              AppSelect(title: L10n.isChinese ? "词条语言" : "Dictionary word language", selection: Binding(
                get: { model.dictionarySourceOverride }, set: { model.setDictionarySource($0) }),
                options: model.dictionarySourceOptions, label: DictionaryLanguages.name, size: .sm, symbol: "globe")
              Text(L10n.isChinese ? "释义语言" : "Definition language").font(AppFont.caption)
              AppSelect(title: L10n.isChinese ? "释义语言" : "Definition language", selection: $settingsStore.settings.dictionaryDefinitionLanguage,
                options: model.dictionaryDefinitionOptions, label: DictionaryLanguages.name, size: .sm)
              Button(L10n.isChinese ? "重新查询" : "Look up again", systemImage: "arrow.clockwise") {
                model.lookupDictionary()
                showingLanguages = false
              }
              .appButton(.secondary, size: .sm)
              .disabled(model.isLookingUpDictionary)
            }
            .padding(AppSpacing.md)
          }
        }
      }
      .padding(.horizontal, AppSpacing.md)
      .padding(.vertical, AppSpacing.sm)
      .onChange(of: model.selectedResultTab) { _, _ in showingLanguages = false }
      Hairline()
    }
  }
}
