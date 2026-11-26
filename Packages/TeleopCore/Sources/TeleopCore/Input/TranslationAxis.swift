import Foundation

public enum TranslationAxis: String, CaseIterable, Equatable, Sendable {
    case height, foreAft, leftRight

    private var commands: (zh: [String], en: String) {
        switch self {
        case .height: return (["只調高度", "只調整高度", "只调高度", "只调整高度"], "height only")
        case .foreAft: return (["只調前後", "只調整前後", "只调前后", "只调整前后"], "forward back only")
        case .leftRight: return (["只調左右", "只調整左右", "只调左右", "只调整左右"], "left right only")
        }
    }

    public static func speechContext(for language: String) -> [String] {
        if language.hasPrefix("zh") { return allCases.flatMap { $0.commands.zh.prefix(2) } }
        return allCases.map { $0.commands.en }
    }

    public static func recognized(_ text: String) -> Self? {
        let (chinese, english) = voiceCommandForms(text)
        return allCases.first { axis in
            axis.commands.en == english || axis.commands.zh.contains(chinese)
        }
    }

    public func project(right: Double, forward: Double, up: Double) -> SIMD3<Double> {
        switch self {
        case .height: return OperatorFrame.linkOffset(right: 0, forward: 0, up: up)
        case .foreAft: return OperatorFrame.linkOffset(right: 0, forward: forward, up: 0)
        case .leftRight: return OperatorFrame.linkOffset(right: right, forward: 0, up: 0)
        }
    }
}

public enum VoiceAction: String, CaseIterable, Equatable, Sendable {
    case forward, up, open, close

    private var commands: (zh: [String], en: [String]) {
        switch self {
        case .forward:
            return (["往前一點", "向前一點", "往前一点", "向前一点"], ["forward a little", "move forward a little"])
        case .up:
            return (["往上一點", "向上一點", "往上一点", "向上一点"], ["up a little", "move up a little"])
        case .open:
            return (["開爪", "打開夾爪", "开爪", "打开夹爪"], ["open gripper", "open the gripper"])
        case .close:
            return (["關爪", "關閉夾爪", "关爪", "关闭夹爪"], ["close gripper", "close the gripper"])
        }
    }

    public static func speechContext(for language: String) -> [String] {
        if language.hasPrefix("zh") { return allCases.flatMap { $0.commands.zh.prefix(2) } }
        return allCases.flatMap { $0.commands.en }
    }

    public static func recognized(_ text: String) -> Self? {
        let (chinese, english) = voiceCommandForms(text)
        return allCases.first { $0.commands.zh.contains(chinese) || $0.commands.en.contains(english) }
    }
}

private func voiceCommandForms(_ text: String) -> (chinese: String, english: String) {
    let words = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".。!?！？")))
        .lowercased()
        .split(whereSeparator: \.isWhitespace)
    return (words.joined(), words.joined(separator: " "))
}

public struct VoiceAxisSession: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case off
        case ready(TranslationAxis?)
        case listening(epoch: Int, axis: TranslationAxis?)
    }
    public private(set) var phase: Phase = .off
    private var generation = 0
    public init() {}
    public var axis: TranslationAxis? {
        switch phase {
        case .off: return nil
        case .ready(let axis), .listening(_, let axis): return axis
        }
    }
    public var enabled: Bool { phase != .off }
    public var listeningEpoch: Int? {
        if case .listening(let epoch, _) = phase { return epoch }
        return nil
    }
    public mutating func enable() { phase = .ready(nil) }
    public mutating func beginListening() -> Int? {
        guard case .ready(let axis) = phase else { return nil }
        generation += 1
        phase = .listening(epoch: generation, axis: axis)
        return generation
    }
    public mutating func suspend() {
        guard enabled else { return }
        phase = .ready(axis)
    }
    public mutating func disable() { phase = .off }
    public mutating func accept(
        _ text: String, final: Bool, epoch: Int, capturedAt: TimeInterval, now: TimeInterval, inputIdle: Bool
    ) -> TranslationAxis? {
        guard canAccept(final: final, epoch: epoch, capturedAt: capturedAt, now: now, inputIdle: inputIdle),
            let chosen = TranslationAxis.recognized(text)
        else { return nil }
        phase = .ready(chosen)
        return chosen
    }

    private func canAccept(
        final: Bool, epoch: Int, capturedAt: TimeInterval, now: TimeInterval, inputIdle: Bool
    ) -> Bool {
        final && inputIdle && listeningEpoch == epoch && capturedAt.isFinite && now.isFinite
            && now >= capturedAt && now - capturedAt <= 3
    }
}

public struct VoiceAxisEndpoint: Equatable, Sendable {
    public struct Deadlines: Equatable, Sendable {
        public let endAudioAt: TimeInterval
        public let finishAt: TimeInterval
    }
    public let startedAt: TimeInterval
    private var lastText: String?
    private var lastCapturedAt: TimeInterval?
    private var scheduled: Deadlines?
    public init(startedAt: TimeInterval) { self.startedAt = startedAt }
    public var hardDeadlines: Deadlines {
        Deadlines(endAudioAt: startedAt + 6, finishAt: startedAt + 9)
    }
    public mutating func deadlines(for text: String, capturedAt: TimeInterval, now: TimeInterval) -> Deadlines {
        if lastText == text, lastCapturedAt == capturedAt, let scheduled { return scheduled }
        lastText = text
        lastCapturedAt = capturedAt
        guard TranslationAxis.recognized(text) != nil || VoiceAction.recognized(text) != nil,
            startedAt.isFinite, capturedAt.isFinite, now.isFinite,
            capturedAt >= startedAt, now >= capturedAt
        else {
            scheduled = hardDeadlines
            return hardDeadlines
        }
        let finish = min(hardDeadlines.finishAt, capturedAt + 3)
        let deadlines = Deadlines(endAudioAt: min(hardDeadlines.endAudioAt, now + 0.5, finish), finishAt: finish)
        scheduled = deadlines
        return deadlines
    }
}
