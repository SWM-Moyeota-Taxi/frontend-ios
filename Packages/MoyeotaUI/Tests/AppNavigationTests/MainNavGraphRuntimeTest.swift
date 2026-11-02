import FeatureExplore
@testable import FeatureChat
import MoyeotaDesignSystem
import MoyeotaDomain
import PresentationCore
import SwiftUI
import Testing
import UIKit
@testable import AppNavigation

// 원본에 없는 테스트. 실제 `MainNavGraph` 를 가짜 저장소로 창에 올려 `NavigationStack` 과 함께 돌린다.
// 손가락 제스처는 흉내 낼 수 없어, 시스템이 시작 때 부르는 대리자와 UIKit pop 으로 대신한다.

@MainActor
@Suite(.serialized) final class MainNavGraphRuntimeTest {
    /// `restoredStack` 이 복원 직전에 잰 17 목록 요청 수.
    private var withinBeforeRestore = 0

    // ─── 진입 ───

    @Test("세션이 확정되기 전에는 스택을 세우지 않고 미로그인이면 온보딩에서 시작한다")
    func splashThenOnboarding() async throws {
        let graph = HostedGraph(auth: .unknown)
        await graph.settle()
        #expect(graph.navigationController == nil)
        #expect(graph.probe.navController == nil)

        graph.auth.flow.value = .unauthenticated
        await graph.waitForViewControllers(1)
        #expect(graph.routes == [.onboardingSaving])
        await graph.close()
    }

    @Test("이미 로그인돼 있으면 홈에서 시작한다")
    func loggedInStartsHome() async throws {
        let graph = HostedGraph()
        await graph.waitForViewControllers(1)
        #expect(graph.routes == [.home])
        await graph.close()
    }

    @Test("강제 업데이트 게이트 - 서버가 막으면 스택이 헐리고 풀리면 다시 선다")
    func updateGate() async throws {
        let graph = HostedGraph(config: AppConfig(taxiEnabled: false, minVersionCode: 200), installedVersionCode: 100)
        await graph.waitUntil("스택이 헐린다") { graph.navigationController == nil && graph.probe.navController != nil }
        await graph.close()

        let passing = HostedGraph(config: AppConfig(taxiEnabled: false, minVersionCode: 50), installedVersionCode: 100)
        await passing.waitForViewControllers(1)
        await passing.settle()
        #expect(passing.navigationController != nil)
        await passing.close()
    }

    // ─── 시작 복귀 ───

    @Test("진행 중 방이 있으면 앱 시작에 단계 화면으로 돌아오고 그 방 id 로 조회한다")
    func startupStageReturn() async throws {
        let graph = HostedGraph(activeRide: fakeRide())
        await graph.waitUntil("21 로 복귀") { graph.routes == [.home, .matchWaiting] }
        await graph.waitForViewControllers(2)
        await graph.waitUntil("21 이 방을 읽는다") { graph.rides.detailRequests.contains(7) }
        await graph.close()
    }

    @Test("복귀는 한 번뿐이다 - 21 에서 홈으로 나온 뒤 재조회가 돌아도 끌려 올라가지 않는다")
    func startupStageOnce() async throws {
        let graph = HostedGraph(activeRide: fakeRide())
        await graph.waitUntil("21 로 복귀") { graph.routes == [.home, .matchWaiting] }
        await graph.waitForViewControllers(2)
        try graph.nav.navigateTab(.home)
        await graph.waitForViewControllers(1)
        await graph.settle(30)
        #expect(graph.routes == [.home])
        await graph.close()
    }

    @Test("이미 홈을 떠났으면 복귀가 끼어들지 않는다 - 방을 만들고 21 에서 홈으로 돌아와도 되끌려 가지 않는다")
    func startupStageWindowCloses() async throws {
        let graph = HostedGraph()
        await graph.waitForViewControllers(1)
        await graph.settle()
        let nav = try graph.nav
        nav.navigate(.destination)
        await graph.waitForViewControllers(2)
        // 16 의 방 생성 자리 — 홈이 아닌 곳에서 진행 중 방이 생긴다
        graph.active.ride = fakeRide()
        graph.rides.ride = fakeRide()
        try #require(graph.probe.activePartyViewModel).rememberParty(partyId: "7")
        await graph.waitUntil("홀더가 방을 안다") { graph.probe.activePartyViewModel?.ride != nil }
        await graph.settle()
        #expect(graph.routes == [.home, .destination], "홈이 아닌 화면을 빼앗지 않는다")

        nav.navigateTab(.home)
        await graph.waitForViewControllers(1)
        await graph.settle(30)
        #expect(graph.routes == [.home], "홈을 떠난 뒤로 빗장이 서 있어 끌어올리지 않는다")
        await graph.close()
    }

    // ─── 알림 채팅방 ───

