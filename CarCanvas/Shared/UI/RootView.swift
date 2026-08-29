import SwiftUI

struct RootView: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        TabView {
            NavigationStack { WallpaperView() }
                .tabItem { Label(L("ROOT_WALLPAPER"), systemImage: "photo") }

            NavigationStack { HistoryView() }
                .tabItem { Label(L("ROOT_HISTORY"), systemImage: "clock") }

            NavigationStack { CarPlayBrowserView() }
                .tabItem { Label(L("ROOT_CARPLAY_WALLPAPER"), systemImage: "folder") }

            NavigationStack { SettingsView() }
                .tabItem { Label(L("ROOT_SETTINGS"), systemImage: "gearshape") }
        }
        .sheet(isPresented: Binding(
            get: { !settings.hasSeenGuide },
            set: { if !$0 { settings.hasSeenGuide = true } }
        )) {
            GuideView()
                .environmentObject(settings)
        }
    }
}
