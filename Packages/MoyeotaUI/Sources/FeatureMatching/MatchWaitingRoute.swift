import MoyeotaDesignSystem
import MoyeotaDomain
import Observation
import os
import PresentationCore
import SwiftUI

/// **화면이 보이고, SSE 가 끊긴 동안에만** 도는 폴백 폴링 간격.
///
/// 가시성 조건은 나중에 붙었다(`fallbackPollStep`). 예전에는 이 루프가 뷰모델 수명에만 묶여 있어서
/// 앱을 내려놓아도 돌았고, 그때 OS 가 네트워크를 조여 SSE 가 죽으면 **3초 재연결 ↔ 6초 폴백**이 서로
/// 틈을 메우며 되풀이됐다(QA 123 D-3: 백그라운드 75초에 9건 — `/events` 5 + 상세 4, 분당 약 7건).
///
/// 평상시 이 화면은 서버를 **주기적으로 부르지 않는다** — 방 상태는 SSE 변경분
/// (`RideRepository.observePartyEvents`)이 전해 준다. 그래도 폴백을 남긴 이유는 그 스트림이
/// **best-effort** 라서다: 서버가 커밋 후 단일 스레드 큐로 발행하고 실패해도 재발행하지 않으며
/// (Redis Pub/Sub 도 at-most-once), `text/event-stream` 을 막는 망·프록시도 있다.
/// 그래서 정책은 채팅 소켓과 같다 — **살아 있으면 0회, 죽었을 때만.**
///
/// 예전(4초)보다 느슨한 이유: 지문(fingerprint)과 가벼운 상태 조회 `GET /rooms/{id}/status` 가
/// 서버에서 사라져(Backend #221) 「바뀌었나」를 싸게 묻는 길이 없다. 폴백 수단은 서버 쿼리 3개에 경로
/// 폴리라인까지 실려 오는 **방 상세 하나**뿐이라, 같은 간격을 유지하면 부하가 3배가 된다.
///
/// 그래서 값은 25·26 이 쓰는 상세 폴링의 **공통 하한**(`PARTY_DETAIL_POLL_FLOOR_MS`)에 맞춘다 — 그 아래로
/// 내리면 옛 구조보다 부하가 커진다. 21 은 그 두 화면과 달리 **끊긴 동안에만** 도므로 하한을 그대로 쓰고 더
/// 늦추지는 않는다: 끊긴 상태에서는 이게 유일한 갱신 수단이라, 들고 나는 사람이 보이기까지의 지연이 그만큼 길어진다.
let PARTY_FALLBACK_POLL_INTERVAL_MS: Int64 = 6_000

private let logger = Logger(subsystem: "com.moyeota.presentation", category: "MatchWaiting")

/// `collectLatest` 의 자리 — 새 값이 오면 앞 패스를 **취소하고 끝날 때까지 기다린 뒤**(`cancelAndJoin`) 다음 패스를 시작한다.
/// 그래서 어느 순간에도 살아 있는 패스는 0개 또는 1개다. 호출자가 취소되면 `for await` 가 끝나고 진행 중인 패스도 함께 멈춘다.
@MainActor
func collectLatest<Value: Sendable>(
    _ stream: AsyncStream<Value>,
    _ pass: @escaping @MainActor (Value) async -> Void
) async {
    var running: Task<Void, Never>?
    for await value in stream {
        running?.cancel()
        await running?.value
        running = Task { @MainActor in await pass(value) }
    }
    running?.cancel()
    await running?.value
}

@MainActor
@Observable
public final class MatchWaitingViewModel {
    public enum UiState: Equatable, Sendable {
        case loading
        case success(ride: Ride)
        case error(message: String)
    }

    /// 액션 결과. 「그만 찾기」(left)와 1차 배포 모드의 「합승 완료」(finished) — 둘 다 성공하면 방을 떠난다.
    /// 준비/매칭 시작은 백엔드에서 삭제됐다.
    public struct ActionState: Equatable, Sendable {
        public var inProgress: Bool
        public var errorMessage: String?
        public var left: Bool
        public var finished: Bool

        public init(
            inProgress: Bool = false,
            errorMessage: String? = nil,
            left: Bool = false,
            finished: Bool = false
        ) {
            self.inProgress = inProgress
            self.errorMessage = errorMessage
            self.left = left
            self.finished = finished
        }
    }

    /// `combine(visible, _partyClosed, streamEnded, _membershipLost)` 의 자리 — 폴백 패스를 다시 평가하게 하는 입력 넷.
    private struct FallbackInputs: Equatable, Sendable {
        var visible = true
        var partyClosed = false
        var streamEnded = false
        var membershipLost = false
    }

    public private(set) var uiState: UiState = .loading

    public private(set) var actionState = ActionState()

    /// 서버가 **방이 닫혔다**고 알려 왔다(`PartyEvent.closed`). 누가 닫았는지(합승 완료·30분 만료·
    /// 마지막 멤버 이탈)는 화면 동작이 같아 구분하지 않는다 — Route 가 받아 홈으로 보낸다.
    ///
    /// 확인용 상세 재조회를 하지 않는다: 서버는 이 신호 뒤에 구독을 끊고, 닫힌 방을 한 번 더 읽어도
    /// 「닫혔다」는 사실만 다시 확인할 뿐이다(예전에는 FINISHED/CANCELED 를 상세로 읽어 와야 알았다).
    public private(set) var partyClosed = false

    /// **나는 이 방의 멤버가 아니다** — 「방이 닫혔다」(`partyClosed`)와 **다른 사실**이고, 사용자가
    /// 할 일은 같다(이 화면에 있을 이유가 없다). Route 가 받아 홈으로 보낸다.
    ///
    /// 두 가지 근거로 선다.
    /// 1. **SSE 403** `NOT_PARTY_MEMBER`(`PartyMembershipLostException`) — 서버가 멤버십을 말해 주는
    ///    **유일한 창구**다. 방 상세(`GET /matching/rooms/{id}`)에는 참여자 검사가 없어 멤버가 아니어도
    ///    조회가 계속 성공한다.
    /// 2. **상세의 members 에 내가 없다**(`hasLostMembership`) — SSE 가 아예 붙지 않는 망(프록시가
    ///    `text/event-stream` 을 막는 경우)에서는 1번 창구가 열리지 않으므로 폴백 조회로 한 번 더 본다.
    ///
    /// 이 값이 없던 동안 403 은 「스트림이 끝났다」와 똑같이 뭉개졌고, 그러면 폴백 폴링이 **내가 들어
    /// 있지 않은 방**을 6초마다 영원히 읽으면서 「같이 탈 사람을 찾고 있어요」를 띄웠다. 거기서
    /// 「그만 찾기」를 눌러도 다시 403 이라 **벗어날 길이 없었다.**
    ///
    /// `partyClosed` 와 합치지 않는 이유: 저 값은 서버가 보낸 `closed` 신호라는 **사실**이고, 닫히지
    /// 않은 방을 닫혔다고 적으면 그 값을 읽는 쪽(폴백 종료 조건)의 뜻이 흐려진다.
    public private(set) var membershipLost = false

    private let repository: any RideRepository
    private let partyId: Int64
    /// 폴백 주기의 대기. 테스트가 시간을 제어할 수 있게 주입한다.
    private let sleep: @Sendable (Duration) async throws -> Void
    private let scope = ViewModelScope()

    /// SSE 가 살아 있는가 — `PartyEvent.snapshot` 을 받으면 true, `PartyEvent.disconnected` 와
    /// 스트림 종료·구독 취소에서 false. **폴백 폴링이 이번 주기에 읽을지의 스위치다**(`shouldPollFallback`).
    @ObservationIgnored private var realtimeAlive = false

    /// 화면이 지금 **보이는가** — SSE 구독(`observeEvents`)과 폴백 폴링(`observeFallbackPolling`)의
    /// **공통 스위치**다. 보이지 않으면 둘 다 멈추고, 돌아오면 둘 다 다시 붙는다.
    ///
    /// ### 왜 끊어도 안전한가 ★
    /// 재연결할 때마다 서버가 `connected` 로 **방 상세 전체**를 다시 준다(`PartyEvent.snapshot`).
    /// 그래서 가려진 동안 끊고 있다가 복귀해 다시 붙으면 **그 순간 상태가 통째로 맞춰진다** — 끊긴 사이의
    /// 변화를 따라잡는 catch-up 조회가 필요 없다. 이것이 이번 SSE 설계의 핵심이고(`117` §2 표의 1번 근거),
    /// 이 게이트가 성립하는 근거다. 증분(`member-joined`/`member-left`)은 바탕이 있을 때만 쓰는 값이라
    /// 「놓친 증분」을 복원할 필요도 없다 — 바탕 자체가 새로 온다.
    ///
    /// ### 왜 끊는 게 이득인가
    /// 보이지 않는 동안 SSE 를 유지해도 **사용자가 얻는 것이 없다**: 알림은 푸시가 띄우는데 **멤버 합류에는
    /// 푸시가 없고**, 화면도 보이지 않는다. 반대로 비용은 확실하다 — 앱을 내려놓으면 OS 가 네트워크를 조여
    /// SSE 가 죽고, 3초 뒤 재연결하고, 그 틈을 6초 폴백이 메우고, 다시 죽는다
    /// (QA 123 D-3 실측: 백그라운드 **75초에 9건**, 분당 약 7건).
    ///
    /// ### 기본값이 true 인 이유
    /// 이 값을 내려 주는 배선(`onScreenStart`·`onScreenStop`)은 Route 에 있다. 기본값을 false 로 두면
    /// 배선이 빠진 채 머지됐을 때 **방 상태가 영영 갱신되지 않는** 기능 손실이 된다 — true 면 최악이
    /// 「고쳐지지 않은 상태 유지」다(`ActivePartyViewModel` 의 `hostVisible` 가 같은 이유로 true 다).
    ///
    /// 플래그가 아니라 `MutableStateFlow` 인 이유는 **수집과 같은 흐름에 묶기** 위해서다: `collectLatest`
    /// 가 가려지는 순간 진행 중인 구독·조회와 대기를 **함께** 취소하고, 다시 보이면 같은 패스를 새로
    /// 시작한다(17 탐색 `ExploreViewModel.visible` 과 같은 모양).
    private let visible = MutableStateFlow(true)

    /// 폴백 패스의 입력(`visible`·방 닫힘·`streamEnded`·멤버십 상실).
    ///
    /// **`streamEnded` 는 SSE 스트림이 종결로 끝났다**는 값이다 — 방 닫힘(`closed`)·404(방 없음), 또는 스트림
    /// 자체가 없는 저장소(더미). 그 밖의 끊김은 데이터 계층이 백오프 뒤 스스로 다시 붙으므로 여기까지 오지 않는다.
    ///
    /// **403(멤버 아님)도 `streamEnded` 를 세우지만 그것만으로 끝나지 않는다** — `membershipLost` 가 함께 서고,
    /// 그쪽이 화면을 떠나게 한다. 둘을 같은 값으로 뭉개면 「내가 없는 방」을 영원히 폴링한다.
    ///
    /// 가시성 게이트가 **되살려야 하는 것과 그러면 안 되는 것**을 가르는 값이다: 가려져서 취소된 구독은
    /// 복귀 때 다시 붙지만, 종결로 끝난 구독은 다시 붙어도 같은 답이라 붙지 않는다(게이트 이전 동작과 동일).
    ///
    /// **평범한 변수가 아닌 이유**: 폴백 루프의 입력이라서다. 평범한 변수면 가려진 사이에 스트림이
    /// 끝나도 복귀 패스가 그 사실을 모른 채 확정돼, 다시 붙을 스트림이 없는데도 6초를 기다린다.
    private let fallbackInputs = MutableStateFlow(FallbackInputs())