    @Test("알림 채팅방은 현재 화면 위에 쌓이고 소비를 알린다")
    func pendingChatRoomOpens() async throws {
        let graph = HostedGraph()
        await graph.waitForViewControllers(1)
        graph.pending.roomId = 42
        await graph.waitUntil("채팅방이 쌓인다") { graph.routes == [.home, .chatRoom(roomId: 42)] }
        await graph.waitUntil("소비 알림") { graph.pending.handled == 1 && graph.pending.roomId == nil }
        await graph.waitForViewControllers(2)
        await graph.close()
    }

    @Test("미로그인이면 알림 채팅방은 소비만 하고 지나간다")
    func pendingChatRoomLoggedOut() async throws {
        let graph = HostedGraph(auth: .unauthenticated)
        await graph.waitForViewControllers(1)
        graph.pending.roomId = 42
        await graph.waitUntil("소비 알림") { graph.pending.handled == 1 }
        #expect(graph.routes == [.onboardingSaving])
        await graph.close()
    }

    // ─── 뒤로가기 ───

    @Test("스와이프 pop 이 스택에 반영된다 - 시스템이 경로를 줄이면 컨트롤러가 따라온다")
    func swipePopWritesBack() async throws {
        let graph = HostedGraph()
        await graph.waitForViewControllers(1)
        try graph.nav.navigate(.destination)
        await graph.waitForViewControllers(2)

        #expect(try graph.edgeSwipeShouldBegin(), "내비게이션 바를 숨겨도 스와이프가 살아 있어야 한다")
        _ = graph.navigationController?.popViewController(animated: false)
        await graph.waitUntil("스택이 따라온다") { graph.routes == [.home] }
        await graph.close()
    }

    @Test("탭 뿌리에서는 스와이프가 시작되지 않는다")
    func swipeAtTabRootIgnored() async throws {
        let graph = HostedGraph()
        await graph.waitForViewControllers(1)
        try graph.nav.navigateTab(.mypage)
        await graph.waitForViewControllers(1)
        await graph.settle()
        #expect(try !graph.edgeSwipeShouldBegin())
        #expect(graph.routes == [.home, .mypage])
        await graph.close()
    }

    @Test("하단탭을 바꿔도 화면이 쌓이지 않는다 - 전환이 뿌리 교체다")
    func tabSwitchDoesNotPush() async throws {
        let graph = HostedGraph()
        await graph.waitForViewControllers(1)
        for tab in [MoyeotaTab.explore, .chat, .mypage, .home] {
            try graph.nav.navigateTab(tab)
            await graph.settle(4)
            #expect(graph.navigationController?.viewControllers.count == 1)
        }
        await graph.close()
    }

    @Test("21·25·26 의 스와이프는 pop 대신 홈으로 간다", arguments: [
        (RideStatus.recruiting, Route.matchWaiting),
        (RideStatus.dispatching, Route.dispatchStatus),
        (RideStatus.ongoing, Route.rideOngoing),
    ])
    func progressScreensInterceptSwipe(status: RideStatus, route: Route) async throws {
        let graph = HostedGraph(activeRide: fakeRide(status: status))
        await graph.waitUntil("단계 화면") { graph.routes == [.home, route] }
        await graph.waitForViewControllers(2)
        await graph.waitUntil("가로채기 등록") { BackInterceptionCenter.shared.isIntercepting }

        #expect(try !graph.edgeSwipeShouldBegin(), "가로채는 동안 시스템 pop 이 시작되면 안 된다")
        await graph.waitForViewControllers(1)
        #expect(graph.routes == [.home])
        await graph.waitUntil("가로채기 해제") { !BackInterceptionCenter.shared.isIntercepting }
        await graph.close()
    }

    @Test("21 위에 채팅방이 쌓이면 21 의 가로채기가 풀린다 - 덮인 화면이 뒤로가기를 받으면 안 된다")
    func coveredHandlerIsStale() async throws {
        let graph = HostedGraph(activeRide: fakeRide())
        await graph.waitUntil("21") { graph.routes == [.home, .matchWaiting] }
        await graph.waitForViewControllers(2)
        await graph.waitUntil("21 가로채기") { BackInterceptionCenter.shared.isIntercepting }

        try graph.nav.openActiveChatRoom(roomId: 3)
        await graph.waitForViewControllers(3)
        await graph.waitUntil("21 가로채기 해제") { !BackInterceptionCenter.shared.isIntercepting }
        #expect(try graph.edgeSwipeShouldBegin(), "채팅방은 스와이프로 21 에 돌아와야 한다")

        _ = graph.navigationController?.popViewController(animated: false)
        await graph.waitUntil("21 로 복귀") { graph.routes == [.home, .matchWaiting] }
        await graph.waitUntil("21 가로채기 재등록") { BackInterceptionCenter.shared.isIntercepting }
        await graph.close()
    }

