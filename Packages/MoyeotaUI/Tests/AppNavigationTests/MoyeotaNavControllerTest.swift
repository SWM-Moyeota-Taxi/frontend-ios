import MoyeotaDesignSystem
import PresentationCore
import Testing
@testable import AppNavigation

// 원본에 없는 테스트. 원본은 실행 도구가 없어 스택 모양을 「실기로만 확인」했다(`NavBackStackRulesTest` 주석).
// 기대값의 근거는 `MainNavGraph.kt` 의 주석과 navigation-runtime 2.9.8 의 동작이다.

@MainActor
private func controller(_ routes: Route...) -> MoyeotaNavController {
    let nav = MoyeotaNavController(startDestination: routes[0])
    for route in routes.dropFirst() { nav.navigate(route) }
    return nav
}

@MainActor
private func stack(_ nav: MoyeotaNavController) -> [Route] {
    nav.backStack.map(\.route)
}

private final class Marker {}

@MainActor
@Suite struct MoyeotaNavControllerTest {

    // ─── 기본 의미 ───

    @Test("navigate 는 쌓고 칸마다 다른 id 를 준다 - 같은 라우트도 두 칸이다")
    func navigatePushes() {
        let nav = controller(.home, .rideOngoing, .chatRoom(roomId: 1), .rideOngoing)
        #expect(stack(nav) == [.home, .rideOngoing, .chatRoom(roomId: 1), .rideOngoing])
        #expect(Set(nav.backStack.map(\.id)).count == 4)
    }

    @Test("popBackStack 은 한 칸 빼고 마지막 칸을 빼면 빈 스택에 false 다")
    func popOne() {
        let nav = controller(.home, .destination)
        #expect(nav.popBackStack())
        #expect(stack(nav) == [.home])
        #expect(!nav.popBackStack())
        #expect(stack(nav).isEmpty)
        #expect(nav.currentRoute == nil)
        #expect(!nav.popBackStack())
    }

    @Test("popBackStack(route) 는 없으면 false, 맨 위가 그 칸이면 뺀 것이 없어 false 다")
    func popToRoute() {
        let nav = controller(.home, .destination, .joinConfirm)
        #expect(!nav.popBackStack(.rideOngoing, inclusive: false))
        #expect(stack(nav) == [.home, .destination, .joinConfirm])
        #expect(!nav.popBackStack(.joinConfirm, inclusive: false))
        #expect(stack(nav) == [.home, .destination, .joinConfirm])
        #expect(nav.popBackStack(.destination, inclusive: false))
        #expect(stack(nav) == [.home, .destination])
        #expect(nav.popBackStack(.destination, inclusive: true))
        #expect(stack(nav) == [.home])
    }

    @Test("popBackStack(route) 는 위에서부터 찾고 경로 인자는 보지 않는다")
    func popMatchesDestination() {
        let nav = controller(.home, .chatRoom(roomId: 1), .rideOngoing, .chatRoom(roomId: 2), .emergency)
        #expect(nav.popBackStack(.chatRoom(roomId: 999), inclusive: false))
        #expect(stack(nav) == [.home, .chatRoom(roomId: 1), .rideOngoing, .chatRoom(roomId: 2)])
    }

    @Test("previousBackStackEntry 는 바로 아래 칸이고 혼자면 nil 이다")
    func previousEntry() {
        let nav = controller(.loginForm)
        #expect(nav.previousBackStackEntry == nil)
        nav.navigate(.profileSetup)
        #expect(nav.previousBackStackEntry?.route == .loginForm)
    }

    @Test("launchSingleTop 은 맨 위가 같은 목적지면 칸을 그대로 둔다")
    func singleTopKeepsEntry() {
        let nav = controller(.home, .rideOngoing)
        let id = nav.currentBackStackEntry?.id
        nav.navigate(.rideOngoing) { $0.launchSingleTop = true }
        #expect(stack(nav) == [.home, .rideOngoing])
        #expect(nav.currentBackStackEntry?.id == id)
    }

