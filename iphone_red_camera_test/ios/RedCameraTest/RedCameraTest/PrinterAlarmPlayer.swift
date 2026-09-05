import AVFoundation
import Combine

final class PrinterAlarmPlayer: ObservableObject {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let gain = AVAudioUnitEQ(numberOfBands: 0)
    private let peakControl = AVAudioUnitDynamicsProcessor()
    private var graphIsReady = false

    func startLooping() {
        if player.isPlaying { return }
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
                engine.attach(peakControl)
                engine.connect(player, to: gain, format: buffer.format)
                engine.connect(gain, to: peakControl, format: buffer.format)
                engine.connect(peakControl, to: engine.mainMixerNode, format: buffer.format)
                graphIsReady = true
            }

            // +9.54 dB is a 3x signal gain. Peak control prevents the extra
            // gain from turning a loud alarm sample into harsh clipping.
            gain.globalGain = 9.54
            peakControl.threshold = -2
            peakControl.headRoom = 0.1
            peakControl.attackTime = 0.001
            peakControl.releaseTime = 0.05
            player.volume = 1
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
