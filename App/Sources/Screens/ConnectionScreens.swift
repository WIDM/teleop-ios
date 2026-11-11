import TeleopCore

/// The old connection sheet's latency read-out. Nothing shows it any more (the operating screen's slow-link state
/// gives the number); `LocalizationTests` still checks its words, so it stays until that test changes.
enum ConnectionDetailsScreen {
    /// A number only for a round trip measured on the link that is up now. The demo link measures none.
    static func latencyText(_ state: FakeTeleopState) -> String {
        guard state.connected, let ms = state.latencyMs else { return L10n.string("connection.latency_none") }
        let format = state.latencyIsAmber
            ? L10n.string("connection.latency_high")
            : L10n.string("connection.latency_normal")
        return String(format: format, ms)
    }
}
