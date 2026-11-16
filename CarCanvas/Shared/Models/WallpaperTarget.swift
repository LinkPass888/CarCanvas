import Foundation

/// A single cache file inside the whitelisted CarPlayWallpaper container.
struct WallpaperTarget: Identifiable, Hashable, Codable {
    enum Appearance: String, Codable { case dark, light, unknown }

    let path: String
    let fileName: String
    let appearance: Appearance
    let byteCount: Int
    var contentDigest: String? = nil

    var id: String { path }

    /// The whitelist uses only this bounded filename token, never a group.
    static func appearanceToken(in fileName: String) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: #"-(Dark|Light)(?=(?:-\d+)?\.cpbitmap$)"#) else { return nil }
        let matches = regex.matches(in: fileName, range: NSRange(fileName.startIndex..., in: fileName))
        return matches.count == 1 ? matches[0] : nil
    }
}

/// Errors are deliberately descriptive: the UI shows them verbatim rather
/// than silently falling back to an unsafe path.
enum CCError: LocalizedError {
    case unsupportedOS(String)
    case appGroupUnavailable(String)
    case outsideWhitelist(String)
    case cacheNotFound
    case noCacheFiles
    case accessFailed(Int64)
    case templateUnreadable(String)
    case unrecognizedTemplate(Int)
    case renderFailed
    case backupFailed
    case verificationFailed
    case nothingSelected

    var errorDescription: String? {
        switch self {
        case .unsupportedOS(let v):
            return "Unsupported iOS version: \(v). CarCanvas is fail-closed and will not touch containers."
        case .appGroupUnavailable(let g):
            return "App Group unavailable (\(g)). Sign the IPA with a profile that includes this entitlement."
        case .outsideWhitelist(let p):
            return "Refused path outside the CarPlayWallpaper whitelist: \(p)"
        case .cacheNotFound:        return L("WALLPAPER_CACHE_NOT_FOUND")
        case .noCacheFiles:         return L("BROWSER_WALLPAPER_CACHE_EMPTY")
        case .accessFailed(let c):  return "Container access failed (code \(c))."
        case .templateUnreadable(let p): return "Cannot read cache template: \(p)"
        case .unrecognizedTemplate(let n):
            return "Unrecognised CPBitmap template (\(n) bytes). Public format data is conflicting; verify on this device."
        case .renderFailed:         return "Could not render the image into the template geometry."
        case .backupFailed:         return "Backup failed; refusing to overwrite the original."
        case .verificationFailed:   return "Post-write size check failed; rolled back."
        case .nothingSelected:      return L("CACHE_EDIT_NOTHING_PENDING")
        }
    }
}
