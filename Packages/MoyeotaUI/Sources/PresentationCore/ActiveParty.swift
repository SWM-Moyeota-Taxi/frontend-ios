import Foundation
import MoyeotaDesignSystem
import MoyeotaDomain
import Observation
import SwiftUI

/// 진행 중인 방이 지금 어느 단계인가. 서버 status 하나로는 갈리지 않는다 —
/// `dispatching` 은 「기사 찾는 중」과 「배정돼 오는 중」을 함께 담고, 둘은 `Ride.driverId` 로 갈린다
/// (55 리포트의 25b/25c 판정 규칙과 같은 기준을 쓴다).
///
/// `ride?.activeStage == .none` 은 `Optional.none`(nil 비교)으로 읽히니, 옵셔널 자리에서는 `ActiveStage.none` 으로 적는다.
public enum ActiveStage: CaseIterable, Hashable, Sendable {
    /// 21 매칭 대기 — 아직 사람을 모으는 중
    case waiting

    /// 25b 기사 찾는 중
    case driverSearch

    /// 25c·25 택시 오는 중
    case driverComing

    /// 26 운행 중
    case ongoing

    /// 끝났거나(COMPLETED·CANCELED) 단계로 옮길 수 없는 상태
    case none
}

public extension Ride {
    var activeStage: ActiveStage {
        if status == .recruiting || status == .matched { return .waiting }
        if status == .dispatching && driverId == nil { return .driverSearch }
        if status == .dispatching { return .driverComing }
        if status == .ongoing { return .ongoing }
        return .none
    }

    /// 배너·카드에 쓰는 단계 문구. 각 단계 화면의 헤더 제목과 같은 말을 쓴다.
    var activeStageLabel: String {
        switch activeStage {
        // 정원이 찬 방(COMPLETED)은 「찾는 중」이 아니다. 기사 모드에선 순간이라 거의 안 보이고,
        // 1차 배포 모드에선 채팅으로 만나는 동안 계속 이 문구다.
        case .waiting: status == .matched ? "같이 탈 사람이 모였어요" : "같이 탈 사람 찾는 중"
        case .driverSearch: "기사님 찾는 중"
        case .driverComing: "택시 오는 중"
        case .ongoing: "운행 중"
        case .none: "진행 중 탑승"
        }
    }
}

/// 진행 중인 방의 채팅방을 다시 찾아보는 주기. 정원이 차야 방이 생기므로 한 번에 못 찾는 게 정상이다.
private let CHAT_ROOM_POLL_INTERVAL_MS: Int64 = 10_000

/// 「방금 끝난 조회」로 볼 창. 화면 진입 한 번에 여러 효과가 연달아 `ActivePartyViewModel.refresh` 를
/// 부르는 것만 흡수하면 되므로 **짧게** 잡는다 — QA 가 잰 중복은 25ms 간격이었고(119 D-2), 전이
/// 애니메이션을 타고 들어오는 재구성도 수백 ms 안이다.
///
/// 길게 잡으면 그만큼 배너·단계가 늦게 바뀐다. 특히 정원이 차는 순간 21 이 거는 재조회
/// (`MainNavGraph` 의 `onMatchingStarted`)까지 삼키면 채팅방 id 가 한 박자 늦는다 — 그래서 0.5초다.
private let RESOLVE_DEDUP_WINDOW_MS: Int64 = 500

/// 같은 조회를 연달아 날리지 않게 막는 문. 「진행 중인 조회가 있다」와 「방금 끝난 조회가 있다」를
/// 함께 본다 — 앞엣것만 보던 `refreshing` 플래그로는 **순서대로** 들어오는 중복(앱 재개 직후의
/// 탭 진입 등)이 그대로 통과했다.
///
/// `ActivePartyViewModel` 밖에 둔 이유는 하나뿐이다 — 뷰모델 없이 시계만 가짜로 넣어 검증할 수 있게 하려는 것.
///
/// 시계는 단조 시계(`DispatchTime`)다. 벽시계는 사용자가 시간을 바꾸거나 NTP 가 보정하면 뒤로 갈 수 있고,
/// 그러면 창이 닫히지 않은 것처럼 보여 재조회가 오래 막힌다.
final class ResolveGate {
    private let windowMs: Int64
    private let nowMs: () -> Int64
    private var inFlight = 0
    private var finishedAtMs: Int64?

