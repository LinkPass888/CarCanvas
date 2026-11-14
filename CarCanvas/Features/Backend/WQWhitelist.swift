import Foundation

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

    /// Exactly one preference file, read-only, for the CarPlay pairing list.
    /// No directory is granted: only this file.
    static let carPlayPreferencesPath = "/var/mobile/Library/Preferences/com.apple.carplay.plist"

    /// The one preference file, accepted under either path spelling.
    static func isAllowedCarPlayPreferences(_ path: String) -> Bool {
        path == carPlayPreferencesPath || path == "/private" + carPlayPreferencesPath
    }

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

    static func appearance(of fileName: String) -> WallpaperTarget.Appearance {
        if fileName.contains("-Dark-") || fileName.hasSuffix("-Dark.cpbitmap") { return .dark }
        if fileName.contains("-Light-") || fileName.hasSuffix("-Light.cpbitmap") { return .light }
        return .unknown
    }
}
