import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Taxonomy Localization Extensions

extension VocabularyFacet {
  var localizedTitle: String {
    guard L10n.isChinese else {
      switch self {
      case .unit: return "Unit"
      case .topic: return "Topics"
      case .partOfSpeech: return "Part of Speech"
      case .difficulty: return "Level"
      case .register: return "Register"
      case .languagePair: return "Language"
      }
    }
    switch self {
    case .unit: return "类型"
    case .topic: return "主题"
    case .partOfSpeech: return "词性"
    case .difficulty: return "难度等级"
    case .register: return "语域"
    case .languagePair: return "语言"
    }
  }
}

extension VocabularyGrouping {
  var localizedTitle: String {
    guard L10n.isChinese else { return title }
    switch self {
    case .none: return "不分组"
    case .facet(let facet): return facet.localizedTitle
    case .month: return "按收藏时间"
    }
  }
}

extension VocabularyUnit {
  var localizedDisplayName: String {
    guard L10n.isChinese else { return displayName }
    switch self {
    case .word: return "单词"
    case .phrase: return "短语"
    case .sentence: return "句子"
    }
  }
}

extension VocabularyPartOfSpeech {
  var localizedDisplayName: String {
    guard L10n.isChinese else { return displayName }
    switch self {
    case .noun: return "名词"
    case .verb: return "动词"
    case .adjective: return "形容词"
    case .adverb: return "副词"
    case .conjunction: return "连词"
    case .particle: return "助词"
    case .expression: return "习语表达"
    }
  }
}

extension VocabularyRegister {
  var localizedDisplayName: String {
    guard L10n.isChinese else { return displayName }
    switch self {
    case .spoken: return "口语"
    case .written: return "书面语"
    case .formal: return "正式"
    case .slang: return "俚语与网络"
    case .honorific: return "敬语"
    }
  }
}

extension VocabularyDifficulty {
  var localizedDisplayName: String {
    guard L10n.isChinese else { return displayName }
    switch self {
    case .beginner: return "入门"
    case .elementary: return "初级"
    case .intermediate: return "中级"
    case .advanced: return "高级"
    case .expert: return "精通"
    }
  }
}

extension VocabularyFacetValue {
  var localizedLabel: String {
    guard L10n.isChinese else { return label }
    if isUntagged {
      return "未分类"
    }
    switch facet {
    case .unit:
      switch key {
      case VocabularyUnit.word.rawValue: return "单词"
      case VocabularyUnit.phrase.rawValue: return "短语"
      case VocabularyUnit.sentence.rawValue: return "句子"
      default: return label
      }
    case .partOfSpeech:
      switch key {
      case VocabularyPartOfSpeech.noun.rawValue: return "名词"
      case VocabularyPartOfSpeech.verb.rawValue: return "动词"
      case VocabularyPartOfSpeech.adjective.rawValue: return "形容词"
      case VocabularyPartOfSpeech.adverb.rawValue: return "副词"
      case VocabularyPartOfSpeech.conjunction.rawValue: return "连词"
      case VocabularyPartOfSpeech.particle.rawValue: return "助词"
      case VocabularyPartOfSpeech.expression.rawValue: return "习语表达"
      default: return label
      }
    case .register:
      switch key {
      case VocabularyRegister.spoken.rawValue: return "口语"
      case VocabularyRegister.written.rawValue: return "书面语"
      case VocabularyRegister.formal.rawValue: return "正式"
      case VocabularyRegister.slang.rawValue: return "俚语与网络"
      case VocabularyRegister.honorific.rawValue: return "敬语"
      default: return label
      }
    case .difficulty:
      switch key {
      case String(VocabularyDifficulty.beginner.rawValue): return "入门"
      case String(VocabularyDifficulty.elementary.rawValue): return "初级"
      case String(VocabularyDifficulty.intermediate.rawValue): return "中级"
      case String(VocabularyDifficulty.advanced.rawValue): return "高级"
      case String(VocabularyDifficulty.expert.rawValue): return "精通"
      default: return label
      }
    case .topic, .languagePair:
      return label
    }
  }
}

// MARK: - Shared scaffolding

/// The frame both library sections share: a filter bar, then either the
/// collection or the reason it is empty.
///
/// Both sections are the same shape — search, select, act on the selection —
/// so they get the same chrome, and the difference between them stays in the
/// rows.
private struct LibraryScaffold<Toolbar: View, Content: View>: View {
  @Binding var searchText: String
  let searchPrompt: String
  let count: Int
  let countNoun: String
  @ViewBuilder var toolbar: Toolbar
  @ViewBuilder var content: Content

  @Environment(\.palette) private var palette
  @Environment(\.layoutWidth) private var layoutWidth

