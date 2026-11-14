import Foundation
import Combine

/// The CarPlay device list shown in the original Wallpaper screen.
///
/// Read from the single allowed preference file. Any failure is reported as
/// "no devices", which is exactly what the original screen did, and never as
/// an empty screen with no explanation.
final class CarPlayDeviceStore: ObservableObject {
    struct Device: Identifiable, Hashable {
        let id: String
        let name: String
    }

    @Published private(set) var devices: [Device] = []
    @Published private(set) var isSearching = false

    private let defaults = UserDefaults.standard
    private let selectedKey = "CCSelectedCarPlayDevice"

    var selectedDeviceID: String? {
        get { defaults.string(forKey: selectedKey) }
        set { defaults.set(newValue, forKey: selectedKey) }
    }

    func refresh() {
        isSearching = true
        defer { isSearching = false }
        do {
            devices = try readDevices()
        } catch {
            CCLog.info("CarPlay device list unavailable: \(error.localizedDescription)")
            devices = []
        }
        if let selected = selectedDeviceID, !devices.contains(where: { $0.id == selected }) {
            selectedDeviceID = devices.first?.id
        }
    }

    private func readDevices() throws -> [Device] {
        try WQAccess.shared.withCarPlayPreferences { data in
            guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
                  let root = plist as? [String: Any] else { return [] }

            // The file stores pairings as a dictionary keyed by a device
            // identifier; the display name is not guaranteed to be present, so
            // fall back to the key itself.
            guard let pairings = root["pairings"] as? [String: Any] else { return [] }

            return pairings.compactMap { key, value in
                let entry = value as? [String: Any]
                let name = (entry?["name"] as? String)
                    ?? (entry?["displayName"] as? String)
                    ?? (entry?["carName"] as? String)
                    ?? key
                guard !name.isEmpty else { return nil }
                return Device(id: key, name: name)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }
}
