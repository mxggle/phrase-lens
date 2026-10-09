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
      .accessibilityLabel(L10n.isChinese ? "追问记录" : "Follow-up questions")
    }
  }
}

/// One question and its answer. The question is set as a bubble on the
/// trailing edge — the shape every chat interface has taught readers to scan
/// for — so the eye can find where each answer starts in a long thread.
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
      question
      answer
    }
    .onHover { isHovering = $0 }
    .animation(AppMotion.hover(reduceMotion: reduceMotion), value: isHovering)
  }

  private var question: some View {
    HStack(alignment: .center, spacing: AppSpacing.xs) {
      Spacer(minLength: AppSpacing.xxxl)

      // Row commands stay out of the reading until the pointer is on the turn
      // they belong to, so a long thread reads as prose rather than as a list
      // of toolbars. They are only faded, never removed: VoiceOver never
      // hovers, and a command it cannot reach is a command it does not have.
      HStack(spacing: 0) {
        IconButton(
          title: L10n.isChinese ? "拷贝此回答" : "Copy this answer",
          symbol: "doc.on.doc",
          isDisabled: turn.answer.isEmpty
        ) {
          model.copyFollowUpAnswer(turn.id)
        }
        IconButton(title: L10n.isChinese ? "删除此问题" : "Remove this question", symbol: "trash") {
          model.removeFollowUp(turn.id)
        }
      }
      .opacity(isHovering ? 1 : 0)

      Text(turn.question)
        .font(.system(size: settingsStore.settings.fontSize - 1))
        .foregroundStyle(palette.foreground)
        .lineSpacing(2)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, AppSpacing.md + 1)
        .padding(.vertical, AppSpacing.sm)
        .background(palette.muted, in: RoundedRectangle(cornerRadius: AppRadius.xxl, style: .continuous))
        .accessibilityLabel(L10n.isChinese ? "提问：\(turn.question)" : "Question: \(turn.question)")
    }
    .padding(.top, AppSpacing.sm)
    .accessibilityElement(children: .contain)
  }

  @ViewBuilder
  private var answer: some View {
    if turn.answer.isEmpty {
      HStack(spacing: AppSpacing.sm) {
        Spinner(size: 12, isLive: isAnswering)
        Text(isAnswering ? (L10n.isChinese ? "正在思考…" : "Thinking…") : (L10n.isChinese ? "暂无回答" : "No answer"))
          .font(AppFont.labelRegular)
          .foregroundStyle(palette.mutedForeground)
      }
    } else {
      MarkdownText(turn.answer, baseFontSize: settingsStore.settings.fontSize)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

// MARK: - Suggestions

/// The questions worth asking next, set at the end of the answer.
///
/// They used to be a row of chips above the composer, which kept a band of
/// chrome under the result whether or not anyone wanted them. At the end of
/// the reading they appear exactly when the reader has finished and is
/// deciding what to ask, and they wrap instead of dropping the ones that do
/// not fit.
struct FollowUpSuggestionList: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.palette) private var palette

  private var suggestions: [FollowUpSuggestion] { model.followUpSuggestions }

  var body: some View {
    // Nothing is offered while text is still arriving: the chips cannot be
    // used until it stops, and a row that jumps down with every token is
    // noise at the edge of what is being read.
    if !suggestions.isEmpty, !model.isTranslating, !model.isAnsweringFollowUp {
      VStack(alignment: .leading, spacing: AppSpacing.sm) {
        HStack(spacing: AppSpacing.xs) {
          Image(systemName: "sparkle")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(palette.accent)
            .accessibilityHidden(true)
          Text(L10n.isChinese ? "继续追问" : "Ask next")
            .font(AppFont.captionMedium)
            .foregroundStyle(palette.mutedForeground)
        }
        .accessibilityAddTraits(.isHeader)

        FlowLayout(spacing: AppSpacing.xs + 2, lineSpacing: AppSpacing.xs + 2) {
          ForEach(suggestions) { suggestion in
            chip(suggestion)
          }
        }
      }
      .padding(.top, AppSpacing.xxl)
      .transition(.opacity)
      .accessibilityElement(children: .contain)
      .accessibilityLabel(L10n.isChinese ? "追问建议" : "Suggested questions")
    }
  }

  private func chip(_ suggestion: FollowUpSuggestion) -> some View {
    Button {
      model.askFollowUp(suggestion.question)
    } label: {
      HStack(spacing: AppSpacing.xs + 1) {
        Image(systemName: suggestion.symbol)
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(palette.mutedForeground)
        Text(suggestion.label)
          .font(AppFont.labelRegular)
          .foregroundStyle(palette.secondaryForeground)
      }
      .padding(.horizontal, AppSpacing.xxs)
    }
    .appButton(.secondary, size: .sm, capsule: true)
    .disabled(!model.canAskFollowUp)
    .help(suggestion.question)
    .accessibilityLabel(suggestion.question)
  }
}

