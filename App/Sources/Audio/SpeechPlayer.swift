import AVFoundation
import TeleopCore

protocol SpeechPlaying: AnyObject {
    /// Called with an utterance's id when it has been spoken through or cut off.
    var onFinished: ((Int) -> Void)? { get set }
    /// - Parameters:
    ///   - language: a BCP 47 voice language, such as "en-US" or "zh-TW".
    ///   - interrupt: stop what is being spoken first.
    func speak(_ text: String, language: String, interrupt: Bool, id: Int)
}

/// Speaks the app's phrases in the app's language, through the app's audio session.
final class SpeechPlayer: NSObject, SpeechPlaying, AVSpeechSynthesizerDelegate {
    var onFinished: ((Int) -> Void)?
    private let synthesizer = AVSpeechSynthesizer()
    private var ids: [ObjectIdentifier: Int] = [:]
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
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
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
        synthesizer.speak(utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finished(utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finished(utterance)
    }

    private func finished(_ utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        DispatchQueue.main.async { [weak self] in
            guard let self, let id = ids.removeValue(forKey: key) else { return }
            onFinished?(id)
        }
    }
}

/// Unit tests: nothing is heard, and every utterance ends at once.
final class NoSpeech: SpeechPlaying {
    var onFinished: ((Int) -> Void)?
    private(set) var spoken: [String] = []

    func speak(_ text: String, language: String, interrupt: Bool, id: Int) {
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
            let format = bundle.localizedString(forKey: phrase.key.rawValue, value: phrase.key.rawValue, table: "Speech")
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
              let bundle = Bundle(path: path) else { return .main }
        return bundle
    }
}