  var body: some View {
    VStack(spacing: 0) {
      filterBar
      Hairline()
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(palette.background)
  }

  private var filterBar: some View {
    HStack(spacing: AppSpacing.sm) {
      AppTextField(
        placeholder: searchPrompt,
        text: $searchText,
        symbol: "magnifyingglass",
        size: .sm
      )
      .frame(maxWidth: layoutWidth.isCompact ? .infinity : 320)

      if !layoutWidth.isCompact {
        let text: String = {
          if L10n.isChinese {
            if countNoun == "translations" {
              return "\(count) 条翻译"
            } else if countNoun == "words" {
              return "\(count) 个生词"
            } else {
              return "\(count) \(countNoun)"
            }
          } else {
            let noun: String
            if count == 1 {
              if countNoun == "translations" {
                noun = "translation"
              } else if countNoun == "words" {
                noun = "word"
              } else {
                noun = countNoun
              }
            } else {
              noun = countNoun
            }
            return "\(count) \(noun)"
          }
        }()
        Text(text)
          .font(AppFont.caption)
          .monospacedDigit()
          .foregroundStyle(palette.mutedForeground)
      }

      Spacer(minLength: AppSpacing.sm)

      toolbar
    }
    .padding(.horizontal, AppSpacing.lg)
    .padding(.vertical, AppSpacing.sm + 2)
    .background(palette.chrome)
  }
}

/// The delete confirmation both library sections share.
///
/// Nothing deleted from the library can be brought back — there is no trash and
/// no undo — so every delete goes through here, including a single row from a
/// context menu.
extension View {
  fileprivate func libraryDeleteConfirmation(
    isPresented: Binding<Bool>,
    count: Int,
    singular: String,
    plural: String,
    perform: @escaping () -> Void
  ) -> some View {
    let noun = count == 1 ? singular : plural
    let title = L10n.isChinese
      ? "确认删除这 \(count) 个\(singular == "word" ? "生词" : "条目")？"
      : "Delete \(count) \(noun)?"
    let destructiveTitle = L10n.isChinese
      ? "删除 \(count) 项"
      : "Delete \(count) \(noun.capitalized)"
    let cancelTitle = L10n.isChinese ? "取消" : "Cancel"
    let messageText = L10n.isChinese
      ? "所选内容将从本机彻底移除，此操作无法撤销。"
      : "\(count == 1 ? "This \(singular) is" : "These \(count) \(plural) are") removed from this Mac. There is no undo."

    return confirmationDialog(
      title,
      isPresented: isPresented,
      titleVisibility: .visible
    ) {
      Button(destructiveTitle, role: .destructive, action: perform)
      Button(cancelTitle, role: .cancel) {}
    } message: {
      Text(messageText)
    }
  }
}

/// A selectable card in a library collection.
///
/// Rows are cards rather than table rows because each one holds two blocks of
/// prose. A table row would have to truncate one of them to stay on a line.
private struct LibraryCard<Content: View>: View {
  let isSelected: Bool
  let onSelect: (_ extending: Bool) -> Void
  var onOpen: (() -> Void)?
  @ViewBuilder var content: Content

  @Environment(\.palette) private var palette
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isHovering = false

  var body: some View {
    content
      .padding(AppSpacing.md)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(fill, in: shape)
      .overlay {
        shape.strokeBorder(
          isSelected ? palette.borderStrong : palette.border,
          lineWidth: 1
        )
      }
      .overlay {
        if isSelected {
          shape.strokeBorder(palette.ring, lineWidth: 3).padding(-2)
        }
      }
      .contentShape(shape)
      .onHover { isHovering = $0 }
      .animation(AppMotion.hover(reduceMotion: reduceMotion), value: isHovering)
      .animation(AppMotion.hover(reduceMotion: reduceMotion), value: isSelected)
      .onTapGesture(count: 2) { onOpen?() }
      // Reading the live modifier flags is what lets one tap handler extend
      // the selection on ⌘-click and replace it otherwise, the way a list
      // does. A second `.modifiers(.command)` gesture would fire alongside the
      // plain one rather than instead of it.
      .onTapGesture { onSelect(NSEvent.modifierFlags.contains(.command)) }
      .accessibilityElement(children: .combine)
      .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : [.isButton])
  }

  private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
  }

  private var fill: Color {
    if isSelected { return palette.surfaceElevated }
    return isHovering ? palette.surfaceElevated : palette.surface
  }
}

/// A run of rows under one heading. A collection that is not grouped is a
/// single section with no heading, so both shapes go down the same path.
private struct LibraryListSection<Item: Identifiable>: Identifiable {
  let id: String
  let title: String?
  let items: [Item]
}

/// Scrolling body shared by both collections.
private struct LibraryList<Item: Identifiable, Row: View>: View {
  let sections: [LibraryListSection<Item>]
  /// Widest a single column may get before the grid adds another one.
  var columnMinWidth: CGFloat?
  @ViewBuilder var row: (Item) -> Row

  @Environment(\.layoutWidth) private var layoutWidth

  init(
    items: [Item],
    columnMinWidth: CGFloat? = nil,
    @ViewBuilder row: @escaping (Item) -> Row
  ) {
    self.sections = [LibraryListSection(id: "all", title: nil, items: items)]
    self.columnMinWidth = columnMinWidth
    self.row = row
  }

  init(
    sections: [LibraryListSection<Item>],
    columnMinWidth: CGFloat? = nil,
    @ViewBuilder row: @escaping (Item) -> Row
  ) {
    self.sections = sections
    self.columnMinWidth = columnMinWidth
    self.row = row
  }

  /// Headings only pin when there are headings; an ungrouped list must not pay
  /// for a pinned empty view at the top of its scroller.
  private var pinnedViews: PinnedScrollableViews {
    sections.contains { $0.title != nil } ? [.sectionHeaders] : []
  }

  var body: some View {
    ScrollView {
      if let columnMinWidth, !layoutWidth.isCompact {
        LazyVGrid(
          columns: [
            GridItem(
              .adaptive(minimum: columnMinWidth),
              spacing: AppSpacing.md,
              alignment: .topLeading
            )
          ],
          alignment: .leading,
          spacing: AppSpacing.md,
          pinnedViews: pinnedViews
        ) {
          content
        }
        .padding(AppSpacing.lg)
      } else {
        LazyVStack(spacing: AppSpacing.sm, pinnedViews: pinnedViews) {
          content
        }
        .padding(AppSpacing.lg)
      }
    }
    .scrollIndicators(.automatic)
  }

