import TeleopCore
import UIKit

/// Reports every raw touch on the operating screen (§2.1): began, moved, ended and cancelled, with the location in
/// points, `majorRadius` and the event time. SwiftUI gestures do not expose `majorRadius`, so this is a UIKit view.
///
/// Lay it over the whole screen, safe areas included, so its coordinates are the ones `SurfaceLayout` uses. Times are
/// seconds on the system uptime clock, the clock `ARFrame.timestamp` uses too, so touches and attitude samples can
/// go to `InputArbiter` on one time line.
final class TouchSurfaceView: UIView {
    var onTouch: ((TouchSample, TimeInterval) -> Void)?

    /// Each live touch's id, stable from `began` to `ended` or `cancelled`.
    private var ids: [ObjectIdentifier: Int] = [:]
    private var nextID = 1

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isMultipleTouchEnabled = true
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { report(touches, .began) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { report(touches, .moved) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { report(touches, .ended) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { report(touches, .cancelled) }

    private func report(_ touches: Set<UITouch>, _ phase: TouchSample.Phase) {
        for touch in touches.sorted(by: { $0.timestamp < $1.timestamp }) {
            let key = ObjectIdentifier(touch)
            let id: Int
            if phase == .began {
                id = nextID
                nextID += 1
                ids[key] = id
            } else if let known = ids[key] {
                id = known
            } else {
                continue
            }
            if phase == .ended || phase == .cancelled { ids[key] = nil }
            let point = touch.location(in: self)
            let sample = TouchSample(
                id: id, phase: phase, x: Double(point.x), y: Double(point.y), majorRadius: Double(touch.majorRadius)
            )
            onTouch?(sample, touch.timestamp)
        }
    }
}
