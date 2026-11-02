import Foundation
import MoyeotaDomain
import os

/// krossbow 기본 `StompConfig` 중 이 앱이 타는 값. 원본은 설정을 건드리지 않으므로 전부 라이브러리 기본값이다:
/// `autoContentLength = true`, `autoReceipt = false`, `connectWithStompCommand = false`,
/// `gracefulDisconnect = true`, `failOnStompVersionMismatch = true`, `heartBeat = (0, 0)`.
///
/// **STOMP 하트비트는 없다.** CONNECT 에 `heart-beat:0,0` 을 싣고 서버가 뭐라 답하든 협상 결과는 0 이다 —
/// 끊김은 웹소켓 ping(`URLSessionWebSocketClient`)이 잡는다. 서버가 그래도 보내는 `\n` 은 무시한다.
struct StompConfig: Sendable {
    /// 웹소켓 연결부터 CONNECTED 까지 전부
    var connectionTimeout: Duration = .seconds(15)
    /// DISCONNECT 의 RECEIPT 를 기다리는 시간. 짧은 이유는 그쪽이 안 와도 어차피 닫기 때문이다.
    var disconnectTimeout: Duration = .milliseconds(200)
}

/// 원본 값: `StompVersion.preferredOrder`.
private let STOMP_VERSIONS: [(header: String, subprotocol: String)] = [
    ("1.2", "v12.stomp"),
    ("1.1", "v11.stomp"),
    ("1.0", "v10.stomp"),
]

struct ConnectionTimeout: Throwable {
    let host: String
    var cause: (any Error)? { nil }
    var message: String? { "Connection timed out for host \(host)" }
}

struct StompConnectionException: Throwable {
    let host: String
    let cause: (any Error)?
    var message: String? { "Couldn't connect to STOMP server at \(host)" }
}

struct StompErrorFrameReceived: Throwable {
    let frame: StompFrame
    var cause: (any Error)? { nil }
    var message: String? { "STOMP ERROR frame received: \(frame.header("message") ?? "null")" }
}

struct SessionDisconnectedException: Throwable {
    var cause: (any Error)? { nil }
    var message: String? { "STOMP session is disconnected" }
}

/// krossbow `StompClient` 의 자리 — 웹소켓을 열고 CONNECT → CONNECTED 까지 끝낸 세션을 돌려준다.
final class StompClient: Sendable {
    private let webSocketClient: any WebSocketClient
    private let config: StompConfig

    init(webSocketClient: any WebSocketClient, config: StompConfig = StompConfig()) {
        self.webSocketClient = webSocketClient
        self.config = config
    }

    func connect(url: String, customStompConnectHeaders: [StompHeader]) async throws -> StompSession {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: config.connectionTimeout)

        // 서브프로토콜을 내밀어야 Spring 이 그에 맞는 STOMP 핸들러로 받는다.
        let connection = try await webSocketClient.connect(url: url, protocols: STOMP_VERSIONS.map(\.subprotocol))

        let host = connection.host
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let watchdog = Task {
            try await Task.sleep(until: deadline, clock: clock)
            timedOut.withLock { $0 = true }
            connection.close(code: CLOSE_CODE_FAILURE, reason: "connection timed out")
        }
        defer { watchdog.cancel() }

        do {
            return try await withTaskCancellationHandler {
                try connection.sendText(connectFrame(connection, customHeaders: customStompConnectHeaders).encodeToText())
                let connected = try await awaitConnectedFrame(connection)
                try checkVersionsMatch(connection, connected)
                return StompSession(connection: connection, config: config)
            } onCancel: {
                connection.close(code: CLOSE_CODE_FAILURE, reason: "cancelled")
            }
        } catch {
            connection.close(code: CLOSE_CODE_FAILURE, reason: closeReason(for: error))
            if Task.isCancelled { throw CancellationError() }
            if timedOut.withLock({ $0 }) { throw ConnectionTimeout(host: host) }
            throw StompConnectionException(host: host, cause: error)
        }
    }

    /// `CONNECT` 헤더 — 순서까지 원본과 같다: accept-version, host, heart-beat, 호출부 헤더(Authorization).
    /// `host` 는 STOMP 1.0 으로 협상됐을 때만 빠진다.
    private func connectFrame(_ connection: any WebSocketConnection, customHeaders: [StompHeader]) -> StompFrame {
        var headers = [StompHeader("accept-version", STOMP_VERSIONS.map(\.header).joined(separator: ","))]
        if connection.negotiatedProtocol != "v10.stomp" {
            headers.append(StompHeader("host", connection.host))
        }
        headers.append(StompHeader("heart-beat", "0,0"))
        headers.append(contentsOf: customHeaders)
        return StompFrame(command: .connect, headers: headers)
    }

    /// 첫 프레임이 CONNECTED 여야 한다. 원본도 건너뛰지 않는다(ERROR 면 그 내용으로 실패한다).
    private func awaitConnectedFrame(_ connection: any WebSocketConnection) async throws -> StompFrame {
        let event = try decodeStompEvent(try await connection.receive())
        guard case .frame(let frame) = event, frame.command == .connected else {
            throw InvalidStompFrameException("Expected CONNECTED frame")
        }
        return frame
    }

    private func checkVersionsMatch(_ connection: any WebSocketConnection, _ connected: StompFrame) throws {
        guard let version = connected.header("version"),
              let actual = STOMP_VERSIONS.first(where: { $0.header == version }) else {
            throw IllegalStateException("Unknown STOMP version in CONNECTED frame: \(connected.header("version") ?? "null")")
        }
        guard let negotiated = connection.negotiatedProtocol,
              let expected = STOMP_VERSIONS.first(where: { $0.subprotocol == negotiated }) else {
            return
        }
        if expected.header != actual.header {
            throw IllegalStateException(
                "negotiated STOMP version mismatch: \(expected.header) at web socket level (subprotocol '\(negotiated)'), \(actual.header) at STOMP level"
            )
        }
    }
}

