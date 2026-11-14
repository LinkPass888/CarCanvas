import SwiftUI

@main
struct CarCanvasApp: App {
    @StateObject private var settings = SettingsStore.shared
    @StateObject private var history = HistoryStore.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        CCLog.startSession()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(history)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                CCLog.event("scene active")
            case .inactive:
                CCLog.event("scene inactive")
            case .background:
                CCLog.event("scene background -> clearing session log")
                CCLog.clear()
            @unknown default:
                break
            }
        }
    }
}
