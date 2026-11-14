import SwiftUI

/// Original layout: Guide / Developer / About / Credits sections, plus the one
/// added control — the interface reload button — and the CPBitmap channel
/// setting that the new backend needs.
struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var showGuide = false
    @State private var showClear = false
    @State private var showRespringConfirm = false
    @State private var isRespringing = false

    private var entitledGroups: [String] { WQAccess.shared.entitledGroups }

    var body: some View {
        Form {
            Section(L("SETTINGS_SECTION_GUIDE")) {
                Button(L("SETTINGS_GUIDE")) { showGuide = true }
                Text(L("SETTINGS_GUIDE_SUBTITLE"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Button(L("SETTINGS_LOGOUT")) { showRespringConfirm = true }
                Text(L("SETTINGS_LOGOUT_SUBTITLE"))
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text(L("SETTINGS_SECTION_SESSION"))
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
                Text(L("SETTINGS_ABOUT_DETAIL"))
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("App Group", value: WQAccess.shared.appGroupIdentifier ?? "NONE")
                if entitledGroups.isEmpty {
                    Text(L("SETTINGS_APP_GROUP_NONE"))
                        .font(.caption).foregroundStyle(.orange)
                }
                Text(LF("SETTINGS_FOOTER", currentYear))
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Section(L("SETTINGS_SECTION_CREDITS")) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("SETTINGS_FILZASLOP_TITLE")).font(.body)
                    Text(L("SETTINGS_FILZASLOP_SUBTITLE"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(L("SETTINGS_CREDITS_FOOTER"))
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Section {
                Button(L("WALLPAPER_CLEAR_SAVED_DATA"), role: .destructive) { showClear = true }
            }
        }
        .navigationTitle(L("SETTINGS_TITLE"))
        .sheet(isPresented: $showGuide) { GuideView().environmentObject(settings) }
        .confirmationDialog(L("SETTINGS_LOGOUT_CONFIRM_TITLE"), isPresented: $showRespringConfirm) {
            Button(L("SETTINGS_LOGOUT"), role: .destructive) { isRespringing = true }
        } message: {
            Text(L("SETTINGS_LOGOUT_CONFIRM_MESSAGE"))
        }
        .confirmationDialog(L("WALLPAPER_CLEAR_CONFIRM_TITLE"), isPresented: $showClear) {
            Button(L("WALLPAPER_CLEAR"), role: .destructive) { settings.clearSavedData() }
        } message: {
            Text(L("WALLPAPER_CLEAR_CONFIRM_MESSAGE"))
        }
        .fullScreenCover(isPresented: $isRespringing) { NeoSpringOverlay() }
    }

    private var currentYear: String {
        String(Calendar.current.component(.year, from: Date()))
    }
}
