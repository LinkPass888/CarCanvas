import Foundation
import Combine

/// Settings used by the cache editor. Old export-name defaults stay untouched.
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var channelOrder: CPBitmapTemplate.ChannelOrder {
        didSet { defaults.set(channelOrder.rawValue, forKey: Keys.channelOrder) }
    }
    @Published var hasSeenGuide: Bool {
        didSet { defaults.set(hasSeenGuide, forKey: Keys.guide) }
    }

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let channelOrder = "CCChannelOrder"
        static let guide = "CCHasSeenGuide"
    }

    private init() {
        let raw = defaults.string(forKey: Keys.channelOrder) ?? CPBitmapTemplate.ChannelOrder.bgra.rawValue
        channelOrder = CPBitmapTemplate.ChannelOrder(rawValue: raw) ?? .bgra
        hasSeenGuide = defaults.bool(forKey: Keys.guide)
    }

}
