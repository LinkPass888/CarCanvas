import SwiftUI

/// Select exactly one existing same-name group; there is no default selection
/// and no mode/all-target toggle. The backend revalidates this exact membership.
struct ExportDestinationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = CarPlayBrowserStore.shared
    let entry: HistoryEntry
    let onFinish: (String) -> Void

    @State private var selectedGroupID: WallpaperGroup.ID?
    @State private var confirmed = false
    @State private var isWorking = false
    @State private var error: String?

    private var selectedGroup: WallpaperGroup? {
        store.groups.first { $0.id == selectedGroupID && $0.isReplaceable }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L("HISTORY_EXPORT_CARPLAY_PICK_TITLE")) {
                    Text(L("HISTORY_EXPORT_CARPLAY_PICK_MESSAGE"))
                        .font(.caption).foregroundStyle(.secondary)
                    if store.isLoading { ProgressView(L("BROWSER_LOADING")) }
                    else if store.groups.isEmpty { Text(L("BROWSER_WALLPAPER_CACHE_EMPTY")).foregroundStyle(.secondary) }
                    ForEach(store.groups) { group in
                        Button {
                            selectedGroupID = group.id
                            confirmed = false
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(group.displayName).font(.headline)
                                    Spacer()
                                    Image(systemName: selectedGroupID == group.id ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selectedGroupID == group.id ? Color.accentColor : .secondary)
                                }
                                WallpaperGroupRow(group: group, thumbnails: store.thumbnails, showsTitle: false)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(!group.isReplaceable || isWorking || store.isLoading)
                        .accessibilityAddTraits(selectedGroupID == group.id ? .isSelected : [])
                    }
                }
                Section {
                    Toggle(L("EXPORT_CONFIRM_TOGGLE"), isOn: $confirmed)
                        .font(.footnote).disabled(selectedGroup == nil || isWorking)
                    Button(L("HISTORY_EXPORT_CARPLAY_WRITE")) { perform() }
                        .disabled(!confirmed || selectedGroup == nil || isWorking || store.isLoading)
                    if isWorking { ProgressView(L("COMMON_PLEASE_WAIT")) }
                }
            }
            .navigationTitle(L("HISTORY_EXPORT_CARPLAY"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("COMMON_CANCEL")) { dismiss() }.disabled(isWorking)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("BROWSER_RETRY")) {
                        confirmed = false
                        Task { await store.load(forceRefresh: true) }
                    }.disabled(isWorking || store.isLoading)
                }
            }
            .interactiveDismissDisabled(isWorking)
            .task { await store.load() }
            .onChange(of: store.groups) { _, _ in
                if selectedGroup == nil { selectedGroupID = nil; confirmed = false }
            }
            .alert(L("COMMON_ERROR"), isPresented: Binding(get: { error != nil || store.error != nil }, set: {
                if !$0 { error = nil; store.error = nil }
            })) {
                Button(L("COMMON_OK")) { error = nil; store.error = nil }
            } message: { Text(error ?? store.error ?? "") }
        }
    }

    private func perform() {
        guard confirmed, let group = selectedGroup, !isWorking else { return }
        let selectedEntry = entry
        isWorking = true
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try CacheWriter().overwrite(entry: selectedEntry, group: group)
                }.value
                onFinish(LF("HISTORY_EXPORT_CARPLAY_DONE", result.succeeded, result.failed))
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            isWorking = false
        }
    }
}
