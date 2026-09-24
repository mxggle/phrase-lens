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
      Text("Select or enter a word to look it up.")
    case .loading:
      HStack { ProgressView().controlSize(.small); Text("Looking up dictionary…") }
    case .failed(let message):
      Text(message).foregroundStyle(palette.mutedForeground)
      HStack(spacing: AppSpacing.sm) {
        Button("Try again") { model.lookupDictionary() }.appButton(.secondary, size: .sm)
        translationButton
      }
    case .result(let result):
      if result.languages.count > 1 {
        Text("Possible languages: " + result.languages.map(DictionaryLanguages.name).joined(separator: " · ")
          + ". Use the language menu to choose.")
          .font(AppFont.caption).foregroundStyle(palette.mutedForeground)
      }
      if result.matches.isEmpty {
        Text(result.supportsPair
          ? "No entry with definitions in \(DictionaryLanguages.name(result.request.definitionLanguage)) was found."
          : "No installed dictionary supports this word language and \(DictionaryLanguages.name(result.request.definitionLanguage)) definitions.")
          .fixedSize(horizontal: false, vertical: true)
        Text("Try the dictionary form or choose the word language. You can also view an AI translation.")
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
    Button("View translation", systemImage: "character.bubble") { model.selectResultTab(.translation) }
      .appButton(.secondary, size: .sm)
  }

  private func entryCard(_ match: DictionaryMatch) -> some View {
    VStack(alignment: .leading, spacing: AppSpacing.sm) {
      HStack(alignment: .firstTextBaseline) {
        Text(match.entry.headword).font(AppFont.title).textSelection(.enabled)
        Spacer(minLength: 0)
        IconButton(title: "Speak dictionary headword", symbol: "speaker.wave.2") {
          model.speakDictionaryEntry(match)
        }
        IconButton(title: "Copy dictionary entry with source", symbol: "doc.on.doc", isDisabled: !match.dictionary.canPersist) {
          model.copyDictionaryEntry(match)
        }
        IconButton(title: "Save dictionary entry", symbol: model.isDictionaryEntrySaved(match) ? "bookmark.fill" : "bookmark", isDisabled: !match.dictionary.canPersist) {
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
          IconButton(title: "Save meaning \(index + 1)", symbol: model.isDictionaryEntrySaved(match, sense: sense) ? "bookmark.fill" : "bookmark", isDisabled: !match.dictionary.canPersist) {
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
          Text("Translation").tag(ResultTab.translation)
          Text("Dictionary").tag(ResultTab.dictionary)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Translation uses AI. Dictionary shows sourced offline definitions.")

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
          .accessibilityLabel("Dictionary languages")
          .help("Choose the word language and definition language")
          .popover(isPresented: $showingLanguages, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
              Text("Word language").font(AppFont.caption)
              AppSelect(title: "Dictionary word language", selection: Binding(
                get: { model.dictionarySourceOverride }, set: { model.setDictionarySource($0) }),
                options: model.dictionarySourceOptions, label: DictionaryLanguages.name, size: .sm, symbol: "globe")
              Text("Definition language").font(AppFont.caption)
              AppSelect(title: "Definition language", selection: $settingsStore.settings.dictionaryDefinitionLanguage,
                options: model.dictionaryDefinitionOptions, label: DictionaryLanguages.name, size: .sm)
              Button("Look up again", systemImage: "arrow.clockwise") {
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
