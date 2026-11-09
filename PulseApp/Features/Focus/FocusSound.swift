import AVFAudio
import Foundation

@MainActor
final class FocusSound {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var buffer: AVAudioPCMBuffer?
    private var attached = false
    private var sessionActive = false
    func play() async throws {
        if engine.isRunning { return }
        if buffer == nil {
            let samples = await Task.detached(priority: .utility) { () -> [Float] in
                let count = 66150
                var seed: UInt64 = 87423
                var low: Float = 0
                return (0..<count).map { n in
                    seed = seed &* 6_364_136_223_846_793_005 &+ 1
                    let x = Float(seed >> 40) / Float(1 << 23) - 1
                    low = low * 0.90 + x * 0.10
                    let edge = Float(min(1, Double(min(n, count - 1 - n)) / 800))
                    return low * edge * 0.22
                }
            }.value
            try Task.checkCancellation()
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 22050, channels: 1),
                let pcm = AVAudioPCMBuffer(
                    pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
                let channel = pcm.floatChannelData?[0]
            else { throw CocoaError(.coderInvalidValue) }
            pcm.frameLength = pcm.frameCapacity
            samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: $0.count) }
            buffer = pcm
        }
        try Task.checkCancellation()
        if let buffer { try startLoop(buffer) }
    }

    private func startLoop(_ buffer: AVAudioPCMBuffer) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.ambient, options: [.mixWithOthers])
        try session.setActive(true)
        sessionActive = true
        if !attached {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
            attached = true
        }
        do { try engine.start() }
        catch {
            stop()
            throw error
        }
        player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
        player.play()
    }
    func stop() {
        guard sessionActive else { return }
        sessionActive = false
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
