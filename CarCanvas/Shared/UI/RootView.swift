import SwiftUI

/// Tab order (second revision):
///   1. Wallpaper list (was "History")
///   2. New wallpaper (was "Wallpaper")
///   3. CarPlay
///   4. Settings
struct RootView: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        TabView {
            NavigationStack { HistoryView() }
                .tabItem { Label(L("ROOT_WALLPAPERS"), systemImage: "photo.stack") }

            NavigationStack { WallpaperView() }
                .tabItem { Label(L("ROOT_NEW_WALLPAPER"), systemImage: "plus.circle") }

            NavigationStack { CarPlayBrowserView() }
                .tabItem { Label(L("ROOT_CARPLAY"), systemImage: "car.fill") }

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
