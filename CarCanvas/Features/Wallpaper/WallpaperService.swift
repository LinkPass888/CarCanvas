import Foundation
import CoreGraphics
import ImageIO

/// Previews and replacements for an explicitly selected single cache file.
final class WallpaperService {
    private let history = HistoryStore.shared
    private let channelOrder: CPBitmapTemplate.ChannelOrder
    static let thumbnailDimension = 320

    init(channelOrder: CPBitmapTemplate.ChannelOrder = .bgra) {
        self.channelOrder = channelOrder
    }

    /// A selected cache supplies the fallback geometry; never substitute the
    /// first Dark/Light file or create a paired export for this single-file edit.
    func targetPixelSize(for target: WallpaperTarget) throws -> CGSize {
        try autoreleasepool { try originalReference(for: target).size }
    }

    func prepareReplacement(imageURL: URL, target: WallpaperTarget,
                            cropCenter: CGPoint = CGPoint(x: 0.5, y: 0.5),
                            expectedPixelSize: CGSize? = nil,
                            outputPixelSize: CGSize? = nil) throws -> (data: Data, preview: CGImage) {
        try autoreleasepool {
            let reference = try originalReference(for: target)
            let size = outputPixelSize ?? reference.size
            guard expectedPixelSize == nil || expectedPixelSize == reference.size,
                  cropCenter.x.isFinite, cropCenter.y.isFinite,
                  size.width.isFinite, size.height.isFinite,
                  size.width >= 1, size.height >= 1, size.width <= 16_384, size.height <= 16_384,
                  size.width.rounded() == size.width, size.height.rounded() == size.height,
                  size.width * size.height <= 32 * 1024 * 1024 else { throw CCError.renderFailed }
            let image = try croppedImage(photo(at: imageURL), size: size, center: cropCenter)
            let data = try encode(image, fallbackData: reference.data, expectedPixelSize: size)
            guard let preview = Self.thumbnail(image) else { throw CCError.renderFailed }
            return (data, preview)
        }
    }

    private func originalReference(for selected: WallpaperTarget) throws -> (data: Data, size: CGSize) {
        let resolved = try ContainerResolver().resolve()
        return try WQAccess.shared.withAccess(containerPath: resolved.containerPath) {
            let files = try ContainerResolver.cacheFiles(in: resolved.cacheDirectory)
            guard let current = files.first(where: {
                $0.path == selected.path && $0.fileName == selected.fileName && $0.appearance == selected.appearance
            }) else { throw CCError.templateUnreadable(selected.fileName) }
            let data: Data, url: URL
            if let backup = try history.originalBackup(for: current.fileName) {
                data = try history.backupData(for: backup)
                url = history.backupsDirectory.appendingPathComponent(backup.backupFileName)
            } else {
                url = URL(fileURLWithPath: current.path)
                data = try Data(contentsOf: url)
            }
            if let size = CPBitmapTemplate.pixelSize(data) { return (data, size) }
            var error: NSError?
            guard let image = CCCopyCPBitmapImage(url, &error) else { throw CCError.renderFailed }
            return (data, CGSize(width: CGFloat(image.width), height: CGFloat(image.height)))
        }
    }

    private func croppedImage(_ image: CGImage, size: CGSize, center: CGPoint) throws -> CGImage {
        let width = Int(size.width), height = Int(size.height)
        guard width > 0, height > 0, width <= 16_384, height <= 16_384,
              width * height <= 32 * 1024 * 1024,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { throw CCError.renderFailed }
        let rect = CPBitmapTemplate.aspectFillRect(imageSize: CGSize(width: CGFloat(image.width), height: CGFloat(image.height)),
                                                  targetSize: size, center: center)
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        guard let cropped = context.makeImage() else { throw CCError.renderFailed }
        return cropped
    }

    /// ImageIO handles real photo formats and their EXIF orientation, not
    /// CPBitmap. A pick displays immediately without retaining full pixels.
    static func photoPreview(data: Data, maxPixelSize: Int = thumbnailDimension) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary)
    }

    private func photo(at url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight as String] as? NSNumber,
              width.intValue > 0, height.intValue > 0 else { throw CCError.renderFailed }
        let maximum = min(max(width.intValue, height.intValue), 16_384)
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maximum
              ] as CFDictionary) else { throw CCError.renderFailed }
        return image
    }

    func previewImage(for target: WallpaperTarget, resolved: ContainerResolver.Resolved,
                      onPixelSize: ((CGSize?) -> Void)? = nil) -> CGImage? {
        do {
            return try WQAccess.shared.withAccess(containerPath: resolved.containerPath) {
                guard try WQWhitelist.cacheDirectoryExists(resolved.cacheDirectory),
                      try ContainerResolver.cacheFiles(in: resolved.cacheDirectory).contains(where: { $0.path == target.path && $0.byteCount > 0 && $0.byteCount <= 256 * 1024 * 1024 }) else {
                    throw CCError.templateUnreadable(target.fileName)
                }
                let url = URL(fileURLWithPath: target.path)
                onPixelSize?(CPBitmapTemplate.pixelSize(at: url))
                return previewImage(at: url)
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

    /// A writer failure may only fall back to the selected file's original.
    private func encode(_ image: CGImage, fallbackData: Data,
                        expectedPixelSize: CGSize) throws -> Data {
        if CCBitmapWriterIsAvailable() {
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("cc-bitmap-\(UUID().uuidString).cpbitmap")
            defer { try? FileManager.default.removeItem(at: temporary) }
            var writeError: NSError?
            if CCWriteCPBitmap(image, temporary, &writeError) {
                let data = try Data(contentsOf: temporary)
                if CPBitmapTemplate.hasCPBitmapSignature(data),
                   CPBitmapTemplate.pixelSize(data) == expectedPixelSize { return data }
            }
            CCLog.info("system CPBitmap writer failed (\(writeError?.localizedDescription ?? "empty output")); using validated template")
        }
        let template = try CPBitmapTemplate.parse(fallbackData)
        guard expectedPixelSize == CGSize(width: CGFloat(template.width), height: CGFloat(template.height)) else {
            throw NSError(domain: "CarCanvas.PhotoCrop", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: L("CROP_CUSTOM_SIZE_UNAVAILABLE")])
        }
        return try template.render(image: image, order: channelOrder)
    }
}
