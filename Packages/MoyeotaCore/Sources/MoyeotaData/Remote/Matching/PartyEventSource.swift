import Foundation
import MoyeotaDomain
import os

/// 끊긴 뒤 다시 붙기까지 — **연속 실패 횟수만큼 늘어난다**(`PartyEventSource.reconnectDelayMs`).
///
/// 예전에는 고정 3초였다. 실패를 세지 않아 서버가 502/503 을 내거나 Redis 가 죽은 동안에도 간격이
/// 그대로였고, 그때 이 루프는 **재기동 중인 서버를 때리는 하드 루프**가 된다 — 대기 화면에 12명이
/// 있으면 분당 240회다(한 사람이 분당 20회). 상한·백오프가 없다는 건 서버가 느려질수록 앱이 더
/// 세게 두드린다는 뜻이고, 그게 장애를 길게 만든다.
///
/// 그래서 같은 레포의 운영 설정 재시도(`AppConfigViewModel.RETRY_DELAYS_MS` = 2s·5s·15s)와 같은
/// 모양으로 **표**를 쓴다. 지수식(`base shl n`)이 아니라 표인 이유도 같다 — 간격이 눈에 보이고,
/// 상한이 계산 결과가 아니라 적어 둔 값이다.
///
/// 횟수를 **넘어가면 마지막 값(30초)에 머문다.** 재시도를 멈추지는 않는다: 이 스트림이 끊긴 동안
/// 대기 화면은 6초 폴백 폴링으로 버티지만(`MatchWaitingViewModel`), 폴백은 들고 나는 사람이 보이기까지
/// 그만큼 느리고 서버 쿼리도 3배다 — 결국 다시 붙는 쪽이 싸다.
private let RECONNECT_DELAYS_MS: [Int64] = [3_000, 6_000, 12_000, 30_000]

/// 대기 시간에 더하는 **지터** 비율(0~20%). 12명이 같은 장애로 동시에 끊기면 같은 초에 다시 몰려
/// 서버가 또 넘어진다 — 표만으로는 그 동기화를 풀 수 없다. 음수 쪽으로 흔들지 않는 건 상한(30초)과
/// 하한(3초)이 둘 다 **지키려는 값**이기 때문이다.
private let RECONNECT_JITTER_RATIO = 0.2

