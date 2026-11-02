import MoyeotaDomain
import SwiftUI
import Testing
import UIKit
@testable import FeatureChat

// 원본에 없는 테스트. 화면을 창에 올려 실제 `UIScrollView` 를 읽는다 — SwiftUI 뷰 상태는 바깥에서 읽을 길이 없다.

@MainActor
@Observable
private final class ScreenInputs {
    var search = ChatSearchUi()
}

private struct SearchToggleHarness: View {
    let inputs: ScreenInputs
    let messages: [ChatUiMessage]

    var body: some View {
        ChatScreen(roomTitle: "방", roomSubtitle: "경로", messages: messages, search: inputs.search)
    }
}

@MainActor
private final class HostedScreen {
    private let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
    private let host: UIViewController

    init<Root: View>(_ root: Root) {
        host = UIHostingController(rootView: root)
        window.rootViewController = host
        window.isHidden = false
    }

    func close() {
        window.isHidden = true
    }

    var scrollViews: [UIScrollView] {
        scrollViews(in: host.view)
    }

    var textFields: [UITextField] {
        textFields(in: host.view)
    }

    private func textFields(in view: UIView) -> [UITextField] {
        ((view as? UITextField).map { [$0] } ?? []) + view.subviews.flatMap { textFields(in: $0) }
    }

    private func scrollViews(in view: UIView) -> [UIScrollView] {
        // 입력 칸 내부의 스크롤 뷰는 세지 않는다
        if view is UITextView { return [] }
        return ((view as? UIScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) }
    }

    func waitUntil(_ what: String, sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async {
        for _ in 0..<200 {
            window.layoutIfNeeded()
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("기다려도 되지 않았다: \(what)", sourceLocation: sourceLocation)
    }

    /// 화면이 다시 그려지고 스크롤 멈춤 판정(150ms)이 끝날 시간을 준다.
    func settle() async {
        for _ in 0..<16 {
            window.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(25))
        }
    }
}

@MainActor
@Suite(.serialized) struct ChatScreenLayoutTest {

    private func messages(_ count: Int) -> [ChatUiMessage] {
        (1...count).map { ChatUiMessage(text: "메시지 \($0)", isMine: $0 % 3 == 0, senderName: "동승자", id: Int64($0)) }
    }

    @Test("지난 대화를 올려 읽다가 검색을 열고 닫아도 읽던 자리에 있다")
    func readingPositionSurvivesSearch() async {
        let inputs = ScreenInputs()
        let screen = HostedScreen(SearchToggleHarness(inputs: inputs, messages: messages(60)))
        defer { screen.close() }
        await screen.waitUntil("메시지 목록") { screen.scrollViews.count == 1 }
        await screen.settle()
        let list = screen.scrollViews[0]
        #expect(list.contentSize.height > list.bounds.height + 1_000, "올려 읽을 만큼 길어야 한다")

        let reading = CGPoint(x: 0, y: 500)
        list.setContentOffset(reading, animated: false)
        await screen.settle()

        inputs.search = ChatSearchUi(open: true)
        await screen.settle()
        inputs.search = ChatSearchUi()
        await screen.settle()

        #expect(screen.scrollViews.first === list, "닫을 때 새 스크롤 뷰가 만들어지면 위치가 0 으로 돌아간다")
        #expect(screen.scrollViews.first?.contentOffset == reading)
    }

    @Test("바닥에 있던 사람은 검색을 열고 닫아도 움직이지 않는다")
    func bottomPositionSurvivesSearch() async {
        let inputs = ScreenInputs()
        let screen = HostedScreen(SearchToggleHarness(inputs: inputs, messages: messages(60)))
        defer { screen.close() }
        await screen.waitUntil("메시지 목록") { screen.scrollViews.count == 1 }
        await screen.settle()
        // 씬이 없는 창에서는 애니메이션이 돌지 않아 첫 바닥 따라가기가 끝나지 않는다 — 바닥으로 직접 옮긴다
        let list = screen.scrollViews[0]
        let bottom = CGPoint(x: 0, y: list.contentSize.height - list.bounds.height)
        list.setContentOffset(bottom, animated: false)
        await screen.settle()

        inputs.search = ChatSearchUi(open: true)
        await screen.settle()
        inputs.search = ChatSearchUi()
        await screen.settle()

        #expect(screen.scrollViews.first === list)
        #expect(screen.scrollViews.first?.contentOffset == bottom)
    }