    @Test("popUpTo 대상이 없으면 pop 만 무효이고 이동은 일어난다")
    func popUpToMissingStillNavigates() {
        let nav = controller(.loginForm)
        nav.navigate(.explore) { $0.popUpTo(.home) }
        #expect(stack(nav) == [.loginForm, .explore])
    }

    // ─── resetTo · resetAfterSignOut ───

    @Test("resetTo 는 스택을 비우고 한 칸만 남긴다 - 같은 라우트여도 새 칸이다")
    func resetToLeavesOne() {
        let nav = controller(.home, .destination, .matchWaiting)
        let oldHome = nav.backStack[0].id
        nav.resetTo(.home)
        #expect(stack(nav) == [.home])
        #expect(nav.backStack[0].id != oldHome)
    }

    @Test("resetTo 는 저장된 탭을 지우지 않는다 - 지우는 것은 resetAfterSignOut 뿐이다")
    func resetToKeepsSavedTabs() {
        let nav = controller(.home)
        nav.navigateTab(.explore)
        let explore = nav.backStack[1].id
        nav.navigateTab(.mypage)
        nav.resetTo(.home)
        nav.navigateTab(.explore)
        #expect(nav.backStack[1].id == explore)
    }

    @Test("resetAfterSignOut 은 지금 스택과 저장된 탭을 모두 버린다")
    func resetAfterSignOutClearsEverything() {
        let nav = controller(.home)
        nav.navigateTab(.explore)
        let explore = nav.backStack[1].id
        nav.navigateTab(.chat)
        let chat = nav.backStack[1].id
        nav.navigateTab(.mypage)

        nav.resetAfterSignOut(.loginForm)
        #expect(stack(nav) == [.loginForm])

        nav.resetTo(.home)
        nav.navigateTab(.explore)
        #expect(nav.backStack[1].id != explore, "이전 계정의 탐색 칸이 되살아났다")
        nav.navigateTab(.chat)
        #expect(nav.backStack[1].id != chat, "이전 계정의 채팅 칸이 되살아났다(QA 결함-1)")
    }

    @Test("resetAfterSignOut 뒤 04a 의 스택에는 이전 칸이 남지 않는다 - 첫 이동이 홈 위를 보관한 경우")
    func resetAfterSignOutWithHomeMappedToStack() {
        // 첫 `popUpTo(.home, saveState)` 가 실제로 칸을 뺐으면 HOME 자리에 그 스택 번호가 적힌다.
        let nav = controller(.home, .matchWaiting, .chatRoom(roomId: 1))
        nav.navigateTab(.mypage)
        nav.resetAfterSignOut(.loginForm)
        #expect(stack(nav) == [.loginForm])
    }

    // ─── navigateTab 의 모든 갈래 ───

    @Test("이미 그 탭이면 아무 일도 없다")
    func navigateTabSameTab() {
        let nav = controller(.home)
        let id = nav.backStack[0].id
        nav.navigateTab(.home)
        #expect(nav.backStack.map(\.id) == [id])
        nav.navigateTab(.chat)
        let chat = nav.backStack[1].id
        nav.navigateTab(.chat)
        #expect(nav.backStack[1].id == chat)
        #expect(stack(nav) == [.home, .chat])
    }

    @Test("탭은 쌓이지 않고 교체된다 - 홈 위에 언제나 하나")
    func tabsReplace() {
        let nav = controller(.home)
        nav.navigateTab(.explore)
        #expect(stack(nav) == [.home, .explore])
        nav.navigateTab(.chat)
        #expect(stack(nav) == [.home, .chat])
        nav.navigateTab(.mypage)
        #expect(stack(nav) == [.home, .mypage])
    }

    @Test("탭을 다녀오면 같은 칸이 돌아온다 - 합승→채팅→합승")
    func tabRestoresSameEntry() {
        let nav = controller(.home)
        nav.navigateTab(.explore)
        let explore = nav.backStack[1].id
        nav.navigateTab(.chat)
        nav.navigateTab(.explore)
        #expect(nav.backStack.map(\.route) == [.home, .explore])
        #expect(nav.backStack[1].id == explore)
    }

