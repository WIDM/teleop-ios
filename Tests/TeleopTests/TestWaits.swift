import Foundation

/// How long a test waits for something that only has to happen, not happen in time. Every wait it is used for returns
/// as soon as its condition holds, so a passing run is no slower for it; it only has to outlast a slow CI machine.
/// A wait whose length is itself what a test checks keeps its own number.
enum TestWaits {
    /// A connection to a server on this machine coming up, the control or the listening one.
    static let linkUp: TimeInterval = 15
    /// The arm or the wrist getting to where it was sent, on the server on this machine.
    static let serverMoves: TimeInterval = 15
}
