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

    /// The tap line keeps its first sentence, then says to tap once and wait until the arm stops before the next tap:
    /// a second touch while the arm goes stops it.
    func testTheTapLineSaysToTapOnceAndWait() {
        let expected: [AppLanguage: (first: String, rest: String)] = [
            .en: (
                "Tap the view from above to send the jaws there.",
                " Tap once, then wait until the arm stops before the next tap. Any key or touch stops it."
            ),
            .zhHant: ("點一下「從上面看」的圖，夾爪就會移到那裡。", "點一下就好，等手臂停了再點下一個點。按任一鍵或觸碰都會讓它停下。"),
        ]
        for (language, words) in expected {
            L10n.language = language
            let line = L10n.string("tutorial.cue.tap_to_go")
            XCTAssertTrue(line.hasPrefix(words.first), "\(language): the first sentence unchanged: \(line)")
            XCTAssertEqual(line, words.first + words.rest, "\(language)")
        }
    }
}