    @Test("가장자리 제스처가 판정을 낼 때까지 다른 제스처는 기다린다 - 지도 팬이 먼저 인식되면 지도 위 스와이프가 뒤로 가지 못한다")
    func edgeGesturesWinOverMapPan() async throws {
        let graph = HostedGraph()
        await graph.waitForViewControllers(1)
        await graph.settle()
        let pop = try #require(graph.navigationController?.interactivePopGestureRecognizer)
        let consumer = try #require(graph.edgeConsumer)
        let delegate = try #require(pop.delegate)
        let mapPan = UIPanGestureRecognizer()
        #expect(delegate.gestureRecognizer?(pop, shouldBeRequiredToFailBy: mapPan) == true)
        #expect(delegate.gestureRecognizer?(consumer, shouldBeRequiredToFailBy: mapPan) == true)
        #expect(delegate.gestureRecognizer?(pop, shouldBeRequiredToFailBy: consumer) == false, "서로 기다리면 둘 다 멈춘다")
        #expect(delegate.gestureRecognizer?(consumer, shouldBeRequiredToFailBy: pop) == false)
        await graph.close()
    }

    @Test("23 을 쌓아도 덮인 21 의 가로채기가 되살아나지 않는다 - SwiftUI 가 두 칸 아래 화면에 onAppear 를 다시 부른다")
    func strayAppearDoesNotReviveCoveredHandler() async throws {
        let graph = HostedGraph(activeRide: fakeRide())
        await graph.waitUntil("21") { graph.routes == [.home, .matchWaiting] }
        await graph.waitForViewControllers(2)
        await graph.waitUntil("21 가로채기") { BackInterceptionCenter.shared.isIntercepting }

        try graph.nav.navigate(.rideDetail)
        await graph.waitForViewControllers(3)
        try graph.nav.navigate(.partnerProfile)
        await graph.waitForViewControllers(4)
        await graph.settle()
        #expect(!BackInterceptionCenter.shared.isIntercepting)
        #expect(try graph.edgeSwipeShouldBegin(), "23 은 22 로 pop 돼야 한다")

        _ = graph.navigationController?.popViewController(animated: false)
        await graph.waitForViewControllers(3)
        _ = graph.navigationController?.popViewController(animated: false)
        await graph.waitForViewControllers(2)
        await graph.waitUntil("21 로 돌아오면 다시 가로챈다") { BackInterceptionCenter.shared.isIntercepting }
        await graph.close()
    }

