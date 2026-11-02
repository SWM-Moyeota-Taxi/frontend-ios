import Foundation
import MoyeotaDomain
import os

/// 웹소켓 메시지 하나. 핑·퐁은 전송 계층이 처리하므로 여기까지 오지 않는다.
enum WebSocketFrame: Equatable, Sendable {
    case text(String)
    case binary(Data)
}

/// krossbow `WebSocketConnection` 의 자리. STOMP 계층을 네트워크 없이 테스트하려고 경계를 둔다.
protocol WebSocketConnection: Sendable {
    var url: String { get }
    /// 서버가 고른 서브프로토콜. 고르지 않았으면 null 이다.
    var negotiatedProtocol: String? { get }

    /// 보낼 프레임을 **큐에 넣고 바로 돌아온다**(OkHttp `WebSocket.send` 와 같다). 쓰기 실패는 `receive` 로 드러난다.
    /// 이미 닫혔으면 던진다.
    func sendText(_ text: String) throws

    /// 다음 메시지를 기다린다. 끊기면 던진다.
    func receive() async throws -> WebSocketFrame

    /// 닫는다. 두 번째 호출부터는 아무 일도 하지 않고, 기다리던 `receive` 는 던지며 풀려난다.
    func close(code: Int, reason: String?)
}

extension WebSocketConnection {
    /// krossbow `WebSocketConnection.host` — 포트를 뺀 호스트 이름.
    var host: String {
        var rest = Substring(url)
        if let scheme = rest.range(of: "://") { rest = rest[scheme.upperBound...] }
        if let slash = rest.firstIndex(of: "/") { rest = rest[..<slash] }
        if let colon = rest.firstIndex(of: ":") { rest = rest[..<colon] }
        return String(rest)
    }
}

/// krossbow `WebSocketClient` 의 자리.
protocol WebSocketClient: Sendable {
    func connect(url: String, protocols: [String]) async throws -> any WebSocketConnection
}

/// 서버가 소켓을 닫았다(Close 프레임). 정상 코드여도 호출부 입장에서는 끊김이다.
struct WebSocketClosedUnexpectedly: Throwable {
    let code: Int
    let reason: String?
    var cause: (any Error)? { nil }
    var message: String? { "the web socket was closed unexpectedly: code=\(code) reason=\(reason ?? "null")" }
}

/// `URLSessionWebSocketTask` 위의 구현. OkHttp 가 해 주던 일 둘을 여기서 맡는다.
///
/// 1. **연결 타임아웃**(`connectTimeout`). 소켓 세션은 읽기 타임아웃을 끈 상태라 스스로는 끝나지 않는다.
///    `URLSession` 은 TCP 연결과 HTTP 업그레이드를 나눠 재지 못해 업그레이드 응답까지 묶어 잰다
///    (docs/IOS-DIFFERENCES.md).
/// 2. **ping**(`pingInterval`). 끝난 소켓을 알아채는 유일한 수단이다. OkHttp `pingInterval` 처럼 주기마다 보내고,
///    **다음 주기까지 pong 이 없으면 연결 실패로 처리한다** — 조용히 죽은 소켓을 살아있다고 믿으면
///    `ChatSocket.live` 가 남아 전송이 REST 로 떨어지지 않는다.
final class URLSessionWebSocketClient: WebSocketClient {
    private let session: URLSession
    private let connectTimeout: Duration
    private let pingInterval: Duration

    init(
        session: URLSession,
        connectTimeout: Duration = .seconds(NetworkModule.SOCKET_CONNECT_TIMEOUT_SECONDS),
        pingInterval: Duration = .seconds(NetworkModule.SOCKET_PING_INTERVAL_SECONDS)
    ) {
        self.session = session
        self.connectTimeout = connectTimeout
        self.pingInterval = pingInterval
    }

