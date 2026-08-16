import SwiftUI

// MARK: - Thread

/// The questions asked about the current result, rendered directly under it.
///
/// A follow-up is not a second result: it is the same reading continued, so it
/// shares one scroller with the answer it is about rather than opening a panel
/// that hides the text the question was about.
struct FollowUpThread: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    if !model.followUps.isEmpty {
      VStack(alignment: .leading, spacing: AppSpacing.lg) {
        ForEach(model.followUps) { turn in
          FollowUpTurnView(
            turn: turn,
            isAnswering: model.isAnsweringFollowUp && turn.id == model.followUps.last?.id
          )
        }
      }
      .padding(.top, AppSpacing.lg)
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Follow-up questions")
    }
  }
}

/// One question and its answer. The question is set on a muted block so the
/// eye can find where each answer starts while scrolling a long thread.
private struct FollowUpTurnView: View {
  let turn: FollowUpTurn
  let isAnswering: Bool

  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var settingsStore: SettingsStore
  @Environment(\.palette) private var palette
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isHovering = false

  var body: some View {
    VStack(alignment: .leading, spacing: AppSpacing.md) {
      Hairline()
      question
      answer
    }
    .onHover { isHovering = $0 }
    .animation(AppMotion.hover(reduceMotion: reduceMotion), value: isHovering)
  }

  private var question: some View {
    HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
      Image(systemName: "arrow.turn.down.right")
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(palette.faintForeground)
        .accessibilityHidden(true)

      Text(turn.question)
        .font(.system(size: settingsStore.settings.fontSize - 1, weight: .medium))
        .foregroundStyle(palette.secondaryForeground)
        .lineSpacing(2)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("Question: \(turn.question)")

      // Row commands stay out of the reading until the pointer is on the turn
      // they belong to, so a long thread reads as prose rather than as a list
      // of toolbars. They are only faded, never removed: VoiceOver never
      // hovers, and a command it cannot reach is a command it does not have.
      HStack(spacing: 0) {
        IconButton(
          title: "Copy this answer",
          symbol: "doc.on.doc",
          isDisabled: turn.answer.isEmpty
        ) {
          model.copyFollowUpAnswer(turn.id)
        }
        IconButton(title: "Remove this question", symbol: "trash") {
          model.removeFollowUp(turn.id)
        }
      }
      .opacity(isHovering ? 1 : 0)
    }
    .padding(.leading, AppSpacing.sm + 2)
    .padding(.trailing, AppSpacing.xs)
    .padding(.vertical, AppSpacing.xs)
    .background(palette.muted, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
    .accessibilityElement(children: .contain)
  }

  @ViewBuilder
  private var answer: some View {
    if turn.answer.isEmpty {
      HStack(spacing: AppSpacing.sm) {
        Spinner(size: 12)
        Text(isAnswering ? "Thinking…" : "No answer")
          .font(AppFont.labelRegular)
          .foregroundStyle(palette.mutedForeground)
      }
      .padding(.leading, AppSpacing.sm + 2)
    } else {
      MarkdownText(turn.answer, baseFontSize: settingsStore.settings.fontSize)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

// MARK: - Composer

/// Where a question is asked. It sits at the foot of the result, under the
/// answer it is about, and offers the questions worth asking before the reader
/// has to think of one: a chip is one click, and typing is always there.
struct FollowUpComposer: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.palette) private var palette
  /// The draft lives here rather than on the model on purpose.
  ///
  /// The model republishes on every streamed token — twenty times a second —
  /// and a `TextField` bound through it is handed a new string value on each
  /// one. AppKit answers that by reconfiguring the cell and invalidating its
  /// intrinsic size, which schedules the layout pass that produces the next
  /// publish: the window pegs a core and stops drawing. View-local state ends
  /// the cycle, and a draft is view state anyway.
  @State private var draft = ""

  private var suggestions: [FollowUpSuggestion] { model.followUpSuggestions }

  private var canSend: Bool {
    model.canAskFollowUp
      && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !model.isAnsweringFollowUp
  }

  var body: some View {
    VStack(spacing: 0) {
      Hairline()
      VStack(alignment: .leading, spacing: AppSpacing.sm) {
        if let error = model.followUpError {
          HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xs) {
            InlineNote(text: error, kind: .error)
            Button("Dismiss") { model.dismissFollowUpError() }
              .appButton(.ghost, size: .xs)
          }
        }
        if !suggestions.isEmpty {
          chips
        }
        field
      }
      .padding(.horizontal, AppSpacing.sm + 2)
      .padding(.vertical, AppSpacing.sm)
      .background(palette.chrome)
    }
    // A question the model hands back — one that was stopped or that failed
    // before it was answered — is the only thing outside this view that writes
    // the draft.
    .onChange(of: model.followUpDraft) { _, handedBack in
      guard handedBack != draft else { return }
      draft = handedBack
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Follow-up")
  }

  // MARK: Suggestions

  /// The strip never scrolls and never wraps: it renders as many chips as the
  /// pane can hold and drops the rest, in the order a reader reaches for them.
  private var chips: some View {
    ViewThatFits(in: .horizontal) {
      chipRow(5)
      chipRow(4)
      chipRow(3)
      chipRow(2)
      chipRow(1)
    }
    .frame(height: AppControlSize.xs.height)
  }

  private func chipRow(_ count: Int) -> some View {
    HStack(spacing: AppSpacing.xs + 2) {
      ForEach(Array(suggestions.prefix(count))) { suggestion in
        chip(suggestion)
      }
      Spacer(minLength: 0)
    }
  }

  private func chip(_ suggestion: FollowUpSuggestion) -> some View {
    Button {
      model.askFollowUp(suggestion.question)
    } label: {
      HStack(spacing: AppSpacing.xs) {
        Image(systemName: suggestion.symbol)
          .font(.system(size: 9.5, weight: .semibold))
        Text(suggestion.label)
      }
    }
    .appButton(.outline, size: .xs)
    .disabled(!model.canAskFollowUp || model.isAnsweringFollowUp)
    .help(suggestion.question)
    .accessibilityLabel(suggestion.question)
  }

  // MARK: Field

  private var field: some View {
    HStack(spacing: AppSpacing.sm) {
      AppTextField(
        placeholder: model.followUps.isEmpty
          ? "Ask a follow-up about this…"
          : "Ask another…",
        text: $draft,
        symbol: "text.bubble",
        size: .sm,
        onSubmit: send,
        focusToken: model.followUpFocusToken
      )
      .disabled(!model.canAskFollowUp || model.isAnsweringFollowUp)

      Button {
        if model.isAnsweringFollowUp {
          model.stopFollowUp()
        } else {
          send()
        }
      } label: {
        Image(systemName: model.isAnsweringFollowUp ? "stop.fill" : "arrow.up")
          .font(.system(size: 11, weight: .semibold))
          .contentTransition(.symbolEffect(.replace))
      }
      .appButton(model.isAnsweringFollowUp ? .secondary : .primary, size: .iconSmall)
      .disabled(!model.isAnsweringFollowUp && !canSend)
      .help(model.isAnsweringFollowUp ? "Stop answering (⌘.)" : "Ask (↩)")
      .accessibilityLabel(model.isAnsweringFollowUp ? "Stop answering" : "Ask")
    }
  }

  private func send() {
    guard canSend else { return }
    let question = draft
    draft = ""
    model.askFollowUp(question)
  }
}
