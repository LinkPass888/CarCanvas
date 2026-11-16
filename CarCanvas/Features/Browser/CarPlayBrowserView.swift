import SwiftUI
import Combine
import CoreGraphics
import PhotosUI
import UIKit

/// Cache photos are edited in place, but remain app-local until Apply.
@MainActor
struct CarPlayBrowserView: View {
    @EnvironmentObject private var history: HistoryStore
    @EnvironmentObject private var settings: SettingsStore
    @StateObject private var store = CarPlayBrowserStore.shared
    @StateObject private var edits = CacheEditStore.shared
    @State private var pickedItem: PhotosPickerItem?
    @State private var pickedTarget: WallpaperTarget?
    @State private var showPhotoPicker = false
    @State private var isPreparingCrop = false
    @State private var preparedCrop: PhotoCropRequest?
    @State private var cropSelection: PhotoCropRequest?
    @State private var showRestoreAllConfirm = false
    @State private var isRespringing = false
    @State private var error: String?
    @State private var selectedDeviceID: String?

    private var selectedDevice: CarPlayDeviceProbe.Device? {
        store.devices.first(where: { $0.id == selectedDeviceID }) ?? store.devices.first
    }

    /// Vehicle records can fail to load while the cache scan succeeds: the
    /// preference file is not a container path, so no extension is issued for
    /// it. Filtering by an empty device list would then hide every cache the
    /// scan just found, so an unknown owner shows all of them instead.
    private var currentFileNames: Set<String> {
        guard let selectedDevice else {
            return Set(store.targets.map(\.fileName)).union(edits.pending.map { $0.target.fileName })
        }
        let otherNames = Set(store.devices.filter { $0.id != selectedDevice.id }.flatMap { $0.cacheFileNames })
        return selectedDevice.cacheFileNames.subtracting(otherNames)
    }

    private var hasSharedCache: Bool {
        guard let selectedDevice else { return false }
        return currentFileNames.count != selectedDevice.cacheFileNames.count
    }

    private var currentPending: [CacheEditStore.PendingEdit] {
        edits.pending.filter { currentFileNames.contains($0.target.fileName) }
    }

    private var currentBackups: [HistoryStore.OriginalBackup] {
        history.originalBackups.filter { currentFileNames.contains($0.cacheFileName) }
    }

    private var currentBackupFailures: [String] {
        history.backupFailures.filter { currentFileNames.contains($0) }
    }

    // Include a staged restore whose exact backed-up filename is absent.
    private var displayedTargets: [WallpaperTarget] {
        var targets = store.targets
        let known = Set(targets.map(\.path))
        for edit in edits.pending where !known.contains(edit.target.path) { targets.append(edit.target) }
        return targets.filter { currentFileNames.contains($0.fileName) }.sorted { $0.path < $1.path }
    }

