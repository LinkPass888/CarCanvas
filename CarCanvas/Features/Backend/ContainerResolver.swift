import Foundation
import Darwin

/// Finds the CarPlayWallpaper data container using query-object identifiers,
/// LaunchServices mappings, then scoped identity probes of trusted candidate
/// paths. The bounded inode walk is a fallback, not proof of target absence.
/// Automatic callers share one session result, including failure; only an
/// explicit refresh starts another discovery flight.
final class ContainerResolver {
    struct Resolved {
        let containerPath: String
        let cacheDirectory: String
        let files: [WallpaperTarget]
    }

    /// Successful and failed lookups are shared for this app session. The
    /// state lock is never held while scanning or acquiring an extension.
    private static let cache = ResolverCache()

    private final class ResolverCache {
        private let condition = NSCondition()
        private var cached: Result<Resolved, Error>?
        private var generation = 0
        private var completedGeneration = 0
        private var minimumGeneration = 1
        private var isLoading = false
        private var isRefreshing = false
        private var loadingThread: Thread?

        func value(forceRefresh: Bool, load: () throws -> Resolved) throws -> Resolved {
            condition.lock()
            let requestedGeneration: Int
            if forceRefresh {
                requestedGeneration = generation + (isLoading && isRefreshing ? 0 : 1)
            } else if let cached {
                condition.unlock()
                return try cached.get()
            } else {
                requestedGeneration = max(minimumGeneration, max(1, generation))
            }

            while true {
                if let cached, completedGeneration >= requestedGeneration {
                    condition.unlock()
                    return try cached.get()
                }
                if isLoading {
                    // A synchronous callback must not wait for its own load.
                    guard loadingThread !== Thread.current,
                          !WQAccess.hasActiveExtensionOnCurrentThread else {
                        condition.unlock()
                        throw NSError(domain: "CarCanvas.ContainerResolver", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "Recursive CarPlay container lookup."])
                    }
                    condition.wait()
                    continue
                }

                generation += 1
                let currentGeneration = generation
                isLoading = true
                isRefreshing = forceRefresh
                loadingThread = Thread.current
                condition.unlock()
                let result = Result { try load() }
                condition.lock()
                if currentGeneration >= minimumGeneration { cached = result }
                completedGeneration = currentGeneration
                isLoading = false
                isRefreshing = false
                loadingThread = nil
                condition.broadcast()
            }
        }

