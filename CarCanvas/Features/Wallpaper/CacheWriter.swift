import Foundation
import Darwin

extension Notification.Name {
    static let carCanvasCacheDidChange = Notification.Name("CarCanvas.cacheDidChange")
}

/// The only writer outside our sandbox. Every operation resolves BEFORE its
/// synchronous, serialized WQ scope, then revalidates the exact fixed paths.
final class CacheWriter {
    private let history = HistoryStore.shared

    /// Restore is staged as metadata + a thumbnail, not as a captured payload.
    /// Apply must re-read and validate the original inside its own write scope.
    func prepareRestores(_ backups: [HistoryStore.OriginalBackup],
                         channelOrder: CPBitmapTemplate.ChannelOrder) throws -> [CacheEditStore.PreparedRestore] {
        guard !backups.isEmpty, Set(backups.map(\.cacheFileName)).count == backups.count else { throw CCError.backupFailed }
        let resolved = try ContainerResolver().resolve()
        return try WQAccess.shared.withAccess(containerPath: resolved.containerPath) {
            guard try WQWhitelist.cacheDirectoryExists(resolved.cacheDirectory) else { throw CCError.cacheNotFound }
            let files = try ContainerResolver.cacheFiles(in: resolved.cacheDirectory)
            let service = WallpaperService(channelOrder: channelOrder)
            return try backups.map { backup in
                try autoreleasepool {
                    let path = resolved.cacheDirectory + "/" + backup.cacheFileName
                    guard WQWhitelist.isAllowedCacheFile(path, in: resolved.cacheDirectory) else { throw CCError.outsideWhitelist(path) }
                    let pixelSize = CPBitmapTemplate.pixelSize(try history.backupData(for: backup))
                    let target = files.first(where: { $0.path == path })
                        ?? WallpaperTarget(path: path, fileName: backup.cacheFileName,
                                           appearance: WQWhitelist.appearance(of: backup.cacheFileName), byteCount: 0)
                    let image = service.previewImage(at: history.backupsDirectory.appendingPathComponent(backup.backupFileName))
                    return CacheEditStore.PreparedRestore(target: target, backup: backup, thumbnail: image, pixelSize: pixelSize)
                }
            }
        }
    }

    /// Process only the explicitly staged filenames. Notify once at the end,
    /// including partial failure, so each member does not restart discovery.
    func apply(edits: [CacheEditStore.PendingEdit]) throws {
        guard !edits.isEmpty else { throw CCError.nothingSelected }
        defer { announceCacheChange() }
        var succeeded = 0
        for edit in edits {
            do {
                try apply(edit: edit)
                succeeded += 1
            } catch {
                throw failure(LF("CACHE_APPLY_FAILED", succeeded, error.localizedDescription))
            }
        }
    }

    /// Exactly one durable edit, exactly one fixed filename. A missing replace
    /// target fails; only explicit restore may re-create its backed-up filename.
    private func apply(edit: CacheEditStore.PendingEdit) throws {
        let resolved = try ContainerResolver().resolve()
        let target = edit.target
        guard target.path == resolved.cacheDirectory + "/" + target.fileName,
              target.appearance == WQWhitelist.appearance(of: target.fileName),
              WQWhitelist.isAllowedCacheFile(target.path, in: resolved.cacheDirectory) else {
            throw failure(L("CACHE_EDIT_TARGET_CHANGED"))
        }
        try WQAccess.shared.withAccess(containerPath: resolved.containerPath) {
            let edits = CacheEditStore.shared
            try edits.validatePending(edit)
            guard try WQWhitelist.cacheDirectoryExists(resolved.cacheDirectory) else { throw CCError.cacheNotFound }
            let files = try ContainerResolver.cacheFiles(in: resolved.cacheDirectory)
            let currentTarget = files.first(where: { $0.path == target.path && $0.fileName == target.fileName })
            if let currentTarget, currentTarget.byteCount > 256 * 1024 * 1024 { throw CCError.templateUnreadable(target.fileName) }
            let payload: Data
            switch edit.action {
            case .replace:
                guard let currentTarget, currentTarget.appearance == target.appearance,
                      currentTarget.byteCount == target.byteCount else { throw failure(L("CACHE_EDIT_TARGET_CHANGED")) }
                payload = try edits.replacementData(for: edit)
                try history.ensureOriginal(for: currentTarget)
            case .restore(let backup):
                guard backup.cacheFileName == target.fileName else { throw CCError.backupFailed }
                payload = try history.backupData(for: backup)
            }
            let current = try existingData(at: target.path)
            if !edit.isRestore && current == nil { throw failure(L("CACHE_EDIT_TARGET_CHANGED")) }
            var wrote = false
            do {
                guard try existingData(at: target.path) == current else { throw failure(L("CACHE_EDIT_TARGET_CHANGED")) }
                try writeVerified(payload, to: target, rollback: current)
                wrote = true
                // Durable status precedes any NeoSpring request. A local index
                // failure is a failed Apply, not a falsely successful write.
                try edits.complete(edit, payload: payload)
            } catch {
                if wrote {
                    do {
                        guard try existingData(at: target.path) == payload else { throw CCError.verificationFailed }
                        if let current { try writeVerified(current, to: target, rollback: payload) }
                        else { try FileManager.default.removeItem(atPath: target.path) }
                    } catch let rollbackError {
                        CCLog.error("edit checkpoint rollback failed for \(target.fileName): \(rollbackError.localizedDescription)")
                        throw failure(LF("HISTORY_BACKUP_ROLLBACK_FAILED", error.localizedDescription))
                    }
                }
                throw error
            }
        }
    }

