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
        let handle = try acquire(path: path, group: group)
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

    /// Tries both flag sets and keeps whichever actually opens the target.
    ///
    /// A single fixed guess is not enough. iOS 26 prefers the alternate flags,
    /// but a token can be issued and consumed and still fail to open the path
    /// (WQFiles hit that on 27.0.1). `handle=-6` means the kernel refused to
    /// issue an extension at all, which the other flag set can sometimes fix.
    private func acquire(path: String, group: String) throws -> Int64 {
        let order: [Bool]
        if let known = WQAccess.preferredAltFlags {
            order = [known, !known]
        } else {
            order = [true, false]
        }

        var last: Int64 = -6
        for useAlt in order {
            CCLog.info("query: altFlags=\(useAlt) path=\(path)")
            let handle = worse_query(path, group, useAlt, true)
            CCLog.info("query handle=\(handle) (altFlags=\(useAlt))")
            if handle < 0 {
                last = handle
                continue
            }
            // A handle that does not open the path is useless.
            if WQAccess.tokenOpens(path) {
                WQAccess.preferredAltFlags = useAlt
                return handle
            }
            CCLog.info("token did not open the target; trying the other flags")
            worse_query_release(handle)
            last = -6
        }

        CCLog.error("both flag sets failed for \(path): \(last)")
        throw CCError.accessFailed(last)
    }

    /// Whichever flag set last succeeded; nil until one does.
    private static var preferredAltFlags: Bool?

    /// Verifies the token really grants access instead of trusting the handle.
    private static func tokenOpens(_ path: String) -> Bool {
        let fd = open(path, O_RDONLY | O_NONBLOCK)
        if fd >= 0 {
            close(fd)
            return true
        }
        return errno != EPERM
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
        return try acquire(path: containerPath, group: group)
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
