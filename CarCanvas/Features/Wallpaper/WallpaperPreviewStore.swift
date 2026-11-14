import Foundation
import Combine
import CoreGraphics

/// Only small previews live here; the independently picked originals stay in
/// temporary files until creation. A device refresh must not replace a pick.
@MainActor
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
    private var pickedDark = false
    private var pickedLight = false

    func beginSearching() { isSearching = true }

    func apply(_ loaded: Loaded) {
        if !pickedDark { darkImage = loaded.dark }
        if !pickedLight { lightImage = loaded.light }
        wallpaperName = loaded.wallpaperName
        cacheDirectory = loaded.cacheDirectory
        hasCacheFiles = loaded.hasCacheFiles
        pairings = loaded.pairings
        pairingProbeFailed = loaded.pairingProbeFailed
        isSearching = false
    }

    func setPickedImage(_ image: CGImage, appearance: WallpaperTarget.Appearance) {
        if appearance == .dark {
            pickedDark = true
            darkImage = image
        } else if appearance == .light {
            pickedLight = true
            lightImage = image
        }
    }

    nonisolated static func loadFromDevice(forceRefresh: Bool = false,
                                          channelOrder: CPBitmapTemplate.ChannelOrder = .bgra) -> Loaded {
        var result = Loaded()
        do {
            let resolved = try ContainerResolver().resolve(forceRefresh: forceRefresh)
            // Never pair the first Dark of one color/screen with another Light.
            let group = WallpaperGroup.make(from: resolved.files).first
            let service = WallpaperService(channelOrder: channelOrder)
            result.cacheDirectory = resolved.cacheDirectory
            result.hasCacheFiles = !resolved.files.isEmpty
            result.wallpaperName = group?.displayName
            result.dark = group?.dark.flatMap { service.previewImage(for: $0, resolved: resolved) }
            result.light = group?.light.flatMap { service.previewImage(for: $0, resolved: resolved) }
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
