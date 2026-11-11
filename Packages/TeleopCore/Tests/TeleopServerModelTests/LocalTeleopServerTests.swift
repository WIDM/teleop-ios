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

    func testItRefusesConnectionsToThisMachinesOtherAddresses() throws {
        guard let other = otherIPv4Address() else { throw XCTSkip("this machine has no IPv4 address besides loopback") }
        XCTAssertTrue(connects(to: "127.0.0.1", port: server.port), "the check cannot see a listening port")
        XCTAssertFalse(connects(to: other, port: server.port), "the server also listens on \(other)")
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
        // A watchdog longer than any delay on a busy machine, so that the close, not the watchdog, ends the hold.
        server.stop()
        var config = ServerModelConfig.s4Simulator(stepsPerSecond: 60)
        config.holdWatchdog = 30
        server = LocalTeleopServer(config: config)
        try server.start()

        let client = try SocketClient(port: server.port)
        client.send(#"{"v":1,"type":"hello","ts":0,"seq":1,"payload":{"client":"phone","name":"test"}}"#)
        _ = try client.next()
        let start = server.inspect { $0.world.arm }
        client.send(#"{"v":1,"type":"pose_start","ts":0,"seq":2,"payload":{"frame":"webxr_local","rate_hz":30,"gain":1,"deadband_deg":0,"smoothing":0}}"#)
        for seq in 3..<33 {
            client.send(#"{"v":1,"type":"pose_update","ts":0,"seq":\#(seq),"payload":{"p_rel_m":[0,0,0.02],"q_rel":[0,0,0,1],"gripper_delta":0}}"#)
            Thread.sleep(forTimeInterval: 1.0 / 30)
        }
        let movedZ = { self.server.inspect { $0.world.arm.z } - start.z }
        XCTAssertTrue(eventually(within: 3) { abs(movedZ() + 0.02) <= 0.002 }, "the arm moved \(movedZ()) m along z; phone z is robot −z")
        client.close()
        XCTAssertTrue(eventually(within: 3) { self.server.inspect { $0.state["estop"] } == true }, "no E-stop after the close")
    }
}

/// An IPv4 address of a network interface that is up and is not loopback, such as the Wi-Fi or Ethernet one.
private func otherIPv4Address() -> String? {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let first = list else { return nil }
    defer { freeifaddrs(list) }
    for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let flags = Int32(entry.pointee.ifa_flags)
        guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
              flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
            return String(cString: host)
        }
    }
    return nil
}

/// Whether a plain TCP connection to `host` (dotted IPv4) and `port` is accepted.
private func connects(to host: String, port: UInt16) -> Bool {
    let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard socket >= 0 else { return false }
    defer { Darwin.close(socket) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return false }
    return withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
        }
    }
}

/// Polls `condition` every 10 ms until it holds or `seconds` have passed.
private func eventually(within seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() {
        if Date() >= deadline { return false }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return true
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
