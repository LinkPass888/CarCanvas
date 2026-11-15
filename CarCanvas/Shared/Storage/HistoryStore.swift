import Foundation
import Combine

final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    struct OriginalBackup: Identifiable, Codable, Equatable {
        enum Source: String, Codable { case firstScan, legacy, recovered }

        let cacheFileName: String
        let backupFileName: String
        let createdAt: Date
        let byteCount: Int
        let source: Source
        let sourceFileName: String?

        var id: String { cacheFileName }
    }

    @Published private(set) var entries: [HistoryEntry] = []
    @Published private(set) var originalBackups: [OriginalBackup] = []
    @Published private(set) var backupFailures: [String] = []

    let exportsDirectory: URL
    let backupsDirectory: URL
    private let indexURL: URL
    private let backupIndexURL: URL
    private let storageQueue = DispatchQueue(label: "CarCanvas.HistoryStore", qos: .utility)
    // Disk state is owned by storageQueue; only snapshots are published on main.
    private var storedEntries: [HistoryEntry] = []
    private var storedBackups: [OriginalBackup] = []
    private var failedBackups: Set<String> = []
    private var backupIndexReadable = true
    private var backupIndexDirty = false

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        exportsDirectory = docs.appendingPathComponent("Exports", isDirectory: true)
        backupsDirectory = docs.appendingPathComponent("Backups", isDirectory: true)
        indexURL = docs.appendingPathComponent("history.json")
        backupIndexURL = backupsDirectory.appendingPathComponent("originals.json")
        storageQueue.async { self.load() }
    }

    private func load() {
        do {
            try FileManager.default.createDirectory(at: exportsDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: indexURL.path) {
                storedEntries = try JSONDecoder().decode([HistoryEntry].self, from: Data(contentsOf: indexURL))
                    .sorted { $0.createdAt > $1.createdAt }
            }
        } catch { CCLog.error("history load failed: \(error.localizedDescription)") }
        do {
            if FileManager.default.fileExists(atPath: backupIndexURL.path) {
                storedBackups = try JSONDecoder().decode([OriginalBackup].self,
                                                        from: Data(contentsOf: backupIndexURL))
                guard Set(storedBackups.map(\.cacheFileName)).count == storedBackups.count else {
                    throw CCError.backupFailed
                }
                for backup in storedBackups {
                    do { _ = try validatedBackupData(backup) }
                    catch {
                        failedBackups.insert(backup.cacheFileName)
                        CCLog.error("original backup unreadable for \(backup.cacheFileName): \(error.localizedDescription)")
                    }
                }
            }
        } catch {
            // Never replace an unreadable index with a new snapshot of custom caches.
            backupIndexReadable = false
            CCLog.error("original backup index load failed: \(error.localizedDescription)")
        }
        publishEntries()
        publishBackups()
    }

    private func publishEntries() {
        let snapshot = storedEntries
        DispatchQueue.main.async { self.entries = snapshot }
    }

    private func publishBackups() {
        let snapshot = storedBackups.sorted { $0.cacheFileName < $1.cacheFileName }
        let failures = failedBackups.sorted()
        DispatchQueue.main.async {
            self.originalBackups = snapshot
            self.backupFailures = failures
        }
    }

    private func persist() {
        do {
            try JSONEncoder().encode(storedEntries).write(to: indexURL, options: .atomic)
        } catch { CCLog.error("history index save failed: \(error.localizedDescription)") }
        publishEntries()
    }

    func add(_ entry: HistoryEntry) {
        storageQueue.async {
            self.storedEntries.insert(entry, at: 0)
            self.persist()
        }
    }

    func remove(_ id: UUID) {
        storageQueue.async {
            self.storedEntries.removeAll { $0.id == id }
            self.persist()
        }
    }

    func clearAll() {
        storageQueue.async {
            self.storedEntries.removeAll()
            self.persist()
        }
    }

    func url(for fileName: String) -> URL {
        exportsDirectory.appendingPathComponent(fileName)
    }

    /// True when an export with this base name already exists on disk.
    func exists(baseName: String) -> Bool {
        for suffix in ["Dark", "Light"] {
            if FileManager.default.fileExists(atPath: url(for: "\(baseName)-\(suffix).cpbitmap").path) {
                return true
            }
        }
        return false
    }

    /// Appends " 2", " 3", ... until the name is free, the way Finder does.
    func uniqueBaseName(from baseName: String) -> String {
        guard exists(baseName: baseName) else { return baseName }
        var index = 2
        while exists(baseName: "\(baseName) \(index)") { index += 1 }
        return "\(baseName) \(index)"
    }

    /// Called inside the resolver's existing authorization, never acquiring another scope.
    /// A failed backup does not hide the cache, but ensureOriginal will refuse its overwrite.
    func backUpMissingOriginals(_ targets: [WallpaperTarget]) {
        for target in targets { _ = try? ensureOriginal(for: target) }
    }

    @discardableResult
    func ensureOriginal(for target: WallpaperTarget) throws -> OriginalBackup {
        guard WQAccess.hasActiveExtensionOnCurrentThread else { throw CCError.backupFailed }
        return try storageQueue.sync {
            do {
                let directory = URL(fileURLWithPath: target.path).deletingLastPathComponent().path
                guard backupIndexReadable,
                      target.fileName == (target.path as NSString).lastPathComponent,
                      WQWhitelist.isAllowedCacheFile(target.path, in: directory) else {
                    throw CCError.backupFailed
                }
                let backup: OriginalBackup
                if let existing = storedBackups.first(where: { $0.cacheFileName == target.fileName }) {
                    // Missing or damaged saved originals must never be replaced by the current cache.
                    _ = try validatedBackupData(existing)
                    backup = existing
                } else {
                    backup = try createOriginal(for: target)
                    storedBackups.append(backup)
                    backupIndexDirty = true
                }
                if backupIndexDirty {
                    let data = try JSONEncoder().encode(storedBackups)
                    try data.write(to: backupIndexURL, options: .atomic)
                    guard try Data(contentsOf: backupIndexURL) == data else { throw CCError.backupFailed }
                    backupIndexDirty = false
                }
                failedBackups.remove(target.fileName)
                publishBackups()
                return backup
            } catch {
                failedBackups.insert(target.fileName)
                publishBackups()
                CCLog.error("original backup failed for \(target.fileName); overwrite blocked: \(error.localizedDescription)")
                throw CCError.backupFailed
            }
        }
    }

    func originalBackup(for cacheFileName: String) throws -> OriginalBackup? {
        guard WQAccess.hasActiveExtensionOnCurrentThread else { throw CCError.backupFailed }
        return try storageQueue.sync {
            guard backupIndexReadable else { throw CCError.backupFailed }
            return storedBackups.first(where: { $0.cacheFileName == cacheFileName })
        }
    }

    func backupData(for backup: OriginalBackup) throws -> Data {
        // In particular, a queued restore cannot keep a payload captured before
        // cleanup and re-create the old cache after its backing record was purged.
        guard WQAccess.hasActiveExtensionOnCurrentThread else { throw CCError.backupFailed }
        return try storageQueue.sync {
            guard backupIndexReadable, storedBackups.contains(backup) else { throw CCError.backupFailed }
            do {
                return try validatedBackupData(backup)
            } catch {
                failedBackups.insert(backup.cacheFileName)
                publishBackups()
                CCLog.error("original backup validation failed for \(backup.cacheFileName): \(error.localizedDescription)")
                throw CCError.backupFailed
            }
        }
    }

    struct BackupPurge {
        let temporaryDirectory: URL
        let existed: Bool
        var snapshot: URL { temporaryDirectory.appendingPathComponent("Backups", isDirectory: true) }
    }

    /// Prepare and byte-verify ALL local copies (including legacy files and the
    /// index) before CacheWriter deletes even the first system file.
    func prepareBackupPurge() throws -> BackupPurge {
        guard WQAccess.hasActiveExtensionOnCurrentThread else { throw CCError.backupFailed }
        return try storageQueue.sync {
            let manager = FileManager.default
            let temporary = manager.temporaryDirectory.appendingPathComponent("cc-backups-clear-\(UUID().uuidString)", isDirectory: true)
            let prepared = BackupPurge(temporaryDirectory: temporary, existed: manager.fileExists(atPath: backupsDirectory.path))
            do {
                try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
                if prepared.existed {
                    try manager.copyItem(at: backupsDirectory, to: prepared.snapshot)
                    try verifyBackupSnapshot(from: backupsDirectory, to: prepared.snapshot)
                }
                return prepared
            } catch {
                try? manager.removeItem(at: temporary)
                throw error
            }
        }
    }

    /// Called only after the whitelisted system cache is successfully empty.
    /// Exports/history.json and settings are intentionally untouched.
    func purgeOriginalBackups(using prepared: BackupPurge) throws {
        guard WQAccess.hasActiveExtensionOnCurrentThread else { throw CCError.backupFailed }
        try storageQueue.sync {
            let manager = FileManager.default
            var beganRemoval = false
            do {
                if prepared.existed {
                    try verifyBackupSnapshot(from: backupsDirectory, to: prepared.snapshot)
                    beganRemoval = true
                    try manager.removeItem(at: backupsDirectory)
                } else if manager.fileExists(atPath: backupsDirectory.path) {
                    throw CCError.backupFailed
                }
                try manager.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
                guard try manager.contentsOfDirectory(atPath: backupsDirectory.path).isEmpty else { throw CCError.backupFailed }
            } catch {
                if prepared.existed && beganRemoval {
                    do {
                        try restoreMissingBackupFiles(from: prepared.snapshot, to: backupsDirectory)
                        try verifyBackupSnapshot(from: backupsDirectory, to: prepared.snapshot)
                    } catch let rollbackError {
                        for backup in storedBackups where (try? validatedBackupData(backup)) == nil {
                            failedBackups.insert(backup.cacheFileName)
                        }
                        publishBackups()
                        CCLog.error("backup purge rollback failed: \(rollbackError.localizedDescription)")
                        throw NSError(domain: "CarCanvas.HistoryStore", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: LF("HISTORY_BACKUP_ROLLBACK_FAILED", error.localizedDescription)])
                    }
                }
                throw error
            }
            storedBackups.removeAll()
            failedBackups.removeAll()
            backupIndexReadable = true
            backupIndexDirty = false
            publishBackups()
        }
    }

    private func verifyBackupSnapshot(from source: URL, to snapshot: URL) throws {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        let a = try source.resourceValues(forKeys: keys), b = try snapshot.resourceValues(forKeys: keys)
        guard a.isSymbolicLink != true, b.isSymbolicLink != true else { throw CCError.backupFailed }
        if a.isDirectory == true && b.isDirectory == true {
            let names = try FileManager.default.contentsOfDirectory(atPath: source.path)
            guard Set(names) == Set(try FileManager.default.contentsOfDirectory(atPath: snapshot.path)) else { throw CCError.backupFailed }
            for name in names { try verifyBackupSnapshot(from: source.appendingPathComponent(name), to: snapshot.appendingPathComponent(name)) }
        } else {
            guard a.isRegularFile == true, b.isRegularFile == true,
                  try Data(contentsOf: source) == Data(contentsOf: snapshot) else { throw CCError.backupFailed }
        }
    }

    private func restoreMissingBackupFiles(from snapshot: URL, to destination: URL) throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: destination.path) {
            try manager.copyItem(at: snapshot, to: destination)
        } else if try snapshot.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
            let values = try destination.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw CCError.backupFailed }
            for name in try manager.contentsOfDirectory(atPath: snapshot.path) {
                try restoreMissingBackupFiles(from: snapshot.appendingPathComponent(name), to: destination.appendingPathComponent(name))
            }
        }
    }

    private func backupFileData(at url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0 else { throw CCError.backupFailed }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count == size else { throw CCError.backupFailed }
        return data
    }

    private func validatedBackupData(_ backup: OriginalBackup) throws -> Data {
        guard backup.byteCount > 0,
              backup.cacheFileName == (backup.cacheFileName as NSString).lastPathComponent,
              backup.backupFileName == "original-\(backup.cacheFileName)" else { throw CCError.backupFailed }
        let data = try backupFileData(at: backupsDirectory.appendingPathComponent(backup.backupFileName))
        guard data.count == backup.byteCount else { throw CCError.backupFailed }
        return data
    }

    private func createOriginal(for target: WallpaperTarget) throws -> OriginalBackup {
        let name = "original-\(target.fileName)"
        let destination = backupsDirectory.appendingPathComponent(name)
        var source = OriginalBackup.Source.firstScan
        var sourceFileName: String?
        var createdAt = Date()
        let payload: Data
        if FileManager.default.fileExists(atPath: destination.path) {
            // Recover a copy left by an interrupted index write, without overwriting it.
            payload = try backupFileData(at: destination)
            source = .recovered
            sourceFileName = name
        } else {
            let files = try FileManager.default.contentsOfDirectory(at: backupsDirectory,
                                                                   includingPropertiesForKeys: nil)
            let suffix = "-" + target.fileName
            let legacy = files.compactMap { url -> (URL, TimeInterval)? in
                let fileName = url.lastPathComponent
                guard fileName.hasSuffix(suffix),
                      let timestamp = TimeInterval(String(fileName.dropLast(suffix.count))),
                      timestamp.isFinite, timestamp > 0 else { return nil }
                return (url, timestamp)
            }.sorted { $0.1 == $1.1 ? $0.0.lastPathComponent < $1.0.lastPathComponent : $0.1 < $1.1 }
            var earliest: (Data, URL, TimeInterval)?
            for (url, timestamp) in legacy {
                // Preserve the raw copy; neither the current cache size nor preview decoding proves its integrity.
                if let data = try? backupFileData(at: url) {
                    earliest = (data, url, timestamp)
                    break
                }
                CCLog.error("legacy backup rejected for \(target.fileName): \(url.lastPathComponent)")
            }
            if let earliest {
                payload = earliest.0
                source = .legacy
                sourceFileName = earliest.1.lastPathComponent
                createdAt = Date(timeIntervalSince1970: earliest.2)
            } else {
                // Existing but invalid legacy copies are not permission to back up a custom cache.
                guard legacy.isEmpty else { throw CCError.backupFailed }
                payload = try Data(contentsOf: URL(fileURLWithPath: target.path))
            }
            guard !payload.isEmpty else { throw CCError.backupFailed }
            if source == .firstScan, payload.count != target.byteCount { throw CCError.backupFailed }
            let temporary = backupsDirectory.appendingPathComponent(".original-\(UUID().uuidString).tmp")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try payload.write(to: temporary, options: .atomic)
            guard try Data(contentsOf: temporary) == payload else { throw CCError.backupFailed }
            // moveItem fails if destination exists: an original is never replaced.
            try FileManager.default.moveItem(at: temporary, to: destination)
            guard try Data(contentsOf: destination) == payload else { throw CCError.backupFailed }
        }
        guard !payload.isEmpty else { throw CCError.backupFailed }
        return OriginalBackup(cacheFileName: target.fileName, backupFileName: name,
                              createdAt: createdAt, byteCount: payload.count,
                              source: source, sourceFileName: sourceFileName)
    }

    /// Commit both independently encoded appearances as one entry. Reserve the
    /// name and persist the index on the same queue; a failed pair leaves no row
    /// or half-created export behind. Existing single-image entries stay readable.
    @discardableResult
    func savePair(darkData: Data, lightData: Data, baseName: String,
                  sourceImageName: String?) throws -> HistoryEntry {
        try storageQueue.sync {
            let uniqueName = uniqueBaseName(from: baseName)
            let darkName = "\(uniqueName)-Dark.cpbitmap"
            let lightName = "\(uniqueName)-Light.cpbitmap"
            let darkURL = url(for: darkName), lightURL = url(for: lightName)
            let entry = HistoryEntry(baseName: uniqueName, source: .local,
                                     darkFileName: darkName, lightFileName: lightName,
                                     sourceImageName: sourceImageName)
            do {
                guard !darkData.isEmpty, !lightData.isEmpty else { throw CCError.renderFailed }
                try darkData.write(to: darkURL, options: .atomic)
                try lightData.write(to: lightURL, options: .atomic)
                guard try Data(contentsOf: darkURL) == darkData,
                      try Data(contentsOf: lightURL) == lightData else { throw CCError.verificationFailed }
                let updated = [entry] + storedEntries
                try JSONEncoder().encode(updated).write(to: indexURL, options: .atomic)
                storedEntries = updated
                publishEntries()
                return entry
            } catch {
                try? FileManager.default.removeItem(at: darkURL)
                try? FileManager.default.removeItem(at: lightURL)
                throw error
            }
        }
    }

    /// Writes an exported CPBitmap and records it on the disk queue.
    @discardableResult
    func save(data: Data, baseName: String, appearance: WallpaperTarget.Appearance,
              source: HistoryEntry.Source, sourceImageName: String? = nil) throws -> HistoryEntry {
        try storageQueue.sync {
            let suffix = appearance == .dark ? "Dark" : "Light"
            let fileName = "\(baseName)-\(suffix).cpbitmap"
            try data.write(to: url(for: fileName), options: .atomic)

            if let existing = storedEntries.first(where: { $0.baseName == baseName && $0.source == source }) {
                var updated = existing
                if appearance == .dark { updated.darkFileName = fileName } else { updated.lightFileName = fileName }
                updated.sourceImageName = sourceImageName
                storedEntries.removeAll { $0.id == existing.id }
                storedEntries.insert(updated, at: 0)
                persist()
                return updated
            }
            let entry = HistoryEntry(baseName: baseName,
                                     source: source,
                                     darkFileName: appearance == .dark ? fileName : nil,
                                     lightFileName: appearance == .light ? fileName : nil,
                                     sourceImageName: sourceImageName)
            storedEntries.insert(entry, at: 0)
            persist()
            return entry
        }
    }
}