    @Test("홈을 거쳐 다녀와도 같은 칸이 돌아온다 - 합승→홈→합승의 비대칭을 고친 결정")
    func tabViaHomeRestores() {
        let nav = controller(.home)
        let home = nav.backStack[0].id
        nav.navigateTab(.explore)
        let explore = nav.backStack[1].id
        nav.navigateTab(.home)
        #expect(nav.backStack.map(\.id) == [home])
        nav.navigateTab(.explore)
        #expect(nav.backStack[1].id == explore)
    }

    @Test("진행 화면에서 홈으로 나오면 보관하지 않는다 - 떠난 방의 상태가 남으면 안 된다")
    func homeFromProgressDiscards() {
        let nav = controller(.home)
        nav.navigateTab(.explore)
        let explore = nav.backStack[1].id
        // 탐색 위에 21 을 쌓은 뒤 21 에서 홈으로 — 탐색 칸째 사라진다
        nav.navigate(.matchWaiting)
        nav.navigateTab(.home)
        #expect(stack(nav) == [.home])
        nav.navigateTab(.explore)
        #expect(nav.backStack[1].id != explore)
    }

    @Test("탭 위에 쌓은 스택은 다른 탭을 다녀오면 통째로 돌아온다 - 원본 saveState 는 칸 하나가 아니다")
    func savedStackRestoresWhole() {
        let nav = controller(.home)
        nav.navigateTab(.explore)
        let explore = nav.backStack[1].id
        nav.navigate(.matchWaiting)
        nav.navigate(.chatRoom(roomId: 5))
        // 채팅방의 하단탭으로 마이 → 다시 합승
        nav.navigateTab(.mypage)
        #expect(stack(nav) == [.home, .mypage])
        nav.navigateTab(.explore)
        #expect(stack(nav) == [.home, .explore, .matchWaiting, .chatRoom(roomId: 5)])
        #expect(nav.backStack[1].id == explore)
    }

    @Test("탭이 아닌 화면을 맨 아래로 보관한 스택은 탭으로 되살아나지 않는다")
    func nonTabStackNotRestoredByTabs() {
        let nav = controller(.home, .matchWaiting, .chatRoom(roomId: 5))
        nav.navigateTab(.explore)
        #expect(stack(nav) == [.home, .explore])
        nav.navigateTab(.chat)
        #expect(stack(nav) == [.home, .chat])
    }

    @Test("한 번 복원한 스택은 두 번 복원되지 않는다")
    func restoreOnlyOnce() {
        let nav = controller(.home)
        nav.navigateTab(.explore)
        let explore = nav.backStack[1].id
        nav.navigateTab(.chat)
        nav.navigateTab(.explore)
        #expect(nav.backStack[1].id == explore)
        nav.resetTo(.home)
        nav.navigateTab(.explore)
        #expect(nav.backStack[1].id != explore, "복원은 저장분을 소비한다")
    }

    @Test("23 에서 쌓은 채팅 탭을 떠나 홈으로 가면 맨 아래 탭 이름으로 보관되고 그 탭으로 돌아온다")
    func stackedChatTabLeavingToHome() {
        let nav = controller(.home)
        nav.navigateTab(.explore)
        nav.navigate(.joinConfirm)
        nav.navigate(.partnerProfile)
        nav.navigate(.chat)
        nav.navigateTab(.home)
        #expect(stack(nav) == [.home])
        // 맨 아래 칸(합승) 이름으로 보관됐으므로 채팅은 새 칸이다
        nav.navigateTab(.chat)
        #expect(stack(nav) == [.home, .chat])
        nav.navigateTab(.explore)
        #expect(stack(nav) == [.home, .explore, .joinConfirm, .partnerProfile, .chat])
    }

    @Test("홈이 스택에 없으면 스택부터 다시 세운다 - 홈 탭")
    func navigateTabWithoutHomeToHome() {
        let nav = controller(.rideOngoing, .chatRoom(roomId: 1))
        nav.navigateTab(.home)
        #expect(stack(nav) == [.home])
    }