  @ViewBuilder
  private var content: some View {
    ForEach(sections) { section in
      Section {
        ForEach(section.items) { row($0) }
      } header: {
        if let title = section.title {
          LibrarySectionHeader(title: title, count: section.items.count)
        }
      }
    }
  }
}

/// The heading over one group.
private struct LibrarySectionHeader: View {
  let title: String
  let count: Int

  @Environment(\.palette) private var palette

  private var displayTitle: String {
    guard L10n.isChinese else { return title }
    switch title {
    case "Not tagged": return "未分类"
    case "Word": return "单词"
    case "Phrase": return "短语"
    case "Sentence": return "句子"
    case "Noun": return "名词"
    case "Verb": return "动词"
    case "Adjective": return "形容词"
    case "Adverb": return "副词"
    case "Conjunction": return "连词"
    case "Particle": return "助词"
    case "Expression": return "习语表达"
    case "Spoken": return "口语"
    case "Written": return "书面语"
    case "Formal": return "正式"
    case "Slang & internet": return "俚语与网络"
    case "Honorific": return "敬语"
    case "Beginner": return "入门"
    case "Elementary": return "初级"
    case "Intermediate": return "中级"
    case "Advanced": return "高级"
    case "Expert": return "精通"
    default: return title
    }
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
      Text(displayTitle)
        .font(AppFont.heading)
        .foregroundStyle(palette.foreground)
        .lineLimit(1)
        .truncationMode(.tail)
      Text("\(count)")
        .font(AppFont.caption)
        .monospacedDigit()
        .foregroundStyle(palette.mutedForeground)
      Spacer(minLength: 0)
    }
    .padding(.top, AppSpacing.sm)
    .padding(.bottom, AppSpacing.xs)
    .frame(maxWidth: .infinity, alignment: .leading)
    // The heading stays put while its cards scroll under it, so the fill has
    // to reach past the grid's own padding — otherwise a card slides through
    // the gutter beside the heading in plain view. Only horizontally: growing
    // it vertically would overlap the row above whenever it is not pinned.
    .background { palette.background.padding(.horizontal, -AppSpacing.lg) }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(L10n.isChinese ? "\(displayTitle)，\(count) 个生词" : "\(title), \(count) words")
    .accessibilityAddTraits(.isHeader)
  }
}

// MARK: - History

struct HistoryView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.layoutWidth) private var layoutWidth
  @State private var searchText = ""
  @State private var selection = Set<UUID>()
  @State private var pendingDelete = Set<UUID>()
  @State private var isConfirmingDelete = false

  private var filtered: [HistoryEntry] {
    guard !searchText.isEmpty else { return model.history }
    return model.history.filter {
      $0.sourceText.localizedCaseInsensitiveContains(searchText)
        || $0.translatedText.localizedCaseInsensitiveContains(searchText)
        || $0.actionName.localizedCaseInsensitiveContains(searchText)
    }
  }

  var body: some View {
    let filteredEntries = filtered
    LibraryScaffold(
      searchText: $searchText,
      searchPrompt: L10n.isChinese ? "搜索历史记录…" : "Search history…",
      count: filteredEntries.count,
      countNoun: "translations"
    ) {
      toolbar
    } content: {
      if filteredEntries.isEmpty {
        emptyState
      } else {
        LibraryList(items: filteredEntries) { entry in
          LibraryCard(
            isSelected: selection.contains(entry.id),
            onSelect: { extending in select(entry.id, extending: extending) },
            onOpen: { model.restore(entry) }
          ) {
            HistoryRow(entry: entry)
          }
          .contextMenu {
            Button(L10n.isChinese ? "在翻译器中载入" : "Restore in translator") {
              model.restore(entry)
            }
            Divider()
            Button(L10n.isChinese ? "拷贝原文" : "Copy source text") {
              copySourceText(of: entry)
            }
            Button(L10n.isChinese ? "拷贝译文" : "Copy translated text") {
              copyTranslatedText(of: entry)
            }
            Divider()
            Button(
              entry.favorite
                ? (L10n.isChinese ? "取消收藏" : "Remove from Favorites")
                : (L10n.isChinese ? "添加到收藏" : "Add to Favorites")
            ) {
              model.toggleFavorite(entry)
            }
            Divider()
            Button(L10n.isChinese ? "删除此条记录" : "Delete translation", role: .destructive) {
              confirmDelete(of: [entry.id])
            }
          }
        }
      }
    }
    .libraryDeleteConfirmation(
      isPresented: $isConfirmingDelete,
      count: pendingDelete.count,
      singular: "translation",
      plural: "translations"
    ) {
      model.deleteHistory(ids: pendingDelete)
      selection.subtract(pendingDelete)
      pendingDelete.removeAll()
    }
  }

  private func confirmDelete(of ids: Set<UUID>) {
    guard !ids.isEmpty else { return }
    pendingDelete = ids
    isConfirmingDelete = true
  }

  @ViewBuilder
  private var toolbar: some View {
    let selected = selection.first.flatMap { id in model.history.first { $0.id == id } }

    Button {
      if let selected { model.restore(selected) }
    } label: {
      AdaptiveLabel(
        title: L10n.isChinese ? "在翻译器中载入" : "Restore in translator",
        symbol: "arrow.uturn.backward",
        iconOnly: layoutWidth.isCompact
      )
    }
    .appButton(.outline, size: .sm)
    .disabled(selection.count != 1)
    .help(L10n.isChinese ? "在翻译器中载入" : "Restore in translator")
    .accessibilityLabel(L10n.isChinese ? "在翻译器中载入" : "Restore in translator")

    Button {
      exportHistory()
    } label: {
      AdaptiveLabel(
        title: L10n.isChinese ? "导出" : "Export",
        symbol: "square.and.arrow.up",
        iconOnly: layoutWidth.isCompact
      )
    }
    .appButton(.outline, size: .sm)
    .disabled(model.history.isEmpty)
    .help(L10n.isChinese ? "导出历史记录 (JSON)" : "Export History (JSON)")
    .accessibilityLabel(L10n.isChinese ? "导出历史记录 (JSON)" : "Export History (JSON)")

    Button {
      confirmDelete(of: Set(model.history.map(\.id)))
    } label: {
      AdaptiveLabel(
        title: L10n.isChinese ? "清空" : "Clear",
        symbol: "trash.slash",
        iconOnly: layoutWidth.isCompact
      )
    }
    .appButton(.ghost, size: .sm)
    .disabled(model.history.isEmpty)
    .help(L10n.isChinese ? "清空历史记录" : "Clear History")
    .accessibilityLabel(L10n.isChinese ? "清空历史记录" : "Clear History")

    Button {
      confirmDelete(of: selection)
    } label: {
      AdaptiveLabel(
        title: L10n.isChinese ? "删除" : "Delete",
        symbol: "trash",
        iconOnly: layoutWidth.isCompact
      )
    }
    .appButton(.destructiveGhost, size: .sm)
    .disabled(selection.isEmpty)
    .help(L10n.isChinese ? "删除所选记录" : "Delete selected translations")
    .accessibilityLabel(L10n.isChinese ? "删除所选记录" : "Delete selected translations")
  }

  private func select(_ id: UUID, extending: Bool) {
    if extending {
      if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    } else {
      selection = [id]
    }
  }

  private func copySourceText(of entry: HistoryEntry) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(entry.sourceText, forType: .string)
  }

  private func copyTranslatedText(of entry: HistoryEntry) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(entry.translatedText, forType: .string)
  }

  private func exportHistory() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = "phraselens-history.json"
    panel.prompt = L10n.isChinese ? "导出" : "Export"
    panel.title = L10n.isChinese ? "导出历史记录 (JSON)" : "Export History (JSON)"
    if panel.runModal() == .OK, let url = panel.url {
      do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(model.history)
        try data.write(to: url)
      } catch {
        model.errorMessage = error.localizedDescription
      }
    }
  }

  @ViewBuilder
  private var emptyState: some View {
    if searchText.isEmpty {
      EmptyState(
        symbol: "clock.arrow.circlepath",
        title: L10n.isChinese ? "暂无翻译历史" : "No saved translations",
        message: L10n.isChinese
          ? "您在工作区或划选浮窗中的翻译记录将自动保存在这里。"
          : "Translations you make in the workspace or the pop-up are saved here automatically."
      )
    } else {
      EmptyState(
        symbol: "magnifyingglass",
        title: L10n.isChinese ? "未找到匹配的翻译记录" : "No matching translations",
        message: L10n.isChinese
          ? "尝试使用其他关键词搜索。"
          : "Try searching for a different word or phrase."
      ) {
        Button(L10n.isChinese ? "清除搜索" : "Clear Search") { searchText = "" }
          .appButton(.outline, size: .sm)
      }
    }
  }
}

