import AVFoundation
import Combine
import Foundation

final class PrinterAlarmPlayer: ObservableObject {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let gain = AVAudioUnitEQ(numberOfBands: 0)
    private var graphIsReady = false
    private var requestedLevel: Float = 0.7
    private let criticalAlarmMinimumVolume: Float = 0.75

    private var effectiveAlarmVolume: Float {
        // A printer fault is safety-critical, so a noisy or disconnected
        // potentiometer must never mute it. The full knob travel still gives
        // useful control, but only across the safe 75...100% range.
        return criticalAlarmMinimumVolume
            + (1 - criticalAlarmMinimumVolume) * powf(requestedLevel, 1.45)
    }

    func setLevel(_ normalizedLevel: Double) {
        let clamped = Float(min(1, max(0, normalizedLevel)))
        requestedLevel = clamped
        player.volume = effectiveAlarmVolume
    }

    func startLooping() {
        // AVAudioSession may be interrupted even while AVAudioPlayerNode still
        // reports that it is playing. Only skip setup when both are healthy.
        if player.isPlaying && engine.isRunning { return }
        if player.isPlaying { player.stop() }
        guard let url = Bundle.main.url(forResource: "fire-alarm-sound", withExtension: "mp3") else {
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.duckOthers])
            try session.setActive(true)

            let file = try AVAudioFile(forReading: url)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)
            ) else { return }
            try file.read(into: buffer)

            if !graphIsReady {
                engine.attach(player)
                engine.attach(gain)
                engine.connect(player, to: gain, format: buffer.format)
                engine.connect(gain, to: engine.mainMixerNode, format: buffer.format)
                graphIsReady = true
            }

            // +9.54 dB is a 3x signal gain. The system output mixer applies
            // the final hardware limit while keeping the alarm at full volume.
            gain.globalGain = 9.54
            player.volume = effectiveAlarmVolume
            player.scheduleBuffer(buffer, at: nil, options: [.loops])
            engine.prepare()
            if !engine.isRunning { try engine.start() }
            player.play()
        } catch {
            player.stop()
            engine.stop()
        }
    }

    func stop() {
        player.stop()
        engine.pause()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    deinit {
        player.stop()
        engine.stop()
    }
}
