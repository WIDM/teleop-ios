import TeleopCore
import XCTest
@testable import Teleop

final class SlowLinkLetGoTests: XCTestCase {
    func testTheSecondSlowSampleStopsAHeldGripAndSaysWhyOnce() {
        let model = connectedModel(assistOn: true)
        model.send(.gripperStart(.closed))
        XCTAssertEqual(model.session.state.gripperMoving, .closed)
        let mark = model.cueLog.count
        model.send(.linkLatency(ms: 450))
        XCTAssertEqual(model.session.state.gripperMoving, .closed)
        XCTAssertFalse(model.cueLog.dropFirst(mark).contains { $0.event == .letGo(.slowLink) })

        model.send(.linkLatency(ms: 450))
        XCTAssertNil(model.session.state.gripperMoving)
        let endings = model.cueLog.dropFirst(mark).filter { $0.event == .letGo(.slowLink) }
        XCTAssertEqual(endings.map(\.speech), [[.slowLink]])
        model.send(.gripperStart(.closed))
        XCTAssertEqual(model.cueLog.last?.event, .refused(.slowLink))
        XCTAssertEqual(model.cueLog.last?.speech, [])
    }

    func testWithAidsOffTheHoldStillStopsWithoutTheVoiceCue() {
        let model = connectedModel(assistOn: false)
        model.send(.gripperStart(.closed))
        XCTAssertEqual(model.session.state.gripperMoving, .closed)
        model.send(.linkLatency(ms: 450))
        model.send(.linkLatency(ms: 450))
        XCTAssertNil(model.session.state.gripperMoving)
        XCTAssertFalse(model.cueLog.contains { $0.event == .letGo(.slowLink) })
        XCTAssertTrue(model.operating.aidsOff)
        XCTAssertFalse(connectedModel(assistOn: true).operating.aidsOff)
        XCTAssertFalse(AppModel(start: .p4, liveLink: false, assistOn: false).operating.aidsOff)
    }

    func testASlowLinkDoesNotAnnounceAReleasedHold() {
        let model = connectedModel(assistOn: true)
        model.send(.gripperStart(.closed))
        XCTAssertEqual(model.session.state.gripperMoving, .closed)
        model.send(.linkLatency(ms: 450))
        model.send(.gripperEnd)
        model.send(.linkLatency(ms: 450))
        XCTAssertTrue(model.session.state.commandsBlocked)
        XCTAssertFalse(model.cueLog.contains { $0.event == .letGo(.slowLink) })
    }

    private func connectedModel(assistOn: Bool) -> AppModel {
        let model = AppModel(start: .p4, speech: NoSpeech(), liveLink: true, assistOn: assistOn)
        model.session.state.markConnected()
        return model
    }
}
