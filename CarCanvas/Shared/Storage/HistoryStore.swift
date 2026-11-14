import Foundation
import Combine

final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published private(set) var entries: [HistoryEntry] = []

    let exportsDirectory: URL
    let backupsDirectory: URL
    private let indexURL: URL

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        exportsDirectory = docs.appendingPathComponent("Exports", isDirectory: true)
        backupsDirectory = docs.appendingPathComponent("Backups", isDirectory: true)
        indexURL = docs.appendingPathComponent("history.json")
        try? FileManager.default.createDirectory(at: exportsDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return }
        entries = decoded.sorted { $0.createdAt > $1.createdAt }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    func add(_ entry: HistoryEntry) {
        entries.insert(entry, at: 0)
        persist()
    }

    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        persist()
    }

    func clearAll() {
        entries.removeAll()
        persist()
    }

    func url(for fileName: String) -> URL {
        exportsDirectory.appendingPathComponent(fileName)
    }

    /// Writes an exported CPBitmap into Documents/Exports and records it.
    @discardableResult
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

    /// The untouched copies taken before any overwrite, newest first.
    func backups() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: backupsDirectory,
                                                     includingPropertiesForKeys: [.contentModificationDateKey]))?
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return l > r
            } ?? []
    }

    func save(data: Data, baseName: String, appearance: WallpaperTarget.Appearance,
              source: HistoryEntry.Source, sourceImageName: String? = nil) throws -> HistoryEntry {
        let suffix = appearance == .dark ? "Dark" : "Light"
        let fileName = "\(baseName)-\(suffix).cpbitmap"
        try data.write(to: url(for: fileName), options: .atomic)

        if let existing = entries.first(where: { $0.baseName == baseName && $0.source == source }) {
            var updated = existing
            if appearance == .dark { updated.darkFileName = fileName } else { updated.lightFileName = fileName }
            updated.sourceImageName = sourceImageName
            entries.removeAll { $0.id == existing.id }
            entries.insert(updated, at: 0)
            persist()
            return updated
        }
        let entry = HistoryEntry(baseName: baseName,
                                 source: source,
                                 darkFileName: appearance == .dark ? fileName : nil,
                                 lightFileName: appearance == .light ? fileName : nil,
                                 sourceImageName: sourceImageName)
        add(entry)
        return entry
    }
}
