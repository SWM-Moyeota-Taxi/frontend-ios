import Foundation
import MoyeotaDomain
import Testing
@testable import FeatureChat

/// 요청이 끊기는 두 경우 — 원본에 대응 테스트가 없는 iOS 전용 테스트다.
///
/// 1. 뷰모델이 사라지면 진행 중인 요청도 끊긴다(원본 `viewModelScope` 취소). 태스크가 대기 구간에서 `self` 를 강하게
///    잡으면 뷰모델이 해제되지 않아 `ViewModelScope.deinit` 의 취소가 돌지 않는다.
/// 2. 태스크가 살아 있는데 온 `URLError(.cancelled)` 는 실패다. 원본에서는 OkHttp `IOException` 이라 오류 문구나
///    재시도 길을 남긴다. 취소로 보고 끝내면 스피너와 「보내는 중」 잠금이 그대로 남는다.
@MainActor
@Suite struct ChatRequestCancellationTest {

    private func eventually(_ what: Comment, until condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("기다리던 상태가 오지 않았다: \(what)")
    }

    /// `act` 로 요청을 띄워 `op` 가 걸린 채 뷰모델을 놓는다. 뷰모델이 해제되고 그 요청이 취소돼야 한다.
    private func expectReleaseCancels(
        _ op: ScriptedChatRepository.Op,
        repository: ScriptedChatRepository = ScriptedChatRepository(),
        act: (ChatRoomViewModel, ScriptedChatRepository) async throws -> Void
    ) async throws {
        repository.set(op, .hang)
        var viewModel: ChatRoomViewModel? = ChatRoomViewModel(repository: repository)
        weak let released = viewModel
        try await act(viewModel!, repository)
        try await eventually("요청 시작") { repository.startedCount(op) >= 1 }

        viewModel = nil
        try await eventually("뷰모델 해제") { released == nil }
        try await eventually("요청 취소") { repository.cancelledCount(op) >= 1 }
    }

    private func openedRoom(_ repository: ScriptedChatRepository) async throws -> ChatRoomViewModel {
        let viewModel = ChatRoomViewModel(repository: repository)
        viewModel.onScreenStart(roomId: 7, knownMuted: false)
        try await eventually("대화 표시") { viewModel.uiState.isSuccess }
        return viewModel
    }

    // ─── 뷰모델이 사라지면 요청도 끊긴다 ─────────────────────────────────────────

    @Test("첫 조회 중에 뷰모델이 사라지면 조회가 끊긴다")
    func releaseCancelsLoad() async throws {
        try await expectReleaseCancels(.messages) { viewModel, _ in
            viewModel.onScreenStart(roomId: 7, knownMuted: false)
        }
    }

    @Test("참여자 조회 중에 뷰모델이 사라지면 조회가 끊긴다")
    func releaseCancelsMembers() async throws {
        try await expectReleaseCancels(.members) { viewModel, _ in
            viewModel.onScreenStart(roomId: 7, knownMuted: false)
        }
    }

    @Test("음소거 조회 중에 뷰모델이 사라지면 조회가 끊긴다")
    func releaseCancelsMutedLookup() async throws {
        try await expectReleaseCancels(.myRooms) { viewModel, _ in
            viewModel.onScreenStart(roomId: 7)
        }
    }

    @Test("음소거 변경 중에 뷰모델이 사라지면 요청이 끊긴다")
    func releaseCancelsMute() async throws {
        try await expectReleaseCancels(.mute) { viewModel, _ in
            viewModel.onScreenStart(roomId: 7, knownMuted: false)
            viewModel.toggleMuted()
        }
    }

    @Test("나가기 중에 뷰모델이 사라지면 요청이 끊긴다")
    func releaseCancelsLeave() async throws {
        try await expectReleaseCancels(.leave) { viewModel, _ in
            viewModel.onScreenStart(roomId: 7, knownMuted: false)
            viewModel.leaveRoom()
        }
    }

    @Test("신고 중에 뷰모델이 사라지면 요청이 끊긴다")
    func releaseCancelsReport() async throws {
        try await expectReleaseCancels(.report) { viewModel, _ in
            viewModel.onScreenStart(roomId: 7, knownMuted: false)
            viewModel.reportMessage(chatMessageId: 3, reason: .abuse, description: nil)
        }
    }

