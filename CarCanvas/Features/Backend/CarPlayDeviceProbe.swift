import Foundation

/// Answers one narrow question: has this iPhone ever paired with a CarPlay
/// device? It reads a single whitelisted preference file through the scoped
/// extension. It does NOT look for wallpaper caches.
///
/// That distinction matters: connecting CarPlay is not the same as opening
/// CarPlay Settings > Wallpaper and picking the six patterned wallpapers. The
/// cache files only appear after the latter, so the UI must never say
/// "no CarPlay device" just because the cache is missing.
enum CarPlayDeviceProbe {
    enum State {
        case paired(count: Int)
        case notPaired
        case unknown(String)
    }

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

    static func probe() -> State {
        do {
            let count = try WQAccess.shared.withCarPlayPreferences { data -> Int in
                guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
                      let root = plist as? [String: Any],
                      let pairings = root["pairings"] as? [String: Any] else { return 0 }
                return pairings.count
            }
            return count > 0 ? .paired(count: count) : .notPaired
        } catch {
            CCLog.info("CarPlay pairing probe: \(error.localizedDescription)")
            return .unknown(error.localizedDescription)
        }
    }
}
