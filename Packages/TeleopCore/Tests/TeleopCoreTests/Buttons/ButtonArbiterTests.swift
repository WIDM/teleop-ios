import XCTest
@testable import TeleopCore

final class ButtonArbiterTests: XCTestCase {
    // MARK: Holds

    func testADirectionButtonHoldsATranslationThatRampsAndStopsOnRelease() {
        var pad = ButtonArbiter()
        XCTAssertEqual(pad.press(.forward, atMs: 1_000, gripping: false), [.startTranslation(.forward)])
        XCTAssertEqual(pad.engaged, .forward)
        XCTAssertEqual(pad.tick(atMs: 1_000), [.updateTranslation(.zero)])
        XCTAssertEqual(pad.tick(atMs: 1_500), [.updateTranslation(OperatorDirection.forward.linkVector * 0.02)], "Coarse by default")
        XCTAssertEqual(pad.release(.forward), [.stopTranslation])
        XCTAssertNil(pad.engaged)
        XCTAssertEqual(pad.tick(atMs: 1_600), [], "nothing streams after the stop")
    }

    func testEveryDirectionButtonRampsAlongItsOwnAxis() {
        for button in ButtonID.allCases {
            guard let direction = button.direction else { continue }
            var pad = ButtonArbiter(speed: .fine)
            XCTAssertEqual(pad.press(button, atMs: 0, gripping: false), [.startTranslation(direction)])
            XCTAssertEqual(pad.tick(atMs: 2_000), [.updateTranslation(direction.linkVector * 0.02)], "\(button)")
        }
        XCTAssertEqual(ButtonID.allCases.compactMap(\.direction), OperatorDirection.allCases)
    }

    func testTheGripperButtonsHoldTheJogAndStreamNoTarget() {
        var pad = ButtonArbiter()
        XCTAssertEqual(pad.press(.open, atMs: 0, gripping: true), [.startGripper(.open)], "open runs while gripping")
        XCTAssertEqual(pad.tick(atMs: 500), [])
        XCTAssertEqual(pad.release(.open), [.stopGripper])

        XCTAssertEqual(pad.press(.close, atMs: 1_000, gripping: false), [.startGripper(.closed)])
        XCTAssertEqual(pad.release(.close), [.stopGripper])
    }

    func testANewPressRampsAgainFromZero() {
        var pad = ButtonArbiter()
        _ = pad.press(.up, atMs: 0, gripping: false)
        _ = pad.release(.up)
        _ = pad.press(.up, atMs: 5_000, gripping: false)
        XCTAssertEqual(pad.tick(atMs: 5_000), [.updateTranslation(.zero)])
        XCTAssertEqual(pad.tick(atMs: 5_250), [.updateTranslation(OperatorDirection.up.linkVector * 0.01)])
    }

    // MARK: One button at a time

    func testAPressWhileAnotherIsHeldIsDeadAndCuesOnce() {
        var pad = ButtonArbiter()
        _ = pad.press(.forward, atMs: 0, gripping: false)
        XCTAssertEqual(pad.press(.up, atMs: 100, gripping: false), [.cue(.deadInput)])
        XCTAssertEqual(pad.engaged, .forward, "first press wins")
        XCTAssertEqual(pad.press(.up, atMs: 150, gripping: false), [], "the same finger again is nothing new")
        XCTAssertEqual(pad.tick(atMs: 500), [.updateTranslation(OperatorDirection.forward.linkVector * 0.02)])

        XCTAssertEqual(pad.release(.forward), [.stopTranslation])
        XCTAssertNil(pad.engaged, "releasing the held button does not wake the dead one")
        XCTAssertEqual(pad.tick(atMs: 700), [])
        XCTAssertEqual(pad.release(.up), [], "a dead button goes quietly")

        XCTAssertEqual(pad.press(.up, atMs: 900, gripping: false), [.startTranslation(.up)], "a fresh press works")
    }