    init(
        windowMs: Int64 = RESOLVE_DEDUP_WINDOW_MS,
        nowMs: @escaping () -> Int64 = { Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000) }
    ) {
        self.windowMs = windowMs
        self.nowMs = nowMs
    }

    /// 겹치지 않을 때만 들어간다. 들어갔으면 반드시 `leave` 로 닫는다.
    func tryEnter() -> Bool {
        if inFlight > 0 { return false }
        if let finishedAtMs, nowMs() - finishedAtMs < windowMs { return false }
        inFlight += 1
        return true
    }

    /// 창을 무시하고 들어간다. **조회의 전제가 방금 바뀐 경우**에만 쓴다(합류·방 생성 직후) —
    /// 그때 「방금 끝난 조회」는 합류 **이전**의 사실이라 재사용하면 안 된다. 억제는 그래서 비대칭이다.
    func enterNow() {
        inFlight += 1
    }

    /// 조회가 끝났다. 실패도 창에 넣는다 — 같은 실패를 몇십 ms 뒤에 반복해 봐야 결과가 같다.
    func leave() {
        if inFlight > 0 { inFlight -= 1 }
        finishedAtMs = nowMs()
    }
}

/// 합류·생성 직후 방 상세를 **다시 읽어야 하는가**. 홀더가 이미 그 방을 들고 있으면 읽을 것이 없다
/// — 21 이 곧바로 자기 상세를 읽고, 배너·채팅 헤더가 보는 값은 이미 그 방이다.
///
/// id 비교는 Int64 로 한다. 호출부가 `ride.id`(매퍼가 만든 문자열)와 `String(joinedPartyId)` 두
/// 가지 길로 들어와 문자열 모양이 어긋날 수 있다.
func needsDetailAfterRemember(held: Ride?, partyId: Int64) -> Bool {
    held.flatMap { Int64($0.id) } != partyId
}

/// 지금 채팅방을 찾아야 하는가(`ActivePartyViewModel.pollChatRoom` 의 판정).
///
/// `visible` 이 맨 앞인 게 이 함수의 요점이다 — **보이지 않는 동안에는 나머지 조건을 보지 않는다.**
/// 예전에는 이 조건이 없어서, 진행 중인 방이 있고 채팅방이 아직 없는 사용자는 **어느 화면에 있든, 앱이
/// 백그라운드여도** 10초마다 `GET /chat-rooms/me` 를 보냈다(QA 119 D-1 과 같은 성격의 누수,
/// `_workspace/120_compose-builder_explore-poll-gate.md` §5 가 유일하게 남은 건으로 지목한 자리).
///
/// 나머지 세 조건은 예전 루프가 매 주기 `continue` 로 걸러낸 것과 같다 — 방이 없으면 찾을 대상이 없고,
/// 이미 찾았으면 다시 찾을 이유가 없고(그래서 **찾는 순간 루프가 끝난다**), 끝난 방(`ActiveStage.none`)의
/// 채팅방은 열어 줄 데가 없다.
func shouldPollChatRoom(visible: Bool, ride: Ride?, chatRoomId: Int64?) -> Bool {
    guard visible, chatRoomId == nil, let ride else { return false }
    return ride.activeStage != ActiveStage.none
}

