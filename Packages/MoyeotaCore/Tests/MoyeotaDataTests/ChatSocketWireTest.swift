import Foundation
import MoyeotaDomain
import Network
import os
import Testing
@testable import MoyeotaData

/// 진짜 `URLSessionWebSocketTask` 를 진짜 웹소켓 서버(127.0.0.1)에 붙인다. 가짜 소켓은 업그레이드·서브프로토콜·
/// Close 코드·ping 같은 **플랫폼이 실제로 하는 일**을 보여 주지 못한다.
@Suite(.timeLimit(.minutes(1)))
struct ChatSocketWireTest {
    private static let messageBody = #"{"id":11,"chatRoomId":7,"content":"안녕","type":"TEXT","createdAt":"2026-10-13T09:00:00Z"}"#

    /// CONNECT·DISCONNECT 에 답하는 최소한의 브로커.
    private static let broker: @Sendable (LoopbackWebSocketServer.Peer, String) -> Void = { peer, text in
        guard let frame = try? StompFrame.decode(text: text) else { return }
        switch frame.command {
        case .connect:
            peer.send("CONNECTED\nversion:1.2\nheart-beat:0,0\n\n\0")
        case .disconnect:
            peer.send("RECEIPT\nreceipt-id:\(frame.header("receipt") ?? "")\n\n\0")
        default:
            break
        }
    }

    private func frames(_ peer: LoopbackWebSocketServer.Peer) -> [StompFrame] {
        peer.texts.compactMap { try? StompFrame.decode(text: $0) }
    }

    private func subscriptionId(_ peer: LoopbackWebSocketServer.Peer, destination: String) async -> String? {
        let find: @Sendable () -> String? = {
            frames(peer).first { $0.command == .subscribe && $0.header("destination") == destination }?.header("id")
        }
        _ = await waitUntil { find() != nil }
        return find()
    }

    private func makeSocket(
        baseUrl: String,
        token: String? = "wire.access",
        connectTimeout: Duration = .seconds(10),
        pingInterval: Duration = .seconds(20),
        sleep: RecordingSleep = RecordingSleep()
    ) throws -> ChatSocket {
        // 운영과 같은 소켓 세션으로 붙는다(읽기 타임아웃을 끈 것까지 같다).
        let apis = try NetworkModule.create(
            baseUrl: baseUrl,
            debugLogging: false,
            tokenHolder: FakeTokenHolder(accessToken: token, refreshToken: "r")
        )
        return ChatSocket(
            baseUrl: baseUrl,
            webSocketClient: URLSessionWebSocketClient(session: apis.socketClient, connectTimeout: connectTimeout, pingInterval: pingInterval),
            tokens: FakeTokenHolder(accessToken: token, refreshToken: "r"),
            sleep: sleep.sleep
        )
    }

    @Test("업그레이드와 CONNECT 가 소켓에 원본과 같게 나간다")
    func handshakeOnWire() async throws {
        let server = try LoopbackWebSocketServer(onText: Self.broker)
        let baseUrl = try await server.start()
        defer { server.stop() }

        var iterator = try makeSocket(baseUrl: baseUrl).room(chatRoomId: 7).makeAsyncIterator()
        #expect(await iterator.next() == .connected)

        // `URLSession` 은 `a, b` 로 잇는다(OkHttp 는 `a,b`). HTTP 목록으로는 같은 값이라 공백은 보지 않는다.
        let offered = server.offeredProtocols.first?.map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(offered == ["v12.stomp", "v11.stomp", "v10.stomp"])
        // HTTP 헤더가 아니라 프레임 헤더다 — 서버가 그것만 읽는다.
        #expect(server.upgradeHeaderNames.first?.contains("authorization") == false)
        let peer = try #require(server.peers.first)
        #expect(peer.texts.first == "CONNECT\naccept-version:1.2,1.1,1.0\nhost:127.0.0.1\nheart-beat:0,0\nAuthorization:Bearer wire.access\n\n\0")
    }

