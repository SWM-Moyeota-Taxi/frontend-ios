import Foundation
import MoyeotaDomain
import os
import Testing
@testable import MoyeotaData

/// 메모리 안의 웹소켓. `autoConnected` 면 CONNECT 에 곧바로 CONNECTED 로 답하는 서버처럼 군다.
final class FakeWebSocketConnection: WebSocketConnection {
    let url: String
    let negotiatedProtocol: String?
    private let inbound: AsyncThrowingStream<WebSocketFrame, any Error>
    private let inboundContinuation: AsyncThrowingStream<WebSocketFrame, any Error>.Continuation
    private let onSend: @Sendable (FakeWebSocketConnection, String) -> Void
    private let sentLock = OSAllocatedUnfairLock<[String]>(initialState: [])
    private let closesLock = OSAllocatedUnfairLock<[Int]>(initialState: [])

    init(
        url: String,
        negotiatedProtocol: String? = "v12.stomp",
        onSend: @escaping @Sendable (FakeWebSocketConnection, String) -> Void
    ) {
        self.url = url
        self.negotiatedProtocol = negotiatedProtocol
        self.onSend = onSend
        (inbound, inboundContinuation) = AsyncThrowingStream.makeStream()
    }

    var sent: [String] { sentLock.withLock { $0 } }
    var closeCodes: [Int] { closesLock.withLock { $0 } }
    var sentFrames: [StompFrame] { sent.compactMap { try? StompFrame.decode(text: $0) } }

    func push(_ text: String) {
        inboundContinuation.yield(.text(text))
    }

    func pushBinary(_ data: Data) {
        inboundContinuation.yield(.binary(data))
    }

    /// 서버 쪽에서 끊는다.
    func serverFails(_ error: any Error = IOException("서버가 끊었다")) {
        inboundContinuation.finish(throwing: error)
    }

    func sendText(_ text: String) throws {
        if !closeCodes.isEmpty { throw IOException("web socket is closed") }
        sentLock.withLock { $0.append(text) }
        onSend(self, text)
    }

    func receive() async throws -> WebSocketFrame {
        var iterator = inbound.makeAsyncIterator()
        guard let frame = try await iterator.next() else { throw IOException("끝났다") }
        return frame
    }

    func close(code: Int, reason: String?) {
        closesLock.withLock { $0.append(code) }
        inboundContinuation.finish(throwing: IOException("closed"))
    }
}

final class FakeWebSocketClient: WebSocketClient {
    /// 연결 시도마다 부른다. 던지면 연결 실패다.
    private let factory: @Sendable (Int, String) throws -> FakeWebSocketConnection
    private let state = OSAllocatedUnfairLock(initialState: (attempts: [(url: String, protocols: [String])](), connections: [FakeWebSocketConnection]()))

    init(factory: @escaping @Sendable (Int, String) throws -> FakeWebSocketConnection) {
        self.factory = factory
    }

    convenience init(respondingWith onSend: @escaping @Sendable (FakeWebSocketConnection, String) -> Void = FakeWebSocketClient.broker) {
        self.init { _, url in FakeWebSocketConnection(url: url, onSend: onSend) }
    }

    /// CONNECT 에 CONNECTED, DISCONNECT 에 RECEIPT 로 답한다.
    static let broker: @Sendable (FakeWebSocketConnection, String) -> Void = { connection, text in
        guard let frame = try? StompFrame.decode(text: text) else { return }
        switch frame.command {
        case .connect:
            connection.push("CONNECTED\nversion:1.2\nheart-beat:0,0\n\n\0")
        case .disconnect:
            connection.push("RECEIPT\nreceipt-id:\(frame.header("receipt") ?? "")\n\n\0")
        default:
            break
        }
    }

    var attempts: [(url: String, protocols: [String])] { state.withLockUnchecked { $0.attempts } }
    var connections: [FakeWebSocketConnection] { state.withLockUnchecked { $0.connections } }

    func connect(url: String, protocols: [String]) async throws -> any WebSocketConnection {
        let index = state.withLockUnchecked { state -> Int in
            state.attempts.append((url, protocols))
            return state.attempts.count - 1
        }
        let connection = try factory(index, url)
        state.withLockUnchecked { $0.connections.append(connection) }
        return connection
    }
}

