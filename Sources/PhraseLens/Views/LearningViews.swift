import AppKit
import SwiftUI

// MARK: - Tabs

enum LearningTab: String, CaseIterable, Identifiable {
  case overview
  case review
  case terms
  case assistant

  var id: String { rawValue }

  var title: String {
    switch self {
    case .overview: L10n.isChinese ? "概览" : "Overview"
    case .review: L10n.isChinese ? "复习" : "Review"
    case .terms: L10n.isChinese ? "词条" : "Terms"
    case .assistant: L10n.isChinese ? "助理" : "Assistant"
    }
  }

  var symbol: String {
    switch self {
    case .overview: "chart.bar.xaxis"
    case .review: "rectangle.on.rectangle.angled"
    case .terms: "list.bullet.rectangle"
    case .assistant: "bubble.left.and.text.bubble.right"
    }
  }
}

/// The study section's switcher, in the window's top bar where the
/// translator keeps its action tabs.
struct LearningTabBar: View {
  @EnvironmentObject private var learning: LearningModel
  @Environment(\.palette) private var palette
  @Environment(\.layoutWidth) private var layoutWidth
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Namespace private var pill

  var body: some View {
    HStack(spacing: 2) {
      ForEach(LearningTab.allCases) { tab in
        button(for: tab)
      }
    }
    .animation(AppMotion.state(reduceMotion: reduceMotion), value: learning.tab)
  }

