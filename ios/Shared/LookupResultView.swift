import SwiftUI
import UIKit

/// The answer to one lookup, with the action strip above it. Used by the
/// Action extension's sheet and by the app's own lookup screen.
struct LookupResultView: View {
  @ObservedObject var session: LookupSession
  /// Shown when the answer failed for want of a key, so the reader knows
  /// where to fix it. The extension cannot open Settings itself.
  var setupHint: String?
  /// Opens the connection settings where the lookup is, for the Share sheet.
  var onSetup: (() -> Void)?

  @Environment(\.palette) private var palette
  @State private var copied = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      actionStrip
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          answer
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      Divider()
      footer
    }
  }

  // MARK: Actions

  private var actionStrip: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(session.actions) { action in
          let selected = action.id == session.action?.id
          Button {
            session.select(action)
          } label: {
            Label(action.mobileTitle, systemImage: action.mobileSymbol)
              .font(.subheadline.weight(selected ? .semibold : .regular))
              .padding(.horizontal, 12)
              .padding(.vertical, 7)
              .background(
                Capsule().fill(selected ? palette.brand : palette.muted)
              )
              .foregroundStyle(selected ? palette.brandForeground : palette.foreground)
          }
          .buttonStyle(.plain)
          .accessibilityAddTraits(selected ? .isSelected : [])
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
    }
  }

  // MARK: Answer

  @ViewBuilder
  private var answer: some View {
    if let error = session.errorMessage {
      VStack(alignment: .leading, spacing: 8) {
        Label(error, systemImage: "exclamationmark.triangle")
          .foregroundStyle(palette.destructive)
        if let setupHint, needsSetup {
          Text(setupHint)
            .font(.footnote)
            .foregroundStyle(palette.mutedForeground)
        }
        if let onSetup, needsSetup {
          Button(L10n.isChinese ? "在这里设置" : "Set Up Here", systemImage: "key", action: onSetup)
            .buttonStyle(.borderedProminent)
        }
      }
    } else if session.output.isEmpty {
      if session.isRunning {
        HStack(spacing: 10) {
          ProgressView()
          Text(L10n.isChinese ? "正在查询…" : "Looking it up…")
            .foregroundStyle(palette.mutedForeground)
        }
      } else if session.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        Text(L10n.isChinese ? "没有收到文字。" : "No text to look up.")
          .foregroundStyle(palette.mutedForeground)
      }
    } else if session.isMarkdown {
      MarkdownText(session.output, baseFontSize: 17)
    } else {
      Text(session.output)
        .font(.system(size: 19))
        .lineSpacing(5)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var needsSetup: Bool {
    guard let message = session.errorMessage else { return false }
    return message == TranslationError.missingAPIKey.localizedDescription
      || message.contains("401")
  }

  // MARK: Footer

  private var footer: some View {
    HStack(spacing: 12) {
      Text(languageLine)
        .font(.footnote)
        .foregroundStyle(palette.mutedForeground)
        .lineLimit(1)
      Spacer()
      if session.isRunning {
        Button(L10n.isChinese ? "停止" : "Stop", systemImage: "stop.fill") {
          session.stop()
        }
      } else {
        Button(L10n.isChinese ? "重试" : "Retry", systemImage: "arrow.clockwise") {
          session.run()
        }
        .disabled(session.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      Button {
        UIPasteboard.general.string = session.output
        copied = true
        Task {
          try? await Task.sleep(for: .seconds(1.5))
          copied = false
        }
      } label: {
        Label(
          copied ? (L10n.isChinese ? "已拷贝" : "Copied") : (L10n.isChinese ? "拷贝" : "Copy"),
          systemImage: copied ? "checkmark" : "doc.on.doc"
        )
      }
      .buttonStyle(.borderedProminent)
      .disabled(session.output.isEmpty)
    }
    .labelStyle(.titleAndIcon)
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
  }

  private var languageLine: String {
    let target = session.store.settings.targetLanguage.displayName
    guard session.detectedSource != .auto else { return "→ \(target)" }
    return "\(session.detectedSource.displayName) → \(target)"
  }
}
