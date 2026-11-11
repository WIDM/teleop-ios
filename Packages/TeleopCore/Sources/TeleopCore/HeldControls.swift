extension FakeTeleopState {
    /// True while the hold that the `start` action begins is the one running. Another control may have taken
    /// over from it since (one held control runs at a time), and then releasing the first must not end that.
    public func isHolding(_ start: TeleopAction) -> Bool {
        switch start {
        case .holdArmStart: return armMoving
        case .gripperStart(let target): return gripperMoving == target
        case .turnStart(let direction): return jawTurning == direction
        case .wristStart: return wristMoving
        default: return false
        }
    }
}