    @Test("홈이 스택에 없으면 스택부터 다시 세운다 - 다른 탭은 홈 위에 선다")
    func navigateTabWithoutHomeToTab() {
        let nav = controller(.rideOngoing, .chatRoom(roomId: 1))
        nav.navigateTab(.chat)
        #expect(stack(nav) == [.home, .chat])
    }

    // ─── navigateToStage ───

    @Test("단계 표 - 대기·배차 둘·운행·끝")
    func stageTable() {
        #expect(MoyeotaNavController.stageRoute(.waiting) == .matchWaiting)
        #expect(MoyeotaNavController.stageRoute(.driverSearch) == .dispatchStatus)
        #expect(MoyeotaNavController.stageRoute(.driverComing) == .dispatchStatus)
        #expect(MoyeotaNavController.stageRoute(.ongoing) == .rideOngoing)
        #expect(MoyeotaNavController.stageRoute(ActiveStage.none) == nil)
    }

    @Test("단계 화면은 홈 위에 하나만 선다 - 나머지는 걷어낸다")
    func stageOnHome() {
        let nav = controller(.home)
        nav.navigateTab(.explore)
        nav.navigateToStage(route: .matchWaiting)
        #expect(stack(nav) == [.home, .matchWaiting])
    }

    @Test("이미 그 단계 화면이면 아무 일도 없다")
    func stageAlreadyThere() {
        let nav = controller(.home, .matchWaiting)
        let id = nav.currentBackStackEntry?.id
        nav.navigateToStage(route: .matchWaiting)
        #expect(nav.currentBackStackEntry?.id == id)
        #expect(stack(nav) == [.home, .matchWaiting])
    }

    @Test("단계 화면이 아래에 있으면 되돌아간다 - 두 겹이 되지 않는다")
    func stagePopsBack() {
        let nav = controller(.home, .destination, .matchWaiting, .chatRoom(roomId: 3))
        let waiting = nav.backStack[2].id
        nav.navigateToStage(route: .matchWaiting)
        #expect(stack(nav) == [.home, .destination, .matchWaiting])
        #expect(nav.currentBackStackEntry?.id == waiting)
    }

    // ─── 화면별 이동 ───

    @Test("25 → 26 은 홈을 바닥에 남긴다")
    func dispatchToOngoingKeepsHome() {
        let nav = controller(.home, .destination, .dispatchStatus)
        nav.navigate(.rideOngoing) {
            $0.popUpTo(.home)
            $0.launchSingleTop = true
        }
        #expect(stack(nav) == [.home, .rideOngoing])
        // 26 의 뒤로가기(`navigateTab(.home)`)가 빈 화면을 만들지 않는다
        nav.navigateTab(.home)
        #expect(stack(nav) == [.home])
    }

    @Test("채팅 열기는 쌓는다 - 뒤로가기가 원래 진행 화면이다")
    func openChatStacks() {
        let nav = controller(.home, .matchWaiting)
        nav.openActiveChatRoom(roomId: 9)
        #expect(stack(nav) == [.home, .matchWaiting, .chatRoom(roomId: 9)])
        nav.popBackStack()
        #expect(nav.currentRoute == .matchWaiting)
    }

    @Test("알림 채팅방은 쌓고 이미 그 방이 맨 위면 쌓지 않는다 - 다른 방은 쌓는다")
    func pendingChatRoom() {
        let nav = controller(.home, .matchWaiting)
        nav.openPendingChatRoom(roomId: 9)
        #expect(stack(nav) == [.home, .matchWaiting, .chatRoom(roomId: 9)])
        let top = nav.currentBackStackEntry?.id
        nav.openPendingChatRoom(roomId: 9)
        #expect(nav.currentBackStackEntry?.id == top)
        #expect(nav.backStack.count == 3)
        nav.openPendingChatRoom(roomId: 10)
        #expect(stack(nav) == [.home, .matchWaiting, .chatRoom(roomId: 9), .chatRoom(roomId: 10)])
    }

    @Test("16 에서 추천 방을 고르면 16 이 빠지고 20 이 15 위에 선다")
    func candidateReplacesDialog() {
        let nav = controller(.home, .destination, .destinationConfirm)
        nav.navigate(.joinConfirm) { $0.popUpTo(.destinationConfirm, inclusive: true) }
        #expect(stack(nav) == [.home, .destination, .joinConfirm])
    }

