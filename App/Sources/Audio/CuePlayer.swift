import Foundation
import TeleopCore

/// Plays feedback events on the device: the scheduler decides, the haptic, sound and speech players play.
/// Main queue only.
final class CuePlayer {
    /// The operator's hold engaged now, for "GO only for its own hold".
    var currentHold: () -> Int? = { nil }
    var onLog: ((String) -> Void)?

    private var scheduler = CueScheduler()
    private let haptics: HapticsPlaying
    private let sounds: SoundPlaying
    private let speech: SpeechPlaying
    private let nowMs: () -> Int
    private var timer: Timer?

    init(haptics: HapticsPlaying, sounds: SoundPlaying, speech: SpeechPlaying, nowMs: @escaping () -> Int) {
        self.haptics = haptics
        self.sounds = sounds
        self.speech = speech
        self.nowMs = nowMs
        speech.onFinished = { [weak self] id in
            guard let self else { return }
            run(scheduler.speechFinished(id: id, at: self.nowMs()))
        }
    }

    /// Every cue decided so far, newest last.
    var log: [CueLogEntry] { scheduler.log }

    func raise(_ event: FeedbackEvent) {
        run(scheduler.raise(event, at: nowMs(), currentHold: currentHold()))
        if let entry = scheduler.log.last { onLog?(Self.describe(entry)) }
        keepTicking()
    }

    func stopHaptics() {
        run(scheduler.stopHaptics())
    }

    /// Plays a waiting GO or the next queued phrase when due. Runs on its own timer while anything waits.
    func tick() {
        run(scheduler.tick(at: nowMs(), currentHold: currentHold()))
        keepTicking()
    }

    private func keepTicking() {
        if scheduler.needsTicks, timer == nil {
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !scheduler.needsTicks {
            timer?.invalidate()
            timer = nil
        }
    }

    private func run(_ outputs: [CueOutput]) {
        for output in outputs {
            switch output {
            case .haptic(let haptic): haptics.play(haptic)
            case .stopHaptics: haptics.stop()
            case .sound(let sound): sounds.play(sound)
            case .speak(let phrases, let interrupt, let id):
                speech.speak(SpeechText.string(phrases), language: SpeechText.voiceLanguage(), interrupt: interrupt, id: id)
            }
        }
    }

    private static func describe(_ entry: CueLogEntry) -> String {
        let parts = [entry.haptic?.rawValue, entry.sound.map { "sound:\($0.rawValue)" }] + entry.speech.map(\.rawValue)
        return "cue \(entry.event): " + parts.compactMap { $0 }.joined(separator: " ") + (entry.dropped ? " (dropped)" : "")
    }
}