    func testAPressWhileADeadButtonIsStillDownIsDeadToo() {
        var pad = ButtonArbiter()
        _ = pad.press(.open, atMs: 0, gripping: false)
        _ = pad.press(.left, atMs: 50, gripping: false)
        _ = pad.release(.open)
        XCTAssertEqual(pad.press(.right, atMs: 200, gripping: false), [.cue(.deadInput)])
        XCTAssertNil(pad.engaged)
    }

    func testReleasingAButtonThatIsNotDownDoesNothing() {
        var pad = ButtonArbiter()
        XCTAssertEqual(pad.release(.back), [])
        _ = pad.press(.back, atMs: 0, gripping: false)
        XCTAssertEqual(pad.release(.forward), [])
        XCTAssertEqual(pad.engaged, .back)
    }

    // MARK: The re-close guard

    func testCloseWhileGrippingSendsNothingAndSaysAlreadyGripping() {
        var pad = ButtonArbiter()
        XCTAssertEqual(pad.press(.close, atMs: 0, gripping: true), [.cue(.alreadyGripping)])
        XCTAssertNil(pad.engaged)
        XCTAssertEqual(pad.press(.forward, atMs: 100, gripping: true), [.cue(.deadInput)], "the refused button is still down")
        XCTAssertEqual(pad.release(.close), [], "nothing was started, so nothing is stopped")
        _ = pad.release(.forward)
        XCTAssertEqual(pad.press(.close, atMs: 300, gripping: false), [.startGripper(.closed)])
    }

    // MARK: The 20 pt drag-out

    func testAFingerSlippingOffItsButtonEndsTheHoldOnce() {
        let layout = ButtonPadLayout.make(width: 402, height: ButtonPadLayout.referenceHeight)
        let forward = layout.buttons[.forward]!
        var pad = ButtonArbiter()
        _ = pad.press(.forward, atMs: 0, gripping: false)

        var commands: [ButtonCommand] = []
        var slipped = false
        // The finger drifts straight up off the top edge, one point at a time.
        for step in 0...40 {
            let y = forward.minY - Double(step)
            if !slipped, layout.hasSlipped(off: .forward, x: forward.midX, y: y) {
                slipped = true
                commands += pad.release(.forward)
                XCTAssertEqual(step, 21, "slips when more than 20 pt outside, not before")
            }
        }
        XCTAssertEqual(commands, [.stopTranslation])
        XCTAssertEqual(pad.release(.forward), [], "the later lift sends nothing more")
        XCTAssertEqual(pad.press(.back, atMs: 900, gripping: false), [.startTranslation(.back)],
                       "a slipped finger no longer holds the pad")
    }

    // MARK: Fine / Coarse

    func testTheSpeedSwitchIsRefusedWhileAnyButtonIsDown() {
        var pad = ButtonArbiter()
        XCTAssertEqual(pad.speed, .coarse, "Coarse is the default")
        _ = pad.press(.down, atMs: 0, gripping: false)
        XCTAssertEqual(pad.selectSpeed(.fine), [.cue(.speedRefused)])
        XCTAssertEqual(pad.speed, .coarse)
        _ = pad.release(.down)

        _ = pad.press(.close, atMs: 100, gripping: true) // refused, but still down
        XCTAssertEqual(pad.selectSpeed(.fine), [.cue(.speedRefused)])
        _ = pad.release(.close)

        XCTAssertEqual(pad.selectSpeed(.fine), [.speedChanged(.fine)])
        XCTAssertEqual(pad.speed, .fine)
        XCTAssertEqual(pad.selectSpeed(.fine), [], "choosing the current speed sends nothing")
    }

    func testTheRampUsesTheSpeedChosenBeforeThePress() {
        var pad = ButtonArbiter()
        _ = pad.selectSpeed(.fine)
        _ = pad.press(.right, atMs: 0, gripping: false)
        XCTAssertEqual(pad.tick(atMs: 1_000), [.updateTranslation(OperatorDirection.right.linkVector * 0.01)])
    }

    // MARK: Holds ended from outside