    /// 폴백 루프가 **제 할 일을 끝냈다** — 방이 대기 단계를 벗어났다(`isWaitingForMembers` false:
    /// 배차 시작·방 종료).
    ///
    /// 게이트를 넣었다고 끝난 루프가 되살아나면 회귀다. 가시성은 「멈췄다 다시 켜는」 스위치지만
    /// 이 값은 「끝났다」는 사실이라 복귀로 되돌아가지 않는다.
    @ObservationIgnored private var fallbackDone = false

    /// 실시간 이벤트를 화면에 반영한 횟수. 값 자체에는 뜻이 없고, **상세 조회가 늦게 도착해**
    /// 더 새로운 실시간 상태를 과거로 되돌리는 걸 막는 표식으로만 쓴다(`readDetail`).
    @ObservationIgnored private var appliedEvents = 0

    /// 화면이 반영한 가장 마지막 **방 순번**(`PartyEvent` 의 표).
    ///
    /// `appliedEvents` 와 역할이 다르다 — 저건 "내가 몇 번 반영했나"(늦은 조회 결과를 버리는 표식)고,
    /// 이건 "서버 기준 어디까지 봤나"다. 프레임 순서가 뒤집혀 도착하는 걸 가려내는 유일한 근거다.
    ///
    /// **끊겨도 지우지 않는다.** 재연결 스냅샷이 들고 있던 것보다 낮을 때 버리려면 남아 있어야 한다.
    /// nil 은 "아직 모른다"(첫 연결 전) 또는 "서버가 말하지 않는다"(옛 배포) 둘 다를 뜻하고,
    /// 어느 쪽이든 순서를 가릴 수 없으니 예전 완화 규칙으로 떨어진다.
    @ObservationIgnored private var heldVersion: Int64?

    /// 서버가 준 멤버 목록에서 **나를 한 번이라도 봤는가**(`User.isMe` 가 true 인 멤버).
    ///
    /// `hasLostMembership` 의 전제다. 이 플래그 없이 「목록에 내가 없다」만 보면 **내가 누군지 모르는
    /// 경우까지 멤버십 상실로 읽는다**: `isMe` 는 `publicId == 세션 uuid` 비교라, 세션 uuid 가 없으면
    /// (미로그인·복원 전) 아무도 나로 표시되지 않아 목록이 정상이어도 「없다」가 참이 된다. 그러면
    /// **멀쩡히 방에 들어 있는 사용자를 쫓아낸다** — 틀렸을 때의 대가가 한쪽으로 크게 기울어 있으므로,
    /// 「나를 본 적이 있다」는 증거가 생긴 뒤에만 그 판정을 켠다.
    @ObservationIgnored private var sawMyself = false

    public init(
        repository: any RideRepository,
        partyId: Int64,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.repository = repository
        self.partyId = partyId
        self.sleep = sleep
        refresh()
        observeEvents()
        observeFallbackPolling()
    }

    /// 화면이 보이기 시작했다 — **즉시 재구독**하고 폴백 폴링을 재개한다.
    ///
    /// 이 길로 오는 것: 첫 진입, 앱 복귀, 위에 올라와 있던 화면(22 상세·24 채팅방)의 pop.
    ///
    /// **즉시성**: 재구독이 곧 스냅샷이다. 패스가 다시 시작되는 순간 연결이 나가고, 서버가
    /// `connected` 에 방 상세 전체를 실어 주므로 6초 폴백 주기를 기다리는 구간이 없다(17 탐색은 같은
    /// 구조에서 복귀 첫 조회가 58ms 였다 — QA 123 A3).
    public func onScreenStart() {
        setVisible(true)
    }

    /// 화면이 가려졌다 — SSE 구독과 폴백 폴링을 **함께** 멈춘다.
    ///
    /// 이 길로 오는 것: 위에 다른 화면이 올라옴(22 상세·24 채팅방), 앱 백그라운드.
    ///
    /// 들고 있던 방 상태는 **건드리지 않는다.** 돌아올 때 보던 화면을 먼저 보여주고 스냅샷으로 덮는 것이
    /// 맞고, 로딩으로 깜빡이게 할 이유가 없다.
    public func onScreenStop() {
        setVisible(false)
    }

    private func setVisible(_ shown: Bool) {
        visible.value = shown
        fallbackInputs.update { inputs in
            var next = inputs
            next.visible = shown
            return next
        }
    }

    /// 첫 진입과 에러 화면의 「다시 시도」 — **주기 폴링이 아니라 1회 조회**다.
    ///
    /// SSE 첫 스냅샷과 경쟁하지만 먼저 온 쪽으로 그리고 늦게 온 조회 결과는 버린다(`readDetail`).
    /// 이 1회를 남겨 둔 이유는 스트림이 **실패를 말해 주지 않기** 때문이다: 403/404 면 조용히 끝나고
    /// 그 밖의 실패는 저장소가 재연결로 삼킨다. 조회가 없으면 에러 화면과 「다시 시도」를 띄울 근거가 없고,
    /// 스트림이 없는 저장소(더미)에서는 영원히 로딩이다.
    ///
    /// **왕복 동안 뷰모델을 잡지 않는다.** 조회는 `readDetail` 과 같지만 그 함수를 부르면 호출 내내 `self` 가
    /// 살아 있어, 화면을 떠나도 해제되지 않고 스코프 취소도 오지 않는다(원본 `viewModelScope` 는 이때 조회를 끊는다).
    public func refresh() {
        // 이미 실시간 상태가 떠 있으면 로딩으로 덮지 않는다(스냅샷이 먼저 온 경우)
        if !hasRide { publish(.loading) }
        let repository = self.repository
        let partyId = self.partyId
        scope.launch { [weak self] in
            guard let mark = self?.appliedEvents else { return }
            let detail = try? await repository.getPartyDetailWithVersion(partyId: partyId)
            guard let self else { return }
            if let detail {
                self.applyDetail(detail, mark: mark)
            } else if !self.hasRide {
                self.publish(.error(message: "매칭 정보를 불러오지 못했어요"))
            }
        }
    }

    /// 방 상태의 **주 경로** — SSE 변경분 구독(`RideRepository.observePartyEvents`).
    ///
    /// **화면이 보이는 동안에만 구독한다**(`visible`) — 가려지면 끊고, 돌아오면 다시 붙는다. 끊어도
    /// 안전한 근거(재연결 = 스냅샷 = 상태 전체 재동기)는 `visible` 의 주석에 적어 두었다.
    ///
    /// ⚠️ 수집 지점은 이 화면에서 **여기 하나뿐이어야 한다.** 서버는 같은 사용자의 기존 구독을 끊고 새 연결을
    /// 받으므로(`PartySseRegistry.closeMember`), 같은 방을 두 곳에서 수집하면 두 연결이 서로를 끊고 3초마다
    /// 번갈아 재연결하는 무한 루프가 된다. 그래서 `init` 에서 **한 번만** 걸고 뷰모델이 사는 동안 그 하나를
    /// 유지한다 — 뷰의 `.task` 로 다시 걸지 않는다.
    ///
    /// 가시성 게이트가 그 성질을 깨지 않는 이유: `collectLatest` 는 새 값을 받으면 **앞 패스를 취소하고
    /// 끝날 때까지 기다린 뒤** 다음 패스를 시작한다. 앞 패스가 끝난다는 건 스트림의 `onTermination` 까지
    /// 돌았다는 뜻이라, 어느 순간에도 **살아 있는 수집은 0개 또는 1개**다. 가시성이 빠르게 토글돼도 두 수집이
    /// 겹치지 않는다.
    ///
    /// **스냅샷이 먼저 온다는 보장은 없다.** 서버는 구독을 레지스트리에 먼저 등록한 뒤 DB 를 읽어
    /// `connected` 를 보내므로, 그 사이에 커밋된 변경분이 스냅샷보다 **먼저** 도착할 수 있다
    /// (`PartySseController`: "연결 중에 방이 바뀌면 변경분이 connected 보다 먼저 올 수 있다").
    /// 그래서 프레임마다 실려 오는 순번으로 순서를 가린다 — `deltaVerdict`·`acceptsSnapshot`.
    /// 가시성 때문에 끊었다 붙는 것도 서버 입장에선 똑같은 재연결이고, 그때도 같은 판정이 걸린다.
    ///
    /// 수집이 **스스로** 끝나는 건 종결뿐이다(방 닫힘·404 방 없음). 그때는 다시 붙어도 같은 답이라
    /// 복귀해도 붙지 않고(`streamEnded`) 폴백이 갱신을 맡는다 — 내가 방을 나간 경우라면 Route 가
    /// 이미 화면을 떠났고 수집도 함께 취소된다.
    ///
    /// **403 멤버 아님은 그 종결에 섞이지 않는다** — 데이터 계층이 `PartyMembershipLostException` 으로
    /// 올리고, 여기서 받아 `membershipLost` 를 세운다. 그러면 폴백도 멈추고 Route 가 화면을 떠난다.
    ///
    /// 패스는 대기하는 동안 뷰모델을 강하게 잡지 않는다 — 잡으면 화면을 떠나도 해제되지 않아 연결이 남는다.
    private func observeEvents() {
        let visible = self.visible
        let repository = self.repository
        let partyId = self.partyId
        scope.launch { [weak self] in
            await collectLatest(visible.values()) { [weak self] shown in
                let ended = self?.fallbackInputs.value.streamEnded ?? true
                if !shouldObservePartyEvents(visible: shown, streamEnded: ended) { return }
                do {
                    for try await event in repository.observePartyEvents(partyId: partyId) {
                        await self?.applyEvent(event)
                    }
                    // 수집이 취소돼도 `for try await` 는 오류 없이 끝나 이 자리로 내려온다(원본 collect 는
                    // CancellationException 을 던져 여기를 지나지 않는다). 그래서 먼저 취소를 가려낸다 —
                    // 그래야 가려져서 끊긴 구독이 종결로 적히지 않고 복귀 때 다시 붙는다.
                    try Task.checkCancellation()
                    // 여기까지 왔으면 스트림이 **종결**로 끝났다.
                    self?.markStreamEnded()
                } catch is PartyMembershipLostException {
                    // 403 `NOT_PARTY_MEMBER` — 끊긴 게 아니라 **내가 이 방 사람이 아니다**.
                    // 다시 붙어 봐야 같은 답이라 종결로 적되(streamEnded), 「스트림이 끝났다」와 갈라
                    // 화면을 떠나게 한다. 순서가 중요하다: 상실을 먼저 세워야 폴백 패스가 다시
                    // 평가될 때 READ_NOW 를 거치지 않고 곧바로 STOP 으로 떨어진다.
                    self?.markMembershipLost()
                    self?.markStreamEnded()
                } catch {
                    // 태스크 취소는 복귀 때 다시 붙는 정상 경로다. 그 밖의 오류는 데이터 계층이 내지 않는다(끊김은
                    // 스스로 재연결한다). 혹시 오면(살아 있는 태스크의 `URLError(.cancelled)` 포함) 앱을 죽이지 않고
                    // 폴백 폴링에 맡긴다(realtimeAlive 가 내려간다).
                    if !Task.isCancelled {
                        logger.warning("SSE 수집이 예상 밖 오류로 끝났다: \(String(describing: error))")
                    }
                }
                // 종결이든 취소든 실시간 근거가 사라진다. 취소된 뒤에도 true 로 남겨 두면 복귀해서
                // 재연결이 실패했을 때 폴백이 영영 돌지 않아 화면이 멈춘다.
                self?.realtimeAlive = false
            }
        }
    }

