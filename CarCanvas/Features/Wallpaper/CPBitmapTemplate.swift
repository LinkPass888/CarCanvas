import Foundation
import CoreGraphics
import ImageIO

/// A CPBitmap file is read as an opaque template.
///
/// Apple never documented the format. Public decoders disagree on BGRA vs
/// RGBA, 4/8/16-pixel row alignment, and whether the trailer is 24 or 78
/// bytes. We therefore do NOT hand-write a header. Instead we derive the
/// geometry from the file we are about to replace, keep the trailer byte-for-
/// byte, and only rewrite the pixel region.
struct CPBitmapTemplate {
    let width: Int
    let height: Int
    let alignedWidth: Int
    let trailerLength: Int
    let originalData: Data

    /// Controls R/B swapping. Exposed in Settings because no public source
    /// agrees; the user verifies with the built-in preview on a real device.
    enum ChannelOrder: String, CaseIterable, Codable, Identifiable {
        case bgra, rgba
        var id: String { rawValue }
        var label: String { rawValue.uppercased() }
    }

    private static let alignments = [16, 8, 4, 1]
    private static let trailerLengths = [78, 24]

    /// Reads width/height from the last 24 bytes (little-endian Int32 at
    /// EOF-20 and EOF-16) — the one field all public decoders agree on.
    private static func dimensions(_ data: Data) -> (Int, Int)? {
        guard data.count >= 24 else { return nil }
        let w: Int32 = data.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: data.count - 20, as: Int32.self)
        }
        let h: Int32 = data.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: data.count - 16, as: Int32.self)
        }
        let width = Int(Int32(littleEndian: w)), height = Int(Int32(littleEndian: h))
        guard width > 0, height > 0, width <= 16_384, height <= 16_384 else { return nil }
        return (width, height)
    }

    /// Tries each (alignment, trailer) pair and keeps the one whose byte
    /// count matches the file exactly. Ambiguity is reported instead of
    /// silently guessed.
    static func parse(_ data: Data) throws -> CPBitmapTemplate {
        guard let (width, height) = dimensions(data) else {
            throw CCError.unrecognizedTemplate(data.count)
        }
        var matches: [(aligned: Int, trailer: Int, alignment: Int)] = []
        for alignment in alignments {
            let aligned = ((width + alignment - 1) / alignment) * alignment
            for trailer in trailerLengths {
                if aligned * height * 4 + trailer == data.count {
                    matches.append((aligned, trailer, alignment))
                }
            }
        }
        guard let best = matches.first else {
            throw CCError.unrecognizedTemplate(data.count)
        }
        return CPBitmapTemplate(width: width,
                                height: height,
                                alignedWidth: best.aligned,
                                trailerLength: best.trailer,
                                originalData: data)
    }

    var pixelRegionLength: Int { alignedWidth * height * 4 }

    /// Renders `image` into the template geometry and returns a complete
    /// file: new pixel bytes + the untouched original trailer.
    func render(image: CGImage, order: ChannelOrder) throws -> Data {
        let bytesPerRow = alignedWidth * 4
        var pixels = [UInt8](repeating: 0, count: pixelRegionLength)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        let drew: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress,
                                      width: alignedWidth,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow,
                                      space: colorSpace,
                                      bitmapInfo: bitmapInfo.rawValue) else {
                return false
            }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { throw CCError.renderFailed }

        if order == .bgra {
            for i in stride(from: 0, to: pixelRegionLength, by: 4) {
                let r = pixels[i]
                pixels[i] = pixels[i + 2]
                pixels[i + 2] = r
            }
        }

        var out = Data(pixels)
        out.append(originalData.suffix(trailerLength))
        return out
    }

    /// Produces a preview using the same geometry, so the user can eyeball
    /// channel order / orientation before committing an overwrite.
    func preview() -> CGImage? {
        let bytesPerRow = alignedWidth * 4
        return originalData.withUnsafeBytes { raw -> CGImage? in
            guard let base = raw.baseAddress else { return nil }
            let ctx = CGContext(data: UnsafeMutableRawPointer(mutating: base),
                                width: alignedWidth,
                                height: height,
                                bitsPerComponent: 8,
                                bytesPerRow: bytesPerRow,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).rawValue)
            return ctx?.makeImage()
        }
    }
}
