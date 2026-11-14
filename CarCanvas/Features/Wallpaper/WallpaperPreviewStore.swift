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
    }

    @Published private(set) var darkImage: CGImage?
    @Published private(set) var lightImage: CGImage?
    @Published private(set) var isSearching = false
    @Published private(set) var wallpaperName: String?
    @Published private(set) var cacheDirectory: String?

    private let settings = SettingsStore.shared

    var hasPreview: Bool { darkImage != nil || lightImage != nil }

    func beginSearching() { isSearching = true }

    /// Applies a result produced off the main actor.
    func apply(_ loaded: Loaded) {
        darkImage = loaded.dark
        lightImage = loaded.light
        wallpaperName = loaded.wallpaperName
        cacheDirectory = loaded.cacheDirectory
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
    nonisolated static func loadFromDevice() -> Loaded {
        do {
            let resolved = try ContainerResolver().resolve()
            let dark = resolved.files.first { $0.isDark }
            let light = resolved.files.first { $0.isLight }
            let service = WallpaperService()

            let name = (dark ?? light)?.fileName
                .replacingOccurrences(of: "-Dark-", with: "-")
                .replacingOccurrences(of: "-Light-", with: "-")

            return Loaded(dark: dark.flatMap { service.previewImage(for: $0, resolved: resolved) },
                          light: light.flatMap { service.previewImage(for: $0, resolved: resolved) },
                          wallpaperName: name,
                          cacheDirectory: resolved.cacheDirectory)
        } catch {
            CCLog.info("preview load: \(error.localizedDescription)")
            return Loaded(dark: nil, light: nil, wallpaperName: nil, cacheDirectory: nil)
        }
    }
}