    /// 이벤트 하나를 화면 상태로 옮긴다 — **상세 재조회 없이**.
    ///
    /// | 이벤트 | 하는 일 |
    /// |---|---|
    /// | `PartyEvent.snapshot` | 들고 있던 방을 **통째로 교체**(가장 신뢰할 수 있는 값) · 폴백 끔 |
    /// | `PartyEvent.memberJoined` | 멤버 목록에 더하고(같은 publicId 는 교체) status 갱신 (`Ride.withMemberJoined`) |
    /// | `PartyEvent.memberLeft` | publicId 로 제거 + status 갱신 + **방장 승계 반영** (`Ride.withHostSuccession`) |
    /// | `PartyEvent.closed` | 닫힘 신호만 세운다 → Route 가 홈으로 |
    /// | `PartyEvent.disconnected` | 폴백 폴링 켬. 상태는 **그대로 둔다** — 곧 올 스냅샷이 보정한다 |
    ///
    /// 상세 1회 조회가 붙는 경우는 둘이다 — **누가 나갔는지 모를 때**(publicId nil)와, 서버가 지목한
    /// **방장이 내 목록에 없을 때**(`RideDelta.needsDetail` — 서버 계약이 그렇게 하라고 적어 두었다).
    private func applyEvent(_ event: PartyEvent) async {
        switch event {
        case .snapshot(let ride, let version):
            // 버리는 경우에도 연결은 살아 있다 — realtimeAlive 는 세운다(폴백이 끼어들면 안 된다).
            realtimeAlive = true
            if acceptsSnapshot(held: heldVersion, incoming: version) {
                heldVersion = version ?? heldVersion
                appliedEvents += 1
                rememberMyself(ride)
                publish(.success(ride: ride))
            }
        // member 의 isMe 는 상세와 같은 근거(publicId == 세션 uuid)로 이미 채워져 온다 — 다시 판정하지 않는다
        // 합류는 방장을 바꿀 수 없어 승계 판정이 없다 — 변경분을 그대로 싣는다(needsDetail = false)
        case .memberJoined(let member, let status, let version):
            switch deltaVerdict(held: heldVersion, incoming: version) {
            case .drop:
                break
            case .resync:
                await readDetail()
            case .apply:
                heldVersion = version ?? heldVersion
                await applyDelta { RideDelta(ride: $0.withMemberJoined(member: member, status: status)) }
            }
        case .memberLeft(let publicId, let status, let hostPublicId, let version):
            switch deltaVerdict(held: heldVersion, incoming: version) {
            case .drop:
                break
            // 틈이다 — 지울 사람을 특정해도 중간 프레임을 모르니 상세를 믿는다. 다만 승계는 먼저
            // 반영한다(publicId nil 경로와 같은 이유: 상세 읽기가 실패하면 이게 유일한 승계 근거다).
            case .resync:
                applyStatus(status: status, hostPublicId: hostPublicId)
                await readDetail()
            case .apply:
                heldVersion = version ?? heldVersion
                await applyMemberLeft(publicId: publicId, status: status, hostPublicId: hostPublicId)
            }
        case .closed:
            realtimeAlive = false
            markPartyClosed()
        case .disconnected:
            realtimeAlive = false
        }
    }

    /// `PartyEvent.memberLeft` 를 순서 판정 **뒤에** 실제로 반영한다.
    private func applyMemberLeft(publicId: String?, status: RideStatus, hostPublicId: String?) async {
        if let publicId {
            await applyDelta { $0.withMemberLeft(publicId: publicId, status: status, hostPublicId: hostPublicId) }
        } else {
            // 누가 나갔는지 서버도 모른다 — 지울 멤버를 특정할 수 없으니 상세를 읽는다.
            // 그래도 **승계는 먼저 반영한다**: 상세 읽기가 실패하면 이 프레임이 유일한 승계 근거다
            // (서버는 member-left 를 다시 보내지 않는다). 이 경로는 아래 readDetail 이 **무조건**
            // 돌므로 승계 쪽 needsDetail 을 따로 볼 필요가 없다 — 서버 계약의 「다시 받는다」가 이미 지켜진다.
            applyStatus(status: status, hostPublicId: hostPublicId)
            await readDetail()
        }
    }

    /// 변경분을 들고 있는 방에 적용한다. 바탕이 없으면(로딩·에러) 적용할 대상이 없어 상세를 1회 읽는다 —
    /// 증분은 **바탕이 있을 때만** 쓸 수 있다.
    ///
    /// 적용 결과가 `needsDetailAfterDelta` 면 상세를 1회 읽어 서버 쪽으로 맞춘다 — 사유는 둘이고
    /// (방장 지목을 못 맞췄다 / 목록이 status 와 모순이다) 처방이 같다. 그때는 **목록이 아니라 서버를
    /// 믿는다**. 주기 호출이 아니라 그 순간 1회이며, 읽어 온 결과에는 이 검사를 다시 걸지 않으므로
    /// (읽기 결과는 `readDetail` 이 `UiState.success` 로 직접 세운다) **되돌이가 되지 않는다** —
    /// 프레임 하나당 추가 조회는 최대 1건이다.
    private func applyDelta(_ transform: (Ride) -> RideDelta) async {
        guard let held = heldRide else {
            await readDetail()
            return
        }
        let delta = transform(held)
        appliedEvents += 1
        publish(.success(ride: delta.ride))
        if needsDetailAfterDelta(delta: delta) { await readDetail() }
    }

    /// 멤버 **목록**은 그대로 두고 서버가 준 status 와 방장 승계만 반영한다 — 지울 멤버를 특정할 수
    /// 없을 때(publicId nil)의 경로다. 목록은 못 고쳐도 `Ride.withHostSuccession` 은 publicId 로
    /// 이름을 불린 한 명만 보므로 그대로 적용할 수 있다(그 사람이 목록에 없으면 표시를 손대지 않는다).
    ///
    /// `RideDelta.needsDetail` 을 **여기서 보지 않는다**: 이 경로의 호출부가 곧바로 `readDetail` 을
    /// 부르므로 서버 계약의 「목록에 없으면 방 상세를 다시 받는다」가 이미 지켜진다. 여기서 또 읽으면
    /// 같은 프레임에 상세가 2건 나간다.
    private func applyStatus(status: RideStatus, hostPublicId: String?) {
        guard let held = heldRide else { return }
        appliedEvents += 1
        var next = held.withHostSuccession(hostPublicId: hostPublicId).ride
        next.status = status
        publish(.success(ride: next))
    }

    /// 방 상세를 1회 읽어 화면에 반영한다. 돌려주는 값은 **읽기 성공 여부**다(에러 화면 판단용).
    ///
    /// 읽는 동안 실시간 이벤트가 반영됐으면(`appliedEvents` 가 달라졌으면) 결과를 **버린다** — 왕복이 느릴 때
    /// 늦게 도착한 조회 결과가 더 새 실시간 상태를 과거로 되돌리는 걸 막는다. 실패는 조용하다
    /// (다음 이벤트·다음 폴백 주기가 메운다).
    ///
    /// 취소도 원본 `runCatching` 처럼 false 로 돌려준다. 호출부가 취소를 따로 다룰 일이 없다 — 폴백 루프는 다음
    /// 대기에서, 구독 패스는 `Task.checkCancellation` 에서 멈춘다. `refresh` 는 뷰모델이 살아 있는 동안 취소되지 않는다.
    ///
    /// 내용이 똑같은 상세를 다시 흘려 넣어도 재구성은 일어나지 않는다 — `publish` 가 같은 값이면 쓰지 않는다
    /// (25·26 이 `shouldPublishDetail` 로 명시해 둔 것과 같은 절약이다).
    ///
    /// **읽어 온 목록에서 내가 사라졌는지도 여기서 본다**(`hasLostMembership`). SSE 403 이 같은 사실을
    /// 먼저 말해 주지만, 그 스트림이 아예 붙지 않는 망에서는 이 조회가 **유일한 창구**다 — 방 상세에는
    /// 참여자 검사가 없어 멤버가 아니어도 200 이 오므로, 보지 않으면 내가 없는 방을 계속 그린다.
    /// 판정은 **버려진 결과에도** 적용한다: 멤버십은 순번과 무관한 사실이고, 늦게 온 응답이라고
    /// 「내가 그 방에 없다」가 뒤집히지는 않는다.
    @discardableResult
    private func readDetail() async -> Bool {
        let mark = appliedEvents
        let detail: PartyDetail
        do {
            detail = try await repository.getPartyDetailWithVersion(partyId: partyId)
        } catch {
            return false
        }
        applyDetail(detail, mark: mark)
        return true
    }

    /// 읽어 온 상세를 반영한다. `mark` 는 **읽기 시작할 때의** `appliedEvents` 다(`readDetail` 주석).
    private func applyDetail(_ detail: PartyDetail, mark: Int) {
        rememberMyself(detail.ride)
        if hasLostMembership(sawMyself: sawMyself, ride: detail.ride) { markMembershipLost() }
        // 가드가 둘인 이유가 다르다: appliedEvents 는 **내 반영**이 끼어들었는지(왕복 지연), acceptsSnapshot 은
        // 읽어 온 상세가 **서버 기준으로** 과거인지(순서 역전). 둘 중 하나만으로는 각자의 경우를 못 막는다.
        if appliedEvents == mark && acceptsSnapshot(held: heldVersion, incoming: detail.version) {
            heldVersion = detail.version ?? heldVersion
            publish(.success(ride: detail.ride))
        }
    }

    /// 서버가 준 멤버 목록에 내가 있었다는 사실을 기록한다 — `hasLostMembership` 의 전제(`sawMyself`).
    ///
    /// 한 번 true 가 되면 되돌리지 않는다. 「전에는 있었는데 지금은 없다」가 바로 상실의 정의다.
    private func rememberMyself(_ ride: Ride) {
        if ride.members.contains(where: { $0.isMe }) { sawMyself = true }
    }

