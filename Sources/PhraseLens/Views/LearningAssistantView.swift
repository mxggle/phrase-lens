import SwiftUI

/// The study assistant: questions about the reader's own study, answered from
/// the record through tools.
struct LearningAssistantView: View {
  @EnvironmentObject private var learning: LearningModel
  @Environment(\.palette) private var palette
  @Environment(\.openSettings) private var openSettings
  /// View-local for the same reason as the follow-up composer's draft: a
  /// field bound through a model that republishes while an answer arrives
  /// re-lays itself out on every publish.
  @State private var draft = ""
  @State private var isFocused = false

  private static var starters: [String] {
    L10n.isChinese
      ? [
        "我最近学习上卡在哪里？",
        "把我容易混淆的词整理成对比表",
        "这周哪些词最该优先复习？为什么？",
        "用我查过的词和句子出 5 道小测验",
      ]
      : [
        "Where am I getting stuck lately?",
        "Put the words I mix up into a comparison table",
        "Which terms should I review first this week, and why?",
        "Quiz me with 5 questions built from my own lookups",
      ]
  }

  var body: some View {
    VStack(spacing: 0) {
      if learning.assistantMessages.isEmpty {
        intro
      } else {
        transcript
      }
      composer
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: Intro

  private var intro: some View {
    ScrollView {
      VStack(spacing: AppSpacing.lg) {
        EmptyState(
          symbol: "bubble.left.and.text.bubble.right",
          title: L10n.isChinese ? "问问你的学习助理" : "Ask about your study",
          message: L10n.isChinese
            ? "助理会先查阅你的查词记录、追问、相关词和复习进度，再回答。使用默认的 AI 连接。"
            : "It reads your lookups, follow-ups, related terms, and review progress before it answers, using the default AI connection."
        )
        FlowLayout(spacing: AppSpacing.sm, lineSpacing: AppSpacing.sm) {
          ForEach(Self.starters, id: \.self) { starter in
            Button {
              learning.askAssistant(starter)
            } label: {
              Text(starter).font(AppFont.label)
            }
            .appButton(.outline, size: .md, capsule: true)
            .disabled(!learning.canAnalyze)
          }
        }
        .frame(maxWidth: 560)
        if !learning.canAnalyze {
          Button(L10n.isChinese ? "先配置 AI 连接" : "Set up an AI connection first") {
            SettingsNavigation.show(.provider) { openSettings() }
          }
          .appButton(.brand, size: .sm)
        }
      }
      .padding(AppSpacing.xl)
      .frame(maxWidth: .infinity)
    }
  }

  // MARK: Transcript

  private var transcriptLength: Int {
    learning.assistantMessages.reduce(0) { $0 + $1.text.count + $1.events.count }
  }

  private var transcript: some View {
    FollowingScrollView(isFollowing: learning.isAssistantRunning, trigger: transcriptLength) {
      LazyVStack(alignment: .leading, spacing: AppSpacing.lg) {
        ForEach(learning.assistantMessages) { message in
          AssistantMessageView(
            message: message,
            isRunning: learning.isAssistantRunning && message.id == learning.assistantMessages.last?.id
          )
        }
      }
      .padding(AppSpacing.lg)
      .frame(maxWidth: 820, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  // MARK: Composer

  private var canSend: Bool {
    !learning.isAssistantRunning && learning.canAnalyze
      && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var composer: some View {
    let shape = RoundedRectangle(cornerRadius: AppRadius.xxl, style: .continuous)
    return HStack(spacing: AppSpacing.sm) {
      if !learning.assistantMessages.isEmpty {
        IconButton(
          title: L10n.isChinese ? "清空对话" : "Clear the conversation",
          symbol: "trash",
          isDisabled: learning.isAssistantRunning
        ) {
          learning.clearAssistant()
        }
      }
      HStack(spacing: AppSpacing.sm) {
        AppTextField(
          placeholder: L10n.isChinese ? "问问关于你学习的任何事…" : "Ask anything about your study…",
          text: $draft,
          size: .md,
          onSubmit: send,
          chromeless: true,
          onFocusChange: { isFocused = $0 }
        )
        .disabled(learning.isAssistantRunning || !learning.canAnalyze)
        Button {
          if learning.isAssistantRunning { learning.stopAssistant() } else { send() }
        } label: {
          Image(systemName: learning.isAssistantRunning ? "stop.fill" : "arrow.up")
            .font(.system(size: 12.5, weight: .semibold))
            .contentTransition(.symbolEffect(.replace))
        }
        .appButton(
          learning.isAssistantRunning ? .secondary : (canSend ? .brand : .secondary),
          size: .iconSmall,
          capsule: true
        )
        .disabled(!learning.isAssistantRunning && !canSend)
        .help(learning.isAssistantRunning ? (L10n.isChinese ? "停止" : "Stop") : (L10n.isChinese ? "发送 (↩)" : "Send (↩)"))
        .accessibilityLabel(learning.isAssistantRunning ? (L10n.isChinese ? "停止" : "Stop") : (L10n.isChinese ? "发送" : "Send"))
      }
      .padding(.leading, AppSpacing.md + 2)
      .padding(.trailing, AppSpacing.xs)
      .padding(.vertical, AppSpacing.xs)
      .background(palette.surface, in: shape)
      .overlay { shape.strokeBorder(isFocused ? palette.borderStrong : palette.border, lineWidth: 1) }
      .shadow(color: palette.shadow, radius: isFocused ? 10 : 6, y: 2)
      .animation(.easeOut(duration: 0.15), value: isFocused)
    }
    .padding(.horizontal, AppSpacing.lg)
    .padding(.vertical, AppSpacing.md)
    .frame(maxWidth: 820)
    .frame(maxWidth: .infinity)
    .background(palette.chrome)
  }

  private func send() {
    guard canSend else { return }
    let question = draft
    draft = ""
    learning.askAssistant(question)
  }
}

private struct AssistantMessageView: View {
  let message: AssistantMessage
  let isRunning: Bool

  @EnvironmentObject private var settingsStore: SettingsStore
  @Environment(\.palette) private var palette

  var body: some View {
    switch message.role {
    case .user:
      HStack {
        Spacer(minLength: 80)
        Text(message.text)
          .font(.system(size: settingsStore.settings.fontSize - 1))
          .foregroundStyle(palette.foreground)
          .textSelection(.enabled)
          .padding(.horizontal, AppSpacing.md)
          .padding(.vertical, AppSpacing.sm + 1)
          .background(palette.accentSoft, in: RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous))
      }
    case .assistant:
      VStack(alignment: .leading, spacing: AppSpacing.sm) {
        if !message.events.isEmpty {
          VStack(alignment: .leading, spacing: 3) {
            ForEach(message.events) { event in
              HStack(spacing: AppSpacing.xs + 1) {
                Image(systemName: event.failed ? "exclamationmark.triangle" : "wrench.and.screwdriver")
                  .font(.system(size: 9.5, weight: .semibold))
                  .foregroundStyle(event.failed ? palette.warning : palette.faintForeground)
                  .frame(width: 14)
                Text(event.summary)
                  .font(AppFont.caption)
                  .foregroundStyle(palette.mutedForeground)
                  .lineLimit(1)
              }
            }
          }
        }
        if message.text.isEmpty, isRunning {
          HStack(spacing: AppSpacing.sm) {
            Spinner(size: 12, isLive: true)
            Text(L10n.isChinese ? "正在查阅你的学习记录…" : "Reading your study record…")
              .font(AppFont.label)
              .foregroundStyle(palette.mutedForeground)
          }
        } else if message.isError {
          InlineNote(text: message.text, kind: .error)
        } else if !message.text.isEmpty {
          MarkdownText(message.text, baseFontSize: settingsStore.settings.fontSize - 1)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}
