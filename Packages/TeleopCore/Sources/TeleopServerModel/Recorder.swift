import Foundation

/// The server's demonstration recorder, as a state machine with no files.
///
/// A reset arms it. The first physics step with a command running starts the take, which then gains one sample
/// every `stepsPerSample` steps, pauses included. A success saves the take, an E-stop or a reset throws it away,
/// and after an E-stop it stays off until the next reset.
struct Recorder: Equatable, Sendable {
    let stepsPerSample: Int
    private(set) var active = false
    private(set) var capturing = false
    /// Samples in the current take. Kept after a save until the next reset arms the recorder again.
    private(set) var samples = 0
    private var phase = 0
    private(set) var saved: Int
    private(set) var discarded = 0

    init(_ config: ServerModelConfig.Recorder) {
        stepsPerSample = config.stepsPerSample
        saved = config.savedAtStart
    }

    /// "off", "armed" or "capturing", as `state.rec` says it.
    var label: String { !active ? "off" : capturing ? "capturing" : "armed" }

    mutating func arm() {
        if active { forget() }
        active = true
        samples = 0
        phase = 0
        capturing = false
    }

    mutating func beforeStep(commandRunning: Bool) {
        guard active else { return }
        if !capturing {
            guard commandRunning else { return }
            capturing = true
            phase = 0
        }
        if phase % stepsPerSample == 0 { samples += 1 }
        phase += 1
    }

    /// Throws the take away; a take that had begun counts as discarded.
    mutating func discard() {
        guard active else { return }
        if capturing { discarded += 1 }
        forget()
    }

    /// Saves the take. A take with fewer than two samples is thrown away instead.
    mutating func success() {
        guard active else { return }
        guard samples >= 2 else {
            discard()
            return
        }
        active = false
        saved += 1
    }

    private mutating func forget() {
        active = false
        capturing = false
        samples = 0
        phase = 0
    }
}