    /// 끊긴 동안의 **폴백** 폴링 — 그리고 **화면이 보이는 동안에만**.
    ///
    /// 판정이 두 층이다. 섞지 않는 이유는 보는 값의 수명이 다르기 때문이다.
    ///
    /// | 함수 | 묻는 것 | 언제 바뀌나 |
    /// |---|---|---|
    /// | `fallbackPollStep` | 루프를 **돌릴지 / 첫 조회를 미룰지** | 가시성·방 닫힘·루프 종료 (패스 단위) |
    /// | `shouldPollFallback` | 이번 주기에 **읽을지** | SSE 생사·화면에 방이 있는지 (주기 단위) |
    ///
    /// SSE 가 살아 있고 화면에 방이 떠 있으면 **한 번도 서버를 부르지 않는다**(평상시 0회). 거기에
    /// 가시성이 더해져, 가려진 동안에는 **깨어나 아무 일도 안 하는 주기조차 남지 않는다** — `collectLatest`
    /// 가 진행 중인 조회와 대기를 함께 취소한다(17 탐색 `ExploreViewModel.observeRequests` 와 같은 모양).
    ///
    /// 폴백 수단은 방 상세뿐이다 — 지문과 `GET /rooms/{id}/status` 가 서버에서 사라져(Backend #221)
    /// 「바뀌었나」를 싸게 묻는 길이 없다. 대신 상세를 **통째로 교체**하는 건 스냅샷과 같은 처리라 멱등하고,
    /// 내용이 같으면 `publish` 가 쓰지 않으므로 재구성도 일어나지 않는다.
    ///
    /// **기존 종료 조건은 그대로다.** 방이 닫히면(`partyClosed`) 루프가 끝나고, 방이 대기 단계를 벗어나면
    /// (`isWaitingForMembers` false) 폴백이 끝난다(`fallbackDone`) — 둘 다 복귀로 되살아나지 않는다.
    /// 화면 이동은 Route 의 `.task` 가 맡고, 조회 실패는 조용히 다음 주기를 기다린다.
    private func observeFallbackPolling() {
        let inputs = fallbackInputs
        let sleep = self.sleep
        scope.launch { [weak self] in
            // streamEnded 가 입력인 이유: 가려진 사이에 스트림이 종결되면(방 닫힘·404)
            // 복귀 때 다시 붙을 스트림이 없다. 평범한 변수로 두면 패스가 이미 WAIT_THEN_READ 로
            // 확정된 뒤라 READ_NOW 가 영영 타지 않고, 그 전이가 늘 6초 늦는다(QA 125 D-2).
            //
            // membershipLost 도 같은 이유로 입력이다 — 403 은 streamEnded 와 **같은 순간**에 서지만,
            // 평범한 변수로 읽으면 그 값이 바뀌어도 패스가 다시 평가되지 않아 「내가 없는 방」을
            // 6초마다 계속 읽는다. 판정을 입력으로 끌어올려 상실이 서는 즉시 루프가 죽게 한다.
            await collectLatest(inputs.values()) { [weak self] input in
                guard let done = self?.fallbackDone else { return }
                let step = fallbackPollStep(
                    visible: input.visible,
                    partyClosed: input.partyClosed,
                    fallbackDone: done,
                    streamEnded: input.streamEnded,
                    membershipLost: input.membershipLost
                )
                if step == .stop { return }
                do {
                    // 평상시(WAIT_THEN_READ)는 첫 주기를 그대로 기다린다 — 복귀의 갱신은 폴백이 아니라
                    // **재구독 스냅샷**이 맡으므로, 여기서 즉시 읽으면 복귀마다 상세 1건이 덧붙는다.
                    // READ_NOW 는 다시 붙을 스트림이 아예 없는 경우다(종결·스트림 없는 저장소) —
                    // 유일한 갱신 수단을 6초 미룰 이유가 없다.
                    if step == .waitThenRead { try await sleep(.milliseconds(PARTY_FALLBACK_POLL_INTERVAL_MS)) }
                    while !Task.isCancelled {
                        if await self?.pollFallbackOnce() == true { return }
                        try await sleep(.milliseconds(PARTY_FALLBACK_POLL_INTERVAL_MS))
                    }
                } catch {
                    // 대기가 던지는 것은 취소뿐이다 — 패스를 끝낸다.
                }
            }
        }
    }

    /// 폴백 한 주기. 루프가 끝났으면(대기 단계를 벗어났으면) true.
    private func pollFallbackOnce() async -> Bool {
        guard shouldPollFallback(realtimeAlive: realtimeAlive, hasRide: hasRide) else { return false }
        guard await readDetail() else { return false }
        if let status = heldRide?.status, !isWaitingForMembers(status: status) {
            fallbackDone = true
            return true
        }
        return false
    }

    /// 「그만 찾기」·「방 나가기」 — 성공하면 Route 가 홈으로 보낸다.
    ///
    /// **403 `NOT_PARTY_MEMBER` 는 여기까지 실패로 오지 않는다** — 데이터 계층이 성공으로 되돌린다
    /// (`RemoteRideRepository.leaveParty`). 그래야 204 응답이 유실된 사용자가(터널·타임아웃)
    /// 「나가지 못했어요」를 보고 다시 눌렀을 때 **같은 문구의 403** 에 갇히지 않는다 — 그 상태에서는
    /// 로컬 기억과 홈 배너가 그 방을 계속 들고 있어 화면상 나는 아직 그 방에 있다.
    ///
    /// 남은 실패는 `leaveFailureMessage` 가 사유별로 가른다 — 409 는 「매칭이 시작돼 못 나간다」라서
    /// 재시도 안내와 **다음 행동이 다르다**(완료의 `finishFailureMessage` 와 같은 선례).
    public func leaveParty() {
        let repository = self.repository
        let partyId = self.partyId
        runAction(
            failureMessage: LEAVE_FAILED_MESSAGE,
            messageOf: { ($0 as? PartyLeaveException).map { leaveFailureMessage(e: $0) } }
        ) { [weak self] in
            // 나가는 주체는 Bearer 토큰이 정한다 — memberId 를 넘기지 않는다 (22 보고서 §2)
            try await repository.leaveParty(partyId: partyId)
            self?.actionState.left = true
        }
    }

    /// 1차 배포 모드의 「합승 완료」 — 기사 없이 방을 닫는다. 한 명이 누르면 **모두의** 방이 끝난다.
    ///
    /// 실패 사유가 여럿이고 **각각 다음 행동이 다르다** — 그래서 `finishFailureMessage` 로 문구를 가른다.
    /// 예전에는 네트워크 끊김도, 403 도, 409 도 전부 「합승을 완료하지 못했어요」 하나였다.
    ///
    /// 특히 Backend #237 이후 이 API 는 **방장 전용**이라 비방장은 403 `NOT_PARTY_HOST` 를 받는다.
    /// 버튼은 이제 **방장에게만 보인다**(`canFinishParty`) — 서버가 멤버마다 `host` 를 내려 주기
    /// 시작하면서(Backend #240 **반영 완료**) 노출 조건을 걸 근거가 생겼다. 예전 주석이 걸림돌로
    /// 적어 두었던 「`hostId` 가 내부 PK `Long` 이라 앱이 방장을 식별할 수 없다」는 **지난 이야기다**:
    /// 그 `hostId` 는 응답에서 제거됐고, 방장은 멤버 목록의 `publicId` 옆에 `host` 로 온다.
    ///
    /// 그래도 이 403 경로는 **남는다.** 방장은 멤버가 나갈 때마다 남은 멤버 중
    /// `min(joinedAt, memberId)` 로 자동 승계되는데(저장값이 아니라 파생값), 서버가 그걸 알려 주는
    /// 신호는 `member-left` 한 번뿐이다 — 반영은 `Ride.withHostSuccession` 이 맡지만, 그 신호를
    /// 놓치거나(SSE 는 at-most-once) **순서가 역전되면** 다음 스냅샷까지 내 목록이 낡은 채로 남는다
    /// (역전된 프레임은 상세 재조회로 메운다 — `RideDelta.needsDetail`). 즉 노출을 막아도
    /// **스냅샷이 낡은 틈**은 남아 있고, 그 틈에서 눌린 「합승 완료」를 받아 주는 자리가 이 403 문구다.
    public func finishParty() {
        let repository = self.repository
        let partyId = self.partyId
        runAction(
            failureMessage: FINISH_FAILED_MESSAGE,
            messageOf: { ($0 as? PartyFinishException).map { finishFailureMessage(e: $0) } }
        ) { [weak self] in
            try await repository.finishParty(partyId: partyId)
            self?.actionState.finished = true
        }
    }

    /// 액션 공통: 중복 실행 차단 → 진행 표시 → 실패 시 한국어 메시지.
    ///
    /// `messageOf` 가 실패를 **사유별 문구**로 옮긴다 — nil 이면 `failureMessage` 로 떨어진다.
    /// 기본값이 "항상 nil" 이라 사유를 가르지 않는 액션은 예전과 똑같이 동작한다. 지금은 두 액션
    /// (나가기·합승 완료) 다 사유를 가르므로 기본값을 쓰는 호출부가 없지만, 남겨 둔다 — 새 액션이
    /// 사유를 가르기 전에도 돌아야 한다.
    ///
    /// 진행 표시는 태스크를 띄우기 **전에** 세운다. 원본은 `Dispatchers.Main.immediate` 라 `launch` 안의 첫 줄이
    /// 곧바로 돌지만, Swift 태스크는 다음 차례에 돌아 그 사이의 두 번째 탭이 중복 차단을 지나간다.
    private func runAction(
        failureMessage: String,
        messageOf: @escaping @MainActor (any Error) -> String? = { _ in nil },
        block: @escaping @MainActor () async throws -> Void
    ) {
        if actionState.inProgress { return }
        actionState.inProgress = true
        actionState.errorMessage = nil
        scope.launch { [weak self] in
            do {
                try await block()
                self?.actionState.inProgress = false
            } catch {
                // 태스크 취소는 뷰모델 해제뿐이라 문구를 보여 줄 화면이 없다.
                if Task.isCancelled { return }
                self?.actionState.inProgress = false
                self?.actionState.errorMessage = messageOf(error) ?? failureMessage
            }
        }
    }

    private var heldRide: Ride? {
        if case .success(let ride) = uiState { ride } else { nil }
    }

    private var hasRide: Bool { heldRide != nil }

    /// `MutableStateFlow` 처럼 같은 값이면 내보내지 않는다 — 같은 내용의 상세가 와도 화면이 다시 그려지지 않는다.
    private func publish(_ state: UiState) {
        if uiState != state { uiState = state }
    }

    private func markPartyClosed() {
        partyClosed = true
        updateFallbackInputs { $0.partyClosed = true }
    }

    private func markMembershipLost() {
        membershipLost = true
        updateFallbackInputs { $0.membershipLost = true }
    }

    private func markStreamEnded() {
        updateFallbackInputs { $0.streamEnded = true }
    }

    private func updateFallbackInputs(_ change: (inout FallbackInputs) -> Void) {
        fallbackInputs.update { inputs in
            var next = inputs
            change(&next)
            return next
        }
    }
}

/// 21 대기 화면이 머무는 단계 — 아직 사람을 모으는 중(서버 ACTIVE)이거나 정원이 찬(서버 COMPLETED) 상태.
/// 이 밖으로 나가면 배차가 시작됐거나(25 배차 현황) 방이 닫힌 것이라 폴백 폴링을 끝낸다.
func isWaitingForMembers(status: RideStatus) -> Bool {
    status == .recruiting || status == .matched
}

/// 이번 주기에 방 상세를 읽어야 하나 — **폴링 정책 그 자체**.
///
/// SSE 가 살아 있으면(`realtimeAlive`) 방 상태는 변경분으로 오므로 **읽지 않는다 — 평상시 0회**.
/// 예전에는 신호가 붙어 있어도 20초마다 「바뀌었나」를 물었는데, 서버가 무엇이 바뀌었는지를 싣게 된 뒤로
/// 그 주기 조회는 같은 내용을 다시 받는 낭비다(상세 폴링이 서버 요청의 45% 였다 — Backend #177).
///
/// 단 **화면에 방이 아직 없으면**(`hasRide` false) 스트림이 살아 있어도 읽는다. 변경분은 바탕이 있을 때만
/// 쓸 수 있어서, 첫 조회가 실패해 에러 화면인 채로 두면 다음 멤버 변화가 올 때까지 거기에 갇힌다.
func shouldPollFallback(realtimeAlive: Bool, hasRide: Bool) -> Bool {
    !realtimeAlive || !hasRide
}