// MARK: - Composer

/// Where a question is asked. It sits at the foot of the result, under the
/// answer it is about, and is a single row: the questions worth asking are
/// offered by `FollowUpSuggestionList` at the end of the answer instead.
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
  @State private var isFocused = false

  private var canSend: Bool {
    model.canAskFollowUp
      && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !model.isAnsweringFollowUp
  }

  var body: some View {
    VStack(alignment: .leading, spacing: AppSpacing.sm) {
      if let error = model.followUpError {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xs) {
          InlineNote(text: error, kind: .error)
          Button(L10n.isChinese ? "关闭" : "Dismiss") { model.dismissFollowUpError() }
            .appButton(.ghost, size: .xs)
        }
        .padding(.horizontal, AppSpacing.xs)
      }
      field
    }
    .padding(.horizontal, AppSpacing.md)
    .padding(.top, AppSpacing.xs)
    .padding(.bottom, AppSpacing.md)
    .background(palette.chrome)
    // A question the model hands back — one that was stopped or that failed
    // before it was answered — is the only thing outside this view that writes
    // the draft.
    .onChange(of: model.followUpDraft) { _, handedBack in
      guard handedBack != draft else { return }
      draft = handedBack
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(L10n.isChinese ? "追问" : "Follow-up")
  }

  // MARK: Field

  /// A prompt box rather than a form field: one rounded container holding the
  /// question and the round command that sends it, lifted slightly off the
  /// answer it sits under.
  private var field: some View {
    let shape = RoundedRectangle(cornerRadius: AppRadius.xxl, style: .continuous)
    return HStack(spacing: AppSpacing.sm) {
      AppTextField(
        placeholder: model.followUps.isEmpty
          ? (L10n.isChinese ? "针对此结果继续追问…" : "Ask a follow-up about this…")
          : (L10n.isChinese ? "提出下一个问题…" : "Ask another…"),
        text: $draft,
        size: .md,
        onSubmit: send,
        focusToken: model.followUpFocusToken,
        chromeless: true,
        onFocusChange: { isFocused = $0 }
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
          .font(.system(size: 12.5, weight: .semibold))
          .contentTransition(.symbolEffect(.replace))
      }
      .appButton(model.isAnsweringFollowUp ? .secondary : (canSend ? .brand : .secondary), size: .iconSmall, capsule: true)
      .disabled(!model.isAnsweringFollowUp && !canSend)
      .help(model.isAnsweringFollowUp ? (L10n.isChinese ? "停止回答 (⌘.)" : "Stop answering (⌘.)") : (L10n.isChinese ? "提问 (↩)" : "Ask (↩)"))
      .accessibilityLabel(model.isAnsweringFollowUp ? (L10n.isChinese ? "停止回答" : "Stop answering") : (L10n.isChinese ? "发送追问" : "Ask"))
    }
    .padding(.leading, AppSpacing.md + 2)
    .padding(.trailing, AppSpacing.xs)
    .padding(.vertical, AppSpacing.xs)
    .background(palette.surface, in: shape)
    .overlay { shape.strokeBorder(isFocused ? palette.borderStrong : palette.border, lineWidth: 1) }
    .shadow(color: palette.shadow, radius: isFocused ? 10 : 6, y: 2)
    .animation(.easeOut(duration: 0.15), value: isFocused)
  }

  private func send() {
    guard canSend else { return }
    let question = draft
    draft = ""
    model.askFollowUp(question)
  }
}