private struct HistoryRow: View {
  let entry: HistoryEntry

  @Environment(\.palette) private var palette
  @Environment(\.layoutWidth) private var layoutWidth

  var body: some View {
    VStack(alignment: .leading, spacing: AppSpacing.sm) {
      HStack(spacing: AppSpacing.sm) {
        Badge(text: entry.actionName, variant: .neutral)
        Badge(
          text: "\(entry.sourceLanguage.displayName) → \(entry.resultLanguageName)",
          variant: .outline
        )
        if entry.favorite {
          Image(systemName: "star.fill")
            .font(.system(size: 9))
            .foregroundStyle(palette.warning)
            .accessibilityLabel(L10n.isChinese ? "已收藏" : "Favorite")
        }
        Spacer(minLength: AppSpacing.sm)
        Text(entry.createdAt, format: .relative(presentation: .named))
          .font(AppFont.caption)
          .foregroundStyle(palette.mutedForeground)
          .lineLimit(1)
          .layoutPriority(1)
      }

      // Wide enough, and the two texts sit side by side with a rule between
      // them, which is how a translation is read. Narrower, they stack.
      if layoutWidth >= .wide {
        HStack(alignment: .top, spacing: AppSpacing.lg) {
          textBlock(entry.sourceText, isSource: true)
          textBlock(entry.translatedText, isSource: false)
            .overlay(alignment: .leading) {
              Rectangle()
                .fill(palette.border)
                .frame(width: 1)
                .padding(.leading, -AppSpacing.sm)
                .accessibilityHidden(true)
            }
        }
      } else {
        VStack(alignment: .leading, spacing: AppSpacing.xs + 2) {
          textBlock(entry.sourceText, isSource: true)
          textBlock(entry.translatedText, isSource: false)
        }
      }

      if let context = entry.selectionContext,
        !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xs) {
          Badge(text: L10n.isChinese ? "语境" : "Context", variant: .neutral)
          Text(context.trimmingCharacters(in: .whitespacesAndNewlines))
            .font(AppFont.caption)
            .foregroundStyle(palette.mutedForeground)
            .lineLimit(2)
        }
      }
    }
    .accessibilityLabel(
      "\(entry.sourceText). \(entry.dictionarySnapshot == nil ? (L10n.isChinese ? "翻译" : "Translated") : (L10n.isChinese ? "词典" : "Dictionary")): \(entry.translatedText). "
        + "\(entry.actionName), \(entry.sourceLanguage.displayName) \(L10n.isChinese ? "至" : "to") "
        + entry.resultLanguageName
        + (entry.selectionContext.map { " \(L10n.isChinese ? "语境" : "Context"): \($0)" } ?? "")
    )
  }

  private func textBlock(_ text: String, isSource: Bool) -> some View {
    Text(text)
      .font(isSource ? AppFont.bodyMedium : AppFont.body)
      .foregroundStyle(isSource ? palette.foreground : palette.mutedForeground)
      .lineLimit(isSource ? 2 : 3)
      .multilineTextAlignment(.leading)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

// MARK: - Vocabulary

struct VocabularyView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.palette) private var palette
  @Environment(\.layoutWidth) private var layoutWidth
  @State private var searchText = ""
  @State private var selection = Set<UUID>()
  @State private var pendingDelete = Set<UUID>()
  @State private var isConfirmingDelete = false
  @State private var filter = VocabularyFilter()
  @State private var grouping: VocabularyGrouping = .none
  @State private var isFilterPresented = false

  /// What search left, before the rail has had its turn.
  ///
  /// The order matters for the counts: a rail built over the whole collection
  /// would offer "Verb · 28" beside a search that only matched three words,
  /// and every one of those rows would lead somewhere empty.
  private var searchMatches: [VocabularyEntry] {
    guard !searchText.isEmpty else { return model.vocabulary }
    return model.vocabulary.filter { entry in
      entry.word.localizedCaseInsensitiveContains(searchText)
        || entry.explanation.localizedCaseInsensitiveContains(searchText)
        || (entry.tags?.topics ?? []).contains {
          $0.localizedCaseInsensitiveContains(searchText)
        }
    }
  }

  var body: some View {
    let matches = searchMatches
    let sections = VocabularyFacets.sections(for: matches, filter: filter)
    let entries = VocabularyFacets.apply(filter, to: matches)
    let unfiled = model.unfiledVocabularyCount
    let showsRail = !layoutWidth.isCompact && !sections.isEmpty
    let showsOrganizeBar = model.isOrganizingVocabulary || unfiled > 0

    LibraryScaffold(
      searchText: $searchText,
      searchPrompt: L10n.isChinese ? "搜索生词本…" : "Search vocabulary…",
      count: entries.count,
      countNoun: "words"
    ) {
      toolbar(sections: sections)
    } content: {
      HStack(spacing: 0) {
        if showsRail {
          VocabularyFacetRail(sections: sections, filter: $filter)
            .frame(width: 212)
          Rectangle()
            .fill(palette.border)
            .frame(width: 1)
            .accessibilityHidden(true)
        }

        VStack(spacing: 0) {
          if showsOrganizeBar {
            VocabularyOrganizeBar(
              progress: model.vocabularyOrganizing,
              unfiled: unfiled,
              organize: { model.organizeVocabulary() },
              cancel: { model.cancelVocabularyOrganizing() }
            )
            Hairline()
          }
          if entries.isEmpty {
            emptyState
          } else if grouping == .none {
            // The rail costs the grid a column's worth of width, so the
            // tiles are allowed to run a little narrower before they give one
            // up — otherwise turning the rail on at a common window size drops
            // the collection to a single stretched column.
            LibraryList(items: entries, columnMinWidth: 280) { entry in
              card(for: entry)
            }
          } else {
            LibraryList(
              sections: VocabularyFacets.groups(of: entries, by: grouping).map {
                LibraryListSection(id: $0.key, title: $0.title, items: $0.entries)
              },
              columnMinWidth: 280
            ) { entry in
              card(for: entry)
            }
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    // A topic whose last word was deleted leaves a choice armed against a row
    // that is no longer drawn, which shows an empty grid and no way out of it.
    .onChange(of: model.vocabulary) { _, updated in
      filter.prune(to: VocabularyFacets.availableValues(for: updated))
    }
    .libraryDeleteConfirmation(
      isPresented: $isConfirmingDelete,
      count: pendingDelete.count,
      singular: "word",
      plural: "words"
    ) {
      model.deleteVocabulary(ids: pendingDelete)
      selection.subtract(pendingDelete)
      pendingDelete.removeAll()
    }
  }

  private func card(for entry: VocabularyEntry) -> some View {
    LibraryCard(
      isSelected: selection.contains(entry.id),
      onSelect: { extending in select(entry.id, extending: extending) },
      onOpen: { speak(entry: entry) }
    ) {
      VocabularyRow(entry: entry)
    }
    .contextMenu {
      Button(L10n.isChinese ? "朗读单词" : "Speak word") { speak(entry: entry) }
      Button(L10n.isChinese ? "拷贝单词" : "Copy word") { copyWord(of: entry) }
      Button(L10n.isChinese ? "拷贝释义" : "Copy Explanation") { copyExplanation(of: entry) }
      Button(L10n.isChinese ? "AI 智能整理分类" : "Organize with AI") {
        model.retagVocabulary(ids: [entry.id])
      }
      .disabled(model.isOrganizingVocabulary)
      Divider()
      Button(L10n.isChinese ? "移出生词本" : "Delete word", role: .destructive) {
        confirmDelete(of: [entry.id])
      }
    }
  }

  @ViewBuilder
  private func toolbar(sections: [VocabularyFacetSection]) -> some View {
    if layoutWidth.isCompact, !sections.isEmpty {
      Button {
        isFilterPresented = true
      } label: {
        AdaptiveLabel(
          title: filter.isEmpty
            ? (L10n.isChinese ? "筛选" : "Filters")
            : (L10n.isChinese ? "筛选 (\(filter.count))" : "Filters (\(filter.count))"),
          symbol: "line.3.horizontal.decrease",
          iconOnly: false
        )
      }
      .appButton(filter.isEmpty ? .outline : .secondary, size: .sm)
      .help(L10n.isChinese ? "按类型、主题或等级筛选生词本" : "Narrow the collection by type, topic, or level")
      .popover(isPresented: $isFilterPresented, arrowEdge: .bottom) {
        VocabularyFacetRail(sections: sections, filter: $filter)
          .frame(width: 240, height: 360)
      }
    }

    AppSelect(
      title: L10n.isChinese ? "按分类对生词本进行分组" : "Group the collection into sections",
      selection: $grouping,
      options: VocabularyGrouping.allCases,
      // Narrow windows get the bare axis: the bar is already carrying a search
      // field and two commands, and "Group: Part of speech" is wider than the
      // room left for it.
      label: { grouping in
        let name = grouping.localizedTitle
        if layoutWidth.isCompact || grouping == .none { return name }
        return L10n.isChinese ? "分组：\(name)" : "Group: \(name)"
      },
      size: .sm,
      symbol: "square.stack.3d.up"
    )

    Button {
      model.organizeVocabulary()
    } label: {
      AdaptiveLabel(
        title: L10n.isChinese ? "AI 智能整理分类" : "Organize with AI",
        symbol: "sparkles",
        iconOnly: layoutWidth.isCompact
      )
    }
    .appButton(.outline, size: .sm)
    .disabled(model.isOrganizingVocabulary || model.vocabulary.isEmpty)
    .help(L10n.isChinese ? "AI 智能整理分类" : "Organize with AI")
    .accessibilityLabel(L10n.isChinese ? "AI 智能整理分类" : "Organize with AI")

    Button {
      exportVocabulary()
    } label: {
      AdaptiveLabel(
        title: L10n.isChinese ? "导出" : "Export",
        symbol: "square.and.arrow.up",
        iconOnly: layoutWidth.isCompact
      )
    }
    .appButton(.outline, size: .sm)
    .disabled(model.vocabulary.isEmpty)
    .help(L10n.isChinese ? "导出生词本" : "Export Vocabulary (JSON / CSV)")
    .accessibilityLabel(L10n.isChinese ? "导出生词本" : "Export Vocabulary")

    Button {
      confirmDelete(of: selection)
    } label: {
      AdaptiveLabel(
        title: L10n.isChinese ? "删除" : "Delete",
        symbol: "trash",
        iconOnly: layoutWidth.isCompact
      )
    }
    .appButton(.destructiveGhost, size: .sm)
    .disabled(selection.isEmpty)
    .help(L10n.isChinese ? "删除所选生词" : "Delete selected words")
    .accessibilityLabel(L10n.isChinese ? "删除所选生词" : "Delete selected words")
  }

  private func confirmDelete(of ids: Set<UUID>) {
    guard !ids.isEmpty else { return }
    pendingDelete = ids
    isConfirmingDelete = true
  }

  private func select(_ id: UUID, extending: Bool) {
    if extending {
      if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    } else {
      selection = [id]
    }
  }

  private func copyExplanation(of entry: VocabularyEntry) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(entry.explanation, forType: .string)
  }

  private func copyWord(of entry: VocabularyEntry) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(entry.word, forType: .string)
  }

  private func speak(entry: VocabularyEntry) {
    let settings = model.settingsStore.settings
    model.speech.speak(
      entry.word,
      language: entry.sourceLanguage,
      rate: settings.speechRate,
      volume: settings.speechVolume,
      provider: settings.resolvedTTSProvider
    )
  }

  private func exportVocabulary() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json, .commaSeparatedText]
    panel.nameFieldStringValue = "phraselens-vocabulary.json"
    panel.prompt = L10n.isChinese ? "导出" : "Export"
    panel.title = L10n.isChinese ? "导出生词本" : "Export Vocabulary"
    if panel.runModal() == .OK, let url = panel.url {
      do {
        if url.pathExtension.lowercased() == "csv" {
          var csv = "Word,Explanation,Source Language,Target Language,Created At\n"
          for entry in model.vocabulary {
            let escapedWord = "\"" + entry.word.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            let escapedExplanation = "\"" + entry.explanation.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            let line = "\(escapedWord),\(escapedExplanation),\(entry.sourceLanguage.rawValue),\(entry.targetLanguage.rawValue),\(entry.createdAt.ISO8601Format())\n"
            csv += line
          }
          try csv.write(to: url, atomically: true, encoding: .utf8)
        } else {
          let encoder = JSONEncoder()
          encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
          encoder.dateEncodingStrategy = .iso8601
          let data = try encoder.encode(model.vocabulary)
          try data.write(to: url)
        }
      } catch {
        model.errorMessage = error.localizedDescription
      }
    }
  }

  @ViewBuilder
  private var emptyState: some View {
    if !filter.isEmpty {
      EmptyState(
        symbol: "line.3.horizontal.decrease",
        title: L10n.isChinese ? "未找到匹配的生词" : "No matching words",
        message: L10n.isChinese
          ? "尝试其他关键词或清除筛选条件。"
          : "Try a different search term or clear the facet filters."
      ) {
        Button(L10n.isChinese ? "清除筛选" : "Clear Filters") { filter.clear() }
          .appButton(.outline, size: .sm)
      }
    } else if !searchText.isEmpty {
      EmptyState(
        symbol: "magnifyingglass",
        title: L10n.isChinese ? "未找到匹配的生词" : "No matching words",
        message: L10n.isChinese
          ? "尝试其他关键词或清除筛选条件。"
          : "Try a different search term or clear the facet filters."
      ) {
        Button(L10n.isChinese ? "清除搜索" : "Clear Search") { searchText = "" }
          .appButton(.outline, size: .sm)
      }
    } else {
      EmptyState(
        symbol: "books.vertical",
        title: L10n.isChinese ? "生词本为空" : "No saved words",
        message: L10n.isChinese
          ? "在翻译结果或词典卡片中点按书签图标，即可收集想学习的生词。"
          : "Click the bookmark icon on any result or dictionary entry to collect words you want to study."
      )
    }
  }
}