/// SSE 를 지금 구독해야 하는가 — **가시성 게이트의 판정**(`MatchWaitingViewModel.observeEvents`).
///
/// | 판정 | 조건 | 왜 |
/// |---|---|---|
/// | 구독하지 않는다 | `visible` 이 false | **이 함수의 존재 이유.** 보이지 않는 화면이 연결을 붙들 이유가 없다 — 멤버 합류에는 푸시가 없어 백그라운드에서 받아도 띄울 데가 없고, OS 가 네트워크를 조여 「죽고 재연결」만 되풀이된다(QA 123 D-3) |
/// | 구독하지 않는다 | `streamEnded` 가 true | 종결로 끝난 스트림이다(방 닫힘·404 방 없음·403 멤버 아님·스트림 없는 저장소). 다시 붙어도 같은 답이고, 게이트 이전에도 다시 붙지 않았다 |
/// | 구독한다 | 그 밖 | 보이고, 아직 종결되지 않았다 |
///
/// 끊어도 안전한 근거는 **재연결마다 서버가 방 상세 전체를 다시 준다**는 것이다(`connected` =
/// `PartyEvent.snapshot`) — 복귀해 붙는 순간 상태가 통째로 맞춰지므로 끊긴 동안의 변화를 따라잡는
/// 별도 조회가 없다(`MatchWaitingViewModel` 의 `visible` 주석).
///
/// - Parameters:
///   - visible: 화면이 사용자에게 보이는가(`lifecycleEffect` 로 받는다)
///   - streamEnded: 스트림이 **종결**로 끝났는가(가려져서 취소된 것과 구분한다)
func shouldObservePartyEvents(visible: Bool, streamEnded: Bool) -> Bool {
    visible && !streamEnded
}

/// 폴백 폴링 패스 하나가 할 일 — `fallbackPollStep` 의 판정 결과.
/// (17 탐색 `NearbyPollStep` 과 같은 자리·같은 모양이다.)
enum FallbackStep: Equatable, Sendable {
    /// 아무것도 하지 않고 다음 신호를 기다린다 — 안 보이거나, 루프가 이미 끝났다
    case stop

    /// 지금 바로 상세를 읽고 주기를 시작한다 — 다시 붙을 스트림이 없어 폴백이 **유일한** 갱신 수단이다
    case readNow

    /// 한 주기 기다린 뒤 읽는다 — 평상시. 복귀의 갱신은 재구독 스냅샷이 맡는다
    case waitThenRead
}

/// 폴백 루프를 **돌릴지, 첫 조회를 미룰지, 아예 멈출지.**
///
/// 폴링을 화면 가시성에 묶는 판정을 이 한 곳에 모은다(17 탐색 `nearbyPollStep` 과 같은 역할).
/// 위에서부터 읽는다 — 앞의 조건이 뒤를 가린다.
///
/// | 판정 | 조건 | 이유 |
/// |---|---|---|
/// | `.stop` | `visible` 이 false | **이 함수의 존재 이유.** 보이지 않는 화면이 서버를 부를 이유가 없다 (QA 123 D-3) |
/// | `.stop` | `partyClosed` | 서버가 방이 닫혔다고 알려 왔다 — 닫힌 방을 다시 읽어도 「닫혔다」만 재확인한다. **기존 종료 조건** |
/// | `.stop` | `fallbackDone` | 방이 대기 단계를 벗어나 루프가 이미 끝났다. **기존 종료 조건** — 복귀로 되살아나면 회귀다 |
/// | `.stop` | `membershipLost` | **내가 이 방 멤버가 아니다.** 읽어도 남의 방이고, Route 가 곧 화면을 떠난다 |
/// | `.readNow` | `streamEnded` | 다시 붙을 스트림이 없다(종결·더미). 복귀 갱신을 맡을 스냅샷이 없으므로 6초를 기다리지 않는다 |
/// | `.waitThenRead` | 그 밖 | 평상시. 복귀 즉시 재구독이 스냅샷을 가져오므로, 여기서 또 읽으면 복귀마다 상세 1건이 덧붙는다 |
///
/// 가시성이 맨 앞인 게 요점이다 — **보이지 않는 동안에는 나머지 조건을 보지 않는다.**
/// 반대로 `partyClosed`·`fallbackDone`·`membershipLost` 는 「끝났다」는 사실이라 복귀해도 되돌아가지
/// 않는다: 가시성은 스위치, 나머지는 종결이다.
///
/// **`membershipLost` 가 `streamEnded` 보다 위에 있는 게 요점이다.** 그 둘은 403 에서 **같은 순간에**
/// 서는데, 순서가 뒤집히면 「다시 붙을 스트림이 없으니 지금 읽어라」(READ_NOW)가 이겨서 **내가 들어
/// 있지 않은 방**을 6초마다 영원히 읽는다 — 이 함수가 고치는 결함이 정확히 그것이었다.
///
/// - Parameters:
///   - visible: 화면이 사용자에게 보이는가(`lifecycleEffect` 로 받는다)
///   - partyClosed: 서버가 `closed` 를 보냈는가(`PartyEvent.closed`)
///   - fallbackDone: 대기 단계를 벗어나 루프가 끝났는가(`isWaitingForMembers` false 를 본 뒤)
///   - streamEnded: SSE 가 종결로 끝나 재구독할 것이 없는가(`shouldObservePartyEvents`)
///   - membershipLost: 내가 이 방 멤버가 아니라고 서버가 말했는가(SSE 403 · 상세의 members 에 내가 없음)
func fallbackPollStep(
    visible: Bool,
    partyClosed: Bool,
    fallbackDone: Bool,
    streamEnded: Bool,
    membershipLost: Bool = false
) -> FallbackStep {
    if !visible { return .stop }
    if partyClosed || fallbackDone || membershipLost { return .stop }
    if streamEnded { return .readNow }
    return .waitThenRead
}

/// 서버가 준 멤버 목록에서 **내가 사라졌는가** — 「유령 대기방」 판정.
///
/// SSE 403 이 같은 사실을 더 빨리 말해 주지만(`PartyMembershipLostException`), 그 스트림이 붙지 않는
/// 망에서는 이 판정이 **유일한 창구**다: `GET /matching/rooms/{partyId}` 에는 참여자 검사가 **없어**
/// 멤버가 아니어도 200 이 오고, 그러면 화면은 남의 방을 「같이 탈 사람을 찾고 있어요」로 그린다.
///
/// 세 조건을 **모두** 요구한다 — 틀렸을 때 멀쩡히 방에 들어 있는 사람을 쫓아내기 때문이다.
///
/// | 조건 | 없으면 |
/// |---|---|
/// | `sawMyself` | `isMe` 는 `publicId == 세션 uuid` 라, 세션 uuid 가 없으면(미로그인·복원 전) 아무도 나로 표시되지 않는다 — 정상인 방까지 상실로 읽는다 |
/// | 목록이 비어 있지 않다 | 멤버가 0명인 방은 **있을 수 없다**(마지막 멤버가 나가면 서버가 방을 닫는다). 빈 목록은 응답이 이상하다는 뜻이라 판정 근거가 되지 못한다 |
/// | 목록에 내가 없다 | 상실의 정의 그 자체 |
///
/// 반대로 **status 는 보지 않는다.** 내가 멤버가 아니라는 사실은 방이 어느 단계인지와 무관하고,
/// ACTIVE 유령 방이 바로 이 결함의 본체였다(닫힌 방은 `PartyEvent.closed` 가 이미 잡는다).
func hasLostMembership(sawMyself: Bool, ride: Ride) -> Bool {
    sawMyself && !ride.members.isEmpty && !ride.members.contains(where: { $0.isMe })
}

/// 변경분 프레임 하나를 어떻게 다룰지 — `deltaVerdict` 의 답.
enum FrameVerdict: Equatable, Sendable {
    /// 순서가 맞다(또는 가릴 수 없다). 들고 있는 방에 그대로 얹는다.
    case apply

    /// 이미 반영한 프레임이다. **버린다** — 다시 얹으면 과거로 되돌아간다.
    case drop

    /// 중간을 놓쳤거나 스냅샷보다 먼저 왔다. 상세를 1회 다시 읽어 맞춘다(스트림은 끊지 않는다).
    case resync
}

/// 받은 변경분의 `incoming` 순번을 들고 있는 `held` 와 견줘 판정한다
/// (서버 계약 원문은 `PartyEvent` 의 표).
///
/// | `held` | `incoming` | 답 | 왜 |
/// |---|---|---|---|
/// | 무엇이든 | `nil` | `.apply` | 순번을 모르는 **옛 서버**다. 가릴 근거가 없으니 예전처럼 그대로 얹는다 |
/// | `nil` | 숫자 | `.resync` | 스냅샷을 아직 못 받았다 = **틈**. 서버가 "상세를 다시 받으라"고 적어 둔 경우 |
/// | N | ≤ N | `.drop` | 이미 반영했다 |
/// | N | N+1 | `.apply` | 바로 다음 프레임 |
/// | N | ≥ N+2 | `.resync` | 중간 프레임을 놓쳤다 |
///
/// **`.drop` 이 이 함수의 존재 이유다.** 서버는 구독을 먼저 등록한 뒤 DB 를 읽어 스냅샷을 보내므로
/// 그 사이 커밋된 변경분이 스냅샷보다 먼저 올 수 있고, 그때 순번 없이 받는 대로 얹으면 뒤늦게 온
/// 낡은 스냅샷이 이미 반영한 합류를 지운다. 지워진 합류가 **정원을 채운 사람**이면 서버는 배차를
/// 시작했는데 화면은 모집 중에 멈추고, 스트림이 살아 있어 재연결 스냅샷도 폴백 폴링도 오지 않는다.
func deltaVerdict(held: Int64?, incoming: Int64?) -> FrameVerdict {
    guard let incoming else { return .apply }
    guard let held else { return .resync }
    if incoming <= held { return .drop }
    if incoming == held + 1 { return .apply }
    return .resync
}

/// 스냅샷(또는 다시 읽은 상세)으로 방을 **통째로 교체해도 되는가**.
///
/// 변경분과 규칙이 다르다 — 스냅샷은 "+1" 을 요구하지 않는다. 한 덩어리로 완결돼 있어 중간을 건너뛰어도
/// 되기 때문이다. 다만 **들고 있는 것보다 과거면 버려야 한다**: 늦게 도착한 스냅샷이 그 사이 반영한
/// 변경분을 되돌리는 게 정확히 우리가 막으려는 것이다.
///
/// `held` 나 `incoming` 이 nil 이면 가릴 근거가 없으므로 받아들인다(옛 서버·첫 연결).
func acceptsSnapshot(held: Int64?, incoming: Int64?) -> Bool {
    guard let held, let incoming else { return true }
    return incoming >= held
}

extension Ride {
    /// `PartyEvent.memberJoined` 적용 — 멤버 목록에 더하고 서버가 준 **들어온 뒤의** `status` 로 바꾼다.
    ///
    /// 같은 publicId 가 이미 있으면 **자리를 지키며 교체**한다(덧붙이지 않는다). 같은 사람이 두 번 들어오는
    /// 일은 없지만, 신호가 겹쳐 오거나 스냅샷 직후의 변경분이 다시 실릴 때 인원이 부풀면 안 된다 —
    /// 21 의 인원 표시는 이 목록의 길이(`members.count`)가 유일한 근거다.
    ///
    /// id 가 빈 멤버(탈퇴 등으로 서버가 요약을 못 만든 경우)는 서로 구별할 근거가 없어 겹침 판정을 하지 않는다 —
    /// 빈 id 끼리 같다고 보면 엉뚱한 사람을 덮어쓴다.
    ///
    /// `member` 의 `User.isMe` 는 상세와 같은 근거(publicId == 세션 uuid)로 **이미 채워져 온다** — 다시 판정하지 않는다.
    func withMemberJoined(member: User, status: RideStatus) -> Ride {
        var result = self
        if let index = members.firstIndex(where: { $0.isSameMemberAs(other: member) }) {
            result.members[index] = member
        } else {
            result.members.append(member)
        }
        result.status = status
        return result
    }

