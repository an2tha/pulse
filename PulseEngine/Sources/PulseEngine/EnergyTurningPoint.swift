import Foundation

public struct EnergyTurningPoint: Identifiable, Sendable {
    public enum Kind: Sendable { case peak, dip }
    public let kind: Kind
    public let sample: EnergyPoint
    public var id: Date { sample.date }

    /// Compare both shoulders within three hours. A flat top gets one marker,
    /// and small fluctuations below a third of a point stay unlabeled.
    public static func find(in samples: [EnergyPoint]) -> [Self] {
        guard samples.count >= 3 else { return [] }
        var result: [Self] = []
        var start = 1
        while start < samples.count - 1 {
            let value = samples[start].score
            var end = start
            while end + 1 < samples.count && abs(samples[end + 1].score - value) < 0.001 {
                end += 1
            }
            guard end + 1 < samples.count else { break }
            let before = samples[max(0, start - 3)..<start].map(\.score)
            let after = samples[(end + 1)..<min(samples.count, end + 4)].map(\.score)
            let kind: Kind?
            if before.last! < value && after.first! < value &&
                min(value - before.min()!, value - after.min()!) >= 0.33 {
                kind = .peak
            } else if before.last! > value && after.first! > value &&
                min(before.max()! - value, after.max()! - value) >= 0.33 {
                kind = .dip
            } else {
                kind = nil
            }
            if let kind { result.append(Self(kind: kind, sample: samples[start + (end - start) / 2])) }
            start = end + 1
        }
        return result
    }
}
