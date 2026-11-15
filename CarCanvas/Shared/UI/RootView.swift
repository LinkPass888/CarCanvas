import SwiftUI

/// Cache management and settings; photo replacement starts on the cache itself.
struct RootView: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var showGuide = false

    var body: some View {
        TabView {
            NavigationStack { CarPlayBrowserView() }
                .tabItem { Label(L("ROOT_CARPLAY"), systemImage: "car.fill") }

            NavigationStack { SettingsView() }
                .tabItem { Label(L("ROOT_SETTINGS"), systemImage: "gearshape") }
        }
        .sheet(isPresented: $showGuide) {
            GuideView()
                .environmentObject(settings)
        }
        .onAppear {
            guard !settings.hasSeenGuide else { return }
            settings.hasSeenGuide = true
            showGuide = true
        }
    }
}
