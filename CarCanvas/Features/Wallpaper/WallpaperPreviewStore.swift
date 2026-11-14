import Foundation
import Combine
import CoreGraphics

/// Holds the two preview images the original Wallpaper screen showed: one for
/// the Dark cache file and one for the Light cache file.
///
/// Both come from the *same* picked image — the original app had a single picker
/// and no image processing at all — so the two previews differ only in which
/// cache file they represent.
final class WallpaperPreviewStore: ObservableObject {
    struct Loaded {
        var dark: CGImage?
        var light: CGImage?
        var wallpaperName: String?
        var cacheDirectory: String?
        var hasCacheFiles = false
        var pairings = 0
        var pairingProbeFailed = false
    }

    @Published private(set) var darkImage: CGImage?
    @Published private(set) var lightImage: CGImage?
    @Published private(set) var isSearching = false
    @Published private(set) var wallpaperName: String?
    @Published private(set) var cacheDirectory: String?
    @Published private(set) var hasCacheFiles = false
    @Published private(set) var pairings = 0
    @Published private(set) var pairingProbeFailed = false

    private let settings = SettingsStore.shared

    var hasPreview: Bool { darkImage != nil || lightImage != nil }

    func beginSearching() { isSearching = true }

    /// Publishes the previews first and the pairing count afterwards is not
    /// needed: the container answer is what matters, and it must clear the
    /// spinner as soon as it is known.
    func finishSearching() { isSearching = false }

    /// Applies a result produced off the main actor.
    func apply(_ loaded: Loaded) {
        darkImage = loaded.dark
        lightImage = loaded.light
        wallpaperName = loaded.wallpaperName
        cacheDirectory = loaded.cacheDirectory
        hasCacheFiles = loaded.hasCacheFiles
        pairings = loaded.pairings
        pairingProbeFailed = loaded.pairingProbeFailed
        isSearching = false
    }

    /// Shows the picked image in both slots, matching the original behaviour.
    func setPickedImage(_ image: CGImage) {
        darkImage = image
        lightImage = image
        wallpaperName = settings.exportBaseName
    }

    /// Reads whatever the device already has. Safe to call off the main actor:
    /// it only returns values and touches no published property.
    ///
    /// Device pairing and the wallpaper cache are probed separately. Connecting
    /// CarPlay does NOT create the cache files — those appear only after the
    /// six patterned wallpapers have been picked in CarPlay Settings.
    nonisolated static func loadFromDevice(forceRefresh: Bool = false) -> Loaded {
        var result = Loaded()

        // Do the container work first, then probe pairings. Both use
        // worse_query's Caches swap; running them back-to-back in the other
        // order can leave the second one reading a half-restored symlink.
        do {
            let resolved = try ContainerResolver().resolve(forceRefresh: forceRefresh)
            let dark = resolved.files.first { $0.isDark }
            let light = resolved.files.first { $0.isLight }
            let service = WallpaperService()

            result.cacheDirectory = resolved.cacheDirectory
            result.hasCacheFiles = !resolved.files.isEmpty
            result.wallpaperName = (dark ?? light)?.fileName
                .replacingOccurrences(of: "-Dark-", with: "-")
                .replacingOccurrences(of: "-Light-", with: "-")
            result.dark = dark.flatMap { service.previewImage(for: $0, resolved: resolved) }
            result.light = light.flatMap { service.previewImage(for: $0, resolved: resolved) }
        } catch {
            CCLog.info("preview load: \(error.localizedDescription)")
        }

        switch CarPlayDeviceProbe.probe() {
        case .paired(let count): result.pairings = count
        case .notPaired: result.pairings = 0
        case .unknown: result.pairingProbeFailed = true
        }
        return result
    }
}
