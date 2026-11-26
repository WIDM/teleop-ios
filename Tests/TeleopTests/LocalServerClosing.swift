import Foundation
import TeleopServerHost

extension LocalTeleopServer {
    /// Runs the main run loop until the server has read the close of every socket the app closed, or `seconds` pass.
    /// True when none is left.
    ///
    /// Closing a socket can hold up the networking of the whole test process, the app's and this server's alike: on a
    /// CI runner a connect made right after a close did not start for 3.7 s and 6.4 s, past the 4 s and 5 s the app
    /// and the tests give a connect. The server reads a close the app made only after that hold-up, so waiting for
    /// this before connecting again, or before `stop`, keeps the hold-up out of the next connect. `stop` alone would
    /// cut the sockets and leave the hold-up to whatever connects next.
    func waitForTheAppsSocketsToClose(within seconds: TimeInterval = 30) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while openSockets > 0, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return openSockets == 0
    }
}
