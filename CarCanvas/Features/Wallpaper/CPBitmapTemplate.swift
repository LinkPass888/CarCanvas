import Foundation
import CoreGraphics

/// Only validated single-image, raw 32-bit CPBitmaps can be used as templates.
/// Preserve the complete metadata/trailer; compressed or unknown formats must
/// use the system reader/writer, not a byte-count guess.
struct CPBitmapTemplate {
    let width: Int
    let height: Int
    let alignedWidth: Int
    let trailerLength: Int
    let originalData: Data
    let format: UInt32

    enum ChannelOrder: String, CaseIterable, Codable, Identifiable {
        case bgra, rgba
        var id: String { rawValue }
        var label: String { rawValue.uppercased() }
    }

    /// The common CPBitmap trailer is checked before handing data to any
    /// private decoder or writing an exported file into the system cache.
    static func hasCPBitmapSignature(_ data: Data) -> Bool {
        guard data.count >= 28, data.count <= 256 * 1024 * 1024 else { return false }
        return data.withUnsafeBytes { raw in
            func word(_ distance: Int) -> UInt32 {
                UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: data.count - distance, as: UInt32.self))
            }
            return word(4) == 0xDCB543A2 && word(8) == 1
                && word(20) > 0 && word(20) <= 16_384 && word(16) > 0 && word(16) <= 16_384
        }
    }

    static func parse(_ data: Data) throws -> CPBitmapTemplate {
        guard hasCPBitmapSignature(data) else { throw CCError.unrecognizedTemplate(data.count) }
        func word(_ distanceFromEnd: Int) -> UInt32 {
            data.withUnsafeBytes {
                UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: data.count - distanceFromEnd, as: UInt32.self))
            }
        }
        let width = Int(word(20)), height = Int(word(16)), format = word(12)
        let metadataLength = Int(word(24))
        guard word(4) == 0xDCB543A2, word(8) == 1, format <= 1,
              width > 0, height > 0, width <= 16_384, height <= 16_384,
              metadataLength <= data.count - 28 else { throw CCError.unrecognizedTemplate(data.count) }
        let trailer = 28 + metadataLength
        let pixelLength = data.count - trailer
        guard pixelLength > 0, pixelLength <= 128 * 1024 * 1024 else {
            throw CCError.unrecognizedTemplate(data.count)
        }
        if metadataLength > 0 {
            let metadata = data.subdata(in: pixelLength..<(data.count - 28))
            guard metadata.starts(with: Data("bplist00".utf8)),
                  (try? PropertyListSerialization.propertyList(from: metadata, options: [], format: nil)) != nil else {
                throw CCError.unrecognizedTemplate(data.count)
            }
        }
        // Several alignments can describe the SAME stride when width is already
        // aligned. Deduplicate layouts instead of pretending those are ambiguous.
        let strides = Set([16, 8, 4, 1].map { ((width + $0 - 1) / $0) * $0 })
            .filter { $0 * height * 4 == pixelLength }
        guard strides.count == 1, let aligned = strides.first else {
            throw CCError.unrecognizedTemplate(data.count)
        }
        return CPBitmapTemplate(width: width, height: height, alignedWidth: aligned,
                                trailerLength: trailer, originalData: data, format: format)
    }

    var pixelRegionLength: Int { alignedWidth * height * 4 }

    private func bitmapInfo(order: ChannelOrder) -> CGBitmapInfo {
        let alpha: CGImageAlphaInfo
        if format == 0 { alpha = order == .bgra ? .noneSkipFirst : .noneSkipLast }
        else { alpha = order == .bgra ? .premultipliedFirst : .premultipliedLast }
        return CGBitmapInfo(rawValue: alpha.rawValue)
            .union(order == .bgra ? .byteOrder32Little : .byteOrder32Big)
    }

    static func pixelSize(_ data: Data) -> CGSize? {
        guard hasCPBitmapSignature(data) else { return nil }
        return data.withUnsafeBytes { raw in
            let width = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: data.count - 20, as: UInt32.self))
            let height = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: data.count - 16, as: UInt32.self))
            return CGSize(width: CGFloat(width), height: CGFloat(height))
        }
    }

    /// The crop center uses the photo's top-left coordinate system.
    static func aspectFillRect(imageSize: CGSize, targetSize: CGSize, center: CGPoint) -> CGRect {
        let scale = max(targetSize.width / imageSize.width, targetSize.height / imageSize.height)
        let width = imageSize.width * scale, height = imageSize.height * scale
        let x = min(0, max(targetSize.width - width, targetSize.width / 2 - center.x * width))
        let y = min(0, max(targetSize.height - height, targetSize.height / 2 - (1 - center.y) * height))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    func render(image: CGImage, order: ChannelOrder) throws -> Data {
        var pixels = Data(count: pixelRegionLength)
        let drew = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: alignedWidth * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo(order: order).rawValue) else { return false }
            context.interpolationQuality = .high
            let rect = Self.aspectFillRect(imageSize: CGSize(width: CGFloat(image.width), height: CGFloat(image.height)),
                                           targetSize: CGSize(width: CGFloat(width), height: CGFloat(height)),
                                           center: CGPoint(x: 0.5, y: 0.5))
            context.draw(image, in: rect)
            return true
        }
        guard drew else { throw CCError.renderFailed }
        pixels.append(originalData.suffix(trailerLength))
        return pixels
    }

    /// Read-only provider owns its bytes. Width excludes row padding, and the
    /// selected channel order is the same one used by the fallback renderer.
    func preview(order: ChannelOrder = .bgra) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(originalData.prefix(pixelRegionLength)) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: alignedWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: bitmapInfo(order: order), provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }
}
