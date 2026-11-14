import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Creates local CPBitmap files from a chosen image, using an existing
/// device cache file as the format template. Nothing is written outside
/// this app's own Documents directory at this stage.
final class WallpaperService {
    private let history = HistoryStore.shared
    private let settings = SettingsStore.shared

    /// Reads the first available cache file as a template. Requires the
    /// scoped extension, but performs a read only.
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
    /// Does NOT touch CarPlay — see CacheWriter for the explicit overwrite.
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

    private func sanitized(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return String(raw.unicodeScalars.filter { allowed.contains($0) }).trimmingCharacters(in: .whitespaces)
    }
}
