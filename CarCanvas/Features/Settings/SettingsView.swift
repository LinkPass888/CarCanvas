import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var showGuide = false
    @State private var showClear = false
    @State private var showLogoutConfirm = false
    @State private var sessionMessage: String?

    private var entitledGroups: [String] { WQAccess.shared.entitledGroups }

    var body: some View {
        Form {
            Section { StatusBanner() }

            Section(L("SETTINGS_SECTION_GUIDE")) {
                Button(L("SETTINGS_GUIDE")) { showGuide = true }
                Text(L("SETTINGS_GUIDE_SUBTITLE")).font(.caption).foregroundStyle(.secondary)
            }

            Section(L("SETTINGS_SECTION_SESSION")) {
                Button(L("SETTINGS_LOGOUT")) { showLogoutConfirm = true }
                Text(L("SETTINGS_LOGOUT_SUBTITLE")).font(.caption).foregroundStyle(.secondary)
            }

            Section(L("SETTINGS_SECTION_CPBITMAP")) {
                Picker(L("SETTINGS_CHANNEL_ORDER"), selection: $settings.channelOrder) {
                    ForEach(CPBitmapTemplate.ChannelOrder.allCases) { order in
                        Text(order.label).tag(order)
                    }
                }
                Text(L("SETTINGS_CHANNEL_ORDER_FOOTER"))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(L("SETTINGS_REQUIRE_CONFIRM"), isOn: $settings.requireExplicitConfirmation)
                    .font(.footnote)
            }

            Section(L("SETTINGS_SECTION_ABOUT")) {
                LabeledContent("Version", value: "2.0.0 (1)")
                LabeledContent("Bundle", value: Bundle.main.bundleIdentifier ?? "-")
                LabeledContent("App Group", value: WQAccess.shared.appGroupIdentifier ?? "NONE")
                if entitledGroups.isEmpty {
                    Text(L("SETTINGS_APP_GROUP_NONE"))
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            Section(L("SETTINGS_SECTION_CREDITS")) {
                Link("forcequitOS / worse_query", destination: URL(string: "https://github.com/forcequitOS/worse_query")!)
                Link("Dcsyhi / CarCanvas", destination: URL(string: "https://github.com/Dcsyhi1998/CarCanvas")!)
                Text(L("SETTINGS_CREDITS_FOOTER")).font(.caption2).foregroundStyle(.secondary)
            }

            Section {
                Button(L("WALLPAPER_CLEAR_SAVED_DATA"), role: .destructive) { showClear = true }
            }
        }
        .navigationTitle(L("SETTINGS_TITLE"))
        .sheet(isPresented: $showGuide) { GuideView().environmentObject(settings) }
        .confirmationDialog(L("SETTINGS_LOGOUT_CONFIRM_TITLE"), isPresented: $showLogoutConfirm) {
            Button(L("SETTINGS_LOGOUT"), role: .destructive) { performLogout() }
        } message: { Text(L("SETTINGS_LOGOUT_CONFIRM_MESSAGE")) }
        .confirmationDialog(L("WALLPAPER_CLEAR_CONFIRM_TITLE"), isPresented: $showClear) {
            Button(L("WALLPAPER_CLEAR"), role: .destructive) { settings.clearSavedData() }
        } message: { Text(L("WALLPAPER_CLEAR_CONFIRM_MESSAGE")) }
        .alert(L("SETTINGS_SECTION_SESSION"), isPresented: Binding(
            get: { sessionMessage != nil },
            set: { if !$0 { sessionMessage = nil } }
        )) {
            Button(L("COMMON_OK")) { sessionMessage = nil }
        } message: { Text(sessionMessage ?? "") }
    }

    private func performLogout() {
        var detail: NSString?
        let result = CCLogoutRequest(&detail)
        switch result {
        case .requested:  sessionMessage = L("SETTINGS_LOGOUT_OK")
        case .denied:     sessionMessage = L("SETTINGS_LOGOUT_DENIED")
        default:          sessionMessage = L("SETTINGS_LOGOUT_UNAVAILABLE")
        }
        CCLog.info("logout result=\(result.rawValue) detail=\(detail ?? "none")")
    }
}
