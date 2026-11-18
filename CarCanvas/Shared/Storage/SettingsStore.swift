import Foundation
import Combine
import CoreGraphics

/// Settings used by the cache editor. Old export-name defaults stay untouched.
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    struct CropSize: Equatable {
        let width: Int
        let height: Int

        static let maxDimension = 16_384
        static let maxPixels = 32 * 1024 * 1024

        init?(width: Int, height: Int) {
            guard (1...Self.maxDimension).contains(width),
                  (1...Self.maxDimension).contains(height),
                  width * height <= Self.maxPixels else { return nil }
            self.width = width
            self.height = height
        }

        var cgSize: CGSize { CGSize(width: CGFloat(width), height: CGFloat(height)) }
    }

    @Published var channelOrder: CPBitmapTemplate.ChannelOrder {
        didSet { defaults.set(channelOrder.rawValue, forKey: Keys.channelOrder) }
    }
    @Published var hasSeenGuide: Bool {
        didSet { defaults.set(hasSeenGuide, forKey: Keys.guide) }
    }
    @Published var customCropSize: CropSize? {
        didSet {
            if let customCropSize {
                defaults.set(customCropSize.width, forKey: Keys.cropWidth)
                defaults.set(customCropSize.height, forKey: Keys.cropHeight)
            } else {
                defaults.removeObject(forKey: Keys.cropWidth)
                defaults.removeObject(forKey: Keys.cropHeight)
            }
        }
    }

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let channelOrder = "CCChannelOrder"
        static let guide = "CCHasSeenGuide"
        static let cropWidth = "CCCustomCropWidth"
        static let cropHeight = "CCCustomCropHeight"
    }

    private init() {
        let raw = defaults.string(forKey: Keys.channelOrder) ?? CPBitmapTemplate.ChannelOrder.bgra.rawValue
        channelOrder = CPBitmapTemplate.ChannelOrder(rawValue: raw) ?? .bgra
        hasSeenGuide = defaults.bool(forKey: Keys.guide)
        if let width = defaults.object(forKey: Keys.cropWidth) as? Int,
           let height = defaults.object(forKey: Keys.cropHeight) as? Int,
           let saved = CropSize(width: width, height: height) {
            customCropSize = saved
        } else {
            customCropSize = nil
        }
    }

}