  private func button(for tab: LearningTab) -> some View {
    let isSelected = learning.tab == tab
    let due = tab == .review ? learning.dueCount : 0
    return Button {
      learning.tab = tab
    } label: {
      HStack(spacing: AppSpacing.xs + 1) {
        Image(systemName: tab.symbol)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(isSelected ? palette.accent : palette.faintForeground)
        if !layoutWidth.isCompact || isSelected {
          Text(tab.title)
            .font(AppFont.label)
            .lineLimit(1)
        }
        if due > 0 {
          Text("\(due)")
            .font(AppFont.captionMedium)
            .monospacedDigit()
            .foregroundStyle(palette.brandForeground)
            .padding(.horizontal, 5)
            .background(palette.brand, in: Capsule(style: .continuous))
        }
      }
      .foregroundStyle(isSelected ? palette.foreground : palette.mutedForeground)
      .fixedSize()
      .padding(.horizontal, 10)
      .frame(height: 30)
      .background {
        if isSelected {
          let shape = RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
          shape
            .fill(palette.surfaceElevated)
            .overlay { shape.strokeBorder(palette.border, lineWidth: 1) }
            .shadow(color: palette.shadow, radius: 2, y: 1)
            .matchedGeometryEffect(id: "learningTab", in: pill)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(tab.title)
    .accessibilityLabel(due > 0 ? "\(tab.title), \(due)" : tab.title)
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
  }
}

// MARK: - Section

/// The study section: what the record says, the review queue, every term,
/// and the assistant to ask about them.
struct LearningView: View {
  @EnvironmentObject private var learning: LearningModel
  @EnvironmentObject private var settingsStore: SettingsStore
  @Environment(\.palette) private var palette

  var body: some View {
    Group {
      if !settingsStore.settings.learningEnabled {
        EmptyState(
          symbol: "graduationcap",
          title: L10n.isChinese ? "学习记录已关闭" : "The study record is off",
          message: L10n.isChinese
            ? "打开后，PhraseLens 会记下你查过的词和短语，找出反复查询和相互关联的词。数据只保存在本机。"
            : "Turn it on and PhraseLens notes the words and phrases you look up, to find the ones that keep coming back and how they relate. It stays on this Mac."
        ) {
          Button(L10n.isChinese ? "打开学习记录" : "Turn On") {
            settingsStore.settings.learningEnabled = true
          }
          .appButton(.brand, size: .sm)
        }
      } else {
        switch learning.tab {
        case .overview: LearningOverview()
        case .review: ReviewSessionView()
        case .terms: LearningTermsView()
        case .assistant: LearningAssistantView()
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(palette.background)
    .onAppear { learning.writeReportIfDue() }
    .alert(
      "PhraseLens",
      isPresented: Binding(
        get: { learning.errorMessage != nil },
        set: { if !$0 { learning.errorMessage = nil } }
      )
    ) {
      Button(L10n.isChinese ? "好" : "OK", role: .cancel) { learning.errorMessage = nil }
    } message: {
      Text(learning.errorMessage ?? "")
    }
  }
}

// MARK: - Overview

private struct LearningOverview: View {
  @EnvironmentObject private var learning: LearningModel
  @EnvironmentObject private var model: AppModel
  @Environment(\.palette) private var palette

  var body: some View {
    if learning.terms.isEmpty && learning.reports.isEmpty {
      EmptyState(
        symbol: "graduationcap",
        title: L10n.isChinese ? "还没有学习记录" : "Nothing studied yet",
        message: L10n.isChinese
          ? "查一个单词或短语之后，这里会显示反复查询的词、相关词和每周的学习诊断。"
          : "Look up a word or a phrase and this fills in with the terms you keep coming back to, how they relate, and a weekly diagnosis."
      )
    } else {
      ScrollView {
        VStack(alignment: .leading, spacing: AppSpacing.xl) {
          LearningAnalysisBar()
          statTiles
          LearningReportCard()
          stubbornSection
          relationsSection
          habitsSection
        }
        .padding(AppSpacing.lg)
        .frame(maxWidth: 860, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlayScrollers()
      }
    }
  }

  private var weekStats: LearningStats {
    let now = Date()
    return LearningLedger.stats(
      terms: learning.terms, history: model.history,
      from: now.addingTimeInterval(-LearningModel.reportPeriod), to: now
    )
  }

  private var statTiles: some View {
    let stats = weekStats
    return LazyVGrid(
      columns: [GridItem(.adaptive(minimum: 150), spacing: AppSpacing.md)],
      alignment: .leading,
      spacing: AppSpacing.md
    ) {
      StatTile(
        value: stats.lookups,
        title: L10n.isChinese ? "本周查词" : "Lookups this week",
        symbol: "magnifyingglass"
      )
      StatTile(
        value: learning.repeatedTerms.count,
        title: L10n.isChinese ? "反复查询的词" : "Looked up again",
        symbol: "arrow.counterclockwise"
      ) { learning.showTerms(.repeated) }
      StatTile(
        value: learning.dueCount,
        title: L10n.isChinese ? "今天待复习" : "Due today",
        symbol: "rectangle.on.rectangle.angled",
        highlighted: learning.dueCount > 0
      ) { learning.tab = .review }
      StatTile(
        value: learning.terms.filter { $0.relations?.isEmpty == false }.count,
        title: L10n.isChinese ? "有关联的词" : "With related terms",
        symbol: "link"
      ) { learning.showTerms(.related) }
    }
  }

  @ViewBuilder
  private var stubbornSection: some View {
    let stubborn = learning.stubbornTerms
    if !stubborn.isEmpty {
      OverviewSection(
        title: L10n.isChinese ? "老记不住的词" : "Not sticking",
        caption: L10n.isChinese
          ? "在不同的日子查过三次以上。复习时会优先出现，记忆卡也会针对这些词生成。"
          : "Looked up three times or more, on different days. They come first in review and get memory cards."
      ) {
        VStack(spacing: AppSpacing.sm) {
          ForEach(stubborn.prefix(8)) { term in
            StubbornRow(term: term)
          }
        }
      }
    }
  }

  @ViewBuilder
  private var relationsSection: some View {
    let pairs = learning.recentRelationPairs(limit: 8)
    if !pairs.isEmpty {
      OverviewSection(
        title: L10n.isChinese ? "最近发现的关联" : "Recently linked",
        caption: L10n.isChinese
          ? "从你查过的词里找出的近义、易混、同根等关系。"
          : "Synonyms, confusables, shared roots and more, found among the terms you looked up."
      ) {
        VStack(spacing: AppSpacing.sm) {
          ForEach(pairs, id: \.id) { pair in
            RelationPairRow(pair: pair)
          }
        }
      }
    }
  }

  @ViewBuilder
  private var habitsSection: some View {
    let counts = learning.termHabitCounts.merging(learning.passageHabitCounts, uniquingKeysWith: +)
      .filter { $0.key != .other }
      .sorted { $0.value > $1.value }
    if !counts.isEmpty {
      OverviewSection(
        title: L10n.isChinese ? "你常追问的内容" : "What you usually ask",
        caption: L10n.isChinese
          ? "经常追问的内容会直接写进第一次的解释里，追问按钮也会按你的习惯排序。"
          : "What you ask for often goes straight into the first answer, and the follow-up chips are ordered by it."
      ) {
        FlowLayout {
          ForEach(counts, id: \.key) { category, count in
            HStack(spacing: AppSpacing.xs) {
              Text(category.title).font(AppFont.label)
              Text("\(count)").font(AppFont.captionMedium).monospacedDigit().foregroundStyle(palette.mutedForeground)
            }
            .padding(.horizontal, AppSpacing.sm + 1)
            .frame(height: AppMetrics.controlHeightSmall)
            .background(palette.muted, in: Capsule(style: .continuous))
          }
        }
      }
    }
  }
}

private struct StatTile: View {
  let value: Int
  let title: String
  let symbol: String
  var highlighted = false
  var action: (() -> Void)?

  @Environment(\.palette) private var palette
  @State private var isHovering = false

  var body: some View {
    Button {
      action?()
    } label: {
      VStack(alignment: .leading, spacing: AppSpacing.xs) {
        HStack(spacing: AppSpacing.xs) {
          Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(highlighted ? palette.accent : palette.faintForeground)
          Text(title)
            .font(AppFont.caption)
            .foregroundStyle(palette.mutedForeground)
            .lineLimit(1)
        }
        Text("\(value)")
          .font(AppFont.display)
          .monospacedDigit()
          .foregroundStyle(palette.foreground)
      }
      .padding(AppSpacing.md)
      .frame(maxWidth: .infinity, alignment: .leading)
      .cardSurface(palette, fill: isHovering && action != nil ? palette.surfaceElevated : palette.surface)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .allowsHitTesting(action != nil)
    .onHover { isHovering = $0 }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(title): \(value)")
  }
}

/// A titled block of the overview.
private struct OverviewSection<Content: View>: View {
  let title: String
  var caption: String?
  @ViewBuilder var content: Content

  @Environment(\.palette) private var palette

  var body: some View {
    VStack(alignment: .leading, spacing: AppSpacing.sm) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(AppFont.heading).foregroundStyle(palette.foreground)
        if let caption {
          Text(caption)
            .font(AppFont.caption)
            .foregroundStyle(palette.mutedForeground)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// Pending annotation, or the run working through it.
private struct LearningAnalysisBar: View {
  @EnvironmentObject private var learning: LearningModel
  @EnvironmentObject private var settingsStore: SettingsStore
  @Environment(\.palette) private var palette
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    let pending = learning.pendingAnnotation.count
    if let progress = learning.analysisProgress {
      bar {
        Spinner(size: 12, isLive: true)
        Text(
          L10n.isChinese
            ? "正在分析 \(progress.completed)/\(progress.total) 个词条…"
            : "Analyzing \(progress.completed) of \(progress.total) terms…"
        )
        .font(AppFont.label)
        Spacer(minLength: AppSpacing.sm)
        Button(L10n.isChinese ? "停止" : "Stop") { learning.cancelAnalysis() }
          .appButton(.ghost, size: .xs)
      }
    } else if pending > 0 {
      bar {
        Image(systemName: "sparkles")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(palette.accent)
        VStack(alignment: .leading, spacing: 1) {
          Text(
            L10n.isChinese ? "\(pending) 个词条还没有分析" : "\(pending) terms not analyzed yet"
          )
          .font(AppFont.label)
          Text(
            L10n.isChinese
              ? "分析会找出原形、读音、当时的词义和相关词，使用默认的 AI 连接。"
              : "Finds dictionary forms, readings, the sense you met, and related terms, using the default AI connection."
          )
          .font(AppFont.caption)
          .foregroundStyle(palette.mutedForeground)
          .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: AppSpacing.sm)
        if learning.canAnalyze {
          Button(L10n.isChinese ? "开始分析" : "Analyze") { learning.analyzeAll() }
            .appButton(.outline, size: .xs)
        } else {
          Button(L10n.isChinese ? "配置连接" : "Set up a connection") {
            SettingsNavigation.show(.provider) { openSettings() }
          }
          .appButton(.outline, size: .xs)
        }
      }
    }
  }

  private func bar<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    HStack(spacing: AppSpacing.sm) { content() }
      .padding(.horizontal, AppSpacing.md)
      .padding(.vertical, AppSpacing.sm + 2)
      .frame(maxWidth: .infinity, alignment: .leading)
      .cardSurface(palette, fill: palette.accentSoft.opacity(0.5))
  }
}

/// The latest diagnosis, and the command that writes a new one.
private struct LearningReportCard: View {
  @EnvironmentObject private var learning: LearningModel
  @Environment(\.palette) private var palette

  var body: some View {
    OverviewSection(
      title: L10n.isChinese ? "学习诊断" : "Diagnosis",
      caption: caption
    ) {
      VStack(alignment: .leading, spacing: AppSpacing.md) {
        if let report = learning.latestReport {
          Text(report.summary)
            .font(AppFont.body)
            .foregroundStyle(palette.foreground)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
          ForEach(report.issues) { issue in
            IssueRow(issue: issue)
          }
          if !report.focusTermIDs.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
              Text(L10n.isChinese ? "优先复习" : "Review first")
                .font(AppFont.captionMedium)
                .foregroundStyle(palette.mutedForeground)
              TermChips(ids: report.focusTermIDs)
            }
          }
        } else {
          Text(
            L10n.isChinese
              ? "根据最近 7 天的查词、反复查询和追问，找出你卡在哪里，并给出具体建议。"
              : "Reads the last 7 days of lookups, repeats and follow-ups to find where you are stuck, with concrete suggestions."
          )
          .font(AppFont.body)
          .foregroundStyle(palette.mutedForeground)
          .fixedSize(horizontal: false, vertical: true)
        }
        HStack(spacing: AppSpacing.sm) {
          Button {
            Task { await learning.writeReport() }
          } label: {
            HStack(spacing: AppSpacing.xs + 1) {
              if learning.isWritingReport {
                Spinner(size: 11, isLive: true)
              } else {
                Image(systemName: "stethoscope").font(.system(size: 11, weight: .medium))
              }
              Text(
                learning.isWritingReport
                  ? (L10n.isChinese ? "正在诊断…" : "Diagnosing…")
                  : (learning.latestReport == nil
                    ? (L10n.isChinese ? "生成诊断" : "Diagnose")
                    : (L10n.isChinese ? "重新诊断" : "Diagnose Again"))
              )
            }
          }
          .appButton(learning.latestReport == nil ? .brand : .outline, size: .sm)
          .disabled(learning.isWritingReport || !learning.canAnalyze)
          Spacer(minLength: 0)
        }
      }
      .padding(AppSpacing.md)
      .frame(maxWidth: .infinity, alignment: .leading)
      .cardSurface(palette)
    }
  }

  private var caption: String {
    guard let report = learning.latestReport else {
      return L10n.isChinese ? "每周自动生成一次，也可以随时手动生成。" : "Written once a week on its own, or whenever you ask."
    }
    let date = LearningCopy.date(report.createdAt, time: true)
    return L10n.isChinese ? "生成于 \(date)，覆盖之前 7 天。" : "Written \(date), covering the 7 days before."
  }
}

private struct IssueRow: View {
  let issue: LearningIssue
  @Environment(\.palette) private var palette

  var body: some View {
    VStack(alignment: .leading, spacing: AppSpacing.xs) {
      Text(issue.title)
        .font(AppFont.bodyMedium)
        .foregroundStyle(palette.foreground)
      Text(issue.detail)
        .font(AppFont.labelRegular)
        .foregroundStyle(palette.secondaryForeground)
        .fixedSize(horizontal: false, vertical: true)
      if !issue.suggestion.isEmpty {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xs) {
          Image(systemName: "lightbulb")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(palette.warning)
          Text(issue.suggestion)
            .font(AppFont.labelRegular)
            .foregroundStyle(palette.foreground)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      if !issue.termIDs.isEmpty {
        TermChips(ids: issue.termIDs)
      }
    }
    .textSelection(.enabled)
    .padding(.leading, AppSpacing.sm + 2)
    .overlay(alignment: .leading) {
      Rectangle().fill(palette.border).frame(width: 2)
    }
  }
}

/// Terms named by id, each opening its own page.
private struct TermChips: View {
  let ids: [UUID]
  @EnvironmentObject private var learning: LearningModel

  var body: some View {
    FlowLayout {
      ForEach(ids.compactMap { learning.term(id: $0) }) { term in
        TermChip(term: term)
      }
    }
  }
}

struct TermChip: View {
  let term: LearningTerm
  @EnvironmentObject private var learning: LearningModel
  @Environment(\.palette) private var palette
  @State private var isHovering = false

  var body: some View {
    Button {
      learning.select(term.id)
    } label: {
      Text(term.headword)
        .font(AppFont.label)
        .foregroundStyle(palette.foreground)
        .padding(.horizontal, AppSpacing.sm)
        .frame(height: 22)
        .background(isHovering ? palette.muted : .clear, in: Capsule(style: .continuous))
        .overlay { Capsule(style: .continuous).strokeBorder(palette.border, lineWidth: 1) }
        .contentShape(Capsule(style: .continuous))
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .help(L10n.isChinese ? "查看“\(term.headword)”" : "Open “\(term.headword)”")
  }
}

private struct StubbornRow: View {
  let term: LearningTerm
  @EnvironmentObject private var learning: LearningModel
  @Environment(\.palette) private var palette

  var body: some View {
    HStack(alignment: .top, spacing: AppSpacing.md) {
      VStack(alignment: .leading, spacing: 3) {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
          Button { learning.select(term.id) } label: {
            Text(term.headword).font(AppFont.bodyMedium).foregroundStyle(palette.foreground)
          }
          .buttonStyle(.plain)
          if let reading = term.reading {
            Text(reading).font(AppFont.caption).foregroundStyle(palette.mutedForeground)
          }
          Text(LearningCopy.lookups(term))
            .font(AppFont.caption)
            .foregroundStyle(palette.mutedForeground)
        }
        if let card = term.card {
          Text(card.hook)
            .font(AppFont.labelRegular)
            .foregroundStyle(palette.secondaryForeground)
            .fixedSize(horizontal: false, vertical: true)
        } else if let sense = term.encounters.last(where: { $0.sense != nil })?.sense {
          Text(sense).font(AppFont.labelRegular).foregroundStyle(palette.secondaryForeground)
        }
      }
      Spacer(minLength: AppSpacing.sm)
      if term.card == nil {
        CardButton(term: term)
      }
    }
    .padding(AppSpacing.md)
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardSurface(palette)
  }
}

/// Writes or rewrites a term's memory card.
private struct CardButton: View {
  let term: LearningTerm
  @EnvironmentObject private var learning: LearningModel

  var body: some View {
    let busy = learning.cardsInProgress.contains(term.id)
    Button {
      Task { await learning.makeCard(for: term.id) }
    } label: {
      HStack(spacing: AppSpacing.xs + 1) {
        if busy { Spinner(size: 10, isLive: true) } else {
          Image(systemName: "sparkles").font(.system(size: 10, weight: .semibold))
        }
        Text(
          term.card == nil
            ? (L10n.isChinese ? "生成记忆卡" : "Make a Card")
            : (L10n.isChinese ? "重写记忆卡" : "Rewrite Card")
        )
      }
    }
    .appButton(.outline, size: .xs)
    .disabled(busy || !learning.canAnalyze)
  }
}

struct RelationPair: Identifiable {
  var id: String
  var left: LearningTerm
  var right: LearningTerm
  var relation: LearningRelation
}

private struct RelationPairRow: View {
  let pair: RelationPair
  @Environment(\.palette) private var palette

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
      TermChip(term: pair.left)
      Image(systemName: "arrow.left.and.right")
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(palette.faintForeground)
      TermChip(term: pair.right)
      Badge(text: pair.relation.kind.title, variant: pair.relation.kind == .confusable ? .warning : .neutral)
      Text(pair.relation.note)
        .font(AppFont.labelRegular)
        .foregroundStyle(palette.secondaryForeground)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

// MARK: - Terms

enum LearningTermFilter: String, CaseIterable, Identifiable {
  case all
  case repeated
  case stubborn
  case reviewing
  case related

  var id: String { rawValue }

  var title: String {
    switch self {
    case .all: L10n.isChinese ? "全部" : "All"
    case .repeated: L10n.isChinese ? "反复查询" : "Looked up again"
    case .stubborn: L10n.isChinese ? "老记不住" : "Not sticking"
    case .reviewing: L10n.isChinese ? "复习中" : "In review"
    case .related: L10n.isChinese ? "有关联" : "With related terms"
    }
  }

  func includes(_ term: LearningTerm) -> Bool {
    switch self {
    case .all: true
    case .repeated: LearningLedger.isRepeat(term)
    case .stubborn: LearningLedger.isStubborn(term)
    case .reviewing: term.review != nil
    case .related: term.relations?.isEmpty == false
    }
  }
}

private struct LearningTermsView: View {
  @EnvironmentObject private var learning: LearningModel
  @Environment(\.palette) private var palette
  @Environment(\.layoutWidth) private var layoutWidth
  @State private var search = ""

  private var filtered: [LearningTerm] {
    let pool = learning.terms.filter(learning.termFilter.includes)
    let matched = search.isEmpty
      ? pool
      : pool.filter {
        $0.display.localizedCaseInsensitiveContains(search)
          || ($0.lemma?.localizedCaseInsensitiveContains(search) ?? false)
          || ($0.reading?.localizedCaseInsensitiveContains(search) ?? false)
          || $0.encounters.contains { $0.sense?.localizedCaseInsensitiveContains(search) ?? false }
      }
    return matched.sorted { $0.lastSeen > $1.lastSeen }
  }

  var body: some View {
    let terms = filtered
    let selected = learning.selectedTermID.flatMap { learning.term(id: $0) }
    if layoutWidth.isCompact {
      if let selected {
        VStack(spacing: 0) {
          HStack {
            Button {
              learning.selectedTermID = nil
            } label: {
              AdaptiveLabel(title: L10n.isChinese ? "全部词条" : "All Terms", symbol: "chevron.left")
            }
            .appButton(.ghost, size: .sm)
            Spacer()
          }
          .padding(.horizontal, AppSpacing.md)
          .padding(.vertical, AppSpacing.xs)
          .background(palette.chrome)
          Hairline()
          LearningTermDetail(term: selected)
        }
      } else {
        list(terms)
      }
    } else {
      HStack(spacing: 0) {
        list(terms)
          .frame(width: 300)
        Rectangle().fill(palette.border).frame(width: 1)
        Group {
          if let selected {
            LearningTermDetail(term: selected)
          } else {
            EmptyState(
              symbol: "text.magnifyingglass",
              title: L10n.isChinese ? "选择一个词条" : "Choose a term",
              message: L10n.isChinese
                ? "可以看到每次遇到它时的句子、当时的词义、追问过的问题和相关词。"
                : "See every sentence you met it in, the sense it had there, what you asked, and how it relates to other terms."
            )
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }

  private func list(_ terms: [LearningTerm]) -> some View {
    VStack(spacing: 0) {
      HStack(spacing: AppSpacing.sm) {
        AppTextField(
          placeholder: L10n.isChinese ? "搜索词条…" : "Search terms…",
          text: $search,
          symbol: "magnifyingglass",
          size: .sm
        )
        AppSelect(
          title: L10n.isChinese ? "筛选" : "Filter",
          selection: $learning.termFilter,
          options: LearningTermFilter.allCases,
          label: { $0.title },
          isGhost: true
        )
        .fixedSize()
      }
      .padding(.horizontal, AppSpacing.md)
      .padding(.vertical, AppSpacing.sm)
      .background(palette.chrome)
      Hairline()
      if terms.isEmpty {
        EmptyState(
          symbol: "tray",
          title: L10n.isChinese ? "没有符合条件的词条" : "No matching terms",
          message: L10n.isChinese ? "换一个筛选条件或搜索词试试。" : "Try another filter or search."
        )
      } else {
        ScrollView {
          LazyVStack(spacing: 2) {
            ForEach(terms) { term in
              TermRow(term: term, isSelected: learning.selectedTermID == term.id) {
                learning.selectedTermID = term.id
              }
            }
          }
          .padding(AppSpacing.sm)
          .overlayScrollers()
        }
      }
    }
  }
}

private struct TermRow: View {
  let term: LearningTerm
  let isSelected: Bool
  let action: () -> Void

  @Environment(\.palette) private var palette
  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xs + 2) {
          Text(term.headword)
            .font(AppFont.bodyMedium)
            .foregroundStyle(palette.foreground)
            .lineLimit(1)
          if let reading = term.reading {
            Text(reading).font(AppFont.caption).foregroundStyle(palette.mutedForeground).lineLimit(1)
          }
          Spacer(minLength: AppSpacing.xs)
          if term.encounters.count > 1 {
            Text("×\(term.encounters.count)")
              .font(AppFont.captionMedium)
              .monospacedDigit()
              .foregroundStyle(LearningLedger.isStubborn(term) ? palette.warning : palette.mutedForeground)
          }
        }
        HStack(spacing: AppSpacing.xs + 2) {
          Text(term.language.shortDisplayName)
          Text(term.lastSeen, format: .relative(presentation: .named))
          if term.card != nil { Image(systemName: "sparkles") }
          if term.review != nil { Image(systemName: "rectangle.on.rectangle.angled") }
          if let count = term.relations?.count, count > 0 {
            HStack(spacing: 1) {
              Image(systemName: "link")
              Text("\(count)")
            }
          }
        }
        .font(AppFont.caption)
        .foregroundStyle(palette.faintForeground)
        .lineLimit(1)
      }
      .padding(.horizontal, AppSpacing.sm + 2)
      .padding(.vertical, AppSpacing.xs + 3)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        isSelected ? palette.surfaceElevated : (isHovering ? palette.muted : .clear),
        in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
      )
      .overlay {
        if isSelected {
          RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
            .strokeBorder(palette.border, lineWidth: 1)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
  }
}

/// Everything the record holds about one term.
struct LearningTermDetail: View {
  enum Style {
    case page
    case popover
  }

  let term: LearningTerm
  var style: Style = .page

  @EnvironmentObject private var learning: LearningModel
  @EnvironmentObject private var model: AppModel
  @Environment(\.palette) private var palette

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: AppSpacing.lg) {
        header
        if style == .page { commands }
        if let card = term.card { cardBlock(card) }
        relationsBlock
        sittingsBlock
        if style == .popover {
          Button {
            model.openLearning(termID: term.id)
          } label: {
            AdaptiveLabel(title: L10n.isChinese ? "在学习中心查看" : "Open in Study", symbol: "graduationcap")
          }
          .appButton(.outline, size: .sm)
        }
      }
      .padding(style == .page ? AppSpacing.lg : AppSpacing.md)
      .frame(maxWidth: style == .page ? 720 : .infinity, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .leading)
      .textSelection(.enabled)
      .overlayScrollers()
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: AppSpacing.xs) {
      HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
        Text(term.headword)
          .font(style == .page ? AppFont.display : AppFont.title)
          .foregroundStyle(palette.foreground)
        if let reading = term.reading {
          Text(reading).font(AppFont.body).foregroundStyle(palette.mutedForeground)
        }
        if term.lemma != nil, term.display != term.headword {
          Text(term.display).font(AppFont.caption).foregroundStyle(palette.faintForeground)
        }
      }
      FlowLayout {
        Badge(text: term.language.displayName, variant: .outline)
        Badge(text: LearningCopy.lookups(term), variant: .neutral, symbol: "arrow.counterclockwise")
        if LearningLedger.isStubborn(term) {
          Badge(text: L10n.isChinese ? "老记不住" : "Not sticking", variant: .warning)
        }
        if let review = term.review {
          Badge(text: LearningCopy.nextReview(review), variant: .success, symbol: "rectangle.on.rectangle.angled")
        }
      }
    }
  }

  private var commands: some View {
    FlowLayout {
      if term.review == nil {
        Button {
          learning.enroll(term.id)
        } label: {
          AdaptiveLabel(title: L10n.isChinese ? "加入复习" : "Add to Review", symbol: "plus.rectangle.on.rectangle")
        }
        .appButton(.outline, size: .sm)
      } else {
        Button {
          learning.unenroll(term.id)
        } label: {
          AdaptiveLabel(title: L10n.isChinese ? "移出复习" : "Remove from Review", symbol: "minus.rectangle")
        }
        .appButton(.ghost, size: .sm)
      }
      CardButton(term: term)
      if let entry = latestEntry {
        Button {
          model.restore(entry)
        } label: {
          AdaptiveLabel(title: L10n.isChinese ? "打开最近一次结果" : "Open Latest Result", symbol: "arrow.up.forward.app")
        }
        .appButton(.ghost, size: .sm)
      }
    }
  }

  private var latestEntry: HistoryEntry? {
    let ids = Set(term.encounters.flatMap(\.historyIDs))
    return model.history.first { ids.contains($0.id) }
  }

  private func cardBlock(_ card: StudyCard) -> some View {
    VStack(alignment: .leading, spacing: AppSpacing.sm) {
      Eyebrow(text: L10n.isChinese ? "记忆卡" : "Memory card")
      Text(card.meaning).font(AppFont.bodyMedium).foregroundStyle(palette.foreground)
      LabeledLine(symbol: "brain", text: card.hook, tint: palette.accent)
      if let contrast = card.contrast {
        LabeledLine(symbol: "arrow.left.and.right", text: contrast, tint: palette.warning)
      }
      if let example = card.example {
        VStack(alignment: .leading, spacing: 2) {
          Text(LearningCopy.highlighted(example, term: term))
            .font(AppFont.body)
          if let translation = card.exampleTranslation {
            Text(translation).font(AppFont.labelRegular).foregroundStyle(palette.mutedForeground)
          }
        }
        .padding(.leading, AppSpacing.sm + 2)
        .overlay(alignment: .leading) { Rectangle().fill(palette.border).frame(width: 2) }
      }
    }
    .padding(AppSpacing.md)
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardSurface(palette)
  }

  @ViewBuilder
  private var relationsBlock: some View {
    let relations = (term.relations ?? []).compactMap { relation in
      learning.term(id: relation.termID).map { (relation, $0) }
    }
    if !relations.isEmpty {
      VStack(alignment: .leading, spacing: AppSpacing.sm) {
        Eyebrow(text: L10n.isChinese ? "相关词" : "Related")
        ForEach(relations, id: \.0.termID) { relation, other in
          HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
            Badge(text: relation.kind.title, variant: relation.kind == .confusable ? .warning : .neutral)
            TermChip(term: other)
            Text(relation.note)
              .font(AppFont.labelRegular)
              .foregroundStyle(palette.secondaryForeground)
              .fixedSize(horizontal: false, vertical: true)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
    }
  }

  private var sittingsBlock: some View {
    VStack(alignment: .leading, spacing: AppSpacing.sm) {
      Eyebrow(text: L10n.isChinese ? "每次遇到它" : "Every sitting")
      ForEach(Array(term.encounters.reversed().prefix(style == .page ? 50 : 3))) { encounter in
        SittingRow(encounter: encounter, term: term, compact: style == .popover)
      }
    }
  }
}

private struct SittingRow: View {
  let encounter: LearningEncounter
  let term: LearningTerm
  var compact = false

  @EnvironmentObject private var model: AppModel
  @Environment(\.palette) private var palette

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: AppSpacing.sm) {
        Text(LearningCopy.date(encounter.at, time: true))
          .font(AppFont.captionMedium)
          .foregroundStyle(palette.mutedForeground)
        if !compact {
          Text(encounter.actions.joined(separator: " · "))
            .font(AppFont.caption)
            .foregroundStyle(palette.faintForeground)
            .lineLimit(1)
        }
        Spacer(minLength: 0)
        if !compact, let entry = model.history.first(where: { encounter.historyIDs.contains($0.id) }) {
          IconButton(title: L10n.isChinese ? "在翻译器中打开" : "Open in translator", symbol: "arrow.up.forward.app") {
            model.restore(entry)
          }
        }
      }
      if let sentence = encounter.sentence {
        Text(LearningCopy.highlighted(sentence, term: term))
          .font(AppFont.body)
          .fixedSize(horizontal: false, vertical: true)
      }
      if let sense = encounter.sense {
        LabeledLine(symbol: "character.book.closed", text: sense, tint: palette.faintForeground)
      }
      ForEach(Array((encounter.followUps ?? []).enumerated()), id: \.offset) { _, question in
        LabeledLine(symbol: "questionmark.bubble", text: question.question, tint: palette.faintForeground)
      }
    }
    .padding(.vertical, AppSpacing.xs)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct LabeledLine: View {
  let symbol: String
  let text: String
  let tint: Color
  @Environment(\.palette) private var palette

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xs + 1) {
      Image(systemName: symbol)
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(tint)
        .frame(width: 14)
      Text(text)
        .font(AppFont.labelRegular)
        .foregroundStyle(palette.secondaryForeground)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

// MARK: - Review

private struct ReviewSessionView: View {
  @EnvironmentObject private var learning: LearningModel
  @Environment(\.palette) private var palette
  @State private var queue: [UUID] = []
  @State private var reviewed = 0
  @State private var revealed = false

  var body: some View {
    let due = learning.dueTerms()
    Group {
      if let id = queue.first, let term = learning.term(id: id) {
        ReviewCardView(
          term: term,
          position: reviewed + 1,
          total: reviewed + queue.count,
          revealed: revealed,
          onReveal: { revealed = true },
          onGrade: { grade in
            learning.grade(id, grade)
            queue.removeFirst()
            if grade == .again { queue.append(id) } else { reviewed += 1 }
            revealed = false
          }
        )
      } else if reviewed > 0 {
        EmptyState(
          symbol: "checkmark.seal",
          title: L10n.isChinese ? "这一轮复习完成了" : "Session done",
          message: L10n.isChinese
            ? "复习了 \(reviewed) 个词条。下一次复习时间会根据你的回答自动安排。"
            : "You reviewed \(reviewed) terms. Each comes back when your answer says it should."
        ) {
          if !due.isEmpty {
            Button(L10n.isChinese ? "继续复习（\(due.count)）" : "Keep Going (\(due.count))") {
              reviewed = 0
              queue = due.map(\.id)
            }
            .appButton(.outline, size: .sm)
          }
        }
      } else if due.isEmpty {
        EmptyState(
          symbol: "rectangle.on.rectangle.angled",
          title: L10n.isChinese ? "今天没有要复习的词" : "Nothing due today",
          message: emptyMessage
        )
      } else {
        EmptyState(
          symbol: "rectangle.on.rectangle.angled",
          title: L10n.isChinese ? "今天有 \(due.count) 个词条待复习" : "\(due.count) terms due today",
          message: L10n.isChinese
            ? "每张卡片先看词和你当时遇到它的句子，回想意思，再翻开对照。再次查询一个复习中的词，会被记作“忘了”。"
            : "Each card shows the term and the sentence you met it in. Recall the meaning, then reveal it. Looking a term up again counts as forgetting it."
        ) {
          Button(L10n.isChinese ? "开始复习" : "Start Review") {
            reviewed = 0
            queue = due.map(\.id)
          }
          .appButton(.brand, size: .md)
          .keyboardShortcut(.defaultAction)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var emptyMessage: String {
    let enrolled = learning.enrolledTerms
    guard let next = enrolled.first?.review?.due else {
      return L10n.isChinese
        ? "查过两次以上的词会自动加入复习，也可以在“词条”里手动加入。"
        : "Terms you look up more than once join review on their own; you can add any term from Terms."
    }
    let date = LearningCopy.date(next)
    return L10n.isChinese
      ? "\(enrolled.count) 个词条在复习中，下一个在 \(date)。"
      : "\(enrolled.count) terms in review; the next is due \(date)."
  }
}

private struct ReviewCardView: View {
  let term: LearningTerm
  let position: Int
  let total: Int
  let revealed: Bool
  let onReveal: () -> Void
  let onGrade: (ReviewGrade) -> Void

  @EnvironmentObject private var learning: LearningModel
  @Environment(\.palette) private var palette

  var body: some View {
    ScrollView {
      VStack(spacing: AppSpacing.lg) {
        Text("\(position) / \(total)")
          .font(AppFont.captionMedium)
          .monospacedDigit()
          .foregroundStyle(palette.mutedForeground)

        VStack(alignment: .leading, spacing: AppSpacing.md) {
          HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
            Text(term.headword).font(.system(size: 28, weight: .semibold)).foregroundStyle(palette.foreground)
            if revealed, let reading = term.reading {
              Text(reading).font(AppFont.title).foregroundStyle(palette.mutedForeground)
            }
            Spacer(minLength: 0)
            Badge(text: LearningCopy.lookups(term), variant: .neutral, symbol: "arrow.counterclockwise")
          }
          if let sentence = term.encounters.last(where: { $0.sentence != nil })?.sentence {
            Text(LearningCopy.highlighted(sentence, term: term))
              .font(.system(size: 15))
              .foregroundStyle(palette.secondaryForeground)
              .fixedSize(horizontal: false, vertical: true)
          }
          if revealed {
            Hairline()
            answer
          }
        }
        .padding(AppSpacing.xl)
        .frame(maxWidth: 560, alignment: .leading)
        .cardSurface(palette, elevated: true)

        if revealed {
          HStack(spacing: AppSpacing.sm) {
            ForEach(ReviewGrade.allCases) { grade in
              Button {
                onGrade(grade)
              } label: {
                VStack(spacing: 1) {
                  Text(grade.title).font(AppFont.label)
                  Text(interval(for: grade)).font(AppFont.caption).foregroundStyle(palette.mutedForeground)
                }
                .frame(minWidth: 72)
              }
              .appButton(grade == .good ? .primary : .outline, size: .lg)
              .keyboardShortcut(KeyEquivalent(Character("\(grade.rawValue)")), modifiers: [])
              .help("\(grade.title) (\(grade.rawValue))")
            }
          }
        } else {
          Button(L10n.isChinese ? "显示答案" : "Show Answer", action: onReveal)
            .appButton(.brand, size: .lg)
            .keyboardShortcut(.space, modifiers: [])
            .help(L10n.isChinese ? "显示答案（空格）" : "Show the answer (Space)")
        }
      }
      .padding(AppSpacing.xl)
      .frame(maxWidth: .infinity)
    }
  }

  @ViewBuilder
  private var answer: some View {
    VStack(alignment: .leading, spacing: AppSpacing.sm) {
      Text(meaning)
        .font(AppFont.bodyMedium)
        .foregroundStyle(palette.foreground)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
      if let card = term.card {
        LabeledLine(symbol: "brain", text: card.hook, tint: palette.accent)
        if let contrast = card.contrast {
          LabeledLine(symbol: "arrow.left.and.right", text: contrast, tint: palette.warning)
        }
      }
      ForEach((term.relations ?? []).prefix(3), id: \.termID) { relation in
        if let other = learning.term(id: relation.termID) {
          LabeledLine(symbol: "link", text: "\(other.headword) · \(relation.kind.title) · \(relation.note)", tint: palette.faintForeground)
        }
      }
    }
  }

  private var meaning: String {
    if let card = term.card { return card.meaning }
    let senses = LearningLedger.unique(term.encounters.compactMap(\.sense))
    if !senses.isEmpty { return senses.suffix(3).joined(separator: " / ") }
    if let explanation = learning.latestExplanation(for: term) {
      let preview = VocabularyPreview.text(for: explanation, word: term.display)
      return preview.count > 320 ? String(preview.prefix(320)) + "…" : preview
    }
    return L10n.isChinese ? "（还没有释义，打开最近一次结果查看）" : "(No meaning on file yet — open the latest result.)"
  }

  private func interval(for grade: ReviewGrade) -> String {
    guard let state = term.review else { return "" }
    let next = ReviewScheduler.grade(state, grade, now: Date())
    if grade == .again { return L10n.isChinese ? "10 分钟" : "10 min" }
    let days = Int(next.interval.rounded())
    return L10n.isChinese ? "\(days) 天" : (days == 1 ? "1 day" : "\(days) days")
  }
}

// MARK: - Lookup badge

/// How many times the term on screen has been looked up, beside its result.
/// Opens what the record says about it.
struct LearningLookupBadge: View {
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var learning: LearningModel
  @State private var isPresented = false

  var body: some View {
    if !model.isTranslating, !model.outputText.isEmpty,
      let term = learning.term(for: model.inputText, language: model.currentSourceLanguage),
      term.encounters.count > 1 || term.relations?.isEmpty == false
    {
      Button {
        isPresented.toggle()
      } label: {
        Badge(
          text: term.encounters.count > 1
            ? LearningCopy.lookups(term)
            : (L10n.isChinese ? "\(term.relations?.count ?? 0) 个相关词" : "\(term.relations?.count ?? 0) related"),
          variant: LearningLedger.isStubborn(term) ? .warning : .neutral,
          symbol: term.encounters.count > 1 ? "arrow.counterclockwise" : "link"
        )
      }
      .buttonStyle(.plain)
      .help(
        L10n.isChinese
          ? "你之前查过这个词。点按查看当时的句子、词义和相关词。"
          : "You have looked this up before. Click to see the sentences, senses, and related terms."
      )
      .popover(isPresented: $isPresented, arrowEdge: .bottom) {
        LearningTermDetail(term: term, style: .popover)
          .frame(width: 360, height: 420)
          .environmentObject(model)
          .environmentObject(learning)
      }
      #if DEBUG
      .onAppear {
        // Visual QA: `--preview-learning-popover` opens the record on launch.
        if CommandLine.arguments.contains("--preview-learning-popover") {
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { isPresented = true }
        }
      }
      #endif
    }
  }
}

// MARK: - Settings

struct LearningSettingsPane: View {
  @EnvironmentObject private var settingsStore: SettingsStore
  @EnvironmentObject private var learning: LearningModel
  @Environment(\.palette) private var palette
  @State private var isConfirmingClear = false

  var body: some View {
    VStack(alignment: .leading, spacing: AppSpacing.xl) {
      SettingsCard(
        L10n.isChinese ? "学习记录" : "Study record",
        caption: L10n.isChinese
          ? "记录只保存在本机；删除历史记录时，对应的学习记录也会一起删除。"
          : "The record stays on this Mac. Deleting history deletes what was learned from it."
      ) {
        switchRow(
          L10n.isChinese ? "记录查过的词" : "Keep a study record",
          detail: L10n.isChinese
            ? "记下查过的单词和短语、当时所在的句子和追问，用来发现反复查询和相互关联的词。"
            : "Notes the words and phrases you look up, the sentence around them, and what you asked, to find repeats and related terms.",
          isOn: $settingsStore.settings.learningEnabled
        )
        Hairline()
        switchRow(
          L10n.isChinese ? "解释时参考学习记录" : "Use the record in explanations",
          detail: L10n.isChinese
            ? "释义、用法、语境等解释会参考你之前遇到这个词的句子、追问和相关词，并补上你常追问的内容。“翻译”动作不受影响。"
            : "Definitions and other explanations build on the sentences, questions, and related terms from earlier lookups, and include what you usually ask for. Translate is never affected.",
          isOn: $settingsStore.settings.learningMemoryInPrompts
        )
        .disabled(!settingsStore.settings.learningEnabled)
      }

      SettingsCard(
        L10n.isChinese ? "后台分析" : "Background analysis",
        caption: L10n.isChinese
          ? "使用默认的 AI 连接，在后台少量、分批地发送查过的词和句子。"
          : "Uses the default AI connection, sending looked-up terms and their sentences in small batches."
      ) {
        switchRow(
          L10n.isChinese ? "自动分析词条" : "Analyze terms automatically",
          detail: L10n.isChinese
            ? "找出原形、读音、当时的词义和相关词；为老记不住的词生成记忆卡；每周生成一次学习诊断。"
            : "Finds dictionary forms, readings, senses, and related terms; makes memory cards for words that will not stick; writes a weekly diagnosis.",
          isOn: $settingsStore.settings.learningAutoAnalyze
        )
        .disabled(!settingsStore.settings.learningEnabled)
        Hairline()
        switchRow(
          L10n.isChinese ? "老记不住的词自动加入生词本" : "Collect words that will not stick",
          detail: L10n.isChinese
            ? "在不同的日子查过三次以上的词，会自动保存到生词本。"
            : "A term looked up three times or more, on different days, is saved to Vocabulary.",
          isOn: $settingsStore.settings.learningAutoCollect
        )
        .disabled(!settingsStore.settings.learningEnabled)
      }

      SettingsCard(
        L10n.isChinese ? "学习助理" : "Study assistant",
        caption: L10n.isChinese
          ? "在学习中心的“助理”里提问。助理会用默认的 AI 连接查阅你的学习记录后再回答。"
          : "Ask in Study → Assistant. It reads your record through the default AI connection before answering."
      ) {
        switchRow(
          L10n.isChinese ? "允许查询公开词典 API" : "Use public dictionary APIs",
          detail: L10n.isChinese
            ? "助理可以向 Datamuse（相关词）和 Free Dictionary（英文释义、音标）查询英文单词，只发送要查的那个词。"
            : "Lets the assistant look English words up in Datamuse (related words) and Free Dictionary (definitions, phonetics). Only the word is sent.",
          isOn: $settingsStore.settings.learningAssistantWebTools
        )
        .disabled(!settingsStore.settings.learningEnabled)
      }

      SettingsCard(L10n.isChinese ? "数据" : "Data") {
        SettingsRow(
          L10n.isChinese ? "已记录" : "On file",
          detail: L10n.isChinese
            ? "\(learning.terms.count) 个词条，其中 \(learning.repeatedTerms.count) 个反复查询过，\(learning.reports.count) 份诊断。"
            : "\(learning.terms.count) terms, \(learning.repeatedTerms.count) looked up more than once, \(learning.reports.count) diagnoses."
        ) {
          Button(L10n.isChinese ? "清除学习记录…" : "Clear Study Record…", role: .destructive) {
            isConfirmingClear = true
          }
          .appButton(.destructiveGhost, size: .sm)
          .disabled(learning.terms.isEmpty && learning.reports.isEmpty)
        }
      }
    }
    .confirmationDialog(
      L10n.isChinese ? "清除全部学习记录？" : "Clear the whole study record?",
      isPresented: $isConfirmingClear,
      titleVisibility: .visible
    ) {
      Button(L10n.isChinese ? "清除" : "Clear", role: .destructive) { learning.clearAll() }
      Button(L10n.isChinese ? "取消" : "Cancel", role: .cancel) {}
    } message: {
      Text(
        L10n.isChinese
          ? "词条、关联、记忆卡、复习进度和诊断都会删除，历史记录和生词本保留。此操作无法撤销。"
          : "Terms, relations, cards, review progress, and diagnoses are removed. History and Vocabulary stay. There is no undo."
      )
    }
  }

  private func switchRow(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
    SettingsRow(title, detail: detail) {
      Toggle("", isOn: isOn)
        .toggleStyle(AppSwitchStyle())
        .labelsHidden()
        .accessibilityLabel(title)
    }
  }
}

// MARK: - Copy

enum LearningCopy {
  /// A date in the interface's language rather than the system's.
  static func date(_ date: Date, time: Bool = false) -> String {
    date.formatted(
      Date.FormatStyle(date: .abbreviated, time: time ? .shortened : .omitted)
        .locale(Locale(identifier: L10n.isChinese ? "zh-Hans" : "en"))
    )
  }

  static func lookups(_ term: LearningTerm) -> String {
    let count = term.encounters.count
    let days = LearningLedger.distinctDays(term)
    if L10n.isChinese {
      return days > 1 ? "查过 \(count) 次 · \(days) 天" : "查过 \(count) 次"
    }
    let times = count == 1 ? "Looked up once" : "Looked up \(count)×"
    return days > 1 ? "\(times) · \(days) days" : times
  }

  static func nextReview(_ review: ReviewState) -> String {
    if ReviewScheduler.isDue(review, now: Date()) {
      return L10n.isChinese ? "今天复习" : "Due today"
    }
    let date = LearningCopy.date(review.due)
    return L10n.isChinese ? "下次复习 \(date)" : "Next review \(date)"
  }

  /// The sentence with the term set in bold, wherever the term appears in it.
  static func highlighted(_ sentence: String, term: LearningTerm) -> AttributedString {
    var attributed = AttributedString(sentence)
    let needles = LearningLedger.unique(term.encounters.map(\.surface) + [term.display, term.headword])
      .sorted { $0.count > $1.count }
    for needle in needles where !needle.isEmpty {
      guard let range = sentence.range(of: needle, options: [.caseInsensitive, .widthInsensitive]),
        let lower = AttributedString.Index(range.lowerBound, within: attributed),
        let upper = AttributedString.Index(range.upperBound, within: attributed)
      else { continue }
      attributed[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
      break
    }
    return attributed
  }
}
