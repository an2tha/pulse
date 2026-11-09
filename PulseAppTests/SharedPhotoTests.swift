import Foundation
import ImageIO
import PulseEngine
import SwiftData
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import Pulse

@Suite struct SharedPhotoTests {
    private func picture() throws -> Data {
        let context = try #require(CGContext(data: nil, width: 1600, height: 40, bitsPerComponent: 8,
            bytesPerRow: 6400, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let data = NSMutableData()
        let output = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        let image = try #require(context.makeImage())
        CGImageDestinationAddImage(output, image, [kCGImagePropertyGPSDictionary: [
            kCGImagePropertyGPSLatitude: 52.5, kCGImagePropertyGPSLatitudeRef: "N"
        ]] as CFDictionary)
        try #require(CGImageDestinationFinalize(output))
        return data as Data
    }

    @Test func sharedPixelsAreResizedOrientedAndStrippedOfSourceLocation() throws {
        let input = try picture()
        let original = try #require(CGImageSourceCreateWithData(input as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(original, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyGPSDictionary] != nil)
        let jpeg = try PreparedPhoto.jpeg(from: input)
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let saved = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(saved[kCGImagePropertyGPSDictionary] == nil)
        #expect(saved[kCGImagePropertyPixelWidth] as? Int == 1440)
        #expect(PreparedPhoto.isValid(jpeg))
        #expect(throws: CaptureError.self) { try SharedCapture(text: "Photo", url: nil, jpeg: input) }
        #expect(throws: CaptureError.self) { try SharedCapture(text: "Photo", url: nil, jpeg: Data([1])) }
        #expect(throws: CaptureError.self) { try SharedCapture(text: "Text only", url: nil, alreadyCompleted: true) }
    }

    @Test func aLatePhotoResultCannotReplaceANewerSelection() throws {
        var selection = PhotoSelection<String>()
        selection.choose("first")
        let first = try #require(selection.current?.id)
        selection.choose("second")
        let second = try #require(selection.current?.id)
        let discarded = selection.finish(first)
        #expect(!discarded && selection.current?.id == second)
        let accepted = selection.finish(second)
        #expect(accepted && selection.current == nil)
        let lateFailure = selection.finish(first)
        #expect(!lateFailure)
    }