    @Test("구독, 수신, 전송이 소켓을 왕복한다")
    func roundTripOnWire() async throws {
        let server = try LoopbackWebSocketServer(onText: Self.broker)
        let baseUrl = try await server.start()
        defer { server.stop() }
        let socket = try makeSocket(baseUrl: baseUrl)

        var iterator = socket.room(chatRoomId: 7).makeAsyncIterator()
        #expect(await iterator.next() == .connected)
        let peer = try #require(server.peers.first)
        let id = try #require(await subscriptionId(peer, destination: "/sub/chat-rooms/7"))
        #expect(await subscriptionId(peer, destination: "/user/queue/errors") != nil)

        let bytes = Self.messageBody.utf8.count
        peer.send("MESSAGE\nsubscription:\(id)\nmessage-id:m\ndestination:/sub/chat-rooms/7\ncontent-length:\(bytes)\n\n\(Self.messageBody)\0")
        guard case .message(let response) = await iterator.next() else {
            Issue.record("메시지가 아니다")
            return
        }
        #expect(response.content == "안녕")

        #expect(await socket.sendMessage(chatRoomId: 7, content: "한글") == true)
        let body = #"{"content":"한글"}"#
        let expected = "SEND\ndestination:/pub/chat-rooms/7/messages\ncontent-length:\(body.utf8.count)\n\n\(body)\0"
        #expect(await waitUntil { peer.texts.contains(expected) })
    }

    @Test("수집을 취소하면 소켓에 UNSUBSCRIBE, DISCONNECT, Close 1000 이 나간다")
    func cleanShutdownOnWire() async throws {
        let server = try LoopbackWebSocketServer(onText: Self.broker)
        let baseUrl = try await server.start()
        defer { server.stop() }
        let socket = try makeSocket(baseUrl: baseUrl)
        let received = OSAllocatedUnfairLock(initialState: 0)
        let collector = Task {
            for await _ in socket.room(chatRoomId: 7) { received.withLock { $0 += 1 } }
        }
        #expect(await waitUntil { received.withLock { $0 } == 1 })
        let peer = try #require(server.peers.first)
        #expect(await subscriptionId(peer, destination: "/user/queue/errors") != nil)

        collector.cancel()
        await collector.value

        #expect(await waitUntil { peer.received.contains(.close(code: 1000)) }, "\(peer.received)")
        let commands = frames(peer).map(\.command)
        #expect(commands.suffix(3) == [.unsubscribe, .unsubscribe, .disconnect])
        #expect(server.peers.count == 1)
    }

    @Test("서버가 Close 로 끊으면 다시 붙는다")
    func serverCloseReconnects() async throws {
        let server = try LoopbackWebSocketServer(onText: Self.broker)
        let baseUrl = try await server.start()
        defer { server.stop() }
        let sleep = RecordingSleep()

        var iterator = try makeSocket(baseUrl: baseUrl, sleep: sleep).room(chatRoomId: 7).makeAsyncIterator()
        #expect(await iterator.next() == .connected)
        try #require(server.peers.first).close()

        #expect(await iterator.next() == .disconnected)
        #expect(await iterator.next() == .connected)
        #expect(server.peers.count == 2)
        #expect(isReconnectDelay(sleep.durations[0], baseMs: 3_000))
    }

    @Test("서버의 ERROR 프레임은 끊김이고 소켓은 3001 로 닫힌다")
    func errorFrameOnWire() async throws {
        let server = try LoopbackWebSocketServer(onText: Self.broker)
        let baseUrl = try await server.start()
        defer { server.stop() }

        var iterator = try makeSocket(baseUrl: baseUrl).room(chatRoomId: 7).makeAsyncIterator()
        #expect(await iterator.next() == .connected)
        let peer = try #require(server.peers.first)

        peer.send("ERROR\nmessage:denied\n\n\0")

        #expect(await iterator.next() == .disconnected)
        #expect(await waitUntil { peer.received.contains(.close(code: 3001)) }, "\(peer.received)")
    }

    /// Close 프레임의 이유는 123바이트까지다. 넘기면 `URLSession` 이 프레임을 아예 보내지 않아 서버가 닫힘을 모른다.
    @Test("이유가 길어도 Close 프레임이 나간다")
    func longCloseReason() async throws {
        let server = try LoopbackWebSocketServer(onText: Self.broker)
        let baseUrl = try await server.start()
        defer { server.stop() }

        var iterator = try makeSocket(baseUrl: baseUrl).room(chatRoomId: 7).makeAsyncIterator()
        #expect(await iterator.next() == .connected)
        let peer = try #require(server.peers.first)

        peer.send("ERROR\nmessage:\(String(repeating: "거절", count: 200))\n\n\0")

        #expect(await iterator.next() == .disconnected)
        #expect(await waitUntil { peer.received.contains(.close(code: 3001)) }, "\(peer.received)")
    }

