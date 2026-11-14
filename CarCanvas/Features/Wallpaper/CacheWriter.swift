import Foundation
import Darwin

extension Notification.Name {
    static let carCanvasCacheDidChange = Notification.Name("CarCanvas.cacheDidChange")
}

/// The only writer outside our sandbox. Every operation resolves BEFORE its
/// synchronous, serialized WQ scope, then revalidates the exact fixed paths.
final class CacheWriter {
    struct Result { let succeeded: Int; let failed: Int }
    private let history = HistoryStore.shared

    private struct Replacement {
        let target: WallpaperTarget
        let payload: Data
        let current: Data
    }

    /// A singular group is the entire destination contract. Incomplete groups
    /// write only their existing member, and legacy one-file exports can supply
    /// that member. A corrupt/missing named counterpart is NOT another photo.
    func overwrite(entry: HistoryEntry, group: WallpaperGroup) throws -> Result {
        guard group.isReplaceable else { throw CCError.nothingSelected }
        let resolved = try ContainerResolver().resolve()
        var changed = false
        defer { if changed { announceCacheChange() } }
        return try WQAccess.shared.withAccess(containerPath: resolved.containerPath) {
            let currentFiles = try ContainerResolver.cacheFiles(in: resolved.cacheDirectory)
            guard let currentGroup = WallpaperGroup.make(from: currentFiles).first(where: { $0.id == group.id }),
                  currentGroup.isReplaceable,
                  Set(currentGroup.targets.map(\.path)) == Set(group.targets.map(\.path)),
                  group.targets.allSatisfy({ selected in
                      currentGroup.targets.contains { $0.path == selected.path && $0.fileName == selected.fileName && $0.appearance == selected.appearance }
                  }) else { throw failure(L("HISTORY_GROUP_CHANGED")) }

            // Prepare BOTH payloads, originals and rollback copies before any
            // member is written. Never expand a selection to another group.
            let replacements = try currentGroup.targets.map { target -> Replacement in
                let payload = try exportData(for: target, entry: entry)
                try history.ensureOriginal(for: target)
                guard let current = try existingData(at: target.path) else { throw CCError.noCacheFiles }
                return Replacement(target: target, payload: payload, current: current)
            }
            var written: [Replacement] = []
            do {
                for replacement in replacements {
                    guard try existingData(at: replacement.target.path) == replacement.current else { throw failure(L("HISTORY_GROUP_CHANGED")) }
                    changed = true
                    try writeVerified(replacement.payload, to: replacement.target, rollback: replacement.current)
                    written.append(replacement)
                }
            } catch {
                var rollbackFailed = false
                for replacement in written.reversed() {
                    do {
                        // Do not clobber a file another process has regenerated.
                        guard try existingData(at: replacement.target.path) == replacement.payload else { throw CCError.verificationFailed }
                        try writeVerified(replacement.current, to: replacement.target, rollback: replacement.payload)
                    } catch let rollbackError {
                        rollbackFailed = true
                        CCLog.error("group rollback failed for \(replacement.target.fileName): \(rollbackError.localizedDescription)")
                    }
                }
                if rollbackFailed { throw failure(LF("HISTORY_BACKUP_ROLLBACK_FAILED", error.localizedDescription)) }
                throw error
            }
            return Result(succeeded: replacements.count, failed: 0)
        }
    }

    /// The exact whitelist filename may be absent, but its original must still
    /// be valid at WRITE-SCOPE time. A queued pre-cleanup payload cannot revive it.
    func restore(backup: HistoryStore.OriginalBackup) throws {
        let resolved = try ContainerResolver().resolve()
        var attemptedWrite = false
        defer { if attemptedWrite { announceCacheChange() } }
        let path = resolved.cacheDirectory + "/" + backup.cacheFileName
        guard WQWhitelist.isAllowedCacheFile(path, in: resolved.cacheDirectory) else { throw CCError.outsideWhitelist(path) }
        try WQAccess.shared.withAccess(containerPath: resolved.containerPath) {
            guard try WQWhitelist.cacheDirectoryExists(resolved.cacheDirectory) else {
                throw failure(LF("HISTORY_BACKUP_TARGET_MISSING", backup.cacheFileName))
            }
            let payload = try history.backupData(for: backup)
            let current = try existingData(at: path)
            let target = WallpaperTarget(path: path, fileName: backup.cacheFileName,
                                         appearance: WQWhitelist.appearance(of: backup.cacheFileName), byteCount: current?.count ?? 0)
            attemptedWrite = true
            try writeVerified(payload, to: target, rollback: current)
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
                    guard try existingData(at: target.path) == Data(contentsOf: copy) else { throw failure(L("HISTORY_GROUP_CHANGED")) }
                    try manager.removeItem(atPath: target.path)
                    removed.append(target)
                    changed = true
                }
                guard try ContainerResolver.cacheFiles(in: resolved.cacheDirectory).isEmpty,
                      let prepared = backupPurge else { throw CCError.verificationFailed }
                try history.purgeOriginalBackups(using: prepared)
                // Empty cache is still a successful explicit backup purge.
                changed = true
                return removed.count
            } catch {
                var rollbackFailed = false
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

    private func exportData(for target: WallpaperTarget, entry: HistoryEntry) throws -> Data {
        let name = target.isDark ? (entry.darkFileName ?? entry.lightFileName) : (entry.lightFileName ?? entry.darkFileName)
        guard let name, name == (name as NSString).lastPathComponent, name.hasSuffix(".cpbitmap"),
              let data = try existingData(at: history.url(for: name).path), CPBitmapTemplate.hasCPBitmapSignature(data) else {
            throw CCError.templateUnreadable(entry.baseName)
        }
        return data
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
