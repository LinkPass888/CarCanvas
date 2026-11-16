import Foundation
import Darwin

/// The *only* paths this app is allowed to hand to the sandbox extension.
///
/// There is deliberately no user-editable path field, no arbitrary path
/// parameter in any public API, and no generic file browser. The whitelist
/// is static and reviewed as part of the security boundary.
enum WQWhitelist {
    static let carPlayWallpaperBundleID = "com.apple.CarPlayWallpaper"

    /// The single container root we are allowed to ask an extension for.
    static let allowedContainerPrefixes: [String] = [
        "/var/mobile/Containers/Data/Application",
        "/private/var/mobile/Containers/Data/Application"
    ]

    /// Relative suffix of the wallpaper image cache inside that container.
    static let cacheRelativePath = "Library/Caches/MappedImageCache/com.apple.CarPlayApp.wallpaper-images"

    /// The original app used `CARWallpaper<Color>-Dark.cpbitmap` /
    /// `-Light.cpbitmap`; READMEs also document a device-dependent `-14`
    /// variant before the extension. Accept both, and nothing else.
    private static let cacheFilePattern = #"^CARWallpaper[A-Za-z]+-(Dark|Light)(-\d+)?\.cpbitmap$"#

    /// Discovery accepts only a canonical, direct UUID child of Application.
    /// This is a path-shape check, not proof of the container's identity; the
    /// scoped probe separately checks directory type, inode and identifier.
    static func canonicalContainerPath(_ path: String) -> String? {
        let canonical = path.hasPrefix("/private/var/") ? String(path.dropFirst(8)) : path
        let prefix = allowedContainerPrefixes[0] + "/"
        guard canonical.hasPrefix(prefix) else { return nil }
        let name = String(canonical.dropFirst(prefix.count))
        guard let uuid = UUID(uuidString: name),
              uuid.uuidString.caseInsensitiveCompare(name) == .orderedSame else { return nil }
        return canonical
    }

    /// Final access additionally requires the exact CarPlay identifier from
    /// a query object or a scoped identity probe, never from a UI path field.
    static func isAllowedContainer(_ path: String, identifier: String) -> Bool {
        identifier == carPlayWallpaperBundleID && canonicalContainerPath(path) != nil
    }

    static func isAllowedCacheDirectory(_ path: String) -> Bool {
        let suffix = "/" + cacheRelativePath
        guard path.hasSuffix(suffix) else { return false }
        return canonicalContainerPath(String(path.dropLast(suffix.count))) != nil
    }

    static func isAllowedCacheFile(_ path: String, in cacheDirectory: String) -> Bool {
        guard isAllowedCacheDirectory(cacheDirectory),
              path.hasPrefix(cacheDirectory + "/"),
              !path.contains("..") else { return false }
        let name = (path as NSString).lastPathComponent
        guard path == cacheDirectory + "/" + name else { return false }
        guard let regex = try? NSRegularExpression(pattern: cacheFilePattern) else { return false }
        let range = NSRange(name.startIndex..., in: name)
        return regex.firstMatch(in: name, range: range) != nil
    }

    /// Filesystem validation is scoped, not merely lexical. Refuse symlinked
    /// intermediate directories. A genuinely absent fixed cache is valid empty
    /// state; permission errors and a replaced directory are never "empty".
    static func cacheDirectoryExists(_ directory: String) throws -> Bool {
        guard WQAccess.hasActiveExtensionOnCurrentThread,
              isAllowedCacheDirectory(directory) else { throw CCError.outsideWhitelist(directory) }
        let suffix = "/" + cacheRelativePath
        var current = String(directory.dropLast(suffix.count))
        for component in cacheRelativePath.split(separator: "/") {
            current += "/" + component
            var info = stat()
            guard lstat(current, &info) == 0 else {
                let code = errno
                if code == ENOENT { return false }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSLocalizedDescriptionKey: "Cache lstat failed (errno \(code))."])
            }
            guard (info.st_mode & UInt16(S_IFMT)) == UInt16(S_IFDIR) else { throw CCError.outsideWhitelist(current) }
        }
        return true
    }

    static func appearance(of fileName: String) -> WallpaperTarget.Appearance {
        guard let token = WallpaperTarget.appearanceToken(in: fileName),
              let range = Range(token.range(at: 1), in: fileName) else { return .unknown }
        return WallpaperTarget.Appearance(rawValue: fileName[range].lowercased()) ?? .unknown
    }
}
