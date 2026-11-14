import SwiftUI

/// Read-only view of the whitelisted CarPlayWallpaper cache.
///
/// Deliberately NOT a general file browser: no create / rename / delete /
/// import / share of container contents, and no editable path field.
@MainActor
struct CarPlayBrowserView: View {
    @StateObject private var store = CarPlayBrowserStore.shared

    var body: some View {
        List {
            Section(L("BROWSER_TITLE")) {
                if store.isLoading { ProgressView(L("BROWSER_LOADING")) }
                else if store.targets.isEmpty {
                    Text(L("BROWSER_WALLPAPER_CACHE_EMPTY"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.targets) { target in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(target.fileName).font(.footnote.monospaced())
                            Text(LF("BROWSER_ITEM_DETAIL", appearanceLabel(target.appearance), String(target.byteCount)))
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
        .toolbar { Button(L("BROWSER_RETRY")) { Task { await store.load(forceRefresh: true) } } }
        .task { await store.load() }
        .refreshable { await store.load(forceRefresh: true) }
        .alert(L("COMMON_ERROR"), isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button(L("COMMON_OK")) { store.error = nil }
        } message: { Text(store.error ?? "") }
    }

    private func appearanceLabel(_ a: WallpaperTarget.Appearance) -> String {
        switch a {
        case .dark: return L("WALLPAPER_SET_DARK")
        case .light: return L("WALLPAPER_SET_LIGHT")
        case .unknown: return "—"
        }
    }
}

/// The session owns this state, not a TabView child that SwiftUI can recreate.
/// A failed load is also a completed load; only an explicit refresh retries it.
@MainActor
private final class CarPlayBrowserStore: ObservableObject {
    static let shared = CarPlayBrowserStore()
    private init() {}

    @Published private(set) var targets: [WallpaperTarget] = []
    @Published var error: String?
    @Published private(set) var isLoading = false

    private var hasLoadedOnce = false
    private var loadTask: Task<Void, Never>?
    private var generation = 0
    private var completedGeneration = 0
    private var isRefreshing = false

    func load(forceRefresh: Bool = false) async {
        let requestedGeneration: Int
        if forceRefresh {
            // Join an existing explicit refresh, but do not let an automatic
            // load satisfy a refresh requested while that load is in flight.
            requestedGeneration = generation + (loadTask != nil && isRefreshing ? 0 : 1)
        } else {
            guard !hasLoadedOnce else { return }
            requestedGeneration = max(1, generation)
        }

        while completedGeneration < requestedGeneration {
            if let current = loadTask {
                await current.value
            } else {
                let current = startLoad(forceRefresh: forceRefresh)
                await current.value
            }
        }
    }

    private func startLoad(forceRefresh: Bool) -> Task<Void, Never> {
        generation += 1
        let currentGeneration = generation
        isRefreshing = forceRefresh
        isLoading = true
        error = nil

        // The shared store owns the task, so disappearance of a tab does not
        // cancel the lookup or discard its result.
        let task = Task { @MainActor in
            do {
                targets = try await Task.detached(priority: .userInitiated) {
                    try ContainerResolver().resolve(forceRefresh: forceRefresh).files
                }.value
            } catch {
                targets = []
                self.error = error.localizedDescription
            }
            hasLoadedOnce = true
            completedGeneration = currentGeneration
            isLoading = false
            isRefreshing = false
            loadTask = nil
        }
        loadTask = task
        return task
    }
}
