import Foundation
import TeleopCore
import XCTest
@testable import Teleop

/// The SO-101 profile file bundled with the app holds exactly the numbers the app ran with when the profile was a
/// constant in code: each field against the literal it had there.
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
            ("graspTolerance", p.graspTolerance, SIMD2<Float>(0.006, 0.008)),
            ("targetSize", p.targetSize, Float(0.025)),
            ("goalSize", p.goalSize, Float(0.05)),
            ("gripperOpenDeg", p.gripperOpenDeg, 97.0),
            ("gripperEmptyDeg", p.gripperEmptyDeg, 2.0),
            ("workspaceMin", p.workspaceMin, SIMD3<Float>(-0.052383, -0.257418, -0.008015)),
            ("workspaceMax", p.workspaceMax, SIMD3<Float>(0.107617, -0.097418, 0.151985)),
            ("tableHeight", p.tableHeight, Float(0.04)),
            ("rollSign", p.rollSign, 1.0),
            ("tiltSign", p.tiltSign, 1.0),
            ("recloseLoosensGrip", p.recloseLoosensGrip, true),
            ("usesDirectionalBlockedFeedback", p.usesDirectionalBlockedFeedback, true),
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

    func testTheSO101FileHoldsTheNumbersTheConstantHad() {
        for (field, file, literal) in Self.rows(TestProfiles.so101) {
            XCTAssertEqual(file, literal, field)
        }
    }

    /// Every stored field of the profile, its assist share included, has a row above: a new field must be pinned too.
    func testTheTableCoversEveryField() {
        let p = TestProfiles.so101
        let stored = Mirror(reflecting: p).children.count - 2 + Mirror(reflecting: p.estimateBound).children.count
        let assist = Mirror(reflecting: p.assist).children.compactMap { child -> Int? in
            guard let value = Mirror(reflecting: child.value).children.first?.value else { return nil }
            return Mirror(reflecting: value).children.count
        }
        // Two stored fields are structures counted by their parts: estimateBound above and assist here.
        XCTAssertEqual(stored + assist.reduce(0, +), Self.rows(p).count)
    }
}
