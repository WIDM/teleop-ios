/// Why a server that keeps one phone per simulator (`--one-phone`) refused or let go of this phone. It comes as an
/// `error` message just before the server closes the connection.
public enum SessionDismissal: String, Equatable, Sendable, CaseIterable {
    /// Another phone holds this simulator.
    case inUse = "session_in_use"
    /// This phone was silent long enough that another phone took the simulator.
    case taken = "session_taken"
    /// No operation for longer than the server allows.
    case idle = "idle_timeout"
}