/// The strip that offers to file what is not filed, and reports on the filing
/// while it runs.
///
/// It sits above the collection rather than in a dialog because filing is
/// optional: the collection is fully usable unfiled, and a modal would make a
/// convenience look like a requirement.
private struct VocabularyOrganizeBar: View {
  let progress: VocabularyOrganizeProgress?
  let unfiled: Int
  let organize: () -> Void
  let cancel: () -> Void

  @Environment(\.palette) private var palette

  var body: some View {
    HStack(spacing: AppSpacing.sm) {
      if let progress {
        Spinner(size: 12)
        Text(
          L10n.isChinese
            ? "正在整理 \(progress.completed) / \(progress.total)…"
            : "Organizing \(progress.completed) of \(progress.total)…"
        )
        .font(AppFont.caption)
        .foregroundStyle(palette.secondaryForeground)
        .monospacedDigit()
        Spacer(minLength: AppSpacing.sm)
        Button(L10n.isChinese ? "停止" : "Stop", action: cancel)
          .appButton(.ghost, size: .xs)
      } else {
        Image(systemName: "sparkles")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(palette.mutedForeground)
        Text(
          L10n.isChinese
            ? "\(unfiled) 个生词尚未分类。"
            : (unfiled == 1
              ? "1 word has not been sorted into categories yet."
              : "\(unfiled) words have not been sorted into categories yet.")
        )
        .font(AppFont.caption)
        .foregroundStyle(palette.secondaryForeground)
        Spacer(minLength: AppSpacing.sm)
        Button(L10n.isChinese ? "整理" : "Organize", action: organize)
          .appButton(.outline, size: .xs)
          .help(
            L10n.isChinese
              ? "使用 AI 模型对这些生词按类型、主题、词性和级别分类"
              : "Have the model file these under type, topic, part of speech, and level"
          )
      }
    }
    .padding(.horizontal, AppSpacing.lg)
    .padding(.vertical, AppSpacing.sm)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(palette.muted)
    .accessibilityElement(children: .contain)
  }
}

