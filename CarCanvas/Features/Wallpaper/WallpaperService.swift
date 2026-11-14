import Foundation
import CoreGraphics
import ImageIO

/// Local creation is independent of applying a specifically selected cache group.
final class WallpaperService {
    private let history = HistoryStore.shared
    private let channelOrder: CPBitmapTemplate.ChannelOrder
    static let thumbnailDimension = 320

    init(channelOrder: CPBitmapTemplate.ChannelOrder = .bgra) {
        self.channelOrder = channelOrder
    }

    func loadTemplate(for selected: WallpaperTarget? = nil) throws -> CPBitmapTemplate {
        let resolved = try ContainerResolver().resolve()
        return try WQAccess.shared.withAccess(containerPath: resolved.containerPath) {
            let files = try ContainerResolver.cacheFiles(in: resolved.cacheDirectory)
            let target: WallpaperTarget
            if let selected {
                guard let current = files.first(where: {
                    $0.path == selected.path && $0.fileName == selected.fileName && $0.appearance == selected.appearance
                }) else { throw CCError.templateUnreadable(selected.fileName) }
                target = current
            } else {
                guard let first = files.first else { throw CCError.noCacheFiles }
                target = first
            }
            return try CPBitmapTemplate.parse(Data(contentsOf: URL(fileURLWithPath: target.path)))
        }
    }

    /// A selected cache supplies the fallback geometry; never substitute the
    /// first Dark/Light file or create a paired export for this single-file edit.
    func replacementData(imageURL: URL, target: WallpaperTarget) throws -> Data {
        try autoreleasepool { try encode(photo(at: imageURL), target: target) }
    }

    /// Encode each photo separately. Only after BOTH succeeded does savePair
    /// reserve one base name and commit two files plus one HistoryEntry.
    @discardableResult
    func createLocal(darkImageURL: URL, lightImageURL: URL, baseName rawName: String) throws -> HistoryEntry {
        let baseName = sanitized(rawName)
        guard !baseName.isEmpty else { throw CCError.renderFailed }
        let darkData = try autoreleasepool { try encode(photo(at: darkImageURL)) }
        // If the second system call is unavailable/refused, the first VALID
        // output itself supplies the geometry/metadata, even before CarPlay has
        // a cache. Render the second photo; never copy the first photo's pixels.
        let localTemplate = try? CPBitmapTemplate.parse(darkData)
        let lightData = try autoreleasepool { try encode(photo(at: lightImageURL), fallbackTemplate: localTemplate) }
        return try history.savePair(darkData: darkData, lightData: lightData, baseName: baseName,
                                    sourceImageName: "\(darkImageURL.lastPathComponent) / \(lightImageURL.lastPathComponent)")
    }

    /// ImageIO handles real photo formats and their EXIF orientation, not
    /// CPBitmap. A pick displays immediately without retaining full pixels.
    static func photoPreview(data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailDimension
        ] as CFDictionary)
    }

    private func photo(at url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight as String] as? NSNumber else { throw CCError.renderFailed }
        let maximum = max(width.intValue, height.intValue)
        guard maximum > 0, maximum <= 16_384,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maximum
              ] as CFDictionary) else { throw CCError.renderFailed }
        return image
    }

    func previewImage(for target: WallpaperTarget, resolved: ContainerResolver.Resolved) -> CGImage? {
        do {
            return try WQAccess.shared.withAccess(containerPath: resolved.containerPath) {
                guard try WQWhitelist.cacheDirectoryExists(resolved.cacheDirectory),
                      try ContainerResolver.cacheFiles(in: resolved.cacheDirectory).contains(where: { $0.path == target.path && $0.byteCount > 0 && $0.byteCount <= 256 * 1024 * 1024 }) else {
                    throw CCError.templateUnreadable(target.fileName)
                }
                return previewImage(at: URL(fileURLWithPath: target.path))
            }
        } catch {
            CCLog.error("CPBitmap preview access failed for \(target.fileName): \(error.localizedDescription)")
            return nil
        }
    }

    /// Also used for validated app-local backups. Decode one original at a
    /// time and return only a small, independently owned image.
    func previewImage(at url: URL) -> CGImage? {
        autoreleasepool {
            var readError: NSError?
            do {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      let size = values.fileSize, size > 0, size <= 256 * 1024 * 1024 else { throw CCError.renderFailed }
                // Native decoding must not be rejected by our narrower parser.
                if let image = CCCopyCPBitmapImage(url, &readError), let small = Self.thumbnail(image) { return small }
                CCLog.info("system CPBitmap preview unavailable for \(url.lastPathComponent): \(readError?.localizedDescription ?? "no image"); trying template")
                let template = try CPBitmapTemplate.parse(Data(contentsOf: url))
                guard let image = template.preview(order: channelOrder), let small = Self.thumbnail(image) else { throw CCError.renderFailed }
                return small
            } catch {
                CCLog.error("CPBitmap preview failed for \(url.lastPathComponent): system=\(readError?.localizedDescription ?? "no image"); template=\(error.localizedDescription)")
                return nil
            }
        }
    }

    static func thumbnail(_ image: CGImage) -> CGImage? {
        guard image.width > 0, image.height > 0, image.width <= 16_384, image.height <= 16_384 else { return nil }
        let scale = min(1, Double(thumbnailDimension) / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private func encode(_ image: CGImage, fallbackTemplate: CPBitmapTemplate? = nil,
                        target: WallpaperTarget? = nil) throws -> Data {
        if CCBitmapWriterIsAvailable() {
            // Unique destinations and distinct UIImage instances for the two
            // photos; never reuse the first photo's bytes as the second output.
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("cc-bitmap-\(UUID().uuidString).cpbitmap")
            defer { try? FileManager.default.removeItem(at: temporary) }
            var writeError: NSError?
            if CCWriteCPBitmap(image, temporary, &writeError) {
                let data = try Data(contentsOf: temporary)
                if CPBitmapTemplate.hasCPBitmapSignature(data) { return data }
            }
            CCLog.info("system CPBitmap writer failed (\(writeError?.localizedDescription ?? "empty output")); using validated template")
        }
        if let fallbackTemplate { return try fallbackTemplate.render(image: image, order: channelOrder) }
        return try loadTemplate(for: target).render(image: image, order: channelOrder)
    }

    private func sanitized(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return String(raw.unicodeScalars.filter { allowed.contains($0) })
    }
}
