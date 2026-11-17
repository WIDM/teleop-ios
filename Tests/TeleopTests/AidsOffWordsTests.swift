import TeleopCore
import XCTest
@testable import Teleop

/// With the hands-free aids' master switch off on the real server, the operating screen says so in a line of its own:
/// in a phone mode, in every state but a stop, in both languages. The state's word and detail lines stay exactly what
/// they are without that line, in every state.
final class AidsOffWordsTests: XCTestCase {
    private var savedLanguage = L10n.language

    override func setUp() {
        super.setUp()
        savedLanguage = L10n.language
        L10n.language = .en
    }

    override func tearDown() {
        L10n.language = savedLanguage
        super.tearDown()
    }

    private static let line: [AppLanguage: String] = [
        .en: "Hands-free aids off: taps do nothing",
        .zhHant: "免持輔助已關閉：點圖不會動",
    ]

    private func aidsOff(_ name: String) throws -> OperatingDisplay {
        var display = try XCTUnwrap(OperatingFixtures.all[name], name)
        display.aidsOff = true
        return display
    }

    func testTheLineShowsInReadyGoingAndSlowLinkInAPhoneMode() throws {
        for language in [AppLanguage.en, .zhHant] {
            L10n.language = language
            for name in ["ready", "going", "slow_link"] {
                XCTAssertEqual(OperatingWords.look(try aidsOff(name)).note, Self.line[language], "\(language) \(name)")
            }
            var schemeB = try aidsOff("ready")
            schemeB.mode = .keyTurns
            XCTAssertEqual(OperatingWords.look(schemeB).note, Self.line[language], "\(language) scheme B")
        }
    }

    func testEveryPhoneModeStateButAStopShowsTheLine() throws {
        for (name, fixture) in OperatingFixtures.all where fixture.mode != .buttons && !fixture.practice {
            var display = fixture
            display.aidsOff = true
            let note = OperatingWords.look(display).note
            if case .stopped = display.state {
                XCTAssertNil(note, "\(name): a stop already says why and what to do next")
            } else {
                XCTAssertEqual(note, Self.line[.en], name)
            }
        }
    }

    func testNoLineInAStopInButtonsModeInPracticeOrWithTheSwitchOn() throws {
        for language in [AppLanguage.en, .zhHant] {
            L10n.language = language
            for name in ["stopped", "stopped_release", "stopped_unknown_server"] {
                XCTAssertNil(OperatingWords.look(try aidsOff(name)).note, "\(language) \(name)")
            }
            for name in ["buttons_ready", "buttons_moving", "buttons_stopped"] {
                XCTAssertNil(OperatingWords.look(try aidsOff(name)).note, "\(language) \(name)")
            }
            for name in ["practice_ready", "practice_stopped", "buttons_practice"] {
                XCTAssertNil(OperatingWords.look(try aidsOff(name)).note, "\(language) \(name)")
            }
            for (name, fixture) in OperatingFixtures.all where name != "ready_aids_off" {
                XCTAssertNil(OperatingWords.look(fixture).note, "\(language) \(name): the switch on")
            }
        }
    }

    func testTheWordAndDetailsAreTheSameWithAndWithoutTheLine() throws {
        for language in [AppLanguage.en, .zhHant] {
            L10n.language = language
            for (name, fixture) in OperatingFixtures.all {
                var on = fixture
                on.aidsOff = false
                var off = fixture
                off.aidsOff = true
                var look = OperatingWords.look(off)
                look.note = nil
                XCTAssertEqual(look, OperatingWords.look(on), "\(language) \(name)")
            }
        }
    }

    func testTheFixtureShowsTheLine() throws {
        let fixture = try XCTUnwrap(OperatingFixtures.all["ready_aids_off"])
        XCTAssertTrue(fixture.aidsOff)
        let look = OperatingWords.look(fixture)
        XCTAssertEqual(look.word, "Ready")
        XCTAssertEqual(look.details, [])
        XCTAssertEqual(look.note, Self.line[.en])
    }
}