/// 매칭방 변화 신호 — SSE(`GET /matching/rooms/{id}/events`, `text/event-stream`).
///
/// **서버가 변경분(delta)을 싣는 방식으로 바뀌었다**(Backend #218). 예전 `changed`(= "뭔가 바뀜, 상세를
/// 다시 읽어라") 이벤트는 **사라졌고**, 이제 네 종류가 온다:
/// - `connected` — data 가 **방 상세 전체 JSON**(`PartyDetailResult`). 구독 직후 1회, **재연결 때마다 다시**.
/// - `member-joined` — `{"member": {publicId,nickname,imageUrl,badgeId,rideCount,host}, "status": "...", "version": N}`
/// - `member-left` — `{"publicId": "..."|null, "status": "...", "hostPublicId": "..."|null, "version": N}`
/// - `closed` — `{"partyId": N, "status": "...", "version": N}`. 파싱하지 않고 종결 신호로만 쓴다
///   (옛 서버는 partyId 숫자 문자열을 보냈다 — 어느 쪽이든 읽지 않으므로 상관없다).
///
/// `closed` 를 뺀 셋은 **방 순번 `version`** 을 싣는다. 프레임이 순서대로 온다는 보장이 없어서
/// (서버가 구독을 먼저 등록한 뒤 DB 를 읽어 `connected` 를 보낸다) 무엇이 더 최신인지 이 숫자로
/// 가린다 — 규칙은 `PartyEvent`. 옛 배포는 이 필드를 보내지 않으므로
/// **null 을 허용해야 한다**; 논-널로 받으면 그 서버에서 모든 프레임이 파싱 실패로 떨어진다.
///
/// 그리고 **30초**마다 `:ping` 주석이 온다(Backend #218 에서 5초 → 30초).
///
/// **주석으로 살아있음을 판정하지 않는다** — `ServerSentEventReader` 가 주석을 삼켜 호출부까지 오지
/// 않으므로, 앱이 알 수 있는 건 "소켓에 바이트가 흘렀다"뿐이다. 그 사실을 쓰는 곳은 세션의 **요청 타임아웃**
/// (`timeoutIntervalForRequest` — 데이터가 올 때마다 다시 잰다) 하나다: ping 이 30초마다 읽기를 깨우고,
/// 45초 안에 아무것도 오지 않으면 `URLError(.timedOut)` → 이 흐름의 재연결로 이어진다
/// (`NetworkModule.SSE_READ_TIMEOUT_SECONDS`). 그 값을 무제한으로 두면 **죽은 연결을 영원히 살아있다고
/// 믿는다** — 폴링을 끈 대기 화면이 그대로 멈추므로, 그 값을 늘려 끄지 말 것.
///
/// **파싱 실패한 프레임은 스트림을 죽이지 않는다** — 경고만 남기고 건너뛴다(`parsePartySseFrame`).
/// 서버가 이벤트 종류나 필드를 늘렸을 때 대기 화면이 통째로 멈추는 것보다, 한 프레임을 놓치고
/// 다음 재연결의 `connected` 스냅샷으로 보정되는 쪽이 낫다.
///
/// **내가 방을 나가면 서버가 이벤트 없이 스트림을 끝낸다**(`PartySseRegistry.closeMember`, 다른 기기의
/// 연결 정리용). 그때 이 흐름은 `PartySseEvent.disconnected` → `reconnectDelayMs` 뒤 재연결 →
/// 멤버가 아니라 403 → `PartyMembershipLostException`, 으로 한 번 더 두드리고 멈춘다. 보통은
/// 「그만 찾기」가 화면을 떠나며 수집을 먼저 취소하므로 그 재연결조차 일어나지 않는다.
///
/// 인증은 보통 API 와 같은 Bearer 헤더다 — `client` 는 인증 인터셉터·401 재발급이 붙은 클라이언트에
/// 읽기 타임아웃만 늘린 것이어야 한다(`NetworkModule.Apis.streamClient`).
///
/// 멤버가 아니거나(403) 방이 없으면(404) 다시 붙지 않는다 — 붙어 봐야 같은 답이다. **다만 그 둘을
/// 같은 값으로 끝내지 않는다**: 403 은 「내가 이 방 사람이 아니다」라 호출부가 **화면을 떠나야** 하는
/// 사실이고, 그래서 흐름의 정상 종료가 아니라 `PartyMembershipLostException` 으로 올린다
/// (그 예외 주석에 왜 갈라야 하는지 적어 두었다). 404 는 예전처럼 조용히 끝낸다.
///
/// 그 외 끊김은 `reconnectDelayMs` 뒤 재시도하며, 그때마다 서버가 `connected` 스냅샷을 다시 주므로
/// **호출부는 놓친 변화를 메우기 위한 catch-up 조회를 할 필요가 없다.**
///
/// **같은 partyId 로 두 번 수집하지 말 것.** 서버 `PartySseRegistry.subscribe` 가 **같은 사용자의 기존
/// 연결을 먼저 끊는다**(`closeMember`) — 한 화면이 두 번 구독하면 두 연결이 서로를 끊고, 끊긴 쪽이
/// 잠시 뒤 다시 붙으며 또 상대를 끊는 **무한 재연결**이 된다. 백오프가 그 루프를 느리게 할 뿐
/// 멈추지는 못한다(붙을 때마다 실패 횟수가 0 으로 되돌아간다) — 수집 지점은 화면당 하나여야 한다.
public final class PartyEventSource: Sendable {
    private static let logger = Logger(subsystem: "com.moyeota.data", category: "PartyEvents")

    private let baseUrl: String
    private let client: HttpClient
    private let sleep: @Sendable (Duration) async throws -> Void

    public convenience init(baseUrl: String, client: HttpClient) {
        self.init(baseUrl: baseUrl, client: client, sleep: { try await Task.sleep(for: $0) })
    }

