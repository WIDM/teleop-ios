import AVFoundation
import TeleopCore

protocol SoundPlaying: AnyObject {
    func play(_ sound: Sound)
}

/// The app's audio session: playback, so the ring switch on silent does not mute the cues, mixed with other audio.
/// The app never records.
/// Activating it can block, so it happens off the main queue, once, when the players are made at launch.
enum CueAudioSession {
    private static var configured = false
    private static let queue = DispatchQueue(label: "CueAudioSession")

    static func activate() {
        guard !configured else { return }
        configured = true
        queue.async {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try? session.setActive(true)
        }
    }

    /// After an interruption (a call, Siri) the session is made active again; the sound engine restarts itself at
    /// the next sound.
    static func reactivate() {
        guard configured else { return }
        queue.async { try? AVAudioSession.sharedInstance().setActive(true) }
    }
}

/// The three sounds, synthesised once as short tones (interaction specification §5.2).
final class SoundPlayer: SoundPlaying {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private lazy var buffers: [Sound: AVAudioPCMBuffer] = Dictionary(
        uniqueKeysWithValues: Sound.allCases.map { ($0, render($0)) })

    init() {
        CueAudioSession.activate()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    func play(_ sound: Sound) {
        CueAudioSession.activate()
        if !engine.isRunning { try? engine.start() }
        guard engine.isRunning, let buffer = buffers[sound] else { return }
        node.scheduleBuffer(buffer, at: nil, options: .interrupts)
        node.play()
    }

    /// Notes as (frequency in hertz, milliseconds); a frequency of 0 is a gap.
    private static func notes(_ sound: Sound) -> [(Double, Int)] {
        let c5 = 523.25, g5 = 783.99
        switch sound {
        case .saved: return [(c5, 120), (g5, 120)]
        case .discarded: return [(g5, 120), (c5, 120)]
        case .linkLost: return [(330, 120), (0, 80), (330, 120), (0, 80), (330, 120)]
        }
    }

    private func render(_ sound: Sound) -> AVAudioPCMBuffer {
        let rate = format.sampleRate
        let notes = Self.notes(sound)
        let total = notes.reduce(0) { $0 + Int(rate * Double($1.1) / 1000) }
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total))!
        buffer.frameLength = AVAudioFrameCount(total)
        let samples = buffer.floatChannelData![0]
        var index = 0
        // A 5 ms ramp at each end of a note keeps it from clicking.
        let ramp = Int(rate * 0.005)
        for (frequency, milliseconds) in notes {
            let count = Int(rate * Double(milliseconds) / 1000)
            for i in 0..<count {
                let edge = min(1, Double(min(i, count - 1 - i)) / Double(ramp))
                samples[index + i] =
                    frequency == 0 ? 0 : Float(0.5 * edge * sin(2 * .pi * frequency * Double(i) / rate))
            }
            index += count
        }
        return buffer
    }
}

final class NoSounds: SoundPlaying {
    func play(_ sound: Sound) {}
}
