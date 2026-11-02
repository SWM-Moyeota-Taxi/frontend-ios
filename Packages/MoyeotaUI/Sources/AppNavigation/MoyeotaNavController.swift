import MoyeotaDesignSystem
import Observation
import PresentationCore

/// 백스택의 한 칸. 원본 `NavBackStackEntry` 자리 — 같은 라우트가 두 번 쌓여도 칸마다 다른 `id` 를 갖는다.
///
/// 저장된 스택을 복원하면 **같은 `id`** 로 돌아온다(원본 `NavBackStackEntryState` 가 id 를 보존한다). 탭 상태가
/// `id` 에 묶여 있어(`MoyeotaNavController.retained`) 이 사실이 곧 「복원하면 상태가 돌아온다」이다.
public struct NavBackStackEntry: Hashable, Identifiable, Sendable {
    public let id: Int64
    public let route: Route

    init(id: Int64, route: Route) {
        self.id = id
        self.route = route
    }
}

/// `navigate(route) { … }` 의 옵션 블록. 원본 `NavOptionsBuilder` 중 `MainNavGraph` 가 쓰는 것만 있다.
public struct NavOptionsBuilder {
    enum PopUpTarget: Equatable {
        /// 원본 `popUpTo(0)` — 루트 그래프까지. 스택 전체다.
        case graphRoot
        case route(Route)
    }

    var popUpTarget: PopUpTarget?
    var popUpToInclusive = false
    var popUpToSaveState = false
    public var launchSingleTop = false
    public var restoreState = false

    public mutating func popUpTo(_ route: Route, inclusive: Bool = false, saveState: Bool = false) {
        popUpTarget = .route(route)
        popUpToInclusive = inclusive
        popUpToSaveState = saveState
    }

    /// 원본 `popUpTo(0) { inclusive = true }`.
    mutating func popUpToGraphRoot() {
        popUpTarget = .graphRoot
        popUpToInclusive = true
        popUpToSaveState = false
    }
}

/// 원본 `NavController` 중 `MainNavGraph.kt` 가 기대는 의미를 그대로 옮긴 순수 클래스. SwiftUI 를 모른다.
///
/// 스택의 **모양을 정하는 진실은 여기 하나다.** `NavigationStack` 은 이 값을 그리기만 한다(`projectBackStack`).
/// 원본의 동작을 라이브러리(navigation-runtime 2.9.8)에서 읽어 옮긴 규칙이 넷 있다.
/// - 대화상자가 맨 위일 때 일반 목적지로 가면 대화상자가 먼저 빠진다(`addEntryToBackStack`).
/// - `popUpTo(HOME) { saveState = true }` 는 탭 하나가 아니라 **HOME 위의 스택 전체**를 맨 아래 칸 이름으로 보관하고,
///   `restoreState = true` 는 그 전체를 되살린다. 그래서 탭에서 쌓아 연 21·24 도 탭을 다녀오면 그대로 돌아온다.
/// - 맨 위가 이미 목적지인데 `inclusive = false` 로 pop 하면 아무것도 빠지지 않아 **false** 다.
/// - 마지막 한 칸을 pop 하면 빈 스택이 되고 false 다(`MainNavGraph` 주석의 「화면 없는 빈 그래프」 함정).
@MainActor
@Observable
public final class MoyeotaNavController {
    public private(set) var backStack: [NavBackStackEntry]

    /// 목적지 → 저장된 스택 번호. 값이 nil 인 자리가 있는 이유: 원본은 스택이 그대로인 `popUpTo(HOME) { saveState = true }`
    /// (홈에서 첫 탭으로 갈 때)에도 `HOME → 빈 값` 을 적어 둔다. 그 뒤로 HOME 자리는 덮어쓰이지 않는다.
    @ObservationIgnored private var backStackMap: [String: Int?] = [:]
    @ObservationIgnored private var backStackStates: [Int: [NavBackStackEntry]] = [:]
    @ObservationIgnored private var nextEntryId: Int64 = 1
    @ObservationIgnored private var nextStateId = 1