/// "지금 내가 타고 있는 방"을 화면 전체가 함께 보는 홀더.
///
/// **내비게이션 스택 바깥(앱 루트)에 한 인스턴스만 둔다** — 홈·합승 배너와 앱 시작 시
/// 단계 복귀가 같은 값을 봐야 하고, 화면마다 만들면 탭을 옮길 때마다 같은 조회를 반복한다
/// (`UserProfileViewModel` 과 같은 배치).
///
/// `ActivePartyRepository.resolve` 는 네트워크 실패에 예외를 던지지 않고 nil 을 준다 — 그래서
/// Loading/Error 3상태를 두지 않는다. 못 찾으면 배너를 숨기는 것이 전부다.
@MainActor
@Observable
public final class ActivePartyViewModel {
    public private(set) var ride: Ride? {
        didSet { syncPollTarget() }
    }

    /// 첫 `resolve` 가 끝났는가. 앱 시작 시 「홈 대신 단계 화면」 판단은 이 값이 true 가 된 뒤에만 한다
    /// — 아직 모르는 상태(nil)와 없는 상태(nil)를 구분할 길이 이것뿐이다.
    public private(set) var resolvedOnce = false

    /// 진행 중인 방에 딸린 채팅방 id. 정원이 차기 전에는 방이 없어 nil 이고, 그때 21·25 의
    /// 「채팅 열기」는 아예 그리지 않는다 — 눌러도 열 것이 없는 버튼을 두지 않는다.
    public private(set) var chatRoomId: Int64? {
        didSet { syncPollTarget() }
    }

    // 위 채팅방 id 가 어느 방의 것인지. 방이 바뀌면 즉시 무효로 만든다.
    @ObservationIgnored private var chatRoomPartyId: Int64?

    /// 앱 화면이 지금 보이는가. `pollChatRoom` 의 게이트다.
    ///
    /// **기본값이 true 인 이유**: 이 값을 내려 주는 배선(`onHostStart`·`onHostStop`)은 `MainNavGraph`
    /// 에 있고 그 파일은 다른 계층이 쥐고 있다. 배선이 붙기 전에는 지금까지와 똑같이 돌아야 한다
    /// — false 로 시작하면 배선이 빠진 채로 합쳐졌을 때 21 의 「채팅 열기」가 **영영 뜨지 않는다**.
    @ObservationIgnored private var hostVisible = true {
        didSet { syncPollTarget() }
    }

    /// 지금 채팅방을 찾아야 할 방 id. 원본의 `combine(hostVisible, ride, chatRoomId)` 결과다.
    ///
    /// 방 id 만 담는다. `Ride` 를 그대로 담으면 status 가 바뀔 때마다 패스가 다시 시작돼 10초 타이머가 초기화된다.
    @ObservationIgnored private let pollTarget = MutableStateFlow<Int64?>(nil)

    // 재조회 중복 방지 — 홈 진입 효과·앱 재개 효과·init 이 같은 프레임에 겹치거나
    // 몇십 ms 차로 잇따라 들어온다. 겹침만 막던 플래그를 「방금 끝난 조회」까지 보는 문으로 바꿨다.
    @ObservationIgnored private let resolveGate: ResolveGate

    @ObservationIgnored private let activePartyRepository: any ActivePartyRepository
    @ObservationIgnored private let chatRepository: any ChatRepository
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let scope = ViewModelScope()

    public convenience init(
        activePartyRepository: any ActivePartyRepository,
        chatRepository: any ChatRepository
    ) {
        self.init(
            activePartyRepository: activePartyRepository,
            chatRepository: chatRepository,
            sleep: { try await Task.sleep(for: $0) },
            resolveGate: ResolveGate()
        )
    }

    init(
        activePartyRepository: any ActivePartyRepository,
        chatRepository: any ChatRepository,
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        resolveGate: ResolveGate
    ) {
        self.activePartyRepository = activePartyRepository
        self.chatRepository = chatRepository
        self.sleep = sleep
        self.resolveGate = resolveGate
        refresh()
    }