/// Every dimension the collection can be cut along, with a live count on each
/// value.
///
/// Values inside a section are an OR and sections are ANDed together, and the
/// counts are taken with the section's own choices lifted — so arming one verb
/// leaves the other parts of speech standing beside it with their real totals
/// rather than collapsing them all to zero.
private struct VocabularyFacetRail: View {
  let sections: [VocabularyFacetSection]
  @Binding var filter: VocabularyFilter

  @Environment(\.palette) private var palette

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: AppSpacing.sm) {
        Eyebrow(text: L10n.isChinese ? "筛选" : "Filter")
        Spacer(minLength: AppSpacing.xs)
        if !filter.isEmpty {
          Button(L10n.isChinese ? "全部" : "All") { filter.clear() }
            .appButton(.ghost, size: .xs)
            .accessibilityLabel(L10n.isChinese ? "显示全部（清除筛选）" : "Show all (Clear filters)")
        }
      }
      .frame(height: AppMetrics.paneHeaderHeight)
      .padding(.horizontal, AppSpacing.md)

      Hairline()

      ScrollView {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
          ForEach(sections) { section in
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
              Eyebrow(text: section.facet.localizedTitle)
                .padding(.horizontal, AppSpacing.sm)
                .padding(.bottom, AppSpacing.xxs)
              ForEach(section.rows) { row in
                VocabularyFacetRow(row: row, isOn: filter.isOn(row.value)) {
                  filter.toggle(row.value)
                }
              }
            }
          }
        }
        .padding(.vertical, AppSpacing.md)
        .padding(.horizontal, AppSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .scrollIndicators(.automatic)
    }
    .background(palette.chrome)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(L10n.isChinese ? "生词本筛选" : "Vocabulary filters")
  }
}

