import Foundation
import Darwin

/// The only code that writes outside this app's sandbox.
///
/// Guarantees, in order:
///  1. fail-closed version gate + App Group check (via WQAccess)
///  2. re-resolve the container; validate every path against WQWhitelist
///  3. back up the original to Documents/Backups (abort if backup fails)
///  4. write atomically, verify byte count, roll back on mismatch
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
        guard SettingsStore.shared.requireExplicitConfirmation else {
            throw CCError.nothingSelected
        }

        let resolved = try ContainerResolver().resolve()
        let selected = targets.filter { t in
            WQWhitelist.isAllowedCacheFile(t.path, in: resolved.cacheDirectory)
                && ((t.isDark && dark) || (t.isLight && light))
        }
        guard !selected.isEmpty else { throw CCError.noCacheFiles }

        let darkData = data(for: entry.darkFileName)
        let lightData = data(for: entry.lightFileName)
        let fallback = darkData ?? lightData
        guard fallback != nil else { throw CCError.templateUnreadable(entry.baseName) }

        return try WQAccess.shared.withAccess(containerPath: resolved.containerPath,
                                              identifier: WQWhitelist.carPlayWallpaperBundleID) {
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

    private func data(for fileName: String?) -> Data? {
        guard let fileName else { return nil }
        return try? Data(contentsOf: history.url(for: fileName))
    }

    private func writeOne(_ payload: Data, to target: WallpaperTarget) throws {
        let url = URL(fileURLWithPath: target.path)
        guard let original = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            throw CCError.templateUnreadable(target.fileName)
        }
        let backupName = "\(Date().timeIntervalSince1970)-\(target.fileName)"
        let backupURL = history.backupsDirectory.appendingPathComponent(backupName)
        do {
            try original.write(to: backupURL, options: .atomic)
        } catch { throw CCError.backupFailed }

        do {
            try payload.write(to: url, options: .atomic)
        } catch {
            try? original.write(to: url, options: .atomic)
            throw error
        }

        var st = stat()
        guard lstat(target.path, &st) == 0, Int(st.st_size) == payload.count else {
            try? original.write(to: url, options: .atomic)
            throw CCError.verificationFailed
        }
    }
}
