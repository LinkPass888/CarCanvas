import Foundation
import Combine
import CoreGraphics
import ImageIO
import CryptoKit

/// Durable, app-local edits. Picking/clearing never writes the system cache;
/// only CacheWriter may complete an edit inside its serialized access scope.
final class CacheEditStore: ObservableObject {
    static let shared = CacheEditStore()

    struct PendingEdit: Identifiable, Codable, Equatable {
        enum Action: Codable, Equatable {
            case replace
            case restore(HistoryStore.OriginalBackup)
        }

        let id: UUID
        let target: WallpaperTarget
        let action: Action
        let createdAt: Date
        var payloadFileName: String { "\(id.uuidString).cpbitmap" }
        var previewFileName: String { "\(id.uuidString).png" }
        var isRestore: Bool { if case .restore = action { return true }; return false }
    }

    struct PreparedRestore {
        let target: WallpaperTarget
        let backup: HistoryStore.OriginalBackup
        let thumbnail: CGImage?
    }

    struct ResetSnapshot {
        let pending: [PendingEdit]
        let applied: [WallpaperTarget]
    }

    private struct State: Codable, Equatable {
        var pending: [PendingEdit] = []
        var applied: [WallpaperTarget] = []
    }

    @Published private(set) var pending: [PendingEdit] = []
    @Published private(set) var appliedTargets: [WallpaperTarget] = []
    @Published private(set) var thumbnails: [String: CGImage] = [:]
    @Published private(set) var isReady = false
    @Published private(set) var isWorking = false
    @Published private(set) var loadError: String?

