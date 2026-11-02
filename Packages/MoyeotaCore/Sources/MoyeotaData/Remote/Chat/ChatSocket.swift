import Foundation
import MoyeotaDomain
import os

/// 연속 실패 1·2·3·4회째의 재연결 대기 — **고정 3초가 아니다.**
///
/// 예전에는 상수 하나(3초)였다. 서버가 5xx 로 누워 있는 동안 한 단말이 분당 20번 WebSocket
/// 업그레이드를 시도하는 하드 루프가 됐고, **서버가 아플 때 가장 세게 때리는** 모양이었다.
/// 같은 레포의 `AppConfigViewModel.RETRY_DELAYS_MS`(2s·5s·15s)도 같은 이유로 증가 간격을 쓴다.
///
/// 값과 모양은 SSE 쪽(`PartyEventSource` 의 같은 이름 함수)과 **일부러 같게** 뒀다 —
/// 두 실시간 통로가 같은 장애에 다르게 반응할 이유가 없다. 지수식(`base shl n`)이 아니라 표인 이유도
/// 그쪽과 같다: 간격이 눈에 보이고, 상한이 계산 결과가 아니라 적어 둔 값이다.
///
/// 횟수를 **넘어가면 마지막 값(30초)에 머문다.** 멈추지는 않는다 — 소켓이 끊긴 동안 호출부의
/// 폴링(3초)이 메시지를 메우긴 하지만, 폴링은 왕복이 잦고 읽음 처리도 REST 로 떨어진다. 결국 다시
/// 붙는 쪽이 싸다.
private let RECONNECT_DELAYS_MS: [Int64] = [3_000, 6_000, 12_000, 30_000]

/// 대기 시간에 더하는 **지터** 비율(0~20%). 서버가 재기동하면 끊긴 단말들이 **같은 초에** 다시 몰려
/// 또 넘어진다 — 표만으로는 그 동기화를 풀 수 없다. 음수 쪽으로 흔들지 않는 건 상한(30초)과
/// 하한(3초)이 둘 다 **지키려는 값**이기 때문이다.
private let RECONNECT_JITTER_RATIO = 0.2

/// 백오프 표를 한 바퀴 다 쓴 시점. 표가 4칸이므로 4회째다.
private let RECONNECT_REPORT_AT = RECONNECT_DELAYS_MS.count

/// 서버가 이 세션의 요청을 거절할 때 쓰는 통로(`StompExceptionHandler`). 구독은 인증만 되면 허용된다
private let ERROR_DESTINATION = "/user/queue/errors"

/// 실패의 **종류**만 담은 이름 — 원본의 `e.javaClass.name` 자리. 메시지·`userInfo` 는 넣지 않는다.
///
/// `URLError` 는 던져지면 `NSError` 로 다리 놓여 타입 이름만으로는 모두 `NSError` 다. 그 경우엔 도메인과 코드가
/// 곧 종류다(`NSURLErrorDomain(-1004)`).
private func errorTypeName(_ error: any Error) -> String {
    let name = String(reflecting: type(of: error))
    guard name == "NSError" || name == "Foundation.NSError" else { return name }
    let nsError = error as NSError
    return "\(nsError.domain)(\(nsError.code))"
}

/// 채팅 실시간 **수신·전송** — STOMP over WebSocket.
///
/// 서버는 메시지가 저장될 때마다 `/sub/chat-rooms/{id}` 로 밀어 준다(`ChatRedisSubscriber`). 페이로드는
/// REST 조회와 **같은 shape**(`ChatMessageResult`)이라 `ChatMessageResponse` 를 그대로 재사용한다.
/// 보내는 쪽은 `/pub/chat-rooms/{id}/messages` 로 SEND 프레임을 쓴다(`StompChatController`) —
/// **응답이 없는 단방향**이다. 저장 결과는 나에게도 위 구독으로 되돌아온다.
///
/// 인증은 STOMP **CONNECT 프레임의 `Authorization: Bearer` 헤더**다(`StompAuthInterceptor`).
/// HTTP 헤더가 아니라 프레임 헤더라는 점이 중요하다 — 서버가 그것만 읽는다.
/// 구독도 서버가 검사한다: 그 방의 **활성 참여자**가 아니면 SUBSCRIBE 가 거부된다.
///
/// **폴링을 대체하지 않고 앞선다.** 이 흐름이 끊겨도 호출부의 폴링이 메시지를 메우므로,
/// 연결 실패는 조용히 재시도만 하고 화면에 에러를 올리지 않는다. 재연결 사이에 오간 메시지도
/// 이 흐름으로는 오지 않으므로 커서 조회가 메워야 한다 — 그래서 폴링을 아주 끄지 않는다.
public final class ChatSocket: Sendable {
    private static let logger = Logger(subsystem: "com.moyeota.data", category: "ChatSocket")