    /// `PartyEvent.memberLeft` 적용 — `publicId` 로 **그 한 명만** 지우고 나간 뒤의 `status` 로 바꾼다.
    ///
    /// 모르는 publicId 면 목록은 그대로 두고 status 만 반영한다 — 그 사람의 입장 신호를 놓쳤다는 뜻이고,
    /// 없는 사람을 지우려 상세를 또 읽지는 않는다(어긋남은 `hasMemberDrift` 나 다음 스냅샷이 잡는다).
    /// 빈 publicId 로는 아무도 지우지 않는다 — 요약이 없는 멤버들을 한꺼번에 날리는 사고를 막는다.
    ///
    /// `hostPublicId` 는 서버가 실어 준 **승계 후 방장**이다 — `Ride.withHostSuccession` 으로 함께 옮긴다.
    /// 그래서 승계는 **나간 사람을 빼고 난 목록**에 적용된다(서버가 싣는 값도 「이 이벤트를 반영한 뒤의
    /// 방장」이다). 그 값이 nil·빈 값이거나 남은 목록에 없으면 표시를 손대지 않고
    /// `RideDelta.needsDetail` 로 **「방 상세를 다시 받으라」**를 돌려준다 — 서버 계약이다.
    func withMemberLeft(publicId: String, status: RideStatus, hostPublicId: String? = nil) -> RideDelta {
        var result = self
        result.members = members.filter { !(!$0.id.isBlank && $0.id == publicId) }
        result.status = status
        return result.withHostSuccession(hostPublicId: hostPublicId)
    }

    /// 방장 승계 반영 — 서버가 `member-left` 에 실어 준 `hostPublicId` 를 멤버 목록의 `User.isHost` 로 옮긴다.
    ///
    /// **이게 빠지면 방장이 나가도 승계된 사람이 「합승 완료」를 못 본다.** 서버는 멤버가 나갈 때마다
    /// 남은 멤버 중 `min(joinedAt, memberId)` 를 방장으로 다시 정하는데(저장값이 아니라 파생값),
    /// 그 결과를 알려 주는 신호는 이 한 번뿐이다 — 다시 보내지 않으므로 여기서 버리면 다음 스냅샷
    /// (재연결)이나 폴백 상세 조회까지 승계된 사람의 화면이 낡은 채로 남는다.
    ///
    /// ### 서버 계약 원문 (백엔드 `matching/sse/PartySseController` 의 Swagger description) ★
    /// > `member-left`: { publicId, status, hostPublicId, version }. … hostPublicId 는 이 이벤트를 반영한 뒤의
    /// > 방장 — 받을 때마다 members 의 host 표시를 이 값으로 다시 지정한다. 단 **null 이거나 목록에 없는
    /// > publicId 면 host 표시를 바꾸지 말고 방 상세를 다시 받는다**(이벤트 순서 역전 대비)
    ///
    /// 그대로 두 갈래다:
    ///
    /// | 지목된 publicId | 하는 일 | 왜 |
    /// |---|---|---|
    /// | 목록에 **있다** | 표시를 **통째로 다시 칠한다** — 그 한 명만 true, 나머지는 전부 false | 서버 말이 곧 「방장은 한 명」이므로, 전에 방장이던 사람(또는 나)의 true 를 지우는 것까지가 이 함수의 일이다 |
    /// | nil·빈 값·목록에 **없다** | 표시를 **그대로 두고** `RideDelta.needsDetail` 을 세운다 | 내 목록이 그 사람을 모르니 다시 칠할 근거가 없다 — 서버에 방 상세를 다시 묻는다 |
    ///
    /// ### 「목록에 없으면 전원 false」로 되돌리지 말 것 ★
    /// 그게 2026-10-15 까지의 동작이었고(근거는 「서버가 나 아닌 누군가를 방장이라 했으니 적어도 *내가
    /// 방장이다*는 거짓이다」였다), **서버 계약과 정반대다.** 깨지는 경로가 실제로 있다 — 두 멤버가
    /// 연달아 나가 프레임 순서가 역전되면(`u2` 이탈 프레임이 `u1` 이탈 프레임보다 먼저 도착) 뒤늦게 온
    /// 프레임이 **이미 나간 사람**을 방장으로 지목한다. 전원 false 로 밀면 그 순간 **진짜 방장의
    /// `User.isHost` 가 지워져 「합승 완료」 버튼을 영구히 잃는다**: `hasMemberDrift` 는 인원수만 보므로
    /// 못 잡고(목록 길이는 맞다), SSE 가 살아 있으면 폴백 폴링도 돌지 않아(`shouldPollFallback`) 재연결
    /// 스냅샷이나 30분 만료 말고는 복구 수단이 없다.
    ///
    /// nil·빈 값도 같은 자리로 떨어진다. 서버가 새 방장의 요약을 못 찾은 경우인데
    /// (`PartyService.leave` 의 `hostSummary == null`), 모른다고 전부 false 로 밀면 역시 **진짜 방장의
    /// 표시를 지운다.** 그래서 손대지 않고 상세로 확인한다.
    ///
    /// 내용이 같으면 `Ride` 가 값 타입이라 결과가 원본과 `==` 이므로 재구성도 일어나지 않는다.
    func withHostSuccession(hostPublicId: String?) -> RideDelta {
        guard let host = hostPublicId, !host.isBlank else { return RideDelta(ride: self, needsDetail: true) }
        // host 가 빈 값이 아니므로 `$0.id == host` 는 id 가 빈 멤버(요약 없음)를 자동으로 비껀다 —
        // 빈 문자열끼리 맞아떨어져 엉뚱한 사람이 방장이 되는 일이 없다.
        if !members.contains(where: { $0.id == host }) { return RideDelta(ride: self, needsDetail: true) }
        var result = self
        result.members = members.map { member in
            var next = member
            next.isHost = member.id == host
            return next
        }
        return RideDelta(ride: result)
    }
}

/// 변경분 하나를 적용한 결과 — 새 방과, **서버가 「방 상세를 다시 받으라」고 한 프레임인가.**
///
/// `needsDetail` 이 서는 자리는 지금 하나다: `member-left` 가 지목한 방장을 내 목록에서 찾지 못한
/// 경우(`Ride.withHostSuccession`). 그때는 host 표시를 손대지 않고 서버에 다시 묻는다 — 서버 Swagger
/// 가 그렇게 적어 두었고, 이유는 **이벤트 순서 역전**이다.
///
/// 왜 `Ride` 안에 담지 않고 따로 내보내나: 이 값은 방의 성질이 아니라 **이 프레임의 처리 지시**다.
/// `Ride` 에 실으면 스냅샷·상세 조회 결과에도 따라붙어 「읽어 온 결과를 보고 또 읽는」 되돌이가 생긴다.
struct RideDelta: Equatable, Sendable {
    var ride: Ride
    var needsDetail: Bool

    init(ride: Ride, needsDetail: Bool = false) {
        self.ride = ride
        self.needsDetail = needsDetail
    }
}

/// 변경분을 적용한 뒤 **방 상세를 1회 읽어야 하는가** — `MatchWaitingViewModel.applyDelta` 의 판정.
///
/// 둘 중 하나라도 참이면 읽는다. 사유는 다르지만 처방이 같다(**목록이 아니라 서버를 믿는다**):
///
/// | 사유 | 뜻 |
/// |---|---|
/// | `RideDelta.needsDetail` | 서버가 지목한 방장이 내 목록에 없다 — **host 표시를 믿을 수 없다** |
/// | `hasMemberDrift` | 서버가 준 status 와 내 멤버 목록이 모순이다 — **목록이 낡았다** |
///
/// 둘 다 참이어도 **상세는 한 번만** 읽는다. 그리고 읽어 온 결과에는 이 판정을 다시 걸지 않는다
/// (`readDetail` 이 화면 상태를 직접 세운다) — 그래서 **되돌이가 생기지 않는다**: 이벤트 프레임
/// 하나당 추가 조회는 최대 1건이고, 그 조회 결과가 또 조회를 부르는 길이 없다.
func needsDetailAfterDelta(delta: RideDelta) -> Bool {
    delta.needsDetail || hasMemberDrift(ride: delta.ride)
}

private extension User {
    // 같은 사람인가 — 서버 식별자(publicId)가 **양쪽에 다 있을 때만** 같다고 본다.
    func isSameMemberAs(other: User) -> Bool { !id.isBlank && id == other.id }
}

/// 들고 있는 멤버 목록이 서버가 준 status 와 **모순**인가 — 변경분이 유실됐다는 신호.
///
/// 인원 표시의 근거는 **멤버 목록 하나**다(`MatchWaitingScreen` 의 `foundCount` = `members.count`) —
/// 별도의 인원 카운터를 들고 있지 않다(합류 응답의 `currentMembers` 도 21 로 넘기지 않는다). 그래야
/// 「목록엔 3명인데 카운터는 4」 같은 두 번째 진실이 생기지 않는다.
///
/// 그래도 어긋날 수 있는 짝이 하나 남는다: 서버가 변경분에 실어 준 status 와, 변경분을 쌓아 만든 목록.
/// 둘이 모순이면 **틀린 쪽은 목록**이라고 본다 — status 는 서버가 그 자리에서 판정한 값이고, 목록은
/// 유실될 수 있는 신호를 더해 만든 값이다. 그래서 모순을 보면 상세를 1회 읽어 **서버 쪽으로 맞춘다.**
///
/// 모순의 정의는 정원뿐이다: 정원이 찼다는 status(MATCHED)인데 목록이 모자라거나, 아직 모집 중
/// (RECRUITING)인데 목록이 정원을 채웠거나. 배차 이후 단계는 Route 가 화면을 넘기므로 보지 않고,
/// 정원을 모르는 방(capacity 0 — 목록·더미 응답)은 비교 기준이 없어 판단하지 않는다.
func hasMemberDrift(ride: Ride) -> Bool {
    if ride.capacity <= 0 { return false }
    switch ride.status {
    case .matched: return ride.members.count < ride.capacity
    case .recruiting: return ride.members.count >= ride.capacity
    default: return false
    }
}

/// 서버가 나가기를 허용하는가. 서버 `ensureRecruiting` = ACTIVE 또는 COMPLETED.
///
/// 기사 모드에선 COMPLETED 가 순간이라(곧 MATCHING) 사실상 ACTIVE 에서만 나갈 수 있고, 눌러 봐야 409 다 —
/// 그래서 예전처럼 막는다. 1차 배포 모드에선 COMPLETED 에 머무르므로 거기서도 나갈 수 있어야 한다
/// (나가면 서버가 방을 ACTIVE 로 되돌려 다시 모집한다).
func canLeaveParty(status: RideStatus, taxiEnabled: Bool) -> Bool {
    status == .recruiting || (!taxiEnabled && status == .matched)
}