    var body: some View {
        List {
            Section { StatusBanner() }
            Section {
                HStack(alignment: .center, spacing: 12) {
                    Menu {
                        Picker(L("VEHICLE_MENU"), selection: Binding(
                            get: { selectedDevice?.id ?? "" }, set: { selectedDeviceID = $0 })) {
                            ForEach(store.devices) { device in
                                Text(device.name).tag(device.id)
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(selectedDevice?.name ?? L("VEHICLE_MENU")).lineLimit(1)
                            Image(systemName: "chevron.down").font(.caption)
                        }.font(.body).frame(height: 28)
                    }
                    .disabled(store.devices.count <= 1 || edits.isWorking || store.isLoading || isPreparingCrop
                              || showPhotoPicker || preparedCrop != nil || cropSelection != nil)
                    Spacer(minLength: 8)
                    Button { Task { await store.load(forceRefresh: true) } } label: {
                        Text(L("BROWSER_RETRY")).font(.body).frame(height: 28)
                    }
                    .disabled(edits.isWorking || store.isLoading || !edits.isReady || isPreparingCrop
                              || showPhotoPicker || preparedCrop != nil || cropSelection != nil)
                }.buttonStyle(.bordered).controlSize(.regular)
            }
            Section {
                if store.isLoading || (!edits.isReady && edits.loadError == nil) { ProgressView(L("BROWSER_LOADING")) }
                if let loadError = edits.loadError { Text(loadError).font(.caption).foregroundStyle(.red) }
                if !store.isLoading {
                    if let deviceError = store.deviceError {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("VEHICLE_RECORDS_UNAVAILABLE") + " " + deviceError)
                            Text(L("VEHICLE_UNKNOWN_OWNER"))
                        }.font(.caption).foregroundStyle(.red)
                    } else if store.devices.isEmpty {
                        Text(L("VEHICLE_RECORDS_EMPTY")).foregroundStyle(.secondary)
                    } else if hasSharedCache {
                        Text(L("VEHICLE_SHARED_CACHE")).font(.caption).foregroundStyle(.secondary)
                    } else if displayedTargets.isEmpty {
                        Text(L("VEHICLE_NO_CACHE_MATCH")).foregroundStyle(.secondary)
                    }
                }
                ForEach(displayedTargets) { target in
                    CacheTargetRow(target: target, image: preview(for: target), pixelSize: pixelSize(for: target), status: status(for: target),
                                   canPick: canPick(target), canRestore: canRestore(target),
                                   canClear: hasPending(target) && edits.isReady && !edits.isWorking,
                                   onPick: { pick(target) }, onRestore: { restore(target) },
                                   onClear: { clear(target) })
                }
                if !store.isLoading && !store.targets.isEmpty && displayedTargets.count < store.targets.count {
                    Text(L("VEHICLE_CACHE_SCOPE_HINT")).font(.caption).foregroundStyle(.secondary)
                }
                if edits.isWorking { ProgressView(L("COMMON_PLEASE_WAIT")) }
            } header: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("BROWSER_TITLE"))
                    Text(L("CACHE_EDIT_PICK_HINT"))
                        .font(.caption).foregroundStyle(.secondary).textCase(nil)
                }
            }
            Section {
                if currentBackups.isEmpty {
                    Text(L("HISTORY_BACKUP_EMPTY")).foregroundStyle(.secondary)
                }
                ForEach(currentBackups) { backup in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(backup.cacheFileName).font(.caption2.monospaced())
                        HStack {
                            Text(backup.createdAt.formatted())
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: Int64(backup.byteCount), countStyle: .file))
                        }.font(.caption).foregroundStyle(.secondary)
                        Text(backupSourceLabel(backup)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !currentBackupFailures.isEmpty {
                    Text(LF("HISTORY_BACKUP_FAILED", currentBackupFailures.joined(separator: ", ")))
                        .font(.caption).foregroundStyle(.red)
                }
            } header: {
                HStack {
                    Text(L("BROWSER_BACKUPS"))
                    Spacer()
                    Button(L("WALLPAPER_RESTORE")) { showRestoreAllConfirm = true }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(currentBackups.isEmpty || !currentBackupFailures.isEmpty
                                  || edits.isWorking || !edits.isReady || store.isLoading || store.cacheDirectory == nil)
                }.textCase(nil)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !currentPending.isEmpty {
                    Button { apply() } label: {
                        Text(L("HISTORY_APPLY"))
                            .padding(.trailing, 6)
                            .overlay(alignment: .topTrailing) {
                                Text("\(currentPending.count)").font(.caption2.monospacedDigit())
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(Color.accentColor, in: Capsule()).foregroundStyle(.white)
                                    .offset(x: 10, y: -10)
                                    .allowsHitTesting(false)
                            }
                    }
                    .accessibilityLabel(LF("CACHE_APPLY_COUNT", currentPending.count))
                    .disabled(edits.isWorking || store.isLoading || !edits.isReady || isPreparingCrop || preparedCrop != nil || cropSelection != nil)
                }
            }
        }
        .task { await store.load() }
        .refreshable { if !edits.isWorking { await store.load(forceRefresh: true) } }
        .photosPicker(isPresented: $showPhotoPicker, selection: $pickedItem, matching: .images)
        .onChange(of: pickedItem) { _, item in
            guard let item, let target = pickedTarget else { return }
            prepareCrop(item: item, target: target, channelOrder: settings.channelOrder)
        }
        .onChange(of: showPhotoPicker) { _, presented in
            if !presented { Task { await Task.yield(); presentPreparedCrop() } }
        }
        .sheet(item: $cropSelection) { request in
            PhotoCropView(image: request.preview, targetPixelSize: request.pixelSize) { center, size in
                try await edits.stagePhoto(for: request.target, channelOrder: request.channelOrder,
                                           cropCenter: center, expectedPixelSize: request.pixelSize,
                                           outputPixelSize: size) { request.data }
            }
        }
        .confirmationDialog(L("CACHE_RESTORE_ALL_TITLE"), isPresented: $showRestoreAllConfirm) {
            Button(L("WALLPAPER_RESTORE")) { restoreAll() }
        } message: { Text(L("CACHE_RESTORE_ALL_MESSAGE")) }
        .fullScreenCover(isPresented: $isRespringing) { NeoSpringOverlay() }
        .alert(L("COMMON_ERROR"), isPresented: Binding(get: { error != nil || store.error != nil }, set: {
            if !$0 { error = nil; store.error = nil }
        })) {
            Button(L("COMMON_OK")) { error = nil; store.error = nil }
        } message: { Text(error ?? store.error ?? "") }
    }

    private func prepareCrop(item: PhotosPickerItem, target: WallpaperTarget,
                             channelOrder: CPBitmapTemplate.ChannelOrder) {
        guard !isPreparingCrop else { return }
        isPreparingCrop = true
        Task {
            defer { isPreparingCrop = false; pickedItem = nil; pickedTarget = nil }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { throw CCError.renderFailed }
                let prepared = try await Task.detached(priority: .userInitiated) {
                    guard let preview = WallpaperService.photoPreview(data: data, maxPixelSize: 1600) else { throw CCError.renderFailed }
                    let size = try WallpaperService(channelOrder: channelOrder).targetPixelSize(for: target)
                    return (preview, size)
                }.value
                preparedCrop = PhotoCropRequest(target: target, data: data, preview: prepared.0,
                                                pixelSize: prepared.1, channelOrder: channelOrder)
                await Task.yield()
                presentPreparedCrop()
            } catch { self.error = error.localizedDescription }
        }
    }

    private func presentPreparedCrop() {
        guard !showPhotoPicker, let preparedCrop else { return }
        cropSelection = preparedCrop
        self.preparedCrop = nil
    }

    private func hasPending(_ target: WallpaperTarget) -> Bool {
        edits.pending.contains { $0.target.path == target.path }
    }

    private func preview(for target: WallpaperTarget) -> CGImage? {
        hasPending(target) ? edits.thumbnails[target.path] : store.thumbnails[target.path]
    }

    private func pixelSize(for target: WallpaperTarget) -> CGSize? {
        hasPending(target) ? edits.pixelSizes[target.path] : store.pixelSizes[target.path]
    }

    private func status(for target: WallpaperTarget) -> String? {
        if let edit = edits.pending.first(where: { $0.target.path == target.path }) {
            return edit.isRestore ? L("CACHE_EDIT_PENDING_RESTORE") : L("CACHE_EDIT_PENDING_REPLACE")
        }
        if edits.appliedTargets.contains(where: { $0.path == target.path }) { return L("CACHE_EDIT_APPLIED") }
        return nil
    }

    private func canPick(_ target: WallpaperTarget) -> Bool {
        currentFileNames.contains(target.fileName) && edits.isReady && !edits.isWorking && !store.isLoading && !isPreparingCrop
            && !showPhotoPicker && preparedCrop == nil && cropSelection == nil
            && store.targets.contains(where: { $0.path == target.path })
            && !history.backupFailures.contains(target.fileName)
    }

    private func canRestore(_ target: WallpaperTarget) -> Bool {
        currentFileNames.contains(target.fileName) && edits.isReady && !edits.isWorking && !store.isLoading && !hasPending(target)
            && edits.appliedTargets.contains(where: { $0.path == target.path })
            && history.originalBackups.contains(where: { $0.cacheFileName == target.fileName })
            && !history.backupFailures.contains(target.fileName)
    }

    private func pick(_ target: WallpaperTarget) {
        guard canPick(target) else { return }
        pickedItem = nil
        pickedTarget = target
        showPhotoPicker = true
    }

    private func restore(_ target: WallpaperTarget) {
        guard canRestore(target), let backup = history.originalBackups.first(where: { $0.cacheFileName == target.fileName }) else { return }
        let order = settings.channelOrder
        Task {
            do { try await edits.stageRestores([backup], for: target, channelOrder: order) }
            catch { self.error = error.localizedDescription }
        }
    }

    private func restoreAll() {
        let backups = currentBackups, order = settings.channelOrder
        Task {
            do { try await edits.stageRestores(backups, channelOrder: order) }
            catch { self.error = error.localizedDescription }
        }
    }

    private func clear(_ target: WallpaperTarget) {
        Task {
            do { try await edits.clearPending(for: target) }
            catch { self.error = error.localizedDescription }
        }
    }

    private func apply() {
        Task {
            do {
                try await edits.applyPending(for: Set(currentPending.map { $0.target.path }))
                // Every successful file and its status are on disk already.
                isRespringing = true
            } catch { self.error = error.localizedDescription }
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

/// Fixed-size, left-aligned photo; the remaining width is not an image slot.
@MainActor
private struct CacheTargetRow: View {
    let target: WallpaperTarget
    let image: CGImage?
    let pixelSize: CGSize?
    let status: String?
    let canPick: Bool
    let canRestore: Bool
    let canClear: Bool
    let onPick: () -> Void
    let onRestore: () -> Void
    let onClear: () -> Void

    var body: some View {
        let previewImage = image
        VStack(alignment: .leading, spacing: 6) {
            Text(target.fileName).font(.caption2.monospaced()).textSelection(.enabled)
            HStack(spacing: 12) {
                Button(action: onPick) {
                    Group {
                        if let previewImage {
                            Image(decorative: previewImage, scale: 1).resizable().scaledToFit()
                                .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                        } else {
                            VStack(spacing: 4) {
                                Image(systemName: "photo.badge.exclamationmark")
                                Text(L("BROWSER_PREVIEW_FAILED")).font(.caption2)
                            }.foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 144, height: 80, alignment: .leading)
                    .background {
                        if previewImage == nil {
                            RoundedRectangle(cornerRadius: 8).fill(Color(uiColor: .tertiarySystemFill))
                        }
                    }
                }
                .buttonStyle(.plain).disabled(!canPick)
                .accessibilityLabel(LF("CACHE_EDIT_PICK_FILE", target.fileName))
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 6) {
                    Button(L("WALLPAPER_RESTORE"), action: onRestore).disabled(!canRestore)
                    Button(L("CACHE_EDIT_CLEAR"), action: onClear).disabled(!canClear)
                }.buttonStyle(.bordered).font(.footnote)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(ByteCountFormatter.string(fromByteCount: Int64(target.byteCount), countStyle: .file))
                Text(pixelSize.map { "\(Int($0.width)) × \(Int($0.height))" } ?? "—")
                if let status { Text(status).font(.caption) }
            }.font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One session cache for the browser. Failed preview /
/// discovery results are cached too; only refresh/mutation retries them. Original
/// file bytes and full-size images never live in this store.
@MainActor
final class CarPlayBrowserStore: ObservableObject {
    static let shared = CarPlayBrowserStore()
    @Published private(set) var targets: [WallpaperTarget] = []
    @Published private(set) var thumbnails: [String: CGImage] = [:]
    @Published private(set) var pixelSizes: [String: CGSize] = [:]
    @Published private(set) var cacheDirectory: String?
    @Published private(set) var devices: [CarPlayDeviceProbe.Device] = []
    @Published private(set) var deviceError: String?
    @Published var error: String?
    @Published private(set) var isLoading = false

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
        pixelSizes = [:]
        error = nil
        if !keepTargets { targets = []; cacheDirectory = nil; devices = []; deviceError = nil }
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
        let pixelSizes: [String: CGSize]
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
                let paired = try await Task.detached(priority: .userInitiated) {
                    try CarPlayDeviceProbe.devices()
                }.value
                if currentRevision == revision { devices = paired; deviceError = nil }
            } catch {
                if currentRevision == revision { devices = []; deviceError = error.localizedDescription }
            }
            do {
                let snapshot = try await Task.detached(priority: .userInitiated) {
                    let resolved = try ContainerResolver().resolve(forceRefresh: forceRefresh)
                    let service = WallpaperService(channelOrder: channelOrder)
                    var images: [String: CGImage] = [:]
                    var sizes: [String: CGSize] = [:]
                    // A serial loop bounds peak memory to one decoded original.
                    for target in resolved.files {
                        autoreleasepool {
                            if let image = service.previewImage(for: target, resolved: resolved,
                                                                onPixelSize: { sizes[target.path] = $0 }) { images[target.path] = image }
                        }
                    }
                    try CacheEditStore.shared.reconcile(with: resolved)
                    return Snapshot(resolved: resolved, thumbnails: images, pixelSizes: sizes)
                }.value
                if currentRevision == revision {
                    targets = snapshot.resolved.files
                    thumbnails = snapshot.thumbnails
                    pixelSizes = snapshot.pixelSizes
                    cacheDirectory = snapshot.resolved.cacheDirectory
                    hasLoadedOnce = true
                }
            } catch {
                if currentRevision == revision {
                    targets = []; thumbnails = [:]; pixelSizes = [:]; cacheDirectory = nil
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
