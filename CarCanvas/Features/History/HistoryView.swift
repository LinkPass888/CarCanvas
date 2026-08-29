import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var history: HistoryStore
    @State private var exportEntry: HistoryEntry?
    @State private var banner: String?

    var body: some View {
        List {
            Section { StatusBanner() }
            if history.entries.isEmpty {
                Text(L("HISTORY_EMPTY")).foregroundStyle(.secondary)
            } else {
                ForEach(history.entries) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.baseName).font(.headline)
                        Text("\(entry.createdAt.formatted()) · \(sourceLabel(entry.source))")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            if entry.darkFileName != nil { Label(L("WALLPAPER_SET_DARK"), systemImage: "moon") }
                            if entry.lightFileName != nil { Label(L("WALLPAPER_SET_LIGHT"), systemImage: "sun.max") }
                        }.font(.caption)
                        HStack {
                            Button(L("HISTORY_EXPORT_CARPLAY")) { exportEntry = entry }
                                .buttonStyle(.borderedProminent)
                            if let name = entry.darkFileName ?? entry.lightFileName {
                                ShareLink(item: history.url(for: name)) {
                                    Label(L("HISTORY_SHARE"), systemImage: "square.and.arrow.up")
                                }
                            }
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
        .navigationTitle(L("HISTORY_TITLE"))
        .toolbar {
            if !history.entries.isEmpty {
                Button(L("HISTORY_CLEAR_ALL")) { history.clearAll() }
            }
        }
        .sheet(item: $exportEntry) { entry in
            ExportDestinationSheet(entry: entry) { summary in banner = summary }
        }
        .alert(L("COMMON_ERROR"), isPresented: .constant(banner != nil)) {
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
