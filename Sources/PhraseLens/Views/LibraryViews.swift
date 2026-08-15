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
          columns: [
            GridItem(
              .adaptive(minimum: columnMinWidth),
              spacing: AppSpacing.md,
              alignment: .topLeading
            )
          ],
          alignment: .leading,
          spacing: AppSpacing.md
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
  @Environment(\.layoutWidth) private var layoutWidth
  @State private var searchText = ""
  @State private var selection = Set<UUID>()
  @State private var pendingDelete = Set<UUID>()
  @State private var isConfirmingDelete = false

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
        confirmDelete(of: selection)
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
            Button("Delete", role: .destructive) { confirmDelete(of: [entry.id]) }
          }
        }
      }
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
    .accessibilityLabel("\(entry.word). \(entry.explanation)")
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