/// 1차 배포 모드에서 **방을 손으로 닫는 단계**인가 — 정원이 찼고(COMPLETED) 기사가 없을 때.
/// 기사 모드에선 절대 참이 아니다(정원이 차면 곧바로 25 배차 현황으로 넘어간다).
///
/// `canFinishParty` 와 **일부러 갈라 두었다**: 이쪽은 「방이 어떤 단계인가」, 저쪽은 「내가 누를 수
/// 있는가」다. 헤드라인(「같이 탈 사람이 모였어요」)·나가기 문구(「방 나가기」)처럼 방장 여부와
/// 상관없는 표시는 **이쪽**을 봐야 한다 — 저쪽을 보면 정원이 찬 방을 보고 있는 비방장에게
/// 「같이 탈 사람 찾는 중」이라고 거짓말을 하게 된다.
func isFinishStage(status: RideStatus, taxiEnabled: Bool) -> Bool {
    !taxiEnabled && status == .matched
}

/// 「합승 완료」 버튼을 **내게** 보여 줄 때 — 손으로 닫는 단계이고(`isFinishStage`) 내가 방장일 때.
///
/// 방장 조건은 2026-10-15 에 붙었다. 서버가 이 API 를 방장 전용으로 좁힌 뒤(Backend #237, 운영
/// 배포 완료) 비방장이 누르면 확인 다이얼로그를 거친 끝에 403 `NOT_PARTY_HOST` 를 맞았다 —
/// 전원에게 보여 주던 버튼이 **절반에게는 실패하는 버튼**이었다. 비활성으로 두지 않고 **숨긴다**:
/// 누를 수 없는 버튼은 왜 못 누르는지 말해 주지 못하므로, 그 자리에는 누가 끝내는지를 말하는
/// 안내문이 들어간다(`finishHostNotice`).
///
/// 판정은 `Ride.isHostedByMe` **하나로만** 한다(= 멤버 목록의 내 줄 `User.isHost`). 서버가 멤버마다
/// `host` 를 내려 주므로 이건 **추정이 아니라 서버 값**이다 — 2026-08-30 에 걷어낸 `joinedAt`
/// 최소값 추정과 다르다(`_workspace/33_api-integrator_no_host.md`). `Ride` 를 통째로 받는 것도
/// 그래서다: status 와 방장 판정의 근거(members)가 **같은 스냅샷**이어야 하고, 호출부가 방장
/// 여부를 따로 계산해 끼워 넣을 틈을 두지 않는다.
///
/// true 라도 **서버가 최종 판정이다.** 방장은 멤버가 들고 날 때마다 바뀌어 내 스냅샷이 낡을 수
/// 있으므로 403 경로(`finishFailureMessage`)는 노출을 막은 뒤에도 그대로 남는다.
func canFinishParty(ride: Ride, taxiEnabled: Bool) -> Bool {
    isFinishStage(status: ride.status, taxiEnabled: taxiEnabled) && ride.isHostedByMe
}

/// 비방장이 「합승 완료」가 있던 자리에서 읽는 안내문 — **버튼을 숨긴 자리를 비워 두지 않는다.**
///
/// 숨기기만 하면 정원이 찬 뒤 할 일이 하나도 없는 화면이 된다. 사용자가 알아야 하는 건 둘이다:
/// **누가 방을 끝내는가**, 그리고 **그게 방을 끝내는 행동이라는 것**. 그 둘만 한 줄로 적는다.
///
/// `hostNickname` 이 있으면 **이름으로 부른다.** 서버가 멤버마다 `host` 를 내려 주므로 그 사람이
/// 누군지 알 수 있다(`hostDisplayNameOrNull`). 이름을 못 쓰는 경우는 셋이다 — 방장의 유저 요약이
/// 없거나(식별자가 빈 값), 방장이 **탈퇴했거나**(soft delete: 식별자는 살아 있고 닉네임만 서버가
/// 「탈퇴한 사용자」로 가린다), 아무도 방장으로 지목되지 않았거나. 그때는 지어내지 않고 **조건**을
/// 말한다: 서버 `Party.hostId()` 가 현재 멤버 중 `min(joinedAt, memberId)` 라
/// 「가장 먼저 참여한 분」은 사실이다(`finishFailureMessage` 의 403 문구와 같은 근거·같은 표현).
///
/// 탈퇴한 방장을 이름으로 부르면 **지킬 수 없는 약속**이 된다 — 그 사람은 「합승 완료」를 영원히
/// 누를 수 없고(방은 30분 만료로만 닫힌다), 안내문이 가리킨 사람을 기다리게 만든다. 그래도
/// **멤버 목록의 「방장」 배지는 그대로 붙는다**: 서버가 그를 방장이라고 말한 건 사실이고, 방이 왜
/// 끝나지 않는지를 설명해 준다. 막는 것은 **이름으로 부르는 것** 하나뿐이다.
///
/// 「잠시 후 다시 시도」류는 넣지 않는다 — 기다려서 풀리는 일이 아니다. 방장이 누르거나, 방장이
/// 나가 내게 승계되어야 바뀐다.
func finishHostNotice(hostNickname: String?) -> String {
    if let hostNickname, !hostNickname.isBlank {
        "다 타면 방장 \(hostNickname)님이 「합승 완료」를 눌러 방을 끝내요"
    } else {
        "다 타면 방장(가장 먼저 참여한 분)이 「합승 완료」를 눌러 방을 끝내요"
    }
}

/// 사유를 가릴 수 없는 「합승 완료」 실패의 일반 문구. 네트워크 실패와 **모르는 코드**가 여기로 떨어진다 —
/// 서버가 `MatchingErrorCode` 를 늘려도 앱은 틀린 말을 하지 않는다(지어내는 것보다 모른다고 하는 게 낫다).
private let FINISH_FAILED_MESSAGE = "합승을 완료하지 못했어요"

/// 「합승 완료」 실패를 사용자 문구로 옮긴다 — 실패마다 **다음 행동이 다르다**.
///
/// | 사유 | 서버 코드(HTTP) | 사용자가 할 일 |
/// |---|---|---|
/// | 방장이 아니다 | `NOT_PARTY_HOST` (403) | 가장 먼저 참여한 사람에게 눌러 달라고 한다 |
/// | 멤버가 아니다 | `NOT_PARTY_MEMBER` (403) | 홈에서 진행 중인 방을 확인한다 |
/// | 정원 미달 | `PARTY_NOT_COMPLETED` (409) | 인원이 모두 모일 때까지 기다린다 |
/// | 기사 배정됨 | `DRIVER_ALREADY_ASSIGNED` (409) | 직접 끝낼 방이 아니다 — 누를 일이 없다 |
/// | 방 없음 | `PARTY_NOT_FOUND` (404) | 홈으로 돌아간다 |
/// | 그 밖·네트워크 | 코드 없음 | `FINISH_FAILED_MESSAGE` |
///
/// **403 과 409 가 각각 두 가지 뜻**이라 상태 코드로는 가를 수 없다(서버 `Party.finishWithoutDriver` 의
/// 검사 순서가 위 표 순서다). 그래서 분기 근거는 서버 코드를 도메인이 한 번 걸러 준
/// `PartyFinishException` 의 프로퍼티다 — 20 합류의 `joinFailureMessage` 와 같은 선례다.
///
/// 방장 안내가 「가장 먼저 참여한 분」인 건 서버가 방장을 그렇게 정하기 때문이다 —
/// `Party.hostId()` 는 **현재 멤버 중 `min(joinedAt, memberId)`** 이고, 저장되는 값이 아니다.
///
/// **이름을 쓰지 않는 근거는 「앱이 방장을 모른다」가 아니다.** 앱은 평소엔 안다 — 서버가 멤버마다
/// `host` 를 내려 주고(`User.isHost`), 버튼을 못 보는 사람에게는 `finishHostNotice` 가 그 이름으로
/// 안내한다. 모르는 것은 **이 403 이 온 그 순간**이다: 403 은 내 스냅샷이 가리킨 방장이 서버 기준으로
/// 더 이상 방장이 아니라는 뜻이고(프레임 유실·순서 역전으로 승계가 반영되지 않았다), 그 스냅샷으로
/// 새 방장을 지목하면 **틀린 사람에게 부탁하라고 말하게 된다.** 그래서 이 자리에서만 이름을 접고
/// **조건**을 말한다 — 지어낸 이름을 띄우는 것보다 정확하다.
///
/// 「잠시 후 다시 시도」류는 넣지 않는다. 다시 눌러도 같은 403·409 다 — 방 사정이 바뀌어야 풀린다.
func finishFailureMessage(e: PartyFinishException) -> String {
    if e.isNotHost { return "방장만 합승을 완료할 수 있어요. 가장 먼저 참여한 분에게 부탁해 주세요" }
    if e.isNotMember { return "이 방의 참여자가 아니에요. 홈에서 진행 중인 방을 확인해 주세요" }
    if e.isNotCompleted { return "아직 정원이 다 차지 않았어요. 인원이 모두 모이면 완료할 수 있어요" }
    if e.isDriverAssigned { return "이미 기사가 배정된 방이라 직접 완료할 수 없어요" }
    if e.isPartyNotFound { return "이미 사라진 방이에요. 홈으로 돌아가 주세요" }
    return FINISH_FAILED_MESSAGE
}

/// 사유를 가릴 수 없는 나가기 실패의 일반 문구 — 네트워크 실패와 **모르는 코드**가 여기로 떨어진다.
///
/// 「이미 나갔다」(403)가 여기 오지 않는 것이 핵심이다 — 그건 실패가 아니라 **이미 됨**이라 데이터
/// 계층이 성공으로 되돌린다(`PartyLeaveException` 주석). 되돌림이 없던 동안에는 이 문구가 「서버는
/// 나를 내보냈는데 앱만 모르는」 상태의 영구 실패 안내였다.
private let LEAVE_FAILED_MESSAGE = "방에서 나가지 못했어요"

/// 나가기 실패를 사용자 문구로 옮긴다 — 실패마다 **다음 행동이 다르다**
/// (`finishFailureMessage` 와 같은 자리·같은 이유).
///
/// | 사유 | 서버 코드(HTTP) | 사용자가 할 일 |
/// |---|---|---|
/// | 모집 단계가 아니다 | `PARTY_NOT_RECRUITING` (409) | 기다린다 — 배차가 시작돼 나갈 수 없다 |
/// | 방 없음 | `PARTY_NOT_FOUND` (404) | 홈으로 돌아간다(이미 닫힌 방이다) |
/// | 그 밖·네트워크 | 코드 없음 | `LEAVE_FAILED_MESSAGE` |
///
/// 「이미 나갔다」(403 `NOT_PARTY_MEMBER`)는 **이 함수에 오지 않는다** — 데이터 계층이 성공으로
/// 되돌리므로 화면은 나가기 성공과 같은 길(홈)로 간다.
///
/// 409 에 「잠시 후 다시 시도」를 붙이지 않는다: 다시 눌러도 같은 409 다(방이 모집 단계로 돌아가는
/// 길은 없다). 대신 **왜** 못 나가는지를 말한다 — 화면은 이 단계에서 버튼을 이미 비활성으로
/// 바꾸지만(`canLeaveParty`) 전이를 알아채기까지 한 주기가 비고, 그 틈에 눌린 것이 여기로 온다.
func leaveFailureMessage(e: PartyLeaveException) -> String {
    if e.isNotRecruiting { return "매칭이 시작돼 지금은 나갈 수 없어요" }
    if e.isPartyNotFound { return "이미 사라진 방이에요. 홈으로 돌아가 주세요" }
    return LEAVE_FAILED_MESSAGE
}

