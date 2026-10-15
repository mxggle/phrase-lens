import SwiftUI

/// Type or paste text and look it up, with the same actions the Share sheet
/// offers. Also the first screen, so it explains how to reach PhraseLens from
/// other apps until the first lookup.
struct LookupScreen: View {
  @StateObject private var session: LookupSession
  @FocusState private var editing: Bool
  @State private var draft = ""

  @Environment(\.palette) private var palette

  init(store: MobileSettingsStore) {
    _session = StateObject(wrappedValue: LookupSession(store: store))
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        HStack(alignment: .top, spacing: 10) {
          TextField(
            L10n.isChinese ? "输入或粘贴要查的文字" : "Type or paste text",
            text: $draft,
            axis: .vertical
          )
          .lineLimit(1...5)
          .font(.title3)
          .focused($editing)
          .submitLabel(.search)
          .onSubmit(lookUp)
          if !draft.isEmpty {
            Button {
              draft = ""
              editing = true
            } label: {
              Image(systemName: "xmark.circle.fill")
                .foregroundStyle(palette.faintForeground)
            }
            .accessibilityLabel(L10n.isChinese ? "清除" : "Clear")
          }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(palette.muted))
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)

        if session.text.isEmpty {
          ShareSheetGuide()
            .padding(16)
          Spacer()
        } else {
          LookupResultView(
            session: session,
            setupHint: L10n.isChinese
              ? "在下方的“设置”标签页里检查服务商、模型和 API Key。"
              : "Check the provider, model, and API key in the Settings tab below."
          )
        }
      }
      .navigationTitle("PhraseLens")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(L10n.isChinese ? "查询" : "Look Up", action: lookUp)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        ToolbarItem(placement: .topBarLeading) {
          Button(L10n.isChinese ? "粘贴" : "Paste", systemImage: "doc.on.clipboard") {
            if let text = UIPasteboard.general.string {
              draft = text
              lookUp()
            }
          }
        }
      }
    }
  }

  private func lookUp() {
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    editing = false
    session.text = text
    session.run()
  }
}

/// How to reach PhraseLens from another app, since iOS gives it no place in
/// the selection menu itself.
private struct ShareSheetGuide: View {
  @Environment(\.palette) private var palette

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(L10n.isChinese ? "在任何 App 里查词" : "Look up from any app")
        .font(.headline)
      step(1, L10n.isChinese ? "选中一个单词或一段话" : "Select a word or passage")
      step(2, L10n.isChinese ? "在弹出的菜单里点“共享…”" : "Tap Share… in the menu that appears")
      step(3, L10n.isChinese ? "在列表底部点 “PhraseLens”" : "Tap PhraseLens near the bottom of the sheet")
      Text(
        L10n.isChinese
          ? "第一次用时，如果列表里没有 PhraseLens，点“编辑操作…”把它加进“个人收藏”，以后它会排在最上面。"
          : "If PhraseLens is missing the first time, tap Edit Actions… and add it to Favorites so it stays at the top."
      )
      .font(.footnote)
      .foregroundStyle(palette.mutedForeground)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(palette.border))
  }

  private func step(_ number: Int, _ text: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text("\(number)")
        .font(.footnote.weight(.semibold))
        .frame(width: 22, height: 22)
        .background(Circle().fill(palette.brand))
        .foregroundStyle(palette.brandForeground)
      Text(text)
    }
  }
}
