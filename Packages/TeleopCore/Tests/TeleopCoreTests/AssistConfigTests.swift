import XCTest
@testable import TeleopCore

/// "Off equals 1.0.1", checked without listing features by hand: `Assist.off` has every stored member nil, so a new aid
/// can only be added as a member whose off value is nil; and the master switch off resolves to `.off` whatever else is
/// chosen. With the switch on, each aid comes from the robot's share, lock only with the operator's choice, and numbers
/// the rules could not end a move with are refused here.
final class AssistConfigTests: XCTestCase {
    private let lockLimits = LockLimits(timeLimitS: 30)
    private let goLimits = GoToLimits(
        travelHeightM: 0.05, speedMps: 0.04, arriveToleranceM: 0.008, corrections: 1, correctionReachM: 0.03,
        settleS: 0.6, timeFactor: 1.5, allowanceS: 3, armDataTimeoutS: 2)
    private let guideOnly = GuideAids(
        workAreaWords: true, lowestCue: false, shadow: true, directionLabels: false, widerOnTarget: false)

    /// None, lock only, go only, guide only, all.
    private var profiles: [AssistProfile] {
        [
            .none, AssistProfile(lock: lockLimits), AssistProfile(goTo: goLimits), AssistProfile(guide: guideOnly),
            AssistProfile(lock: lockLimits, goTo: goLimits, guide: .all),
        ]
    }

    private let unusable: [Double] = [0, -1, .infinity, -.infinity, .nan]

    func testOffHasEveryMemberNil() {
        let members = Mirror(reflecting: Assist.off).children
        XCTAssertFalse(members.isEmpty)
        for member in members {
            let value = Mirror(reflecting: member.value)
            XCTAssertEqual(value.displayStyle, .optional, "\(member.label ?? "?") must be optional")
            XCTAssertTrue(value.children.isEmpty, "\(member.label ?? "?") must be nil when off")
        }
    }

    func testTheMasterSwitchOffIsOffWhateverElseIsChosen() {
        for choice in LockChoice.allCases {
            for profile in profiles {
                XCTAssertEqual(
                    Assist.resolve(masterOn: false, lockChoice: choice, profile: profile), .off,
                    "\(choice) with \(profile)")
            }
        }
    }

    func testLockNeedsTheRobotAndTheOperator() {
        let chosen: [LockChoice: LockVariant?] = [.off: nil, .pressPress: .pressPress, .holdThenSlide: .holdThenSlide]
        XCTAssertEqual(Set(chosen.keys), Set(LockChoice.allCases))
        let ownLimit = LockLimits(timeLimitS: 12.5)
        for profile in profiles + [AssistProfile(lock: ownLimit, goTo: goLimits)] {
            for choice in LockChoice.allCases {
                let resolved = Assist.resolve(masterOn: true, lockChoice: choice, profile: profile)
                if let limits = profile.lock, let variant = chosen[choice] ?? nil {
                    XCTAssertEqual(
                        resolved.lock, LockRule(variant: variant, timeLimitS: limits.timeLimitS),
                        "\(choice) with \(profile)")
                } else {
                    XCTAssertNil(resolved.lock, "\(choice) with \(profile)")
                }
                // The operator's choice reaches lock only; the other aids are the robot's share.
                XCTAssertEqual(resolved.goTo, profile.goTo, "\(choice) with \(profile)")
                XCTAssertEqual(resolved.guide, profile.guide, "\(choice) with \(profile)")
            }
        }
    }

    func testARobotThatAllowsNothingIsTheSwitchOffForLockAndTaps() {
        for choice in LockChoice.allCases {
            XCTAssertEqual(
                Assist.resolve(masterOn: true, lockChoice: choice, profile: .none),
                Assist.resolve(masterOn: false, lockChoice: choice, profile: .none), "\(choice)")
            XCTAssertEqual(Assist.resolve(masterOn: true, lockChoice: choice, profile: .none), .off, "\(choice)")

            let guideOnlyRobot = Assist.resolve(
                masterOn: true, lockChoice: choice, profile: AssistProfile(guide: guideOnly))
            XCTAssertNil(guideOnlyRobot.lock, "\(choice)")
            XCTAssertNil(guideOnlyRobot.goTo, "\(choice)")
            XCTAssertEqual(guideOnlyRobot.guide, guideOnly, "\(choice)")
        }
    }

    func testUnusableNumbersResolveToNil() {
        let all = AssistProfile(lock: lockLimits, goTo: goLimits, guide: .all)
        let usable = Assist.resolve(masterOn: true, lockChoice: .pressPress, profile: all)
        XCTAssertEqual(usable.lock, LockRule(variant: .pressPress, timeLimitS: 30))
        XCTAssertEqual(usable.goTo, goLimits)

        for bad in unusable {
            var profile = all
            profile.lock = LockLimits(timeLimitS: bad)
            for choice in LockChoice.allCases {
                let resolved = Assist.resolve(masterOn: true, lockChoice: choice, profile: profile)
                XCTAssertNil(resolved.lock, "time limit \(bad), \(choice)")
                XCTAssertEqual(resolved.goTo, goLimits, "time limit \(bad) drops lock only")
                XCTAssertEqual(resolved.guide, .all, "time limit \(bad) drops lock only")
            }
        }

        let mustBePositive: [(String, WritableKeyPath<GoToLimits, Double>)] = [
            ("travel height", \.travelHeightM), ("speed", \.speedMps), ("tolerance", \.arriveToleranceM),
            ("settle time", \.settleS), ("timeout", \.armDataTimeoutS), ("time factor", \.timeFactor),
        ]
        for (name, path) in mustBePositive {
            for bad in unusable {
                var limits = goLimits
                limits[keyPath: path] = bad
                assertGoTo(limits, isKept: false, "\(name) \(bad)")
            }
        }

        let mayBeZero: [(String, WritableKeyPath<GoToLimits, Double>)] = [
            ("correction reach", \.correctionReachM), ("allowance", \.allowanceS),
        ]
        for (name, path) in mayBeZero {
            for bad in [-1, .infinity, -.infinity, .nan] as [Double] {
                var limits = goLimits
                limits[keyPath: path] = bad
                assertGoTo(limits, isKept: false, "\(name) \(bad)")
            }
            var zero = goLimits
            zero[keyPath: path] = 0
            assertGoTo(zero, isKept: true, "\(name) 0")
        }

        var negativeCorrections = goLimits
        negativeCorrections.corrections = -1
        assertGoTo(negativeCorrections, isKept: false, "corrections -1")
        var noCorrections = goLimits
        noCorrections.corrections = 0
        assertGoTo(noCorrections, isKept: true, "corrections 0")
    }

    /// Resolves a robot that allows everything with these go-to numbers; only `goTo` may depend on them.
    private func assertGoTo(
        _ limits: GoToLimits, isKept: Bool, _ message: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let resolved = Assist.resolve(
            masterOn: true, lockChoice: .holdThenSlide,
            profile: AssistProfile(lock: lockLimits, goTo: limits, guide: .all))
        if isKept {
            XCTAssertEqual(resolved.goTo, limits, message, file: file, line: line)
        } else {
            XCTAssertNil(resolved.goTo, message, file: file, line: line)
        }
        XCTAssertEqual(
            resolved.lock, LockRule(variant: .holdThenSlide, timeLimitS: 30), "\(message) keeps lock", file: file,
            line: line)
        XCTAssertEqual(resolved.guide, .all, "\(message) keeps the guide", file: file, line: line)
    }
}
