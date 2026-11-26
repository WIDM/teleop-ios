import simd
import TeleopCore
import XCTest
@testable import Teleop

/// The gestures of lock and the tap on the guide, and the grasp before a carried move, made with the hand's raw inputs
/// only, like everything else the scripted hand does. For the tap the hand also plays the operating screen's part,
/// which no view plays in the unit-test host: it reports where the guide's view from above is drawn.
extension ScriptedOperator {
    /// About where the reference phone draws the guide's view from above. The input rules use only what is reported;
    /// `GuidePanelTapUITests` checks the drawn rectangle on a device.
    static let panelRect = SurfaceLayout.Rect(x: 118, y: 262, width: 166, height: 166)

    /// Plays the operating screen's part: the guide's view from above is drawn at `rect`.
    func reportGuidePanel(_ rect: SurfaceLayout.Rect = ScriptedOperator.panelRect) {
        model.guidePanelChanged(rect)
    }

    /// Taps, still, for 50 ms, where the view from above draws `base` (robot base frame; its height does not show
    /// there), through the panel the input rules judge a tap against, as an eye and a thumb would. Fails the test when
    /// no panel reaches the rules.
    func tapGuide(over base: SIMD3<Double>, file: StaticString = #filePath, line: UInt = #line) throws {
        let panel = try XCTUnwrap(model.inputFacts().goPanel, "no panel reaches the rules", file: file, line: line)
        let point = panel.point(over: base)
        tap(x: point.x, y: point.y)
    }

    /// The pinch point of the newest state that carried the arm's position, robot base frame.
    func measuredPinch(file: StaticString = #filePath, line: UInt = #line) throws -> SIMD3<Double> {
        let state = try XCTUnwrap(model.link.newestArmState, "no position reported", file: file, line: line)
        let gripper = try XCTUnwrap(state.endEffector, file: file, line: line)
        let pinch = model.profile.pinchPoint(
            gripper: SIMD3<Float>(gripper), tool: state.toolPoint.map { SIMD3<Float>($0) }, flexDeg: state.wristFlexDeg,
            rollDeg: state.wristRollDeg)
        return SIMD3<Double>(pinch.point)
    }

    /// Opens the jaws, takes hold of the task object where the server reports it and lifts it 3 cm, with the scheme's
    /// own inputs, as `pickAndPlace` does before it carries the object. False, after failing the test, when no object
    /// is reported, the arm does not reach the grasp point, the jaws do not close on the object or it does not rise.
    func graspAndLift(file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let lift = SIMD3<Float>(0, 0, 0.03)
        gripper(.open, seconds: 5)
        guard let object = model.link.objectPosition else {
            XCTFail("\(mode): no task object reported", file: file, line: line)
            return false
        }
        // Where the reported gripper point has to be for the jaws to pinch the object's centre.
        let grasp = model.profile.inBase(world: object) - model.profile.toolOffset
        moveArm(to: grasp + lift, "above the grasp point")
        guard moveArm(to: grasp, "grasp point", maxHolds: 3) else {
            XCTFail("\(mode): the arm could not reach the grasp point", file: file, line: line)
            return false
        }
        gripper(.closed, seconds: 15)
        guard model.gripping else {
            XCTFail("\(mode): the jaws did not close on the object", file: file, line: line)
            return false
        }
        moveArm(to: grasp + lift, "lift 3 cm", maxHolds: 2)
        pump(1.0)
        guard let raised = model.link.objectPosition, raised.z - object.z > 0.015 else {
            XCTFail("\(mode): the object was not lifted", file: file, line: line)
            return false
        }
        return true
    }

    /// Lock as a press then a press: a press and release of the upper key; the follow stays latched.
    func lockPressPress() {
        press(.upper)
        pump(0.3)
        release(.upper)
    }

    /// Lock as a hold then a slide: hold the upper key, land a thumb at `point`, slide it up `millimetres` over
    /// `seconds`, lift it, release the key. At `surfaceCentre` in scheme B the thumb is in the centre band, where the
    /// input rules accept the latch.
    func lockHoldSlide(at point: SIMD2<Double>, millimetres: Int = 12, seconds: Double) {
        press(.upper)
        pump(0.3)
        let id = touchDown(x: point.x, y: point.y)
        slideUp(id, from: point, millimetres: millimetres, in: seconds)
        touchUp(id, x: point.x, y: point.y - Double(millimetres) * layout.pointsPerMm)
        release(.upper)
    }

    /// The gear's centre on the reference layout, away from the side edge.
    var gear: SIMD2<Double> { SIMD2(layout.gear.x + layout.gear.width / 2, layout.gear.y + layout.gear.height / 2) }
}
