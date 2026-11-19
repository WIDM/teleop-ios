#if canImport(Network)
import Foundation
import Network
import TeleopServerModel

/// The server model behind a real WebSocket on 127.0.0.1, at a port the system picks, for app and UI tests.
///
/// The model runs in real time: its clock is the time since `start()`, and its simulation steps
/// `stepsPerSecond` times a wall-clock second. The default is the nominal 60, about three and a half times
/// the lab server without cameras, so tests stay short while every protocol timer (the 750 ms watchdog, the
/// 200 ms state broadcast) keeps its real length. Everything runs on one private queue.
public final class LocalTeleopServer {
    public let config: ServerModelConfig
    /// The port the system picked; 0 until `start()` returns.
    public private(set) var port: UInt16 = 0
    /// What to type as the server address: `127.0.0.1:<port>`.
    public var address: String { "127.0.0.1:\(port)" }

    private let queue = DispatchQueue(label: "LocalTeleopServer")
    private var model: ServerModel
    private var listener: NWListener?
    private var timer: DispatchSourceTimer?
    private var sockets: [Int: NWConnection] = [:]
    private var startedAt = DispatchTime.now()

    public init(config: ServerModelConfig = .s4Simulator(stepsPerSecond: 60)) {
        self.config = config
        model = ServerModel(config: config)
    }

    deinit {
        // Not through the queue: the last reference may be dropped by a handler running on it.
        timer?.cancel()
        listener?.cancel()
        for socket in sockets.values { socket.cancel() }
    }

    /// Starts listening and returns once the port is known. The listener is normally ready within milliseconds; the
    /// generous bound is for a CI runner that stalls for many seconds at a time, where 5 s ran out.
    public func start(timeout: TimeInterval = 30) throws {
        let parameters = NWParameters.tcp
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        var failure: Error?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case .failed(let error):
                failure = error
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        startedAt = DispatchTime.now()
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + timeout) == .success, failure == nil, let port = listener.port?.rawValue
        else {
            listener.cancel()
            throw failure ?? NWError.posix(.ETIMEDOUT)
        }
        self.listener = listener
        self.port = port
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(4), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            deliver(model.advance(to: now))
        }
        timer.resume()
        self.timer = timer
    }

    /// Stops listening and drops every socket. The model is kept, so `inspect` still works.
    public func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            listener?.cancel()
            listener = nil
            for socket in sockets.values { socket.cancel() }
            sockets = [:]
        }
    }

    /// Runs `body` on the model, between messages. For checks such as "is the cube in the goal".
    public func inspect<T>(_ body: (ServerModel) -> T) -> T {
        queue.sync { body(model) }
    }

    private var now: Double { Double(DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1e9 }

    private func accept(_ connection: NWConnection) {
        let id = model.open()
        sockets[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.closed(id)
            default: break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, id: id)
    }

    private func receive(on connection: NWConnection, id: Int) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self, sockets[id] != nil else { return }
            if error != nil {
                closed(id)
                return
            }
            let metadata =
                context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            switch metadata?.opcode {
            case .text?:
                if let data, let text = String(data: data, encoding: .utf8) {
                    deliver(model.receive(text, from: id, at: now))
                }
            case .close?:
                closed(id)
                return
            default:
                break
            }
            receive(on: connection, id: id)
        }
    }

    private func closed(_ id: Int) {
        guard let socket = sockets.removeValue(forKey: id) else { return }
        socket.cancel()
        deliver(model.close(id, at: now))
    }

    private func deliver(_ outputs: [ServerOutput]) {
        for output in outputs {
            guard let socket = sockets[output.connection] else { continue }
            let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
            socket.send(
                content: Data(output.text.utf8), contentContext: context, isComplete: true, completion: .idempotent)
        }
    }
}
#endif
