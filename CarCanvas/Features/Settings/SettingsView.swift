import SwiftUI

@MainActor
struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @StateObject private var edits = CacheEditStore.shared
    @State private var showGuide = false
    @State private var showClear = false
    @State private var showLogViewer = false
    @State private var isClearing = false
    @State private var message: String?
    @State private var messageIsError = false

    private var entitledGroups: [String] { WQAccess.shared.entitledGroups }

    var body: some View {
        Form {

            Section(L("SETTINGS_SECTION_GUIDE")) {
                Button(L("SETTINGS_GUIDE")) { showGuide = true }
                Text(L("SETTINGS_GUIDE_SUBTITLE")).font(.caption).foregroundStyle(.secondary)
            }

            Section(L("SETTINGS_SECTION_CPBITMAP")) {
                Picker(L("SETTINGS_CHANNEL_ORDER"), selection: $settings.channelOrder) {
                    ForEach(CPBitmapTemplate.ChannelOrder.allCases) { order in
                        Text(order.label).tag(order)
                    }
                }
                Text(L("SETTINGS_CHANNEL_ORDER_FOOTER"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(L("SETTINGS_SECTION_ABOUT")) {
                LabeledContent("Version", value: "2.0.2 (4)")
                LabeledContent("Bundle", value: Bundle.main.bundleIdentifier ?? "-")
                LabeledContent("App Group", value: WQAccess.shared.appGroupIdentifier ?? "NONE")
                if entitledGroups.isEmpty {
                    Text(L("SETTINGS_APP_GROUP_NONE"))
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            Section(L("SETTINGS_SECTION_DEVELOPER")) {
                Link(L("SETTINGS_CHANNEL_TELEGRAM"),
                     destination: URL(string: "https://t.me/linkpass666")!)
                Text(L("SETTINGS_CHANNEL_TELEGRAM_SUBTITLE"))
                    .font(.caption).foregroundStyle(.secondary)
                Link(L("SETTINGS_DONATE"),
                     destination: URL(string: "https://afdian.com/a/linkpass")!)
                Text(L("SETTINGS_DONATE_SUBTITLE"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(L("SETTINGS_SECTION_CREDITS")) {
                Link("forcequitOS / worse_query", destination: URL(string: "https://github.com/forcequitOS/worse_query")!)
                Link("Dcsyhi / CarCanvas", destination: URL(string: "https://github.com/Dcsyhi1998/CarCanvas")!)
                Text(L("SETTINGS_CREDITS_FOOTER")).font(.caption2).foregroundStyle(.secondary)
            }

            Section {
                Button(L("WALLPAPER_CLEAR_SAVED_DATA"), role: .destructive) { showClear = true }
                    .disabled(isClearing || edits.isWorking)
                Text(L("SETTINGS_CACHE_CLEAR_FOOTER"))
                    .font(.caption).foregroundStyle(.secondary)
                if isClearing { ProgressView(L("COMMON_PLEASE_WAIT")) }
            }
            Section {
                Button(L("SETTINGS_LOG_VIEW")) { showLogViewer = true }
                Text(L("SETTINGS_LOG_FOOTER"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(L("SETTINGS_TITLE"))
        .sheet(isPresented: $showGuide) { GuideView().environmentObject(settings) }
        .confirmationDialog(L("WALLPAPER_CLEAR_CONFIRM_TITLE"), isPresented: $showClear) {
            Button(L("WALLPAPER_CLEAR"), role: .destructive) { clearCache() }
        } message: { Text(L("WALLPAPER_CLEAR_CONFIRM_MESSAGE")) }
        .alert(messageIsError ? L("COMMON_ERROR") : L("COMMON_SUCCESS"),
               isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button(L("COMMON_OK")) { message = nil }
        } message: { Text(message ?? "") }
        .sheet(isPresented: $showLogViewer) {
            LogViewerView()
        }
    }

    private func clearCache() {
        guard !isClearing && !edits.isWorking else { return }
        isClearing = true
        Task {
            do {
                let count = try await edits.clearCacheAndBackups()
                message = LF("CACHE_CLEAR_DONE", count)
                messageIsError = false
            } catch {
                message = error.localizedDescription
                messageIsError = true
            }
            isClearing = false
        }
    }
}
