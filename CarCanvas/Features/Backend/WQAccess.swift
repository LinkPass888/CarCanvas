import Foundation
import Darwin

/// Narrow Objective-C bridge to the GPL-3.0 `worse_query` primitive.
///
/// Design rules:
///  * `withAccess` is the ONLY way to obtain an extension handle.
///  * Callers cannot pass an arbitrary path: only `WQWhitelist` roots are
///    accepted, and every candidate is re-validated before use.
///  * The App Group is read from this app's own code signature at runtime,
///    the same way WQFiles and Regitela do it. Whichever group the signing
///    tool embedded is the one used, so the group name does not matter and
///    the entitlements file needs no editing.
///  * The handle is always released in `defer`, even on error.
///  * No path is persisted, logged, or exposed through the UI.
final class WQAccess {
    static let shared = WQAccess()
    private init() {}

    /// Populated at first use from the signature. `nil` means the build was
    /// signed without an App Group (Sideloadly, wildcard profile, ...).
    private(set) lazy var appGroupIdentifier: String? = CCAppGroupIdentifier()

    /// Every group listed in the signature, for the diagnostics panel.
    var entitledGroups: [String] { CCAppGroupEntitledIdentifiers() }

    /// Fails closed on unsupported OS versions and a missing App Group before
    /// touching any ContainerManager symbol.
    func preflight() throws {
        try WQCompatibility.requireSupported()
        guard let group = appGroupIdentifier,
              FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) != nil else {
            throw CCError.appGroupUnavailable(entitledGroups.isEmpty
                                              ? "no com.apple.security.application-groups entitlement"
                                              : entitledGroups.joined(separator: ", "))
        }
        // An interrupted previous run can leave Library/Caches as a symlink,
        // which makes every subsequent query fail. Restore it first.
        if let group = appGroupIdentifier {
            var error: NSError?
            if !CCAppGroupResetCachesDirectory(group, &error) {
                CCLog.error("App Group cache reset failed: \(error?.localizedDescription ?? "unknown")")
            }
        }
    }

    /// Validates a container candidate then consumes a sandbox extension for it.
    private func consume(containerPath: String) throws -> Int64 {
        guard let group = appGroupIdentifier else {
            throw CCError.appGroupUnavailable("no com.apple.security.application-groups entitlement")
        }
        // Read the container's own metadata plist and compare, so a caller
        // cannot bypass validation by passing an expected constant for an
        // unrelated container.
        let metadata = (containerPath as NSString)
            .appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: metadata)),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any],
              let actual = dict["MCMMetadataIdentifier"] as? String,
              actual == WQWhitelist.carPlayWallpaperBundleID else {
            throw CCError.outsideWhitelist(containerPath)
        }
        guard WQWhitelist.isAllowedContainer(containerPath, identifier: actual) else {
            throw CCError.outsideWhitelist(containerPath)
        }
        // iOS 26.x App Group containers need the alternate flag set; iOS 27
        // rejects it. This is the only place alt_flags is decided.
        let is26 = WQCompatibility.current.majorVersion == 26
        let handle = worse_query(containerPath, group, is26, false)
        guard handle >= 0 else { throw CCError.accessFailed(handle) }
        return handle
    }

    /// The one scoped entry point for the CarPlayWallpaper container.
    /// The closure runs while the extension is consumed; the handle is
    /// released unconditionally afterwards.
    func withAccess<T>(containerPath: String, _ body: () throws -> T) throws -> T {
        try preflight()
        let handle = try consume(containerPath: containerPath)
        defer { worse_query_release(handle) }
        return try body()
    }

    /// Scoped read of the single allowed preference file. No directory is ever
    /// granted, so this cannot be widened into a general file read.
    func withCarPlayPreferences<T>(_ body: (Data) throws -> T) throws -> T {
        try preflight()
        guard let group = appGroupIdentifier else {
            throw CCError.appGroupUnavailable("no com.apple.security.application-groups entitlement")
        }
        let path = WQWhitelist.carPlayPreferencesPath
        guard WQWhitelist.isAllowedCarPlayPreferences(path) else {
            throw CCError.outsideWhitelist(path)
        }
        let is26 = WQCompatibility.current.majorVersion == 26
        // create_dir is false: the file must already exist.
        let handle = worse_query(path, group, is26, false)
        guard handle >= 0 else { throw CCError.accessFailed(handle) }
        defer { worse_query_release(handle) }

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            throw CCError.templateUnreadable("com.apple.carplay.plist")
        }
        return try body(data)
    }
}
