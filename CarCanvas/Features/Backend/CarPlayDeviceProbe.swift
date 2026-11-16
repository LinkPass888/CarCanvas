import Foundation

/// Reads saved CarPlay devices and their explicit wallpaper references through
/// the scoped preference-file extension. Missing caches never imply no pairing.
enum CarPlayDeviceProbe {
    struct Device: Identifiable {
        let id: String
        let name: String
        let wallpaperIdentifier: String?

        // Only direct references from the saved pairing record. Do not guess
        // which vehicle owns a numeric cache suffix or a screen resolution.
        var cacheFileNames: Set<String> {
            guard let wallpaperIdentifier else { return [] }
            return [wallpaperIdentifier + "-Dark.cpbitmap", wallpaperIdentifier + "-Light.cpbitmap"]
        }
    }

    static func devices() throws -> [Device] {
        try WQAccess.shared.withCarPlayPreferences { data in
            guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
                  let root = plist as? [String: Any] else {
                throw NSError(domain: "CarCanvas.Vehicle", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: L("VEHICLE_RECORDS_UNAVAILABLE")])
            }
            guard let pairings = root["pairings"] as? [String: Any] else { return [] }
            return pairings.keys.sorted().enumerated().compactMap { index, id in
                guard let record = pairings[id] as? [String: Any] else { return nil }
                let name = (record["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let identifier = ["wallpaperIdentifierUserPreference", "wallpaperIdentifier"]
                    .compactMap { (record[$0] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty }
                return Device(id: id, name: name.isEmpty ? LF("VEHICLE_UNNAMED", index + 1) : name,
                              wallpaperIdentifier: identifier)
            }
        }
    }

}