    private let baseUrl: String
    private let tokens: any TokenHolder
    private let client: StompClient
    private let sleep: @Sendable (Duration) async throws -> Void
    private let report: @Sendable (FailureSite, any Error) throws -> Void

    /// 지금 붙어 있는 세션. `room` 을 수집하는 동안에만 채워지고, 전송이 **같은 세션**을 쓴다 —
    /// 보내려고 따로 연결하면 서버 입장에서 세션이 둘이 되고, 전송 결과를 되돌려받을 구독도 없다.
    private let live = OSAllocatedUnfairLock<LiveSession?>(initialState: nil)

    private struct LiveSession: Sendable {
        let chatRoomId: Int64
        let session: StompSession
    }

    private struct SendMessageFrame: Encodable {
        let content: String
    }

    private struct ReadFrame: Encodable {
        let lastReadMessageId: Int64
    }

    /// 연결 하나에서 오는 신호. 구독이 걸린 순간(`connected`)을 알려야 호출부가 그 전의 공백을 메울 수 있다
    public enum RoomSignal: Equatable, Sendable {
        case connected
        case message(response: ChatMessageResponse)
        case disconnected
    }

    /// 인증이 붙은 클라이언트를 쓰지 않는다 — STOMP 인증은 프레임 헤더라 HTTP 헤더는
    /// 필요 없고, 401 재발급이 업그레이드 요청에 끼어들 이유도 없다(`NetworkModule.Apis.socketClient`).
    public convenience init(baseUrl: String, session: URLSession, tokens: any TokenHolder) {
        self.init(baseUrl: baseUrl, webSocketClient: URLSessionWebSocketClient(session: session), tokens: tokens)
    }

