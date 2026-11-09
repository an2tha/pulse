import ActivityKit
import Foundation

struct FocusAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var deadline: Date?
        var secondsLeft: Int
        var title: String
        var timerRevision: Int? = nil
        var resumeDeclined: Bool? = nil
    }
    var session: String
}

struct DayWidgetEntry: Codable, Equatable, Sendable {
    let title: String
    let start: Date
    let end: Date
    let minutes: Int
}

struct DayWidgetSnapshot: Codable, Equatable, Sendable {
    var day: Date
    var entries: [DayWidgetEntry]
    var rest: Bool

    func canKeepTimeline(for next: Self, at now: Date) -> Bool {
        guard day == next.day, rest == next.rest, entries.count == next.entries.count,
              entries.first(where: { $0.end > now })?.title == next.entries.first(where: { $0.end > now })?.title
        else { return false }
        return zip(entries, next.entries).allSatisfy { old, new in
            old.title == new.title && old.minutes == new.minutes &&
                abs(old.start.timeIntervalSince(new.start)) < 900 &&
                abs(old.end.timeIntervalSince(new.end)) < 900
        }
    }
}

enum SurfaceData {
    static let suite = "group.app.pulseplanner.pulse"
    static let widgetKey = "pulse.widget.day.v1"
    static let widgetKind = "PulseDay"
    static let today = URL(string: "pulseplanner://today")!
    static let focus = URL(string: "pulseplanner://focus")!

    static func focusID(task: UUID, started: Date) -> String {
        "\(task.uuidString)-\(started.timeIntervalSince1970)"
    }

    static func focusURL(session: String) -> URL {
        focus.appending(queryItems: [URLQueryItem(name: "session", value: session)])
    }

    static func distractionURL(session: String) -> URL {
        focus.appendingPathComponent("capture")
            .appending(queryItems: [URLQueryItem(name: "session", value: session)])
    }

    static func currentDay() -> DayWidgetSnapshot? {
        guard let data = UserDefaults(suiteName: suite)?.data(forKey: widgetKey),
            let day = try? JSONDecoder().decode(DayWidgetSnapshot.self, from: data),
            Calendar.current.isDateInToday(day.day)
        else { return nil }
        return day
    }
}