    /// 칸마다 맡아 두는 상태 — 원본 엔트리의 `ViewModelStore`·저장 상태 자리.
    @ObservationIgnored private var retainedStates: [Int64: [ObjectIdentifier: AnyObject]] = [:]
    /// 방금 죽은 칸의 상태. 사라지는 화면이 전환 애니메이션 동안 다시 그려져도 새 뷰모델을 만들지 않게 잠깐 들고 있다.
    @ObservationIgnored private var retiringStates: [Int64: [ObjectIdentifier: AnyObject]] = [:]

    /// - Parameter startDestination: 원본 `NavHost(startDestination:)`. 뒤의 로그인 전이가 스택을 바꿔도 이 값을 다시 보지 않는다.
    public init(startDestination: Route) {
        backStack = [NavBackStackEntry(id: 0, route: startDestination)]
    }

    // ─── 읽기 ───

    /// 원본 `currentDestination?.route` + 인자.
    public var currentRoute: Route? { backStack.last?.route }

    /// 원본 `currentBackStackEntry`.
    public var currentBackStackEntry: NavBackStackEntry? { backStack.last }

    /// 원본 `previousBackStackEntry`.
    public var previousBackStackEntry: NavBackStackEntry? {
        backStack.count >= 2 ? backStack[backStack.count - 2] : nil
    }

    // ─── 원본 NavController 의 의미 ───

    /// 원본 `navigate(route) { … }`.
    public func navigate(_ route: Route, _ configure: (inout NavOptionsBuilder) -> Void = { _ in }) {
        var options = NavOptionsBuilder()
        configure(&options)
        switch options.popUpTarget {
        case .graphRoot:
            removeTop(backStack.count)
        case .route(let target):
            _ = popBackStackInternal(target, inclusive: options.popUpToInclusive, saveState: options.popUpToSaveState)
        case nil:
            break
        }
        if options.restoreState, backStackMap.keys.contains(route.destination) {
            // 라이브러리처럼 복원은 launchSingleTop 을 보지 않는다.
            for entry in takeSavedStack(destination: route.destination) {
                addEntry(entry)
            }
        } else if options.launchSingleTop, backStack.last?.route.destination == route.destination {
            // 맨 위가 이미 그 목적지면 새 칸을 만들지 않는다 — 칸이 그대로라 화면 상태도 남는다.
        } else {
            addEntry(makeEntry(route))
        }
        pruneRetainedStates()
    }

    /// 원본 `popBackStack()` — 맨 위 한 칸. 마지막 칸을 빼면 빈 스택이 되고 false 다.
    @discardableResult
    public func popBackStack() -> Bool {
        guard !backStack.isEmpty else { return false }
        removeTop(1)
        pruneRetainedStates()
        return !backStack.isEmpty
    }

    /// 원본 `popBackStack(route, inclusive, saveState)`. 뺀 것이 없으면 false 다.
    @discardableResult
    public func popBackStack(_ route: Route, inclusive: Bool, saveState: Bool = false) -> Bool {
        let popped = popBackStackInternal(route, inclusive: inclusive, saveState: saveState)
        pruneRetainedStates()
        return popped && !backStack.isEmpty
    }

    /// 원본 `clearBackStack(route)` — 그 목적지 이름으로 보관된 스택을 버린다.
    ///
    /// 원본은 「복원한 뒤 그 목적지까지 pop」으로 구현돼 있어, 보관된 스택의 맨 아래가 그 목적지가 아니면(`HOME` 자리에 다른
    /// 스택이 적힌 드문 경우) 복원된 칸이 그대로 남는다. 주석에 적힌 의도(`resetAfterSignOut`)와 어긋나는 라이브러리 부작용이라
    /// 옮기지 않고 **버리기만** 한다.
    @discardableResult
    public func clearBackStack(_ route: Route) -> Bool {
        guard backStackMap.keys.contains(route.destination) else { return false }
        let cleared = !takeSavedStack(destination: route.destination).isEmpty
        pruneRetainedStates()
        return cleared
    }

