import simd
import XCTest
@testable import TeleopCore

/// The input rules across a change of the attitude's frame. Each time the phone's tracking starts again, and each time
/// the camera stops, the samples that follow are in a new world frame whose heading is wherever the phone pointed then.
/// Measured against an anchor from before, the phone would read as turned when it never moved, so the rules forget the
/// attitude they hold and anchor again at the first sample of the new frame.
final class AttitudeFrameTests: XCTestCase {
    typealias Rig = ArbiterRig

    /// The phone held upright, then tipped 60° toward lying flat with its screen up, in a world frame whose y axis is
    /// up, as tracking's is.
    private static let tippedTowardFlat = simd_quatd(angle: Phone.rad(-60), axis: Phone.x)
    /// The same phone held the same way, in a frame whose heading is 18° round: tipped toward flat, much of a turn
    /// about the vertical reads as a turn about the screen's normal.
    private static let sameInANewFrame = simd_normalize(
        simd_quatd(angle: Phone.rad(18), axis: Phone.y) * tippedTowardFlat)

    /// One call of the rules: how long after the previous one, its events, and the attitude frame its facts carry.
    private struct Call {
        var after: TimeInterval
        var events: [InputEvent]
        var frame: Int
    }

    private static func touch(_ id: Int, _ phase: TouchSample.Phase, _ p: SIMD2<Double> = Rig.middle) -> InputEvent {
        .touch(TouchSample(id: id, phase: phase, x: p.x, y: p.y, majorRadius: 8))
    }

    /// The order seen after a return from Settings: a sample in the old frame, the tracking starts again, a thumb comes
    /// down, the first sample of the new frame arrives inside the thumb's palm window, and the window ends.
    private static let acrossARun = [
        Call(after: 0, events: [.attitude(Phone.rest)], frame: 0),
        Call(after: 0.5, events: [.attitude(tippedTowardFlat)], frame: 0),
        Call(after: 0.5, events: [.tick], frame: 1),
        Call(after: 0.4, events: [touch(1, .began)], frame: 1),
        Call(after: 0.05, events: [.attitude(sameInANewFrame)], frame: 1),
        Call(after: 0.2, events: [.tick], frame: 1),
    ]

    /// The same, with the thumb already down when the tracking starts again: it was anchored on the last sample of the
    /// old frame, and the first sample of the new frame arrives inside its palm window.
    private static let whileAThumbWaits = [
        Call(after: 0, events: [.attitude(Phone.rest)], frame: 0),
        Call(after: 0.5, events: [.attitude(tippedTowardFlat)], frame: 0),
        Call(after: 0.4, events: [touch(1, .began)], frame: 0),
        Call(after: 0.02, events: [], frame: 1),
        Call(after: 0.03, events: [.attitude(sameInANewFrame)], frame: 1),
        Call(after: 0.2, events: [.tick], frame: 1),
    ]

    func testATurnThatNeverHappenedIsNotReadAcrossATrackerRun() {
        let reading = WristAngles(from: Self.tippedTowardFlat, to: Self.sameInANewFrame)
        XCTAssertGreaterThan(abs(reading.turn), 10, "compared across the two frames, the phone reads as turned")
        for assist in [Assist.off, Rig.goTo(lock: LockRule(variant: .holdThenSlide, timeLimitS: 30))] {
            var arbiter = InputArbiter(scheme: .screenTurns, layout: Rig.layout, assist: assist)
            var time = 10.0
            var commands: [InputCommand] = []
            for call in Self.acrossARun {
                time += call.after
                commands += arbiter.handle(call.events, at: time, facts: InputFacts(attitudeFrame: call.frame))
            }
            XCTAssertEqual(
                commands, [],
                "\(assist): the first sample after the tracking started again was read as a turn from an anchor kept "
                    + "from before it, and the wrist started at an angle the phone never turned")
            XCTAssertEqual(arbiter.held[.touch(1)], .waiting, "\(assist)")
        }
        // Version 1.0.1's rules, given the same events, keep the old attitude as the thumb's anchor.
        var old = InputArbiter101(scheme: .screenTurns, layout: Rig.layout)
        var time = 10.0
        var commands: [InputCommand] = []
        for call in Self.acrossARun {
            time += call.after
            commands += old.handle(call.events, at: time, facts: InputFacts(attitudeFrame: call.frame))
        }
        XCTAssertTrue(commands.contains(.startWrist), "1.0.1 starts the wrist: \(commands)")
        XCTAssertGreaterThan(abs(commands.wristTargets.first?.degrees ?? 0), 10, "at a false angle: \(commands)")
    }