    func connect(url: String, protocols: [String]) async throws -> any WebSocketConnection {
        guard let target = URL(string: url) else {
            throw IllegalArgumentException("잘못된 웹소켓 주소: \(url)")
        }
        let task = session.webSocketTask(with: target, protocols: protocols)
        let delegate = OpenDelegate()
        task.delegate = delegate

        let timeout = connectTimeout
        let timer = Task {
            try await Task.sleep(for: timeout)
            delegate.fail(IOException("web socket connect timed out after \(timeout)"))
            task.cancel()
        }
        defer { timer.cancel() }

        let negotiated: String?
        do {
            negotiated = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    delegate.install(continuation)
                    task.resume()
                }
            } onCancel: {
                task.cancel()
            }
        } catch {
            task.cancel()
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
        return URLSessionWebSocketConnection(task: task, url: url, negotiatedProtocol: negotiated, pingInterval: pingInterval)
    }

    /// 업그레이드가 끝나는 순간을 알려 준다. `task.delegate` 는 태스크가 끝날 때까지 태스크가 붙들고 있다.
    private final class OpenDelegate: NSObject, URLSessionWebSocketDelegate, Sendable {
        private let waiter = OSAllocatedUnfairLock<CheckedContinuation<String?, any Error>?>(initialState: nil)

        func install(_ continuation: CheckedContinuation<String?, any Error>) {
            waiter.withLock { $0 = continuation }
        }

        func fail(_ error: any Error) {
            take()?.resume(throwing: error)
        }

        func urlSession(
            _ session: URLSession,
            webSocketTask: URLSessionWebSocketTask,
            didOpenWithProtocol negotiatedProtocol: String?
        ) {
            take()?.resume(returning: negotiatedProtocol)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            take()?.resume(throwing: error ?? IOException("web socket closed before it opened"))
        }

        private func take() -> CheckedContinuation<String?, any Error>? {
            waiter.withLock { current in
                defer { current = nil }
                return current
            }
        }
    }
}

private final class URLSessionWebSocketConnection: WebSocketConnection {
    private struct State: Sendable {
        var isClosed = false
        var failure: (any Error)?
        var awaitingPong = false
        var pingLoop: Task<Void, Never>?
    }

    let url: String
    let negotiatedProtocol: String?
    private let task: URLSessionWebSocketTask
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(task: URLSessionWebSocketTask, url: String, negotiatedProtocol: String?, pingInterval: Duration) {
        self.task = task
        self.url = url
        self.negotiatedProtocol = negotiatedProtocol
        startPinging(every: pingInterval)
    }

    deinit {
        // 이미 닫은 소켓을 여기서 다시 취소하면 아직 나가지 못한 Close 프레임까지 버려진다.
        let isClosed = state.withLock { state -> Bool in
            state.pingLoop?.cancel()
            return state.isClosed
        }
        if !isClosed { task.cancel() }
    }

    func sendText(_ text: String) throws {
        if let closedError = state.withLock({ $0.isClosed ? ($0.failure ?? IOException("web socket is closed")) : nil }) {
            throw closedError
        }
        task.send(.string(text)) { [weak self] error in
            if let error { self?.fail(error) }
        }
    }

    func receive() async throws -> WebSocketFrame {
        do {
            switch try await task.receive() {
            case .string(let text): return .text(text)
            case .data(let data): return .binary(data)
            @unknown default: throw IOException("모르는 웹소켓 메시지 종류")
            }
        } catch {
            if let failure = state.withLock({ $0.failure }) { throw failure }
            if task.closeCode != .invalid {
                let reason = task.closeReason.map { String(decoding: $0, as: UTF8.self) }
                throw WebSocketClosedUnexpectedly(code: task.closeCode.rawValue, reason: reason)
            }
            throw error
        }
    }

    func close(code: Int, reason: String?) {
        let isFirst = state.withLock { state -> Bool in
            state.pingLoop?.cancel()
            defer { state.isClosed = true }
            return !state.isClosed
        }
        guard isFirst else { return }
        // 3001 처럼 등록 안 된 코드도 원시값 그대로 나간다. 혹시 못 만들면 내부 오류로 닫는다.
        let closeCode = URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .internalServerError
        task.cancel(with: closeCode, reason: reason.map { Data($0.utf8) })
    }

    /// OkHttp `RealWebSocket.writePingFrame`: 앞 ping 의 pong 이 아직이면 그 자리에서 연결 실패다.
    private func startPinging(every interval: Duration) {
        let loop = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard let self, sendPing(interval: interval) else { return }
            }
        }
        state.withLock { $0.pingLoop = loop }
    }

    private func sendPing(interval: Duration) -> Bool {
        let missedPong = state.withLock { state -> Bool in
            defer { state.awaitingPong = true }
            return state.awaitingPong
        }
        if missedPong {
            fail(IOException("sent ping but didn't receive pong within \(interval)"))
            return false
        }
        task.sendPing { [weak self] error in
            if let error {
                self?.fail(error)
            } else {
                self?.state.withLock { $0.awaitingPong = false }
            }
        }
        return true
    }

    private func fail(_ error: any Error) {
        let isFirst = state.withLock { state -> Bool in
            state.pingLoop?.cancel()
            guard !state.isClosed else { return false }
            state.isClosed = true
            state.failure = error
            return true
        }
        if isFirst { task.cancel() }
    }
}
