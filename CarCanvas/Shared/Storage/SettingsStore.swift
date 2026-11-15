import Foundation
import Combine

final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var exportBaseName: String {
        didSet { defaults.set(exportBaseName, forKey: Keys.exportBaseName) }
    }
    @Published var channelOrder: CPBitmapTemplate.ChannelOrder {
        didSet { defaults.set(channelOrder.rawValue, forKey: Keys.channelOrder) }
    }
    @Published var hasSeenGuide: Bool {
        didSet { defaults.set(hasSeenGuide, forKey: Keys.guide) }
    }

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let exportBaseName = "CCExportBaseName"
        static let channelOrder = "CCChannelOrder"
        static let guide = "CCHasSeenGuide"
    }

    private init() {
        exportBaseName = defaults.string(forKey: Keys.exportBaseName) ?? "CarCanvas"
        let raw = defaults.string(forKey: Keys.channelOrder) ?? CPBitmapTemplate.ChannelOrder.bgra.rawValue
        channelOrder = CPBitmapTemplate.ChannelOrder(rawValue: raw) ?? .bgra
        hasSeenGuide = defaults.bool(forKey: Keys.guide)
    }

    func clearSavedData() {
        for key in [Keys.exportBaseName, Keys.channelOrder] {
            defaults.removeObject(forKey: key)
        }
        exportBaseName = "CarCanvas"
        channelOrder = .bgra
    }
}