    @Test("검색 결과를 끌어도 키보드를 내리지 않는다")
    func searchResultsKeepKeyboard() async {
        let results = messages(30)
        let screen = HostedScreen(
            ChatScreen(
                roomTitle: "방",
                roomSubtitle: "경로",
                messages: [],
                search: ChatSearchUi(open: true, query: "메시지", results: results)
            )
        )
        defer { screen.close() }
        // 가려 둔 대화 목록 + 결과 목록
        await screen.waitUntil("결과 목록") { screen.scrollViews.count == 2 }
        #expect(screen.scrollViews.map(\.keyboardDismissMode) == [.none, .none])
    }

    @Test("신고 사유 시트를 끌어도 키보드를 내리지 않는다")
    func reportSheetKeepsKeyboard() async {
        let screen = HostedScreen(
            ReportReasonSheet(
                quotedText: "메시지",
                reason: .etc,
                description: "",
                submitting: false,
                failureMessage: nil,
                onReasonSelect: { _ in },
                onDescriptionChange: { _ in },
                onSubmit: { _ in },
                onDismiss: {}
            )
        )
        defer { screen.close() }
        await screen.waitUntil("시트") { screen.scrollViews.count == 1 }
        #expect(screen.scrollViews.map(\.keyboardDismissMode) == [.none])
    }

    @Test("검색 결과 수에는 구분 기호가 붙지 않는다")
    func searchCountHasNoGrouping() {
        #expect(searchResultCountLabel(count: 1_000, hasMore: false) == "검색 결과 1000개")
        #expect(searchResultCountLabel(count: 1_234, hasMore: true) == "검색 결과 1234개 이상")
        #expect(searchResultCountLabel(count: 3, hasMore: false) == "검색 결과 3개")
    }

    @Test("호스트가 탭 상태를 들고 있으면 탭을 떠났다 돌아와도 같은 방의 쓰던 입력이 남는다")
    func hostHeldTabStateSurvivesViewRemoval() async {
        let repository = ScriptedChatRepository()
        let state = ChatTabState(repository: repository)
        state.openedRoom = ChatRoom(id: 7, partyId: 0, departure: "출발", destination: "도착", createdAt: "2026-10-28T02:00:00Z", status: .active)
        state.openedMuted = true
        let roomViewModel = state.roomViewModel

        // 씬이 없는 창에서는 화면 시작 신호가 오지 않아(앱 전면이 아니다) 직접 시작한다
        roomViewModel.onScreenStart(roomId: 7, knownMuted: true)
        defer { roomViewModel.stopPolling() }
        for _ in 0..<200 where !roomViewModel.uiState.isSuccess {
            try? await Task.sleep(for: .milliseconds(25))
        }
        roomViewModel.onInputChange(text: "쓰던 글")

        // 첫 진입
        var screen: HostedScreen? = HostedScreen(ChatRoute(state: state))
        await screen?.waitUntil("입력 칸") { screen?.textFields.first?.text == "쓰던 글" }

        // 호스트가 다른 탭으로 갈아 끼운다
        screen?.close()
        screen = nil
        try? await Task.sleep(for: .milliseconds(100))

        // 돌아온다
        let again = HostedScreen(ChatRoute(state: state))
        defer { again.close() }
        await again.waitUntil("같은 방의 쓰던 입력") { again.textFields.first?.text == "쓰던 글" }

        #expect(state.openedRoom?.id == 7, "방이 닫혀 목록으로 돌아가면 안 된다")
        #expect(roomViewModel.uiState.isSuccess, "스피너부터 다시 돌면 안 된다")
    }
}
