import Foundation

/// Version gate for the worse_query backend.
///
/// The upstream PoC (forcequitOS/worse_query) states support for
/// "iOS 26.0 - 26.7.2 / 27.2". Downstream projects report a slightly wider
/// iOS 27 range in practice (WQFiles: tested on 27.0.1, 27.2.1 and a 27.3
/// beta; Regitela: 27.0 - 27.2), so this project enables the two ranges that
/// are actually backed by reports:
///
///   * 26.0  – 26.7.2   (contiguous)
///   * 27.0  – 27.2.x   (contiguous)
///
/// These are author/downstream claims, not an Apple advisory, and no CVE is
/// assigned. Anything outside them fails closed.
enum WQCompatibility {
    private static let supported: [ClosedRange<OperatingSystemVersion>] = [
        OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
            ... OperatingSystemVersion(majorVersion: 26, minorVersion: 7, patchVersion: 2),
        OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)
            ... OperatingSystemVersion(majorVersion: 27, minorVersion: 2, patchVersion: 99)
    ]

    static var current: OperatingSystemVersion { ProcessInfo.processInfo.operatingSystemVersion }

    static var versionString: String {
        let v = current
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    private static func compare(_ a: OperatingSystemVersion, _ b: OperatingSystemVersion) -> ComparisonResult {
        for (x, y) in [(a.majorVersion, b.majorVersion),
                       (a.minorVersion, b.minorVersion),
                       (a.patchVersion, b.patchVersion)] {
            if x < y { return .orderedAscending }
            if x > y { return .orderedDescending }
        }
        return .orderedSame
    }

    static var isSupported: Bool {
        let v = current
        return supported.contains { range in
            compare(v, range.lowerBound) != .orderedAscending
                && compare(v, range.upperBound) != .orderedDescending
        }
    }

    static var supportSummary: String {
        "iOS 26.0–26.7.2, 27.0–27.2 (upstream claim; current: \(versionString))"
    }

    /// Called before any container access. Throws rather than returning a
    /// degraded backend — there is no safe degraded mode here.
    static func requireSupported() throws {
        guard isSupported else { throw CCError.unsupportedOS(versionString) }
    }
}