/// 21 매칭 대기 — SSE 변경분 구독(+끊김 폴백) · 나가기/합승 완료 진입점. partyId 없으면 오류 안내 후 되돌린다.
///
/// 방 상태의 출처는 `MatchWaitingViewModel` 하나뿐이다 — 이 화면에서 SSE 를 두 번 수집하면 서버가 서로의
/// 연결을 끊어 무한 재연결이 되므로, 여기서 `.task` 로 구독을 추가하지 말 것. 아래
/// `lifecycleEffect` 는 **구독을 추가하지 않는다** — 그 하나의 수집을 켜고 끄는 신호만 보낸다
/// (`MatchWaitingViewModel.onScreenStart`·`MatchWaitingViewModel.onScreenStop`).
public struct MatchWaitingRoute: View {
    private let repository: any RideRepository
    private let partyId: Int64?
    private let taxiEnabled: Bool
    private let onCancelSearch: () -> Void
    private let onExitKeepingParty: () -> Void
    private let onCardClick: () -> Void
    private let onMatchingStarted: () -> Void
    private let onPartyClosed: () -> Void
    private let onOpenChat: (() -> Void)?

    /// - Parameters:
    ///   - taxiEnabled: 서버 운영 설정의 택시 모드(`AppConfig.taxiEnabled`).
    ///     false(1차 배포)면 정원이 찼을 때 기사 대기 대신 「합승 완료」를 보여 준다.
    ///   - onExitKeepingParty: 방을 유지한 채 화면만 벗어난다(나가기가 막힌 단계의 뒤로가기)
    ///   - onPartyClosed: 방이 닫혔다(FINISHED·CANCELED) — 내가 「합승 완료」를 눌렀거나, 다른 참여자가 눌렀거나,
    ///     30분 스윕이 닫았다. 호출자는 진행 중 기억을 지우고 홈으로 보낸다.
    ///   - onOpenChat: 이 방의 채팅방을 여는 길. 채팅방이 아직 없으면 nil — 화면이 버튼을 그리지 않는다
    public init(
        repository: any RideRepository,
        partyId: Int64?,
        taxiEnabled: Bool = false,
        onCancelSearch: @escaping () -> Void = {},
        onExitKeepingParty: @escaping () -> Void = {},
        onCardClick: @escaping () -> Void = {},
        onMatchingStarted: @escaping () -> Void = {},
        onPartyClosed: @escaping () -> Void = {},
        onOpenChat: (() -> Void)? = nil
    ) {
        self.repository = repository
        self.partyId = partyId
        self.taxiEnabled = taxiEnabled
        self.onCancelSearch = onCancelSearch
        self.onExitKeepingParty = onExitKeepingParty
        self.onCardClick = onCardClick
        self.onMatchingStarted = onMatchingStarted
        self.onPartyClosed = onPartyClosed
        self.onOpenChat = onOpenChat
    }

    public var body: some View {
        // 방 id 없이 닿을 길은 없다(16 생성 · 20 합류 · 홈 배너가 모두 id 를 넘긴다). 그래도 nil 이면
        // 예시 방을 그리는 대신 사실대로 말하고 되돌린다 — 20·22·23 과 같은 방식이다.
        //
        // 예전에는 여기서 `MatchWaitingScreen` 을 `ride` 없이 불러 **예시 방**을 그렸다. 구성 변경에 방
        // id 가 날아가던 동안 진짜 방에 들어 있던 사용자에게 남의 가짜 방이 떴다. 그 길을 아예 막기 위해
        // 화면 쪽 `ride` 기본값도 함께 걷어냈다.
        //
        // 되돌아갈 곳은 `onExitKeepingParty` — **방은 그대로 두고** 홈으로만 간다. 내가 어느 방에 있는지
        // 모르는 상태에서 나가기·기억 지우기(`onCancelSearch`·`onPartyClosed`)를 걸면 아직 들어 있는
        // 방을 끊어 버릴 수 있고, 홈 배너가 그 방으로 다시 들어갈 길이다.
        if let partyId {
            // `.id` 가 원본의 뷰모델 키(`waiting-{partyId}`) 자리다 — 방이 바뀌면 뷰모델도 새로 만든다.
            MatchWaitingContent(
                repository: repository,
                partyId: partyId,
                taxiEnabled: taxiEnabled,
                onCancelSearch: onCancelSearch,
                onExitKeepingParty: onExitKeepingParty,
                onCardClick: onCardClick,
                onMatchingStarted: onMatchingStarted,
                onPartyClosed: onPartyClosed,
                onOpenChat: onOpenChat
            )
            .id(partyId)
        } else {
            BackStateScaffold(title: "매칭 대기", onBack: onExitKeepingParty) {
                ErrorBox(
                    message: "어느 방을 기다리는지 알 수 없어요. 홈에서 진행 중인 방으로 다시 들어가 주세요",
                    onRetry: onExitKeepingParty,
                    actionLabel: "홈으로 가기"
                )
            }
        }
    }
}

/// 방 id 를 아는 Route 본체. 뷰모델은 id 가 있어야 만들 수 있어 나눴다.
private struct MatchWaitingContent: View {
    @HostedViewModel private var viewModel: MatchWaitingViewModel

    // 지도의 파란 점. 권한을 자동 요청하지 않는다 — 대기 화면의 본질은 지도가 아니라 「기다림」이라,
    // 여기서 다이얼로그를 띄우면 흐름을 끊는다. 이미 허용돼 있으면(14·17 에서 받았을 것) 점이 뜬다.
    @RememberMyLocationState(autoRequestPermission: false) private var myLocation

    private let taxiEnabled: Bool
    private let onCancelSearch: () -> Void
    private let onExitKeepingParty: () -> Void
    private let onCardClick: () -> Void
    private let onMatchingStarted: () -> Void
    private let onPartyClosed: () -> Void
    private let onOpenChat: (() -> Void)?

    init(
        repository: any RideRepository,
        partyId: Int64,
        taxiEnabled: Bool,
        onCancelSearch: @escaping () -> Void,
        onExitKeepingParty: @escaping () -> Void,
        onCardClick: @escaping () -> Void,
        onMatchingStarted: @escaping () -> Void,
        onPartyClosed: @escaping () -> Void,
        onOpenChat: (() -> Void)?
    ) {
        _viewModel = HostedViewModel(wrappedValue: MatchWaitingViewModel(repository: repository, partyId: partyId))
        self.taxiEnabled = taxiEnabled
        self.onCancelSearch = onCancelSearch
        self.onExitKeepingParty = onExitKeepingParty
        self.onCardClick = onCardClick
        self.onMatchingStarted = onMatchingStarted
        self.onPartyClosed = onPartyClosed
        self.onOpenChat = onOpenChat
    }

    var body: some View {
        let viewModel = self.viewModel
        let action = viewModel.actionState
        let closed = viewModel.partyClosed
        let membershipLost = viewModel.membershipLost
        let status: RideStatus? = if case .success(let ride) = viewModel.uiState { ride.status } else { nil }

        // 효과는 바뀌지 않는 바깥 컨테이너에 건다. 상태 분기(switch)마다 걸면 로딩→성공 전환에서
        // 사라짐·나타남이 불려 SSE 를 괜히 끊었다 다시 붙인다.
        ZStack {
            // 탭바가 없는 화면 — 로딩·에러에서도 뒤로가기(=탐색 취소)를 남긴다 (QA F-1 동류)
            switch viewModel.uiState {
            // 로딩·에러에서는 방 상태를 모른다. 나가기를 걸면 매칭 중인 방에 409 를 쏘게 되므로
            // 여기서의 뒤로가기는 **방을 유지한 채** 화면만 벗어난다.
            case .loading:
                BackStateScaffold(title: "같이 탈 사람 찾는 중", onBack: onExitKeepingParty) {
                    LoadingBox()
                }
            case .error(let message):
                BackStateScaffold(title: "같이 탈 사람 찾는 중", onBack: onExitKeepingParty) {
                    ErrorBox(message: message, onRetry: { viewModel.refresh() })
                }
            case .success(let ride):
                MatchWaitingScreen(
                    ride: ride,
                    foundCount: ride.members.count,
                    conditionLabel: "\(ride.capacity)인",
                    myLocation: myLocation.coordinates,
                    taxiEnabled: taxiEnabled,
                    actionInProgress: action.inProgress,
                    actionErrorMessage: action.errorMessage,
                    onCancelSearch: { viewModel.leaveParty() }, // 나가기 성공 시 14 홈
                    onFinish: { viewModel.finishParty() }, // 합승 완료 성공 시 14 홈
                    onExitKeepingParty: onExitKeepingParty,
                    onCardClick: onCardClick,
                    onOpenChat: onOpenChat
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .myLocationEffect($myLocation)
        // 화면이 보이는 동안만 SSE 를 구독하고 폴백 폴링을 돌린다 — 위에 22 상세·24 채팅방이 올라오거나
        // 앱이 백그라운드로 가면 둘 다 멈추고, 돌아오면 그 자리에서 다시 붙는다.
        // 끊어도 안전한 근거는 **재연결마다 서버가 방 상세 전체를 다시 준다**는 것이다(MatchWaitingViewModel.visible).
        .lifecycleEffect(
            onStart: { viewModel.onScreenStart() },
            onStop: { viewModel.onScreenStop() }
        )
        .task(id: action.left) {
            if action.left { onCancelSearch() }
        }
        .task(id: action.finished) {
            if action.finished { onPartyClosed() }
        }
        // 서버가 방을 닫았다(SSE closed) — 다른 참여자의 「합승 완료」·30분 만료·마지막 멤버 이탈.
        // 예전에는 폴링이 FINISHED/CANCELED 를 읽어 와야 알았고, 지금은 신호 하나로 바로 떠난다.
        .task(id: closed) {
            if closed { onPartyClosed() }
        }
        // **나는 이 방 멤버가 아니다**(SSE 403 · 상세에서 내가 사라짐). 「방이 닫혔다」와 다른 사실이지만
        // 할 일은 같아 같은 길로 보낸다 — 진행 중 기억을 지우고 홈으로. 그대로 머무르면 내가 들어 있지
        // 않은 방을 6초마다 폴링하며 「같이 탈 사람을 찾고 있어요」를 띄우고, 「그만 찾기」도 403 이라
        // 벗어날 길이 없다(MatchWaitingViewModel.membershipLost).
        //
        // 기억을 지우는 쪽(onPartyClosed)을 고른 이유: 그 방은 내 방이 아니므로 홈 배너가 다시
        // 그리로 데려가면 같은 자리로 되돌아온다. 방을 유지하는 onExitKeepingParty 는 "내가 어느 방에
        // 있는지 모를 때"의 길이고, 여기서는 **모르는 게 아니라 아니라는 걸 안다.**
        .task(id: membershipLost) {
            if membershipLost { onPartyClosed() }
        }
        // 매칭 시작 버튼이 없어졌으므로, 25 배차 현황으로의 이동은 서버 status 전이가 유일한 신호다.
        // 그 전이는 SSE 로 오지 않지만(서버 발행처가 참여·퇴장·종료뿐) 정원이 찬 뒤 서버가 곧바로 배차를
        // 시작하므로, 변경분에 실려 온 status 와 끊김 폴백의 상세가 함께 그 전이를 비춘다.
        .task(id: status) {
            switch status {
            case .dispatching, .ongoing: onMatchingStarted()
            case .completed, .canceled: onPartyClosed()
            default: break
            }
        }
    }
}

// 21 「탐색 반경」 라벨을 만들던 radiusLabel/meters 는 지웠다(2026-10-14) — 반경이 서버 고정값이
// 되면서(Backend `a668aee`) 사용자가 정한 조건이 아니게 됐고, 매칭은 그 값을 읽지도 않는다
// (합류에 거리 검사 없음, 목록은 지도 뷰포트). 도메인 `Ride` 에서도 반경 필드를 뺐다.
