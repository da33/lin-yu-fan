import Foundation

/// 跟辦公室 Mac 上的小呆呆服務一直保持一條連線（WebSocket，經過 Tailscale）。
/// 雙方的約定寫在 mac/server.py 開頭。斷線會自己一直重連。
final class MacLink: NSObject, @unchecked Sendable {
    enum Event: Equatable {
        case connected
        case disconnected
        case heard(String)
        case say(Speech)
        case done(kind: String)
    }

    struct Speech: Equatable {
        /// answer 直接回答／ack「收到，我去做」／report 做好了的報告／error 出錯
        let kind: String
        let text: String
        let question: String
        let audio: Data
    }

    static let port = 8787

    /// 在主執行緒呼叫，照收到的順序
    var onEvent: ((Event) -> Void)?

    private let lock = NSLock()
    private let delegateQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1  // 一則一則照順序處理
        return queue
    }()
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: delegateQueue)
    private var task: URLSessionWebSocketTask?
    private var url: URL?
    private var wanted = false
    private var open = false
    private var parser = MacMessageParser()
    private var retryDelay = 2.0

    var isConnected: Bool { lock.withLock { open } }

    func connect(host: String) {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.withLock {
            wanted = !host.isEmpty
            url = URL(string: "ws://\(host):\(Self.port)")
            retryDelay = 2
        }
        delegateQueue.addOperation { self.reopen() }
    }

    func disconnect() {
        let old: URLSessionWebSocketTask? = lock.withLock {
            wanted = false
            defer { task = nil }
            return task
        }
        old?.cancel(with: .goingAway, reason: nil)
        markClosed()
    }

    func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else { return }
        send(.string(text))
    }

    func send(_ audio: Data) {
        send(.data(audio))
    }

    // MARK: - 連線

    private func send(_ message: URLSessionWebSocketTask.Message) {
        guard let task = lock.withLock({ open ? task : nil }) else { return }
        task.send(message) { [weak self] error in
            if error != nil { self?.delegateQueue.addOperation { self?.failed(task) } }
        }
    }

    /// 只在 delegateQueue 上呼叫
    private func reopen() {
        markClosed()
        let (old, target): (URLSessionWebSocketTask?, URL?) = lock.withLock {
            defer { task = nil }
            return (task, wanted ? url : nil)
        }
        old?.cancel(with: .goingAway, reason: nil)
        guard let target else { return }
        let task = session.webSocketTask(with: target)
        task.maximumMessageSize = 16 * 1024 * 1024  // 一句很長的回答，聲音可能超過預設的 1 MB
        lock.withLock {
            self.task = task
            parser = MacMessageParser()
        }
        task.resume()
        receive(on: task)
        keepAlive(task)
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                self.failed(task)
            case .success(let message):
                let event: Event? = self.lock.withLock {
                    guard task === self.task else { return nil }
                    switch message {
                    case .string(let text): return self.parser.text(text)
                    case .data(let data): return self.parser.binary(data)
                    @unknown default: return nil
                    }
                }
                if let event { self.emit(event) }
                self.receive(on: task)
            }
        }
    }

    /// 每 15 秒確認一次連線還在；手機換網路時，舊連線常常不會自己斷
    private func keepAlive(_ task: URLSessionWebSocketTask) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.lock.withLock({ task === self.task }) else { return }
            task.sendPing { error in
                if error != nil { self.delegateQueue.addOperation { self.failed(task) } }
            }
            self.keepAlive(task)
        }
    }

    private func failed(_ task: URLSessionWebSocketTask) {
        let (current, delay): (Bool, Double) = lock.withLock {
            guard task === self.task else { return (false, 0) }
            self.task = nil
            let delay = retryDelay
            retryDelay = min(retryDelay * 2, 30)
            return (true, delay)
        }
        guard current else { return }
        task.cancel(with: .goingAway, reason: nil)
        markClosed()
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.delegateQueue.addOperation { self?.reopenIfStillClosed() }
        }
    }

    private func reopenIfStillClosed() {
        let closed = lock.withLock { wanted && task == nil }
        if closed { reopen() }
    }

    private func markClosed() {
        let wasOpen = lock.withLock {
            defer { open = false }
            return open
        }
        if wasOpen { emit(.disconnected) }
    }

    private func emit(_ event: Event) {
        DispatchQueue.main.async { self.onEvent?(event) }
    }
}

extension MacLink: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol _: String?) {
        let current = lock.withLock {
            guard webSocketTask === task else { return false }
            open = true
            retryDelay = 2
            return true
        }
        if current { emit(.connected) }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        failed(webSocketTask)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let webSocketTask = task as? URLSessionWebSocketTask { failed(webSocketTask) }
    }
}

/// 把 Mac 傳來的訊息整理成事件：「say」後面緊跟的那段二進位就是它的聲音
struct MacMessageParser {
    private struct Message: Decodable {
        let type: String
        let text: String?
        let kind: String?
        let question: String?
    }

    private var pendingSay: Message?

    mutating func text(_ text: String) -> MacLink.Event? {
        guard let data = text.data(using: .utf8),
              let message = try? JSONDecoder().decode(Message.self, from: data)
        else { return nil }
        switch message.type {
        case "heard":
            return .heard(message.text ?? "")
        case "say":
            pendingSay = message
            return nil
        case "done":
            return .done(kind: message.kind ?? "answer")
        default:
            return nil
        }
    }

    mutating func binary(_ data: Data) -> MacLink.Event? {
        guard let say = pendingSay else { return nil }
        pendingSay = nil
        return .say(MacLink.Speech(kind: say.kind ?? "answer", text: say.text ?? "", question: say.question ?? "", audio: data))
    }
}
