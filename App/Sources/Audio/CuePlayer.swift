import Foundation
import TeleopCore

/// Plays feedback events on the device: the scheduler decides, the haptic, sound and speech players play.
/// Main queue only.
final class CuePlayer {
    /// The operator's hold engaged now, for "GO only for its own hold".
    var currentHold: () -> Int? = { nil }
    var isReady: () -> Bool = { false }
    var onLog: ((String) -> Void)?
    var onSpeechLog: ((String) -> Void)?
    var onAudioWillPlay: (() -> Void)?
    var onAudioSettled: (() -> Void)?
    var onSpeechEvent: ((String, Int, UInt64) -> Void)?
    var onDecision: ((FeedbackEvent, UInt64) -> Void)?
    private var activeSpeechIDs: Set<Int> = []
    private var voiceAxisSpeechIDs: Set<Int> = []
    private var soundUntil: TimeInterval = 0
    var hasAudio: Bool { !activeSpeechIDs.isEmpty || ProcessInfo.processInfo.systemUptime < soundUntil }

    func cancelVoiceAxisConfirmation() {
        for id in voiceAxisSpeechIDs {
            activeSpeechIDs.remove(id)
            awaitingSpeechStart[id] = nil
            speech.stop(id: id)
            run(scheduler.speechFinished(id: id, at: nowMs()))
            onSpeechEvent?("cancel", id, DispatchTime.now().uptimeNanoseconds)
        }
        voiceAxisSpeechIDs.removeAll()
    }
    private var awaitingSpeechStart: [Int: [Phrase]] = [:]

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
            activeSpeechIDs.remove(id)
            voiceAxisSpeechIDs.remove(id)
            onSpeechEvent?("end", id, DispatchTime.now().uptimeNanoseconds)
            onAudioSettled?()
            if !(self.speech is SpeechPlayer) { onSpeechLog?("speech end id=\(id) finished") }
            refreshReadiness()
            run(scheduler.speechFinished(id: id, at: self.nowMs()))
        }
        speech.onStarted = { [weak self] id in _ = self?.speechStarted(id) }
        if let player = speech as? SpeechPlayer {
            player.onEnded = { [weak self] id, cut in
                self?.awaitingSpeechStart[id] = nil
                self?.onSpeechLog?("speech end id=\(id) \(cut ? "cut" : "finished")")
            }
        }
    }

    /// Every cue decided so far, newest last.
    var log: [CueLogEntry] { scheduler.log }

    func raise(_ event: FeedbackEvent) {
        onDecision?(event, DispatchTime.now().uptimeNanoseconds)
        refreshReadiness()
        run(scheduler.raise(event, at: nowMs(), currentHold: currentHold()))
        if let entry = scheduler.log.last { onLog?(Self.describe(entry)) }
        keepTicking()
    }

    func stopHaptics() {
        run(scheduler.stopHaptics())
    }

    /// Plays a waiting GO or the next queued phrase when due. Runs on its own timer while anything waits.
    func tick() {
        refreshReadiness()
        run(scheduler.tick(at: nowMs(), currentHold: currentHold()))
        keepTicking()
    }

    func refreshReadiness() {
        run(scheduler.updateReadiness(isReady(), at: nowMs()))
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
            case .stopSpeech(let id):
                activeSpeechIDs.remove(id)
                voiceAxisSpeechIDs.remove(id)
                onSpeechEvent?("cancel", id, DispatchTime.now().uptimeNanoseconds)
                awaitingSpeechStart[id] = nil
                onSpeechLog?("speech invalidated id=\(id) reason=invalidated_or_timed_out")
                speech.stop(id: id)
            case .sound(let sound):
                onAudioWillPlay?()
                soundUntil = ProcessInfo.processInfo.systemUptime + 1
                sounds.play(sound)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.onAudioSettled?() }
            case .speak(let phrases, let interrupt, let id):
                onAudioWillPlay?()
                activeSpeechIDs.insert(id)
                if phrases.contains(where: { [.voiceHeight, .voiceForeAft, .voiceLeftRight].contains($0.key) }) {
                    voiceAxisSpeechIDs.insert(id)
                }
                onSpeechEvent?("submit", id, DispatchTime.now().uptimeNanoseconds)
                awaitingSpeechStart[id] = phrases
                speech.speak(
                    SpeechText.string(phrases), language: SpeechText.voiceLanguage(), interrupt: interrupt, id: id)
            }
        }
    }

    private func speechStarted(_ id: Int) -> Bool {
        onSpeechEvent?("start", id, DispatchTime.now().uptimeNanoseconds)
        refreshReadiness()
        run(scheduler.speechWillStart(id: id, at: nowMs()))
        guard let phrases = awaitingSpeechStart.removeValue(forKey: id) else { return false }
        onSpeechLog?("speech start id=\(id) keys=\(phrases.map { $0.key.rawValue }.joined(separator: ","))")
        return true
    }

    private static func describe(_ entry: CueLogEntry) -> String {
        let parts = [entry.haptic?.rawValue, entry.sound.map { "sound:\($0.rawValue)" }] + entry.speech.map(\.rawValue)
        return "cue \(entry.event): " + parts.compactMap { $0 }.joined(separator: " ")
            + (entry.dropped ? " (dropped)" : "")
    }
}
