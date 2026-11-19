import AVFoundation
import TeleopCore

protocol SpeechPlaying: AnyObject {
    /// Called with an utterance's id when it has been spoken through or cut off.
    var onFinished: ((Int) -> Void)? { get set }
    var onStarted: ((Int) -> Void)? { get set }
    /// - Parameters:
    ///   - language: a BCP 47 voice language, such as "en-US" or "zh-TW".
    ///   - interrupt: stop what is being spoken first.
    func speak(_ text: String, language: String, interrupt: Bool, id: Int)
    func stop(id: Int)
}

/// Speaks the app's phrases in the app's language, through the app's audio session.
final class SpeechPlayer: NSObject, SpeechPlaying, AVSpeechSynthesizerDelegate {
    var onFinished: ((Int) -> Void)?
    var onStarted: ((Int) -> Void)?
    var onEnded: ((Int, Bool) -> Void)?
    private let synthesizer = AVSpeechSynthesizer()
    private var ids: [ObjectIdentifier: Int] = [:]
    private var activeID: Int?
    private var submittedID: Int?
    private var invalidated: Set<Int> = []
    private var interruptions: NSObjectProtocol?

    override init() {
        super.init()
        CueAudioSession.activate()
        synthesizer.delegate = self
        // A call or Siri interrupts the audio session. What was being said is cut off, which reports it finished,
        // so a paused utterance cannot hold every later phrase behind it.
        interruptions = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(
                AVAudioSession.InterruptionType.init)
            if type == .began { self?.synthesizer.stopSpeaking(at: .immediate) }
            if type == .ended { CueAudioSession.reactivate() }
        }
    }

    deinit {
        if let interruptions { NotificationCenter.default.removeObserver(interruptions) }
    }

    func speak(_ text: String, language: String, interrupt: Bool, id: Int) {
        CueAudioSession.activate()
        if interrupt || synthesizer.isPaused, synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language)
        ids[ObjectIdentifier(utterance)] = id
        submittedID = id
        synthesizer.speak(utterance)
    }

    func stop(id: Int) {
        guard ids.values.contains(id) else { return }
        invalidated.insert(id)
        if activeID == id || (activeID == nil && submittedID == id) {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        activeID = ids[key]
        DispatchQueue.main.async { [weak self] in
            guard let self, let id = ids[key] else { return }
            if invalidated.contains(id) {
                stop(id: id)
                return
            }
            onStarted?(id)
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finished(utterance, cut: false)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finished(utterance, cut: true)
    }

    private func finished(_ utterance: AVSpeechUtterance, cut: Bool) {
        let key = ObjectIdentifier(utterance)
        DispatchQueue.main.async { [weak self] in
            guard let self, let id = ids.removeValue(forKey: key) else { return }
            if activeID == id { activeID = nil }
            if submittedID == id { submittedID = nil }
            invalidated.remove(id)
            onEnded?(id, cut)
            onFinished?(id)
        }
    }
}

/// Unit tests: nothing is heard, and every utterance ends at once.
final class NoSpeech: SpeechPlaying {
    var onStarted: ((Int) -> Void)?
    var onFinished: ((Int) -> Void)?
    private(set) var spoken: [String] = []

    func stop(id: Int) {}

    func speak(_ text: String, language: String, interrupt: Bool, id: Int) {
        onStarted?(id)
        spoken.append(text)
        onFinished?(id)
    }
}

/// The words for a phrase, from the `Speech` table in the app's language.
enum SpeechText {
    static func string(_ phrases: [Phrase], language: AppLanguage = L10n.language) -> String {
        let bundle = bundle(for: language)
        // Chinese sentences follow each other with no space between them.
        let separator = voiceLanguage(language).hasPrefix("zh") ? "" : " "
        return phrases.map { phrase in
            let format = bundle.localizedString(
                forKey: phrase.key.rawValue, value: phrase.key.rawValue, table: "Speech")
            return phrase.number.map { String(format: format, $0) } ?? format
        }.joined(separator: separator)
    }

    /// The voice for the app's language.
    static func voiceLanguage(_ language: AppLanguage = L10n.language) -> String {
        let code = language == .system ? (Bundle.main.preferredLocalizations.first ?? "en") : language.rawValue
        return code.hasPrefix("zh") ? "zh-TW" : "en-US"
    }

    private static func bundle(for language: AppLanguage) -> Bundle {
        guard language != .system,
            let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
            let bundle = Bundle(path: path)
        else { return .main }
        return bundle
    }
}
