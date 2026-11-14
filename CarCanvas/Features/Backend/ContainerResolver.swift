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
    private let scanBudget: TimeInterval = 20

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

        // 1. Enumerate containers through ContainerManager. The bundle-id
        //    single-result query needs an identity this build does not have and
        //    always returns nothing, so enumeration is the working route.
        route = "container enumeration"
        let enumerated = CCContainerEnumerate()
        CCLog.info("container enumeration: \(enumerated.count) containers")
        for entry in enumerated {
            guard let found = entry["path"], entry["identifier"] == WQWhitelist.carPlayWallpaperBundleID else { continue }
            containerPath = found
            CCLog.info("container enumeration matched: \(found)")
            break
        }

        // 2. LaunchServices. Reads each installed app's dataContainerURL, so it
        //    needs neither a query nor an inode walk. This is the route WQFiles
        //    uses when ContainerManager refuses.
        if containerPath == nil {
            route = "launchservices"
            if CCLSIsAvailable() {
                let all = CCLSAllContainers()
                CCLog.info("launchservices: \(all.count) containers")
                for (path, identifier) in all where identifier == WQWhitelist.carPlayWallpaperBundleID {
                    containerPath = path
                    CCLog.info("launchservices: \(path)")
                    break
                }
            } else {
                CCLog.error("launchservices unavailable")
            }
        }

        // 3. Last resort: a short bounded inode scan. Skipped entirely once
        //    enumeration has already shown the container is not listed - that
        //    answer will not change by walking inodes for 15 seconds.
        if containerPath == nil, enumerated.isEmpty {
            route = "inode scan"
            containerPath = scanForContainer()
        } else if containerPath == nil {
            CCLog.info("skipping inode scan: enumeration listed \(enumerated.count) containers without a match")
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
                // The container exists but this exact cache path does not. On
                // newer builds the mapped-image cache can live elsewhere inside
                // the same container, so look one level up before giving up.
                if let fallback = Self.locateWallpaperImages(inContainer: container) {
                    CCLog.info("cache directory fallback: \(fallback)")
                    return Self.cacheFiles(in: fallback)
                }
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

    /// Searches the container for a directory that actually holds .cpbitmap
    /// files, so a layout change in CarPlay's cache path does not break the app.
    private static func locateWallpaperImages(inContainer container: String) -> String? {
        let candidates = [
            container + "/Library/Caches/MappedImageCache",
            container + "/Library/Caches",
            container + "/Library"
        ]
        let fm = FileManager.default
        for candidate in candidates {
            guard let entries = try? fm.contentsOfDirectory(atPath: candidate) else { continue }
            for entry in entries where entry.lowercased().contains("wallpaper") {
                let path = candidate + "/" + entry
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                    if let inner = try? fm.contentsOfDirectory(atPath: path),
                       inner.contains(where: { $0.lowercased().hasSuffix(".cpbitmap") }) {
                        return path
                    }
                }
            }
            // Also accept the candidate itself if it holds cache files.
            if let inner = try? fm.contentsOfDirectory(atPath: candidate),
               inner.contains(where: { $0.lowercased().hasSuffix(".cpbitmap") }) {
                return candidate
            }
        }
        return nil
    }

    private static func cacheFiles(in directory: String) -> [WallpaperTarget] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        var targets: [WallpaperTarget] = []
        for name in names.sorted() {
            let path = directory + "/" + name
            var st = stat()
            guard lstat(path, &st) == 0, (st.st_mode & UInt16(S_IFMT)) == UInt16(S_IFREG) else { continue }
            guard name.lowercased().hasSuffix(".cpbitmap") else { continue }
            targets.append(WallpaperTarget(path: path,
                                           fileName: name,
                                           appearance: WQWhitelist.appearance(of: name),
                                           byteCount: Int(st.st_size)))
        }
        return targets
    }

    /// Bounded inode walk. Only reached when the direct query is unavailable.
    private func scanForContainer() -> String? {
        var found: String?
        var candidates = 0
        var identified = 0
        var sample: [String] = []

        _ = CCScanApplicationContainers(scanBudget) { path in
            candidates += 1
            guard let identifier = CCContainerIdentifier(path) else {
                return false   // could not read this one's identifier
            }
            identified += 1
            if sample.count < 3 { sample.append(identifier) }
            if identifier == WQWhitelist.carPlayWallpaperBundleID,
               WQWhitelist.isAllowedContainer(path, identifier: identifier) {
                found = path
                return true
            }
            return false
        }

        // The two failure modes are completely different, so log them apart:
        //  - identified == 0  -> xattr is unreadable, scanning can never work
        //  - identified > 0   -> xattr works, CarPlayWallpaper just isn't there
        CCLog.info("scan: \(candidates) candidates, \(identified) identified")
        if identified == 0 && candidates > 0 {
            CCLog.error("scan: identifiers unreadable on this build; enumeration/query required")
        } else if !sample.isEmpty {
            CCLog.info("scan sample ids: \(sample.joined(separator: ", "))")
        }
        CCLog.info("scan result: \(found ?? "none")")
        return found
    }

    func findCacheFiles() throws -> [WallpaperTarget] {
        try resolve().files
    }
}
