import Foundation

/// Only the on-device database references separate photo rows. Exported backups
/// always contain their JPEGs and can be restored without the originating device.
enum LocalPictures {
    struct Cached {
        let payloadID: UUID
        let jpeg: Data
    }

    struct Loaded {
        var journal: Journal
        var cache: [UUID: Cached] = [:]
        var unavailable = 0
    }

    struct Document {
        let bytes: Data
        var payloadIDs: Set<UUID> = []
    }

    private struct Header: Decodable {
        let format: String?
        let version: Int?
    }

    private struct Picture: Codable {
        let id: UUID
        let payloadID: UUID
        let taskID: UUID
        let date: Date
        let title: String
        let completion: Bool
        let caption: String?
    }

    private struct Envelope: Codable {
        let format: String
        let version: Int
        let journal: Journal
        let pictures: [Picture]
    }

    static func key(_ id: UUID) -> String { "picture/" + id.uuidString }

    static func encode(_ journal: Journal, cache: inout [UUID: Cached], insert: (UUID, Data) -> Void) throws -> Document {
        guard let photos = journal.photos, !photos.isEmpty else {
            return try Document(bytes: JournalArchive.database(journal))
        }
        guard photos.count <= 300, Set(photos.map(\.id)).count == photos.count,
              photos.reduce(0, { $0 + $1.jpeg.count }) <= JournalPhoto.budget else { throw JournalArchive.Failure.invalid }
        var body = journal
        body.photos = nil
        var pictures: [Picture] = []
        for photo in photos {
            let id: UUID
            if let saved = cache[photo.id], saved.jpeg == photo.jpeg {
                id = saved.payloadID
            } else {
                guard photo.isSafeImage else { throw JournalArchive.Failure.invalid }
                id = UUID()
                insert(id, photo.jpeg)
                cache[photo.id] = Cached(payloadID: id, jpeg: photo.jpeg)
            }
            pictures.append(Picture(id: photo.id, payloadID: id, taskID: photo.taskID, date: photo.date,
                                    title: photo.title, completion: photo.completion, caption: photo.caption))
        }
        let envelope = Envelope(format: "app.pulseplanner.journal", version: 2, journal: body, pictures: pictures)
        return try Document(bytes: JSONEncoder().encode(envelope), payloadIDs: Set(pictures.map(\.payloadID)))
    }

    static func read(_ bytes: Data, payload: (UUID) throws -> Data?) throws -> Loaded {
        let decoder = JSONDecoder()
        let header = try decoder.decode(Header.self, from: bytes)
        guard header.version == 2 && header.format == "app.pulseplanner.journal" else {
            return try Loaded(journal: JournalArchive.readDatabase(bytes))
        }
        let envelope = try decoder.decode(Envelope.self, from: bytes)
        guard envelope.journal.photos == nil, envelope.pictures.count <= 300,
              Set(envelope.pictures.map(\.id)).count == envelope.pictures.count else { throw JournalArchive.Failure.invalid }
        var result = Loaded(journal: envelope.journal)
        var pictures: [JournalPhoto] = []
        for ref in envelope.pictures {
            guard let jpeg = try payload(ref.payloadID) else {
                result.unavailable += 1
                continue
            }
            let photo = JournalPhoto(id: ref.id, date: ref.date, taskID: ref.taskID, title: ref.title,
                                     completion: ref.completion, jpeg: jpeg, caption: ref.caption)
            guard photo.isSafeImage else {
                result.unavailable += 1
                continue
            }
            result.cache[ref.id] = Cached(payloadID: ref.payloadID, jpeg: jpeg)
            pictures.append(photo)
        }
        result.journal.photos = pictures
        try JournalArchive.validate(result.journal)
        return result
    }
}
