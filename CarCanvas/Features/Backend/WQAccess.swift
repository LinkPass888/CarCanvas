import Foundation

/// Narrow Objective-C bridge to the GPL-3.0 `worse_query` primitive.
///
/// Design rules:
///  * `withAccess` is the ONLY way to obtain an extension handle.
///  * Callers cannot pass an arbitrary path: only `WQWhitelist` roots are
///    accepted, and every candidate is re-validated before use.
///  * The handle is always released in `defer`, even on error.
///  * No path is persisted, logged, or exposed through the UI.
final class WQAccess {
    static let shared = WQAccess()
    private init() {}

    private let groupIdentifier: String = {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "CCAppGroupIdentifier") as? String,
              !value.isEmpty else { return "group.example.carcanvas.wq" }
        return value
    }()

    /// Fails closed on unsupported OS versions and missing App Group before
    /// touching any ContainerManager symbol.
    func preflight() throws {
        try WQCompatibility.requireSupported()
        guard FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier) != nil else {
            throw CCError.appGroupUnavailable(groupIdentifier)
        }
    }

    var appGroupIdentifier: String { groupIdentifier }

    /// Validates a container candidate then consume a sandbox extension for it.
    /// `identifier` must come from the container's metadata plist.
    private func consume(containerPath: String, identifier: String) throws -> Int64 {
        // The identifier argument is only a hint. Re-read the container's own
        // metadata plist and compare, so a caller cannot bypass validation by
        // passing the expected constant for an unrelated container.
        let metadata = (containerPath as NSString)
            .appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: metadata)),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any],
              let actual = dict["MCMMetadataIdentifier"] as? String,
              actual == identifier else {
            throw CCError.outsideWhitelist(containerPath)
        }
        guard WQWhitelist.isAllowedContainer(containerPath, identifier: actual) else {
            throw CCError.outsideWhitelist(containerPath)
        }
        // iOS 26.x App Group containers need the alternate flag set. This is
        // the only place where the alt_flags argument is decided.
        let is26 = WQCompatibility.current.majorVersion == 26
        let handle = worse_query(containerPath, groupIdentifier, is26, false)
        guard handle >= 0 else { throw CCError.accessFailed(handle) }
        return handle
    }

    /// The one scoped entry point. The closure runs while the extension is
    /// consumed; the handle is released unconditionally afterwards.
    func withAccess<T>(containerPath: String,
                       identifier: String,
                       _ body: () throws -> T) throws -> T {
        try preflight()
        let handle = try consume(containerPath: containerPath, identifier: identifier)
        defer { worse_query_release(handle) }
        return try body()
    }
}
