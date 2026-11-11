#if canImport(Network)
import Foundation
import TeleopServerHost
import XCTest
@testable import TeleopServerModel

/// The socket host, through a real WebSocket client on this machine's loopback.
final class LocalTeleopServerTests: XCTestCase {
    private var server: LocalTeleopServer!

    override func setUpWithError() throws {
        server = LocalTeleopServer()
        try server.start()
    }

    override func tearDown() {
        server.stop()
        server = nil
    }

    func testItListensOnLoopbackAtAPortTheSystemPicked() {
        XCTAssertNotEqual(server.port, 0)
        XCTAssertNotEqual(server.port, 8765)
        XCTAssertEqual(server.address, "127.0.0.1:\(server.port)")
    }

    func testHelloIsAnsweredAndIdleStatesFollow() throws {
        let client = try SocketClient(port: server.port)
        client.send(#"{"v":1,"type":"hello","ts":0,"seq":1,"payload":{"client":"phone","name":"test"}}"#)
        let first = try client.next(), second = try client.next()
        XCTAssertEqual(first["type"], "welcome")
        XCTAssertEqual(second["type"], "state")
        let third = try client.next()
        XCTAssertEqual(third["type"], "state", "a state every 200 ms while the client is quiet")
    }

    func testAHoldThroughTheSocketMovesTheArmAndASocketClosedDuringItEStops() throws {
        let client = try SocketClient(port: server.port)
        client.send(#"{"v":1,"type":"hello","ts":0,"seq":1,"payload":{"client":"phone","name":"test"}}"#)
        _ = try client.next()
        let start = server.inspect { $0.world.arm }
        client.send(#"{"v":1,"type":"pose_start","ts":0,"seq":2,"payload":{"frame":"webxr_local","rate_hz":30,"gain":1,"deadband_deg":0,"smoothing":0}}"#)
        for seq in 3..<33 {
            client.send(#"{"v":1,"type":"pose_update","ts":0,"seq":\#(seq),"payload":{"p_rel_m":[0,0,0.02],"q_rel":[0,0,0,1],"gripper_delta":0}}"#)
            Thread.sleep(forTimeInterval: 1.0 / 30)
        }
        let moved = server.inspect { $0.world.arm } - start
        XCTAssertEqual(moved.z, -0.02, accuracy: 0.002, "phone z is robot −z")
        client.close()
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(server.inspect { $0.state["estop"] }, true)
    }
}

/// A plain URLSession WebSocket client that reads frames one at a time.
private final class SocketClient {
    private let task: URLSessionWebSocketTask

    init(port: UInt16) throws {
        task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)")!)
        task.resume()
    }

    func send(_ text: String) {
        task.send(.string(text)) { _ in }
    }

    func next(timeout: TimeInterval = 2) throws -> JSONValue {
        let done = DispatchSemaphore(value: 0)
        var result: Result<URLSessionWebSocketTask.Message, Error>?
        task.receive { message in
            result = message
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success, case .string(let text)? = try result?.get(),
              let value = JSONValue.parse(text) else {
            throw URLError(.timedOut)
        }
        return value
    }

    func close() { task.cancel(with: .goingAway, reason: nil) }
}
#endif