    // ─── MainNavGraph 의 이동 함수 ───

    /// 스택을 통째로 비우고 `route` **하나만** 남긴다(`popUpTo(0) { inclusive = true }` 는 루트 그래프까지
    /// 걷어낸다).
    ///
    /// 그래서 쓸 수 있는 곳은 **그 화면이 스택 바닥이어도 되는 자리**뿐이다 — 13 가입 완료·로그인
    /// 직후의 14 홈, 33 도착 완료의 「확인」, 04/04a(로그아웃·세션 만료는 `resetAfterSignOut`).
    ///
    /// 진행 화면(25·26)에는 쓰지 않는다. 목적지가 하나뿐인 스택에서 뒤로가기를 누르면 그 하나가
    /// pop 돼 **화면 없는 빈 그래프**가 남고(`Route.loginForm` 의 onBack 이 가드를 둔 그 함정),
    /// 홈이 사라져 `navigateTab` 의 「탭 교체」도 「탭 쌓기」가 된다. 그 자리에는
    /// `popUpTo(.home)` 으로 **홈을 바닥에 남기는** 이동을 쓴다(26 진입·`navigateToStage` 가 그 모양이다).
    public func resetTo(_ route: Route) {
        navigate(route) {
            $0.popUpToGraphRoot()
            $0.launchSingleTop = true
        }
    }

    /// 로그아웃·세션 만료 전용 초기화.
    /// `popUpTo(0)` 은 "지금 스택"만 지운다 — 탭 전환이 saveState=true 로 따로 보관해 둔 엔트리는
    /// 상태째 살아남아, 새 계정으로 그 탭에 들어가면 이전 계정의 뷰모델이 복원된다.
    /// 채팅에서는 그게 이전 방을 향한 3초 폴링으로 나타났다(QA 결함-1: 새 토큰으로 403 반복).
    /// 저장분까지 명시적으로 폐기해 계정 전환 뒤에는 어떤 탭도 이전 상태를 되살리지 않게 한다.
    public func resetAfterSignOut(_ route: Route) {
        resetTo(route)
        TabRoutes.forEach { clearBackStack($0) }
        // 원본은 탭 넷의 이름으로 보관된 것만 지운다. 맨 아래가 21 처럼 탭이 아닌 저장분은 다시 꺼낼 길이 없어 보이지 않지만,
        // 그 안에 쌓였던 24 탭의 상태까지 함께 없애야 「새 계정이 이전 상태를 못 본다」가 예외 없이 맞다.
        backStackMap.removeAll()
        backStackStates.removeAll()
        pruneRetainedStates()
        retiringStates.removeAll()
    }