    init(baseUrl: String, client: HttpClient, sleep: @escaping @Sendable (Duration) async throws -> Void) {
        self.baseUrl = baseUrl
        self.client = client
        self.sleep = sleep
    }

    /// 연속 실패 `failures` 회째의 재연결 대기(ms) — **네트워크 없이 테스트할 수 있는 순수 함수다.**
    ///
    /// `RECONNECT_DELAYS_MS` 표를 1회째부터 차례로 읽고, 표를 다 쓰면 마지막 값에 머문다. 거기에
    /// `RECONNECT_JITTER_RATIO` 만큼의 지터를 **더한다**(0 ≤ `jitter` ≤ 1 이 그 안에서의 위치다).
    ///
    /// `failures` 가 0 이하여도 첫 간격으로 떨어진다 — 세는 쪽이 틀려도 0ms 하드 루프가 되지 않게.
    /// **성공(`Signal.open`)하면 호출부가 횟수를 0 으로 되돌린다**(`events`) — 그러지 않으면
    /// 몇 시간 붙어 있던 연결이 한 번 끊겼을 때 30초를 기다린다.
    ///
    /// (원본은 채팅 소켓 쪽과 패키지가 달라 같은 이름의 최상위 함수다. 여기는 한 모듈이라 타입 안에 둔다.)
    static func reconnectDelayMs(failures: Int, jitter: Double = Double.random(in: 0..<1)) -> Int64 {
        let index = min(max(failures, 1) - 1, RECONNECT_DELAYS_MS.count - 1)
        let base = RECONNECT_DELAYS_MS[index]
        return base + Int64(Double(base) * RECONNECT_JITTER_RATIO * min(max(jitter, 0.0), 1.0))
    }