    /// 화면 복귀(앱 재개·탭 진입)마다 부른다. 로컬 기억이 있으면 상세 1회로 끝나는 가벼운 조회다.
    ///
    /// 진입 한 번에 여러 효과가 겹쳐 부르는 것은 `ResolveGate` 가 흡수한다 — 진행 중인 조회가 있거나
    /// `RESOLVE_DEDUP_WINDOW_MS` 안에 끝난 조회가 있으면 그 결과를 그대로 쓴다.
    public func refresh() {
        if !resolveGate.tryEnter() { return }
        scope.launch { [weak self] in
            guard let self else { return }
            await self.reload()
            self.resolveGate.leave()
        }
    }

    /// 방 생성·합류 성공 직후. 기억을 심고, **홀더가 아직 그 방을 모를 때만** 상세를 읽는다.
    ///
    /// 조회를 아예 걷어내지 않은 이유(QA 119 D-2 의 두 선택지 중 뒤쪽을 고른 근거): `ride` 는 앱 전체가
    /// 공유하는 **유일한 `Ride` 값**이다 — 14·17 배너, 24 채팅 헤더의 「매칭 화면으로 →」(`MainNavGraph`
    /// 가 `activeRide?.id` 로 가른다), `pollChatRoom` 의 게이트가 모두 이 값에 달려 있다. 21 이 읽는
    /// 상세는 21 자신의 상태로만 쓰이고 이 홀더로 흘러들지 않으므로, 여기서 조회를 지우면 홀더는 빈 채로
    /// 남는다. 그러면
    /// - 홈·합승으로 돌아갈 때 각 화면의 `refresh()` 가 채워 주긴 하지만 **한 왕복
    ///   동안 배너가 비어 보이고**(그 조회가 실패하면 다음 복귀까지 계속 비어 있다),
    /// - 그 전에 21 에서 채팅을 열면 헤더의 매칭 화면 링크가 사라지며,
    /// - `pollChatRoom` 이 `ride == nil` 에서 멈춰 21 의 「채팅 열기」가 아예 뜨지 않는다
    ///   (채팅방은 합류 시점에 생기므로 21 에서 떠야 하는 버튼이다).
    ///
    /// 그래서 지우는 대신 **겹치는 것만** 지운다.
    /// - 이미 그 방을 들고 있으면(`needsDetailAfterRemember`) 상세를 건너뛴다 — 서버가 「이미 이 방
    ///   멤버」라고 답해 합류 교착에서 복구된 경로가 여기로 온다. 채팅방 id 만 아직이면 그것만 따로
    ///   찾는다(채팅방 목록 1회, 방 상세 0회).
    /// - 읽어야 할 때는 창을 무시하고 읽는다(`ResolveGate.enterNow`) — 직전 조회는 합류 **이전**의
    ///   사실이라 재사용하면 방금 들어간 방을 놓친다. 대신 끝난 시각을 남겨, 전이 도중의 재구성으로
    ///   뒤따라 들어오는 `refresh()` 를 흡수한다.
    ///
    /// 21 진입에 남는 상세 1건(21 자신의 조회)은 계층이 달라 이 파일에서 지울 수 없다 —
    /// `RideRepository.getPartyDetail` 에 짧은 TTL 캐시를 두거나 21 의 SSE 첫 스냅샷을 홀더로 밀어
    /// 넣어야 한다.
    ///
    /// 숫자가 아니거나 0 이하인 id 는 심지도, 읽지도 않는다 — 그런 값은 `GET /matching/rooms/0` 404 로만
    /// 끝난다(`RemoteActivePartyRepository` 가 같은 기준으로 한 번 더 막는다).
    public func rememberParty(partyId: String) {
        guard let id = Int64(partyId), id > 0 else { return }
        scope.launch { [weak self] in
            guard let self else { return }
            try? await self.activePartyRepository.remember(partyId: String(id))
            if let held = self.ride, !needsDetailAfterRemember(held: held, partyId: id) {
                if self.chatRoomId == nil && held.activeStage != ActiveStage.none {
                    await self.lookupChatRoom(partyId: id)
                }
                return
            }
            self.resolveGate.enterNow()
            await self.reload()
            self.resolveGate.leave()
        }
    }