    /// 업그레이드를 거절당해도(5xx 등) 예외 없이 재연결 루프에 들어가야 한다.
    @Test("업그레이드가 거절되면 끊김으로 올리고 다시 시도한다")
    func upgradeRejected() async throws {
        let server = try LoopbackServer { _ in "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n\r\n" }
        let baseUrl = try await server.start()
        defer { server.stop() }

        var iterator = try makeSocket(baseUrl: baseUrl).room(chatRoomId: 7).makeAsyncIterator()

        #expect(await iterator.next() == .disconnected)
        #expect(await iterator.next() == .disconnected)
        #expect(server.requests.first?.hasPrefix("GET /ws-chat HTTP/1.1\r\n") == true)
    }

    /// 소켓 세션은 읽기 타임아웃을 꺼 두었다. 소켓 쪽이 직접 안 지키면 답 없는 서버 앞에서 영영 안 끝난다.
    @Test("업그레이드 응답이 없으면 연결 타임아웃으로 실패한다")
    func connectTimesOut() async throws {
        let server = try LoopbackServer { _ in nil }
        let baseUrl = try await server.start()
        defer { server.stop() }

        var iterator = try makeSocket(baseUrl: baseUrl, connectTimeout: .milliseconds(200)).room(chatRoomId: 7).makeAsyncIterator()

        #expect(await iterator.next() == .disconnected)
    }

    @Test("연결 중에 취소하면 바로 끝난다")
    func cancelWhileConnecting() async throws {
        let server = try LoopbackServer { _ in nil }
        let baseUrl = try await server.start()
        defer { server.stop() }
        let socket = try makeSocket(baseUrl: baseUrl)
        let collector = Task {
            for await _ in socket.room(chatRoomId: 7) {}
        }
        #expect(await waitUntil { !server.requests.isEmpty })

        collector.cancel()
        await collector.value
    }

    /// pong 이 오는 동안엔 끊지 않는다 — 멀쩡한 연결을 매번 끊으면 안 된다.
    @Test("ping 을 주기마다 보내고 pong 이 오면 연결을 유지한다")
    func pingsKeepConnectionAlive() async throws {
        let server = try LoopbackWebSocketServer(onText: Self.broker)
        let baseUrl = try await server.start()
        defer { server.stop() }

        var iterator = try makeSocket(baseUrl: baseUrl, pingInterval: .milliseconds(100)).room(chatRoomId: 7).makeAsyncIterator()
        #expect(await iterator.next() == .connected)
        let peer = try #require(server.peers.first)
        let id = try #require(await subscriptionId(peer, destination: "/sub/chat-rooms/7"))

        try await Task.sleep(for: .milliseconds(600))

        peer.send("MESSAGE\nsubscription:\(id)\n\n\(Self.messageBody)\0")
        guard case .message = await iterator.next() else {
            Issue.record("끊겼다")
            return
        }
        #expect(server.peers.count == 1)
    }

    /// 조용히 죽은 소켓(NAT 만료 등)을 알아채는 유일한 수단이다. 안 되면 `live` 가 남아 전송이 REST 로 떨어지지 않는다.
    @Test("pong 이 안 오면 연결 실패로 처리하고 전송도 false 가 된다")
    func missedPongFails() async throws {
        let server = try LoopbackWebSocketServer(answerPings: false, onText: Self.broker)
        let baseUrl = try await server.start()
        defer { server.stop() }
        let socket = try makeSocket(baseUrl: baseUrl, pingInterval: .milliseconds(100))

        var iterator = socket.room(chatRoomId: 7).makeAsyncIterator()
        #expect(await iterator.next() == .connected)
        #expect(await iterator.next() == .disconnected)

        #expect(await socket.sendMessage(chatRoomId: 7, content: "x") == false)
    }

    @Test("소켓 상수는 원본과 같다")
    func socketConstants() {
        #expect(NetworkModule.SOCKET_PING_INTERVAL_SECONDS == 20)
        #expect(NetworkModule.SOCKET_CONNECT_TIMEOUT_SECONDS == 10)
    }
}