    private let directory: URL
    private let indexURL: URL
    private let storageQueue = DispatchQueue(label: "CarCanvas.CacheEditStore", qos: .utility)
    private var stored = State()
    private var storedThumbnails: [String: CGImage] = [:]
    private var indexReadable = false

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = docs.appendingPathComponent("StagedWallpapers", isDirectory: true)
        indexURL = directory.appendingPathComponent("index.json")
        storageQueue.async { self.load() }
    }

    private func load() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: indexURL.path) {
                stored = try JSONDecoder().decode(State.self, from: Data(contentsOf: indexURL))
                try validate(stored)
            }
            for edit in stored.pending {
                // Missing/corrupt staging files remain clearable, never silently
                // treated as applied or replaced with another file's contents.
                if let data = try? localData(edit.previewFileName, maximum: 4 * 1024 * 1024),
                   let image = WallpaperService.photoPreview(data: data) {
                    storedThumbnails[edit.target.path] = image
                }
            }
            indexReadable = true
            publish()
        } catch {
            CCLog.error("cache edit state load failed: \(error.localizedDescription)")
            DispatchQueue.main.async { self.loadError = L("CACHE_EDIT_STATE_UNREADABLE") }
        }
    }

    private func validate(_ state: State) throws {
        guard Set(state.pending.map(\.id)).count == state.pending.count,
              Set(state.pending.map { $0.target.path }).count == state.pending.count,
              Set(state.applied.map(\.path)).count == state.applied.count else { throw CCError.verificationFailed }
        for target in state.applied + state.pending.map(\.target) {
            let parent = URL(fileURLWithPath: target.path).deletingLastPathComponent().path
            guard target.fileName == (target.path as NSString).lastPathComponent,
                  target.appearance == WQWhitelist.appearance(of: target.fileName),
                  WQWhitelist.isAllowedCacheFile(target.path, in: parent) else { throw CCError.outsideWhitelist(target.path) }
        }
        for edit in state.pending {
            if case .restore(let backup) = edit.action {
                guard backup.cacheFileName == edit.target.fileName,
                      backup.backupFileName == "original-\(backup.cacheFileName)" else { throw CCError.backupFailed }
            }
        }
    }

    private func persist(_ state: State) throws {
        guard indexReadable else { throw failure(L("CACHE_EDIT_STATE_UNREADABLE")) }
        try validate(state)
        let data = try JSONEncoder().encode(state)
        let previous = try JSONEncoder().encode(stored)
        do {
            try data.write(to: indexURL, options: .atomic)
            guard try Data(contentsOf: indexURL) == data else { throw CCError.verificationFailed }
            stored = state
        } catch {
            // A failed read-back must not leave a new index pointing at payloads
            // the caller is about to discard, or at a system write rolled back.
            do {
                try previous.write(to: indexURL, options: .atomic)
                guard try Data(contentsOf: indexURL) == previous else { throw CCError.verificationFailed }
            } catch let rollbackError {
                indexReadable = false
                DispatchQueue.main.async {
                    self.isReady = false
                    self.loadError = L("CACHE_EDIT_STATE_UNREADABLE")
                }
                CCLog.error("cache edit index rollback failed: \(rollbackError.localizedDescription)")
                throw failure(LF("HISTORY_BACKUP_ROLLBACK_FAILED", error.localizedDescription))
            }
            throw error
        }
    }

    private func publish() {
        let edits = stored.pending.sorted { $0.target.path < $1.target.path }
        let applied = stored.applied
        let images = storedThumbnails
        DispatchQueue.main.async {
            self.pending = edits
            self.appliedTargets = applied
            self.thumbnails = images
            self.isReady = true
        }
    }

    @MainActor
    private func beginWork() throws {
        guard isReady else { throw failure(L("CACHE_EDIT_STATE_UNREADABLE")) }
        guard !isWorking else { throw failure(L("CACHE_EDIT_BUSY")) }
        isWorking = true
    }

    @MainActor
    func stagePhoto(for target: WallpaperTarget, channelOrder: CPBitmapTemplate.ChannelOrder,
                    cropCenter: CGPoint = CGPoint(x: 0.5, y: 0.5), expectedPixelSize: CGSize? = nil,
                    loadPhoto: () async throws -> Data) async throws {
        try beginWork()
        defer { isWorking = false }
        let data = try await loadPhoto()
        try Task.checkCancellation()
        try await Task.detached(priority: .userInitiated) {
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("cc-photo-\(UUID().uuidString).img")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try data.write(to: temporary, options: .atomic)
            let prepared = try WallpaperService(channelOrder: channelOrder).prepareReplacement(
                imageURL: temporary, target: target, cropCenter: cropCenter, expectedPixelSize: expectedPixelSize)
            try self.saveReplacement(target: target, payload: prepared.data, thumbnail: prepared.preview)
        }.value
    }

    private func saveReplacement(target: WallpaperTarget, payload: Data, thumbnail: CGImage) throws {
        try storageQueue.sync {
            guard CPBitmapTemplate.hasCPBitmapSignature(payload) else { throw CCError.renderFailed }
            let edit = PendingEdit(id: UUID(), target: target, action: .replace, createdAt: Date())
            do {
                try payload.write(to: directory.appendingPathComponent(edit.payloadFileName), options: .atomic)
                guard try localData(edit.payloadFileName) == payload else { throw CCError.verificationFailed }
                try saveThumbnail(thumbnail, for: edit)
                try replacePending(with: [edit], images: [target.path: thumbnail])
            } catch {
                removeFiles(for: edit)
                throw error
            }
        }
    }

    @MainActor
    func stageRestores(_ backups: [HistoryStore.OriginalBackup], for appliedTarget: WallpaperTarget? = nil,
                       channelOrder: CPBitmapTemplate.ChannelOrder) async throws {
        try beginWork()
        defer { isWorking = false }
        try await Task.detached(priority: .userInitiated) {
            let prepared = try CacheWriter().prepareRestores(backups, channelOrder: channelOrder)
            try self.storageQueue.sync {
                if let target = appliedTarget {
                    guard prepared.count == 1, prepared[0].target.path == target.path,
                          self.stored.applied.contains(where: { $0.path == target.path }),
                          !self.stored.pending.contains(where: { $0.target.path == target.path }) else {
                        throw self.failure(L("CACHE_EDIT_TARGET_CHANGED"))
                    }
                }
                let edits = prepared.map { PendingEdit(id: UUID(), target: $0.target,
                                                       action: .restore($0.backup), createdAt: Date()) }
                var images: [String: CGImage] = [:]
                do {
                    for (edit, restore) in zip(edits, prepared) {
                        if let image = restore.thumbnail {
                            try self.saveThumbnail(image, for: edit)
                            images[edit.target.path] = image
                        }
                    }
                    try self.replacePending(with: edits, images: images)
                } catch {
                    for edit in edits { self.removeFiles(for: edit) }
                    throw error
                }
            }
        }.value
    }

    /// Persist the whole selection before deleting superseded local payloads.
    private func replacePending(with edits: [PendingEdit], images: [String: CGImage]) throws {
        let paths = Set(edits.map { $0.target.path })
        let previous = stored.pending.filter { paths.contains($0.target.path) }
        var updated = stored
        updated.pending.removeAll { paths.contains($0.target.path) }
        updated.pending.append(contentsOf: edits)
        try persist(updated)
        for path in paths { storedThumbnails[path] = images[path] }
        for edit in previous { removeFiles(for: edit) }
        publish()
    }

    @MainActor
    func clearPending(for target: WallpaperTarget) async throws {
        try beginWork()
        defer { isWorking = false }
        try await Task.detached(priority: .userInitiated) {
            try self.storageQueue.sync {
                let removed = self.stored.pending.filter { $0.target.path == target.path }
                var updated = self.stored
                updated.pending.removeAll { $0.target.path == target.path }
                try self.persist(updated)
                self.storedThumbnails[target.path] = nil
                for edit in removed { self.removeFiles(for: edit) }
                self.publish()
            }
        }.value
    }

    /// Re-read the durable record/payload at WRITE-SCOPE time, not at pick time.
    func replacementData(for edit: PendingEdit) throws -> Data {
        guard WQAccess.hasActiveExtensionOnCurrentThread else { throw CCError.verificationFailed }
        return try storageQueue.sync {
            guard indexReadable, stored.pending.contains(edit), edit.action == .replace else { throw CCError.verificationFailed }
            let data = try localData(edit.payloadFileName)
            guard CPBitmapTemplate.hasCPBitmapSignature(data) else { throw CCError.renderFailed }
            return data
        }
    }

    func validatePending(_ edit: PendingEdit) throws {
        try storageQueue.sync {
            guard indexReadable, stored.pending.contains(edit) else { throw CCError.verificationFailed }
        }
    }

    /// The writer rolls its single file back if this durable checkpoint fails.
    func complete(_ edit: PendingEdit, payload: Data) throws {
        guard WQAccess.hasActiveExtensionOnCurrentThread else { throw CCError.verificationFailed }
        try storageQueue.sync {
            guard stored.pending.contains(edit) else { throw CCError.verificationFailed }
            var updated = stored
            updated.pending.removeAll { $0.id == edit.id }
            updated.applied.removeAll { $0.path == edit.target.path }
            if !edit.isRestore {
                var applied = edit.target
                applied.contentDigest = Self.digest(payload)
                updated.applied.append(applied)
            }
            try persist(updated)
            storedThumbnails[edit.target.path] = nil
            removeFiles(for: edit)
            publish()
        }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A persisted flag is not proof that a regenerated cache is still custom.
    func reconcile(with resolved: ContainerResolver.Resolved) throws {
        try WQAccess.shared.withAccess(containerPath: resolved.containerPath) {
            let files = try ContainerResolver.cacheFiles(in: resolved.cacheDirectory)
            let paths = Set(files.map(\.path))
            let snapshot = storageQueue.sync { stored }
            var matching: Set<WallpaperTarget> = []
            for target in snapshot.applied {
                guard let expected = target.contentDigest,
                      files.contains(where: { $0.path == target.path && $0.byteCount <= 256 * 1024 * 1024 }),
                      let data = try? Data(contentsOf: URL(fileURLWithPath: target.path)),
                      Self.digest(data) == expected else { continue }
                matching.insert(target)
            }
            try storageQueue.sync {
                guard indexReadable else { return }
                var updated = stored
                updated.applied.removeAll { snapshot.applied.contains($0) && !matching.contains($0) }
                let removed = updated.pending.filter { edit in
                    let parent = URL(fileURLWithPath: edit.target.path).deletingLastPathComponent().path
                    return parent != resolved.cacheDirectory || (!edit.isRestore && !paths.contains(edit.target.path))
                }
                let ids = Set(removed.map(\.id))
                updated.pending.removeAll { ids.contains($0.id) }
                guard updated != stored else { return }
                try persist(updated)
                for edit in removed {
                    storedThumbnails[edit.target.path] = nil
                    removeFiles(for: edit)
                }
                publish()
            }
        }
    }

    @MainActor
    func applyPending() async throws {
        try beginWork()
        defer { isWorking = false }
        let edits = pending
        guard !edits.isEmpty else { throw CCError.nothingSelected }
        try await Task.detached(priority: .userInitiated) {
            try CacheWriter().apply(edits: edits)
        }.value
    }

    @MainActor
    func clearCacheAndBackups() async throws -> Int {
        try beginWork()
        defer { isWorking = false }
        return try await Task.detached(priority: .userInitiated) { try CacheWriter().clearCacheAndBackups() }.value
    }

    func prepareReset() throws -> ResetSnapshot {
        try storageQueue.sync {
            guard indexReadable else { throw failure(L("CACHE_EDIT_STATE_UNREADABLE")) }
            return ResetSnapshot(pending: stored.pending, applied: stored.applied)
        }
    }

    func reset(using snapshot: ResetSnapshot) throws {
        try storageQueue.sync {
            guard stored == State(pending: snapshot.pending, applied: snapshot.applied) else { throw CCError.verificationFailed }
            // Keep payloads until the cache AND backup purge have committed.
            try persist(State())
            storedThumbnails = [:]
            publish()
        }
    }

    func rollbackReset(_ snapshot: ResetSnapshot) throws {
        try storageQueue.sync {
            guard stored == State() else { throw CCError.verificationFailed }
            try persist(State(pending: snapshot.pending, applied: snapshot.applied))
            for edit in snapshot.pending {
                if let data = try? localData(edit.previewFileName, maximum: 4 * 1024 * 1024) {
                    storedThumbnails[edit.target.path] = WallpaperService.photoPreview(data: data)
                }
            }
            publish()
        }
    }

    func finishReset(_ snapshot: ResetSnapshot) {
        storageQueue.sync { for edit in snapshot.pending { removeFiles(for: edit) } }
    }

    private func localData(_ name: String, maximum: Int = 256 * 1024 * 1024) throws -> Data {
        guard name == (name as NSString).lastPathComponent else { throw CCError.verificationFailed }
        let url = directory.appendingPathComponent(name)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= maximum else { throw CCError.verificationFailed }
        let data = try Data(contentsOf: url)
        guard data.count == size else { throw CCError.verificationFailed }
        return data
    }

    private func saveThumbnail(_ image: CGImage, for edit: PendingEdit) throws {
        guard image.width <= WallpaperService.thumbnailDimension, image.height <= WallpaperService.thumbnailDimension,
              let destination = CGImageDestinationCreateWithURL(directory.appendingPathComponent(edit.previewFileName) as CFURL,
                                                                "public.png" as CFString, 1, nil) else { throw CCError.renderFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CCError.renderFailed }
    }

    private func removeFiles(for edit: PendingEdit) {
        for name in [edit.payloadFileName, edit.previewFileName] {
            let url = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                do { try FileManager.default.removeItem(at: url) }
                catch { CCLog.error("staged file cleanup failed: \(error.localizedDescription)") }
            }
        }
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "CarCanvas.CacheEditStore", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
