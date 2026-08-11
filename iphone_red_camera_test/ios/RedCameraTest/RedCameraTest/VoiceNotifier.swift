import AVFoundation
import UIKit

final class VoiceNotifier {
    enum FeedbackKind {
        case success
        case start
        case warning
    }

    private let synthesizer = AVSpeechSynthesizer()

    init() {
        synthesizer.usesApplicationAudioSession = true
    }

    func speak(_ text: String, kind: FeedbackKind, interruptCurrent: Bool = true) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            if interruptCurrent, self.synthesizer.isSpeaking {
                self.synthesizer.stopSpeaking(at: .immediate)
            }

            switch kind {
            case .success:
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            case .start:
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            case .warning:
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            }

            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(language: "vi-VN")
            utterance.rate = 0.50
            utterance.pitchMultiplier = 1.0
            utterance.volume = 1.0
            utterance.preUtteranceDelay = 0.05
            self.synthesizer.speak(utterance)
        }
    }

    func stop() {
        DispatchQueue.main.async { [weak self] in
            self?.synthesizer.stopSpeaking(at: .immediate)
        }
    }
}