/// krossbow `closeCodeFor`: 정상 종료는 1000, 그 밖의 실패는 앱 전용 3001.
private let CLOSE_CODE_NORMAL = 1000
private let CLOSE_CODE_FAILURE = 3001

/// 원본처럼 예외 메시지를 이유로 싣는다.
private func closeReason(for error: any Error) -> String {
    truncateToCloseFrameReasonLength((error as? any Throwable)?.message ?? error.localizedDescription)
}

/// 웹소켓 Close 프레임의 이유는 UTF-8 로 123바이트까지다. 넘기면 `URLSession` 이 Close 프레임을 아예 보내지 않는다.
private func truncateToCloseFrameReasonLength(_ reason: String) -> String {
    let limit = 123
    if reason.utf8.count <= limit { return reason }
    var truncated = ""
    var size = 0
    for character in reason {
        size += character.utf8.count
        if size > limit { break }
        truncated.append(character)
    }
    return truncated
}

private enum StompEvent {
    case frame(StompFrame)
    case heartBeat
}

/// krossbow `decodeToStompEvent`: 개행만 있는 메시지는 하트비트, ERROR 프레임은 예외다.
private func decodeStompEvent(_ message: WebSocketFrame) throws -> StompEvent {
    let bytes: [UInt8]
    switch message {
    case .text(let text): bytes = Array(text.utf8)
    case .binary(let data): bytes = Array(data)
    }
    if bytes == [0x0A] || bytes == [0x0D, 0x0A] { return .heartBeat }
    let frame = try StompFrame.decode(bytes: bytes)
    if frame.command == .error { throw StompErrorFrameReceived(frame: frame) }
    return .frame(frame)
}

/// krossbow `BaseStompSession` 의 자리 — 붙어 있는 세션 하나.
///
/// 읽기 루프가 프레임을 구독별로 나눠 준다. 소켓이 끊기거나 ERROR·깨진 프레임을 받으면 **모든 구독이 그 오류로
/// 끝난다** — 호출부(`ChatSocket.room`)의 재연결이 그 신호를 받는다.
final class StompSession: Sendable {
    private struct State: Sendable {
        var subscriptions: [String: AsyncThrowingStream<String, any Error>.Continuation] = [:]
        var receiptWaiters: [String: CheckedContinuation<Void, Never>] = [:]
        var isShutDown = false
    }

    private let connection: any WebSocketConnection
    private let config: StompConfig
    private let state = OSAllocatedUnfairLock(initialState: State())

    fileprivate init(connection: any WebSocketConnection, config: StompConfig) {
        self.connection = connection
        self.config = config
        Task { [self] in await readLoop() }
    }

    /// 구독을 걸고 그 본문 흐름을 돌려준다. **돌아온 시점에 SUBSCRIBE 는 이미 나갔다**(큐에 들어갔다).
    ///
    /// 구독을 먼저 등록한 뒤 프레임을 보내므로 그 사이에 온 MESSAGE 를 놓치지 않는다. 흐름이 취소되면 세션이 살아
    /// 있을 때만 UNSUBSCRIBE 를 보낸다(세션이 끝나서 흐름이 끝난 경우엔 보낼 곳이 없다).
    func subscribeText(destination: String) throws -> AsyncThrowingStream<String, any Error> {
        let id = UUID().uuidString.lowercased()
        let (stream, continuation) = AsyncThrowingStream<String, any Error>.makeStream()
        continuation.onTermination = { [weak self] termination in
            if case .cancelled = termination { self?.unsubscribe(id: id) }
        }
        let accepted = state.withLock { state -> Bool in
            guard !state.isShutDown else { return false }
            state.subscriptions[id] = continuation
            return true
        }
        guard accepted else { throw SessionDisconnectedException() }
        do {
            try send(StompFrame(command: .subscribe, headers: withContentLength(
                [StompHeader("id", id), StompHeader("destination", destination)], body: nil
            )))
        } catch {
            state.withLock { $0.subscriptions[id] = nil }
            continuation.finish()
            throw error
        }
        return stream
    }