    init(
        baseUrl: String,
        webSocketClient: any WebSocketClient,
        tokens: any TokenHolder,
        config: StompConfig = StompConfig(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        report: @escaping @Sendable (FailureSite, any Error) throws -> Void = { try Diagnostics.report(site: $0, throwable: $1) }
    ) {
        self.baseUrl = baseUrl
        self.tokens = tokens
        self.client = StompClient(webSocketClient: webSocketClient, config: config)
        self.sleep = sleep
        self.report = report
    }

    /// 연속 실패 `failures` 회째의 재연결 대기(ms) — **네트워크 없이 테스트할 수 있는 순수 함수다.**
    ///
    /// `RECONNECT_DELAYS_MS` 표를 1회째부터 차례로 읽고, 표를 다 쓰면 마지막 값에 머문다. 거기에
    /// `RECONNECT_JITTER_RATIO` 만큼의 지터를 **더한다**(0 ≤ `jitter` ≤ 1 이 그 안에서의 위치다).
    ///
    /// `failures` 가 0 이하여도 첫 간격으로 떨어진다 — 세는 쪽이 틀려도 0ms 하드 루프가 되지 않게.
    /// **구독까지 성공하면 호출부가 횟수를 0 으로 되돌린다**(`room`) — 그러지 않으면 몇 시간
    /// 붙어 있던 연결이 한 번 끊겼을 때 30초를 기다린다.
    ///
    /// (원본은 SSE 쪽과 패키지가 달라 같은 이름의 최상위 함수다. 여기는 한 모듈이라 타입 안에 둔다.)
    static func reconnectDelayMs(failures: Int, jitter: Double = Double.random(in: 0..<1)) -> Int64 {
        let index = min(max(failures, 1) - 1, RECONNECT_DELAYS_MS.count - 1)
        let base = RECONNECT_DELAYS_MS[index]
        return base + Int64(Double(base) * RECONNECT_JITTER_RATIO * min(max(jitter, 0.0), 1.0))
    }

    /// 이 방의 새 메시지 흐름. 수집이 취소될 때까지 유지되고, 끊기면 `reconnectDelayMs` 뒤 다시 붙는다
    /// (연속 실패마다 늘어나는 간격 + 소량 지터 — 고정 3초가 아니다).
    /// 미로그인이면 연결하지 않고 다음 주기를 기다린다(로그인 뒤 자연히 붙는다).
    ///
    /// 메인 액터 밖의 태스크에서 돈다 — 호출부가 어디서 수집하든 소켓 일이 화면을 붙들지 않는다.
    public func room(chatRoomId: Int64) -> AsyncStream<RoomSignal> {
        AsyncStream { continuation in
            let task = Task { [self] in
                try? await run(chatRoomId: chatRoomId, continuation: continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 취소될 때만 던진다.
    private func run(chatRoomId: Int64, continuation: AsyncStream<RoomSignal>.Continuation) async throws {
        // 연속 실패 횟수 — 붙는 데 성공하면(connected) 0 으로 되돌린다
        var failures = 0
        // 마지막 실패의 **종류만** 기억한다. 예외 객체나 메시지를 들고 있지 않는 이유는
        // 보고에 서버 응답 조각 같은 값이 섞여 나가지 않게 하기 위해서다.
        var lastErrorType: String?
        while true {
            try Task.checkCancellation()
            do {
                try await collectRoom(chatRoomId: chatRoomId) { signal in
                    // 구독까지 성공했으면 백오프를 처음으로 되돌린다. 긴 연결이 끊긴 것과
                    // 「붙지도 못하는 상태」를 같게 다루면 멀쩡한 서버에도 30초를 기다린다.
                    if case .connected = signal {
                        failures = 0
                        lastErrorType = nil
                    }
                    continuation.yield(signal)
                }
                // 예외 없이 돌아오는 경우(미로그인·구독 종료)도 **실패로 센다** — 조건이 그대로면
                // 다음 시도도 같은 결과라, 3초마다 깨어나는 하드 루프가 된다.
                failures += 1
            } catch {
                // 취소만 위로 흘린다. `URLError(.cancelled)` 는 태스크가 취소됐을 때만 취소다.
                if Task.isCancelled { throw CancellationError() }
                failures += 1
                lastErrorType = errorTypeName(error)
                Self.logger.debug("연결 끊김 roomId=\(chatRoomId) — \(failures)회째 실패: \(error)")
            }
            // `for await` 는 취소되면 던지지 않고 끝나기도 한다 — 그 길은 위의 정상 반환으로 온다.
            try Task.checkCancellation()
            try reportIfStuck(failures: failures, lastErrorType: lastErrorType)
            continuation.yield(.disconnected)
            let wait = Self.reconnectDelayMs(failures: failures)
            Self.logger.debug("재연결 대기 roomId=\(chatRoomId) — \(wait)ms (\(failures)회째)")
            try await sleep(.milliseconds(wait))
        }
    }

    /// 소켓이 **붙지 못하고 있다**는 것을 딱 한 번 보고한다.
    ///
    /// 한 번의 끊김은 버그가 아니다 — 지하철에서는 늘 일어난다. 그래서 `RECONNECT_DELAYS_MS` 표를
    /// 한 바퀴 다 쓴 `RECONNECT_REPORT_AT` 회째에 **정확히 한 번만** 올린다. `==` 비교인 것이
    /// 중요하다 — `>=` 로 쓰면 못 붙는 동안 30초마다 같은 보고가 쌓여 대시보드를 덮는다.
    ///
    /// **전송 실패 필터를 일부러 비껴간다.** 소켓 실패는 거의 다 전송 계층 오류라 원본을 넘기면
    /// `Diagnostics` 가 걸러 버린다. 여기서 신호는 예외의 종류가 아니라 **「연속 N회」라는 사실**
    /// 이므로, 종류 이름만 문자열로 옮겨 담은 새 예외로 올린다. 값은 들어가지 않는다.
    private func reportIfStuck(failures: Int, lastErrorType: String?) throws {
        if failures != RECONNECT_REPORT_AT { return }
        try report(
            .chatSocketReconnect,
            IllegalStateException("\(RECONNECT_REPORT_AT) consecutive failures; last=\(lastErrorType ?? "no-exception")")
        )
    }

    /// 이 방으로 메시지를 **보낸다**(SEND `/pub/chat-rooms/{id}/messages`).
    ///
    /// 서버 핸들러는 `void` 다 — 성공 여부가 프레임으로 돌아오지 않고, 저장된 메시지가 구독(`room`)으로
    /// 온다(`room` 의 message). 그래서 여기서 참을 돌려줘도 "서버가 저장했다"는 뜻이 아니라 **"살아 있는 세션에 써 넣었다"**는
    /// 뜻이다. 호출부는 되돌아오는 메시지를 확인으로 삼아야 한다.
    ///
    /// 연결이 없거나(미로그인·끊김) 다른 방에 붙어 있으면 false — 그때는 호출부가 REST 로 보낸다.
    public func sendMessage(chatRoomId: Int64, content: String) async -> Bool {
        send(chatRoomId: chatRoomId, destination: "/pub/chat-rooms/\(chatRoomId)/messages", frame: SendMessageFrame(content: content))
    }

    /// 읽음 지점 갱신(SEND `/pub/chat-rooms/{id}/read`). 메시지마다 한 번씩 일어나는 일이라
    /// 소켓이 붙어 있으면 REST 왕복을 아낀다. 실패해도 조용하다 — 배지 정확도보다 대화가 우선이다.
    public func markAsRead(chatRoomId: Int64, readMessageId: Int64) async -> Bool {
        send(chatRoomId: chatRoomId, destination: "/pub/chat-rooms/\(chatRoomId)/read", frame: ReadFrame(lastReadMessageId: readMessageId))
    }

    private func send(chatRoomId: Int64, destination: String, frame: some Encodable) -> Bool {
        guard let current = live.withLock({ $0 }), current.chatRoomId == chatRoomId else { return false }
        do {
            let body = String(decoding: try MoyeotaJSON.encoder.encode(frame), as: UTF8.self)
            try current.session.sendText(destination: destination, body: body)
            return true
        } catch {
            Self.logger.debug("전송 실패 dest=\(destination): \(error)")
            return false
        }
    }

    private func collectRoom(chatRoomId: Int64, emit: (RoomSignal) -> Void) async throws {
        guard let token = await tokens.currentAccessToken() else {
            Self.logger.debug("토큰이 없어 연결하지 않는다(미로그인)")
            return
        }
        let session = try await client.connect(
            url: webSocketUrl(),
            customStompConnectHeaders: [StompHeader("Authorization", "Bearer \(token)")]
        )

        Self.logger.debug("연결됨 roomId=\(chatRoomId)")
        live.withLock { $0 = LiveSession(chatRoomId: chatRoomId, session: session) }

        // 서버가 내 SEND 를 거절하면(참여자 아님·1000자 초과 등) 이 통로로만 알려 온다.
        let errors = Task { await collectErrors(session) }
        do {
            // 프레임 본문을 직접 받아 파싱한다 — 서버가 보내는 JSON 이 REST 응답과 같은 shape 이라
            // 변환 계층을 따로 끼우지 않는다. 모르는 필드는 무시하므로 서버가 필드를 늘려도 깨지지 않는다.
            // subscribeText 가 돌아온 시점에 SUBSCRIBE 가 이미 나갔다. 그 **뒤에** connected 를 내야
            // 호출부의 공백 조회와 소켓 수신 사이에 틈이 없다(겹치는 메시지는 호출부가 id 로 합친다).
            let messages = try session.subscribeText(destination: "/sub/chat-rooms/\(chatRoomId)")
            emit(.connected)
            for try await body in messages {
                // 파싱 못 한 프레임은 흘려보낸다 — 다음 연결의 공백 조회가 메운다
                guard let response = try? MoyeotaJSON.decoder.decode(ChatMessageResponse.self, from: Data(body.utf8)) else {
                    continue
                }
                emit(.message(response: response))
            }
        } catch {
            await finish(session: session, errors: errors)
            throw error
        }
        await finish(session: session, errors: errors)
    }

    /// 어느 길로 끝나든 세션을 닫는다. 취소된 태스크 안에서는 영수증 대기(`Task.sleep`)가 곧바로 깨므로
    /// **별도 태스크로** 닫아 DISCONNECT → RECEIPT → Close 순서를 지킨다. 구독 해제가 그 앞에 나가도록 에러 통로를 먼저 정리한다.
    private func finish(session: StompSession, errors: Task<Void, Never>) async {
        live.withLock { $0 = nil }
        errors.cancel()
        await errors.value
        await Task { await session.disconnect() }.value
    }

    // 에러 통로가 막혀도(구버전 서버 등) 대화는 그대로 돌아가야 한다 — 실패는 로그로만 남긴다.
    private func collectErrors(_ session: StompSession) async {
        do {
            for try await body in try session.subscribeText(destination: ERROR_DESTINATION) {
                Self.logger.warning("서버가 요청을 거절함: \(body)")
            }
        } catch {
            Self.logger.debug("에러 통로 구독 실패: \(error)")
        }
    }

    /// `https://host/` → `wss://host/ws-chat`. baseUrl 은 RestClient 규약상 항상 `/` 로 끝난다
    private func webSocketUrl() -> String {
        var url = baseUrl
        if let range = url.range(of: "https://") {
            url.replaceSubrange(range, with: "wss://")
        }
        if let range = url.range(of: "http://") {
            url.replaceSubrange(range, with: "ws://")
        }
        return url + "ws-chat"
    }
}