    public func events(partyId: Int64) -> AsyncThrowingStream<PartySseEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [self] in
                do {
                    try await run(partyId: partyId, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        partyId: Int64,
        continuation: AsyncThrowingStream<PartySseEvent, any Error>.Continuation
    ) async throws {
        // 연속 실패 횟수 — 재연결 간격의 유일한 입력이다(`reconnectDelayMs`). 붙으면 0 으로 되돌린다.
        var failures = 0
        while true {
            try Task.checkCancellation()
            var terminal = false
            var forbidden = false
            do {
                try await connect(partyId: partyId) { signal in
                    switch signal {
                    // 붙었다 = 지금까지의 실패는 지나간 일이다. 다음 끊김은 다시 첫 간격부터 센다.
                    case .open: failures = 0
                    case .event(let event): continuation.yield(event)
                    case .terminal: terminal = true
                    case .forbidden: forbidden = true
                    }
                }
            } catch {
                // 취소만 위로 흘린다. `URLError(.cancelled)` 는 태스크가 취소됐을 때만 취소다.
                if Task.isCancelled { throw CancellationError() }
                Self.logger.debug("연결 끊김 partyId=\(partyId) — 재시도 예정: \(error)")
            }
            // 403 은 **끊김이 아니다** — 내가 이 방 사람이 아니라는 사실이고, 호출부가 할 일은
            // 재시도가 아니라 화면을 떠나는 것이다. 그래서 정상 종료(아래 terminal)와 갈라
            // 예외로 올린다(`PartyMembershipLostException` 주석).
            if forbidden { throw PartyMembershipLostException(partyId: partyId) }
            if terminal { return }
            try Task.checkCancellation()
            continuation.yield(.disconnected)
            failures += 1
            let wait = Self.reconnectDelayMs(failures: failures)
            Self.logger.debug("재연결 대기 partyId=\(partyId) — \(wait)ms (연속 실패 \(failures)회)")
            try await sleep(.milliseconds(wait))
        }
    }

    private enum Signal {
        /// 연결이 섰다. **이벤트로 올리지 않는다** — 바깥 루프의 실패 횟수를 0 으로 되돌리는 데만 쓴다.
        ///
        /// 아래 `connect` 주석의 「아무것도 내지 않는다」는 **호출부로** 내지 않는다는 뜻이고 그대로다:
        /// 이 신호는 `PartyEventSource` 안에서 끝나므로 호출부가 스냅샷보다 먼저 무언가를 보는 일이 없다.
        case open

        case event(PartySseEvent)

        /// 다시 붙지 않는다 — 방이 닫혔거나(closed) 방이 없다(404)
        case terminal

        /// 403 — **내가 이 방 멤버가 아니다.** `terminal` 과 갈라 둔 이유는 `run` 안에 있다
        case forbidden
    }

    // 연결 하나의 수명. 서버가 닫거나(closed) 오류가 나면 돌아오거나 던져 바깥 루프가 이어받는다.
    private func connect(partyId: Int64, onSignal: (Signal) -> Void) async throws {
        guard let url = URL(string: "\(baseUrl)api/v1/matching/rooms/\(partyId)/events") else {
            throw IllegalArgumentException("잘못된 SSE 주소: \(baseUrl)")
        }
        var request = URLRequest(url: url)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let response = try await client.stream(request)

        // 403 과 404 를 **갈라서** 올린다. 둘 다 "다시 붙지 않는다"지만 호출부가 할 일이 다르다:
        // 404 는 방이 없어진 것(폴백 조회가 닫힘을 확인한다), 403 은 **내가 이 방 사람이 아닌 것**
        // (화면에 있을 이유가 없다). 예전엔 둘이 같은 Terminal 이라 403 이 「스트림이 끝났다」로
        // 뭉개졌고, 그 결과 내가 들어 있지 않은 방을 6초마다 영원히 폴링했다.
        switch response.code {
        case 403:
            Self.logger.debug("구독 거부 partyId=\(partyId) code=403 — 이 방의 멤버가 아니다")
            onSignal(.forbidden)
            return
        case 404:
            Self.logger.debug("구독 거부 partyId=\(partyId) code=404 — 방이 없다. 다시 붙지 않는다")
            onSignal(.terminal)
            return
        default:
            break
        }
        guard response.isSuccessful, let bytes = response.bytes else {
            throw IllegalStateException("SSE 실패 code=\(response.code)")
        }

        try await withTaskCancellationHandler {
            // 어느 길로 나가든 연결을 닫는다 — `closed` 를 받고 빠져나올 때 서버가 닫기를 기다리지 않는다.
            defer { bytes.task.cancel() }

            // okhttp-sse 와 같다: 2xx 라도 SSE 가 아니면 붙은 것으로 치지 않는다(프록시의 HTML 200 등).
            let contentType = response.header("Content-Type")
            guard isEventStream(contentType: contentType) else {
                throw IllegalStateException("Invalid content-type: \(contentType ?? "null")")
            }

            // 호출부에는 아무것도 내지 않는다 — 상태를 싣고 오는 건 바로 뒤에 올 `connected` 프레임이다.
            // 예전처럼 여기서 **이벤트**를 내면 스냅샷이 오기 전에 호출부가 상세를 한 번 더 읽는다.
            // `Signal.open` 은 바깥 루프의 실패 횟수를 되돌리는 내부 신호라 호출부까지 가지 않는다.
            Self.logger.debug("연결됨 partyId=\(partyId)")
            onSignal(.open)

            var reader = ServerSentEventReader()
            for try await byte in bytes {
                guard let event = reader.read(byte) else { continue }
                switch parsePartySseFrame(type: event.type, data: event.data) {
                case .received(let received):
                    onSignal(.event(received))
                    // 방이 닫히면 서버가 곧 연결을 끊는다 — 다시 붙지 않는다
                    if received == .closed {
                        onSignal(.terminal)
                        return
                    }
                case .skipped(let reason):
                    // 깨진·모르는 프레임 하나로 스트림을 끝내지 않는다
                    Self.logger.warning("프레임 건너뜀 partyId=\(partyId) — \(reason)")
                }
            }
        } onCancel: {
            bytes.task.cancel()
        }
    }

    /// okhttp-sse `isEventStream` — 파라미터(`;charset=UTF-8`)와 대소문자를 무시하고 type/subtype 만 본다.
    private func isEventStream(contentType: String?) -> Bool {
        guard let contentType else { return false }
        let mediaType = contentType.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return mediaType.trimmingCharacters(in: .whitespaces).lowercased() == "text/event-stream"
    }
}
