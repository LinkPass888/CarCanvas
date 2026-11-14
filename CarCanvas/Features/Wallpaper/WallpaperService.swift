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

    func loadTemplate() throws -> CPBitmapTemplate {
        let resolved = try ContainerResolver().resolve()
        return try WQAccess.shared.withAccess(containerPath: resolved.containerPath) {
            guard let target = try ContainerResolver.cacheFiles(in: resolved.cacheDirectory).first else { throw CCError.noCacheFiles }
            return try CPBitmapTemplate.parse(Data(contentsOf: URL(fileURLWithPath: target.path)))
        }
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
                return autoreleasepool { () -> CGImage? in
                    let url = URL(fileURLWithPath: target.path)
                    var readError: NSError?
                    do {
                        // Native decoding must not be rejected by our narrower
                        // raw-template parser. Only the detached thumbnail escapes.
                        if let image = CCCopyCPBitmapImage(url, &readError), let small = Self.thumbnail(image) { return small }
                        CCLog.info("system CPBitmap preview unavailable for \(target.fileName): \(readError?.localizedDescription ?? "no image"); trying template")
                        let data = try Data(contentsOf: url)
                        let template = try CPBitmapTemplate.parse(data)
                        if let image = template.preview(order: channelOrder), let small = Self.thumbnail(image) { return small }
                        throw CCError.renderFailed
                    } catch {
                        CCLog.error("CPBitmap preview failed for \(target.fileName): system=\(readError?.localizedDescription ?? "no image"); template=\(error.localizedDescription)")
                        return nil
                    }
                }
            }
        } catch {
            CCLog.error("CPBitmap preview access failed for \(target.fileName): \(error.localizedDescription)")
            return nil
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

    private func encode(_ image: CGImage, fallbackTemplate: CPBitmapTemplate? = nil) throws -> Data {
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
        return try loadTemplate().render(image: image, order: channelOrder)
    }

    private func sanitized(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return String(raw.unicodeScalars.filter { allowed.contains($0) })
    }
}