    /// 하단탭(14 홈 · 17 합승 · 24 채팅 · 35 마이) 이동 — 홈을 탭 루트로 유지
    public func navigateTab(_ tab: MoyeotaTab) {
        let route: Route = switch tab {
        case .home: .home
        case .explore: .explore
        case .chat: .chat
        case .mypage: .mypage
        }
        // 이미 그 탭이면 아무 것도 하지 않는다 (엔트리 재생성 방지)
        if currentRoute == route { return }
        if !backStack.contains(where: { $0.route == .home }) {
            // 홈이 스택에 없으면 아래 두 장치(홈 pop 복귀 · popUpTo(.home))가 **둘 다 무효**라
            // 탭이 교체가 아니라 그냥 쌓인다 — [rideOngoing, chatRoom, home] 처럼. 그러면 홈에서
            // 뒤로가기를 누를 때마다 방금 나온 채팅방·운행 중 화면이 되살아나고, 나간 방에 재진입도
            // 된다(403 → ErrorBox). 그때는 스택을 실제로 비워 홈을 바닥에 세운다.
            resetTo(.home)
            if route == .home { return }
            // 홈이 바닥에 섰다 — 아래 일반 경로가 그 위에 탭 하나를 세운다
        } else if route == .home {
            // 홈탭은 스택에 남아있는 기존 HOME 엔트리로 pop 복귀한다.
            // navigate 로 새 엔트리를 만들면 상태가 엔트리 id 로 묶여 있어 HomeScreen 의 저장값(지도 카메라 등)이 통째로 폐기된다.
            //
            // `saveState` 가 붙은 이유: 이 pop 은 **떠나는 탭 엔트리를 폐기한다.** 다른 탭으로 갈 때는
            // 아래 `popUpTo(.home, saveState: true)` + `restoreState` 가 지도 카메라·스크롤을 보관하는데
            // 홈 경유만 초기화되는 비대칭이 있었다(합승→채팅→합승은 보존, 합승→홈→합승은 초기화).
            //
            // 다만 **탭에서 떠날 때만** 켠다. `saveState = true` 인 pop 은 엔트리의 상태를 버리지 않는다 —
            // 21·25·26·채팅방에서 navigateTab(.home) 으로 빠져나오는 길까지 켜면 이미 떠난 방의 뷰모델이
            // 프로세스 끝까지 남는다(그 보관분을 지우는 clearBackStack 은 resetAfterSignOut 이 탭 넷에만 건다).
            let leavingTab = currentRoute.map { TabRoutes.contains($0) } == true
            if popBackStack(.home, inclusive: false, saveState: leavingTab) {
                return
            }
        }
        navigate(route) {
            // 홈을 탭 루트로 유지하고, 벗어나는 탭의 상태는 저장·복원한다
            $0.popUpTo(.home, saveState: true)
            $0.launchSingleTop = true
            $0.restoreState = true
        }
    }

    /// `navigateToStage` 의 목적지 표. 끝난 방(`ActiveStage.none`)은 갈 단계가 없어 nil 이다.
    ///
    /// | `Ride` | 목적지 |
    /// |---|---|
    /// | RECRUITING · MATCHED(서버 COMPLETED = 정원 충족) | 21 매칭 대기 |
    /// | DISPATCHING (기사 미배정) | 25b — `Route.dispatchStatus` 안에서 갈린다 |
    /// | DISPATCHING (기사 배정) | 25c·25 — 같은 라우트 |
    /// | ONGOING | 26 운행 중 |
    /// | 그 외(끝난 방) | 14 홈 |
    public static func stageRoute(_ stage: ActiveStage) -> Route? {
        switch stage {
        case .waiting: .matchWaiting
        // 25b/25c/25 는 한 라우트가 서버 status 로 갈아 끼운다(DispatchStatusRoute)
        case .driverSearch, .driverComing: .dispatchStatus
        case .ongoing: .rideOngoing
        // 끝난 방을 가리키는 배너가 남아 있을 수 있다 — 없는 단계로 보내는 대신 홈으로
        case .none: nil
        }
    }

    /// 단계 화면으로 가는 스택 이동. 방 id 기억·설정 재조회는 호스트의 `navigateToStage(ride:)` 가 한다.
    ///
    /// 스택은 **홈 위에 단계 화면 하나**로 만든다(resetTo 로 통째로 비우지 않는다) — 단계 화면의
    /// 뒤로가기가 갈 곳이 있어야 하고, 홈은 언제나 스택 바닥이라 popUpTo 로 나머지만 걷어내면 된다.
    public func navigateToStage(route: Route) {
        if currentRoute == route { return }
        // 그 단계 화면이 이미 스택에 있으면(채팅방을 쌓아 연 상태 등) **되돌아간다**.
        // 새로 쌓으면 같은 화면이 두 겹이 되고, 뒤로가기가 자기 자신으로 돌아가는 길이 생긴다.
        if popBackStack(route, inclusive: false) { return }
        navigate(route) {
            // 홈은 스택 바닥이라 여기까지만 걷어내면 「홈 위에 단계 화면 하나」가 된다.
            // 26 진입도 홈을 바닥에 남기므로(DispatchStatusRoute 의 onStartRide) 홈이 없는
            // 스택은 더 이상 만들어지지 않는다. 그래도 남았다면 `navigateTab` 이 홈부터 다시 세운다.
            $0.popUpTo(.home)
            $0.launchSingleTop = true
        }
    }

