import SwiftUI

/// Read-only view of the whitelisted CarPlayWallpaper cache.
///
/// Deliberately NOT a general file browser: no create / rename / delete /
/// import / share of container contents, and no editable path field.
struct CarPlayBrowserView: View {
    @State private var targets: [WallpaperTarget] = []
    @State private var error: String?
    @State private var isLoading = false

    var body: some View {
        List {
            Section { StatusBanner() }
            Section(L("BROWSER_TITLE")) {
                if isLoading { ProgressView(L("BROWSER_LOADING")) }
                else if targets.isEmpty {
                    Text(L("BROWSER_WALLPAPER_CACHE_EMPTY"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(targets) { target in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(target.fileName).font(.footnote.monospaced())
                            Text("\(appearanceLabel(target.appearance)) · \(target.byteCount) bytes")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                Text(L("ROOT_CARPLAY_WALLPAPER_SUBTITLE"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(L("ROOT_CARPLAY_WALLPAPER"))
        .toolbar { Button(L("BROWSER_RETRY")) { load() } }
        .task { load() }
        .refreshable { await loadAsync() }
        .alert(L("COMMON_ERROR"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(L("COMMON_OK")) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func load() {
        isLoading = true
        Task.detached(priority: .userInitiated) {
            let outcome: (files: [WallpaperTarget], message: String?) = await loadAsync()
            await MainActor.run {
                targets = outcome.files
                error = outcome.message
                isLoading = false
            }
        }
    }

    private func loadAsync() async -> ([WallpaperTarget], String?) {
        do {
            let files = try await Task.detached(priority: .userInitiated) {
                try ContainerResolver().resolve().files
            }.value
            return (files, nil)
        } catch {
            return ([], error.localizedDescription)
        }
    }

    private func appearanceLabel(_ a: WallpaperTarget.Appearance) -> String {
        switch a {
        case .dark: return L("WALLPAPER_SET_DARK")
        case .light: return L("WALLPAPER_SET_LIGHT")
        case .unknown: return "—"
        }
    }
}