    @Test("iOS 26 의 화면 전체 pop 제스처는 꺼 두고 가장자리 제스처의 대리자는 브리지다")
    func contentPopGestureDisabled() async throws {
        let graph = HostedGraph()
        await graph.waitForViewControllers(1)
        await graph.settle()
        let navigationController = try #require(graph.navigationController)
        #expect(navigationController.interactivePopGestureRecognizer?.delegate is BackGestureBridgeController)
        #expect(navigationController.interactivePopGestureRecognizer?.isEnabled == true)
        #expect(graph.edgeConsumer?.delegate is BackGestureBridgeController, "16 은 스택 밖이라 제스처가 창에 있어야 스와이프가 닿는다")
        #expect(graph.edgeConsumer?.cancelsTouchesInView == true, "터치를 취소해야 손가락 아래 행이 눌리지 않는다")
        if #available(iOS 26.0, *) {
            let contentPop = try #require(navigationController.interactiveContentPopGestureRecognizer)
            #expect(contentPop.isEnabled == false)
        }
        try graph.nav.navigate(.destination)
        await graph.waitForViewControllers(2)
        if #available(iOS 26.0, *) {
            #expect(navigationController.interactiveContentPopGestureRecognizer?.isEnabled == false, "쌓은 뒤에도 꺼져 있어야 한다")
        }
        await graph.close()
    }

    // ─── 복원된 스택 ───

    /// 17 → 15 → 21 → 24 에서 35 를 다녀와 스택을 한 번에 되살린다.
    /// 진행 중 방이 있으면 시작 복귀(21)에서 방 id 를 받은 뒤 탭으로 나가 같은 스택을 쌓는다. 그래야 21 이 그 방을 읽는다.
    private func restoredStack(_ graph: HostedGraph, afterTabReturn: () -> Int = { 0 }) async throws {
        if graph.active.ride != nil {
            await graph.waitUntil("시작 복귀") { graph.routes == [.home, .matchWaiting] }
            await graph.waitForViewControllers(2)
        } else {
            await graph.waitForViewControllers(1)
        }
        await graph.settle()
        let nav = try graph.nav
        nav.navigateTab(.explore)
        await graph.waitForViewControllers(1)
        await graph.settle(8)
        nav.navigate(.destination)
        await graph.waitForViewControllers(2)
        nav.navigate(.matchWaiting)
        await graph.waitForViewControllers(3)
        nav.openActiveChatRoom(roomId: 3)
        await graph.waitForViewControllers(4)
        await graph.waitUntil("덮이면 21 가로채기가 풀린다") { !BackInterceptionCenter.shared.isIntercepting }
        nav.navigateTab(.mypage)
        await graph.waitForViewControllers(1)
        await graph.settle(8)
        withinBeforeRestore = afterTabReturn()
        nav.navigateTab(.explore)
        await graph.waitForViewControllers(4)
        await graph.settle(20)
        #expect(graph.routes == [.home, .explore, .destination, .matchWaiting, .chatRoom(roomId: 3)])
    }

    @Test("복원된 24 의 스와이프는 덮인 21 의 가로채기에 걸리지 않고 21 로 돌아간다")
    func restoredStackSwipePopsToCovered() async throws {
        let graph = HostedGraph(activeRide: fakeRide())
        try await restoredStack(graph)

        #expect(!BackInterceptionCenter.shared.isIntercepting, "덮인 화면의 가로채기가 살아 있다")
        #expect(try graph.edgeSwipeShouldBegin(), "24 는 스와이프로 시스템 pop 이 시작돼야 한다")
        #expect(graph.routes == [.home, .explore, .destination, .matchWaiting, .chatRoom(roomId: 3)], "스택이 무너졌다")

        // 돌아오면 21 이 그때 시작한다 — 가로채기도 그때 걸린다
        _ = graph.navigationController?.popViewController(animated: false)
        await graph.waitUntil("21 로 복귀") { graph.routes == [.home, .explore, .destination, .matchWaiting] }
        await graph.waitUntil("21 가로채기 재등록") { BackInterceptionCenter.shared.isIntercepting }
        await graph.close()
    }

    @Test("복원된 스택에서 덮인 21 은 돌지 않는다 - 조회도 전이도 없고 돌아왔을 때 읽는다")
    func restoredCoveredScreenIsIdle() async throws {
        let graph = HostedGraph(activeRide: fakeRide())
        try await restoredStack(graph)
        await graph.settle(8)
        let before = graph.rides.detailRequests.count

        // 덮여 있는 동안 서버가 배차로 넘어갔다 — 원본은 21 이 멈춰 있어 사용자가 돌아와야 움직인다
        graph.rides.ride = fakeRide(status: .dispatching)
        // 폴백 주기(6초)보다 길게 기다린다
        try? await Task.sleep(for: .seconds(7))
        await graph.settle(4)
        #expect(graph.rides.detailRequests.count == before, "덮인 21 이 폴링한다")
        #expect(graph.routes == [.home, .explore, .destination, .matchWaiting, .chatRoom(roomId: 3)], "덮인 21 이 채팅방을 걷어냈다")

        try graph.nav.popBackStack()
        await graph.waitUntil("돌아오면 21 이 읽고 25 로 간다") {
            graph.routes == [.home, .explore, .destination, .dispatchStatus]
        }
        await graph.close()
    }

    @Test("복원된 스택을 뿌리까지 내려오면 17 이 그때 시작한다 - 덮여 있는 동안은 목록을 읽지 않는다")
    func restoredRootStartsOnReturn() async throws {
        let graph = HostedGraph()
        try await restoredStack(graph) { graph.rides.withinRequests }
        await graph.settle(8)
        let before = graph.rides.withinRequests
        #expect(before == withinBeforeRestore, "덮인 17 이 목록을 읽었다")
        try graph.nav.popBackStack(.explore, inclusive: false)
        await graph.waitForViewControllers(1)
        await graph.waitUntil("17 이 다시 읽는다") { graph.rides.withinRequests > before }
        await graph.settle(8)
        // 주기 조회(4초)가 끼기 전이다 — 복귀 1회와 첫 범위 1회까지만 허용한다
        #expect(graph.rides.withinRequests - before <= 2)
        await graph.close()
    }

    // ─── 쌓인 화면이 빠지면서 탭 뿌리가 바뀔 때 ───

    @Test("단독 24 에서 탭 17 로 가면 17 이 한 번만 시작한다 - 목록 요청이 겹치지 않는다")
    func tabFromStackedStartsOnce() async throws {
        let graph = HostedGraph()
        await graph.waitForViewControllers(1)
        await graph.settle()
        let nav = try graph.nav
        nav.openActiveChatRoom(roomId: 3)
        await graph.waitForViewControllers(2)
        await graph.settle(8)
        let before = graph.rides.withinRequests

        nav.navigateTab(.explore)
        await graph.waitForViewControllers(1)
        await graph.settle(20)
        #expect(graph.rides.withinRequests - before == 1, "17 목록 요청 \(graph.rides.withinRequests - before) 번")
        await graph.close()
    }

    @Test("단독 24 에서 방이 열린 채팅 탭으로 가면 소켓이 한 번만 붙는다")
    func tabFromStackedChatConnectsOnce() async throws {
        let graph = HostedGraph()
        await graph.waitForViewControllers(1)
        await graph.settle()
        let nav = try graph.nav
        nav.navigateTab(.chat)
        await graph.settle(8)
        let tab = nav.retained(for: nav.backStack[1]) { ChatTabState(repository: graph.chat) }
        tab.openedRoom = ChatRoom(id: 5, partyId: 0, departure: "부산대", destination: "서면", createdAt: "", status: .active)
        await graph.waitUntil("방 5 구독") { graph.chat.observedRooms.contains(5) }
        nav.navigateTab(.home)
        await graph.settle(8)
        nav.openActiveChatRoom(roomId: 3)
        await graph.waitForViewControllers(2)
        await graph.settle(8)
        let observedBefore = graph.chat.observedRooms.filter { $0 == 5 }.count
        let fetchedBefore = graph.chat.messageRequests.filter { $0 == 5 }.count

        nav.navigateTab(.chat)
        await graph.waitForViewControllers(1)
        await graph.settle(20)
        #expect(graph.chat.observedRooms.filter { $0 == 5 }.count - observedBefore == 1, "방 5 구독 횟수")
        #expect(graph.chat.messageRequests.filter { $0 == 5 }.count - fetchedBefore == 1, "방 5 메시지 조회 횟수")
        await graph.close()
    }

    // ─── 16 오버레이 ───

    @Test("15 검색칸에 키보드가 뜬 채 16 이 열리면 키보드가 내려간다 - 16 에는 입력 칸이 없다")
    func dialogDismissesKeyboard() async throws {
        let graph = HostedGraph()
        graph.window.makeKeyAndVisible()
        await graph.waitForViewControllers(1)
        await graph.settle(8)
        let nav = try graph.nav
        nav.navigate(.destination)
        await graph.waitForViewControllers(2)
        await graph.settle(16)
        let field = try #require(graph.allViews(of: UITextField.self, in: graph.topView).first)
        try #require(field.becomeFirstResponder(), "시험하려면 칸이 포커스를 받아야 한다")
        await graph.settle(8)

        nav.navigate(.destinationConfirm)
        await graph.waitUntil("16 이 포커스를 거둔다") { !field.isFirstResponder }
        #expect(graph.routes == [.home, .destination, .destinationConfirm])
        await graph.close()
    }

    @Test("16 은 15 위에 얹히고 스와이프는 16 만 닫는다")
    func dialogOverlay() async throws {
        let graph = HostedGraph()
        await graph.waitForViewControllers(1)
        try graph.nav.navigate(.destination)
        await graph.waitForViewControllers(2)
        try graph.nav.navigate(.destinationConfirm)
        await graph.settle()
        #expect(graph.navigationController?.viewControllers.count == 2, "16 은 쌓이지 않는다")
        await graph.waitUntil("16 의 가로채기") { BackInterceptionCenter.shared.isIntercepting }

        #expect(try !graph.edgeSwipeShouldBegin())
        await graph.waitUntil("16 만 닫힌다") { graph.routes == [.home, .destination] }
        #expect(graph.navigationController?.viewControllers.count == 2)
        await graph.waitUntil("가로채기 해제") { !BackInterceptionCenter.shared.isIntercepting }
        await graph.close()
    }

    @Test("16 에서 추천을 고르면 오버레이가 닫히고 20 이 쌓인다")
    func dialogReplacedByJoinConfirm() async throws {
        let graph = HostedGraph()
        await graph.waitForViewControllers(1)
        try graph.nav.navigate(.destination)
        await graph.waitForViewControllers(2)
        try graph.nav.navigate(.destinationConfirm)
        await graph.waitUntil("16 의 가로채기") { BackInterceptionCenter.shared.isIntercepting }

        try graph.nav.navigate(.joinConfirm) { $0.popUpTo(.destinationConfirm, inclusive: true) }
        await graph.waitForViewControllers(3)
        await graph.waitUntil("가로채기 해제") { !BackInterceptionCenter.shared.isIntercepting }
        #expect(graph.routes == [.home, .destination, .joinConfirm])
        await graph.close()
    }

    @Test("16 의 상태바 여백은 원본 대화상자처럼 0 이다")
    func dialogSpacerCollapses() async throws {
        let graph = HostedGraph()
        await graph.waitForViewControllers(1)
        try graph.nav.navigate(.destination)
        await graph.waitForViewControllers(2)
        try graph.nav.navigate(.destinationConfirm)
        await graph.settle(20)
        // 오버레이는 스택 바깥이다 — 스택 뷰를 뺀 자리에서 찾는다
        let stackView = try #require(graph.navigationController?.view)
        let overlaySpacers = graph.insetSpacerFrames(in: graph.host.view)
            .filter { !stackView.frame.isEmpty && $0.minY >= InsetWindow.insets.top - 0.5 && $0.maxY <= 874 - InsetWindow.insets.bottom + 0.5 }
        #expect(overlaySpacers.contains { $0.height < 0.5 && abs($0.minY - InsetWindow.insets.top) < 0.5 })
        await graph.close()
    }

    // ─── 가장자리까지 ───

    @Test("여백은 뿌리에서도 쌓인 화면에서도 접히거나 겹치지 않는다", arguments: [
        [Route.onboardingSaving, .login, .loginForm],
        [Route.onboardingSaving],
    ])
    func spacersInPushedDestinations(routes: [Route]) async throws {
        let graph = HostedGraph(auth: .unauthenticated)
        await graph.waitForViewControllers(1)
        for route in routes.dropFirst() {
            try graph.nav.navigate(route)
        }
        await graph.waitForViewControllers(routes.count)
        await graph.settle(16)

        let spacers = graph.insetSpacerFrames(in: graph.topView)
        let top = spacers.filter { $0.minY < 1 }
        #expect(!top.isEmpty, "맨 위 화면에 상태바 여백이 없다 — 화면이 안전 영역 안으로 밀렸다")
        for frame in top {
            #expect(abs(frame.height - InsetWindow.insets.top) < 0.5, "상태바 여백 \(frame)")
        }
        // 내용이 안전 영역 아래로 한 번 더 밀렸다면 첫 여백이 창 맨 위에 있지 않다
        #expect(spacers.allSatisfy { $0.minY >= 0 })
        let bottom = spacers.filter { $0.maxY > 874 - 1 }
        #expect(!bottom.isEmpty, "맨 위 화면에 내비게이션바 여백이 없다")
        for frame in bottom {
            #expect(abs(frame.height - InsetWindow.insets.bottom) < 0.5, "내비게이션바 여백 \(frame)")
        }
        await graph.close()
    }

    @Test("로그인 뒤의 탭 뿌리·쌓인 화면도 상태바 여백이 온전하다")
    func spacersLoggedIn() async throws {
        let graph = HostedGraph()
        await graph.waitForViewControllers(1)
        let nav = try graph.nav
        nav.navigateTab(.mypage)
        await graph.settle(16)
        var top = graph.insetSpacerFrames(in: graph.topView).filter { $0.minY < 1 }
        #expect(top.contains { abs($0.height - InsetWindow.insets.top) < 0.5 }, "35 상태바 여백 \(top)")

        nav.navigate(.rideHistory)
        await graph.waitForViewControllers(2)
        await graph.settle(16)
        top = graph.insetSpacerFrames(in: graph.topView).filter { $0.minY < 1 }
        #expect(top.contains { abs($0.height - InsetWindow.insets.top) < 0.5 }, "34 상태바 여백 \(top)")
        await graph.close()
    }

    // ─── 탭 상태 ───

    @Test("35 스크롤 위치는 탭을 다녀와도 남고 로그아웃하면 사라진다")
    func myPageScrollRetained() async throws {
        let graph = HostedGraph(height: 480)
        await graph.waitForViewControllers(1)
        try graph.nav.navigateTab(.mypage)
        await graph.waitUntil("35 스크롤 뷰") { !graph.scrollViews.isEmpty }
        await graph.settle()
        let scroll = try #require(graph.scrollViews.first)
        try #require(scroll.contentSize.height > scroll.bounds.height + 60, "시험에 쓸 만큼 내용이 길어야 한다")
        scroll.contentOffset.y = 60
        await graph.settle(4)

        try graph.nav.navigateTab(.home)
        await graph.settle(8)
        try graph.nav.navigateTab(.mypage)
        await graph.waitUntil("35 스크롤 복원") { graph.scrollViews.first?.contentOffset.y == 60 }
        await graph.close()
    }

    @Test("17 시트 단계는 칸의 저장 상태에서 돌아온다", arguments: [
        (ExploreSheetState.half, true),
        (ExploreSheetState.peek, false),
    ])
    func exploreSheetRestored(state: ExploreSheetState, listShown: Bool) async throws {
        let graph = HostedGraph()
        graph.rides.parties = [fakeRide(id: "1")]
        await graph.waitForViewControllers(1)
        let nav = try graph.nav
        nav.navigateTab(.explore)
        nav.retained(for: nav.backStack[1]) { TabSavedState() }.set("explore.sheetState", state)
        await graph.settle(30)
        // 목록은 half·full 에서만 있다 — 지도 안의 스크롤 뷰와 섞이지 않게 내용이 있는 세로 스크롤만 센다
        let lists = graph.scrollViews.filter { $0.contentSize.height > 0 && $0.bounds.height > 0 }
        #expect(!lists.isEmpty == listShown, "목록 스크롤 \(lists.count) 개, 기대 \(listShown)")
        await graph.close()
    }

    @Test("14 시트 접힘은 칸의 저장 상태에서 돌아온다")
    func homeSheetRestored() async throws {
        let graph = HostedGraph()
        await graph.waitForViewControllers(1)
        await graph.settle(8)
        let openHeight = graph.scrollViews.map(\.bounds.height).max() ?? 0
        try #require(openHeight > 1, "펼친 시트의 상세가 보여야 시험이 된다")

        let nav = try graph.nav
        nav.navigateTab(.mypage)
        await graph.settle(4)
        nav.retained(for: nav.backStack[0]) { TabSavedState() }.set("mapSheet.expanded", false)
        nav.navigateTab(.home)
        await graph.settle(16)
        #expect((graph.scrollViews.map(\.bounds.height).max() ?? 0) < 1, "접어 둔 시트가 펼쳐져 돌아왔다")
        await graph.close()
    }

    @Test("탭 뷰모델은 탭을 다녀와도 같고 로그아웃 뒤 새 계정은 새 객체를 받는다")
    func tabStateDiscardedOnSignOut() async throws {
        let graph = HostedGraph()
        await graph.waitForViewControllers(1)
        let nav = try graph.nav
        final class Marker {}
        let homeEntry = nav.backStack[0]
        let marker = nav.retained(for: homeEntry) { Marker() }
        nav.navigateTab(.explore)
        await graph.settle(6)
        nav.navigateTab(.home)
        await graph.settle(6)
        #expect(nav.retained(for: nav.backStack[0]) { Marker() } === marker)

        graph.auth.flow.value = .unauthenticated
        await graph.waitUntil("04a") { graph.routes == [.loginForm] }
        graph.auth.flow.value = .authenticated(userUuid: "v")
        nav.resetTo(.home)
        await graph.waitForViewControllers(1)
        #expect(nav.retained(for: nav.backStack[0]) { Marker() } !== marker)
        await graph.close()
    }

    // ─── 로그인 전이와 네 안내 ───

    @Test("세션 만료는 만료 안내와 함께 04a 로 간다")
    func sessionExpiredNotice() async throws {
        let graph = HostedGraph()
        await graph.waitForViewControllers(1)
        graph.auth.flow.value = .unauthenticated
        await graph.waitUntil("04a") { graph.routes == [.loginForm] }
        #expect(graph.probe.signOutNotices == ["세션이 만료됐어요. 다시 로그인해 주세요"])
        await graph.close()
    }

    @Test("사용자의 로그아웃에는 안내가 없다")
    func logoutNoNotice() async throws {
        let graph = HostedGraph()
        await graph.waitForViewControllers(1)
        graph.probe.markLogoutRequested()
        await graph.settle(2)
        graph.auth.flow.value = .unauthenticated
        await graph.waitUntil("04a") { graph.routes == [.loginForm] }
        #expect(graph.probe.signOutNotices == [nil])
        await graph.close()
    }

    @Test("탈퇴 204 가 세션 소멸보다 늦게 와도 탈퇴 안내가 뜬다 - 200ms 안이면 기다린다")
    func deletedArrivesLate() async throws {
        let graph = HostedGraph()
        await graph.waitForViewControllers(1)
        graph.probe.markDeleteRequested()
        await graph.settle(2)
        graph.auth.flow.value = .unauthenticated
        try? await Task.sleep(for: .milliseconds(40))
        graph.probe.markDeleted()
        await graph.waitUntil("04a") { graph.routes == [.loginForm] }
        #expect(graph.probe.signOutNotices == ["탈퇴가 처리됐어요. 그동안 이용해 주셔서 고마웠어요"])
        await graph.close()
    }

    @Test("탈퇴 결과를 끝내 못 보면 아무 말도 하지 않는다")
    func deleteResultUnknown() async throws {
        let graph = HostedGraph()
        await graph.waitForViewControllers(1)
        graph.probe.markDeleteRequested()
        await graph.settle(2)
        let started = ContinuousClock.now
        graph.auth.flow.value = .unauthenticated
        await graph.waitUntil("04a") { graph.routes == [.loginForm] }
        #expect(ContinuousClock.now - started >= .milliseconds(150), "결과를 기다리지 않았다")
        #expect(graph.probe.signOutNotices == [nil])
        await graph.close()
    }

    @Test("탈퇴가 실패로 되돌려지면 뒤의 세션 만료는 만료 안내다")
    func deleteKeptThenExpired() async throws {
        let graph = HostedGraph()
        await graph.waitForViewControllers(1)
        graph.probe.markDeleteRequested()
        await graph.settle(2)
        graph.probe.markDeleteKept()
        await graph.settle(2)
        graph.auth.flow.value = .unauthenticated
        await graph.waitUntil("04a") { graph.routes == [.loginForm] }
        #expect(graph.probe.signOutNotices == ["세션이 만료됐어요. 다시 로그인해 주세요"])
        await graph.close()
    }

    @Test("재로그인하면 시작 복귀가 다시 돈다 - 빗장이 되돌아간다")
    func relogInRunsStartupAgain() async throws {
        let graph = HostedGraph(activeRide: fakeRide())
        await graph.waitUntil("21") { graph.routes == [.home, .matchWaiting] }
        graph.auth.flow.value = .unauthenticated
        await graph.waitUntil("04a") { graph.routes == [.loginForm] }
        // 앞선 조회의 중복 방지 창(0.5초)이 지난 뒤의 재로그인 — 사람이 다시 로그인하는 데 걸리는 시간이다
        try? await Task.sleep(for: .milliseconds(600))
        graph.auth.flow.value = .authenticated(userUuid: "u")
        let nav = try graph.nav
        nav.resetTo(.home)
        // 04a 의 onLoggedIn 뒤 홈 진입 재조회 자리 — 홈의 `.task` 가 refresh 를 건다
        await graph.waitUntil("다시 21 로 복귀") { graph.routes == [.home, .matchWaiting] }
        await graph.close()
    }
}