    @Test("16 에서 방을 만들면 16 이 빠지고 21 이 15 위에 선다")
    func createdReplacesDialog() {
        let nav = controller(.home, .destination, .destinationConfirm)
        nav.navigate(.matchWaiting) { $0.popUpTo(.destinationConfirm, inclusive: true) }
        #expect(stack(nav) == [.home, .destination, .matchWaiting])
    }

    @Test("20 합류는 20 을 21 로 바꾼다")
    func joinedReplaces() {
        let nav = controller(.home)
        nav.navigateTab(.explore)
        nav.navigate(.joinConfirm)
        nav.navigate(.matchWaiting) { $0.popUpTo(.joinConfirm, inclusive: true) }
        #expect(stack(nav) == [.home, .explore, .matchWaiting])
    }

    @Test("21 → 25 는 21 을 지운다 - 뒤로 왔을 때 튕기는 루프를 막는다")
    func waitingToDispatch() {
        let nav = controller(.home, .destination, .matchWaiting)
        nav.navigate(.dispatchStatus) { $0.popUpTo(.matchWaiting, inclusive: true) }
        #expect(stack(nav) == [.home, .destination, .dispatchStatus])
    }

    @Test("26 → 33 은 26 을 지운다")
    func ongoingToComplete() {
        let nav = controller(.home, .rideOngoing)
        nav.navigate(.rideComplete) { $0.popUpTo(.rideOngoing, inclusive: true) }
        #expect(stack(nav) == [.home, .rideComplete])
    }

    @Test("12 의 닉네임 중복·재인증은 10 으로 되돌아간다 - 같은 칸이라 입력이 남는다")
    func pledgeBackToProfile() {
        let nav = controller(.loginForm, .profileSetup, .mannerPledge)
        let profile = nav.backStack[1].id
        #expect(nav.popBackStack(.profileSetup, inclusive: false))
        #expect(nav.currentBackStackEntry?.id == profile)
    }

    @Test("13 의 탐색 시작은 홈을 바닥에 두고 탭을 세운다")
    func signupCompleteExplore() {
        let nav = controller(.loginForm, .profileSetup, .mannerPledge, .signupComplete)
        nav.resetTo(.home)
        nav.navigateTab(.explore)
        #expect(stack(nav) == [.home, .explore])
    }

    @Test("대화상자 위로 일반 목적지가 오면 대화상자가 먼저 빠진다 - 알림 채팅방")
    func nonDialogPopsDialog() {
        let nav = controller(.home, .destination, .destinationConfirm)
        nav.openPendingChatRoom(roomId: 2)
        #expect(stack(nav) == [.home, .destination, .chatRoom(roomId: 2)])
    }

    // ─── 칸별 상태 수명 ───

    @Test("칸별 상태는 탭을 떠나도 남고 돌아오면 같은 객체다")
    func retainedSurvivesTabSwitch() {
        let nav = controller(.home)
        nav.navigateTab(.explore)
        let entry = nav.backStack[1]
        let marker = nav.retained(for: entry) { Marker() }
        nav.navigateTab(.chat)
        nav.navigateTab(.home)
        nav.navigateTab(.explore)
        #expect(nav.backStack[1] == entry)
        #expect(nav.retained(for: entry) { Marker() } === marker)
    }

    @Test("칸별 상태는 21 처럼 보관되지 않고 빠지면 사라진다")
    func retainedDiesWithEntry() {
        let nav = controller(.home)
        nav.navigateTab(.explore)
        weak var weakMarker: Marker?
        do {
            let marker = nav.retained(for: nav.backStack[1]) { Marker() }
            weakMarker = marker
        }
        #expect(weakMarker != nil)
        nav.navigate(.matchWaiting)
        nav.navigateTab(.home)
        // 사라지는 화면의 전환 동안 한 번 더 들고 있다가 다음 이동에서 놓는다
        nav.navigate(.destination)
        #expect(weakMarker == nil)
    }

