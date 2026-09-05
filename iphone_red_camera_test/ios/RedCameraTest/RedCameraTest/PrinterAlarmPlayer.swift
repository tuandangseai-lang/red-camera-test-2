import AVFoundation
import Combine

final class PrinterAlarmPlayer: ObservableObject {
    private var player: AVAudioPlayer?

    func startLooping() {
        if player?.isPlaying == true { return }
        guard let url = Bundle.main.url(forResource: "fire-alarm-sound", withExtension: "mp3") else {
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.duckOthers])
            try session.setActive(true)
            let alarm = try AVAudioPlayer(contentsOf: url)
            alarm.numberOfLoops = -1
            alarm.prepareToPlay()
            alarm.play()
            player = alarm
        } catch {
            player = nil
        }
    }

    func stop() {
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    deinit {
        player?.stop()
    }
}
