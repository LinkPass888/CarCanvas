import SwiftUI
import Combine
import CoreGraphics
import UIKit

/// Only cache previews and original-backup restore, never a general file browser.
@MainActor
struct CarPlayBrowserView: View {
    @EnvironmentObject private var history: HistoryStore
    @StateObject private var store = CarPlayBrowserStore.shared
    @State private var restoringFileName: String?
    @State private var banner: String?
    @State private var bannerIsError = false

    var body: some View {
        List {
            Section(L("BROWSER_TITLE")) {
                if store.isLoading { ProgressView(L("BROWSER_LOADING")) }
                else if store.groups.isEmpty {
                    Text(L("BROWSER_WALLPAPER_CACHE_EMPTY")).foregroundStyle(.secondary)
                } else {
                    ForEach(store.groups) { group in
                        WallpaperGroupRow(group: group, thumbnails: store.thumbnails)
                    }
                }
            }
            Section(L("BROWSER_BACKUPS")) {
                if history.originalBackups.isEmpty {
                    Text(L("HISTORY_BACKUP_EMPTY")).foregroundStyle(.secondary)
                }
                ForEach(history.originalBackups) { backup in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(backup.cacheFileName).font(.headline)
                        Text(backup.createdAt.formatted()).font(.caption).foregroundStyle(.secondary)
                        Text(backupSourceLabel(backup)).font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Spacer()
                            Button { restoreOriginal(backup) } label: {
                                if restoringFileName == backup.cacheFileName {
                                    ProgressView().controlSize(.small)
                                } else { Text(L("WALLPAPER_RESTORE")) }
                            }
                            .buttonStyle(.bordered)
                            .disabled(restoringFileName != nil || history.backupFailures.contains(backup.cacheFileName))
                        }
                    }
                }
                if !history.backupFailures.isEmpty {
                    Text(LF("HISTORY_BACKUP_FAILED", history.backupFailures.joined(separator: ", ")))
                        .font(.caption).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(L("ROOT_CARPLAY_WALLPAPER"))
        .toolbar { Button(L("BROWSER_RETRY")) { Task { await store.load(forceRefresh: true) } } }
        .task { await store.load() }
        .refreshable { await store.load(forceRefresh: true) }
        .alert(store.error != nil || bannerIsError ? L("COMMON_ERROR") : L("COMMON_SUCCESS"),
               isPresented: Binding(get: { store.error != nil || banner != nil }, set: {
                if !$0 { store.error = nil; banner = nil }
               })) {
            Button(L("COMMON_OK")) { store.error = nil; banner = nil }
        } message: { Text(store.error ?? banner ?? "") }
    }

    private func restoreOriginal(_ backup: HistoryStore.OriginalBackup) {
        restoringFileName = backup.cacheFileName
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { try CacheWriter().restore(backup: backup) }.value
                banner = L("WALLPAPER_RESTORED")
                bannerIsError = false
            } catch {
                banner = error.localizedDescription
                bannerIsError = true
            }
            restoringFileName = nil
        }
    }

    private func backupSourceLabel(_ backup: HistoryStore.OriginalBackup) -> String {
        switch backup.source {
        case .firstScan: return L("HISTORY_BACKUP_FIRST_SCAN")
        case .legacy: return LF("HISTORY_BACKUP_LEGACY", backup.sourceFileName ?? backup.backupFileName)
        case .recovered: return L("HISTORY_BACKUP_RECOVERED")
        }
    }
}

