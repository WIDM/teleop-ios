import XCTest

extension XCUIElement {
    /// Presses the element and returns the accessibility values it showed while the press call ran.
    ///
    /// `press(forDuration:)` pumps the run loop, so a timer on it can read the value mid-press. The reads are
    /// spread over the whole call because the touch does not begin when the call does: on a slow machine,
    /// finding the element first has taken more than four seconds, and a single read one second in saw the
    /// control before the finger was down.
    func valuesDuringPress(seconds: TimeInterval = 2.0) -> [String] {
        var seen: [String] = []
        // Reading the value pumps the run loop too, so the timer can fire again inside a read.
        var reading = false
        let timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [self] _ in
            guard !reading else { return }
            reading = true
            defer { reading = false }
            if let value = value as? String { seen.append(value) }
        }
        press(forDuration: seconds)
        timer.invalidate()
        return seen
    }
}
