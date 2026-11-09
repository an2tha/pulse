import Foundation
import ImageIO
import UniformTypeIdentifiers

enum PreparedPhoto {
    static let byteLimit = 3 * 1024 * 1024
    private static let inputLimit = 64 * 1024 * 1024
    static let side = 1440
    private static var readingOptions: CFDictionary { [kCGImageSourceShouldCache: false] as CFDictionary }

    static func jpeg(from bytes: Data) throws -> Data {
        guard bytes.count <= inputLimit,
              let source = CGImageSourceCreateWithData(bytes as CFData, readingOptions) else { throw CaptureError.image }
        return try encode(source)
    }

    static func jpeg(from file: URL) throws -> Data {
        guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= inputLimit,
              let source = CGImageSourceCreateWithURL(file as CFURL, readingOptions) else { throw CaptureError.image }
        return try encode(source)
    }

    private static func encode(_ source: CGImageSource) throws -> Data {
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: side,
            kCGImageSourceCreateThumbnailWithTransform: true
        ] as CFDictionary) else { throw CaptureError.image }
        return try jpeg(fromOrientedPixels: image)
    }

    static func jpeg(fromOrientedPixels image: CGImage) throws -> Data {
        guard image.width <= side, image.height <= side else { throw CaptureError.image }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw CaptureError.image }
        // Re-encode the oriented pixels, without copying location or source metadata.
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.76] as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length <= byteLimit else { throw CaptureError.image }
        return output as Data
    }

    static func isValid(_ jpeg: Data) -> Bool {
        guard jpeg.count <= byteLimit, let source = CGImageSourceCreateWithData(jpeg as CFData, readingOptions),
              CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return false }
        return (1...side).contains(width) && (1...side).contains(height)
    }
}