    /// 나가기 성공·FINISHED/CANCELED 확인. 로컬 기억까지 지운다.
    public func clearParty() {
        scope.launch { [weak self] in
            guard let self else { return }
            try? await self.activePartyRepository.clear()
            self.ride = nil
            self.chatRoomId = nil
            self.chatRoomPartyId = nil
        }
    }

    /// 채팅방 캐시만 비운다 — 「채팅방 나가기」 성공 뒤, 또는 캐시된 방에서 403(참여자 아님)을 받았을 때.
    /// 방(party)은 그대로이므로 `pollChatRoom` 이 다음 주기에 다시 찾는다(서버가 되살려 주면 붙는다).
    /// 비우지 않으면 26 의 「채팅 열기」가 죽은 방 id 로 계속 403 을 맞는다(실기 QA).
    public func forgetChatRoom() {
        chatRoomId = nil
        chatRoomPartyId = nil
    }

    /// 로그아웃·세션 만료용 **메모리 초기화**. 로컬 기억은 건드리지 않는다 —
    /// 그 기억은 계정에 매인 것이고, 같은 계정으로 다시 로그인하면 그대로 되살아나야 한다.
    public func forget() {
        ride = nil
        chatRoomId = nil
        chatRoomPartyId = nil
        resolvedOnce = false
    }

    /// 앱 화면이 보이기 시작했다 / 가려졌다. **`MainNavGraph` 가 호스트 수명으로 불러 줘야 한다**:
    ///
    /// ```
    /// .lifecycleEffect(
    ///     onStart: { activePartyViewModel.onHostStart() },
    ///     onStop: { activePartyViewModel.onHostStop() }
    /// )
    /// ```
    ///
    /// 앱 전면 복귀(`scenePhase`)를 보는 쪽이지, 화면 전환 애니메이션이 끝나기를 기다리지 않는다 — 기다리면
    /// 복귀 첫 조회가 그만큼 늦는다. 같은 이유로 17 탐색(`ExploreRoute.onScreenStart`)·24 채팅
    /// (`ChatRoute`)·GPS 구독(`MyLocationState`)이 모두 같은 효과를 쓴다.
    ///
    /// 이 뷰모델은 내비게이션 스택 **바깥**(앱 루트)이라 화면 전환으로는 가려지지 않는다 —
    /// 여기서 잡히는 것은 **앱 자체가 백그라운드로 가는 순간**이다. 그래서 신호 하나로 족하고,
    /// 화면별 가시성은 볼 필요가 없다(홈이든 21 이든 진행 중 방의 채팅방은 똑같이 필요하다).
    public func onHostStart() {
        hostVisible = true
    }

    /// `onHostStart` 참고.
    public func onHostStop() {
        hostVisible = false
    }