private final class ReportLog: Sendable {
    private let entries = OSAllocatedUnfairLock<[(FailureSite, String)]>(initialState: [])

    var all: [(FailureSite, String)] { entries.withLock { $0 } }

    var report: @Sendable (FailureSite, any Error) throws -> Void {
        { [entries] site, error in
            let message = (error as? IllegalStateException)?.message ?? "\(error)"
            entries.withLock { $0.append((site, message)) }
        }
    }
}

/// 프레임이 소켓에 나타날 때까지 기다린다.
private func frames(
    _ connection: FakeWebSocketConnection,
    _ command: StompCommand,
    atLeast count: Int = 1
) async -> [StompFrame] {
    _ = await waitUntil { connection.sentFrames.filter { $0.command == command }.count >= count }
    return connection.sentFrames.filter { $0.command == command }
}

@Suite(.timeLimit(.minutes(1)))
struct ChatSocketTest {
    private static let baseUrl = "https://api.example.com/"
    private static let messageBody = #"{"id":11,"chatRoomId":7,"content":"안녕","type":"TEXT","createdAt":"2026-10-13T09:00:00Z"}"#

    private func makeSocket(
        _ client: FakeWebSocketClient,
        token: String? = "tok",
        baseUrl: String = ChatSocketTest.baseUrl,
        config: StompConfig = StompConfig(),
        sleep: RecordingSleep = RecordingSleep(),
        report: @escaping @Sendable (FailureSite, any Error) throws -> Void = { _, _ in }
    ) -> ChatSocket {
        ChatSocket(
            baseUrl: baseUrl,
            webSocketClient: client,
            tokens: FakeTokenHolder(accessToken: token, refreshToken: "refresh"),
            config: config,
            sleep: sleep.sleep,
            report: report
        )
    }

    private func take(_ count: Int, from stream: AsyncStream<ChatSocket.RoomSignal>) async -> [ChatSocket.RoomSignal] {
        var signals: [ChatSocket.RoomSignal] = []
        for await signal in stream {
            signals.append(signal)
            if signals.count == count { break }
        }
        return signals
    }

    private func subscriptionId(_ connection: FakeWebSocketConnection, destination: String) async -> String? {
        _ = await waitUntil { connection.sentFrames.contains { $0.command == .subscribe && $0.header("destination") == destination } }
        return connection.sentFrames.first { $0.command == .subscribe && $0.header("destination") == destination }?.header("id")
    }

    // MARK: - 프레임 계약

    /// 서버가 인증을 읽는 유일한 자리다(`StompAuthInterceptor`). 순서까지 krossbow 와 같다.
    @Test("CONNECT 프레임은 원본과 글자까지 같다")
    func connectFrame() async throws {
        let client = FakeWebSocketClient()
        let socket = makeSocket(client)

        var iterator = socket.room(chatRoomId: 7).makeAsyncIterator()
        #expect(await iterator.next() == .connected)

        let connection = try #require(client.connections.first)
        #expect(connection.sent.first == "CONNECT\naccept-version:1.2,1.1,1.0\nhost:api.example.com\nheart-beat:0,0\nAuthorization:Bearer tok\n\n\0")
    }

    @Test("서브프로토콜과 주소가 원본과 같다")
    func webSocketUrlAndProtocols() async throws {
        let client = FakeWebSocketClient()

        _ = await take(1, from: makeSocket(client).room(chatRoomId: 7))

        let attempt = try #require(client.attempts.first)
        #expect(attempt.url == "wss://api.example.com/ws-chat")
        #expect(attempt.protocols == ["v12.stomp", "v11.stomp", "v10.stomp"])
    }

    @Test("http 는 ws 로 바꾸고 host 에서 포트를 뺀다")
    func httpBaseUrl() async throws {
        let client = FakeWebSocketClient()

        _ = await take(1, from: makeSocket(client, baseUrl: "http://10.0.2.2:8080/").room(chatRoomId: 7))

        #expect(client.attempts.first?.url == "ws://10.0.2.2:8080/ws-chat")
        let connect = try #require(client.connections.first?.sentFrames.first)
        #expect(connect.header("host") == "10.0.2.2")
    }