    /// Truly clear only regular, whitelist-named files in the identified fixed
    /// cache, then ALL app Backups/legacy copies/index. No prefs/pairings, cache
    /// directory, Exports/history, automatic logout or permanent rollback copy.
    @discardableResult
    func clearCacheAndBackups() throws -> Int {
        let resolved = try ContainerResolver().resolve(forceRefresh: true)
        var changed = false
        defer { if changed { announceCacheChange() } }
        return try WQAccess.shared.withAccess(containerPath: resolved.containerPath) {
            let targets = try ContainerResolver.cacheFiles(in: resolved.cacheDirectory)
            let manager = FileManager.default
            let temporary = manager.temporaryDirectory.appendingPathComponent("cc-cache-clear-\(UUID().uuidString)", isDirectory: true)
            var backupPurge: HistoryStore.BackupPurge?
            defer {
                removeTemporary(temporary)
                if let backupPurge { removeTemporary(backupPurge.temporaryDirectory) }
            }
            let editStore = CacheEditStore.shared
            let editSnapshot = try editStore.prepareReset()
            var resetEdits = false
            // Preparation is read/copy/verify only. A denied scope or unreadable
            // source fails before any system or local original is removed.
            try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
            backupPurge = try history.prepareBackupPurge()
            for target in targets {
                guard let data = try existingData(at: target.path) else { throw CCError.templateUnreadable(target.fileName) }
                let copy = temporary.appendingPathComponent(target.fileName)
                try data.write(to: copy, options: .atomic)
                guard try Data(contentsOf: copy) == data else { throw CCError.backupFailed }
            }
            var removed: [WallpaperTarget] = []
            do {
                for target in targets {
                    let copy = temporary.appendingPathComponent(target.fileName)
                    guard try existingData(at: target.path) == Data(contentsOf: copy) else { throw failure(L("CACHE_EDIT_TARGET_CHANGED")) }
                    try manager.removeItem(atPath: target.path)
                    removed.append(target)
                    changed = true
                }
                guard try ContainerResolver.cacheFiles(in: resolved.cacheDirectory).isEmpty,
                      let prepared = backupPurge else { throw CCError.verificationFailed }
                try editStore.reset(using: editSnapshot)
                resetEdits = true
                try history.purgeOriginalBackups(using: prepared)
                editStore.finishReset(editSnapshot)
                // Empty cache is still a successful explicit backup purge.
                changed = true
                return removed.count
            } catch {
                var rollbackFailed = false
                if resetEdits {
                    do { try editStore.rollbackReset(editSnapshot) }
                    catch let rollbackError {
                        rollbackFailed = true
                        CCLog.error("cache edit state rollback failed: \(rollbackError.localizedDescription)")
                    }
                }
                for target in removed {
                    do {
                        guard try WQWhitelist.cacheDirectoryExists(resolved.cacheDirectory) else { throw CCError.cacheNotFound }
                        // A recreated path (even a nonregular one) is never touched.
                        var info = stat()
                        if lstat(target.path, &info) == 0 { continue }
                        guard errno == ENOENT else { throw CCError.verificationFailed }
                        let payload = try Data(contentsOf: temporary.appendingPathComponent(target.fileName))
                        try payload.write(to: URL(fileURLWithPath: target.path), options: .withoutOverwriting)
                        guard try existingData(at: target.path) == payload else { throw CCError.verificationFailed }
                    } catch let rollbackError {
                        rollbackFailed = true
                        CCLog.error("cache clear rollback failed for \(target.fileName): \(rollbackError.localizedDescription)")
                    }
                }
                if rollbackFailed { throw failure(LF("CACHE_CLEAR_ROLLBACK_FAILED", error.localizedDescription)) }
                throw error
            }
        }
    }

    private func existingData(at path: String) throws -> Data? {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            let code = errno
            if code == ENOENT { return nil }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSLocalizedDescriptionKey: "Cache read failed (errno \(code))."])
        }
        guard (info.st_mode & UInt16(S_IFMT)) == UInt16(S_IFREG) else { throw CCError.outsideWhitelist(path) }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    private func writeVerified(_ payload: Data, to target: WallpaperTarget, rollback current: Data?) throws {
        let url = URL(fileURLWithPath: target.path)
        var didWrite = false
        do {
            try payload.write(to: url, options: current == nil ? .withoutOverwriting : .atomic)
            didWrite = true
            guard try existingData(at: target.path) == payload else { throw CCError.verificationFailed }
        } catch {
            do {
                if let current {
                    try current.write(to: url, options: .atomic)
                    guard try existingData(at: target.path) == current else { throw CCError.verificationFailed }
                } else if didWrite {
                    guard try existingData(at: target.path) == payload else { throw CCError.verificationFailed }
                    try FileManager.default.removeItem(at: url)
                }
            } catch let rollbackError {
                CCLog.error("rollback failed for \(target.fileName): \(rollbackError.localizedDescription)")
                throw failure(LF("HISTORY_BACKUP_ROLLBACK_FAILED", error.localizedDescription))
            }
            throw error
        }
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "CarCanvas.CacheWriter", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    private func removeTemporary(_ directory: URL) {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        do { try FileManager.default.removeItem(at: directory) }
        catch { CCLog.error("temporary rollback cleanup failed: \(error.localizedDescription)") }
    }
    private func announceCacheChange() {
        ContainerResolver.invalidateCache()
        NotificationCenter.default.post(name: .carCanvasCacheDidChange, object: nil)
    }
}
