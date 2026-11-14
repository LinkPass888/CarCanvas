import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var history: HistoryStore
    @State private var banner: String?
    @State private var applyingEntry: HistoryEntry?
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
                            if entry.darkFileName != nil { Label(L("WALLPAPER_PREVIEW_DARK"), systemImage: "moon") }
                            if entry.lightFileName != nil { Label(L("WALLPAPER_PREVIEW_LIGHT"), systemImage: "sun.max") }
                        }.font(.caption)
                        HStack {
                            if let name = entry.darkFileName ?? entry.lightFileName {
                                ShareLink(item: history.url(for: name)) {
                                    Label(L("HISTORY_SHARE"), systemImage: "square.and.arrow.up")
                                }
                            }
                            Spacer()
                            Button(L("HISTORY_APPLY")) { applyingEntry = entry }
                                .buttonStyle(.borderedProminent)
                        }
                        .font(.footnote)
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
        .sheet(item: $applyingEntry) { entry in
            ExportDestinationSheet(entry: entry) { banner = $0 }
        }
        .confirmationDialog(L("SETTINGS_LOGOUT_CONFIRM_TITLE"), isPresented: $showRespringConfirm) {
            Button(L("SETTINGS_LOGOUT"), role: .destructive) { isRespringing = true }
        } message: { Text(L("SETTINGS_LOGOUT_CONFIRM_MESSAGE")) }
        .fullScreenCover(isPresented: $isRespringing) { NeoSpringOverlay() }
        .alert(L("COMMON_SUCCESS"), isPresented: Binding(get: { banner != nil }, set: { if !$0 { banner = nil } })) {
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
