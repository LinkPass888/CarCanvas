import Foundation
import Darwin

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

    /// Log-only forensics for the one question the refused routes leave open:
    /// does the CarPlayWallpaper container itself record which wallpaper
    /// identifier belongs to which vehicle?
    ///
    /// It reads only the fixed whitelist entries through the container
    /// extension that is already granted, and logs paths, sizes, kinds and
    /// plist key paths. Values are never logged, and nothing here is returned
    /// to the UI, so a pasted session log carries no vehicle name and no image.
    static func diagnoseContainerContents() {
        let container: String
        do {
            container = try ContainerResolver().resolve().containerPath
        } catch {
            CCLog.error("container forensics skipped: no verified container (\(error.localizedDescription))")
            return
        }
        for bundleID in WQWhitelist.carPlayRelatedBundleIDs {
            CCLog.info("container forensics: \(bundleID) data container = \(CCContainerPathForBundleID(bundleID) ?? "none")")
        }
        do {
            try WQAccess.shared.withAccess(containerPath: container) { () -> Void in
                for relative in WQWhitelist.containerDiagnosticDirectories {
                    logEntries(relative: relative, in: container)
                }
                for relative in WQWhitelist.containerDiagnosticFiles {
                    logFile(relative: relative, in: container)
                }
            }
        } catch {
            CCLog.error("container forensics failed: \(error.localizedDescription)")
        }
    }

    /// Entry names only, bounded: this text is meant to be pasted into a report.
    private static func logEntries(relative: String, in container: String) {
        let directory = container + "/" + relative
        guard WQWhitelist.isAllowedContainerDiagnosticDirectory(directory, in: container) else {
            CCLog.error("container forensics: refused directory \(relative)")
            return
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            CCLog.info("container forensics: \(relative) is not listable")
            return
        }
        let sample = names.sorted().prefix(40).joined(separator: ", ")
        CCLog.info("container forensics: \(relative) has \(names.count) entries: \(sample)")
    }

    /// Kind, size, and for a bounded regular plist its key paths.
    private static func logFile(relative: String, in container: String) {
        let path = container + "/" + relative
        guard WQWhitelist.isAllowedContainerDiagnosticFile(path, in: container) else {
            CCLog.error("container forensics: refused file \(relative)")
            return
        }
        var info = stat()
        guard lstat(path, &info) == 0 else {
            CCLog.info("container forensics: \(relative) absent (errno \(errno))")
            return
        }
        guard (info.st_mode & UInt16(S_IFMT)) == UInt16(S_IFREG) else {
            CCLog.info("container forensics: \(relative) is not a regular file")
            return
        }
        CCLog.info("container forensics: \(relative) is a \(info.st_size)-byte file")
        guard info.st_size > 0, info.st_size <= 256 * 1024,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return }
        var lines: [String] = []
        describe(plist, at: "root", depth: 3, into: &lines)
        for line in lines { CCLog.info("container forensics: \(relative) \(line)") }
    }

    /// Key paths, container kinds and counts only; values stay unread by the log.
    private static func describe(_ value: Any, at path: String, depth: Int, into lines: inout [String]) {
        guard lines.count < 60 else { return }
        if let dictionary = value as? [String: Any] {
            lines.append("\(path): dict(\(dictionary.count))")
            guard depth > 0 else { return }
            for key in dictionary.keys.sorted() {
                if let child = dictionary[key] { describe(child, at: "\(path).\(key)", depth: depth - 1, into: &lines) }
            }
        } else if let array = value as? [Any] {
            lines.append("\(path): array(\(array.count))")
            guard depth > 0, let first = array.first else { return }
            describe(first, at: "\(path)[0]", depth: depth - 1, into: &lines)
        } else if let string = value as? String {
            lines.append("\(path): string(\(string.count))")
        } else if let data = value as? Data {
            lines.append("\(path): data(\(data.count))")
        } else if let number = value as? NSNumber {
            let kind = String(cString: number.objCType) == "c" ? "bool" : "number"
            lines.append("\(path): \(kind)")
        } else {
            lines.append("\(path): other")
        }
    }
}

