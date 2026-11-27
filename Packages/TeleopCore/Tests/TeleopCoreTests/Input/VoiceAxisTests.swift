import XCTest
@testable import TeleopCore

final class VoiceAxisTests: XCTestCase {
    func testOnlyExactPositiveCommandsSelectAxes() {
        for (words, axis) in [
            ("只調高度", TranslationAxis.height), ("只調前後", .foreAft), ("只調左右", .leftRight),
            ("height only", .height), ("forward back only", .foreAft), ("left right only", .leftRight),
        ] {
            XCTAssertEqual(TranslationAxis.recognized(words), axis)
        }
        for words in ["不要只調高度", "高度", "只調高度然後移動", "", "stop", "not height only"] {
            XCTAssertNil(TranslationAxis.recognized(words))
        }
    }

    func testLocalizedSpeechOutputAcceptsOnlyWholeAxisCommands() {
        XCTAssertEqual(TranslationAxis.recognized("只調 高 度。"), .height)
        XCTAssertEqual(TranslationAxis.recognized("只调高度"), .height)
        XCTAssertEqual(TranslationAxis.recognized("只調整高度"), .height)
        XCTAssertEqual(TranslationAxis.recognized("只调前后"), .foreAft)
        XCTAssertEqual(TranslationAxis.recognized("只 調 左 右"), .leftRight)
        for text in ["不要只调高度", "只調高度還要往前", "只調高度，只調左右", "只調高", "高度"] {
            XCTAssertNil(TranslationAxis.recognized(text), text)
        }
    }

    func testSelectedAxisAlwaysStopsOnUpperReleaseWithEitherLatchConfigured() {
        for scheme in [InputScheme.screenTurns, .keyTurns] {
            for aid in [ArbiterRig.lockPressPress(), ArbiterRig.lockHoldSlide()] {
                var rig = ArbiterRig(scheme, assist: aid)
                rig.arbiter.selectTranslationAxis(.height, at: rig.time, facts: rig.facts)
                XCTAssertEqual(rig.press(.upper, after: 0.1), [.startTranslation])
                rig.touchDown(1, at: ArbiterRig.middle, after: 0.1)
                rig.wait(0.1)
                rig.slide(1, mm: 12, degrees: 90)
                XCTAssertFalse(rig.isLatched)
                XCTAssertTrue(rig.release(.upper).contains(.stopTranslation))
                XCTAssertNil(rig.arbiter.engagement)
            }
        }
    }

    func testAxisProjectionNeverLeaksOffAxisNoise() {
        XCTAssertEqual(
            TranslationAxis.height.project(right: 3, forward: 2, up: -5, frames: TestFrames.so101),
            TestFrames.so101.linkOffset(right: 0, forward: 0, up: -5))
        XCTAssertEqual(
            TranslationAxis.foreAft.project(right: 3, forward: 2, up: -5, frames: TestFrames.so101),
            TestFrames.so101.linkOffset(right: 0, forward: 2, up: 0))
        XCTAssertEqual(
            TranslationAxis.leftRight.project(right: 3, forward: 2, up: -5, frames: TestFrames.so101),
            TestFrames.so101.linkOffset(right: 3, forward: 0, up: 0))
    }
    func testDelayedPartialMidHoldAndOldEpochResultsCannotSelect() {
        var session = VoiceAxisSession()
        session.enable()
        let epoch = session.beginListening()!
        XCTAssertNil(session.accept("只調高度", final: false, epoch: epoch, capturedAt: 10, now: 10, inputIdle: true))
        XCTAssertNil(session.accept("只調高度", final: true, epoch: epoch, capturedAt: 10, now: 14, inputIdle: true))
        XCTAssertNil(session.accept("只調高度", final: true, epoch: epoch, capturedAt: 10, now: 10, inputIdle: false))
        session.suspend()
        let next = session.beginListening()!
        XCTAssertNil(session.accept("只調高度", final: true, epoch: epoch, capturedAt: 10, now: 10, inputIdle: true))
        XCTAssertEqual(
            session.accept("只調高度", final: true, epoch: next, capturedAt: 10, now: 10, inputIdle: true), .height)
        session.disable()
        XCTAssertNil(session.axis)
        XCTAssertNil(session.accept("只調左右", final: true, epoch: next, capturedAt: 10, now: 10, inputIdle: true))
    }

    func testAxisChangeEndsHoldAndRequiresFreshPhysicalPress() {
        var rig = ArbiterRig(.screenTurns)
        rig.arbiter.selectTranslationAxis(.height, at: rig.time, facts: rig.facts)
        rig.press(.upper, after: 0.1)
        XCTAssertTrue(rig.arbiter.selectTranslationAxis(nil, at: rig.time, facts: rig.facts).contains(.stopTranslation))
        XCTAssertFalse(rig.press(.upper, after: 0.1).contains(.startTranslation))
        rig.release(.upper)
        XCTAssertTrue(rig.press(.upper, after: 0.1).contains(.startTranslation))
    }

}