    func testABlockedRampStopsMovingUntilRelease() {
        var pad = ButtonArbiter()
        _ = pad.press(.left, atMs: 0, gripping: false)
        pad.rampBlocked(atMs: 500)
        let held = OperatorDirection.left.linkVector * 0.02
        XCTAssertEqual(pad.tick(atMs: 500), [.updateTranslation(held)])
        XCTAssertEqual(pad.tick(atMs: 3_000), [.updateTranslation(held)], "the hold stays, the target does not move")
        XCTAssertEqual(pad.release(.left), [.stopTranslation])
        _ = pad.press(.left, atMs: 4_000, gripping: false)
        XCTAssertEqual(pad.tick(atMs: 4_500), [.updateTranslation(held)], "the next press ramps freely")
    }

    func testAHoldEndedElsewhereLeavesItsButtonDeadUntilReleased() {
        var pad = ButtonArbiter()
        _ = pad.press(.back, atMs: 0, gripping: false)
        pad.holdEnded()
        XCTAssertNil(pad.engaged)
        XCTAssertEqual(pad.tick(atMs: 300), [])
        XCTAssertEqual(pad.press(.up, atMs: 400, gripping: false), [.cue(.deadInput)])
        XCTAssertEqual(pad.release(.back), [], "the stop was not this pad's to send")
        _ = pad.release(.up)
        XCTAssertEqual(pad.press(.up, atMs: 600, gripping: false), [.startTranslation(.up)])
    }

    // MARK: Every ordering

    /// Random presses, releases, speed taps, blocks and outside ends over many fingers: never two holds, every
    /// start answered by exactly one stop of its kind, no start while another button is down, and a dead press
    /// never wakes.
    func testOneButtonAtATimeHoldsForEveryOrdering() {
        var random = SplitMix64(seed: 0x5EED)
        for _ in 0..<2_000 {
            var pad = ButtonArbiter()
            var running: ButtonCommand?
            var dead: Set<ButtonID> = []
            var now = 0
            for _ in 0..<40 {
                now += Int(random.next() % 120)
                let button = ButtonID.allCases[Int(random.next() % UInt64(ButtonID.allCases.count))]
                let downBefore = pad.down
                let out: [ButtonCommand]
                switch random.next() % 10 {
                case 0..<4:
                    out = pad.press(button, atMs: now, gripping: random.next() % 2 == 0)
                    let starts = out.filter(\.isStart)
                    if !downBefore.isEmpty || downBefore.contains(button) {
                        XCTAssertTrue(starts.isEmpty, "a start while a button was down")
                    }
                    if out == [.cue(.deadInput)] { dead.insert(button) }
                    if let start = starts.first {
                        XCTAssertNil(running, "two holds at once")
                        XCTAssertFalse(dead.contains(button), "a dead press woke")
                        running = start
                    }
                case 4..<8:
                    out = pad.release(button)
                    dead.remove(button)
                    if let stop = out.first(where: \.isStop) {
                        XCTAssertEqual(running?.matchingStop, stop, "a stop that does not match the running start")
                        running = nil
                    }
                case 8:
                    out = pad.selectSpeed(random.next() % 2 == 0 ? .fine : .coarse)
                    if !downBefore.isEmpty { XCTAssertEqual(out, [.cue(.speedRefused)]) }
                default:
                    if random.next() % 2 == 0 {
                        pad.rampBlocked(atMs: now)
                    } else {
                        pad.holdEnded()
                        running = nil
                        dead.formUnion(pad.down)
                    }
                    out = []
                }
                XCTAssertLessThanOrEqual(out.filter(\.isStart).count, 1)
                if let engaged = pad.engaged { XCTAssertTrue(pad.down.contains(engaged)) }
                XCTAssertEqual(pad.engaged == nil, running == nil)
                XCTAssertEqual(pad.tick(atMs: now).isEmpty, !(running?.isTranslation ?? false))
            }
        }
    }
}

private extension ButtonCommand {
    var isStart: Bool {
        switch self {
        case .startTranslation, .startGripper: return true
        default: return false
        }
    }

    var isStop: Bool { self == .stopTranslation || self == .stopGripper }
    var isTranslation: Bool { matchingStop == .stopTranslation }

    var matchingStop: ButtonCommand? {
        switch self {
        case .startTranslation: return .stopTranslation
        case .startGripper: return .stopGripper
        default: return nil
        }
    }
}