    @Test("REST 전송 중에 뷰모델이 사라지면 요청이 끊긴다")
    func releaseCancelsRestSend() async throws {
        try await expectReleaseCancels(.send) { viewModel, _ in
            viewModel.onScreenStart(roomId: 7, knownMuted: false)
            viewModel.onInputChange(text: "네")
            viewModel.send()
        }
    }

    @Test("소켓 전송을 기다리다 뷰모델이 사라지면 REST 로 다시 보내지 않는다")
    func releaseDuringSocketSendSkipsRest() async throws {
        let repository = ScriptedChatRepository()
        try await expectReleaseCancels(.trySend, repository: repository) { viewModel, _ in
            viewModel.onScreenStart(roomId: 7, knownMuted: false)
            viewModel.onInputChange(text: "네")
            viewModel.send()
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(repository.startedCount(.send) == 0)
    }

    @Test("검색 중에 뷰모델이 사라지면 요청이 끊긴다")
    func releaseCancelsSearch() async throws {
        try await expectReleaseCancels(.search) { viewModel, _ in
            viewModel.onScreenStart(roomId: 7, knownMuted: false)
            viewModel.onSearchQueryChange(text: "부산역")
        }
    }

    @Test("이전 결과를 더 받는 중에 뷰모델이 사라지면 요청이 끊긴다")
    func releaseCancelsSearchMore() async throws {
        let repository = ScriptedChatRepository()
        repository.searchPage = ChatMessagePage(messages: [repository.message(9)], nextCursor: 9, hasNext: true)
        var viewModel: ChatRoomViewModel? = try await openedRoom(repository)
        weak let released = viewModel
        viewModel?.onSearchQueryChange(text: "부산역")
        try await eventually("첫 결과") { released?.searchState.results != nil }

        repository.set(.search, .hang)
        viewModel?.loadMoreSearch()
        try await eventually("다음 페이지 요청") { repository.startedCount(.search) == 2 }

        viewModel = nil
        try await eventually("뷰모델 해제") { released == nil }
        try await eventually("요청 취소") { repository.cancelledCount(.search) == 1 }
    }

    @Test("소켓이 붙어 공백을 메우는 중에 뷰모델이 사라지면 요청이 끊긴다")
    func releaseCancelsGapFillFromSocket() async throws {
        let repository = ScriptedChatRepository()
        repository.set(.after, .hang)
        var viewModel: ChatRoomViewModel? = try await openedRoom(repository)
        weak let released = viewModel

        repository.emit(.connected)
        try await eventually("공백 조회") { repository.startedCount(.after) == 1 }

        viewModel = nil
        try await eventually("뷰모델 해제") { released == nil }
        try await eventually("요청 취소") { repository.cancelledCount(.after) == 1 }
    }

    @Test("첫 조회가 이어 받는 공백 조회 중에 뷰모델이 사라지면 요청이 끊긴다")
    func releaseCancelsGapFillAfterLoad() async throws {
        let repository = ScriptedChatRepository()
        repository.set(.messages, .hang)
        repository.set(.after, .hang)
        var viewModel: ChatRoomViewModel? = ChatRoomViewModel(repository: repository)
        weak let released = viewModel
        viewModel?.onScreenStart(roomId: 7, knownMuted: false)
        try await eventually("첫 조회") { repository.startedCount(.messages) == 1 }

        // 조회가 걸린 동안 소켓이 먼저 붙는다 — 그 순간의 공백 조회는 대화가 아직 없어 건너뛰고, 첫 조회 뒤로 미룬다.
        repository.emit(.connected)
        try await Task.sleep(for: .milliseconds(50))
        repository.releaseHang(.messages)
        try await eventually("공백 조회") { repository.startedCount(.after) == 1 }

        viewModel = nil
        try await eventually("뷰모델 해제") { released == nil }
        try await eventually("요청 취소") { repository.cancelledCount(.after) == 1 }
    }

    @Test("폴링이 공백을 메우는 중에 뷰모델이 사라지면 요청이 끊긴다")
    func releaseCancelsGapFillFromPolling() async throws {
        let repository = ScriptedChatRepository()
        repository.set(.after, .hang)
        var viewModel: ChatRoomViewModel? = try await openedRoom(repository)
        weak let released = viewModel

        // 소켓이 안 붙은 채 3초 주기를 기다린다
        try await eventually("폴링 조회") { repository.startedCount(.after) == 1 }

        viewModel = nil
        try await eventually("뷰모델 해제") { released == nil }
        try await eventually("요청 취소") { repository.cancelledCount(.after) == 1 }
    }

    @Test("방 목록 조회 중에 뷰모델이 사라지면 조회가 끊긴다")
    func releaseCancelsList() async throws {
        let repository = ScriptedChatRepository()
        repository.set(.myRooms, .hang)
        var viewModel: ChatListViewModel? = ChatListViewModel(repository: repository)
        weak let released = viewModel
        viewModel?.refresh()
        try await eventually("조회 시작") { repository.startedCount(.myRooms) == 1 }

        viewModel = nil
        try await eventually("뷰모델 해제") { released == nil }
        try await eventually("요청 취소") { repository.cancelledCount(.myRooms) == 1 }
    }

    // ─── 태스크가 살아 있는데 온 URLError(.cancelled) ───────────────────────────

    @Test("태스크 취소 없는 URLError(.cancelled) 로 첫 조회가 끝나면 재시도 화면을 그린다")
    func liveCancelErrorShowsLoadError() async throws {
        let repository = ScriptedChatRepository()
        repository.set(.messages, .fail(URLError(.cancelled)))
        let viewModel = ChatRoomViewModel(repository: repository)
        defer { viewModel.stopPolling() }

        viewModel.onScreenStart(roomId: 7, knownMuted: false)
        try await eventually("에러") { viewModel.uiState != .loading }
        #expect(viewModel.uiState == .error(message: "대화를 불러오지 못했어요", notParticipant: false))
    }

    @Test("태스크 취소 없는 URLError(.cancelled) 로 방 목록이 끝나면 재시도 화면을 그린다")
    func liveCancelErrorShowsListError() async throws {
        let repository = ScriptedChatRepository()
        repository.set(.myRooms, .fail(URLError(.cancelled)))
        let viewModel = ChatListViewModel(repository: repository)

        viewModel.refresh()
        try await eventually("에러") { viewModel.uiState != .loading }
        #expect(viewModel.uiState == .error(message: "채팅방 목록을 불러오지 못했어요"))
    }

    @Test("태스크 취소 없는 URLError(.cancelled) 로 나가기가 끝나면 사유를 알린다")
    func liveCancelErrorReportsLeaveFailure() async throws {
        let repository = ScriptedChatRepository()
        repository.set(.leave, .fail(URLError(.cancelled)))
        let viewModel = try await openedRoom(repository)
        defer { viewModel.stopPolling() }

        viewModel.leaveRoom()
        try await eventually("안내") { viewModel.inputState.errorMessage != nil }
        #expect(viewModel.inputState.errorMessage == "채팅방에서 나가지 못했어요")
        #expect(!viewModel.leftRoom)
    }

    @Test("태스크 취소 없는 URLError(.cancelled) 로 신고가 끝나면 잠금을 풀고 다시 보낼 수 있다")
    func liveCancelErrorUnlocksReport() async throws {
        let repository = ScriptedChatRepository()
        repository.set(.report, .fail(URLError(.cancelled)))
        let viewModel = try await openedRoom(repository)
        defer { viewModel.stopPolling() }

        viewModel.reportMessage(chatMessageId: 3, reason: .abuse, description: nil)
        try await eventually("결과") { viewModel.reportState.outcome != nil }
        #expect(!viewModel.reportState.submitting, "「보내는 중」에 잠기면 방을 바꾸기 전까지 신고가 무시된다")
        // 원본에서는 OkHttp IOException 이 네트워크 실패로 올라온다
        #expect(viewModel.reportState.outcome == ChatReportOutcome(
            message: "연결이 끊겼어요. 잠시 뒤 다시 시도해 주세요",
            accepted: false,
            retryable: true
        ))
    }

    @Test("태스크 취소 없는 URLError(.cancelled) 로 검색이 끝나면 재시도 길을 남긴다")
    func liveCancelErrorShowsSearchError() async throws {
        let repository = ScriptedChatRepository()
        repository.set(.search, .fail(URLError(.cancelled)))
        let viewModel = try await openedRoom(repository)
        defer { viewModel.stopPolling() }

        viewModel.onSearchQueryChange(text: "부산역")
        try await eventually("안내") { viewModel.searchState.errorMessage != nil }
        #expect(viewModel.searchState.errorMessage == "검색하지 못했어요")
        #expect(!viewModel.searchState.loading)
    }

    @Test("살아 있는 태스크의 URLError(.cancelled) 만 네트워크 실패로 옮긴다")
    func liveFailureMapping() async {
        let mapped = chatFailureOnLiveTask(error: URLError(.cancelled))
        #expect((mapped as? ChatException)?.isNetwork == true)

        let other = ChatException(code: "CHAT_ROOM_CLOSED", serverMessage: nil, httpStatus: 400)
        #expect((chatFailureOnLiveTask(error: other) as? ChatException)?.code == "CHAT_ROOM_CLOSED")
        #expect(chatFailureOnLiveTask(error: CancellationError()) is CancellationError)

        let cancelled = Task<Bool, Never> {
            withUnsafeCurrentTask { $0?.cancel() }
            return chatFailureOnLiveTask(error: URLError(.cancelled)) == nil
                && chatFailureOnLiveTask(error: CancellationError()) == nil
        }
        #expect(await cancelled.value, "정말 취소된 태스크는 쓸 곳이 없다")
    }

    // ─── 태스크가 정말 취소된 경우는 그대로 조용하다 ───────────────────────────

    @Test("방을 갈아타 취소된 앞 방의 조회는 오류를 쓰지 않는다")
    func cancelledLoadWritesNothing() async throws {
        let repository = ScriptedChatRepository()
        repository.set(.messages, .hang)
        let viewModel = ChatRoomViewModel(repository: repository)
        defer { viewModel.stopPolling() }

        viewModel.onScreenStart(roomId: 7, knownMuted: false)
        try await eventually("앞 방 조회") { repository.startedCount(.messages) == 1 }
        viewModel.onScreenStart(roomId: 8, knownMuted: false)
        try await eventually("앞 방 조회 취소") { repository.cancelledCount(.messages) == 1 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(viewModel.uiState == .loading)
    }

    @Test("검색어를 바꿔 취소된 앞 검색은 오류를 쓰지 않는다")
    func cancelledSearchWritesNothing() async throws {
        let repository = ScriptedChatRepository()
        repository.set(.search, .hang)
        let viewModel = try await openedRoom(repository)
        defer { viewModel.stopPolling() }

        viewModel.onSearchQueryChange(text: "부산역")
        try await eventually("앞 검색") { repository.startedCount(.search) == 1 }
        viewModel.closeSearch()
        try await eventually("앞 검색 취소") { repository.cancelledCount(.search) == 1 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(viewModel.searchState == ChatRoomViewModel.SearchState())
    }
}

/// 호출마다 동작을 고르는 가짜 저장소. `hang` 은 취소될 때까지 돌아오지 않고, 취소되면 `URLSession` 처럼 `URLError(.cancelled)` 를 던진다.
final class ScriptedChatRepository: ChatRepository, @unchecked Sendable {
    enum Op: Hashable, Sendable {
        case myRooms, members, mute, leave, messages, after, trySend, send, search, report
    }

    enum Behavior: @unchecked Sendable {
        case succeed
        case hang
        case fail(any Error)
    }

    private let lock = NSLock()
    private var behaviors: [Op: Behavior] = [:]
    private var started: [Op: Int] = [:]
    private var cancelled: [Op: Int] = [:]
    private var released: Set<Op> = []
    private var continuation: AsyncStream<ChatRealtimeEvent>.Continuation?
    private var storedSearchPage = ChatMessagePage(messages: [], nextCursor: nil, hasNext: false)

    func set(_ op: Op, _ behavior: Behavior) {
        lock.withLock { behaviors[op] = behavior }
    }

    /// 걸어 둔 호출을 정상 반환시킨다
    func releaseHang(_ op: Op) {
        lock.withLock {
            released.insert(op)
            behaviors[op] = .succeed
        }
    }

    func startedCount(_ op: Op) -> Int { lock.withLock { started[op, default: 0] } }
    func cancelledCount(_ op: Op) -> Int { lock.withLock { cancelled[op, default: 0] } }
    func emit(_ event: ChatRealtimeEvent) {
        _ = lock.withLock { continuation }?.yield(event)
    }

    var searchPage: ChatMessagePage {
        get { lock.withLock { storedSearchPage } }
        set { lock.withLock { storedSearchPage = newValue } }
    }

    func message(_ id: Int64) -> ChatMessage {
        ChatMessage(
            id: id,
            chatRoomId: 7,
            senderPublicId: "peer",
            content: "메시지 \(id)",
            type: .text,
            createdAt: "2026-10-28T02:00:00Z",
            deleted: false,
            isMine: false,
            senderName: "동승자"
        )
    }

    private func run(_ op: Op) async throws {
        let behavior = lock.withLock {
            started[op, default: 0] += 1
            return behaviors[op] ?? .succeed
        }
        switch behavior {
        case .succeed:
            return
        case .fail(let error):
            throw error
        case .hang:
            try await withTaskCancellationHandler {
                while !lock.withLock({ released.contains(op) }) {
                    do {
                        try await Task.sleep(for: .milliseconds(10))
                    } catch {
                        throw URLError(.cancelled)
                    }
                }
            } onCancel: {
                lock.withLock { cancelled[op, default: 0] += 1 }
            }
        }
    }

    func getMyChatRooms() async throws -> [MyChatRoom] {
        try await run(.myRooms)
        return []
    }

    func getChatRoom(chatRoomId: Int64) async throws -> ChatRoom {
        ChatRoom(id: chatRoomId, partyId: 0, departure: "출발", destination: "도착", createdAt: "2026-10-28T02:00:00Z", status: .active)
    }

    func joinChatRoom(chatRoomId: Int64) async throws {}

    func leaveChatRoom(chatRoomId: Int64) async throws {
        try await run(.leave)
    }

    func getChatRoomMembers(chatRoomId: Int64) async throws -> [ChatMember] {
        try await run(.members)
        return []
    }

    func setNotificationMuted(chatRoomId: Int64, muted: Bool) async throws {
        try await run(.mute)
    }

    func markAsRead(chatRoomId: Int64, readMessageId: Int64) async throws {}

    func getMessages(chatRoomId: Int64, cursor: Int64?, size: Int) async throws -> ChatMessagePage {
        try await run(.messages)
        return ChatMessagePage(messages: [message(1)], nextCursor: nil, hasNext: false)
    }

    func observeRoom(chatRoomId: Int64) -> AsyncStream<ChatRealtimeEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: ChatRealtimeEvent.self)
        lock.withLock { self.continuation = continuation }
        return stream
    }

    func getMessagesAfter(chatRoomId: Int64, cursor: Int64, size: Int) async throws -> ChatMessagePage {
        try await run(.after)
        return ChatMessagePage(messages: [], nextCursor: nil, hasNext: false)
    }

    func trySendMessage(chatRoomId: Int64, content: String) async throws -> Bool {
        try await run(.trySend)
        return false
    }

    func tryMarkAsRead(chatRoomId: Int64, readMessageId: Int64) async throws -> Bool {
        true
    }

    func sendMessage(chatRoomId: Int64, content: String) async throws -> ChatMessage {
        try await run(.send)
        return message(2)
    }

    func deleteMessage(chatRoomId: Int64, messageId: Int64) async throws {}

    func searchMessages(chatRoomId: Int64, keyword: String, cursor: Int64?, size: Int) async throws -> ChatMessagePage {
        try await run(.search)
        return searchPage
    }

    func reportMessage(
        chatRoomId: Int64,
        chatMessageId: Int64,
        reason: ChatReportReason,
        description: String?
    ) async throws {
        try await run(.report)
    }
}