/// `moyeotaBackHandler` 를 실제 `NavigationStack` 으로 시험한다 — 그래프 없이 수정자만.
@MainActor
@Observable
private final class HandlerRouter {
    var path: [Int] = []
    var rootEnabled = true
    var rootTag = "첫 값"
}

private struct HandlerHarness: View {
    @Bindable var router: HandlerRouter
    let onRoot: (String) -> Void
    let onPushed: () -> Void

    var body: some View {
        let tag = router.rootTag
        NavigationStack(path: $router.path) {
            Color.white
                .moyeotaBackHandler(enabled: router.rootEnabled) { onRoot(tag) }
                .navigationDestination(for: Int.self) { _ in
                    Color.red.moyeotaBackHandler { onPushed() }
                }
        }
    }
}

@MainActor
@Suite(.serialized) struct BackHandlerStackTest {
    private func host(_ view: some View) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = UIHostingController(rootView: view)
        window.isHidden = false
        return window
    }

    private func wait(
        _ window: UIWindow,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: () -> Bool
    ) async {
        for _ in 0..<200 {
            window.layoutIfNeeded()
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("기다려도 되지 않았다", sourceLocation: sourceLocation)
    }

    private func settle(_ window: UIWindow) async {
        for _ in 0..<20 {
            window.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    private var center: BackInterceptionCenter { .shared }

    @Test("위 화면이 덮으면 아래 화면 가로채기가 빠지고 뒤로가기는 맨 위 화면만 받는다")
    func topEntryOnly() async {
        let router = HandlerRouter()
        var rootCalls = 0
        var pushedCalls = 0
        let window = host(HandlerHarness(router: router, onRoot: { _ in rootCalls += 1 }, onPushed: { pushedCalls += 1 }))
        await wait(window) { center.isIntercepting }

        router.path = [1]
        await settle(window)
        #expect(center.handleBack())
        #expect(pushedCalls == 1)
        #expect(rootCalls == 0)

        router.path = []
        await settle(window)
        #expect(center.handleBack())
        #expect(rootCalls == 1, "돌아오면 다시 받는다")
        #expect(pushedCalls == 1)

        window.rootViewController = nil
        window.isHidden = true
        await wait(window) { !center.isIntercepting }
    }

    @Test("덮여 있는 동안 켜져도 등록되지 않고 돌아오면 등록된다")
    func enabledWhileCovered() async {
        let router = HandlerRouter()
        router.rootEnabled = false
        var rootCalls = 0
        var pushedCalls = 0
        let window = host(HandlerHarness(router: router, onRoot: { _ in rootCalls += 1 }, onPushed: { pushedCalls += 1 }))
        await settle(window)
        #expect(!center.isIntercepting)

        router.path = [1]
        await settle(window)
        router.rootEnabled = true
        await settle(window)
        #expect(center.handleBack())
        #expect(pushedCalls == 1)
        #expect(rootCalls == 0, "덮인 화면이 뒤로가기를 받았다")

        router.path = []
        await settle(window)
        #expect(center.handleBack())
        #expect(rootCalls == 1)

        window.rootViewController = nil
        window.isHidden = true
        await wait(window) { !center.isIntercepting }
    }

    @Test("등록 뒤 바뀐 동작을 부른다 - 원본 rememberUpdatedState")
    func latestAction() async {
        let router = HandlerRouter()
        var seen: [String] = []
        let window = host(HandlerHarness(router: router, onRoot: { seen.append($0) }, onPushed: {}))
        await wait(window) { center.isIntercepting }
        router.rootTag = "새 값"
        await settle(window)
        #expect(center.handleBack())
        #expect(seen == ["새 값"])

        window.rootViewController = nil
        window.isHidden = true
        await wait(window) { !center.isIntercepting }
    }
}
