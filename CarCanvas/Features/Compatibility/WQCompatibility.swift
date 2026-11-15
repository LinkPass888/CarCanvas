import Foundation

/// Compatibility policy for the worse_query backend.
///
/// The upstream PoC (forcequitOS/worse_query) states support for
/// "iOS 26.0 - 26.7.2 / 27.2". Downstream projects report a slightly wider
/// iOS 27 range in practice (WQFiles: tested on 27.0.1, 27.2.1 and a 27.3
/// beta; Regitela: 27.0 - 27.2). Formal support, used by the status banner,
/// remains limited to:
///
///   * 26.0  – 26.7.2   (contiguous)
///   * 27.0  – 27.2.1   (contiguous)
///
/// Container operations also allow the rest of 27.2.x and all of 27.3.x,
/// including betas. These are author/downstream claims, not an Apple advisory,
/// and no CVE is assigned. Anything outside those ranges fails closed.
enum WQCompatibility {
    private struct Range {
        let lower: OperatingSystemVersion
        let upper: OperatingSystemVersion
    }

    private static let supported: [Range] = [
        Range(lower: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0),
              upper: OperatingSystemVersion(majorVersion: 26, minorVersion: 7, patchVersion: 2)),
        Range(lower: OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0),
              upper: OperatingSystemVersion(majorVersion: 27, minorVersion: 2, patchVersion: 1))
    ]

    static var current: OperatingSystemVersion { ProcessInfo.processInfo.operatingSystemVersion }

    static var versionString: String {
        let v = current
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    private static func isAtLeast(_ a: OperatingSystemVersion, _ b: OperatingSystemVersion) -> Bool {
        if a.majorVersion != b.majorVersion { return a.majorVersion > b.majorVersion }
        if a.minorVersion != b.minorVersion { return a.minorVersion > b.minorVersion }
        return a.patchVersion >= b.patchVersion
    }

    static var isSupported: Bool {
        let v = current
        return supported.contains { isAtLeast(v, $0.lower) && isAtLeast($0.upper, v) }
    }

    static var isOperationAllowed: Bool {
        let v = current
        return isSupported || (v.majorVersion == 27 && (v.minorVersion == 2 || v.minorVersion == 3))
    }

    static var supportSummary: String {
        "iOS 26.0-26.7.2, 27.0-27.2.1 (upstream claim; current: \(versionString))"
    }

    /// Called before any container access. The operation gate is independent
    /// of the formal support shown in the banner; other versions fail closed.
    static func requireSupported() throws {
        guard isOperationAllowed else { throw CCError.unsupportedOS(versionString) }
    }
}