    @Test("STOMP 1.0 으로 협상되면 host 를 싣지 않는다")
    func noHostOnStomp10() async throws {
        let client = FakeWebSocketClient { _, url in
            FakeWebSocketConnection(url: url, negotiatedProtocol: "v10.stomp") { connection, _ in
                connection.push("CONNECTED\nversion:1.0\n\n\0")
            }
        }

        _ = await take(1, from: makeSocket(client).room(chatRoomId: 7))

        let connect = try #require(client.connections.first?.sentFrames.first)
        #expect(connect.header("host") == nil)
    }

    /// `content-length:0` 까지 원본과 같다. 방 구독과 에러 통로 둘이 나간다.
    @Test("SUBSCRIBE 프레임은 방과 에러 통로 둘이다")
    func subscribeFrames() async throws {
        let client = FakeWebSocketClient()
        let socket = makeSocket(client)

        var iterator = socket.room(chatRoomId: 7).makeAsyncIterator()
        #expect(await iterator.next() == .connected)

        let connection = try #require(client.connections.first)
        let subscribes = await frames(connection, .subscribe, atLeast: 2)
        #expect(Set(subscribes.compactMap { $0.header("destination") }) == ["/sub/chat-rooms/7", "/user/queue/errors"])
        for frame in subscribes {
            let id = try #require(frame.header("id"))
            #expect(frame.headers == [
                StompHeader("id", id),
                StompHeader("destination", frame.header("destination") ?? ""),
                StompHeader("content-length", "0"),
            ])
        }
        #expect(Set(subscribes.compactMap { $0.header("id") }).count == 2)
    }

    /// 이 순서가 틀리면 호출부의 공백 조회와 소켓 수신 사이에 틈이 생겨 메시지를 잃는다.
    @Test("connected 신호는 SUBSCRIBE 가 나간 뒤에 온다")
    func connectedAfterSubscribe() async throws {
        let client = FakeWebSocketClient()
        var iterator = makeSocket(client).room(chatRoomId: 7).makeAsyncIterator()

        #expect(await iterator.next() == .connected)

        let connection = try #require(client.connections.first)
        #expect(connection.sentFrames.contains { $0.command == .subscribe && $0.header("destination") == "/sub/chat-rooms/7" })
    }

    // MARK: - 수신

    @Test("MESSAGE 본문을 메시지로 올린다")
    func receivesMessage() async throws {
        let client = FakeWebSocketClient()
        var iterator = makeSocket(client).room(chatRoomId: 7).makeAsyncIterator()
        #expect(await iterator.next() == .connected)
        let connection = try #require(client.connections.first)
        let id = try #require(await subscriptionId(connection, destination: "/sub/chat-rooms/7"))

        connection.push("MESSAGE\nsubscription:\(id)\nmessage-id:m\ndestination:/sub/chat-rooms/7\n\n\(Self.messageBody)\0")

        guard case .message(let response) = await iterator.next() else {
            Issue.record("메시지가 아니다")
            return
        }
        #expect(response.id == 11)
        #expect(response.content == "안녕")
    }

    @Test("바이너리 메시지도 읽는다")
    func receivesBinaryMessage() async throws {
        let client = FakeWebSocketClient()
        var iterator = makeSocket(client).room(chatRoomId: 7).makeAsyncIterator()
        #expect(await iterator.next() == .connected)
        let connection = try #require(client.connections.first)
        let id = try #require(await subscriptionId(connection, destination: "/sub/chat-rooms/7"))

        connection.pushBinary(Data("MESSAGE\nsubscription:\(id)\n\n\(Self.messageBody)\0".utf8))

        guard case .message(let response) = await iterator.next() else {
            Issue.record("메시지가 아니다")
            return
        }
        #expect(response.id == 11)
    }

    @Test("파싱 못 한 본문과 다른 구독의 메시지는 흘려보낸다")
    func skipsUnparsableAndForeign() async throws {
        let client = FakeWebSocketClient()
        var iterator = makeSocket(client).room(chatRoomId: 7).makeAsyncIterator()
        #expect(await iterator.next() == .connected)
        let connection = try #require(client.connections.first)
        let id = try #require(await subscriptionId(connection, destination: "/sub/chat-rooms/7"))
        let errorsId = try #require(await subscriptionId(connection, destination: "/user/queue/errors"))

        connection.push("MESSAGE\nsubscription:\(id)\n\nnot json\0")
        connection.push("MESSAGE\nsubscription:\(errorsId)\n\n\(Self.messageBody)\0")
        connection.push("MESSAGE\nsubscription:nobody\n\n\(Self.messageBody)\0")
        connection.push("MESSAGE\n\n\(Self.messageBody)\0")
        connection.push("MESSAGE\nsubscription:\(id)\n\n\(Self.messageBody)\0")

        guard case .message(let response) = await iterator.next() else {
            Issue.record("메시지가 아니다")
            return
        }
        #expect(response.id == 11)
    }

    /// STOMP 하트비트를 협상하지 않아도 서버가 보낼 수 있다. 프레임으로 파싱하려 들면 세션이 죽는다.
    @Test("개행뿐인 하트비트는 세션을 끊지 않는다")
    func heartBeatIgnored() async throws {
        let client = FakeWebSocketClient()
        var iterator = makeSocket(client).room(chatRoomId: 7).makeAsyncIterator()
        #expect(await iterator.next() == .connected)
        let connection = try #require(client.connections.first)
        let id = try #require(await subscriptionId(connection, destination: "/sub/chat-rooms/7"))

        connection.push("\n")
        connection.push("\r\n")
        connection.pushBinary(Data([0x0A]))
        connection.push("MESSAGE\nsubscription:\(id)\n\n\(Self.messageBody)\0")

        guard case .message = await iterator.next() else {
            Issue.record("메시지가 아니다")
            return
        }
        #expect(client.connections.count == 1)
    }

    // MARK: - 전송

    /// `content-type` 이 없어야 한다 — Spring 은 없는 쪽을 JSON 으로 읽는다. text/plain 을 붙이면 변환이 깨진다.
    @Test("sendMessage 는 SEND 프레임을 원본과 같게 쓴다")
    func sendMessageFrame() async throws {
        let client = FakeWebSocketClient()
        let socket = makeSocket(client)
        var iterator = socket.room(chatRoomId: 7).makeAsyncIterator()
        #expect(await iterator.next() == .connected)
        let connection = try #require(client.connections.first)

        #expect(await socket.sendMessage(chatRoomId: 7, content: "안녕 \"a\"") == true)

        let body = #"{"content":"안녕 \"a\""}"#
        let sent = connection.sent.last
        #expect(sent == "SEND\ndestination:/pub/chat-rooms/7/messages\ncontent-length:\(body.utf8.count)\n\n\(body)\0")
    }

    @Test("markAsRead 는 읽음 프레임을 쓴다")
    func markAsReadFrame() async throws {
        let client = FakeWebSocketClient()
        let socket = makeSocket(client)
        var iterator = socket.room(chatRoomId: 7).makeAsyncIterator()
        #expect(await iterator.next() == .connected)
        let connection = try #require(client.connections.first)

        #expect(await socket.markAsRead(chatRoomId: 7, readMessageId: 99) == true)

        let body = #"{"lastReadMessageId":99}"#
        #expect(connection.sent.last == "SEND\ndestination:/pub/chat-rooms/7/read\ncontent-length:\(body.utf8.count)\n\n\(body)\0")
    }

    /// 호출부가 false 를 보고 REST 로 보낸다.
    @Test("붙어 있지 않으면 전송은 false 다")
    func sendWithoutSession() async {
        let socket = makeSocket(FakeWebSocketClient())

        #expect(await socket.sendMessage(chatRoomId: 7, content: "x") == false)
        #expect(await socket.markAsRead(chatRoomId: 7, readMessageId: 1) == false)
    }

    @Test("다른 방에 붙어 있으면 전송은 false 다")
    func sendToOtherRoom() async throws {
        let client = FakeWebSocketClient()
        let socket = makeSocket(client)
        var iterator = socket.room(chatRoomId: 7).makeAsyncIterator()
        #expect(await iterator.next() == .connected)
        let connection = try #require(client.connections.first)

        #expect(await socket.sendMessage(chatRoomId: 8, content: "x") == false)
        #expect(await socket.markAsRead(chatRoomId: 8, readMessageId: 1) == false)
        #expect(connection.sentFrames.allSatisfy { $0.command != .send })
    }

    @Test("끊긴 뒤의 전송은 false 다")
    func sendAfterDisconnect() async throws {
        let client = FakeWebSocketClient()
        let socket = makeSocket(client)
        var iterator = socket.room(chatRoomId: 7).makeAsyncIterator()
        #expect(await iterator.next() == .connected)
        let connection = try #require(client.connections.first)

        connection.serverFails()
        #expect(await iterator.next() == .disconnected)

        #expect(await socket.sendMessage(chatRoomId: 7, content: "x") == false)
    }

    // MARK: - 종료

    /// UNSUBSCRIBE 두 개 → DISCONNECT → 웹소켓 1000. 이 순서가 깨끗한 종료다.
    @Test("수집을 취소하면 구독을 풀고 DISCONNECT 뒤 1000 으로 닫는다")
    func cleanShutdown() async throws {
        let client = FakeWebSocketClient()
        let socket = makeSocket(client)
        let received = OSAllocatedUnfairLock(initialState: 0)
        let collector = Task {
            for await _ in socket.room(chatRoomId: 7) { received.withLock { $0 += 1 } }
        }
        #expect(await waitUntil { received.withLock { $0 } == 1 })
        let connection = try #require(client.connections.first)
        _ = await frames(connection, .subscribe, atLeast: 2)

        collector.cancel()
        await collector.value
        #expect(await waitUntil { connection.closeCodes.isEmpty == false })

        let commands = connection.sentFrames.map(\.command)
        #expect(commands.suffix(3) == [.unsubscribe, .unsubscribe, .disconnect])
        let subscribed = Set(connection.sentFrames.filter { $0.command == .subscribe }.compactMap { $0.header("id") })
        let unsubscribed = connection.sentFrames.filter { $0.command == .unsubscribe }
        #expect(Set(unsubscribed.compactMap { $0.header("id") }) == subscribed)
        #expect(unsubscribed.allSatisfy { $0.header("content-length") == "0" })
        let disconnect = try #require(connection.sentFrames.last)
        #expect(disconnect.headers.map(\.name) == ["receipt"])
        #expect(connection.closeCodes == [1000])
        // 끊겼다는 신호를 내지 않고 다시 붙지도 않는다.
        #expect(received.withLock { $0 } == 1)
        #expect(client.attempts.count == 1)
        #expect(await socket.sendMessage(chatRoomId: 7, content: "x") == false)
    }

    /// 태스크 취소 없이 `for await` 를 빠져나오기만 해도(`break`) 스트림이 사라지며 정리돼야 한다.
    @Test("수집을 그만두기만 해도 소켓을 닫는다")
    func stopsWhenStreamIsDropped() async throws {
        let client = FakeWebSocketClient()

        _ = await take(1, from: makeSocket(client).room(chatRoomId: 7))

        let connection = try #require(client.connections.first)
        #expect(await waitUntil { connection.closeCodes == [1000] })
        #expect(client.attempts.count == 1)
    }

    /// 서버가 영수증 전에 닫는 건 흔하다. 기다리다 멈추면 안 된다.
    @Test("RECEIPT 가 안 와도 타임아웃 뒤 닫는다")
    func disconnectWithoutReceipt() async throws {
        let client = FakeWebSocketClient { connection, text in
            if text.hasPrefix("CONNECT\n") { connection.push("CONNECTED\nversion:1.2\n\n\0") }
        }
        var config = StompConfig()
        config.disconnectTimeout = .milliseconds(30)
        let socket = makeSocket(client, config: config)
        let received = OSAllocatedUnfairLock(initialState: 0)
        let collector = Task {
            for await _ in socket.room(chatRoomId: 7) { received.withLock { $0 += 1 } }
        }
        #expect(await waitUntil { received.withLock { $0 } == 1 })
        let connection = try #require(client.connections.first)

        collector.cancel()
        await collector.value

        #expect(await waitUntil { connection.closeCodes == [1000] })
        #expect(connection.sentFrames.contains { $0.command == .disconnect })
    }

    @Test("connect 중에 취소하면 소켓을 닫는다")
    func cancelDuringHandshake() async throws {
        // CONNECTED 를 보내지 않는 서버
        let client = FakeWebSocketClient { _, _ in }
        let socket = makeSocket(client)
        let collector = Task {
            for await _ in socket.room(chatRoomId: 7) {}
        }
        #expect(await waitUntil { client.connections.first?.sent.isEmpty == false })
        let connection = try #require(client.connections.first)

        collector.cancel()
        await collector.value

        #expect(await waitUntil { connection.closeCodes.isEmpty == false })
        #expect(connection.closeCodes.first == 3001)
        #expect(client.attempts.count == 1)
    }

    // MARK: - 재연결

    @Test("서버가 끊으면 끊김을 올리고 3초 뒤 다시 붙어 구독을 다시 건다")
    func reconnectsAndResubscribes() async throws {
        let client = FakeWebSocketClient()
        let sleep = RecordingSleep()
        var iterator = makeSocket(client, sleep: sleep).room(chatRoomId: 7).makeAsyncIterator()
        #expect(await iterator.next() == .connected)
        let first = try #require(client.connections.first)
        _ = await frames(first, .subscribe, atLeast: 2)

        first.serverFails()

        #expect(await iterator.next() == .disconnected)
        #expect(await iterator.next() == .connected)
        let second = try #require(client.connections.last)
        #expect(second !== first)
        let resubscribed = await frames(second, .subscribe, atLeast: 2)
        #expect(Set(resubscribed.compactMap { $0.header("destination") }) == ["/sub/chat-rooms/7", "/user/queue/errors"])
        #expect(isReconnectDelay(sleep.durations[0], baseMs: 3_000))
        // 재연결마다 CONNECT 를 다시 보낸다.
        #expect(second.sent.first?.hasPrefix("CONNECT\n") == true)
    }

    /// 재연결마다 토큰을 새로 읽는다 — 끊긴 사이 재발급됐으면 새 토큰으로 붙어야 한다.
    @Test("재연결은 그때의 토큰을 쓴다")
    func reconnectReadsCurrentToken() async throws {
        let client = FakeWebSocketClient()
        let tokens = FakeTokenHolder(accessToken: "first", refreshToken: "r")
        let socket = ChatSocket(baseUrl: Self.baseUrl, webSocketClient: client, tokens: tokens, sleep: RecordingSleep().sleep)
        var iterator = socket.room(chatRoomId: 7).makeAsyncIterator()
        #expect(await iterator.next() == .connected)

        tokens.onTokensRefreshed(accessToken: "second", refreshToken: "r")
        try #require(client.connections.first).serverFails()
        #expect(await iterator.next() == .disconnected)
        #expect(await iterator.next() == .connected)

        #expect(client.connections.map { $0.sentFrames.first?.header("Authorization") } == ["Bearer first", "Bearer second"])
    }

    /// 3초 하드 루프 방지. 예외가 없어도 실패로 센다.
    @Test("미로그인이면 연결하지 않고 간격을 늘려 기다린다")
    func notLoggedIn() async {
        let client = FakeWebSocketClient()
        let sleep = RecordingSleep()

        let signals = await take(5, from: makeSocket(client, token: nil, sleep: sleep).room(chatRoomId: 7))

        #expect(signals == Array(repeating: .disconnected, count: 5))
        #expect(client.attempts.isEmpty)
        let bases: [Int64] = [3_000, 6_000, 12_000, 30_000]
        for (duration, base) in zip(sleep.durations, bases) {
            #expect(isReconnectDelay(duration, baseMs: base), "\(duration) vs \(base)")
        }
    }

    @Test("연결 실패도 간격을 늘린다")
    func connectFailureBacksOff() async {
        let client = FakeWebSocketClient { _, _ in throw URLError(.cannotConnectToHost) }
        let sleep = RecordingSleep()

        let signals = await take(4, from: makeSocket(client, sleep: sleep).room(chatRoomId: 7))

        #expect(signals == Array(repeating: .disconnected, count: 4))
        let bases: [Int64] = [3_000, 6_000, 12_000]
        for (duration, base) in zip(sleep.durations, bases) {
            #expect(isReconnectDelay(duration, baseMs: base), "\(duration) vs \(base)")
        }
    }

    /// 긴 연결이 끊긴 것과 「붙지도 못하는 상태」를 같게 다루면 멀쩡한 서버에도 30초를 기다린다.
    @Test("구독까지 성공하면 실패 횟수가 처음으로 돌아간다")
    func connectedResetsFailures() async throws {
        let client = FakeWebSocketClient { index, url in
            if index < 3 { throw URLError(.cannotConnectToHost) }
            return FakeWebSocketConnection(url: url, onSend: FakeWebSocketClient.broker)
        }
        let sleep = RecordingSleep()
        var iterator = makeSocket(client, sleep: sleep).room(chatRoomId: 7).makeAsyncIterator()

        for _ in 0..<3 { #expect(await iterator.next() == .disconnected) }
        #expect(await iterator.next() == .connected)
        try #require(client.connections.first).serverFails()
        #expect(await iterator.next() == .disconnected)
        _ = await iterator.next()

        #expect(isReconnectDelay(sleep.durations[3], baseMs: 3_000))
    }

    /// 구독을 거부당한 사람(참여자 아님)의 경로다. 끊긴 것으로 처리하고 재연결이 맡는다.
    @Test("ERROR 프레임을 받으면 3001 로 닫고 다시 붙는다")
    func errorFrameReconnects() async throws {
        let client = FakeWebSocketClient()
        var iterator = makeSocket(client).room(chatRoomId: 7).makeAsyncIterator()
        #expect(await iterator.next() == .connected)
        let first = try #require(client.connections.first)
        _ = await frames(first, .subscribe, atLeast: 2)

        first.push("ERROR\nmessage:denied\n\n\0")

        #expect(await iterator.next() == .disconnected)
        #expect(first.closeCodes.first == 3001)
        #expect(await iterator.next() == .connected)
        #expect(client.connections.count == 2)
    }

    @Test("깨진 프레임을 받으면 끊고 다시 붙는다")
    func invalidFrameReconnects() async throws {
        let client = FakeWebSocketClient()
        var iterator = makeSocket(client).room(chatRoomId: 7).makeAsyncIterator()
        #expect(await iterator.next() == .connected)
        let first = try #require(client.connections.first)

        first.push("garbage")

        #expect(await iterator.next() == .disconnected)
        #expect(first.closeCodes.first == 3001)
    }

    // MARK: - 핸드셰이크 실패

    @Test("CONNECT 에 ERROR 로 답하면 연결 실패다")
    func errorOnConnect() async throws {
        let client = FakeWebSocketClient { connection, text in
            if text.hasPrefix("CONNECT\n") { connection.push("ERROR\nmessage:bad token\n\n\0") }
        }
        let stomp = StompClient(webSocketClient: client)

        await #expect(throws: StompConnectionException.self) {
            _ = try await stomp.connect(url: "wss://a/ws-chat", customStompConnectHeaders: [])
        }
        #expect(client.connections.first?.closeCodes.first == 3001)
    }

    @Test("첫 프레임이 CONNECTED 가 아니면 연결 실패다")
    func notConnectedFirst() async throws {
        let client = FakeWebSocketClient { connection, text in
            if text.hasPrefix("CONNECT\n") { connection.push("RECEIPT\nreceipt-id:x\n\n\0") }
        }
        let stomp = StompClient(webSocketClient: client)

        await #expect(throws: StompConnectionException.self) {
            _ = try await stomp.connect(url: "wss://a/ws-chat", customStompConnectHeaders: [])
        }
    }

    @Test("웹소켓과 STOMP 의 버전이 다르면 연결 실패다")
    func versionMismatch() async throws {
        let client = FakeWebSocketClient { connection, text in
            if text.hasPrefix("CONNECT\n") { connection.push("CONNECTED\nversion:1.1\n\n\0") }
        }
        let stomp = StompClient(webSocketClient: client)

        await #expect(throws: StompConnectionException.self) {
            _ = try await stomp.connect(url: "wss://a/ws-chat", customStompConnectHeaders: [])
        }
    }

    /// 서버가 서브프로토콜을 고르지 않은 경우는 비교할 대상이 없어 통과한다.
    @Test("서브프로토콜이 없으면 버전을 비교하지 않는다")
    func noSubprotocolSkipsVersionCheck() async throws {
        let client = FakeWebSocketClient { _, url in
            FakeWebSocketConnection(url: url, negotiatedProtocol: nil) { connection, text in
                if text.hasPrefix("CONNECT\n") { connection.push("CONNECTED\nversion:1.1\n\n\0") }
            }
        }
        let stomp = StompClient(webSocketClient: client)

        let session = try await stomp.connect(url: "wss://a/ws-chat", customStompConnectHeaders: [])
        await session.disconnect()
    }

    @Test("CONNECTED 가 안 오면 시간이 지나 실패한다")
    func connectionTimeout() async throws {
        let client = FakeWebSocketClient { _, _ in }
        var config = StompConfig()
        config.connectionTimeout = .milliseconds(50)
        let stomp = StompClient(webSocketClient: client, config: config)

        await #expect(throws: ConnectionTimeout.self) {
            _ = try await stomp.connect(url: "wss://a/ws-chat", customStompConnectHeaders: [])
        }
        #expect(client.connections.first?.closeCodes.first == 3001)
    }

    /// 기본값이 곧 계약이다 — 원본이 설정을 건드리지 않아 라이브러리 값이 그대로 앱의 값이다.
    @Test("타임아웃 기본값은 krossbow 와 같다")
    func configDefaults() {
        #expect(StompConfig().connectionTimeout == .seconds(15))
        #expect(StompConfig().disconnectTimeout == .milliseconds(200))
    }

    // MARK: - 보고

    /// `==` 비교다. `>=` 면 못 붙는 동안 30초마다 같은 보고가 쌓여 대시보드를 덮는다.
    @Test("연속 4회째에 딱 한 번 보고한다")
    func reportsOnce() async {
        let client = FakeWebSocketClient { _, _ in throw URLError(.cannotConnectToHost) }
        let log = ReportLog()

        _ = await take(7, from: makeSocket(client, report: log.report).room(chatRoomId: 7))

        #expect(log.all.count == 1)
        #expect(log.all.first?.0 == .chatSocketReconnect)
        #expect(log.all.first?.1 == "4 consecutive failures; last=NSURLErrorDomain(-1004)")
    }

    @Test("앱이 만든 예외는 타입 이름으로 보고한다")
    func reportsSwiftErrorType() async {
        let client = FakeWebSocketClient { _, _ in throw IOException("서버 응답 조각") }
        let log = ReportLog()

        _ = await take(5, from: makeSocket(client, report: log.report).room(chatRoomId: 7))

        #expect(log.all.map(\.1) == ["4 consecutive failures; last=MoyeotaDomain.IOException"])
    }

    @Test("예외가 없던 실패는 no-exception 으로 보고한다")
    func reportsNoException() async {
        let log = ReportLog()

        _ = await take(5, from: makeSocket(FakeWebSocketClient(), token: nil, report: log.report).room(chatRoomId: 7))

        #expect(log.all.map(\.1) == ["4 consecutive failures; last=no-exception"])
    }

    /// 보고에 서버 응답 조각이 섞여 나가면 안 된다 — 종류 이름만 담는다.
    @Test("보고에 예외 메시지가 들어가지 않는다")
    func reportHasNoValues() async {
        struct Leaky: Error, CustomStringConvertible {
            var description: String { "secret-token" }
        }
        let client = FakeWebSocketClient { _, _ in throw Leaky() }
        let log = ReportLog()

        _ = await take(5, from: makeSocket(client, report: log.report).room(chatRoomId: 7))

        #expect(log.all.count == 1)
        #expect(log.all.first?.1.contains("secret-token") == false)
    }

    @Test("한 번 붙으면 보고 횟수도 다시 센다")
    func reportCountResets() async throws {
        let client = FakeWebSocketClient { index, url in
            if index == 2 { return FakeWebSocketConnection(url: url, onSend: FakeWebSocketClient.broker) }
            throw URLError(.cannotConnectToHost)
        }
        let log = ReportLog()
        var iterator = makeSocket(client, report: log.report).room(chatRoomId: 7).makeAsyncIterator()

        // 실패 2 → 붙음 → 끊김 → 실패 3: 합쳐서 여섯 번이지만 연속 4회는 없다.
        for _ in 0..<2 { #expect(await iterator.next() == .disconnected) }
        #expect(await iterator.next() == .connected)
        try #require(client.connections.first).serverFails()
        for _ in 0..<3 { #expect(await iterator.next() == .disconnected) }

        #expect(log.all.isEmpty)
    }
}