    /// krossbow `sendText`: `content-type` 없이 `content-length` 만 붙는다 — 서버(Spring)가 없는 쪽을 JSON 으로 읽는다.
    func sendText(destination: String, body: String) throws {
        let bytes = Data(body.utf8)
        try send(StompFrame(
            command: .send,
            headers: withContentLength([StompHeader("destination", destination)], body: bytes),
            body: bytes.isEmpty ? nil : bytes
        ))
    }

    /// 정중히 닫는다: DISCONNECT → RECEIPT 대기(`disconnectTimeout`) → 웹소켓 1000. 남은 구독은 정상 종료된다.
    /// 영수증이 안 와도 실패가 아니다 — 서버가 답 전에 닫는 일은 흔하다.
    func disconnect() async {
        let receipt = UUID().uuidString.lowercased()
        let frame = StompFrame(command: .disconnect, headers: [StompHeader("receipt", receipt)])
        let timeout = config.disconnectTimeout

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let accepted = state.withLock { state -> Bool in
                guard !state.isShutDown else { return false }
                state.receiptWaiters[receipt] = continuation
                return true
            }
            guard accepted else {
                continuation.resume()
                return
            }
            do {
                try send(frame)
            } catch {
                resumeReceiptWaiter(receipt)
                return
            }
            Task { [self] in
                try? await Task.sleep(for: timeout)
                resumeReceiptWaiter(receipt)
            }
        }

        // 소켓보다 먼저 세션을 내린다 — 읽기 루프가 닫힘을 먼저 보고 남은 구독을 오류로 끝내지 않게.
        shutDown(failure: nil)
        connection.close(code: CLOSE_CODE_NORMAL, reason: nil)
    }

    private func unsubscribe(id: String) {
        let isActive = state.withLock { state -> Bool in
            state.subscriptions[id] = nil
            return !state.isShutDown
        }
        guard isActive else { return }
        try? send(StompFrame(command: .unsubscribe, headers: withContentLength([StompHeader("id", id)], body: nil)))
    }

    /// `autoContentLength` — 본문이 없어도 `content-length:0` 이 붙는다. CONNECT·DISCONNECT 는 이 길을 안 탄다.
    private func withContentLength(_ headers: [StompHeader], body: Data?) -> [StompHeader] {
        headers + [StompHeader("content-length", String(body?.count ?? 0))]
    }

    private func send(_ frame: StompFrame) throws {
        try connection.sendText(frame.encodeToText())
    }

    private func readLoop() async {
        do {
            while true {
                guard case .frame(let frame) = try decodeStompEvent(try await connection.receive()) else { continue }
                dispatch(frame)
            }
        } catch {
            // `disconnect` 가 닫아서 깨어난 경우엔 할 일이 없다 — 이미 1000 으로 닫혔다.
            guard !state.withLock({ $0.isShutDown }) else { return }
            connection.close(code: CLOSE_CODE_FAILURE, reason: closeReason(for: error))
            shutDown(failure: error)
        }
    }

    private func dispatch(_ frame: StompFrame) {
        switch frame.command {
        case .message:
            guard let id = frame.header("subscription") else { return }
            let continuation = state.withLock { $0.subscriptions[id] }
            continuation?.yield(frame.bodyAsText)
        case .receipt:
            if let id = frame.header("receipt-id") { resumeReceiptWaiter(id) }
        default:
            break
        }
    }

    private func resumeReceiptWaiter(_ receipt: String) {
        let waiter = state.withLock { $0.receiptWaiters.removeValue(forKey: receipt) }
        waiter?.resume()
    }

    private func shutDown(failure: (any Error)?) {
        let (subscriptions, waiters) = state.withLock { state in
            let taken = (state.subscriptions, state.receiptWaiters)
            state.isShutDown = true
            state.subscriptions = [:]
            state.receiptWaiters = [:]
            return taken
        }
        for continuation in subscriptions.values {
            continuation.finish(throwing: failure)
        }
        for waiter in waiters.values {
            waiter.resume()
        }
    }
}
