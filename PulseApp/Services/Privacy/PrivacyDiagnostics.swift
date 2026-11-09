import Foundation
import MetricKit

/// Counts delivered by MetricKit. Raw payloads and journal content never enter the report.
final class PrivacyDiagnostics: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = PrivacyDiagnostics()
    private let lock = NSLock()
    private var enabled = false
    private var seen = Set<String>()
    private var counts = Counts()
    private struct Counts: Codable {
        var consentDate: Date?
        var crashes = 0
        var hangs = 0
        var cpuExceptions = 0
        var diskWriteExceptions = 0
        var windows: [String] = []
    }
    private var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Pulse-diagnostic-counts.json")
    }
    func setEnabled(_ newValue: Bool) {
        lock.lock()
        let changed = newValue != enabled
        enabled = newValue
        if changed && newValue {
            counts = (try? JSONDecoder().decode(Counts.self, from: Data(contentsOf: url))) ?? Counts()
            if counts.consentDate == nil {
                counts.consentDate = .now
                writeCounts()
            }
            seen = Set(counts.windows)
        }
        if !newValue {
            counts = Counts()
            seen = []
            try? FileManager.default.removeItem(at: url)
        }
        lock.unlock()
        if changed {
            if newValue { MXMetricManager.shared.add(self) } else { MXMetricManager.shared.remove(self) }
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        lock.lock()
        defer { lock.unlock() }
        guard enabled, let consentDate = counts.consentDate else { return }
        for payload in payloads where payload.timeStampBegin >= consentDate {
            let key = "\(payload.timeStampBegin.timeIntervalSince1970)/\(payload.timeStampEnd.timeIntervalSince1970)"
            // Sessions may redeliver the same window after launch.
            guard seen.insert(key).inserted else { continue }
            counts.crashes += payload.crashDiagnostics?.count ?? 0
            counts.hangs += payload.hangDiagnostics?.count ?? 0
            counts.cpuExceptions += payload.cpuExceptionDiagnostics?.count ?? 0
            counts.diskWriteExceptions += payload.diskWriteExceptionDiagnostics?.count ?? 0
        }
        counts.windows = Array(seen.sorted().suffix(366))
        seen = Set(counts.windows)
        writeCounts()
    }

    private func writeCounts() {
        if let data = try? JSONEncoder().encode(counts) {
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    var summary: String {
        lock.lock()
        defer { lock.unlock() }
        return
            "Crashes: \(counts.crashes)\nHangs: \(counts.hangs)\nCPU exceptions: \(counts.cpuExceptions)\nDisk write exceptions: \(counts.diskWriteExceptions)"
    }
}
