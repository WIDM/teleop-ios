import Foundation

/// One text WebSocket. Callbacks arrive on the main queue.
protocol LinkTransport: AnyObject {
    var onText: ((String) -> Void)? { get set }
    /// Called once, when the socket fails or closes from the far side. Not called after `close()`.
    var onClose: (() -> Void)? { get set }
    func open()
    func send(_ text: String)
    func close()
}

final class WebSocketTransport: NSObject, LinkTransport, URLSessionWebSocketDelegate {
    var onText: ((String) -> Void)?
    var onClose: (() -> Void)?

    private let url: URL
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var closed = false

    init(url: URL) {
        self.url = url
    }

    func open() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        self.session = session
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        receiveNext()
    }

    func send(_ text: String) {
        let message = URLSessionWebSocketTask.Message.string(text)
        task?.send(message) { [weak self] error in
            guard error != nil else { return }
            DispatchQueue.main.async { self?.finish() }
        }
    }

    func close() {
        closed = true
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        task = nil
        session = nil
    }

    private func receiveNext() {
        task?.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, !self.closed else { return }
                switch result {
                case .success(.string(let text)):
                    self.onText?(text)
                    self.receiveNext()
                case .success:
                    self.receiveNext()
                case .failure:
                    self.finish()
                }
            }
        }
    }

    private func finish() {
        guard !closed else { return }
        close()
        onClose?()
    }

    func urlSession(
        _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?
    ) {
        finish()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish()
    }
}
