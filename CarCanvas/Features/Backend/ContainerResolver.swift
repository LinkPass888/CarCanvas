import Foundation
import Darwin

/// Finds the CarPlayWallpaper data container without exposing a general
/// container browser.
///
/// Two things make this fast enough to be usable:
///  1. The container identifier is read from the container's xattr, which does
///     NOT require a sandbox extension. So the scan can identify the right
///     container before consuming anything.
///  2. The inode walk is bounded (probe-file inode + margin, with a time
///     budget) instead of scanning the whole volume, and it looks at one root
///     instead of trying two path prefixes.
final class ContainerResolver {
    struct Resolved {
        let containerPath: String
        let cacheDirectory: String
        let files: [WallpaperTarget]
    }

    /// Wallpaper caches are small; one pass is quick on real devices.
    private let scanBudget: TimeInterval = 20

    private func candidateContainers() -> [String] {
        var results: [String] = []
        _ = CCScanApplicationContainers(scanBudget) { path in
            results.append(path)
            // Keep scanning: we need the CarPlayWallpaper one, and we cannot
            // know which it is without reading the identifier.
            return false
        }
        return results
    }

    /// Resolves the container. The identifier comes from the container's own
    /// xattr, so no extension is consumed until we know it is the right one.
    func resolve() throws -> Resolved {
        try WQAccess.shared.preflight()

        var container: String?
        _ = CCScanApplicationContainers(scanBudget) { path in
            guard let identifier = CCContainerIdentifier(path) else { return false }
            if identifier == WQWhitelist.carPlayWallpaperBundleID,
               WQWhitelist.isAllowedContainer(path, identifier: identifier) {
                container = path
                return true   // found it: stop the scan early
            }
            return false
        }
        guard let containerPath = container else { throw CCError.cacheNotFound }

        let cacheDirectory = containerPath + "/" + WQWhitelist.cacheRelativePath
        guard WQWhitelist.isAllowedCacheDirectory(cacheDirectory) else {
            throw CCError.outsideWhitelist(cacheDirectory)
        }

        let files = try WQAccess.shared.withAccess(containerPath: containerPath) {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: cacheDirectory) else {
                throw CCError.cacheNotFound
            }
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
        guard !files.isEmpty else { throw CCError.noCacheFiles }
        return Resolved(containerPath: containerPath, cacheDirectory: cacheDirectory, files: files)
    }

    /// Cheaper path used by the browser/preview: locate the cache directories
    /// and files but skip building the full model when the caller only wants a
    /// template. Kept separate so the UI can show progress.
    func findCacheFiles() throws -> [WallpaperTarget] {
        try resolve().files
    }
}
