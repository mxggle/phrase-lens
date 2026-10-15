import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The sheet that opens from "Share…" on selected text in any app.
///
/// iOS does not let an app replace or join the system's own Translate and
/// Look Up items in the selection menu, so this Action extension is the
/// nearest hook: select, Share, PhraseLens, and the answer streams in over
/// the app the reader is already in.
final class ActionViewController: UIViewController {
  private var session: LookupSession?

  override func viewDidLoad() {
    super.viewDidLoad()
    let store = MobileSettingsStore()
    let session = LookupSession(store: store)
    self.session = session

    let root = ActionSheetView(session: session) { [weak self] in
      self?.extensionContext?.completeRequest(returningItems: nil)
    }
    let host = UIHostingController(rootView: root)
    addChild(host)
    host.view.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(host.view)
    NSLayoutConstraint.activate([
      host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      host.view.topAnchor.constraint(equalTo: view.topAnchor),
      host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    host.didMove(toParent: self)

    let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
    Task { @MainActor in
      session.text = await Self.sharedText(in: items)
      session.run()
    }
  }

  /// The selected text, from whichever form the host app handed it over in.
  /// Most apps send plain text; some attach it as the item's content text.
  private static func sharedText(in items: [NSExtensionItem]) async -> String {
    for item in items {
      for provider in item.attachments ?? [] {
        if let text = await loadText(from: provider), !text.isEmpty { return text }
      }
      if let text = item.attributedContentText?.string,
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        return text
      }
    }
    return ""
  }

  private static func loadText(from provider: NSItemProvider) async -> String? {
    let type = UTType.plainText.identifier
    guard provider.hasItemConformingToTypeIdentifier(type) else { return nil }
    return await withCheckedContinuation { continuation in
      provider.loadItem(forTypeIdentifier: type, options: nil) { item, _ in
        let text: String? =
          switch item {
          case let string as String: string
          case let attributed as NSAttributedString: attributed.string
          case let data as Data: String(data: data, encoding: .utf8)
          case let url as URL: try? String(contentsOf: url, encoding: .utf8)
          default: nil
          }
        continuation.resume(returning: text)
      }
    }
  }
}

private struct ActionSheetView: View {
  @ObservedObject var session: LookupSession
  let done: () -> Void
  @State private var settingUp = false

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        if !session.text.isEmpty {
          Text(session.text)
            .font(.headline)
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.top, 4)
            .padding(.bottom, 2)
            .textSelection(.enabled)
        }
        LookupResultView(
          session: session,
          setupHint: setupHint,
          onSetup: { settingUp = true }
        )
      }
      .navigationTitle("PhraseLens")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(L10n.isChinese ? "完成" : "Done", action: done)
        }
      }
    }
    .mobilePalette()
    .sheet(isPresented: $settingUp, onDismiss: { session.run() }) {
      SettingsScreen(onDone: { settingUp = false })
        .environmentObject(session.store)
        .mobilePalette()
    }
  }

  /// Where the key is set depends on whether this build shares settings with
  /// the app. A Personal Team build cannot, so the sheet keeps its own.
  private var setupHint: String {
    if MobileSettingsStore.isAppGroupAvailable {
      return L10n.isChinese
        ? "在 PhraseLens App 的“设置”里填好服务商和 API Key，或者直接在这里设置。"
        : "Add your provider and API key in the PhraseLens app's Settings, or set them up here."
    }
    return L10n.isChinese
      ? "这个版本的共享面板和 App 不共用设置，需要在这里单独填一次服务商和 API Key。"
      : "This build's Share sheet keeps its own settings, so add your provider and API key here once."
  }
}