    /// 진행 화면(21·25·26)의 「채팅 열기」. 채팅 **탭**이 아니라 채팅방을 **쌓아** 연다 —
    /// 탭으로 보내면 매칭 화면이 스택에서 빠져 돌아올 길이 없어진다(이 작업의 출발점이 된 결함).
    public func openActiveChatRoom(roomId: Int64) {
        navigate(.chatRoom(roomId: roomId))
    }

    /// 채팅 알림 탭 → 그 채팅방. 현재 화면 위에 **쌓는다**(뒤로가기로 원래 자리 복귀). 이미 그 방이
    /// 맨 위면 다시 쌓지 않는다.
    public func openPendingChatRoom(roomId: Int64) {
        let target = Route.chatRoom(roomId: roomId)
        if currentRoute != target { navigate(target) }
    }

    // ─── SwiftUI 경로와의 연결 ───

    /// 스와이프로 `NavigationStack` 이 경로를 줄였을 때 그만큼 스택을 맞춘다.
    ///
    /// 받는 것은 **지금 경로의 앞부분**뿐이다. 프로그램으로 스택을 바꾼 직후에 늦게 도착한 옛 경로가 앞선 이동을 되돌리면
    /// 안 되므로, 앞부분이 아니거나 길이가 같으면 무시한다 — 스택의 주인은 이 클래스다.
    public func applyPoppedPath(_ newPath: [NavBackStackEntry]) {
        let current = projectBackStack(backStack)
        guard newPath.count < current.path.count, Array(current.path.prefix(newPath.count)) == newPath else { return }
        removeTop(current.path.count - newPath.count + (current.overlay == nil ? 0 : 1))
        pruneRetainedStates()
    }

    // ─── 칸별 상태 ───

    /// 이 칸에 묶인 상태. 칸이 스택에도 저장분에도 없게 되는 순간 함께 버린다 — 원본 엔트리의 `ViewModelStore` 와 같은 수명이다.
    ///
    /// 그래서 원본의 세 경우가 그대로 나온다: 탭을 떠나면(`saveState`) 남고, 21·25·26 에서 홈으로 가면(`saveState` 없음)
    /// 죽고, 로그아웃하면 전부 죽는다. `resetTo(.home)` 으로 새 홈 칸이 서면 새 상태다.
    public func retained<State: AnyObject>(for entry: NavBackStackEntry, make: () -> State) -> State {
        let key = ObjectIdentifier(State.self)
        if let found = retainedStates[entry.id]?[key] as? State { return found }
        if let retiring = retiringStates[entry.id]?[key] as? State { return retiring }
        let state = make()
        // 이미 죽은 칸이면 맡지 않는다. 맡아 두면 다음 정리 때까지 주인 없이 남는다.
        if isLive(entry.id) {
            retainedStates[entry.id, default: [:]][key] = state
        }
        return state
    }

    // ─── 내부 ───

    private func makeEntry(_ route: Route) -> NavBackStackEntry {
        defer { nextEntryId += 1 }
        return NavBackStackEntry(id: nextEntryId, route: route)
    }

    /// 원본 `addEntryToBackStack` — 일반 목적지가 올라오면 맨 위의 대화상자는 먼저 빠진다.
    private func addEntry(_ entry: NavBackStackEntry) {
        if !entry.route.isDialog {
            while let last = backStack.last, last.route.isDialog {
                backStack.removeLast()
            }
        }
        backStack.append(entry)
    }

    private func removeTop(_ count: Int) {
        backStack.removeLast(min(count, backStack.count))
    }

    /// 원본 `popBackStackInternal` + `executePopOperations`.
    private func popBackStackInternal(_ route: Route, inclusive: Bool, saveState: Bool) -> Bool {
        guard let index = backStack.lastIndex(where: { $0.route.destination == route.destination }) else {
            return false
        }
        let keepCount = inclusive ? index : index + 1
        let popped = Array(backStack[keepCount...])
        backStack.removeLast(popped.count)
        if saveState {
            save(popped, foundDestination: route.destination, inclusive: inclusive)
        }
        return !popped.isEmpty
    }

