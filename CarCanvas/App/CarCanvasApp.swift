import SwiftUI

@main
struct CarCanvasApp: App {
    @StateObject private var settings = SettingsStore.shared
    @StateObject private var history = HistoryStore.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(history)
        }
    }
}
