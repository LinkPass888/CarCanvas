import Foundation

/// Reads saved CarPlay devices and their explicit wallpaper references.
///
/// Two routes, narrowest first:
/// 1. cfprefsd, through `UserDefaults`. Reading a preference *domain* asks the
///    daemon for the value; it does not open the plist, so no sandbox extension
///    is involved and no file under someone else's container is touched.
/// 2. The scoped extension on the one whitelisted preference file. That route
///    exists but is known to be refused on iOS 26/27 (the extension is
///    container-scoped, and this plist is not inside a container), so it is a
///    fallback rather than the primary.
///
/// Missing caches never imply no pairing, and a refused read of either route is
/// never reported as "no devices".
enum CarPlayDeviceProbe {
    /// Preferences domain holding CarPlay's pairing list.
    static let preferencesDomain = "com.apple.carplay"

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
        if let pairings = pairingsFromPreferencesDomain() {
            CCLog.info("carplay pairings via cfprefsd: \(pairings.count)")
            return devices(from: pairings)
        }
        CCLog.info("cfprefsd returned no carplay pairings; falling back to the scoped file read")
        return try WQAccess.shared.withCarPlayPreferences { data in
            guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
                  let root = plist as? [String: Any] else {
                throw NSError(domain: "CarCanvas.Vehicle", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: L("VEHICLE_RECORDS_UNAVAILABLE")])
            }
            let pairings = root["pairings"] as? [String: Any] ?? [:]
            CCLog.info("carplay pairings via preference file: \(pairings.count)")
            return devices(from: pairings)
        }
    }

    /// nil means the daemon served no value for this domain, which is not the
    /// same as a readable domain holding zero pairings: the caller decides.
    private static func pairingsFromPreferencesDomain() -> [String: Any]? {
        guard let defaults = UserDefaults(suiteName: preferencesDomain),
              let value = defaults.object(forKey: "pairings") else { return nil }
        return value as? [String: Any] ?? [:]
    }

    private static func devices(from pairings: [String: Any]) -> [Device] {
        pairings.keys.sorted().enumerated().compactMap { index, id in
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