private struct VocabularyFacetRow: View {
  let row: VocabularyFacetSection.Row
  let isOn: Bool
  let toggle: () -> Void

  @Environment(\.palette) private var palette
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isHovering = false

  var body: some View {
    Button(action: toggle) {
      HStack(spacing: AppSpacing.sm) {
        Image(systemName: isOn ? "checkmark.square.fill" : "square")
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(isOn ? palette.foreground : palette.faintForeground)
        Text(row.value.localizedLabel)
          .font(AppFont.labelRegular)
          .foregroundStyle(
            row.value.isUntagged ? palette.mutedForeground : palette.secondaryForeground
          )
          .lineLimit(1)
          .truncationMode(.tail)
        Spacer(minLength: AppSpacing.xs)
        Text("\(row.count)")
          .font(AppFont.caption)
          .monospacedDigit()
          .foregroundStyle(palette.mutedForeground)
      }
      .padding(.horizontal, AppSpacing.sm)
      .frame(height: 25)
      .background(fill, in: RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous))
      .contentShape(RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous))
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .animation(AppMotion.hover(reduceMotion: reduceMotion), value: isHovering)
    .help(row.value.localizedLabel)
    .accessibilityLabel(L10n.isChinese ? "\(row.value.localizedLabel)，\(row.count) 个生词" : "\(row.value.label), \(row.count) words")
    .accessibilityAddTraits(isOn ? [.isSelected, .isButton] : [.isButton])
  }

  private var fill: Color {
    if isOn { return palette.accentFill }
    return isHovering ? palette.mutedHover : .clear
  }
}

