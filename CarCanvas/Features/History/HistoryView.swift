import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var history: HistoryStore
    @State private var exportEntry: HistoryEntry?
    @State private var banner: String?
    @State private var showRespringConfirm = false
    @State private var isRespringing = false

    var body: some View {
        List {
            Section { StatusBanner() }
            if history.entries.isEmpty {
                Text(L("HISTORY_EMPTY")).foregroundStyle(.secondary)
            } else {
                ForEach(history.entries) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.baseName).font(.headline)
                        Text(LF("HISTORY_ENTRY_DETAIL", entry.createdAt.formatted(), sourceLabel(entry.source)))
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            if entry.darkFileName != nil { Label(L("WALLPAPER_SET_DARK"), systemImage: "moon") }
                            if entry.lightFileName != nil { Label(L("WALLPAPER_SET_LIGHT"), systemImage: "sun.max") }
                        }.font(.caption)
                        // Apply and Share are separate rows: applying writes to
                        // the device, sharing only hands the file out.
                        Button(L("HISTORY_APPLY")) { exportEntry = entry }
                            .buttonStyle(.borderedProminent)

                        if let name = entry.darkFileName ?? entry.lightFileName {
                            ShareLink(item: history.url(for: name)) {
                                Label(L("HISTORY_SHARE"), systemImage: "square.and.arrow.up")
                            }
                            .font(.footnote)
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) { history.remove(entry.id) } label: {
                            Label(L("HISTORY_DELETE"), systemImage: "trash")
                        }
                    }
                }
            }
        }
        .navigationTitle(L("ROOT_WALLPAPERS"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L("SETTINGS_LOGOUT")) { showRespringConfirm = true }
            }
        }
        .confirmationDialog(L("SETTINGS_LOGOUT_CONFIRM_TITLE"), isPresented: $showRespringConfirm) {
            Button(L("SETTINGS_LOGOUT"), role: .destructive) { isRespringing = true }
        } message: {
            Text(L("SETTINGS_LOGOUT_CONFIRM_MESSAGE"))
        }
        .fullScreenCover(isPresented: $isRespringing) { NeoSpringOverlay() }
        .sheet(item: $exportEntry) { entry in
            ExportDestinationSheet(entry: entry) { summary in banner = summary }
        }
        .alert(L("COMMON_ERROR"), isPresented: Binding(get: { banner != nil }, set: { if !$0 { banner = nil } })) {
            Button(L("COMMON_OK")) { banner = nil }
        } message: { Text(banner ?? "") }
    }

    private func sourceLabel(_ source: HistoryEntry.Source) -> String {
        switch source {
        case .local: return L("HISTORY_SOURCE_LOCAL")
        case .carplay: return L("HISTORY_SOURCE_CARPLAY")
        case .applyExport: return L("HISTORY_SOURCE_APPLY_EXPORT")
        }
    }
}
