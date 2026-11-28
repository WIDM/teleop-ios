/// The numbers the feedback monitor decides "Blocked." by: the commanded point is ahead of the measured arm, and the arm
/// has made little progress. They come from how one arm and its server answer a command (the SO-101 in the S4 simulator
/// moves at about 12 to 17 passes a second): a faster arm stalls inside the window, a slower one is told it is blocked
/// while it is moving.
public struct BlockedRule: Equatable, Sendable {
    /// The commanded point is at least this far ahead of the measured one for the arm to count as held back, metres.
    public var shortM: Double
    /// Over the window the measured arm moved less than this, metres: it stood still. Also how close two points must be
    /// to count as the same place.
    public var movedM: Double
    /// The window the arm is judged over, milliseconds.
    public var windowMs: Int
    /// A measured position older than this says nothing about now, milliseconds.
    public var freshMs: Int
    /// No two states of a judged window arrived further apart than this, milliseconds: states held back and delivered
    /// together say nothing about how the arm stood between them.
    public var arrivalGapMs: Int
    /// The arm made less progress along the lead than this share of the lead.
    public var leadProgressShare: Double
    /// An arm that moved this far, metres, is following the command, whatever its direction.
    public var exclusionM: Double
    /// An arm that moved along the command's own travel by at least this share of that travel is following it.
    public var followingShare: Double
    /// A lead that turns by less than this, degrees, is part of the same request.
    public var sameWayDeg: Double

    public init(
        shortM: Double, movedM: Double, windowMs: Int, freshMs: Int, arrivalGapMs: Int, leadProgressShare: Double,
        exclusionM: Double, followingShare: Double, sameWayDeg: Double
    ) {
        self.shortM = shortM
        self.movedM = movedM
        self.windowMs = windowMs
        self.freshMs = freshMs
        self.arrivalGapMs = arrivalGapMs
        self.leadProgressShare = leadProgressShare
        self.exclusionM = exclusionM
        self.followingShare = followingShare
        self.sameWayDeg = sameWayDeg
    }
}

/// The numbers of the "Can't go lower." rule, which judges the height alone: an arm on a table slides along it, so it is
/// never still in all three directions.
public struct LowestRule: Equatable, Sendable {
    /// Every state of the window was sent at least this much lower, metres: the least ask the rule judges.
    public var sustainM: Double
    /// The quicker stall, back near the lowest height already found: every state of its window was sent at least this
    /// much lower, metres, and the height moved less than `quickMovedM` in `quickMs`.
    public var quickShortM: Double
    public var quickMovedM: Double
    public var quickMs: Int
    /// No stall is told while the height is still falling at least this fast over its window, metres a second. A slow
    /// simulator moves the arm slowly in wall time; a rate is judged the same over a long window and a short one.
    public var descentMps: Double

    public init(sustainM: Double, quickShortM: Double, quickMovedM: Double, quickMs: Int, descentMps: Double) {
        self.sustainM = sustainM
        self.quickShortM = quickShortM
        self.quickMovedM = quickMovedM
        self.quickMs = quickMs
        self.descentMps = descentMps
    }
}