    func testAThumbWaitingWhenTheFrameChangesIsAnchoredAgain() {
        for assist in [Assist.off, Rig.goTo(lock: LockRule(variant: .holdThenSlide, timeLimitS: 30))] {
            var arbiter = InputArbiter(scheme: .screenTurns, layout: Rig.layout, assist: assist)
            var time = 10.0
            var commands: [InputCommand] = []
            for call in Self.whileAThumbWaits {
                time += call.after
                commands += arbiter.handle(call.events, at: time, facts: InputFacts(attitudeFrame: call.frame))
            }
            XCTAssertEqual(
                commands, [],
                "\(assist): a thumb already down kept its anchor from before the tracking started again, and the "
                    + "first sample after it was read as a turn the phone never made")
            XCTAssertEqual(arbiter.held[.touch(1)], .waiting, "\(assist)")
        }
        // Version 1.0.1's rules, given the same events, measure that sample from the thumb's old anchor.
        var old = InputArbiter101(scheme: .screenTurns, layout: Rig.layout)
        var time = 10.0
        var commands: [InputCommand] = []
        for call in Self.whileAThumbWaits {
            time += call.after
            commands += old.handle(call.events, at: time, facts: InputFacts(attitudeFrame: call.frame))
        }
        XCTAssertTrue(commands.contains(.startWrist), "1.0.1 starts the wrist: \(commands)")
    }

    func testAThumbWaitingWhenTheCameraStopsAgainIsAnchoredAgain() {
        for assist in [Assist.off, Rig.goTo(lock: LockRule(variant: .holdThenSlide, timeLimitS: 30))] {
            var rig = Rig(.screenTurns, assist: assist)
            rig.send(.attitude(Self.tippedTowardFlat), after: 0.5)
            // The camera stops: the stop ends every hold, and the count moves in a step of its own after it.
            rig.facts.trackingRefusal = .notTracking
            rig.send(.holdsEnded(.cameraStopped), after: 0.5)
            rig.facts.attitudeFrame = 1
            rig.batch([], after: 0.01)
            // Its samples come again before any report that the camera is back, and a thumb comes down on them.
            rig.send(.attitude(Self.tippedTowardFlat), after: 1)
            var commands = rig.touchDown(1, at: Rig.middle, after: 0.4)
            // A second report of a stop, while the camera is still marked stopped, moves the count with no stop of its
            // own.
            rig.facts.attitudeFrame = 2
            commands += rig.batch([], after: 0.02)
            commands += rig.send(.attitude(Self.sameInANewFrame), after: 0.03)
            commands += rig.wait(0.2)
            XCTAssertEqual(
                commands, [],
                "\(assist): a thumb already down kept its anchor from before the camera stopped again, and the first "
                    + "sample after it was read as a turn and refused")
            XCTAssertEqual(rig.phase(.touch(1)), .waiting, "\(assist)")
        }
    }

    func testAThumbRestingPastItsPalmWindowWhenTheFrameChangesIsAnchoredAgain() {
        for assist in [Assist.off, Rig.goTo(lock: LockRule(variant: .holdThenSlide, timeLimitS: 30))] {
            var rig = Rig(.screenTurns, assist: assist)
            rig.send(.attitude(Self.tippedTowardFlat), after: 0.5)
            var commands = rig.touchDown(1, at: Rig.middle, after: 0.4)
            // Its palm window ends with the phone still, and it rests, waiting for a turn or a slide.
            commands += rig.wait(0.3)
            XCTAssertEqual(rig.phase(.touch(1)), .waiting, "\(assist)")
            rig.facts.attitudeFrame = 1
            commands += rig.batch([], after: 0.02)
            commands += rig.send(.attitude(Self.sameInANewFrame), after: 0.03)
            commands += rig.wait(0.2)
            XCTAssertEqual(
                commands, [],
                "\(assist): a thumb resting past its palm window kept its anchor from before the tracking started "
                    + "again, and the first sample after it was read as a turn the phone never made")
            XCTAssertEqual(rig.phase(.touch(1)), .waiting, "\(assist)")
        }
    }

