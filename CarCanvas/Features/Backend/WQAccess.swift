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

    /// Fails closed on unsupported OS versions before touching any
    /// ContainerManager symbol.
    func preflight() throws {
        try WQCompatibility.requireSupported()
    }

    /// Worse_query needs an App Group because it swaps that group's Caches
    /// directory. The direct ContainerManager query does not, so the group is
    /// only required on the path that actually calls worse_query.
    func requireAppGroup() throws -> String {
        try preflight()
        guard let group = appGroupIdentifier,
              FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) != nil else {
            throw CCError.appGroupUnavailable(entitledGroups.isEmpty
                                              ? "no com.apple.security.application-groups entitlement"
                                              : entitledGroups.joined(separator: ", "))
        }
        return group
    }

    /// Scoped read of the single allowed CarPlay preference file. No directory
    /// is ever granted, so this cannot be widened into a general file read.
    func withCarPlayPreferences<T>(_ body: (Data) throws -> T) throws -> T {
        let group = try requireAppGroup()
        let path = WQWhitelist.carPlayPreferencesPath
        guard WQWhitelist.isAllowedCarPlayPreferences(path) else {
            throw CCError.outsideWhitelist(path)
        }
        let is26 = WQCompatibility.current.majorVersion == 26
        // create_dir is false: the file must already exist.
        CCLog.info("prefs query: group=\(group) altFlags=\(is26)")
        let handle = worse_query(path, group, is26, false)
        CCLog.info("prefs query handle=\(handle)")
        guard handle >= 0 else { throw CCError.accessFailed(handle) }
        defer { worse_query_release(handle) }

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            CCLog.error("prefs file unreadable after token")
            throw CCError.templateUnreadable("com.apple.carplay.plist")
        }
        return try body(data)
    }

    private var retainedHandle: Int64 = -1

    /// Keeps a container extension alive for the process lifetime. Used for the
    /// handle ContainerManager already handed us, so we do not immediately ask
    /// for a second extension for the same container.
    func retainContainerHandle(_ handle: Int64) {
        guard handle >= 0, retainedHandle < 0 else {
            if handle >= 0 { worse_query_release(handle) }
            return
        }
        retainedHandle = handle
    }

    /// Consumes a sandbox extension for a container that the scanner has
    /// already identified as `com.apple.CarPlayWallpaper`.
    ///
    /// The identifier check is NOT repeated here: the metadata plist lives
    /// outside our sandbox and is only reachable through the scanner's bounded
    /// enumeration, so re-reading it at this point would always fail and reject
    /// a perfectly valid container. The path whitelist is still enforced.
    private func consume(containerPath: String) throws -> Int64 {
        let group = try requireAppGroup()
        guard WQWhitelist.isAllowedContainer(containerPath,
                                             identifier: WQWhitelist.carPlayWallpaperBundleID) else {
            throw CCError.outsideWhitelist(containerPath)
        }
        // iOS 26.x App Group containers need the alternate flag set; iOS 27
        // rejects it. This is the only place alt_flags is decided.
        let is26 = WQCompatibility.current.majorVersion == 26
        CCLog.info("container query: group=\(group) altFlags=\(is26) path=\(containerPath)")
        let handle = worse_query(containerPath, group, is26, false)
        CCLog.info("container query handle=\(handle)")
        guard handle >= 0 else { throw CCError.accessFailed(handle) }
        return handle
    }

    /// The one scoped entry point. The closure runs while the extension is
    /// consumed; the handle is released unconditionally afterwards.
    func withAccess<T>(containerPath: String, _ body: () throws -> T) throws -> T {
        try preflight()
        let handle = try consume(containerPath: containerPath)
        defer { worse_query_release(handle) }
        return try body()
    }
}