    /// 원본 `executePopOperations` 의 저장 부분. 이미 적힌 자리는 덮어쓰지 않는다.
    private func save(_ popped: [NavBackStackEntry], foundDestination: String, inclusive: Bool) {
        let stateId: Int? = popped.isEmpty ? nil : nextStateId
        if !inclusive, !backStackMap.keys.contains(foundDestination) {
            backStackMap[foundDestination] = .some(stateId)
        }
        guard let stateId, let first = popped.first else { return }
        nextStateId += 1
        if !backStackMap.keys.contains(first.route.destination) {
            backStackMap[first.route.destination] = .some(stateId)
        }
        // 어느 자리에도 적히지 못한 저장분은 다시 꺼낼 길이 없어 원본도 들고 있지 않는다.
        if backStackMap.values.contains(where: { $0 == stateId }) {
            backStackStates[stateId] = popped
        }
    }

    /// 저장된 스택을 꺼낸다. 한 번 꺼내면 그 스택을 가리키는 자리가 모두 지워진다(두 번 복원되지 않는다).
    private func takeSavedStack(destination: String) -> [NavBackStackEntry] {
        guard let stateId = backStackMap[destination] else { return [] }
        backStackMap = backStackMap.filter { $0.value != stateId }
        guard let stateId else { return [] }
        return backStackStates.removeValue(forKey: stateId) ?? []
    }

    private func isLive(_ entryId: Int64) -> Bool {
        backStack.contains { $0.id == entryId }
            || backStackStates.values.contains { $0.contains { $0.id == entryId } }
    }

    private func pruneRetainedStates() {
        var retiring: [Int64: [ObjectIdentifier: AnyObject]] = [:]
        for (entryId, states) in retainedStates where !isLive(entryId) {
            retiring[entryId] = states
            retainedStates[entryId] = nil
        }
        retiringStates = retiring
    }
}

/// `NavigationStack` 에 그릴 모양.
public struct BackStackProjection: Equatable, Sendable {
    /// 스택의 뿌리 화면. 빈 스택이면 nil(원본의 「화면 없는 빈 그래프」).
    public var root: NavBackStackEntry?
    /// 뿌리 위에 쌓인 화면들.
    public var path: [NavBackStackEntry]
    /// 아래 화면 위에 뜨는 대화상자 목적지(16).
    public var overlay: NavBackStackEntry?
}

/// 백스택 → (뿌리, 경로, 오버레이).
///
/// - 대화상자(16)는 쌓지 않는다. 원본처럼 아래 화면이 스크림 뒤에 보여야 하고, 쌓으면 아래 화면이 가려진다.
/// - 홈으로 pop 하면 홈 위에는 탭이 많아야 하나 남는다. 그래서 `backStack[1]` 이 탭이면 그 탭이 뿌리이고 그 위가 경로다.
///   탭을 바꾸면 경로가 아니라 뿌리가 바뀌어 밀려 들어오는 전환 없이 바로 바뀐다(원본 하단탭처럼).
/// - 이때 아래에 깔린 홈은 그려지지 않는다. 원본 NavHost 도 덮인 칸은 컴포지션에서 빼며, 돌아오면 상태는 `retained` 에서 나온다.
public func projectBackStack(_ backStack: [NavBackStackEntry]) -> BackStackProjection {
    var screens = backStack
    var overlay: NavBackStackEntry?
    if let last = screens.last, last.route.isDialog {
        overlay = last
        screens.removeLast()
    }
    guard let first = screens.first else {
        return BackStackProjection(root: nil, path: [], overlay: overlay)
    }
    if screens.count > 1, [Route.explore, .chat, .mypage].contains(screens[1].route) {
        return BackStackProjection(root: screens[1], path: Array(screens.dropFirst(2)), overlay: overlay)
    }
    return BackStackProjection(root: first, path: Array(screens.dropFirst()), overlay: overlay)
}
