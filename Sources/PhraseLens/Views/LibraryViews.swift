import AppKit
import SwiftUI

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
        Text("\(count) \(countNoun)")
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
    return confirmationDialog(
      "Delete \(count) \(noun)?",
      isPresented: isPresented,
      titleVisibility: .visible
    ) {
      Button("Delete \(count) \(noun.capitalized)", role: .destructive, action: perform)
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "\(count == 1 ? "This \(singular) is" : "These \(count) \(plural) are") removed "
          + "from this Mac. There is no undo."
      )
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

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
      Text(title)
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
    .accessibilityLabel("\(title), \(count) words")
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
      searchPrompt: "Search history",
      count: filteredEntries.count,
      countNoun: filteredEntries.count == 1 ? "entry" : "entries"
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
            Button("Use Again") { model.restore(entry) }
            Button(entry.favorite ? "Remove from Favorites" : "Add to Favorites") {
              model.toggleFavorite(entry)
            }
            Divider()
            Button("Delete", role: .destructive) { confirmDelete(of: [entry.id]) }
          }
        }
      }
    }
    .libraryDeleteConfirmation(
      isPresented: $isConfirmingDelete,
      count: pendingDelete.count,
      singular: "entry",
      plural: "entries"
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
        title: "Use Again",
        symbol: "arrow.uturn.backward",
        iconOnly: layoutWidth.isCompact
      )
    }
    .appButton(.outline, size: .sm)
    .disabled(selection.count != 1)
    .help("Load the selected translation back into the translator")
    .accessibilityLabel("Use the selected translation again")

    Button {
      confirmDelete(of: selection)
    } label: {
      AdaptiveLabel(title: "Delete", symbol: "trash", iconOnly: layoutWidth.isCompact)
    }
    .appButton(.destructiveGhost, size: .sm)
    .disabled(selection.isEmpty)
    .help("Delete the selected entries")
    .accessibilityLabel("Delete the selected entries")
  }

  private func select(_ id: UUID, extending: Bool) {
    if extending {
      if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    } else {
      selection = [id]
    }
  }

  @ViewBuilder
  private var emptyState: some View {
    if searchText.isEmpty {
      EmptyState(
        symbol: "clock.arrow.circlepath",
        title: "No history yet",
        message: "Completed translations are saved on this Mac and appear here."
      )
    } else {
      EmptyState(
        symbol: "magnifyingglass",
        title: "No matches",
        message: "Nothing in your history matches “\(searchText)”."
      ) {
        Button("Clear Search") { searchText = "" }
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
          text: "\(entry.sourceLanguage.displayName) → \(entry.targetLanguage.displayName)",
          variant: .outline
        )
        if entry.favorite {
          Image(systemName: "star.fill")
            .font(.system(size: 9))
            .foregroundStyle(palette.warning)
            .accessibilityLabel("Favorite")
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
    }
    .accessibilityLabel(
      "\(entry.sourceText). Translated: \(entry.translatedText). "
        + "\(entry.actionName), \(entry.sourceLanguage.displayName) to "
        + entry.targetLanguage.displayName
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
      searchPrompt: "Search vocabulary",
      count: entries.count,
      countNoun: entries.count == 1 ? "word" : "words"
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
      onSelect: { extending in select(entry.id, extending: extending) }
    ) {
      VocabularyRow(entry: entry)
    }
    .contextMenu {
      Button("Copy Explanation") { copyExplanation(of: entry) }
      Button("Organize Again") { model.retagVocabulary(ids: [entry.id]) }
        .disabled(model.isOrganizingVocabulary)
      Divider()
      Button("Delete", role: .destructive) { confirmDelete(of: [entry.id]) }
    }
  }

  @ViewBuilder
  private func toolbar(sections: [VocabularyFacetSection]) -> some View {
    if layoutWidth.isCompact, !sections.isEmpty {
      Button {
        isFilterPresented = true
      } label: {
        AdaptiveLabel(
          title: filter.isEmpty ? "Filters" : "Filters (\(filter.count))",
          symbol: "line.3.horizontal.decrease",
          iconOnly: false
        )
      }
      .appButton(filter.isEmpty ? .outline : .secondary, size: .sm)
      .help("Narrow the collection by type, topic, or level")
      .popover(isPresented: $isFilterPresented, arrowEdge: .bottom) {
        VocabularyFacetRail(sections: sections, filter: $filter)
          .frame(width: 240, height: 360)
      }
    }

    AppSelect(
      title: "Group the collection into sections",
      selection: $grouping,
      options: VocabularyGrouping.allCases,
      // Narrow windows get the bare axis: the bar is already carrying a search
      // field and two commands, and "Group: Part of speech" is wider than the
      // room left for it.
      label: { grouping in
        if layoutWidth.isCompact || grouping == .none { return grouping.title }
        return "Group: \(grouping.title)"
      },
      size: .sm,
      symbol: "square.stack.3d.up"
    )

    Button {
      confirmDelete(of: selection)
    } label: {
      AdaptiveLabel(title: "Delete", symbol: "trash", iconOnly: layoutWidth.isCompact)
    }
    .appButton(.destructiveGhost, size: .sm)
    .disabled(selection.isEmpty)
    .help("Delete the selected words")
    .accessibilityLabel("Delete the selected words")
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

  @ViewBuilder
  private var emptyState: some View {
    if !filter.isEmpty {
      EmptyState(
        symbol: "line.3.horizontal.decrease",
        title: "No matches",
        message: "No saved word is filed under every one of those at once."
      ) {
        Button("Clear Filters") { filter.clear() }
          .appButton(.outline, size: .sm)
      }
    } else if !searchText.isEmpty {
      EmptyState(
        symbol: "magnifyingglass",
        title: "No matches",
        message: "No saved word matches “\(searchText)”."
      ) {
        Button("Clear Search") { searchText = "" }
          .appButton(.outline, size: .sm)
      }
    } else {
      EmptyState(
        symbol: "books.vertical",
        title: "No saved words",
        message: "Choose Collect under a short translation to save it here."
      )
    }
  }

  private func copyExplanation(of entry: VocabularyEntry) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(entry.explanation, forType: .string)
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
        Text("Organizing \(progress.completed) of \(progress.total)…")
          .font(AppFont.caption)
          .foregroundStyle(palette.secondaryForeground)
          .monospacedDigit()
        Spacer(minLength: AppSpacing.sm)
        Button("Stop", action: cancel)
          .appButton(.ghost, size: .xs)
      } else {
        Image(systemName: "sparkles")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(palette.mutedForeground)
        Text(
          unfiled == 1
            ? "1 word has not been sorted into categories yet."
            : "\(unfiled) words have not been sorted into categories yet."
        )
        .font(AppFont.caption)
        .foregroundStyle(palette.secondaryForeground)
        Spacer(minLength: AppSpacing.sm)
        Button("Organize", action: organize)
          .appButton(.outline, size: .xs)
          .help("Have the model file these under type, topic, part of speech, and level")
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
        Eyebrow(text: "Filter")
        Spacer(minLength: AppSpacing.xs)
        if !filter.isEmpty {
          Button("Clear") { filter.clear() }
            .appButton(.ghost, size: .xs)
            .accessibilityLabel("Clear all filters")
        }
      }
      .frame(height: AppMetrics.paneHeaderHeight)
      .padding(.horizontal, AppSpacing.md)

      Hairline()

      ScrollView {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
          ForEach(sections) { section in
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
              Eyebrow(text: section.facet.title)
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
    .accessibilityLabel("Vocabulary filters")
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
        Text(row.value.label)
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
    .help(row.value.label)
    .accessibilityLabel("\(row.value.label), \(row.count) words")
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
          text: "\(entry.sourceLanguage.displayName) → \(entry.targetLanguage.displayName)",
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
      if let unit = tags.unit { labels.append(unit.displayName) }
    case .word, nil:
      if let part = tags.partOfSpeech {
        labels.append(part.displayName)
      } else if let unit = tags.unit {
        labels.append(unit.displayName)
      }
    }
    if let level = tags.levelLabel {
      labels.append(level)
    } else if let difficulty = tags.difficulty {
      labels.append(difficulty.displayName)
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
