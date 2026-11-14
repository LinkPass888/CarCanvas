import SwiftUI

/// Original layout: a list of saved CPBitmap entries with the source label,
/// Dark/Light badges, share / export / delete actions, and a Clear All toolbar
/// button.
struct HistoryView: View {
    @EnvironmentObject private var history: HistoryStore
    @State private var exportEntry: HistoryEntry?
    @State private var banner: String?
    @State private var showClearConfirm = false

    var body: some View {
        List {
            if history.entries.isEmpty {
                Text(L("HISTORY_EMPTY")).foregroundStyle(.secondary)
            } else {
                ForEach(history.entries) { entry in
                    entryRow(entry)
                }
            }
        }
        .navigationTitle(L("HISTORY_TITLE"))
        .toolbar {
            if !history.entries.isEmpty {
                Button(L("HISTORY_CLEAR_ALL")) { showClearConfirm = true }
            }
        }
        .confirmationDialog(L("HISTORY_CLEAR_TITLE"), isPresented: $showClearConfirm) {
            Button(L("HISTORY_CLEAR_ALL"), role: .destructive) { history.clearAll() }
        } message: {
            Text(L("HISTORY_CLEAR_MESSAGE"))
        }
        .sheet(item: $exportEntry) { entry in
            ExportDestinationSheet(entry: entry) { summary in banner = summary }
        }
        .alert(L("COMMON_ERROR"), isPresented: Binding(
            get: { banner != nil }, set: { if !$0 { banner = nil } })) {
            Button(L("COMMON_OK")) { banner = nil }
        } message: { Text(banner ?? "") }
    }

    private func entryRow(_ entry: HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.baseName).font(.headline)
            Text(LF("HISTORY_ENTRY_DETAIL",
                    entry.createdAt.formatted(),
                    sourceLabel(entry.source)))
                .font(.caption).foregroundStyle(.secondary)

            HStack(spacing: 12) {
                if entry.darkFileName != nil {
                    Label(L("WALLPAPER_SET_DARK"), systemImage: "moon")
                }
                if entry.lightFileName != nil {
                    Label(L("WALLPAPER_SET_LIGHT"), systemImage: "sun.max")
                }
            }
            .font(.caption)

            HStack {
                Button(L("HISTORY_EXPORT_CARPLAY")) { exportEntry = entry }
                    .buttonStyle(.borderedProminent)
                if let name = entry.darkFileName ?? entry.lightFileName {
                    ShareLink(item: history.url(for: name)) {
                        Label(L("HISTORY_SHARE"), systemImage: "square.and.arrow.up")
                    }
                }
                Button(L("HISTORY_EXPORT_FOLDER")) { exportEntry = entry }
            }
            .font(.footnote)
        }
        .swipeActions {
            Button(role: .destructive) { history.remove(entry.id) } label: {
                Label(L("HISTORY_DELETE"), systemImage: "trash")
            }
        }
    }

    private func sourceLabel(_ source: HistoryEntry.Source) -> String {
        switch source {
        case .local: return L("HISTORY_SOURCE_LOCAL")
        case .carplay: return L("HISTORY_SOURCE_CARPLAY")
        case .applyExport: return L("HISTORY_SOURCE_APPLY_EXPORT")
        }
    }
}
