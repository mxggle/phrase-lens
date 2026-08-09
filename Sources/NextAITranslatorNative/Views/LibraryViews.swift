import AppKit
import SwiftUI

struct HistoryView: View {
  @EnvironmentObject private var model: AppModel
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
    Group {
      if filtered.isEmpty {
        emptyState
      } else {
        List(selection: $selection) {
          ForEach(filtered) { entry in
            HistoryRow(entry: entry)
              .tag(entry.id)
              .contextMenu {
                Button("Use Again") { model.restore(entry) }
                Button(entry.favorite ? "Remove from Favorites" : "Add to Favorites") {
                  model.toggleFavorite(entry)
                }
                Divider()
                Button("Delete", role: .destructive) {
                  model.deleteHistory(ids: [entry.id])
                }
              }
              .onTapGesture(count: 2) { model.restore(entry) }
          }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds()
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(AppDesign.canvas)
    .searchable(text: $searchText, prompt: "Search history")
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        Button {
          if let id = selection.first,
            let entry = model.history.first(where: { $0.id == id })
          {
            model.restore(entry)
          }
        } label: {
          Label("Use Again", systemImage: "arrow.uturn.backward")
        }
        .disabled(selection.count != 1)
        .help("Load the selected translation back into the translator")

        Button(role: .destructive) {
          model.deleteHistory(ids: selection)
          selection.removeAll()
        } label: {
          Label("Delete", systemImage: "trash")
        }
        .disabled(selection.isEmpty)
        .help("Delete the selected entries")
      }
    }
  }

  @ViewBuilder
  private var emptyState: some View {
    if searchText.isEmpty {
      ContentUnavailableView(
        "No History",
        systemImage: "clock.arrow.circlepath",
        description: Text("Completed translations are saved on this Mac and appear here.")
      )
    } else {
      ContentUnavailableView.search(text: searchText)
    }
  }
}

private struct HistoryRow: View {
  let entry: HistoryEntry

  var body: some View {
    VStack(alignment: .leading, spacing: AppSpacing.xs) {
      HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
        Text(entry.sourceText)
          .font(.body.weight(.medium))
          .lineLimit(1)
        Spacer(minLength: AppSpacing.sm)
        if entry.favorite {
          Image(systemName: "star.fill")
            .font(.caption)
            .foregroundStyle(.yellow)
            .accessibilityLabel("Favorite")
        }
        Text(entry.createdAt, style: .relative)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .layoutPriority(1)
      }
      Text(entry.translatedText)
        .foregroundStyle(.secondary)
        .lineLimit(2)
      Text(
        "\(entry.actionName) · \(entry.sourceLanguage.displayName) → "
          + entry.targetLanguage.displayName
      )
      .font(.caption)
      .foregroundStyle(.tertiary)
    }
    .padding(.vertical, AppSpacing.xs + 1)
  }
}

struct VocabularyView: View {
  @EnvironmentObject private var model: AppModel
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
    Group {
      if filtered.isEmpty {
        emptyState
      } else {
        List(filtered, selection: $selection) { entry in
          VocabularyRow(entry: entry)
            .tag(entry.id)
            .contextMenu {
              Button("Copy Explanation") {
                copyExplanation(of: entry)
              }
              Divider()
              Button("Delete", role: .destructive) {
                model.deleteVocabulary(ids: [entry.id])
              }
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds()
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(AppDesign.canvas)
    .searchable(text: $searchText, prompt: "Search vocabulary")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button(role: .destructive) {
          model.deleteVocabulary(ids: selection)
          selection.removeAll()
        } label: {
          Label("Delete", systemImage: "trash")
        }
        .disabled(selection.isEmpty)
        .help("Delete the selected words")
      }
    }
  }

  @ViewBuilder
  private var emptyState: some View {
    if searchText.isEmpty {
      ContentUnavailableView(
        "No Saved Words",
        systemImage: "books.vertical",
        description: Text("Choose Collect under a short translation to save it here.")
      )
    } else {
      ContentUnavailableView.search(text: searchText)
    }
  }

  private func copyExplanation(of entry: VocabularyEntry) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(entry.explanation, forType: .string)
  }
}

private struct VocabularyRow: View {
  let entry: VocabularyEntry

  var body: some View {
    VStack(alignment: .leading, spacing: AppSpacing.xs) {
      HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
        Text(entry.word)
          .font(.body.weight(.medium))
        Spacer(minLength: AppSpacing.sm)
        Text("\(entry.sourceLanguage.displayName) → \(entry.targetLanguage.displayName)")
          .font(.caption)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
      }
      Text(entry.explanation)
        .foregroundStyle(.secondary)
        .lineLimit(4)
    }
    .padding(.vertical, AppSpacing.xs + 1)
  }
}
