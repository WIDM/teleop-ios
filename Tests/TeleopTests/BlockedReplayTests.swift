import TeleopCore
import XCTest
@testable import Teleop

final class BlockedReplayTests: XCTestCase {
    private struct Segment: Decodable {
        let start: Int
        let states: [Sample]
    }

    private struct Sample: Decodable {
        let time: Int
        let activity: String?
        let arm: SIMD3<Double>?
        let tool: SIMD3<Double>?
        let request: SIMD3<Double>?

        init(from decoder: Decoder) throws {
            var row = try decoder.unkeyedContainer()
            time = try row.decode(Int.self)
            activity = try row.decodeIfPresent(String.self)
            arm = try row.decodeIfPresent(SIMD3<Double>.self)
            tool = try row.decodeIfPresent(SIMD3<Double>.self)
            request = try row.decodeIfPresent(SIMD3<Double>.self)
        }
    }

    // From the Nov 10–14 server recording. Targets are reconstructed from the segment start and
    // the last pose_update at each state timestamp, using the same clock as the offline replay.
    private func recordedHolds() throws -> [String: [Segment]] {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "BlockedReplay", withExtension: "json"))
        return try JSONDecoder().decode([String: [Segment]].self, from: Data(contentsOf: fixture))
    }

    func testRecordedHoldsThroughTheLinkAndDefaultGuideCues() throws {
        let holds = try recordedHolds()
        let oldLanguage = L10n.language
        L10n.language = .zhHant
        defer { L10n.language = oldLanguage }

        let expected: [(String, [CueKey], [Felt], [String])] = [
            ("4684", [.limit(.workspace), .commandOutside(.up)], [.play(.end)], ["太高了。"]),
            ("6953", [.limit(.workspace), .commandOutside(.back)], [.play(.end), .play(.end)], ["太後面了。"]),
            ("6966", [.commandOutside(.forward)], [.play(.end)], ["太前面了。"]),
            ("6977", [.commandOutside(.up), .limit(.blocked)], [.play(.end), .play(.end)], ["太高了。", "擋住了。"]),
            ("6928", [], [], []),
            ("6938", [.commandOutside(.forward)], [.play(.end)], ["太前面了。"]),
        ]
        for (id, cues, haptics, words) in expected {
            let felt = SpyHaptics()
            let speech = SpySpeech()
            var now = 0
            let model = AppModel(
                start: .p4, haptics: felt, sounds: SpySounds(), speech: speech,
                liveLink: false, nowMs: { now }, assistOn: true, lockChoice: .off
            )
            for (index, segment) in try XCTUnwrap(holds[id]).enumerated() {
                now = segment.start
                model.link.feedbackStartSent(.pose, restart: index > 0, at: now)
                for sample in segment.states {
                    now = sample.time
                    if let request = sample.request { model.link.poseCommandSent(SIMD3<Float>(request), at: now) }
                    let state = ServerState(
                        activity: sample.activity.map(ServerActivity.init), endEffector: sample.arm,
                        toolPoint: sample.tool
                    )
                    model.link.stateArrived(state, serverMs: now, onControl: false)
                }
            }
            let cueKeys = model.cueLog.map(\.event)
            print("Blocked link replay \(id): \(cueKeys), \(felt.felt), \(speech.spoken)")
            XCTAssertEqual(cueKeys, cues, id)
            XCTAssertEqual(felt.felt, haptics, id)
            XCTAssertEqual(speech.spoken, words, id)
        }
    }

    func testEarlierWorkspaceCueDoesNotSilenceANewObstruction() {
        for restart in [false, true] {
            var monitor = FeedbackMonitor(limits: TestProfiles.so101.gripperLimits, frames: TestProfiles.so101.frames)
            monitor.blockedWorkspace = TestProfiles.so101.gripperWorkspace
            monitor.reportsLowest = true
            let face = SIMD3(0.02, TestProfiles.so101.gripperWorkspace.low.y, 0.15)
            monitor.startSent(.pose, restart: false, at: 0)
            monitor.commanded(face + SIMD3(0.02, -0.02, 0))
            var cues = monitor.observe(ServerState(activity: .poseTracking, endEffector: face), at: 0)
            for time in stride(from: 200, through: 1200, by: 200) {
                cues += monitor.observe(ServerState(activity: .poseClamped, endEffector: face), at: time)
            }
            if restart {
                monitor.startSent(.pose, restart: true, at: 1400)
            } else {
                monitor.commanded(face)
                cues += monitor.observe(ServerState(activity: .poseTracking, endEffector: face), at: 1400)
            }
            monitor.commanded(face + SIMD3(-0.02, 0, 0))
            for time in stride(from: 1600, through: 2800, by: 200) {
                cues += monitor.observe(ServerState(activity: .poseTracking, endEffector: face), at: time)
            }
            XCTAssertEqual(cues, [.limit(.workspace), .limit(.blocked)], "restart = \(restart)")
        }
    }

    func testBlockedDuringDescentDoesNotRepeatAsLowestAtTheSameHeight() {
        var monitor = FeedbackMonitor(limits: TestProfiles.so101.gripperLimits, frames: TestProfiles.so101.frames)
        monitor.blockedWorkspace = TestProfiles.so101.gripperWorkspace
        monitor.reportsLowest = true
        let arm = SIMD3(0.02, -0.14, 0.15)
        monitor.startSent(.pose, restart: false, at: 0)
        var cues: [FeedbackEvent] = []
        for time in stride(from: 0, through: 2200, by: 200) {
            monitor.commanded(arm + SIMD3(0.02, 0, time < 1000 ? -0.004 : -0.012))
            cues += monitor.observe(ServerState(activity: .poseTracking, endEffector: arm), at: time)
        }
        XCTAssertEqual(cues, [.limit(.blocked)])
        XCTAssertEqual(monitor.lowestSeen, arm.z, "The measured height is still kept")
    }

    func testBlockedAtAHigherPointLeavesALaterLowerApproachArmed() {
        var monitor = FeedbackMonitor(limits: TestProfiles.so101.gripperLimits, frames: TestProfiles.so101.frames)
        monitor.blockedWorkspace = TestProfiles.so101.gripperWorkspace
        monitor.reportsLowest = true
        let high = SIMD3(0.02, -0.14, 0.17)
        let low = SIMD3(0.02, -0.14, 0.13)
        monitor.startSent(.pose, restart: false, at: 0)
        monitor.commanded(high + SIMD3(0.02, 0, -0.006))
        var cues: [FeedbackEvent] = []
        for time in stride(from: 0, through: 1000, by: 200) {
            cues += monitor.observe(ServerState(activity: .poseTracking, endEffector: high), at: time)
        }
        monitor.commanded(low)
        cues += monitor.observe(ServerState(activity: .poseTracking, endEffector: low), at: 1200)
        monitor.commanded(low - SIMD3(0, 0, 0.02))
        for time in stride(from: 1400, through: 2400, by: 200) {
            cues += monitor.observe(ServerState(activity: .poseTracking, endEffector: low), at: time)
        }
        XCTAssertEqual(cues, [.limit(.blocked), .limit(.lowest)])
    }

    func testNewDownwardDirectionAtTheSameHeightCanSayLowest() {
        var monitor = FeedbackMonitor(limits: TestProfiles.so101.gripperLimits, frames: TestProfiles.so101.frames)
        monitor.blockedWorkspace = TestProfiles.so101.gripperWorkspace
        monitor.reportsLowest = true
        let arm = SIMD3(0.02, -0.14, 0.15)
        monitor.startSent(.pose, restart: false, at: 0)
        var cues: [FeedbackEvent] = []
        for time in stride(from: 0, through: 2400, by: 200) {
            let offset = time <= 1000 ? SIMD3(0.02, 0, -0.006) : SIMD3(0, 0, -0.02)
            monitor.commanded(arm + offset)
            cues += monitor.observe(ServerState(activity: .poseTracking, endEffector: arm), at: time)
        }
        XCTAssertEqual(cues, [.limit(.blocked), .limit(.lowest)])
    }

    func testRecordedObstructionsStillSayBlockedIncludingAfterAnEarlierClamp() throws {
        let holds = try recordedHolds()
        for id in ["6950", "6954", "7187"] {
            var monitor = FeedbackMonitor(limits: TestProfiles.so101.gripperLimits, frames: TestProfiles.so101.frames)
            monitor.blockedWorkspace = TestProfiles.so101.gripperWorkspace
            monitor.reportsLowest = true
            var cues: [FeedbackEvent] = []
            for (index, segment) in try XCTUnwrap(holds[id]).enumerated() {
                monitor.startSent(.pose, restart: index > 0, at: segment.start)
                for sample in segment.states {
                    if let request = sample.request { monitor.commanded(request) }
                    let state = ServerState(
                        activity: sample.activity.map(ServerActivity.init), endEffector: sample.arm,
                        toolPoint: sample.tool
                    )
                    cues += monitor.observe(state, at: sample.time)
                }
            }
            XCTAssertEqual(cues.filter { $0 == .limit(.blocked) }, [.limit(.blocked)], id)
        }
    }

    func testRecordedHoldsReachTheAppHapticAndSpeechPlayers() throws {
        let holds = try recordedHolds()
        let oldLanguage = L10n.language
        L10n.language = .zhHant
        defer { L10n.language = oldLanguage }

        let expected: [(String, [CueKey], [Felt], [String])] = [
            ("4684", [.limit(.workspace)], [.play(.end)], []),
            ("6953", [.limit(.workspace)], [.play(.end)], []),
            ("6966", [.limit(.workspace)], [.play(.end)], []),
            ("6977", [.limit(.blocked)], [.play(.end)], ["擋住了。"]),
            ("6928", [], [], []),
            ("6938", [], [], []),
        ]
        for (id, cues, haptics, words) in expected {
            let felt = SpyHaptics()
            let speech = SpySpeech()
            var now = 0
            let player = CuePlayer(haptics: felt, sounds: SpySounds(), speech: speech, nowMs: { now })
            var monitor = FeedbackMonitor(limits: TestProfiles.so101.gripperLimits, frames: TestProfiles.so101.frames)
            monitor.reportsLowest = true
            monitor.blockedWorkspace = TestProfiles.so101.gripperWorkspace

            for (index, segment) in try XCTUnwrap(holds[id]).enumerated() {
                monitor.startSent(.pose, restart: index > 0, at: segment.start)
                for sample in segment.states {
                    now = sample.time
                    if let request = sample.request { monitor.commanded(request) }
                    let state = ServerState(
                        activity: sample.activity.map(ServerActivity.init), endEffector: sample.arm,
                        toolPoint: sample.tool
                    )
                    for event in monitor.observe(state, at: now) { player.raise(event) }
                    player.tick()
                }
            }
            print("Blocked replay \(id): \(player.log.map(\.event)), \(felt.felt), \(speech.spoken)")
            XCTAssertEqual(player.log.map(\.event), cues, id)
            XCTAssertEqual(felt.felt, haptics, id)
            XCTAssertEqual(speech.spoken, words, id)
        }
    }
}
