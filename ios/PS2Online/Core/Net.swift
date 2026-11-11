import Foundation

/// اتصال WebSocket بسيرفر Cloudflare (نفس السيرفر الذي يستخدمه برنامج الكمبيوتر)
final class Net: NSObject, URLSessionWebSocketDelegate {
    var onMessage: ((URLSessionWebSocketTask.Message) -> Void)?
    var onClose: (() -> Void)?

    private var session: URLSession!
    private var task: URLSessionWebSocketTask!
    private var closed = false

    init(url: URL) {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        task = session.webSocketTask(with: url)
        task.maximumMessageSize = 32 * 1024 * 1024
        task.resume()
        receive()
    }

    private func receive() {
        task.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, !self.closed else { return }
                switch result {
                case .success(let msg):
                    self.onMessage?(msg)
                    self.receive()
                case .failure:
                    self.finish()
                }
            }
        }
    }

    func send(_ data: Data) {
        guard !closed else { return }
        task.send(.data(data)) { _ in }
    }

    func sendText(_ text: String) {
        guard !closed else { return }
        task.send(.string(text)) { _ in }
    }

    func close() {
        guard !closed else { return }
        closed = true
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        onClose?()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        finish()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish()
    }
}
