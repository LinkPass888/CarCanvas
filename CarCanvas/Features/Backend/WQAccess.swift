import Foundation
import Darwin

/// Narrow Objective-C bridge to the GPL-3.0 `worse_query` primitive.
///
/// Final cache access requires a verified CarPlay container. Discovery may
/// briefly grant a trusted Application UUID candidate, but exposes only its
/// identifier and releases the handle before returning. All extension scopes
/// are synchronous and serialized because worse_query swaps the App Group's
/// Caches directory. No lock is held across an await.
final class WQAccess {
    static let shared = WQAccess()
    private init() { appGroupIdentifier = CCAppGroupIdentifier() }

    /// Read once from the signature; immutable even when first used off main.
    let appGroupIdentifier: String?

    /// Every group listed in the signature, for the diagnostics panel.
    var entitledGroups: [String] { CCAppGroupEntitledIdentifiers() }

    private let accessLock = NSRecursiveLock()
    private static let extensionScopeKey = "CarCanvas.WQAccess.extensionScope"

    /// Synchronous scopes never cross await, so this marker can prevent a
    /// callback from waiting on a resolver flight that needs its own lock.
    static var hasActiveExtensionOnCurrentThread: Bool {
        Thread.current.threadDictionary[extensionScopeKey] != nil
    }
    private var preferredAltFlags: Bool?
    private var retainedHandle: Int64 = -1

