import Foundation
import Darwin

/// Finds the CarPlayWallpaper data container.
///
/// Primary route: ask ContainerManager for the container of
/// `com.apple.CarPlayWallpaper` by bundle identifier, exactly as the original
/// CarCanvas did. That returns a path and a sandbox-extension token immediately.
///
/// Fallback: a bounded inode walk, only for builds where the query is refused.
/// On iOS 26 that scan can take close to an hour, so it is never the first
/// choice and it is never run twice for the same launch.
final class ContainerResolver {
    struct Resolved {
        let containerPath: String
        let cacheDirectory: String
        let files: [WallpaperTarget]
    }

    /// One shared, launch-long result. The container does not move while the
    /// app is running, so re-resolving on every screen appearance is pointless
    /// work — and re-running the fallback scan would be far worse.
    private static let cache = ResolverCache()

    private final class ResolverCache {
        private let lock = NSLock()
        private var cached: Resolved?

        func value(for key: String) -> Resolved? {
            lock.lock(); defer { lock.unlock() }
            guard let cached, cached.containerPath == key || key.isEmpty else { return cached }
            return cached
        }

        func store(_ resolved: Resolved) {
            lock.lock(); defer { lock.unlock() }
            cached = resolved
        }

        func invalidate() {
            lock.lock(); defer { lock.unlock() }
            cached = nil
        }
    }

    /// Wallpaper caches are small; this is only for the fallback path.
    private let scanBudget: TimeInterval = 15

    static func invalidateCache() { cache.invalidate() }

    func resolve(forceRefresh: Bool = false) throws -> Resolved {
        if !forceRefresh, let hit = ContainerResolver.cache.value(for: "") { return hit }

        try WQAccess.shared.preflight()
        let resolved = try resolveUncached()
        ContainerResolver.cache.store(resolved)
        return resolved
    }

    private func resolveUncached() throws -> Resolved {
        var containerPath: String?
        var route = "query"

        // 1. Direct ContainerManager lookup — instant.
        if CCContainerQueryIsAvailable() {
            var path: NSString?
            var token: NSString?
            if CCContainerLookup(WQWhitelist.carPlayWallpaperBundleID, &path, &token),
               let found = path as String?, !found.isEmpty {
                containerPath = found
                // ContainerManager already issued the extension. Keep the handle
                // alive for this launch so the container stays readable, instead
                // of dropping the token and asking worse_query for another one.
                if let raw = token as String? {
                    let handle = CCConsumeContainerToken(raw)
                    CCLog.info("container query: \(found) (token handle \(handle))")
                    if handle >= 0 { WQAccess.shared.retainContainerHandle(handle) }
                } else {
                    CCLog.info("container query: \(found) (no token)")
                }
            } else {
                CCLog.error("container query returned nothing for \(WQWhitelist.carPlayWallpaperBundleID)")
            }
        } else {
            CCLog.error("container query symbols unavailable")
        }

        // 2. Fallback: bounded inode scan.
        if containerPath == nil {
            route = "inode scan"
            containerPath = scanForContainer()
        }

        guard let container = containerPath else {
            CCLog.error("container lookup failed (route: \(route))")
            throw CCError.cacheNotFound
        }

        let cacheDirectory = container + "/" + WQWhitelist.cacheRelativePath
        guard WQWhitelist.isAllowedCacheDirectory(cacheDirectory) else {
            throw CCError.outsideWhitelist(cacheDirectory)
        }

        let files = try WQAccess.shared.withAccess(containerPath: container) {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: cacheDirectory) else {
                CCLog.error("cache directory unreadable: \(cacheDirectory)")
                throw CCError.cacheNotFound
            }
            CCLog.info("cache directory: \(names.count) entries")
            var targets: [WallpaperTarget] = []
            for name in names.sorted() {
                let path = cacheDirectory + "/" + name
                guard WQWhitelist.isAllowedCacheFile(path, in: cacheDirectory) else { continue }
                var st = stat()
                guard lstat(path, &st) == 0, (st.st_mode & UInt16(S_IFMT)) == UInt16(S_IFREG) else { continue }
                targets.append(WallpaperTarget(path: path,
                                               fileName: name,
                                               appearance: WQWhitelist.appearance(of: name),
                                               byteCount: Int(st.st_size)))
            }
            return targets
        }
        CCLog.info("cache files accepted: \(files.count) (route: \(route))")
        guard !files.isEmpty else { throw CCError.noCacheFiles }
        return Resolved(containerPath: container, cacheDirectory: cacheDirectory, files: files)
    }

    /// Bounded inode walk. Only reached when the direct query is unavailable.
    private func scanForContainer() -> String? {
        var found: String?
        var candidates = 0
        _ = CCScanApplicationContainers(scanBudget) { path in
            candidates += 1
            guard let identifier = CCContainerIdentifier(path) else { return false }
            if identifier == WQWhitelist.carPlayWallpaperBundleID,
               WQWhitelist.isAllowedContainer(path, identifier: identifier) {
                found = path
                return true
            }
            return false
        }
        CCLog.info("scan inspected \(candidates) candidates, found: \(found ?? "none")")
        return found
    }

    func findCacheFiles() throws -> [WallpaperTarget] {
        try resolve().files
    }
}
