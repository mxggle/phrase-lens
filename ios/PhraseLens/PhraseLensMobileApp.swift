import SwiftUI

@main
struct PhraseLensMobileApp: App {
  @StateObject private var store = MobileSettingsStore()
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      MobileRootView()
        .environmentObject(store)
        .mobilePalette()
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { store.reload() }
    }
  }
}

struct MobileRootView: View {
  @EnvironmentObject private var store: MobileSettingsStore

  var body: some View {
    TabView {
      LookupScreen(store: store)
        .tabItem { Label(L10n.isChinese ? "查词" : "Look Up", systemImage: "character.magnify") }
      ActionsScreen()
        .tabItem { Label(L10n.isChinese ? "动作" : "Actions", systemImage: "sparkles") }
      SettingsScreen()
        .tabItem { Label(L10n.isChinese ? "设置" : "Settings", systemImage: "gearshape") }
    }
  }
}