private struct VocabularyRow: View {
  let entry: VocabularyEntry

  @Environment(\.palette) private var palette

  /// Lines of explanation every card holds open, whether or not it has them.
  ///
  /// A card sized to its own text leaves the grid ragged: a two-line entry
  /// beside a ten-line one opens a hole a column wide, and the eye reads the
  /// hole before it reads the words. Reserving the lines makes every card the
  /// same height, so the tiles land on a shared baseline row after row.
  private static let previewLines = 4

  var body: some View {
    VStack(alignment: .leading, spacing: AppSpacing.sm) {
      Text(entry.word)
        .font(AppFont.title)
        .foregroundStyle(palette.foreground)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)

      Text(VocabularyPreview.text(for: entry.explanation, word: entry.word))
        .font(AppFont.body)
        .foregroundStyle(palette.secondaryForeground)
        .lineSpacing(2)
        .lineLimit(Self.previewLines, reservesSpace: true)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .topLeading)

      // What the card was filed under. The strip keeps its line whether or not
      // there is anything on it, for the same reason the preview reserves its
      // four: a card that grows a row the moment a batch lands would shuffle
      // every tile below it while the reader is reading them.
      HStack(spacing: AppSpacing.xs) {
        ForEach(Self.tagLabels(for: entry), id: \.self) { label in
          Badge(text: label, variant: .neutral)
        }
        Spacer(minLength: 0)
      }
      .frame(height: 18)
      .clipped()

      // The two pieces of metadata share the last line: the pair is smaller
      // than the word and the prose above it, and reads as the card's footer
      // rather than as a third thing to look at.
      HStack(spacing: AppSpacing.sm) {
        Badge(
          text: "\(entry.sourceLanguage.displayName) → \(entry.resultLanguageName)",
          variant: .outline
        )
        Spacer(minLength: AppSpacing.sm)
        Text(entry.createdAt, format: .relative(presentation: .named))
          .font(AppFont.caption)
          .foregroundStyle(palette.mutedForeground)
          .lineLimit(1)
          .layoutPriority(1)
      }
    }
    .accessibilityLabel(
      ([entry.word, entry.explanation] + Self.tagLabels(for: entry)).joined(separator: ". ")
    )
  }

  /// At most three badges, in the order a reader scanning a card wants them.
  ///
  /// A phrase or a sentence leads with what it is, because that is the thing
  /// that separates it from everything around it; a single word leads with its
  /// part of speech, since "Word" beside a word says nothing. The native rung
  /// ("N2") beats the shared scale wherever the language has one.
  private static func tagLabels(for entry: VocabularyEntry) -> [String] {
    guard let tags = entry.tags else { return [] }
    var labels: [String] = []
    switch tags.unit {
    case .phrase, .sentence:
      if let unit = tags.unit { labels.append(unit.localizedDisplayName) }
    case .word, nil:
      if let part = tags.partOfSpeech {
        labels.append(part.localizedDisplayName)
      } else if let unit = tags.unit {
        labels.append(unit.localizedDisplayName)
      }
    }
    if let level = tags.levelLabel {
      labels.append(level)
    } else if let difficulty = tags.difficulty {
      labels.append(difficulty.localizedDisplayName)
    }
    if let topic = tags.topics?.first { labels.append(topic) }
    return labels
  }
}

/// The plain text a vocabulary card shows under the word.
///
/// Explanations are stored exactly as the model wrote them, which is Markdown —
/// typically a heading repeating the word, then bold field labels. Four lines is
/// too little room to lay that out as a document, and at that size the markers
/// read as damage rather than as emphasis, so the card takes the prose alone.
private enum VocabularyPreview {
  /// Roughly what the reserved lines can hold at the widest column. Whatever
  /// follows is not dropped, only unread here — the saved entry keeps it.
  private static let characterBudget = 400

  static func text(for explanation: String, word: String) -> String {
    let word = word.trimmingCharacters(in: .whitespacesAndNewlines)
    var lines: [String] = []
    var remaining = characterBudget

    for rawLine in explanation.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = clean(String(rawLine))
      guard !line.isEmpty else { continue }
      lines.append(line)
      remaining -= line.count
      if remaining <= 0 { break }
    }

    // The model opens on a heading that is the word itself, which the card
    // already prints above this in its own type. An entry that is *only* that
    // line keeps it: a card showing nothing at all reads as a failure.
    if lines.count > 1, lines[0].caseInsensitiveCompare(word) == .orderedSame {
      lines.removeFirst()
    }

    return lines.joined(separator: "\n")
  }

  /// One source line with its block and inline markers taken off.
  private static func clean(_ line: String) -> String {
    var text = line.trimmingCharacters(in: .whitespaces)

    // A rule carries nothing once it is not being drawn as one.
    if text.allSatisfy({ $0 == "-" || $0 == "_" || $0 == "*" }) { return "" }

    text = String(text.drop { $0 == "#" || $0 == ">" }).trimmingCharacters(in: .whitespaces)

    for marker in ["- ", "* ", "+ "] where text.hasPrefix(marker) {
      text.removeFirst(marker.count)
    }
    let number = text.prefix(while: \.isNumber)
    if !number.isEmpty, text.dropFirst(number.count).hasPrefix(". ") {
      text.removeFirst(number.count + 2)
    }

    text =
      text
      .replacingOccurrences(of: "**", with: "")
      .replacingOccurrences(of: "__", with: "")
      .replacingOccurrences(of: "`", with: "")
    text = text.replacing(/\[([^\]]*)\]\([^)]*\)/) { $0.output.1 }

    return text.trimmingCharacters(in: .whitespaces)
  }
}
