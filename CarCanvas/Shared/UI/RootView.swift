import SwiftUI

/// Cache management and settings; photo replacement starts on the cache itself.
struct RootView: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        TabView {
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