    @Test("칸별 상태는 로그아웃하면 저장된 탭 것까지 전부 놓는다")
    func retainedDiesOnSignOut() {
        let nav = controller(.home)
        weak var weakHome: Marker?
        weak var weakExplore: Marker?
        do {
            let home = nav.retained(for: nav.backStack[0]) { Marker() }
            weakHome = home
            nav.navigateTab(.explore)
            let explore = nav.retained(for: nav.backStack[1]) { Marker() }
            weakExplore = explore
            nav.navigateTab(.mypage)
        }
        #expect(weakHome != nil)
        #expect(weakExplore != nil, "다른 탭으로 옮겨도 저장된 탭의 상태는 남는다")
        nav.resetAfterSignOut(.loginForm)
        #expect(weakHome == nil)
        #expect(weakExplore == nil)
    }

    @Test("resetTo(.home) 로 선 새 홈은 새 상태다 - 33 「확인」")
    func newHomeNewState() {
        let nav = controller(.home)
        let old = nav.retained(for: nav.backStack[0]) { Marker() }
        nav.resetTo(.home)
        #expect(nav.retained(for: nav.backStack[0]) { Marker() } !== old)
    }

    // ─── 스와이프 반영 ───

    @Test("스와이프 pop 은 경로의 앞부분만 받는다")
    func applyPoppedPath() {
        let nav = controller(.home, .destination, .joinConfirm)
        let path = projectBackStack(nav.backStack).path
        nav.applyPoppedPath(Array(path.prefix(1)))
        #expect(stack(nav) == [.home, .destination])
    }

    @Test("탭 뿌리 위의 스와이프 pop 은 탭을 남긴다")
    func applyPoppedPathOnTabRoot() {
        let nav = controller(.home)
        nav.navigateTab(.explore)
        nav.navigate(.joinConfirm)
        nav.applyPoppedPath([])
        #expect(stack(nav) == [.home, .explore])
    }

    @Test("지금 경로의 앞부분이 아니면 무시한다 - 늦게 도착한 옛 경로가 이동을 되돌리면 안 된다")
    func applyPoppedPathIgnoresStale() {
        let nav = controller(.home, .destination)
        let stale = projectBackStack(nav.backStack).path
        nav.navigate(.joinConfirm)
        nav.navigateTab(.mypage)
        nav.applyPoppedPath(stale)
        #expect(stack(nav) == [.home, .mypage])
        let same = projectBackStack(nav.backStack).path
        nav.applyPoppedPath(same)
        #expect(stack(nav) == [.home, .mypage])
    }

    // ─── 05~09 ───

    @Test("05~09 는 라우트 상수만 있고 그래프 목적지가 아니다")
    func unwiredAuthRoutes() throws {
        let source = try #require(SourceTree.read("AppNavigation/MainNavGraph.swift"))
        for screen in ["AccountTypeScreen", "SchoolEmailScreen", "EmailCodeScreen", "WorkVerifyScreen", "IdentityVerifyScreen"] {
            #expect(!source.contains(screen), "\(screen) 이 그래프에 등록됐다")
        }
        #expect(Routes.ACCOUNT_TYPE == "auth/account-type")
        #expect(Routes.IDENTITY_VERIFY == "auth/identity")
    }

    @Test("라우트 문자열이 원본과 같다")
    func routeStrings() {
        #expect(Route.home.destination == "home")
        #expect(Route.chatRoom(roomId: 5).destination == "chat/room/{roomId}")
        #expect(Routes.chatRoom(roomId: 5) == "chat/room/5")
        #expect(Route.destinationConfirm.isDialog)
        #expect(!Route.destination.isDialog)
    }
}

/// `projectBackStack` — 원본에 없는 iOS 층.
@MainActor
@Suite struct BackStackProjectionTest {
    @Test("빈 스택은 뿌리가 없다")
    func empty() {
        let projection = projectBackStack([])
        #expect(projection.root == nil)
        #expect(projection.path.isEmpty)
        #expect(projection.overlay == nil)
    }