    /// 채팅방이 생겼는지 주기적으로 확인한다. **호출자(앱 루트)의 `.task` 에서 돌린다** —
    /// 뷰가 사라지면 함께 멈춘다(25 pollDriver 와 같은 배치).
    ///
    /// 다만 앱 루트 뷰는 **앱이 백그라운드로 가도 살아 있다.** 그래서 뷰 수명만으로는
    /// 부족하고, `hostVisible` 로 한 번 더 막는다(`shouldPollChatRoom`) — 가시성·방·채팅방 세 값이
    /// 바뀌면 `pollTarget` 이 바뀌어 **조건이 깨지면 진행 중인 조회와 대기가 함께 죽는다**
    /// (17 탐색이 쓴 모양과 같다. 깨어나 아무 일도 안 하는 주기조차 남기지 않는다).
    ///
    /// 멈추는 조건: 앱이 가려짐 · 진행 중인 방이 없음 · **채팅방을 찾음** · 끝난 방.
    /// 다시 켜지는 조건: 그 조건이 되돌아감 — 앱 복귀, 방 생성·합류(`rememberParty`),
    /// 그리고 「채팅방 나가기」로 캐시를 버린 뒤(`forgetChatRoom`). 되돌아오면 **10초 뒤** 첫 조회다
    /// (즉시 1회를 붙이지 않은 이유: 홈·합승 진입과 앱 복귀는 이미 `refresh()` → `reload()` 가
    /// 채팅방을 **그 자리에서** 한 번 찾는다. 즉시 조회를 또 붙이면 복귀마다 2건이 된다).
    ///
    /// 모집 중(21)에도 찾는다 — 서버가 채팅방을 **합류 시점에** 만든다(Backend #109). 예전엔 정원이 차야
    /// 생겨서 대기 중엔 건너뛰었는데, 그대로 두면 1차 배포 모드(정원 차도 대기 단계)에선 영영 안 뜬다.
    public func pollChatRoom() async {
        var pass: Task<Void, Never>?
        // `collectLatest` 의 자리 — 새 값이 오면 앞 패스를 취소하고, 호출자가 취소되면 루프가 끝난다.
        for await partyId in pollTarget.values() {
            pass?.cancel()
            pass = nil
            guard let partyId else { continue }
            let sleep = self.sleep
            pass = Task { [weak self] in
                while !Task.isCancelled {
                    do {
                        try await sleep(.milliseconds(CHAT_ROOM_POLL_INTERVAL_MS))
                    } catch {
                        return
                    }
                    await self?.lookupChatRoom(partyId: partyId)
                }
            }
        }
        pass?.cancel()
    }

    private func syncPollTarget() {
        let visibleRide = shouldPollChatRoom(visible: hostVisible, ride: ride, chatRoomId: chatRoomId) ? ride : nil
        pollTarget.value = visibleRide.flatMap { Int64($0.id) }
    }

    private func reload() async {
        let resolved: Ride?
        do {
            resolved = try await activePartyRepository.resolve()
        } catch {
            // 저장소는 네트워크 실패에 던지지 않는다. 태스크가 정말 취소됐으면 아무것도 바꾸지 않는다.
            // 살아 있는 태스크의 `URLError(.cancelled)` 는 원본에서 「판단 보류」로 null 이 되는 `IOException` 이다 —
            // 저장소가 그 값만 그대로 던지므로 여기서 같은 결과를 만든다(안 그러면 `resolvedOnce` 가 서지 않는다).
            if Task.isCancelled { return }
            resolved = nil
        }
        ride = resolved
        resolvedOnce = true
        let partyId = resolved.flatMap { Int64($0.id) }
        if partyId == nil || partyId != chatRoomPartyId {
            chatRoomId = nil
            chatRoomPartyId = nil
        }
        guard let resolved else { return }
        if chatRoomId == nil, resolved.activeStage != ActiveStage.none, let partyId {
            await lookupChatRoom(partyId: partyId)
        }
    }

