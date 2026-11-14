import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Creates local CPBitmap files from a chosen image, using an existing device
/// cache file as the format template. Nothing outside this app's own Documents
/// directory is written here.
final class WallpaperService {
    private let history = HistoryStore.shared
    private let settings = SettingsStore.shared

    /// Reads the first available cache file as a template. Uses the scoped
    /// extension but performs a read only.
    func loadTemplate() throws -> CPBitmapTemplate {
        let resolved = try ContainerResolver().resolve()
        guard let target = resolved.files.first else { throw CCError.noCacheFiles }
        return try WQAccess.shared.withAccess(containerPath: resolved.containerPath) {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: target.path),
                                       options: [.mappedIfSafe]) else {
                throw CCError.templateUnreadable(target.fileName)
            }
            return try CPBitmapTemplate.parse(data)
        }
    }

    /// Builds Dark + Light CPBitmap files in Documents/Exports.
    @discardableResult
    func createLocal(imageURL: URL,
                     appearances: Set<WallpaperTarget.Appearance>) throws -> HistoryEntry {
        let template = try loadTemplate()
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CCError.renderFailed
        }
        let data = try template.render(image: cgImage, order: settings.channelOrder)
        let baseName = sanitized(settings.exportBaseName)
        guard !baseName.isEmpty else { throw CCError.renderFailed }

        var last: HistoryEntry?
        for appearance in appearances where appearance != .unknown {
            last = try history.save(data: data,
                                    baseName: baseName,
                                    appearance: appearance,
                                    source: .local,
                                    sourceImageName: imageURL.lastPathComponent)
        }
        guard let entry = last else { throw CCError.nothingSelected }
        return entry
    }

    /// Copies the cache files that are currently on the device into History,
    /// so the user has a recoverable copy before overwriting anything.
    @discardableResult
    func exportExistingCacheFiles(from targets: [WallpaperTarget],
                                  baseName: String) throws -> Int {
        let resolved = try ContainerResolver().resolve()
        let name = sanitized(baseName)
        guard !name.isEmpty else { throw CCError.renderFailed }

        var count = 0
        try WQAccess.shared.withAccess(containerPath: resolved.containerPath) {
            for target in targets {
                guard WQWhitelist.isAllowedCacheFile(target.path, in: resolved.cacheDirectory),
                      let data = try? Data(contentsOf: URL(fileURLWithPath: target.path)) else { continue }
                try history.save(data: data,
                                 baseName: name,
                                 appearance: target.appearance,
                                 source: .carplay)
                count += 1
            }
        }
        return count
    }

    private func sanitized(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return String(raw.unicodeScalars.filter { allowed.contains($0) })
            .trimmingCharacters(in: .whitespaces)
    }
}
