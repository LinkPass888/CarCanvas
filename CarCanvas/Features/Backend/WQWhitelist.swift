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

    /// Cache files may only match this shape. The numeric suffix (-14 etc.)
    /// varies between devices, so we accept digits but nothing else.
    private static let cacheFilePattern = #"^CARWallpaper[A-Za-z]+-(Dark|Light)-\d+\.cpbitmap$"#

    /// A container directory is acceptable only if it resolves to the
    /// CarPlayWallpaper data container. `identifier` comes from the
    /// container metadata plist, not from user input.
    static func isAllowedContainer(_ path: String, identifier: String) -> Bool {
        guard identifier == carPlayWallpaperBundleID else { return false }
        return allowedContainerPrefixes.contains { prefix in
            path.hasPrefix(prefix + "/") && !path.contains("..")
        }
    }

    static func isAllowedCacheDirectory(_ path: String) -> Bool {
        guard allowedContainerPrefixes.contains(where: { path.hasPrefix($0 + "/") }),
              !path.contains("..") else { return false }
        return path.hasSuffix("/" + cacheRelativePath)
    }

    static func isAllowedCacheFile(_ path: String, in cacheDirectory: String) -> Bool {
        guard isAllowedCacheDirectory(cacheDirectory),
              path.hasPrefix(cacheDirectory + "/"),
              !path.contains("..") else { return false }
        let name = (path as NSString).lastPathComponent
        guard let regex = try? NSRegularExpression(pattern: cacheFilePattern) else { return false }
        let range = NSRange(name.startIndex..., in: name)
        return regex.firstMatch(in: name, range: range) != nil
    }

    static func appearance(of fileName: String) -> WallpaperTarget.Appearance {
        if fileName.contains("-Dark-") { return .dark }
        if fileName.contains("-Light-") { return .light }
        return .unknown
    }
}
