import Foundation
import TeleopCore
import XCTest
@testable import Teleop

/// The SO-101 profile file bundled with the app holds exactly these numbers: each field against the SO-101's literal.
final class ProfileFileTests: XCTestCase {
    private static func rows(_ p: RobotProfile) -> [(String, AnyHashable, AnyHashable)] {
        [
            ("name", p.name, "SO-101 (S4 simulator)"),
            ("toolOffset", p.toolOffset, SIMD3<Float>(0.007, -0.036, -0.088)),
            ("offsetMeasuredAt", p.offsetMeasuredAt, SIMD3<Float>(-0.002, -0.164, 0.1405)),
            ("offsetMeasuredFlexDeg", p.offsetMeasuredFlexDeg, 40.24),
            ("offsetMeasuredRollDeg", p.offsetMeasuredRollDeg, 90.0),
            ("estimateBound.xMmPerCm", p.estimateBound.xMmPerCm, Float(2.56)),
            ("estimateBound.plusYMmPerCm", p.estimateBound.plusYMmPerCm, Float(11.12)),
            ("estimateBound.minusYMmPerCm", p.estimateBound.minusYMmPerCm, Float(1.80)),
            ("estimateBound.zMmPerCm", p.estimateBound.zMmPerCm, Float(8.43)),
            ("estimateBound.flexMmPerDeg", p.estimateBound.flexMmPerDeg, Float(1.65)),
            ("estimateBound.rollMmPerDeg", p.estimateBound.rollMmPerDeg, Float(0.23)),
            ("baseInWorld", p.baseInWorld, SIMD3<Float>(0, 0, 0.05)),
            ("frames.forward", p.frames.forward.text, "-y"),
            ("frames.left", p.frames.left.text, "+x"),
            ("frames.up", p.frames.up.text, "+z"),
            ("frames.linkSigns", p.frames.linkSigns, SIMD3<Double>(1, 1, -1)),
            ("frames.worldTurn.x", p.frames.worldTurn.x.text, "+x"),
            ("frames.worldTurn.y", p.frames.worldTurn.y.text, "+y"),
            ("frames.worldTurn.z", p.frames.worldTurn.z.text, "+z"),
            ("graspTolerance", p.graspTolerance, SIMD2<Float>(0.006, 0.008)),
            ("targetSize", p.targetSize, Float(0.025)),
            ("goalSize", p.goalSize, Float(0.05)),
            ("gripper.unit", p.gripper.unit, JawUnit.deg),
            ("gripper.closedReading", p.gripper.closedReading, 0.0),
            ("gripper.openReading", p.gripper.openReading, 97.0),
            ("gripper.validMin", p.gripper.validMin, -360.0),
            ("gripper.validMax", p.gripper.validMax, 360.0),
            ("gripper.fullyOpenAt", p.gripper.fullyOpenAt, 97.0),
            ("gripper.emptyAt", p.gripper.emptyAt, 2.0),
            ("workspaceMin", p.workspaceMin, SIMD3<Float>(-0.052383, -0.257418, -0.008015)),
            ("workspaceMax", p.workspaceMax, SIMD3<Float>(0.107617, -0.097418, 0.151985)),
            ("tableHeight", p.tableHeight, Float(0.04)),
            ("wrist.rollSign", p.wrist.rollSign, 1.0),
            ("wrist.tiltSign", p.wrist.tiltSign, 1.0),
            ("wrist.rollWindowDeg", p.wrist.rollWindowDeg, 150.0),
            ("wrist.tiltWindowDeg", p.wrist.tiltWindowDeg, 25.0),
            ("wrist.rollClampDeg", p.wrist.rollClampDeg, 55.0),
            ("wrist.tiltClampDeg", p.wrist.tiltClampDeg, 20.0),
            ("wrist.tiltCentre", p.wrist.tiltCentre, TiltCentre.measuredAfterReset),
            ("wrist.turnRateDegS", p.wrist.turnRateDegS, 20.0),
            ("wrist.tiltRateDegS", p.wrist.tiltRateDegS, 10.0),
            ("wrist.lead.leadDeg", p.wrist.lead.leadDeg, 2.0),
            ("wrist.lead.rateMaxDegS", p.wrist.lead.rateMaxDegS, 10.0),
            ("wrist.lead.memoryDeg", p.wrist.lead.memoryDeg, 0.5),
            ("wrist.lead.freshStateMs", p.wrist.lead.freshStateMs, 400),
            ("motion.fineMps", p.motion.fineMps, 0.01),
            ("motion.coarseMps", p.motion.coarseMps, 0.04),
            ("motion.maxLeadM", p.motion.maxLeadM, Float(0.08)),
            ("motion.toolMaxLeadM", p.motion.toolMaxLeadM, Float(0.005)),
            ("server.stopDistanceM", p.server.stopDistanceM, 0.10),
            ("server.resync.afterMs", p.server.resync.afterMs, 1500),
            ("server.resync.toolAfterMs", p.server.resync.toolAfterMs, 500),
            ("server.resync.timeoutMs", p.server.resync.timeoutMs, 1500),
            ("server.heldObjectPoint", p.server.heldObjectPoint, HeldObjectPoint.gripperLink),
            ("server.stallDetection", p.server.stallDetection, StallDetection.simulation),
            ("recloseLoosensGrip", p.recloseLoosensGrip, true),
            ("usesDirectionalBlockedFeedback", p.usesDirectionalBlockedFeedback, true),
            ("blocked.shortM", p.blocked.shortM, 0.010),
            ("blocked.movedM", p.blocked.movedM, 0.002),
            ("blocked.windowMs", p.blocked.windowMs, 1000),
            ("blocked.freshMs", p.blocked.freshMs, 400),
            ("blocked.arrivalGapMs", p.blocked.arrivalGapMs, 400),
            ("blocked.leadProgressShare", p.blocked.leadProgressShare, 0.10),
            ("blocked.exclusionM", p.blocked.exclusionM, 0.04),
            ("blocked.followingShare", p.blocked.followingShare, 0.5),
            ("blocked.sameWayDeg", p.blocked.sameWayDeg, 45.0),
            ("lowest.sustainM", p.lowest.sustainM, 0.005),
            ("lowest.quickShortM", p.lowest.quickShortM, 0.005),
            ("lowest.quickMovedM", p.lowest.quickMovedM, 0.001),
            ("lowest.quickMs", p.lowest.quickMs, 300),
            ("lowest.descentMps", p.lowest.descentMps, 0.0005),
            ("assist.lock.timeLimitS", p.assist.lock?.timeLimitS, Double?(30.0)),
            ("assist.goTo.travelHeightM", p.assist.goTo?.travelHeightM, Double?(0.05)),
            ("assist.goTo.speedMps", p.assist.goTo?.speedMps, Double?(0.04)),
            ("assist.goTo.arriveToleranceM", p.assist.goTo?.arriveToleranceM, Double?(0.008)),
            ("assist.goTo.corrections", p.assist.goTo?.corrections, Int?(2)),
            ("assist.goTo.correctionReachM", p.assist.goTo?.correctionReachM, Double?(0.03)),
            ("assist.goTo.settleS", p.assist.goTo?.settleS, Double?(0.6)),
            ("assist.goTo.timeFactor", p.assist.goTo?.timeFactor, Double?(1.5)),
            ("assist.goTo.allowanceS", p.assist.goTo?.allowanceS, Double?(3.0)),
            ("assist.goTo.armDataTimeoutS", p.assist.goTo?.armDataTimeoutS, Double?(2.0)),
            ("assist.goTo.startGraceS", p.assist.goTo?.startGraceS, Double?(1.5)),
            ("assist.goTo.pacing.followShare", p.assist.goTo?.pacing.followShare, Double?(0.5)),
            ("assist.goTo.pacing.paceGain", p.assist.goTo?.pacing.paceGain, Double?(0.25)),
            ("assist.goTo.pacing.slowestShare", p.assist.goTo?.pacing.slowestShare, Double?(0.15)),
            ("assist.goTo.pacing.startShare", p.assist.goTo?.pacing.startShare, Double?(0.5)),
            ("assist.goTo.pacing.pathWatchTolerances", p.assist.goTo?.pacing.pathWatchTolerances, Double?(2.5)),
            ("assist.goTo.pacing.freshMs", p.assist.goTo?.pacing.freshMs, Int?(400)),
            ("assist.goTo.pacing.stillM", p.assist.goTo?.pacing.stillM, Double?(0.002)),
            ("assist.goTo.pacing.paceChangeShare", p.assist.goTo?.pacing.paceChangeShare, Double?(0.05)),
            ("assist.guide.workAreaWords", p.assist.guide?.workAreaWords, Bool?(true)),
            ("assist.guide.lowestCue", p.assist.guide?.lowestCue, Bool?(true)),
            ("assist.guide.shadow", p.assist.guide?.shadow, Bool?(true)),
            ("assist.guide.directionLabels", p.assist.guide?.directionLabels, Bool?(true)),
            ("assist.guide.widerOnTarget", p.assist.guide?.widerOnTarget, Bool?(true)),
            ("assist.explain.slowLinkLetGo", p.assist.explain?.slowLinkLetGo, Bool?(true)),
            ("assist.views.behindTopAboveTableM", p.assist.views?.behindTopAboveTableM, Double?(0.09)),
            ("assist.views.maxRetargetedMoveS", p.assist.views?.maxRetargetedMoveS, Double?(30.0)),
            ("onTargetWindow", p.onTargetWindow, SIMD2<Float>?.none),
        ]
    }

