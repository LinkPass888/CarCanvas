import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Creates local CPBitmap files from a chosen image.
///
/// The system's own CPBitmap writer is used first, which is what the original
/// app did and which needs no cache file on the device. Only if that writer is
/// unavailable does it fall back to the template approach. Nothing outside this
/// app's own Documents directory is written, and nothing is applied to CarPlay
/// at this stage.
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

    /// Builds Dark + Light CPBitmap files in Documents/Exports and records them
    /// in History. Does NOT touch CarPlay — see CacheWriter for the explicit
    /// overwrite.
    ///
    /// This deliberately does not require the device to have a CarPlay cache
    /// yet: the original app let you create local files before CarPlay had ever
    /// generated one.
    @discardableResult
    func createLocal(imageURL: URL,
                     appearances: Set<WallpaperTarget.Appearance>) throws -> HistoryEntry {
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CCError.renderFailed
        }

        // Encode ONCE. The system writer is not reliably repeatable in the same
        // process (the second call can fail), and both appearances share the
        // same pixels anyway - only the file name differs.
        let data = try encode(cgImage, appearance: appearances.contains(.dark) ? .dark : .light)
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

    /// Decodes an existing cache file into an image for the preview slots.
    /// Uses the template header so the geometry matches how the file is laid
    /// out, and falls back to the system decoder for anything it cannot parse.
    func previewImage(for target: WallpaperTarget,
                      resolved: ContainerResolver.Resolved) -> CGImage? {
        let url = URL(fileURLWithPath: target.path)
        let data: Data? = try? WQAccess.shared.withAccess(containerPath: resolved.containerPath) {
            try? Data(contentsOf: url, options: [.mappedIfSafe])
        }
        guard let data else { return nil }

        if let template = try? CPBitmapTemplate.parse(data), let image = template.preview() {
            return image
        }
        // Non-CPBitmap or an unrecognised layout: let the system try.
        return CGImageSourceCreateWithData(data as CFData, nil).flatMap {
            CGImageSourceCreateImageAtIndex($0, 0, nil)
        }
    }

    /// System writer first (no template needed), template renderer as fallback.
    private func encode(_ image: CGImage,
                        appearance: WallpaperTarget.Appearance) throws -> Data {
        let baseName = sanitized(settings.exportBaseName)
        guard !baseName.isEmpty else { throw CCError.renderFailed }

        if CCBitmapWriterIsAvailable() {
            let suffix = appearance == .dark ? "Dark" : "Light"
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(baseName)-\(suffix).cpbitmap")
            var writeError: NSError?
            if CCWriteCPBitmap(image, tmp, &writeError),
               let data = try? Data(contentsOf: tmp) {
                try? FileManager.default.removeItem(at: tmp)
                return data
            }
            try? FileManager.default.removeItem(at: tmp)
            let why = writeError?.localizedDescription ?? "unknown"
            CCLog.info("system CPBitmap writer failed (\(why)); using template")
        }

        // Fallback: reuse an existing cache file as the format template.
        let template = try loadTemplate()
        return try template.render(image: image, order: settings.channelOrder)
    }

    private func sanitized(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return String(raw.unicodeScalars.filter { allowed.contains($0) }).trimmingCharacters(in: .whitespaces)
    }
}