    func testAThumbAnchoredAgainCommitsAsOneThatCameDownWithNoAnchor() {
        // The phone's samples from the first of the new frame on: still, then a real turn that commits the wrist.
        func turnInTheNewFrame(_ rig: inout Rig) -> [InputCommand] {
            var commands = rig.send(.attitude(Self.sameInANewFrame), after: 0.03)
            commands += rig.wait(0.3)
            for degrees in 1...12 {
                let sample = Phone.attitude(turn: Double(degrees), from: Self.sameInANewFrame)
                commands += rig.send(.attitude(sample), after: 1.0 / 60)
            }
            return commands
        }
        for assist in [Assist.off, Rig.goTo(lock: LockRule(variant: .holdThenSlide, timeLimitS: 30))] {
            // Down on the last sample of the old frame, and anchored again when the tracking starts again.
            var again = Rig(.screenTurns, assist: assist)
            again.send(.attitude(Self.tippedTowardFlat), after: 0.5)
            again.touchDown(1, at: Rig.middle, after: 0.4)
            again.facts.attitudeFrame = 1
            again.batch([], after: 0.02)
            // Down at the same instant in the call that starts the new frame, so with nothing to anchor on.
            var fresh = Rig(.screenTurns, assist: assist)
            fresh.send(.attitude(Self.tippedTowardFlat), after: 0.5)
            fresh.facts.attitudeFrame = 1
            fresh.touchDown(1, at: Rig.middle, after: 0.4)
            fresh.batch([], after: 0.02)

            let anchoredAgain = turnInTheNewFrame(&again)
            let noAnchor = turnInTheNewFrame(&fresh)
            XCTAssertTrue(noAnchor.contains(.startWrist), "\(assist): \(noAnchor)")
            XCTAssertNotEqual(noAnchor.wristTargets.first?.degrees ?? 0, 0, "\(assist): \(noAnchor)")
            XCTAssertEqual(
                anchoredAgain.wristTargets.first, noAnchor.wristTargets.first,
                "\(assist): a thumb anchored again did not start the wrist at the angle it committed at, as a thumb "
                    + "that came down with no anchor does")
            XCTAssertEqual(anchoredAgain, noAnchor, "\(assist)")
        }
    }

    func testAFrameChangeIsTakenBeforeTheTimersOfItsCall() {
        for assist in [Assist.off, Rig.goTo(lock: LockRule(variant: .holdThenSlide, timeLimitS: 30))] {
            var rig = Rig(.screenTurns, assist: assist)
            var commands = rig.touchDown(1, at: Rig.middle, after: 0.5)
            // A turn inside the thumb's palm window, in the old frame. The window runs out between two calls, and the
            // next call carries the change of frame.
            commands += rig.send(.attitude(Phone.attitude(turn: 12)), after: 0.05)
            rig.facts.attitudeFrame = 1
            commands += rig.batch([], after: 0.1)
            XCTAssertEqual(
                commands, [],
                "\(assist): a palm window that ran out before the frame changed was judged with an attitude from "
                    + "the old frame, in the call that carried the change")
            XCTAssertEqual(rig.phase(.touch(1)), .waiting, "\(assist)")
        }
    }