    /// 방 id → 채팅방 id. 서버에 「이 방의 채팅방」을 직접 묻는 API 가 없어
    /// `GET /chat-rooms/me` 를 훑는다. 실패는 삼킨다 — 채팅 버튼이 늦게 뜰 뿐이다.
    ///
    /// 방 id 를 `Ride` 가 아니라 Int64 로 받는다 — 호출부 세 곳(복귀 조회·합류 직후·폴링) 중
    /// 폴링은 Ride 값을 들고 있을 이유가 없고(`pollTarget` 참고), 나머지 둘도 id 만 쓴다.
    private func lookupChatRoom(partyId: Int64) async {
        guard let rooms = try? await chatRepository.getMyChatRooms() else { return }
        // 목록 응답에는 partyId 가 없다(서버 ChatRoomUserResult) — 목록만 보면 0 이라 영영 못 찾는다.
        // 목록에 이미 값이 있으면 그걸 쓰고, 없으면 **닫히지 않은 방만** 상세를 읽어 partyId 를 확인한다.
        // 찾는 순간 채팅방 id 를 기억하고 이후 폴링은 멈추므로(pollChatRoom) 상세 조회는 몇 번 안 된다.
        var roomId = rooms.first { $0.room.partyId == partyId }?.room.id
        if roomId == nil {
            for candidate in rooms where candidate.room.partyId == 0 && candidate.room.status != .closed {
                if Task.isCancelled { return }
                let room = try? await chatRepository.getChatRoom(chatRoomId: candidate.room.id)
                if room?.partyId == partyId {
                    roomId = candidate.room.id
                    break
                }
            }
        }
        // 코루틴은 취소되면 다음 대기 지점에서 던져 여기까지 오지 않는다. URLSession 은 취소와 응답이 엇갈릴 수 있어 직접 본다.
        guard let roomId, !Task.isCancelled else { return }
        chatRoomPartyId = partyId
        chatRoomId = roomId
    }
}

/// 14 홈 · 17 합승 상단의 「진행 중 탑승 · 보기」 배너.
///
/// 문구는 단계별로 갈린다 — 「진행 중 탑승」 한마디로는 지금 눌러야 하는지(택시가 오는 중)와
/// 그냥 기다리면 되는지(사람 찾는 중)를 구분할 수 없다.
public struct ActiveRideBanner: View {
    private let ride: Ride
    private let onClick: () -> Void

    public init(ride: Ride, onClick: @escaping () -> Void) {
        self.ride = ride
        self.onClick = onClick
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .circular)
        let textType = inheritedBodyLargeType(13, .bold)
        Button(action: onClick) {
            HStack(spacing: 0) {
                Circle()
                    .fill(MoyeotaColor.Primary500)
                    .frame(width: 8, height: 8)
                Spacer().frame(width: 10)
                Text(ride.activeStageLabel)
                    .moyeotaText(textType, color: MoyeotaColor.InkPrimary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer().frame(width: 8)
                Text(ride.destination)
                    .moyeotaText(textType.copy(fontWeight: .medium), color: MoyeotaColor.TextMute)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer().frame(width: 8)
                Text("보기")
                    .moyeotaText(textType, color: MoyeotaColor.Primary600)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityLabel("보기 ›")
                Spacer().frame(width: 3.5)
                GlyphMark(.chevronRight, color: MoyeotaColor.Primary600, lineWidth: 1.2)
                    .offset(y: 1.1)
            }
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(MoyeotaColor.SurfaceCanvas, in: shape)
            .clipShape(shape)
        }
        .buttonStyle(PressOverlayStyle(shape: shape))
        // 그림자도 토큰에서 뽑는다 — 예전 배너는 같은 값을 0x29085AF5 로 박아 두고 있었다
        .moyeotaShadow(elevation: 8, shape: shape, spotColor: MoyeotaColor.Primary500.copy(alpha: 0.16))
    }
}

/// 21·25 의 「채팅 열기」. **채팅방이 실제로 있을 때만** 그린다(호출부가 nil 검사로 가른다).
///
/// 26 운행 중에는 같은 이름의 버튼이 화면 레이아웃 안에 이미 박혀 있어 여기서 쓰지 않는다.
///
/// 원본 호출부가 전부 `Modifier.fillMaxWidth()` 를 넘겨, 폭을 채우는 것을 이 뷰의 기본 모양으로 삼았다.
public struct OpenChatButton: View {
    private let onClick: () -> Void

    public init(onClick: @escaping () -> Void) {
        self.onClick = onClick
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .circular)
        Button(action: onClick) {
            Text("채팅 열기")
                .moyeotaText(inheritedBodyLargeType(15, .bold), color: MoyeotaColor.Primary600)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(MoyeotaColor.Primary50, in: shape)
        }
        .buttonStyle(PressOverlayStyle(shape: shape))
    }
}
