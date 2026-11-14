import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var history: HistoryStore
    @State private var banner: String?
    @State private var applyingID: HistoryEntry.ID?
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
                        // One row: Share on the left, Apply on the right.
                        HStack {
                            if let name = entry.darkFileName ?? entry.lightFileName {
                                ShareLink(item: history.url(for: name)) {
                                    Label(L("HISTORY_SHARE"), systemImage: "square.and.arrow.up")
                                }
                            }
                            Spacer()
                            Button {
                                apply(entry)
                            } label: {
                                if applyingID == entry.id {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Text(L("HISTORY_APPLY"))
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(applyingID != nil)
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
        .confirmationDialog(L("SETTINGS_LOGOUT_CONFIRM_TITLE"), isPresented: $showRespringConfirm) {
            Button(L("SETTINGS_LOGOUT"), role: .destructive) { isRespringing = true }
        } message: {
            Text(L("SETTINGS_LOGOUT_CONFIRM_MESSAGE"))
        }
        .fullScreenCover(isPresented: $isRespringing) { NeoSpringOverlay() }
        .alert(L("COMMON_ERROR"), isPresented: Binding(get: { banner != nil }, set: { if !$0 { banner = nil } })) {
            Button(L("COMMON_OK")) { banner = nil }
        } message: { Text(banner ?? "") }
    }

    /// Writes this entry over the matching cache files. Both appearances were
    /// already chosen when the CPBitmap was created, so this asks nothing.
    /// Runs off the main actor so the button can show progress while the
    /// container is resolved and the cache is rewritten.
    private func apply(_ entry: HistoryEntry) {
        applyingID = entry.id
        Task {
            var outcome: String
            do {
                outcome = try await Task.detached(priority: .userInitiated) {
                    let targets = try ContainerResolver().resolve().files
                    let result = try CacheWriter().overwrite(entry: entry,
                                                            targets: targets,
                                                            dark: entry.darkFileName != nil,
                                                            light: entry.lightFileName != nil)
                    return LF("HISTORY_EXPORT_CARPLAY_DONE", result.succeeded, result.failed)
                }.value
            } catch let caught {
                outcome = caught.localizedDescription
            }
            await MainActor.run {
                banner = outcome
                applyingID = nil
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
