import Foundation
import MoyeotaDomain
import os
import Testing
@testable import MoyeotaData

/// 재연결 대기를 기록만 하고 넘어가는 시계. 실제로 3초씩 기다리지 않는다.
final class RecordingSleep: Sendable {
    private let recorded = OSAllocatedUnfairLock<[Duration]>(initialState: [])

    var durations: [Duration] { recorded.withLock { $0 } }

    var sleep: @Sendable (Duration) async throws -> Void {
        { [recorded] duration in
            recorded.withLock { $0.append(duration) }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

/// `n` 번째 실패의 대기가 표의 값 + 지터(0~20%) 범위인가.
func isReconnectDelay(_ duration: Duration, baseMs: Int64) -> Bool {
    let min = Duration.milliseconds(baseMs)
    let max = Duration.milliseconds(baseMs + baseMs / 5)
    return duration >= min && duration <= max
}

/// 401 을 받으면 같은 요청을 그대로 다시 보내는 인증기. 재발급 자체는 `TokenAuthenticatorTest` 가 본다.
private struct RetryingAuthenticator: Authenticator {
    func authenticate(response: HttpRawResponse) async -> URLRequest? { response.request }
}

@Suite(.timeLimit(.minutes(1)))
struct PartyEventSourceTest {
    private static let eventStream = ["Content-Type": "text/event-stream"]
    private static let connected = "event: connected\ndata: {\"id\":7,\"status\":\"ACTIVE\"}\n\n"

    private func source(_ stub: StubServer, sleep: RecordingSleep = RecordingSleep()) -> PartyEventSource {
        PartyEventSource(baseUrl: stub.baseUrl, client: HttpClient(session: stub.session()), sleep: sleep.sleep)
    }

    private func isSnapshot(_ event: PartySseEvent?) -> Bool {
        if case .snapshot = event { return true }
        return false
    }

    /// 앞에서 `count` 개를 받는다. 스트림이 먼저 끝나면 그만큼만 돌려준다.
    private func first(_ count: Int, of stream: AsyncThrowingStream<PartySseEvent, any Error>) async throws -> [PartySseEvent] {
        var events: [PartySseEvent] = []
        for try await event in stream {
            events.append(event)
            if events.count == count { break }
        }
        return events
    }

    @Test("경로와 Accept 헤더로 요청한다")
    func requestShape() async throws {
        let stub = StubServer { _ in StubResponse(status: 200, body: "event: closed\ndata: 7\n\n", headers: Self.eventStream) }

        _ = try await first(1, of: source(stub).events(partyId: 42))

        let request = try #require(stub.requests.first)
        #expect(request.method == "GET")
        #expect(request.path == "/api/v1/matching/rooms/42/events")
        #expect(request.header("Accept") == "text/event-stream")
    }

    /// `HttpClient` 로 갈라 붙는 인증이 SSE 에도 실제로 걸리는지. 만료 토큰으로 첫 스냅샷을 못 받으면 대기 화면이 멈춘다.
    @Test("Bearer 를 붙이고 401 이면 재발급한 토큰으로 다시 붙는다")
    func refreshesOn401() async throws {
        let stub = StubServer { request in
            if request.path == "/api/v1/auth/reissue" {
                return StubResponse(status: 200, body: #"{"accessToken":"new.access","refreshToken":"new.refresh"}"#)
            }
            if request.header("Authorization") == "Bearer new.access" {
                return StubResponse(status: 200, body: Self.connected + "event: closed\ndata: 7\n\n", headers: Self.eventStream)
            }
            return StubResponse(status: 401, body: #"{"code":"USER002","message":"만료"}"#)
        }
        let tokens = FakeTokenHolder(accessToken: "old.access", refreshToken: "old.refresh")
        let apis = try NetworkModule.create(
            baseUrl: stub.baseUrl,
            debugLogging: false,
            tokenHolder: tokens,
            protocolClasses: [StubURLProtocol.self],
            logSink: { _ in }
        )
        let source = PartyEventSource(baseUrl: stub.baseUrl, client: apis.streamClient)

        let events = try await first(5, of: source.events(partyId: 7))

        #expect(events.count == 2)
        #expect(isSnapshot(events.first))
        #expect(events.last == .closed)
        let eventRequests = stub.requests.filter { $0.path.hasSuffix("/events") }
        #expect(eventRequests.map { $0.header("Authorization") } == ["Bearer old.access", "Bearer new.access"])
        #expect(tokens.accessToken == "new.access")
    }

    @Test("closed 를 받으면 끊김 신호 없이 끝나고 다시 붙지 않는다")
    func closedTerminates() async throws {
        let stub = StubServer { _ in
            StubResponse(status: 200, body: Self.connected + "event: closed\ndata: 7\n\n", headers: Self.eventStream)
        }
        let sleep = RecordingSleep()

        let events = try await first(10, of: source(stub, sleep: sleep).events(partyId: 7))

        #expect(events.count == 2)
        #expect(isSnapshot(events.first))
        #expect(events.last == .closed)
        #expect(stub.requests.count == 1)
        #expect(sleep.durations.isEmpty)
    }

    @Test("404 는 조용히 끝나고 다시 붙지 않는다")
    func notFoundEndsQuietly() async throws {
        let stub = StubServer(status: 404, body: #"{"code":"PARTY001"}"#)
        let sleep = RecordingSleep()

        let events = try await first(10, of: source(stub, sleep: sleep).events(partyId: 7))

        #expect(events.isEmpty)
        #expect(stub.requests.count == 1)
        #expect(sleep.durations.isEmpty)
    }

    /// 뭉개면 내가 없는 방을 6초마다 영원히 폴링한다 — `PartyMembershipLostException` 주석.
    @Test("403 은 정상 종료가 아니라 멤버 상실 예외다")
    func forbiddenThrows() async throws {
        let stub = StubServer(status: 403, body: #"{"code":"NOT_PARTY_MEMBER"}"#)
        let sleep = RecordingSleep()
        var seen: [PartySseEvent] = []

        let error = await #expect(throws: PartyMembershipLostException.self) {
            for try await event in source(stub, sleep: sleep).events(partyId: 7) { seen.append(event) }
        }

        #expect(error?.partyId == 7)
        #expect(seen.isEmpty)
        #expect(stub.requests.count == 1)
        #expect(sleep.durations.isEmpty)
    }

    /// 원본은 상태 코드만 보고 본문을 읽지 않는다(okhttp-sse `onFailure`). 본문을 기다리면 `상태를 받고도`
    /// 끊김으로 뭉개져 멤버 상실을 늦게 알고 재연결을 한 번 더 한다.
    ///
    /// 서버는 본문의 첫 바이트(`{`)까지만 보내고 멈춘다. `URLSession` 은 첫 바이트 전에는 응답 자체를 내주지
    /// 않아, 헤더만 온 경우는 원본과 맞출 수 없다(docs/IOS-DIFFERENCES.md).
    private func stalledBodySource(
        _ baseUrl: String,
        sleep: RecordingSleep,
        authenticator: (any Authenticator)? = nil
    ) -> PartyEventSource {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        return PartyEventSource(
            baseUrl: baseUrl,
            client: HttpClient(session: URLSession(configuration: configuration), authenticator: authenticator),
            sleep: sleep.sleep
        )
    }

    @Test("403 은 본문이 도중에 멈춰도 바로 멤버 상실이고 연결을 닫는다")
    func forbiddenWithStalledBody() async throws {
        let server = try LoopbackStreamServer { exchange in
            exchange.send("HTTP/1.1 403 Forbidden\r\nContent-Type: application/json\r\nContent-Length: 100\r\n\r\n{")
        }
        let baseUrl = try await server.start()
        defer { server.stop() }
        let sleep = RecordingSleep()
        var seen: [PartySseEvent] = []

        await #expect(throws: PartyMembershipLostException.self) {
            for try await event in stalledBodySource(baseUrl, sleep: sleep).events(partyId: 7) {
                seen.append(event)
                if seen.count > 3 { break }
            }
        }

        #expect(seen.isEmpty)
        #expect(sleep.durations.isEmpty)
        #expect(server.exchanges.count == 1)
        let exchange = try #require(server.exchanges.first)
        #expect(await waitUntil { exchange.isPeerClosed })
    }

    @Test("404 는 본문이 도중에 멈춰도 바로 끝나고 다시 붙지 않는다")
    func notFoundWithStalledBody() async throws {
        let server = try LoopbackStreamServer { exchange in
            exchange.send("HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: 100\r\n\r\n{")
        }
        let baseUrl = try await server.start()
        defer { server.stop() }
        let sleep = RecordingSleep()

        let events = try await first(3, of: stalledBodySource(baseUrl, sleep: sleep).events(partyId: 7))

        #expect(events.isEmpty)
        #expect(sleep.durations.isEmpty)
        #expect(server.exchanges.count == 1)
    }

    @Test("401 은 멈춘 본문을 기다리지 않고 바로 재발급으로 넘어간다")
    func unauthorizedWithStalledBody() async throws {
        let server = try LoopbackStreamServer { exchange in
            if exchange.index == 0 {
                exchange.send("HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: 100\r\n\r\n{")
            } else {
                exchange.send("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\nevent: closed\ndata: 7\n\n")
            }
        }
        let baseUrl = try await server.start()
        defer { server.stop() }
        let sleep = RecordingSleep()

        let events = try await first(1, of: stalledBodySource(baseUrl, sleep: sleep, authenticator: RetryingAuthenticator()).events(partyId: 7))

        #expect(events == [.closed])
        #expect(sleep.durations.isEmpty)
        #expect(server.exchanges.count == 2)
    }

    /// 서버가 `closeMember` 로 스트림을 끝낸 뒤의 경로: 끊김 → 재연결 → 403 → 예외. 원본 주석 그대로다.
    @Test("스트림이 끝나 재연결했는데 403 이면 예외로 멈춘다")
    func leftThenForbidden() async throws {
        let count = OSAllocatedUnfairLock(initialState: 0)
        let stub = StubServer { _ in
            let index = count.withLock { value -> Int in
                defer { value += 1 }
                return value
            }
            return index == 0
                ? StubResponse(status: 200, body: Self.connected, headers: Self.eventStream)
                : StubResponse(status: 403)
        }
        var seen: [PartySseEvent] = []

        await #expect(throws: PartyMembershipLostException.self) {
            for try await event in source(stub).events(partyId: 7) { seen.append(event) }
        }

        #expect(seen.count == 2)
        #expect(isSnapshot(seen.first))
        #expect(seen.last == .disconnected)
    }

    @Test("서버 오류는 끊김으로 올리고 실패할수록 오래 기다린다")
    func backoffGrowsOnFailure() async throws {
        let stub = StubServer(status: 503)
        let sleep = RecordingSleep()

        let events = try await first(6, of: source(stub, sleep: sleep).events(partyId: 7))

        #expect(events == Array(repeating: .disconnected, count: 6))
        let bases: [Int64] = [3_000, 6_000, 12_000, 30_000, 30_000]
        #expect(sleep.durations.count >= bases.count)
        for (duration, base) in zip(sleep.durations, bases) {
            #expect(isReconnectDelay(duration, baseMs: base), "\(duration) vs \(base)")
        }
    }

    @Test("전송 실패도 끊김으로 올리고 다시 붙는다")
    func transportFailureReconnects() async throws {
        let stub = StubServer { _ in StubResponse(failure: URLError(.networkConnectionLost)) }

        let events = try await first(2, of: source(stub).events(partyId: 7))

        #expect(events == [.disconnected, .disconnected])
        #expect(stub.requests.count >= 2)
    }

    /// 몇 시간 붙어 있던 연결이 한 번 끊겼을 때 30초를 기다리면 안 된다.
    @Test("한 번 붙으면 실패 횟수가 처음으로 돌아간다")
    func openResetsFailures() async throws {
        let count = OSAllocatedUnfairLock(initialState: 0)
        let stub = StubServer { _ in
            let index = count.withLock { value -> Int in
                defer { value += 1 }
                return value
            }
            // 실패 세 번 → 붙었다 끊김 → 실패
            return index == 3
                ? StubResponse(status: 200, body: Self.connected, headers: Self.eventStream)
                : StubResponse(status: 500)
        }
        let sleep = RecordingSleep()

        // 끊김 3 + 스냅샷 + 끊김 + 끊김
        let events = try await first(6, of: source(stub, sleep: sleep).events(partyId: 7))

        #expect(isSnapshot(events[3]))
        let bases: [Int64] = [3_000, 6_000, 12_000, 3_000]
        for (duration, base) in zip(sleep.durations, bases) {
            #expect(isReconnectDelay(duration, baseMs: base), "\(duration) vs \(base)")
        }
        #expect(sleep.durations.count >= bases.count)
    }

    /// 프록시의 HTML 200 을 「붙었다」로 세면 실패 횟수가 늘지 않아 3초 하드 루프가 된다.
    @Test("2xx 라도 SSE 가 아니면 붙은 것으로 치지 않는다")
    func wrongContentTypeIsFailure() async throws {
        let stub = StubServer { _ in
            StubResponse(status: 200, body: "event: connected\ndata: {\"id\":1}\n\n", headers: ["Content-Type": "text/html"])
        }
        let sleep = RecordingSleep()

        let events = try await first(3, of: source(stub, sleep: sleep).events(partyId: 7))

        #expect(events == [.disconnected, .disconnected, .disconnected])
        #expect(isReconnectDelay(sleep.durations[0], baseMs: 3_000))
        #expect(isReconnectDelay(sleep.durations[1], baseMs: 6_000))
    }

    @Test("Content-Type 의 파라미터와 대소문자는 보지 않는다")
    func contentTypeParameters() async throws {
        let stub = StubServer { _ in
            StubResponse(status: 200, body: "event: closed\ndata: 7\n\n", headers: ["content-type": "Text/Event-Stream; charset=UTF-8"])
        }

        #expect(try await first(5, of: source(stub).events(partyId: 7)) == [.closed])
    }

    @Test("깨진·모르는 프레임과 주석은 건너뛰고 스트림은 산다")
    func skipsBadFrames() async throws {
        let body = ":ping\n\n"
            + "event: member-joined\ndata: not json\n\n"
            + "event: driver-assigned\ndata: {}\n\n"
            + "data: {}\n\n"
            + Self.connected
            + "event: closed\ndata: 7\n\n"
        let stub = StubServer { _ in StubResponse(status: 200, body: body, headers: Self.eventStream) }

        let events = try await first(10, of: source(stub).events(partyId: 7))

        #expect(events.count == 2)
        #expect(isSnapshot(events.first))
        #expect(events.last == .closed)
    }

    /// 원본은 `Last-Event-ID` 를 보내지 않는다. 재연결 보정은 `connected` 스냅샷의 몫이다.
    @Test("재연결에 Last-Event-ID 를 싣지 않는다")
    func noLastEventId() async throws {
        let stub = StubServer { _ in StubResponse(status: 200, body: "id: 9\n" + Self.connected, headers: Self.eventStream) }

        _ = try await first(4, of: source(stub).events(partyId: 7))

        #expect(stub.requests.count >= 2)
        #expect(stub.requests.allSatisfy { $0.header("Last-Event-ID") == nil })
    }

    // MARK: - 실제 소켓

    /// `URLProtocol` 스텁은 본문을 한 번에 주고 끝나서 이걸 보여 주지 못한다. `URLSession` 이 응답을 쌓아 두면
    /// 스냅샷이 다음 바이트가 올 때(30초 뒤 ping)까지 안 보인다.
    @Test("열린 연결에서 프레임이 오는 대로 나온다")
    func deliversIncrementally() async throws {
        let server = try LoopbackStreamServer { exchange in
            exchange.send("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n")
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                exchange.send(Self.connected)
            }
        }
        let baseUrl = try await server.start()
        defer { server.stop() }
        let source = PartyEventSource(baseUrl: baseUrl, client: HttpClient(session: URLSession(configuration: .ephemeral)))

        var iterator = source.events(partyId: 7).makeAsyncIterator()
        #expect(isSnapshot(try await iterator.next()))

        let exchange = try #require(server.exchanges.first)
        exchange.send("event: member-left\ndata: {\"publicId\":\"a\",\"status\":\"ACTIVE\"}\n\n")
        let left = try await iterator.next()
        guard case .memberLeft(let payload) = left else {
            Issue.record("member-left 가 아니다: \(String(describing: left))")
            return
        }
        #expect(payload.publicId == "a")
        // 끊긴 적 없다 — 같은 연결에서 받았다.
        #expect(server.exchanges.count == 1)
    }

    /// 죽은 연결을 알아채는 유일한 수단이다. 안 되면 폴링을 끈 대기 화면이 그대로 멈춘다.
    @Test("읽기 타임아웃이 지나면 끊김으로 올리고 다시 붙는다")
    func readTimeoutReconnects() async throws {
        let server = try LoopbackStreamServer { exchange in
            exchange.send("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n" + Self.connected)
        }
        let baseUrl = try await server.start()
        defer { server.stop() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 0.3
        let sleep = RecordingSleep()
        let source = PartyEventSource(baseUrl: baseUrl, client: HttpClient(session: URLSession(configuration: configuration)), sleep: sleep.sleep)

        let events = try await first(3, of: source.events(partyId: 7))

        #expect(isSnapshot(events[0]))
        #expect(events[1] == .disconnected)
        #expect(isSnapshot(events[2]))
        #expect(server.exchanges.count == 2)
        #expect(isReconnectDelay(sleep.durations[0], baseMs: 3_000))
    }

    /// 수집 취소가 소켓까지 닿지 않으면 화면을 떠난 뒤에도 서버 쪽 구독이 남는다.
    @Test("수집을 취소하면 연결이 닫히고 끊김 신호를 내지 않는다")
    func cancellationClosesConnection() async throws {
        let server = try LoopbackStreamServer { exchange in
            exchange.send("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n" + Self.connected)
        }
        let baseUrl = try await server.start()
        defer { server.stop() }
        let sleep = RecordingSleep()
        let source = PartyEventSource(baseUrl: baseUrl, client: HttpClient(session: URLSession(configuration: .ephemeral)), sleep: sleep.sleep)
        let received = OSAllocatedUnfairLock<[PartySseEvent]>(initialState: [])

        let collector = Task {
            for try await event in source.events(partyId: 7) {
                received.withLock { $0.append(event) }
            }
        }
        #expect(await waitUntil { received.withLock { !$0.isEmpty } })

        collector.cancel()
        _ = await collector.result

        let exchange = try #require(server.exchanges.first)
        #expect(await waitUntil { exchange.isPeerClosed })
        #expect(received.withLock { $0.count } == 1)
        #expect(sleep.durations.isEmpty)
        #expect(server.exchanges.count == 1)
    }

    /// 태스크 취소 없이 `for await` 를 빠져나오기만 해도(`break`) 스트림이 사라지며 정리돼야 한다.
    @Test("수집을 그만두기만 해도 연결을 닫는다")
    func stopsWhenStreamIsDropped() async throws {
        let server = try LoopbackStreamServer { exchange in
            exchange.send("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n" + Self.connected)
        }
        let baseUrl = try await server.start()
        defer { server.stop() }
        let source = PartyEventSource(baseUrl: baseUrl, client: HttpClient(session: URLSession(configuration: .ephemeral)))

        let events = try await first(1, of: source.events(partyId: 7))

        #expect(isSnapshot(events.first))
        let exchange = try #require(server.exchanges.first)
        #expect(await waitUntil { exchange.isPeerClosed })
        #expect(server.exchanges.count == 1)
    }

    /// `closed` 뒤에 서버가 끊기를 기다리지 않는다 — 안 끊어 주면 연결이 45초 더 남는다.
    @Test("closed 를 받으면 앱이 먼저 연결을 닫는다")
    func closedClosesConnection() async throws {
        let server = try LoopbackStreamServer { exchange in
            exchange.send("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\nevent: closed\ndata: 7\n\n")
        }
        let baseUrl = try await server.start()
        defer { server.stop() }
        let source = PartyEventSource(baseUrl: baseUrl, client: HttpClient(session: URLSession(configuration: .ephemeral)))

        #expect(try await first(5, of: source.events(partyId: 7)) == [.closed])

        let exchange = try #require(server.exchanges.first)
        #expect(await waitUntil { exchange.isPeerClosed })
    }
}