    private struct ContainerIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }
    private var verifiedContainers: [String: ContainerIdentity] = [:]

    struct IdentifierProbe {
        var identifier: String?
        var grantAttempted = false
        var grantSucceeded = false
        var error: String?
    }

    /// Fails closed on unsupported OS versions before touching any
    /// ContainerManager symbol.
    func preflight() throws {
        try WQCompatibility.requireSupported()
    }

    /// Worse_query needs an App Group because it swaps that group's Caches
    /// directory. It is required only when an extension is actually requested.
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

    /// Identifier-only discovery. Callers supply paths from ContainerManager,
    /// LaunchServices or fsgetpath, never an editable UI path. A denied pre-stat
    /// may need a token, but no identity file is read after grant until lstat
    /// confirms a non-symlink directory and its captured inode still matches.
    func probeContainerIdentifier(_ path: String, mappedIdentifier: String? = nil) -> IdentifierProbe {
        accessLock.lock(); defer { accessLock.unlock() }
        var result = IdentifierProbe()
        do {
            try preflight()
            guard let candidate = WQWhitelist.canonicalContainerPath(path) else {
                throw CCError.outsideWhitelist(path)
            }
            let before = try containerIdentity(at: candidate, allowDenied: true)
            let observed = before == nil ? nil : CCContainerIdentifier(candidate)
            if let mappedIdentifier, let observed, mappedIdentifier != observed {
                throw CCError.outsideWhitelist(candidate)
            }
            if let before, let identifier = observed ?? mappedIdentifier {
                guard let after = try containerIdentity(at: candidate), before == after else {
                    throw CCError.outsideWhitelist(candidate)
                }
                result.identifier = identifier
                if identifier == WQWhitelist.carPlayWallpaperBundleID {
                    verifiedContainers[candidate] = after
                }
                return result
            }

            let group = try requireAppGroup()
            result.grantAttempted = true
            let handle = try acquire(path: candidate, group: group, directory: true)
            Thread.current.threadDictionary[WQAccess.extensionScopeKey] = true
            defer {
                worse_query_release(handle)
                Thread.current.threadDictionary.removeObject(forKey: WQAccess.extensionScopeKey)
            }
            result.grantSucceeded = true
            guard let after = try containerIdentity(at: candidate),
                  before == nil || before == after else {
                throw CCError.outsideWhitelist(candidate)
            }
            var identifierDiagnostic: NSString?
            let grantedIdentifier = CCContainerIdentifierWithDiagnostic(candidate, &identifierDiagnostic)
            if grantedIdentifier == nil && mappedIdentifier == nil { result.error = identifierDiagnostic as String? }
            if let mappedIdentifier, let grantedIdentifier, mappedIdentifier != grantedIdentifier {
                throw CCError.outsideWhitelist(candidate)
            }
            result.identifier = grantedIdentifier ?? mappedIdentifier
            // Bind only the exact target to this directory identity. Other
            // candidates never become eligible for normal cache access.
            if result.identifier == WQWhitelist.carPlayWallpaperBundleID {
                guard try containerIdentity(at: candidate) == after else {
                    throw CCError.outsideWhitelist(candidate)
                }
                verifiedContainers[candidate] = after
            }
        } catch {
            result.identifier = nil
            result.error = error.localizedDescription
        }
        return result
    }

    private func containerIdentity(at path: String, allowDenied: Bool = false) throws -> ContainerIdentity? {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            let code = errno
            if allowDenied && (code == EPERM || code == EACCES) { return nil }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                          userInfo: [NSLocalizedDescriptionKey: "Container lstat failed (errno \(code)): \(String(cString: strerror(code)))"])
        }
        guard (info.st_mode & UInt16(S_IFMT)) == UInt16(S_IFDIR) else {
            throw CCError.outsideWhitelist(path)
        }
        return ContainerIdentity(device: info.st_dev, inode: info.st_ino)
    }

    /// Keeps a ContainerManager extension alive for the process lifetime.
    func retainContainerHandle(_ handle: Int64) {
        accessLock.lock(); defer { accessLock.unlock() }
        guard handle >= 0, retainedHandle < 0 else {
            if handle >= 0 { worse_query_release(handle) }
            return
        }
        retainedHandle = handle
    }

    /// Tries both flag sets. A nonnegative handle is not success until open
    /// really succeeds; ENOENT, EACCES and EPERM all remain failures.
    private func acquire(path: String, group: String, directory: Bool = false) throws -> Int64 {
        guard !WQAccess.hasActiveExtensionOnCurrentThread else {
            throw NSError(domain: "CarCanvas.WQAccess", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Nested CarPlay extension access."])
        }
        let order = preferredAltFlags.map { [$0, !$0] } ?? [true, false]
        var lastHandle: Int64 = -6
        var lastOpenError: Int32?
        for useAlt in order {
            CCLog.info("query: altFlags=\(useAlt) path=\(path)")
            let handle = worse_query(path, group, useAlt, true)
            CCLog.info("query handle=\(handle) (altFlags=\(useAlt))")
            if handle < 0 {
                lastHandle = handle
                continue
            }
            if let code = tokenOpenError(path, directory: directory) {
                lastOpenError = code
                CCLog.error("token issued but open failed (errno \(code)); trying the other flags")
                worse_query_release(handle)
                continue
            }
            preferredAltFlags = useAlt
            return handle
        }

        if let code = lastOpenError {
            CCLog.error("token access verification failed (open errno \(code))")
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                          userInfo: [NSLocalizedDescriptionKey: "Token issued, but target open failed (errno \(code)): \(String(cString: strerror(code)))"])
        }
        CCLog.error("both flag sets returned no usable handle for \(path): \(lastHandle)"
                    + " | \(describePathFailure(path, directory: directory))")
        throw CCError.accessFailed(lastHandle)
    }

    private func tokenOpenError(_ path: String, directory: Bool) -> Int32? {
        let flags = O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC | (directory ? O_DIRECTORY : 0)
        let fd = open(path, flags)
        guard fd >= 0 else { return errno }
        close(fd)
        return nil
    }

    /// A negative handle alone cannot say why the query failed: worse_query
    /// collapses a rejected query, a refused extension and a refused consume
    /// into the same code. Report what the path itself looks like, so the log
    /// separates "no such file" from "exists but denied" from "fine without a
    /// token". Runs only on the failure path; success pays nothing.
    private func describePathFailure(_ path: String, directory: Bool) -> String {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            let code = errno
            return "lstat errno \(code) (\(String(cString: strerror(code))))"
        }
        let kind: String
        switch info.st_mode & UInt16(S_IFMT) {
        case UInt16(S_IFDIR): kind = "directory"
        case UInt16(S_IFREG): kind = "file (\(info.st_size) bytes)"
        case UInt16(S_IFLNK): kind = "symlink"
        default:             kind = "mode \(info.st_mode & UInt16(S_IFMT))"
        }
        if let code = tokenOpenError(path, directory: directory) {
            return "\(kind), open errno \(code) (\(String(cString: strerror(code))))"
        }
        return "\(kind), opens without a token"
    }

    private func consume(containerPath: String) throws -> Int64 {
        let group = try requireAppGroup()
        guard WQWhitelist.isAllowedContainer(containerPath,
                                             identifier: WQWhitelist.carPlayWallpaperBundleID) else {
            throw CCError.outsideWhitelist(containerPath)
        }
        return try acquire(path: containerPath, group: group, directory: true)
    }

    /// Final access is available only after an exact CarPlay identity probe.
    /// Revalidate the directory inode while the extension is active; a stale
    /// cached path must never authorize a replacement container.
    func withAccess<T>(containerPath: String, _ body: () throws -> T) throws -> T {
        accessLock.lock(); defer { accessLock.unlock() }
        try preflight()
        guard let candidate = WQWhitelist.canonicalContainerPath(containerPath),
              let expected = verifiedContainers[candidate] else {
            throw CCError.outsideWhitelist(containerPath)
        }
        let handle = try consume(containerPath: candidate)
        Thread.current.threadDictionary[WQAccess.extensionScopeKey] = true
        defer {
            worse_query_release(handle)
            Thread.current.threadDictionary.removeObject(forKey: WQAccess.extensionScopeKey)
        }
        guard try containerIdentity(at: candidate) == expected else {
            throw CCError.outsideWhitelist(candidate)
        }
        if let identifier = CCContainerIdentifier(candidate),
           identifier != WQWhitelist.carPlayWallpaperBundleID {
            throw CCError.outsideWhitelist(candidate)
        }
        return try body()
    }
}
