import Foundation
import Darwin

/// Finds the CarPlayWallpaper data container without exposing a general
/// container browser. Enumeration is bounded and every candidate is
/// validated against the static whitelist.
final class ContainerResolver {
    struct Resolved {
        let containerPath: String
        let cacheDirectory: String
        let files: [WallpaperTarget]
    }

    private let metadataName = ".com.apple.mobile_container_manager.metadata.plist"
    private let metadataKey = "MCMMetadataIdentifier"

    /// Uses `pathleak` (bounded inode enumeration) to list first-level
    /// children of the application data container root. The root itself is
    /// held constant — no user-supplied enumeration target exists.
    private func candidateContainers() -> [String] {
        let baseline = FileManager.default.temporaryDirectory
            .appendingPathComponent(".cc-baseline-\(UUID().uuidString)")
        var maxInode: UInt64 = 0
        do {
            try "baseline".write(to: baseline, atomically: true, encoding: .utf8)
            var st = stat()
            if stat(baseline.path, &st) == 0 { maxInode = UInt64(st.st_ino) }
            try? FileManager.default.removeItem(at: baseline)
        } catch { return [] }
        guard maxInode > 0 else { return [] }

        var results: [String] = []
        for prefix in WQWhitelist.allowedContainerPrefixes {
            guard let found = pathleak(prefix, maxInode) else { continue }
            results.append(contentsOf: found)
        }
        return Array(Set(results)).sorted()
    }

    private func identifier(for container: String) -> String? {
        let url = URL(fileURLWithPath: container).appendingPathComponent(metadataName)
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any] else { return nil }
        return dict[metadataKey] as? String
    }

    /// Returns the single whitelisted container plus its existing cache
    /// files. Never creates files and never follows symlinks out of scope.
    func resolve() throws -> Resolved {
        try WQAccess.shared.preflight()

        let candidates = candidateContainers().filter { candidate in
            WQWhitelist.allowedContainerPrefixes.contains { prefix in
                candidate.hasPrefix(prefix + "/") && !candidate.contains("..")
            }
        }
        guard let container = candidates.first(where: { candidate in
            guard let id = identifier(for: candidate) else { return false }
            return WQWhitelist.isAllowedContainer(candidate, identifier: id)
        }) else { throw CCError.cacheNotFound }

        let cacheDirectory = container + "/" + WQWhitelist.cacheRelativePath
        guard WQWhitelist.isAllowedCacheDirectory(cacheDirectory) else {
            throw CCError.outsideWhitelist(cacheDirectory)
        }

        let files = try WQAccess.shared.withAccess(containerPath: container,
                                                   identifier: WQWhitelist.carPlayWallpaperBundleID) {
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
        return Resolved(containerPath: container, cacheDirectory: cacheDirectory, files: files)
    }
}
