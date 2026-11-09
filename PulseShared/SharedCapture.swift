import Foundation

/// Transfer only what a person explicitly saved from the share sheet.
/// The journal itself never leaves the private app container.
struct SharedCapture: Codable, Identifiable, Sendable {
    let id: UUID
    let created: Date
    let text: String
    let url: URL?
    let jpeg: Data?
    let alreadyCompleted: Bool?
    let distraction: Bool?
    let timingCaption: String?
    let timeZoneID: String?

    init(text: String, url: URL?, id: UUID = UUID(), created: Date = .now, jpeg: Data? = nil, alreadyCompleted: Bool = false,
         distraction: Bool = false, timingCaption: String? = nil, timeZoneID: String? = nil) throws {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw CaptureError.empty }
        guard cleaned.count <= 32_000 else { throw CaptureError.tooLong }
        guard created.timeIntervalSince1970.isFinite, abs(created.timeIntervalSince1970) < 32_000_000_000 else {
            throw CaptureError.unsupported
        }
        guard url.map(Self.isWebLink) ?? true else { throw CaptureError.unsupported }
        guard jpeg.map(PreparedPhoto.isValid) != false, !alreadyCompleted || jpeg != nil else { throw CaptureError.image }
        let caption = timingCaption?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (caption?.count ?? 0) <= 500 else { throw CaptureError.caption }
        guard !distraction || !alreadyCompleted else { throw CaptureError.unsupported }
        guard timeZoneID.map({ TimeZone(identifier: $0) != nil }) != false else { throw CaptureError.unsupported }
        self.distraction = distraction ? true : nil
        self.timingCaption = distraction && caption?.isEmpty == false ? caption : nil
        self.timeZoneID = distraction ? timeZoneID ?? TimeZone.current.identifier : nil
        self.jpeg = jpeg
        self.alreadyCompleted = alreadyCompleted ? true : nil
        self.id = id
        self.created = created
        self.text = cleaned
        self.url = url
    }

    static func isWebLink(_ url: URL) -> Bool {
        ["https", "http"].contains(url.scheme?.lowercased() ?? "") && url.host?.isEmpty == false
    }
}

enum CaptureError: LocalizedError {
    case empty, tooLong, unsupported, inaccessible, image, caption
    var errorDescription: String? {
        switch self {
        case .caption: "Keep the timing note under 500 characters."
        case .image: "This photo couldn’t be prepared. Choose one image under 64 MB."
        case .empty: "Enter a task before adding it."
        case .tooLong: "This capture is too long. Shorten the text and try again."
        case .unsupported: "Choose text, a web link, or one photo to add to Pulse."
        case .inaccessible: "The inbox couldn’t be opened. Try again."
        }
    }
}

actor SharedCaptureQueue {
    static let shared = SharedCaptureQueue()
    private static let textLimit = 256 * 1024
    private static let byteLimit = textLimit + 4 * ((PreparedPhoto.byteLimit + 2) / 3)

    struct Batch {
        var captures: [SharedCapture] = []
        var known = Set<UUID>()
        var waitingForSpace = false
    }
    private let directory: URL?

    init(directory: URL? = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SurfaceData.suite)?
        .appendingPathComponent("Inbox", isDirectory: true)) {
        self.directory = directory
    }

    func add(_ capture: SharedCapture) throws {
        guard let directory else { throw CaptureError.inaccessible }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var folder = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        let writer = JSONEncoder()
        writer.outputFormatting = [.withoutEscapingSlashes]
        let bytes = try writer.encode(capture)
        guard bytes.count <= (capture.jpeg == nil ? Self.textLimit : Self.byteLimit) else { throw CaptureError.tooLong }
        try bytes.write(to: file(capture.id, in: directory), options: [.atomic, .completeFileProtection])
    }

    func pending() throws -> [SharedCapture] {
        try batch(availableBytes: .max, availableCount: .max, alreadyImported: []).captures
    }

    func batch(availableBytes: Int, availableCount: Int, alreadyImported: Set<UUID>) throws -> Batch {
        var bytesLeft = availableBytes
        var slots = availableCount
        var result = Batch()
        let files = try captureFiles().map { file in
            (file, (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
        }.sorted { ($0.1, $0.0.lastPathComponent) < ($1.1, $1.0.lastPathComponent) }
        for (location, _) in files {
            guard let id = UUID(uuidString: location.deletingPathExtension().lastPathComponent) else { continue }
            if alreadyImported.contains(id) { result.known.insert(id); continue }
            guard let size = try? location.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= Self.byteLimit,
                  let data = try? Data(contentsOf: location, options: .mappedIfSafe),
                  let item = try? JSONDecoder().decode(SharedCapture.self, from: data), item.id == id,
                  item.jpeg != nil || size <= Self.textLimit,
                  item.distraction != true || item.timingCaption == nil || item.timeZoneID != nil,
                  let checked = try? SharedCapture(text: item.text, url: item.url, id: id, created: item.created,
                                                   jpeg: item.jpeg, alreadyCompleted: item.alreadyCompleted == true,
                                                   distraction: item.distraction == true, timingCaption: item.timingCaption, timeZoneID: item.timeZoneID)
            else { continue }
            if let jpeg = checked.jpeg {
                guard slots > 0, jpeg.count <= bytesLeft else {
                    result.waitingForSpace = true
                    continue
                }
                slots -= 1
                bytesLeft -= jpeg.count
            }
            result.captures.append(checked)
        }
        result.captures.sort { ($0.created, $0.id.uuidString) < ($1.created, $1.id.uuidString) }
        return result
    }

    func acknowledge(_ ids: Set<UUID>) throws {
        guard let directory else { throw CaptureError.inaccessible }
        for id in ids { try remove(file(id, in: directory)) }
    }

    func clear() throws {
        for location in try captureFiles() { try remove(location) }
    }

    private func captureFiles() throws -> [URL] {
        guard let directory else { throw CaptureError.inaccessible }
        do {
            return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .creationDateKey],
                                                              options: .skipsHiddenFiles).filter { $0.pathExtension == "capture" }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
    }

    private func file(_ id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("capture")
    }

    private func remove(_ location: URL) throws {
        do { try FileManager.default.removeItem(at: location) }
        catch let error as CocoaError where error.code == .fileNoSuchFile {}
    }
}
