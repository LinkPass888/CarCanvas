import Foundation
import Combine

/// The app-container list behind the original browser's "app data" mode.
///
/// Discovery is bounded (probe-file inode + margin, with a time budget) and
/// identifiers come from container xattrs, which need no sandbox extension.
/// Results are cached: the original app scanned once and remembered.
final class AppContainerStore: ObservableObject {
    struct Entry: Identifiable, Hashable {
        let id: String            // container path
        let bundleID: String
        let displayName: String
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var isScanning = false
    @Published private(set) var lastError: String?

    private var didScan = false
    private let scanBudget: TimeInterval = 20

    /// Scans at most once per launch unless `force` is set, mirroring the
    /// original behaviour of remembering the result.
    func scanIfNeeded(force: Bool = false) {
        guard force || !didScan else { return }
        didScan = true
        scan()
    }

    func scan() {
        isScanning = true
        lastError = nil
        var found: [Entry] = []
        let inspected = CCScanApplicationContainers(scanBudget) { path in
            guard let identifier = CCContainerIdentifier(path), !identifier.isEmpty else { return false }
            if !identifier.hasPrefix("com.apple.") {
                found.append(Entry(id: path, bundleID: identifier, displayName: identifier))
            }
            return false
        }
        if inspected < 0 {
            lastError = L("BROWSER_EMPTY")
        }
        entries = found.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        isScanning = false
        CCLog.info("container scan: \(entries.count) app containers, \(inspected) candidates inspected")
    }

    func entry(forBundleID bundleID: String) -> Entry? {
        entries.first { $0.bundleID == bundleID }
    }
}