        func invalidate() {
            condition.lock(); defer { condition.unlock() }
            cached = nil
            minimumGeneration = generation + 1
            condition.broadcast()
        }
    }

    private final class LookupDiagnostics {
        var deadline: TimeInterval = 0
        var seen: Set<String> = []
        var mappedIDs: [String: String] = [:]
        var knownNonTargets = 0
        var probes = 0
        var preGrantIDs = 0
        var postGrantIDs = 0
        var grantAttempts = 0
        var grantsSucceeded = 0
        var probeFailures = 0
        var excludedPaths = 0
        var timedOut = false
        var samples: [String] = []
    }
    private var lookup = LookupDiagnostics()

    /// One budget shared by candidate probes and the fallback inode walk.
    private let scanBudget: TimeInterval = 20

    static func invalidateCache() { cache.invalidate() }

    func resolve(forceRefresh: Bool = false) throws -> Resolved {
        try ContainerResolver.cache.value(forceRefresh: forceRefresh) {
            try WQAccess.shared.preflight()
            return try resolveUncached()
        }
    }

    private func resolveUncached() throws -> Resolved {
        lookup = LookupDiagnostics()
        lookup.deadline = ProcessInfo.processInfo.systemUptime + scanBudget
        defer {
            CCLog.info("container discovery: probes=\(lookup.probes) preGrantIDs=\(lookup.preGrantIDs) postGrantIDs=\(lookup.postGrantIDs) grantAttempts=\(lookup.grantAttempts) grantsSucceeded=\(lookup.grantsSucceeded) probeFailures=\(lookup.probeFailures) excludedPaths=\(lookup.excludedPaths) knownNonTargets=\(lookup.knownNonTargets) timedOut=\(lookup.timedOut)")
        }
        var containerPath: String?
        var route = "container enumeration"
        var enumerationDiagnostic: NSString?
        let enumerated = CCContainerEnumerate(&enumerationDiagnostic)
        if let enumerationDiagnostic { CCLog.info(enumerationDiagnostic as String) }

        // MCM/LS mappings can identify a path without reading its root-only
        // metadata. Conflicting mappings are not accepted as identity proof.
        var mappedIDs: [String: String] = [:]
        var conflicts: Set<String> = []
        var candidates: [String] = []
        func addCandidate(_ path: String, identifier: String?) {
            let key = WQWhitelist.canonicalContainerPath(path) ?? path
            candidates.append(key)
            guard let identifier, !identifier.isEmpty, !conflicts.contains(key) else { return }
            if let existing = mappedIDs[key], existing != identifier {
                mappedIDs[key] = nil
                conflicts.insert(key)
                CCLog.error("container identity mappings disagree for \(key)")
            } else {
                mappedIDs[key] = identifier
            }
        }
        for entry in enumerated {
            if let path = entry["path"] {
                if entry["identifierConflict"] == "true" {
                    conflicts.insert(WQWhitelist.canonicalContainerPath(path) ?? path)
                }
                addCandidate(path, identifier: entry["identifier"])
            }
        }
        if CCLSIsAvailable() {
            let all = CCLSAllContainers()
            CCLog.info("launchservices: \(all.count) path identifiers")
            for (path, identifier) in all { addCandidate(path, identifier: identifier) }
        } else {
            CCLog.error("launchservices unavailable")
        }

        lookup.mappedIDs = mappedIDs

        // Exact target mappings go first, before any unknown candidate grant.
        for path in candidates where mappedIDs[path] == WQWhitelist.carPlayWallpaperBundleID {
            if let found = identifyCandidate(path, mappedIdentifier: mappedIDs[path]) {
                containerPath = found
                route = "container identity mapping"
                break
            }
        }
        if containerPath == nil {
            for path in candidates where mappedIDs[path] == nil {
                guard ProcessInfo.processInfo.systemUptime < lookup.deadline else {
                    lookup.timedOut = true
                    break
                }
                if let found = identifyCandidate(path) {
                    containerPath = found
                    route = "enumerated candidate probe"
                    break
                }
            }
        }

        // A partial nonempty enumeration does not prove the target is absent.
        if containerPath == nil, ProcessInfo.processInfo.systemUptime < lookup.deadline {
            route = "inode scan"
            containerPath = scanForContainer()
        }
        if containerPath == nil && ProcessInfo.processInfo.systemUptime >= lookup.deadline {
            lookup.timedOut = true
        }
        guard let container = containerPath else {
            CCLog.error("container lookup failed (route: \(route))")
            throw CCError.cacheNotFound
        }

        let cacheDirectory = container + "/" + WQWhitelist.cacheRelativePath
        guard WQWhitelist.isAllowedCacheDirectory(cacheDirectory) else {
            throw CCError.outsideWhitelist(cacheDirectory)
        }

        let files = try WQAccess.shared.withAccess(containerPath: container) {
            let targets = try Self.cacheFiles(in: cacheDirectory)
            HistoryStore.shared.backUpMissingOriginals(targets)
            return targets
        }
        CCLog.info("cache files accepted: \(files.count) (route: \(route))")
        // An identified container with an empty/missing fixed cache remains
        // usable for explicit cleanup. Creation/apply still check their inputs.
        return Resolved(containerPath: container, cacheDirectory: cacheDirectory, files: files)
    }

    /// Re-enumerate INSIDE the caller's existing scope before reading/writing.
    /// Only the fixed directory and whitelist-named regular files participate.
    static func cacheFiles(in directory: String) throws -> [WallpaperTarget] {
        guard try WQWhitelist.cacheDirectoryExists(directory) else { return [] }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory)
        var targets: [WallpaperTarget] = []
        for name in names.sorted() {
            let path = directory + "/" + name
            guard WQWhitelist.isAllowedCacheFile(path, in: directory) else { continue }
            var info = stat()
            guard lstat(path, &info) == 0 else {
                let code = errno
                if code == ENOENT { continue }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSLocalizedDescriptionKey: "Cache file lstat failed (errno \(code))."])
            }
            guard (info.st_mode & UInt16(S_IFMT)) == UInt16(S_IFREG) else { continue }
            targets.append(WallpaperTarget(path: path, fileName: name,
                                           appearance: WQWhitelist.appearance(of: name), byteCount: Int(info.st_size)))
        }
        return targets
    }

    /// Only identity metadata is exposed by the short-lived discovery grant.
    /// The access layer binds an exact match to the directory's device/inode.
    private func identifyCandidate(_ path: String, mappedIdentifier: String? = nil) -> String? {
        guard let candidate = WQWhitelist.canonicalContainerPath(path) else {
            lookup.excludedPaths += 1
            if mappedIdentifier == WQWhitelist.carPlayWallpaperBundleID {
                CCLog.error("CarPlay identity matched outside the Application UUID whitelist: \(path)")
            }
            return nil
        }
        guard lookup.seen.insert(candidate).inserted else { return nil }
        if let mappedIdentifier, mappedIdentifier != WQWhitelist.carPlayWallpaperBundleID {
            lookup.knownNonTargets += 1
            return nil
        }
        lookup.probes += 1
        let probe = WQAccess.shared.probeContainerIdentifier(candidate, mappedIdentifier: mappedIdentifier)
        if probe.grantAttempted { lookup.grantAttempts += 1 }
        if probe.grantSucceeded { lookup.grantsSucceeded += 1 }
        if let error = probe.error {
            lookup.probeFailures += 1
            if lookup.probeFailures <= 3 { CCLog.error("container identity probe: \(error)") }
        }
        guard let identifier = probe.identifier else { return nil }
        if probe.grantSucceeded { lookup.postGrantIDs += 1 }
        else { lookup.preGrantIDs += 1 }
        if lookup.samples.count < 3 { lookup.samples.append(identifier) }
        guard WQWhitelist.isAllowedContainer(candidate, identifier: identifier) else { return nil }
        CCLog.info("CarPlay container identity matched (afterGrant=\(probe.grantSucceeded)): \(candidate)")
        return candidate
    }

    /// The scan supplies paths, not identifiers. A candidate may need a
    /// scoped grant before either xattr or metadata can identify it.
    private func scanForContainer() -> String? {
        var found: String?
        var candidates = 0
        let identifiersBeforeScan = lookup.preGrantIDs + lookup.postGrantIDs
        let remaining = max(0, lookup.deadline - ProcessInfo.processInfo.systemUptime)
        var scanDiagnostic: NSString?
        let inspected = CCScanApplicationContainers(remaining, { path in
            candidates += 1
            guard ProcessInfo.processInfo.systemUptime < self.lookup.deadline else {
                self.lookup.timedOut = true
                return true
            }
            let key = WQWhitelist.canonicalContainerPath(path) ?? path
            if let matched = self.identifyCandidate(path, mappedIdentifier: self.lookup.mappedIDs[key]) {
                found = matched
                return true
            }
            return false
        }, &scanDiagnostic)

        if let scanDiagnostic { CCLog.info(scanDiagnostic as String) }
        if inspected < 0 { CCLog.error("container inode scan unavailable (result \(inspected))") }
        if ProcessInfo.processInfo.systemUptime >= lookup.deadline { lookup.timedOut = true }
        let scanIDs = lookup.preGrantIDs + lookup.postGrantIDs - identifiersBeforeScan
        CCLog.info("scan: \(candidates) raw candidates, \(scanIDs) identified")
        if !lookup.samples.isEmpty {
            CCLog.info("discovery sample ids: \(lookup.samples.joined(separator: ", "))")
        }
        CCLog.info("scan result: \(found ?? "none")")
        return found
    }

    func findCacheFiles() throws -> [WallpaperTarget] {
        try resolve().files
    }
}