    func testAKeyHeldFromBeforeTheFirstSampleOfANewRunTurnsNothing() {
        // Pressed after the tracking started again, before its first sample.
        var rig = Rig(.keyTurns)
        rig.send(.attitude(Self.tippedTowardFlat), after: 0.5)
        rig.facts.attitudeFrame = 1
        rig.wait(0.5)
        XCTAssertEqual(rig.press(.lower, after: 0.3), [.startWrist, .wristUpdate(.identity)])
        var targets = rig.send(.attitude(Self.sameInANewFrame), after: 0.05).wristTargets
        targets += rig.wait(0.2).wristTargets
        XCTAssertTrue(targets.allSatisfy { $0 == .identity }, "\(targets)")
        // From the first sample of the new frame on, the phone's turns count as they always do.
        var turned: [InputCommand] = []
        for degrees in 1...8 {
            let sample = Phone.attitude(turn: Double(degrees), from: Self.sameInANewFrame)
            turned += rig.send(.attitude(sample), after: 0.02)
        }
        XCTAssertEqual(turned.wristTargets.last?.axis, .turn, "\(turned)")

        // Pressed before the tracking started again, and not yet committed to an axis: the hold goes on, anchored
        // again at the first sample of the new frame.
        var held = Rig(.keyTurns)
        held.send(.attitude(Self.tippedTowardFlat), after: 0.5)
        XCTAssertEqual(held.press(.lower, after: 0.3), [.startWrist, .wristUpdate(.identity)])
        held.facts.attitudeFrame = 1
        XCTAssertEqual(held.wait(0.5), [])
        targets = held.send(.attitude(Self.sameInANewFrame), after: 0.05).wristTargets
        targets += held.wait(0.2).wristTargets
        XCTAssertTrue(targets.allSatisfy { $0 == .identity }, "\(targets)")
        XCTAssertEqual(held.phase(.key(.lower)), .engaged(.wrist))
        XCTAssertEqual(held.release(.lower, after: 0.3), [.stopWrist])
    }

    func testACameraStopStartsANewFrame() {
        var rig = Rig(.screenTurns)
        rig.send(.attitude(Self.tippedTowardFlat), after: 0.5)
        // A thumb turning the wrist when the camera stops: the stop ends the hold, and the count moves in a step of
        // its own after it, with nothing left to end.
        rig.touchDown(1, at: Rig.middle, after: 0.2)
        rig.send(.attitude(Phone.attitude(turn: 10, from: Self.tippedTowardFlat)), after: 0.05)
        XCTAssertTrue(rig.wait(0.1).contains(.startWrist))
        XCTAssertEqual(rig.send(.holdsEnded(.cameraStopped), after: 0.1).withoutUpdates, [.stopWrist])
        rig.facts.attitudeFrame = 1
        XCTAssertEqual(rig.wait(0.01), [])
        XCTAssertEqual(rig.lift(1, after: 0.3), [])
        // The camera comes back with the phone pointing elsewhere: a thumb down before the first sample turns nothing.
        rig.touchDown(2, at: Rig.middle, after: 2)
        var after = rig.send(.attitude(Self.sameInANewFrame), after: 0.05)
        after += rig.wait(0.2)
        XCTAssertEqual(after, [], "a sample after the camera stopped was compared with one from before it")
        XCTAssertEqual(rig.phase(.touch(2)), .waiting)
    }

    func testAWristHoldEngagedAtAFrameChangeEndsAsACameraStopEndsIt() {
        for scheme in [InputScheme.screenTurns, .keyTurns] {
            var changed = Self.committedWristHold(scheme)
            var stopped = Self.committedWristHold(scheme)
            XCTAssertEqual(changed.arbiter.engagedHold, .wrist, "\(scheme)")
            XCTAssertNotNil(changed.log.wristTargets.last?.axis, "\(scheme)")
            changed.facts.attitudeFrame = 1
            let byFrame = changed.wait(0.05)
            let byStop = stopped.send(.holdsEnded(.cameraStopped), after: 0.05)
            XCTAssertEqual(byFrame, byStop, "\(scheme)")
            XCTAssertTrue(byFrame.contains(.stopWrist), "\(scheme): \(byFrame)")
            XCTAssertNil(changed.arbiter.engagedHold, "\(scheme)")
            XCTAssertEqual(changed.arbiter.held, stopped.arbiter.held, "\(scheme)")
            // Its input stays dead until it is let go of, as after a camera stop.
            XCTAssertEqual(changed.rotate(turn: 20), [], "\(scheme)")
        }

        // Holds that do not follow the phone's turns go on.
        var jaws = Rig(.screenTurns)
        XCTAssertEqual(jaws.press(.lower, after: 0.3), [.startGripper(.closed)])
        jaws.facts.attitudeFrame = 1
        XCTAssertEqual(jaws.wait(0.05), [])
        XCTAssertEqual(jaws.release(.lower, after: 0.3), [.stopGripper])
        var arm = Rig(.keyTurns)
        XCTAssertEqual(arm.press(.upper, after: 0.3), [.startTranslation])
        arm.facts.attitudeFrame = 1
        XCTAssertEqual(arm.wait(0.05), [])
        XCTAssertEqual(arm.release(.upper, after: 0.3), [.stopTranslation])
    }

