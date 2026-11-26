import AVFoundation
import Foundation
import Speech
import TeleopCore

/// Errors are operator-visible; no remote speech fallback is used.
enum AxisSpeechFailure: String, Error {
    case permission, unavailable, audio, interrupted, unsupportedTool
}

enum AxisSpeechEvent {
    case listening
    case transcript(String, final: Bool, capturedAt: TimeInterval)
    case ended
    case failed(AxisSpeechFailure)
}

protocol AxisSpeechRecognizing: AnyObject {
    var onEvent: ((Int, AxisSpeechEvent) -> Void)? { get set }
    func start(epoch: Int, language: String)
    func stop()
}

final class AxisSpeechRecognizer: AxisSpeechRecognizing {
    var onEvent: ((Int, AxisSpeechEvent) -> Void)?
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var epoch: Int?
    private var tapInstalled = false
    private var endpoint: VoiceAxisEndpoint?
    private var ending: DispatchWorkItem?
    private var timeout: DispatchWorkItem?
    private var interruption: NSObjectProtocol?

    init() {
        interruption = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let epoch = self.epoch,
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                AVAudioSession.InterruptionType(rawValue: raw) == .began
            else { return }
            self.finish(epoch, event: .failed(.interrupted))
        }
    }

    deinit {
        ending?.cancel()
        timeout?.cancel()
        if let interruption { NotificationCenter.default.removeObserver(interruption) }
        task?.cancel()
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
    }

    func start(epoch: Int, language: String) {
        stop()
        self.epoch = epoch
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)),
            recognizer.isAvailable, recognizer.supportsOnDeviceRecognition
        else {
            finish(epoch, event: .failed(.unavailable))
            return
        }
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self, self.epoch == epoch else { return }
                guard status == .authorized else { self.finish(epoch, event: .failed(.permission)); return }
                AVAudioSession.sharedInstance().requestRecordPermission { [weak self] allowed in
                    DispatchQueue.main.async {
                        guard let self, self.epoch == epoch else { return }
                        guard allowed else { self.finish(epoch, event: .failed(.permission)); return }
                        CueAudioSession.prepareRecording { [weak self] ready in
                            guard let self, self.epoch == epoch else { return }
                            guard ready else { self.finish(epoch, event: .failed(.audio)); return }
                            self.capture(epoch: epoch, recognizer: recognizer)
                        }
                    }
                }
            }
        }
    }

    static func makeRequest(language: String) -> SFSpeechAudioBufferRecognitionRequest {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .confirmation
        request.contextualStrings =
            TranslationAxis.speechContext(for: language) + VoiceAction.speechContext(for: language)
        return request
    }

    static func completion(for error: Error) -> AxisSpeechEvent {
        let error = error as NSError
        // See the error codes documented on SFSpeechRecognitionTask.error.
        switch (error.domain, error.code) {
        case ("kAFAssistantErrorDomain", 1110): return .ended
        case ("kAFAssistantErrorDomain", 1700): return .failed(.permission)
        default: return .failed(.unavailable)
        }
    }

    private func capture(epoch: Int, recognizer: SFSpeechRecognizer) {
        let request = Self.makeRequest(language: recognizer.locale.identifier)
        self.request = request
        let started = ProcessInfo.processInfo.systemUptime
        endpoint = VoiceAxisEndpoint(startedAt: started)
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.epoch == epoch else { return }
                if let result {
                    let last = result.bestTranscription.segments.last
                    let captured = started + (last.map { $0.timestamp + $0.duration } ?? 0)
                    self.onEvent?(
                        epoch,
                        .transcript(
                            result.bestTranscription.formattedString,
                            final: result.isFinal, capturedAt: captured))
                    guard self.epoch == epoch else { return }
                    if result.isFinal {
                        self.finish(epoch, event: .ended)
                        return
                    }
                    if let deadlines = self.endpoint?.deadlines(
                        for: result.bestTranscription.formattedString, capturedAt: captured,
                        now: ProcessInfo.processInfo.systemUptime)
                    {
                        self.schedule(deadlines, epoch: epoch)
                    }
                }
                if let error { self.finish(epoch, event: Self.completion(for: error)) }
            }
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { finish(epoch, event: .failed(.audio)); return }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
        tapInstalled = true
        engine.prepare()
        do { try engine.start() } catch { finish(epoch, event: .failed(.audio)); return }
        onEvent?(epoch, .listening)
        schedule(VoiceAxisEndpoint(startedAt: started).hardDeadlines, epoch: epoch)
    }

    private func schedule(_ deadlines: VoiceAxisEndpoint.Deadlines, epoch: Int) {
        ending?.cancel()
        timeout?.cancel()
        let now = ProcessInfo.processInfo.systemUptime
        if tapInstalled {
            let ending = DispatchWorkItem { [weak self] in
                guard let self, self.epoch == epoch else { return }
                self.endCapture()
                self.request?.endAudio()
            }
            self.ending = ending
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadlines.endAudioAt - now), execute: ending)
        }
        let timeout = DispatchWorkItem { [weak self] in
            self?.finish(epoch, event: .ended)
        }
        self.timeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadlines.finishAt - now), execute: timeout)
    }

    private func finish(_ epoch: Int, event: AxisSpeechEvent) {
        guard self.epoch == epoch else { return }
        stop()
        onEvent?(epoch, event)
    }

    private func endCapture() {
        engine.stop()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
    }

    func stop() {
        epoch = nil
        endpoint = nil
        ending?.cancel()
        timeout?.cancel()
        ending = nil
        timeout = nil
        endCapture()
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
    }
}
