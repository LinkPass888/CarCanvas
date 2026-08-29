import Foundation

/// Version gate for the worse_query backend.
///
/// The upstream PoC (forcequitOS/worse_query) *claims* iOS 26.0 – 26.7.2.
/// This is an author statement, not an Apple advisory, and no CVE is
/// assigned to it. We therefore enable exactly that claimed range and
/// fail closed on anything else — including 27.x, which upstream also
/// mentions but which this project deliberately does not enable.
enum WQCompatibility {
    static let minimum = OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
    static let maximum = OperatingSystemVersion(majorVersion: 26, minorVersion: 7, patchVersion: 2)

    static var current: OperatingSystemVersion { ProcessInfo.processInfo.operatingSystemVersion }

    static var versionString: String {
        let v = current
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// Lexicographic comparison on (major, minor, patch).
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
        return compare(v, minimum) != .orderedAscending
            && compare(v, maximum) != .orderedDescending
    }

    static var supportSummary: String {
        "iOS 26.0 – 26.7.2 (upstream claim; current: \(versionString))"
    }

    /// Called before any container access. Throws rather than returning a
    /// degraded backend — there is no safe degraded mode here.
    static func requireSupported() throws {
        guard isSupported else { throw CCError.unsupportedOS(versionString) }
    }
}
