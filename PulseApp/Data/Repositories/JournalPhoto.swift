import Foundation
import PulseEngine

struct JournalPhoto: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var date = Date.now
    var taskID: UUID
    var title: String
    var completion: Bool
    var jpeg: Data
    var caption: String?
    static func matching(_ photos: [Self], query: String, tasks: [PlanTask]) -> [Self] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return photos }
        let linked = Set(photos.map(\.taskID))
        let matchingTasks = Set(tasks.lazy.filter {
            linked.contains($0.id) && ($0.title.localizedStandardContains(term) || $0.project?.localizedStandardContains(term) == true)
        }.map(\.id))
        return photos.filter {
            $0.title.localizedStandardContains(term) || $0.caption?.localizedStandardContains(term) == true || matchingTasks.contains($0.taskID)
        }
    }

    static let maximumCount = 300
    static let budget = 24 * 1024 * 1024
    var isSafeImage: Bool { PreparedPhoto.isValid(jpeg) }
    static func fits(_ bytes: Data, in journal: Journal) -> Bool {
        (journal.photos?.count ?? 0) < maximumCount
            && bytes.count + (journal.photos ?? []).reduce(0) { $0 + $1.jpeg.count } <= budget
    }
}