    @Test("탭이 없으면 맨 아래가 뿌리이고 나머지가 경로다")
    func plainStack() {
        let nav = controller(.home, .destination, .joinConfirm)
        let projection = projectBackStack(nav.backStack)
        #expect(projection.root?.route == .home)
        #expect(projection.path.map(\.route) == [.destination, .joinConfirm])
    }

    @Test("둘째 칸이 탭이면 탭이 뿌리다 - 탭마다")
    func tabRoots() {
        for (tab, route) in [(MoyeotaTab.explore, Route.explore), (.chat, .chat), (.mypage, .mypage)] {
            let nav = controller(.home)
            nav.navigateTab(tab)
            let projection = projectBackStack(nav.backStack)
            #expect(projection.root?.route == route)
            #expect(projection.path.isEmpty)
        }
    }

    @Test("탭을 바꾸면 경로가 아니라 뿌리가 바뀐다 - 밀려 들어오는 전환이 없다")
    func tabSwitchIsRootOnly() {
        let nav = controller(.home)
        #expect(projectBackStack(nav.backStack).path.isEmpty)
        nav.navigateTab(.explore)
        #expect(projectBackStack(nav.backStack).path.isEmpty)
        nav.navigateTab(.mypage)
        #expect(projectBackStack(nav.backStack).path.isEmpty)
        nav.navigateTab(.home)
        #expect(projectBackStack(nav.backStack).path.isEmpty)
    }

    @Test("탭 위에 쌓인 것은 경로다")
    func stackOnTab() {
        let nav = controller(.home)
        nav.navigateTab(.mypage)
        nav.navigate(.profileEdit)
        let projection = projectBackStack(nav.backStack)
        #expect(projection.root?.route == .mypage)
        #expect(projection.path.map(\.route) == [.profileEdit])
    }

    @Test("셋째 칸 이후의 채팅 탭은 쌓인 화면이다 - 23 의 채팅")
    func chatDeepIsPushed() {
        let nav = controller(.home, .matchWaiting, .rideDetail, .partnerProfile, .chat)
        let projection = projectBackStack(nav.backStack)
        #expect(projection.root?.route == .home)
        #expect(projection.path.last?.route == .chat)
    }

    @Test("16 은 쌓지 않고 오버레이다 - 15 는 경로에 그대로 남는다")
    func dialogIsOverlay() {
        let nav = controller(.home, .destination, .destinationConfirm)
        let projection = projectBackStack(nav.backStack)
        #expect(projection.overlay?.route == .destinationConfirm)
        #expect(projection.path.map(\.route) == [.destination])
    }

    @Test("16 이 20 으로 바뀌면 오버레이가 사라지고 경로에 20 이 선다")
    func dialogReplacedProjects() {
        let nav = controller(.home, .destination, .destinationConfirm)
        nav.navigate(.joinConfirm) { $0.popUpTo(.destinationConfirm, inclusive: true) }
        let projection = projectBackStack(nav.backStack)
        #expect(projection.overlay == nil)
        #expect(projection.path.map(\.route) == [.destination, .joinConfirm])
    }
}

@Suite struct BackGestureDecisionTest {
    @Test("쌓인 화면이 있으면 pop, 뿌리면 아무 일도 없다")
    func plain() {
        #expect(backGestureDecision(viewControllerCount: 2, isIntercepting: false, isTransitioning: false) == .pop)
        #expect(backGestureDecision(viewControllerCount: 1, isIntercepting: false, isTransitioning: false) == .ignore)
    }

    @Test("가로채기가 있으면 pop 대신 가로채기를 부른다 - 뿌리에서도")
    func intercept() {
        #expect(backGestureDecision(viewControllerCount: 2, isIntercepting: true, isTransitioning: false) == .intercept)
        #expect(backGestureDecision(viewControllerCount: 1, isIntercepting: true, isTransitioning: false) == .intercept)
    }

    @Test("전환 중에는 아무 일도 없다")
    func transitioning() {
        #expect(backGestureDecision(viewControllerCount: 2, isIntercepting: false, isTransitioning: true) == .ignore)
        #expect(backGestureDecision(viewControllerCount: 2, isIntercepting: true, isTransitioning: true) == .ignore)
    }
}
