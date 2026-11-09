import Foundation

/// Recurring local clock times. An explicitly moved edge stays anchored when the other edge is edited.
public struct PlannedSleepWindow: Codable, Equatable, Sendable {
    public enum Edge: String, CaseIterable, Codable, Sendable { case bedtime, wake }
    public private(set) var bedtime: Int
    public private(set) var wake: Int
    public private(set) var firstEdge: Edge?
    public private(set) var independent = false

    public init(wake: Int, targetMinutes: Int) {
        self.wake = Self.clock(wake)
        bedtime = Self.clock(wake - min(1439, max(1, targetMinutes)))
    }

    private static func clock(_ minute: Int) -> Int { ((minute % 1440) + 1440) % 1440 }
    public var minutes: Int { Self.clock(wake - bedtime) }
    public func time(_ edge: Edge) -> Int { edge == .wake ? wake : bedtime }

    public func moving(_ edge: Edge, to minute: Int) -> Self {
        let time = Self.clock(minute)
        guard time != self.time(edge) else { return self }
        var result = self
        result.independent = independent || (firstEdge != nil && firstEdge != edge)
        result.firstEdge = firstEdge ?? edge
        if edge == .wake {
            result.wake = time
            if !result.independent { result.bedtime = Self.clock(time - minutes) }
        } else {
            result.bedtime = time
            if !result.independent { result.wake = Self.clock(time + minutes) }
        }
        // Prevent crossing the fixed edge from turning a short night into a near-24-hour window.
        guard (15...960).contains(result.minutes) else { return self }
        return result
    }
}