/// Shared by the read-only list and the single-group replacement picker.
struct WallpaperGroupRow: View {
    let group: WallpaperGroup
    let thumbnails: [String: CGImage]
    var showsTitle = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsTitle { Text(group.displayName).font(.headline) }
            HStack(alignment: .top, spacing: 12) {
                ForEach(group.targets) { target in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(target.isDark ? L("WALLPAPER_PREVIEW_DARK") : L("WALLPAPER_PREVIEW_LIGHT"))
                            .font(.caption).foregroundStyle(.secondary)
                        Group {
                            if let image = thumbnails[target.path] {
                                Image(decorative: image, scale: 1).resizable().scaledToFit()
                            } else {
                                VStack(spacing: 4) {
                                    Image(systemName: "photo.badge.exclamationmark")
                                    Text(L("BROWSER_PREVIEW_FAILED")).font(.caption2)
                                }.foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity).frame(height: 80)
                        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                        Text(target.fileName).font(.caption2.monospaced()).lineLimit(3)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(target.byteCount), countStyle: .file))
                            .font(.caption2).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// One session cache for the browser and destination picker. Failed preview /
/// discovery results are cached too; only refresh/mutation retries them. Original
/// file bytes and full-size images never live in this store.
@MainActor
final class CarPlayBrowserStore: ObservableObject {
    static let shared = CarPlayBrowserStore()
    @Published private(set) var targets: [WallpaperTarget] = []
    @Published private(set) var thumbnails: [String: CGImage] = [:]
    @Published private(set) var cacheDirectory: String?
    @Published var error: String?
    @Published private(set) var isLoading = false
    var groups: [WallpaperGroup] { WallpaperGroup.make(from: targets) }

    private var hasLoadedOnce = false
    private var loadTask: Task<Void, Never>?
    private var generation = 0
    private var completedGeneration = 0
    private var minimumGeneration = 1
    private var revision = 0
    private var isRefreshing = false
    private var subscriptions: Set<AnyCancellable> = []

    private init() {
        NotificationCenter.default.publisher(for: .carCanvasCacheDidChange).receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                invalidate()
                Task { await self.load() }
            }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification).receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // Reload small images on next appearance, reusing the resolver
                // session result rather than doing another full discovery.
                self?.invalidate(keepTargets: true)
            }.store(in: &subscriptions)
    }

    private func invalidate(keepTargets: Bool = false) {
        revision += 1
        minimumGeneration = generation + 1
        hasLoadedOnce = false
        thumbnails = [:]
        error = nil
        if !keepTargets { targets = []; cacheDirectory = nil }
    }

    func load(forceRefresh: Bool = false) async {
        let requestedGeneration: Int
        if forceRefresh {
            requestedGeneration = max(minimumGeneration, generation + (loadTask != nil && isRefreshing ? 0 : 1))
        } else {
            guard !hasLoadedOnce else { return }
            requestedGeneration = max(minimumGeneration, max(1, generation))
        }
        while completedGeneration < requestedGeneration {
            if let current = loadTask { await current.value }
            else { await startLoad(forceRefresh: forceRefresh).value }
        }
    }

    private struct Snapshot {
        let resolved: ContainerResolver.Resolved
        let thumbnails: [String: CGImage]
    }

    private func startLoad(forceRefresh: Bool) -> Task<Void, Never> {
        generation += 1
        let currentGeneration = generation, currentRevision = revision
        let channelOrder = SettingsStore.shared.channelOrder
        isRefreshing = forceRefresh
        isLoading = true
        error = nil
        let task = Task { @MainActor in
            do {
                let snapshot = try await Task.detached(priority: .userInitiated) {
                    let resolved = try ContainerResolver().resolve(forceRefresh: forceRefresh)
                    let service = WallpaperService(channelOrder: channelOrder)
                    var images: [String: CGImage] = [:]
                    // A serial loop bounds peak memory to one decoded original.
                    for target in resolved.files {
                        autoreleasepool {
                            if let image = service.previewImage(for: target, resolved: resolved) { images[target.path] = image }
                        }
                    }
                    return Snapshot(resolved: resolved, thumbnails: images)
                }.value
                if currentRevision == revision {
                    targets = snapshot.resolved.files
                    thumbnails = snapshot.thumbnails
                    cacheDirectory = snapshot.resolved.cacheDirectory
                    hasLoadedOnce = true
                }
            } catch {
                if currentRevision == revision {
                    targets = []; thumbnails = [:]; cacheDirectory = nil
                    self.error = error.localizedDescription
                    hasLoadedOnce = true
                }
            }
            completedGeneration = currentGeneration
            isLoading = false
            isRefreshing = false
            loadTask = nil
        }
        loadTask = task
        return task
    }
}
