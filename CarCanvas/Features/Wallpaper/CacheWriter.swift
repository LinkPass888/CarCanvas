import Foundation

/// The only code that writes outside this app's sandbox.
///
/// Guarantees, in order:
///  1. fail-closed version gate + App Group check (via WQAccess)
///  2. re-resolve the container; validate every path against WQWhitelist
///  3. require a verified, persisted original in Documents/Backups
///  4. write atomically, verify contents, roll back on mismatch
///  5. release the sandbox extension in `defer`
///
/// There is no silent path: `targets` must be explicitly provided by the UI
/// after the user confirms each Dark / Light destination.
final class CacheWriter {
    struct Result { let succeeded: Int; let failed: Int }

    private let history = HistoryStore.shared

    func overwrite(entry: HistoryEntry,
                   targets: [WallpaperTarget],
                   dark: Bool,
                   light: Bool) throws -> Result {
        guard dark || light else { throw CCError.nothingSelected }

        let resolved = try ContainerResolver().resolve()
        let selected = targets.filter { t in
            resolved.files.contains(where: { $0.path == t.path && $0.fileName == t.fileName })
                && WQWhitelist.isAllowedCacheFile(t.path, in: resolved.cacheDirectory)
                && ((t.isDark && dark) || (t.isLight && light))
        }
        guard !selected.isEmpty else { throw CCError.noCacheFiles }

        let darkData = data(for: entry.darkFileName)
        let lightData = data(for: entry.lightFileName)
        let fallback = darkData ?? lightData
        guard fallback != nil else { throw CCError.templateUnreadable(entry.baseName) }

        return try WQAccess.shared.withAccess(containerPath: resolved.containerPath) {
            var ok = 0, failed = 0
            for target in selected {
                // Prefer the matching appearance; fall back to the single
                // exported file only when no counterpart exists.
                let payload = (target.isDark ? (darkData ?? fallback) : (lightData ?? fallback))!
                do {
                    try writeOne(payload, to: target)
                    ok += 1
                } catch {
                    CCLog.error("overwrite failed for \(target.fileName): \(error.localizedDescription)")
                    failed += 1
                }
            }
            return Result(succeeded: ok, failed: failed)
        }
    }

    /// Restore only the exact current cache filename recorded with this copy.
    /// Resolution ends before acquiring the write scope; there is no nested grant.
    func restore(backup: HistoryStore.OriginalBackup) throws {
        do {
            let resolved = try ContainerResolver().resolve()
            let matches = resolved.files.filter { $0.fileName == backup.cacheFileName }
            guard matches.count == 1 else {
                throw NSError(domain: "CarCanvas.CacheWriter", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: LF("HISTORY_BACKUP_TARGET_MISSING", backup.cacheFileName)])
            }
            let target = matches[0]
            guard WQWhitelist.isAllowedCacheFile(target.path, in: resolved.cacheDirectory) else {
                throw CCError.outsideWhitelist(target.path)
            }
            let payload = try history.backupData(for: backup)
            try WQAccess.shared.withAccess(containerPath: resolved.containerPath) {
                let current = try Data(contentsOf: URL(fileURLWithPath: target.path))
                try writeVerified(payload, to: target, rollback: current)
            }
        } catch {
            CCLog.error("restore failed for \(backup.cacheFileName): \(error.localizedDescription)")
            throw error
        }
    }

    private func data(for fileName: String?) -> Data? {
        guard let fileName else { return nil }
        return try? Data(contentsOf: history.url(for: fileName))
    }

    private func writeOne(_ payload: Data, to target: WallpaperTarget) throws {
        // Existing originals are validated, never refreshed from a custom cache.
        try history.ensureOriginal(for: target)
        let current = try Data(contentsOf: URL(fileURLWithPath: target.path))
        try writeVerified(payload, to: target, rollback: current)
    }

    private func writeVerified(_ payload: Data, to target: WallpaperTarget, rollback current: Data) throws {
        let url = URL(fileURLWithPath: target.path)
        do {
            try payload.write(to: url, options: .atomic)
            guard try Data(contentsOf: url) == payload else {
                throw NSError(domain: "CarCanvas.CacheWriter", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: L("HISTORY_BACKUP_VERIFY_FAILED")])
            }
        } catch {
            do {
                try current.write(to: url, options: .atomic)
                guard try Data(contentsOf: url) == current else {
                    throw CCError.verificationFailed
                }
            } catch let rollbackError {
                CCLog.error("rollback failed for \(target.fileName): \(rollbackError.localizedDescription)")
                throw NSError(domain: "CarCanvas.CacheWriter", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: LF("HISTORY_BACKUP_ROLLBACK_FAILED", error.localizedDescription)])
            }
            throw error
        }
    }
}