    /// Scheme A: a thumb whose turn committed the wrist. Scheme B: the lower key, its hold committed to tilt.
    private static func committedWristHold(_ scheme: InputScheme) -> Rig {
        var rig = Rig(scheme)
        switch scheme {
        case .screenTurns:
            rig.touchDown(1, at: Rig.middle, after: 0.3)
            rig.rotate(turn: 12, steps: 12)
        case .keyTurns:
            rig.press(.lower, after: 0.3)
            rig.rotate(tilt: 9)
        }
        return rig
    }

    func testWithTheFrameUnchangedTheRulesAreAsBefore() {
        let aids = Rig.goTo(lock: LockRule(variant: .holdThenSlide, timeLimitS: 30))
        let arm = SIMD3(0.027617, -0.177418, Rig.travelZ)
        for scheme in [InputScheme.screenTurns, .keyTurns] {
            for assist in [Assist.off, aids] {
                let facts = assist == .off ? InputFacts() : Rig.goFacts(arm: arm)
                var atZero = InputArbiter(scheme: scheme, layout: Rig.layout, assist: assist)
                var atFour = InputArbiter(scheme: scheme, layout: Rig.layout, assist: assist)
                var old = InputArbiter101(scheme: scheme, layout: Rig.layout)
                var time = 10.0
                var acted = false
                for (index, step) in Self.mix(scheme).enumerated() {
                    time += step.after
                    var four = facts
                    four.attitudeFrame = 4
                    let expected = atZero.handle(step.events, at: time, facts: facts)
                    let got = atFour.handle(step.events, at: time, facts: four)
                    acted = acted || !expected.isEmpty
                    XCTAssertEqual(got, expected, "\(scheme), \(assist), step \(index)")
                    XCTAssertEqual(atFour.held, atZero.held, "\(scheme), \(assist), step \(index)")
                    if assist == .off {
                        XCTAssertEqual(
                            got, old.handle(step.events, at: time, facts: four), "1.0.1, \(scheme), \(index)")
                    }
                }
                XCTAssertTrue(acted, "\(scheme), \(assist)")
            }
        }
    }

    /// Touches, keys and samples of both kinds of hold, in the given scheme, with a tap on the guide's view among them.
    private static func mix(_ scheme: InputScheme) -> [(after: TimeInterval, events: [InputEvent])] {
        var steps: [(after: TimeInterval, events: [InputEvent])] = []
        func at(_ after: TimeInterval, _ events: InputEvent...) { steps.append((after, events)) }
        let point = Rig.inPanel(0.3, 0.65)
        at(0, .attitude(Phone.rest))
        switch scheme {
        case .screenTurns:
            at(0.3, touch(1, .began))
            for step in 1...12 { at(1.0 / 60, .attitude(Phone.attitude(turn: Double(step)))) }
            at(0.1, .wristStartSent)
            at(0.2, touch(1, .ended))
            at(0.3, .keyDown(.lower))
            at(0.4, .keyUp(.lower))
            at(0.3, touch(2, .began, Rig.rightHalf))
            for step in 1...12 { at(0.01, touch(2, .moved, Rig.rightHalf - SIMD2(0, 6.4 * Double(step)))) }
            at(0.2, touch(2, .ended, Rig.rightHalf - SIMD2(0, 6.4 * 12)))
        case .keyTurns:
            at(0.3, .keyDown(.lower))
            for step in 1...12 { at(1.0 / 60, .attitude(Phone.attitude(tilt: Double(step)))) }
            at(0.05, .wristStartSent)
            at(0.3, .keyUp(.lower))
            at(0.3, touch(2, .began, Rig.rightHalf))
            at(0.2, .tick)
            at(0.3, touch(2, .ended, Rig.rightHalf))
        }
        at(0.3, .keyDown(.upper))
        at(0.1, .attitude(Phone.attitude(turn: 3, tilt: 2)))
        at(0.5, .keyUp(.upper))
        at(0.2, .sceneReset)
        at(0.3, touch(3, .began, point))
        at(0.08, touch(3, .ended, point))
        at(0.5, .tick)
        at(0.2, touch(4, .began))
        at(0.1, touch(4, .ended))
        at(0.3, .tick)
        return steps
    }
}
