import XCTest
@testable import Teleop

/// The tutorial's line about the guide has two forms: what the on-target cue means, and the same words followed by the
/// sentence about the guide's arrows, shown where the guide draws them. The longer one begins with the shorter one word
/// for word, in both languages, so an edit to one cannot leave the other saying something else.
final class TutorialLinesTests: XCTestCase {
    private var savedLanguage = L10n.language

    override func setUp() {
        super.setUp()
        savedLanguage = L10n.language
    }

    override func tearDown() {
        L10n.language = savedLanguage
        super.tearDown()
    }

    func testTheLineWithTheArrowsBeginsWithTheOnTargetLine() {
        for language in [AppLanguage.en, .zhHant] {
            L10n.language = language
            let onTarget = L10n.string("tutorial.cue.on_target")
            let withArrows = L10n.string("tutorial.cue.on_target_arrows")
            XCTAssertNotEqual(onTarget, "tutorial.cue.on_target", "\(language): the on-target line has words")
            XCTAssertNotEqual(withArrows, "tutorial.cue.on_target_arrows", "\(language): the arrows line has words")
            XCTAssertTrue(
                withArrows.hasPrefix(onTarget), "\(language): \"\(withArrows)\" does not begin with \"\(onTarget)\"")
            XCTAssertGreaterThan(withArrows.count, onTarget.count, "\(language): the sentence about the arrows follows")
        }
    }
}
