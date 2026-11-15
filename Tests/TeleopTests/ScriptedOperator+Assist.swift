import simd
import TeleopCore
import XCTest
@testable import Teleop

/// The gestures of lock, made with the hand's raw inputs only, like everything else the scripted hand does.
extension ScriptedOperator {
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
