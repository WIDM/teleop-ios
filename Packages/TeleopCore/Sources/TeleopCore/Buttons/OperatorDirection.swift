/// The six ways the operator can send the arm, as seen from the operator's place at the table. Buttons, voice and
/// the phone all use this frame (INTERACTION §3.3). Which base axis each one moves the arm along is the profile's
/// `Frames`; this type only names the directions.
public enum OperatorDirection: String, CaseIterable, Sendable {
    case forward, back, left, right, up, down
}