    @Test func cancelledAndOversizedPhotoFilesAreRejectedBeforeDecoding() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        // A valid JPEG with trailing bytes would still decode without the file budget.
        try picture().write(to: url)
        let file = try FileHandle(forWritingTo: url)
        try file.truncate(atOffset: 64 * 1024 * 1024 + 1)
        try file.close()
        await #expect(throws: CaptureError.self) { try await PreparedPhoto.pickedJPEG(from: url) }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await PreparedPhoto.pickedJPEG(from: url)
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
    }

    private func writeFixture(_ size: CGSize, orientation: Int, to url: URL) throws {
        let width = Int(size.width), height = Int(size.height)
        let buffer = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        for index in 0..<4 {
            buffer.setFillColor(gray: CGFloat(index) / 3, alpha: 1)
            buffer.fill(CGRect(x: CGFloat(index % 2) * size.width / 2, y: CGFloat(index / 2) * size.height / 2,
                               width: size.width / 2, height: size.height / 2))
        }
        let output = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(output, try #require(buffer.makeImage()), [
            kCGImagePropertyOrientation: orientation, kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 52.5, kCGImagePropertyGPSLatitudeRef: "N"]
        ] as CFDictionary)
        try #require(CGImageDestinationFinalize(output))
    }

    private func corners(_ image: CGImage) throws -> [Int] {
        var pixels = [UInt8](repeating: 0, count: 64 * 64)
        try pixels.withUnsafeMutableBytes { bytes in
            let buffer = try #require(CGContext(data: bytes.baseAddress, width: 64, height: 64, bitsPerComponent: 8,
                bytesPerRow: 64, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
            buffer.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        return [(16, 16), (48, 16), (16, 48), (48, 48)].map { x, y in Int(pixels[64 * y + x]) }
    }

    @Test func cameraAndFileInputsAgreeForLargeRotatedAndMirroredPhotos() async throws {
        for (width, height, exif, orientation) in [(4032, 3024, 6, UIImage.Orientation.right),
                                                   (8064, 6048, 7, UIImage.Orientation.rightMirrored)] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
            defer { try? FileManager.default.removeItem(at: url) }
            try writeFixture(CGSize(width: width, height: height), orientation: exif, to: url)
            let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
            let pixels = try #require(CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary))
            let camera = try await PreparedPhoto.cameraJPEG(from: UIImage(cgImage: pixels, scale: 1, orientation: orientation))
            let file = try await PreparedPhoto.pickedJPEG(from: url)
            var samples: [[Int]] = []
            for jpeg in [camera, file] {
                #expect(PreparedPhoto.isValid(jpeg))
                let reader = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
                let properties = try #require(CGImageSourceCopyPropertiesAtIndex(reader, 0, nil) as? [CFString: Any])
                #expect(properties[kCGImagePropertyGPSDictionary] == nil)
                #expect((properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
                let image = try #require(CGImageSourceCreateImageAtIndex(reader, 0, nil))
                #expect(image.width == 1080 && image.height == 1440)
                samples.append(try corners(image))
            }
            #expect(Set(samples[0]).count == 4, "Corner samples: \(samples)")
            #expect(zip(samples[0], samples[1]).allSatisfy { abs($0 - $1) < 12 })
        }
    }

    @Test func aDistractionPhotoWaitingForSpaceRetainsItsOriginalSprint() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = SharedCaptureQueue(directory: directory)
        let jpeg = try PreparedPhoto.jpeg(from: picture())
        let start = Date.now.addingTimeInterval(-300)
        let session = ActiveSession(openSprintSeconds: 120, now: start, tick: 0, boot: "local")
        var journal = Journal()
        journal.beginLocalSession(session)
        let item = try SharedCapture(text: "An interesting photo tomorrow at 10am", url: nil, created: start.addingTimeInterval(10),
                                     jpeg: jpeg, distraction: true)
        try await queue.add(item)
        let pending = try await queue.batch(availableBytes: 0, availableCount: 0, alreadyImported: [])
        #expect(pending.waitingForSpace && pending.captures.isEmpty)
        var record = session.record(now: start.addingTimeInterval(90), tick: 90, boot: "local")
        record.finishedAt = start.addingTimeInterval(90)
        journal.sessions = [record]
        journal.beginLocalSession(ActiveSession(openSprintSeconds: 120, now: .now, tick: 300, boot: "local"))
        var restarted = try JournalArchive.readDatabase(JournalArchive.database(journal))
        let released = try await queue.pending()
        restarted.importSharedCaptures(released + released)
        #expect(restarted.tasks.count == 1 && restarted.tasks.first?.capturedDuringSessionID == record.id)
        #expect(restarted.tasks.first?.isInboxOnly == true && restarted.tasks.first?.plannedStart == nil)
        #expect(restarted.photos?.count == 1 && restarted.photos?.first?.jpeg == jpeg && restarted.photos?.first?.completion == false)
    }

    @Test func aFullLogLeavesPhotoPendingAndLetsTextPassBeforeRetry() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let queue = SharedCaptureQueue(directory: folder)
        let jpeg = try PreparedPhoto.jpeg(from: picture())
        let photo = try SharedCapture(text: "Water the fern", url: nil, jpeg: jpeg, alreadyCompleted: true)
        let text = try SharedCapture(text: "Write field notes", url: URL(string: "https://example.com/"))
        try await queue.add(photo)
        try await queue.add(photo)
        try await queue.add(text)
        let full = try await queue.batch(availableBytes: jpeg.count - 1, availableCount: 1, alreadyImported: [])
        #expect(full.waitingForSpace && full.captures.map(\.id) == [text.id])
        var journal = Journal()
        journal.importSharedCaptures(full.captures)
        try await queue.acknowledge([text.id])
        var existing = JournalPhoto(taskID: text.id, title: "Earlier photo", completion: false, jpeg: jpeg)
        journal.photos = (0..<300).map { _ in existing.id = UUID(); return existing }
        journal.importSharedCaptures([photo])
        #expect(journal.tasks.count == 1 && journal.importedShares?.contains(photo.id) != true)
        journal.photos?.removeLast()
        let available = try await queue.batch(availableBytes: jpeg.count, availableCount: 1, alreadyImported: [text.id])
        journal.importSharedCaptures(available.captures)
        let imported = try #require(journal.photos?.last)
        #expect(imported.taskID == photo.id && imported.completion && imported.jpeg == jpeg)
        #expect(journal.tasks.last?.done == true && journal.tasks.last?.completedAt == photo.created)
        let restarted = try JournalArchive.readDatabase(JournalArchive.database(journal))
        let replay = try await queue.batch(availableBytes: 0, availableCount: 0, alreadyImported: restarted.importedShares ?? [])
        #expect(replay.known == [photo.id] && replay.captures.isEmpty && !replay.waitingForSpace)
        try await queue.acknowledge(replay.known)
        #expect(try await queue.pending().isEmpty)
    }
}
