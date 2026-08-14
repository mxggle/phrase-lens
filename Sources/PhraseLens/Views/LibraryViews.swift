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
          .foregroundStyle(palette.faintForeground)
      }

      Spacer(minLength: AppSpacing.sm)

      toolbar
    }
    .padding(.horizontal, AppSpacing.lg)
    .padding(.vertical, AppSpacing.sm + 2)
    .background(palette.chrome)
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

/// Scrolling body shared by both collections.
private struct LibraryList<Item: Identifiable, Row: View>: View {
  let items: [Item]
  /// Widest a single column may get before the grid adds another one.
  var columnMinWidth: CGFloat?
  @ViewBuilder var row: (Item) -> Row

  @Environment(\.layoutWidth) private var layoutWidth

  var body: some View {
    ScrollView {
      if let columnMinWidth, !layoutWidth.isCompact {
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: columnMinWidth), spacing: AppSpacing.sm)],
          alignment: .leading,
          spacing: AppSpacing.sm
        ) {
          ForEach(items) { row($0) }
        }
        .padding(AppSpacing.lg)
      } else {
        LazyVStack(spacing: AppSpacing.sm) {
          ForEach(items) { row($0) }
        }
        .padding(AppSpacing.lg)
      }
    }
    .scrollIndicators(.automatic)
  }
}

// MARK: - History

struct HistoryView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.layoutWidth) private var layoutWidth
  @State private var searchText = ""
  @State private var selection = Set<UUID>()

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
            Button("Delete", role: .destructive) {
              model.deleteHistory(ids: [entry.id])
              selection.remove(entry.id)
            }
          }
        }
      }
    }
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
      model.deleteHistory(ids: selection)
      selection.removeAll()
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
        Text(entry.createdAt, style: .relative)
          .font(AppFont.caption)
          .foregroundStyle(palette.faintForeground)
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
  @Environment(\.layoutWidth) private var layoutWidth
  @State private var searchText = ""
  @State private var selection = Set<UUID>()

  private var filtered: [VocabularyEntry] {
    guard !searchText.isEmpty else { return model.vocabulary }
    return model.vocabulary.filter {
      $0.word.localizedCaseInsensitiveContains(searchText)
        || $0.explanation.localizedCaseInsensitiveContains(searchText)
    }
  }

  var body: some View {
    let filteredEntries = filtered
    LibraryScaffold(
      searchText: $searchText,
      searchPrompt: "Search vocabulary",
      count: filteredEntries.count,
      countNoun: filteredEntries.count == 1 ? "word" : "words"
    ) {
      Button {
        model.deleteVocabulary(ids: selection)
        selection.removeAll()
      } label: {
        AdaptiveLabel(title: "Delete", symbol: "trash", iconOnly: layoutWidth.isCompact)
      }
      .appButton(.destructiveGhost, size: .sm)
      .disabled(selection.isEmpty)
      .help("Delete the selected words")
      .accessibilityLabel("Delete the selected words")
    } content: {
      if filteredEntries.isEmpty {
        emptyState
      } else {
        // Vocabulary entries are short and self-contained, so they tile into
        // however many columns the window can hold.
        LibraryList(items: filteredEntries, columnMinWidth: 300) { entry in
          LibraryCard(
            isSelected: selection.contains(entry.id),
            onSelect: { extending in select(entry.id, extending: extending) }
          ) {
            VocabularyRow(entry: entry)
          }
          .contextMenu {
            Button("Copy Explanation") { copyExplanation(of: entry) }
            Divider()
            Button("Delete", role: .destructive) {
              model.deleteVocabulary(ids: [entry.id])
              selection.remove(entry.id)
            }
          }
        }
      }
    }
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
        symbol: "books.vertical",
        title: "No saved words",
        message: "Choose Collect under a short translation to save it here."
      )
    } else {
      EmptyState(
        symbol: "magnifyingglass",
        title: "No matches",
        message: "No saved word matches “\(searchText)”."
      ) {
        Button("Clear Search") { searchText = "" }
          .appButton(.outline, size: .sm)
      }
    }
  }

  private func copyExplanation(of entry: VocabularyEntry) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(entry.explanation, forType: .string)
  }
}

private struct VocabularyRow: View {
  let entry: VocabularyEntry

  @Environment(\.palette) private var palette

  var body: some View {
    VStack(alignment: .leading, spacing: AppSpacing.sm) {
      HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
        Text(entry.word)
          .font(AppFont.title)
          .foregroundStyle(palette.foreground)
          .lineLimit(2)
        Spacer(minLength: AppSpacing.sm)
        Badge(
          text: "\(entry.sourceLanguage.displayName) → \(entry.targetLanguage.displayName)",
          variant: .outline
        )
      }

      Text(entry.explanation)
        .font(AppFont.body)
        .foregroundStyle(palette.mutedForeground)
        .lineLimit(5)
        .frame(maxWidth: .infinity, alignment: .leading)

      Text(entry.createdAt, style: .relative)
        .font(AppFont.caption)
        .foregroundStyle(palette.faintForeground)
    }
    .accessibilityLabel("\(entry.word). \(entry.explanation)")
  }
}
