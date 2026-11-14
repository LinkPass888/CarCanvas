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
