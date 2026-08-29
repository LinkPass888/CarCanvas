import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var showGuide = false
    @State private var showClear = false

    var body: some View {
        Form {
            Section { StatusBanner() }

            Section(L("SETTINGS_SECTION_GUIDE")) {
                Button(L("SETTINGS_GUIDE")) { showGuide = true }
                Text(L("SETTINGS_GUIDE_SUBTITLE")).font(.caption).foregroundStyle(.secondary)
            }

            Section("CPBitmap") {
                Picker("Channel order", selection: $settings.channelOrder) {
                    ForEach(CPBitmapTemplate.ChannelOrder.allCases) { order in
                        Text(order.label).tag(order)
                    }
                }
                Text("Public decoders disagree on BGRA vs RGBA. Use the built-in preview and verify on your device.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Require explicit confirmation before overwrite", isOn: $settings.requireExplicitConfirmation)
                    .font(.footnote)
            }

            Section(L("SETTINGS_SECTION_ABOUT")) {
                LabeledContent("Version", value: "2.0.0 (1)")
                LabeledContent("Bundle", value: Bundle.main.bundleIdentifier ?? "—")
                LabeledContent("App Group", value: WQAccess.shared.appGroupIdentifier)
                Text(L("SETTINGS_ABOUT_DETAIL")).font(.caption).foregroundStyle(.secondary)
            }

            Section(L("SETTINGS_SECTION_CREDITS")) {
                Link("forcequitOS / worse_query", destination: URL(string: "https://github.com/forcequitOS/worse_query")!)
                Link("0xjohnnydev / FilzaSlop", destination: URL(string: "https://github.com/0xjohnnydev/FilzaSlop")!)
                Link("Dcsyhi / CarCanvas", destination: URL(string: "https://github.com/Dcsyhi1998/CarCanvas")!)
                Text(L("SETTINGS_CREDITS_FOOTER")).font(.caption2).foregroundStyle(.secondary)
            }

            Section {
                Button(L("WALLPAPER_CLEAR_SAVED_DATA"), role: .destructive) { showClear = true }
            }
        }
        .navigationTitle(L("SETTINGS_TITLE"))
        .sheet(isPresented: $showGuide) { GuideView().environmentObject(settings) }
        .confirmationDialog(L("WALLPAPER_CLEAR_CONFIRM_TITLE"), isPresented: $showClear) {
            Button(L("WALLPAPER_CLEAR"), role: .destructive) { settings.clearSavedData() }
        } message: { Text(L("WALLPAPER_CLEAR_CONFIRM_MESSAGE")) }
    }
}
