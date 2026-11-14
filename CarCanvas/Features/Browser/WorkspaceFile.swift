import Foundation

/// One item in the workspace browser. The workspace is the app's own Documents
/// directory ("On My iPhone"), not another app's container.
struct WorkspaceFile: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool
    let byteCount: Int
    let modified: Date

    var id: String { url.path }
    var name: String { url.lastPathComponent }
    var isCPBitmap: Bool { url.pathExtension.lowercased() == "cpbitmap" }
}

/// Scoped operations inside the app's own Documents directory only. Paths are
/// always re-derived from the workspace root, so no caller-supplied path can
/// escape it.
enum Workspace {
    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func list(_ directory: URL) throws -> [WorkspaceFile] {
        guard isInsideRoot(directory) else { throw CCError.outsideWhitelist(directory.path) }
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let items = try FileManager.default.contentsOfDirectory(at: directory,
                                                               includingPropertiesForKeys: keys,
                                                               options: [])
        return items.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return WorkspaceFile(url: url,
                                 isDirectory: values.isDirectory ?? false,
                                 byteCount: values.fileSize ?? 0,
                                 modified: values.contentModificationDate ?? .distantPast)
        }
        .sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// Validates a single path component: no separators, no traversal, and a
    /// sane length. This is what keeps renames and creations inside the root.
    static func validate(name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CCError.invalidName }
        guard trimmed.count <= 255 else { throw CCError.nameTooLong }
        guard !trimmed.contains("/"), trimmed != ".", trimmed != "..",
              !trimmed.contains(":") else { throw CCError.invalidName }
        return trimmed
    }

    static func isInsideRoot(_ url: URL) -> Bool {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let target = url.standardizedFileURL.resolvingSymlinksInPath().path
        return target == rootPath || target.hasPrefix(rootPath + "/")
    }

    /// Uniquifies a name the way Finder does, for "keep both" imports and
    /// duplicate.
    static func uniqueURL(in directory: URL, preferredName: String) -> URL {
        let base = (preferredName as NSString).deletingPathExtension
        let ext = (preferredName as NSString).pathExtension
        var candidate = directory.appendingPathComponent(preferredName)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            candidate = directory.appendingPathComponent(name)
            index += 1
        }
        return candidate
    }
}