    func testEachFieldOfTheSO101FileMatchesItsLiteral() {
        for (field, file, literal) in Self.rows(TestProfiles.so101) {
            XCTAssertEqual(file, literal, field)
        }
    }

    /// Every stored field of the profile, its assist share included, has a row above and every row names a stored
    /// field: a new field must be pinned, and a row for a field that is gone must go. Compared by name, so that one
    /// miscount cannot hide another.
    func testTheTableCoversEveryField() {
        let p = TestProfiles.so101
        // The structures the rows name by their parts. A value of any other type is a field of its own, however many
        // parts it has (a vector, a signed axis).
        func isStructure(_ value: Any) -> Bool {
            value is EstimateBound || value is WristProfile || value is GripperProfile || value is WristLeadLimits
                || value is MotionProfile || value is ServerProfile || value is ResyncTimes || value is BlockedRule
                || value is LowestRule || value is GoToPacing
                || value is Frames
                || value is WorldTurn || value is AssistProfile
                || value is LockLimits || value is GoToLimits || value is GuideAids || value is ExplainAids
                || value is ViewAim
        }
        func fields(of value: Any, under prefix: String) -> [String] {
            Mirror(reflecting: value).children.flatMap { child -> [String] in
                guard let label = child.label else { return [] }
                let path = prefix.isEmpty ? label : prefix + "." + label
                let inner = Mirror(reflecting: child.value)
                let held: Any? = inner.displayStyle == .optional ? inner.children.first?.value : child.value
                if let held, isStructure(held) { return fields(of: held, under: path) }
                return [path]
            }
        }
        // The shift is a stored field of the frames; the profile's own property of that name is what its row reads.
        let stored = fields(of: p, under: "").map { $0 == "frames.baseInWorld" ? "baseInWorld" : $0 }
        let named = Self.rows(p).map(\.0)
        XCTAssertEqual(stored.count, Set(stored).count, "a field is listed twice: \(stored)")
        XCTAssertEqual(named.count, Set(named).count, "a row is listed twice: \(named)")
        XCTAssertEqual(Set(stored).subtracting(named).sorted(), [], "stored fields with no row")
        XCTAssertEqual(Set(named).subtracting(stored).sorted(), [], "rows that name no stored field")
    }
}
