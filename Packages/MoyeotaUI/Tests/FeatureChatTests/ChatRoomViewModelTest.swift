import Foundation
import MoyeotaDomain
import Testing
@testable import FeatureChat

/// `ChatRoomViewModel` 의 흐름 — 원본에 대응 테스트가 없는 iOS 전용 테스트다.
///
/// 원본 `viewModelScope` 는 `launch` 첫 구간을 호출한 자리에서 바로 돌리지만 Swift 태스크는 다음 차례에 시작해,
/// 상태 변경 순서를 옮겨 적은 자리가 있다. 그 옮김이 규칙을 깨지 않았는지를 가짜 저장소로 확인한다.
@MainActor
@Suite struct ChatRoomViewModelTest {

    private func message(_ id: Int64, _ content: String, mine: Bool = false) -> ChatMessage {
        ChatMessage(
            id: id,
            chatRoomId: 7,
            senderPublicId: mine ? "me" : "peer",
            content: content,
            type: .text,
            createdAt: "2026-10-28T02:00:00Z",
            deleted: false,
            isMine: mine,
            senderName: mine ? nil : "동승자"
        )
    }

    /// 조건이 설 때까지 양보하며 기다린다. 뷰모델 태스크가 메인 액터에서 도는 동안 끼어들 틈을 준다.
    private func eventually(_ what: Comment, until condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("기다리던 상태가 오지 않았다: \(what)")
    }

    private func messages(_ viewModel: ChatRoomViewModel) -> [ChatMessage]? {
        if case .success(let messages, _) = viewModel.uiState { return messages }
        return nil
    }

    private func pending(_ viewModel: ChatRoomViewModel) -> [ChatRoomViewModel.PendingMessage]? {
        if case .success(_, let pending) = viewModel.uiState { return pending }
        return nil
    }

    @Test("소켓으로 보내면 입력창을 비우고 되돌아온 메시지가 대기 말풍선을 걷어낸다")
    func socketSendIsConfirmedByEcho() async throws {
        let repository = FakeChatRepository()
        repository.page = ChatMessagePage(messages: [message(1, "안녕")], nextCursor: nil, hasNext: false)
        repository.socketWrites = true
        let viewModel = ChatRoomViewModel(repository: repository)
        defer { viewModel.stopPolling() }

        viewModel.onScreenStart(roomId: 7)
        try await eventually("대화 표시") { messages(viewModel) != nil }

        viewModel.onInputChange(text: "  다 왔어요 ")
        viewModel.send()
        #expect(viewModel.inputState.sending, "버튼을 두 번 누르는 사이에 sending 이 아직 거짓이다")

        try await eventually("대기 말풍선") { pending(viewModel)?.count == 1 }
        #expect(pending(viewModel)?.first?.content == "다 왔어요", "앞뒤 공백을 접어 보내야 한다")
        #expect(pending(viewModel)?.first?.sinceId == 1)
        #expect(viewModel.inputState == ChatRoomViewModel.InputState())
        #expect(repository.restSends.isEmpty, "소켓으로 보낸 뒤 REST 로 또 보내면 두 번 저장된다")

        repository.emit(.message(message: message(2, "다 왔어요", mine: true)))
        try await eventually("확인") { pending(viewModel)?.isEmpty == true }
        #expect(messages(viewModel)?.map(\.id) == [1, 2])
    }

    @Test("소켓이 없으면 REST 로 보내고 응답을 붙인다")
    func restSendAppendsResponse() async throws {
        let repository = FakeChatRepository()
        repository.page = ChatMessagePage(messages: [], nextCursor: nil, hasNext: false)
        repository.restResponse = message(5, "네", mine: true)
        let viewModel = ChatRoomViewModel(repository: repository)
        defer { viewModel.stopPolling() }

        viewModel.onScreenStart(roomId: 7)
        try await eventually("대화 표시") { messages(viewModel) != nil }

        viewModel.onInputChange(text: "네")
        viewModel.send()
        try await eventually("REST 응답") { messages(viewModel)?.map(\.id) == [5] }
        #expect(repository.restSends == ["네"])
        #expect(pending(viewModel)?.isEmpty == true)
        #expect(viewModel.inputState == ChatRoomViewModel.InputState())
    }

    @Test("REST 전송이 실패하면 입력을 남기고 안내한다")
    func restFailureKeepsInput() async throws {
        let repository = FakeChatRepository()
        repository.page = ChatMessagePage(messages: [], nextCursor: nil, hasNext: false)
        repository.restFailure = ChatException(code: "CHAT_ROOM_CLOSED", serverMessage: nil, httpStatus: 400)
        let viewModel = ChatRoomViewModel(repository: repository)
        defer { viewModel.stopPolling() }

        viewModel.onScreenStart(roomId: 7)
        try await eventually("대화 표시") { messages(viewModel) != nil }

        viewModel.onInputChange(text: "네")
        viewModel.send()
        try await eventually("실패 안내") { viewModel.inputState.errorMessage != nil }
        #expect(viewModel.inputState.text == "네")
        #expect(!viewModel.inputState.sending)
    }

    @Test("한도를 넘긴 입력은 보내지 않고 안내한다")
    func overLimitIsNotSent() async throws {
        let repository = FakeChatRepository()
        repository.page = ChatMessagePage(messages: [], nextCursor: nil, hasNext: false)
        let viewModel = ChatRoomViewModel(repository: repository)
        defer { viewModel.stopPolling() }

        viewModel.onScreenStart(roomId: 7)
        viewModel.onInputChange(text: String(repeating: "가", count: MAX_CONTENT_LENGTH + 1))
        viewModel.send()

        #expect(viewModel.inputState.errorMessage == "메시지는 1000자까지 보낼 수 있어요")
        #expect(!viewModel.inputState.sending)
    }

    @Test("연결되면 hasNext 를 따라 공백을 메우되 10페이지에서 멈춘다")
    func gapFillStopsAtPageLimit() async throws {
        let repository = FakeChatRepository()
        repository.page = ChatMessagePage(messages: [message(1, "하나")], nextCursor: nil, hasNext: false)
        repository.afterHasNextForever = true
        let viewModel = ChatRoomViewModel(repository: repository)
        defer { viewModel.stopPolling() }

        viewModel.onScreenStart(roomId: 7)
        try await eventually("대화 표시") { messages(viewModel) != nil }

        repository.emit(.connected)
        try await eventually("10페이지 조회") { repository.afterCursors.count == 10 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(repository.afterCursors.count == 10, "서버가 hasNext 를 잘못 내면 끝나지 않는 루프가 된다")
        #expect(repository.afterCursors == Array(1...10).map { Int64($0) })
        #expect(messages(viewModel)?.count == 11)
    }

    @Test("같은 id 가 소켓으로 다시 오면 새 사본이 이긴다")
    func socketRedeliveryReplaces() async throws {
        let repository = FakeChatRepository()
        repository.page = ChatMessagePage(messages: [message(1, "지울 말")], nextCursor: nil, hasNext: false)
        let viewModel = ChatRoomViewModel(repository: repository)
        defer { viewModel.stopPolling() }

        viewModel.onScreenStart(roomId: 7)
        try await eventually("대화 표시") { messages(viewModel) != nil }

        repository.emit(.message(message: message(1, "삭제된 메시지입니다")))
        try await eventually("삭제 반영") { messages(viewModel)?.first?.content == "삭제된 메시지입니다" }
        #expect(messages(viewModel)?.count == 1)
    }

    @Test("참여자가 아니면 에러 상태가 그 사실을 함께 든다")
    func notParticipantIsFlagged() async throws {
        let repository = FakeChatRepository()
        repository.pageFailure = ChatException(code: "CHAT_NOT_PARTICIPANT", serverMessage: nil, httpStatus: 403)
        let viewModel = ChatRoomViewModel(repository: repository)
        defer { viewModel.stopPolling() }

        viewModel.onScreenStart(roomId: 7)
        try await eventually("에러") { !viewModel.uiState.isSuccess && viewModel.uiState != .loading }
        #expect(viewModel.uiState == .error(message: "이 채팅방에 참여하고 있지 않아요", notParticipant: true))
    }

    @Test("이미 대화가 떠 있으면 재조회 실패로 화면을 갈아치우지 않는다")
    func silentReloadFailureKeepsConversation() async throws {
        let repository = FakeChatRepository()
        repository.page = ChatMessagePage(messages: [message(1, "하나")], nextCursor: nil, hasNext: false)
        let viewModel = ChatRoomViewModel(repository: repository)
        defer { viewModel.stopPolling() }

        viewModel.onScreenStart(roomId: 7)
        try await eventually("대화 표시") { messages(viewModel) != nil }

        repository.pageFailure = ChatException(code: nil, serverMessage: nil, isNetwork: true)
        let callsBefore = repository.pageCalls
        viewModel.onScreenStart(roomId: 7)
        try await eventually("재조회") { repository.pageCalls > callsBefore }
        try await Task.sleep(for: .milliseconds(50))
        #expect(messages(viewModel)?.map(\.id) == [1])
    }

    @Test("목록에서 받은 음소거 값은 목록 API 를 다시 부르지 않는다")
    func knownMutedSkipsListCall() async throws {
        let repository = FakeChatRepository()
        repository.page = ChatMessagePage(messages: [], nextCursor: nil, hasNext: false)
        let viewModel = ChatRoomViewModel(repository: repository)
        defer { viewModel.stopPolling() }

        viewModel.onScreenStart(roomId: 7, knownMuted: true)
        #expect(viewModel.muted)
        try await eventually("대화 표시") { messages(viewModel) != nil }
        #expect(repository.myRoomsCalls == 0)
    }

    @Test("음소거 변경이 거절되면 되돌리고 안내한다")
    func muteRollsBackOnFailure() async throws {
        let repository = FakeChatRepository()
        repository.page = ChatMessagePage(messages: [], nextCursor: nil, hasNext: false)
        repository.muteFailure = ChatException(code: nil, serverMessage: nil, isNetwork: true)
        let viewModel = ChatRoomViewModel(repository: repository)
        defer { viewModel.stopPolling() }

        viewModel.onScreenStart(roomId: 7, knownMuted: false)
        viewModel.toggleMuted()
        #expect(viewModel.muted, "응답을 기다리지 않고 먼저 바꾼다")
        try await eventually("되돌림") { !viewModel.muted }
        #expect(viewModel.inputState.errorMessage == "알림 설정을 바꾸지 못했어요")
    }

    @Test("신고는 보내는 동안 다시 보내지 않고 시작할 때 앞 결과를 지운다")
    func reportGuardsAndResets() async throws {
        let repository = FakeChatRepository()
        repository.page = ChatMessagePage(messages: [], nextCursor: nil, hasNext: false)
        repository.reportFailure = ChatException(code: "CHAT_ALREADY_REPORTED", serverMessage: nil, httpStatus: 409)
        let viewModel = ChatRoomViewModel(repository: repository)
        defer { viewModel.stopPolling() }

        viewModel.onScreenStart(roomId: 7)
        viewModel.reportMessage(chatMessageId: 3, reason: .abuse, description: nil)
        #expect(viewModel.reportState == ChatRoomViewModel.ReportState(submitting: true, outcome: nil))
        viewModel.reportMessage(chatMessageId: 3, reason: .abuse, description: nil)

        try await eventually("결과") { viewModel.reportState.outcome != nil }
        #expect(repository.reportCalls == 1, "같은 신고를 두 번 보냈다")
        #expect(viewModel.reportState.outcome?.message == "이미 신고한 메시지예요")

        // 같은 결과가 또 와도 화면이 변화를 볼 수 있게 nil 을 한 번 거친다
        viewModel.reportMessage(chatMessageId: 3, reason: .abuse, description: nil)
        #expect(viewModel.reportState.outcome == nil)
        try await eventually("둘째 결과") { viewModel.reportState.outcome != nil }
    }

    @Test("방을 갈아타면 앞 방의 상태를 비운다")
    func roomChangeResetsState() async throws {
        let repository = FakeChatRepository()
        repository.page = ChatMessagePage(messages: [message(1, "하나")], nextCursor: nil, hasNext: false)
        repository.members = [
            ChatMember(userId: nil, publicId: "peer", nickname: "스모크일", imageUrl: "https://cdn/01.png", active: true, isMe: false),
        ]
        let viewModel = ChatRoomViewModel(repository: repository)
        defer { viewModel.stopPolling() }

        viewModel.onScreenStart(roomId: 7, knownMuted: true)
        try await eventually("참여자") { viewModel.peerTitle == "스모크일" }
        viewModel.onInputChange(text: "쓰던 말")
        viewModel.openSearch()

        repository.membersFailure = ChatException(code: nil, serverMessage: nil, isNetwork: true)
        viewModel.onScreenStart(roomId: 8, knownMuted: false)
        #expect(viewModel.uiState == .loading)
        #expect(viewModel.peerTitle == nil)
        #expect(viewModel.peerImageUrls.isEmpty, "앞 방의 얼굴이 남으면 새 방에서 다른 사람 얼굴로 그려진다")
        #expect(!viewModel.muted)
        #expect(viewModel.inputState.text.isEmpty)
        #expect(!viewModel.searchState.open)
    }

    @Test("검색어가 짧으면 묻지 않고 길면 디바운스 뒤 한 번만 묻는다")
    func searchDebounces() async throws {
        let repository = FakeChatRepository()
        repository.page = ChatMessagePage(messages: [], nextCursor: nil, hasNext: false)
        repository.searchPage = ChatMessagePage(messages: [message(1, "부산역")], nextCursor: 1, hasNext: true)
        let viewModel = ChatRoomViewModel(repository: repository)
        defer { viewModel.stopPolling() }

        viewModel.onScreenStart(roomId: 7)
        viewModel.onSearchQueryChange(text: "부")
        #expect(viewModel.searchState.results == nil)
        #expect(!viewModel.searchState.loading)

        viewModel.onSearchQueryChange(text: "부산")
        viewModel.onSearchQueryChange(text: "부산역")
        #expect(viewModel.searchState.loading)
        try await eventually("검색 결과") { viewModel.searchState.results != nil }
        #expect(repository.searchKeywords == ["부산역"], "한 글자마다 요청이 나갔다")
        #expect(viewModel.searchState.hasNext)

        viewModel.closeSearch()
        #expect(viewModel.searchState == ChatRoomViewModel.SearchState())
    }
}

/// 읽고 쓰는 값이 많아 잠금 하나로 묶은 가짜 저장소. 호출은 테스트 안에서만 일어난다.
private final class FakeChatRepository: ChatRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var stored = Stored()

    private struct Stored {
        var page = ChatMessagePage(messages: [], nextCursor: nil, hasNext: false)
        var pageFailure: ChatException?
        var pageCalls = 0
        var afterHasNextForever = false
        var afterCursors: [Int64] = []
        var socketWrites = false
        var restSends: [String] = []
        var restResponse: ChatMessage?
        var restFailure: ChatException?
        var members: [ChatMember] = []
        var membersFailure: ChatException?
        var myRoomsCalls = 0
        var muteFailure: ChatException?
        var reportFailure: ChatException?
        var reportCalls = 0
        var searchPage = ChatMessagePage(messages: [], nextCursor: nil, hasNext: false)
        var searchKeywords: [String] = []
        var continuation: AsyncStream<ChatRealtimeEvent>.Continuation?
    }

    private func value<T>(_ read: (Stored) -> T) -> T { lock.withLock { read(stored) } }
    private func update(_ write: (inout Stored) -> Void) { lock.withLock { write(&stored) } }

    var page: ChatMessagePage {
        get { value(\.page) }
        set { update { $0.page = newValue } }
    }
    var pageFailure: ChatException? {
        get { value(\.pageFailure) }
        set { update { $0.pageFailure = newValue } }
    }
    var pageCalls: Int { value(\.pageCalls) }
    var afterHasNextForever: Bool {
        get { value(\.afterHasNextForever) }
        set { update { $0.afterHasNextForever = newValue } }
    }
    var afterCursors: [Int64] { value(\.afterCursors) }
    var socketWrites: Bool {
        get { value(\.socketWrites) }
        set { update { $0.socketWrites = newValue } }
    }
    var restSends: [String] { value(\.restSends) }
    var restResponse: ChatMessage? {
        get { value(\.restResponse) }
        set { update { $0.restResponse = newValue } }
    }
    var restFailure: ChatException? {
        get { value(\.restFailure) }
        set { update { $0.restFailure = newValue } }
    }
    var members: [ChatMember] {
        get { value(\.members) }
        set { update { $0.members = newValue } }
    }
    var membersFailure: ChatException? {
        get { value(\.membersFailure) }
        set { update { $0.membersFailure = newValue } }
    }
    var myRoomsCalls: Int { value(\.myRoomsCalls) }
    var muteFailure: ChatException? {
        get { value(\.muteFailure) }
        set { update { $0.muteFailure = newValue } }
    }
    var reportFailure: ChatException? {
        get { value(\.reportFailure) }
        set { update { $0.reportFailure = newValue } }
    }
    var reportCalls: Int { value(\.reportCalls) }
    var searchPage: ChatMessagePage {
        get { value(\.searchPage) }
        set { update { $0.searchPage = newValue } }
    }
    var searchKeywords: [String] { value(\.searchKeywords) }

    func emit(_ event: ChatRealtimeEvent) {
        _ = value(\.continuation)?.yield(event)
    }

    func getMyChatRooms() async throws -> [MyChatRoom] {
        update { $0.myRoomsCalls += 1 }
        return []
    }

    func getChatRoom(chatRoomId: Int64) async throws -> ChatRoom {
        ChatRoom(id: chatRoomId, partyId: 0, departure: "출발", destination: "도착", createdAt: "2026-10-28T02:00:00Z", status: .active)
    }

    func joinChatRoom(chatRoomId: Int64) async throws {}

    func leaveChatRoom(chatRoomId: Int64) async throws {}

    func getChatRoomMembers(chatRoomId: Int64) async throws -> [ChatMember] {
        if let failure = value(\.membersFailure) { throw failure }
        return value(\.members)
    }

    func setNotificationMuted(chatRoomId: Int64, muted: Bool) async throws {
        if let failure = value(\.muteFailure) { throw failure }
    }

    func markAsRead(chatRoomId: Int64, readMessageId: Int64) async throws {}

    func getMessages(chatRoomId: Int64, cursor: Int64?, size: Int) async throws -> ChatMessagePage {
        update { $0.pageCalls += 1 }
        if let failure = value(\.pageFailure) { throw failure }
        return value(\.page)
    }

    func observeRoom(chatRoomId: Int64) -> AsyncStream<ChatRealtimeEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: ChatRealtimeEvent.self)
        update { $0.continuation = continuation }
        return stream
    }

    func getMessagesAfter(chatRoomId: Int64, cursor: Int64, size: Int) async throws -> ChatMessagePage {
        update { $0.afterCursors.append(cursor) }
        guard value(\.afterHasNextForever) else {
            return ChatMessagePage(messages: [], nextCursor: nil, hasNext: false)
        }
        let id = cursor + 1
        let message = ChatMessage(
            id: id,
            chatRoomId: chatRoomId,
            senderPublicId: "peer",
            content: "메시지 \(id)",
            type: .text,
            createdAt: "2026-10-28T02:00:00Z",
            deleted: false,
            isMine: false,
            senderName: "동승자"
        )
        return ChatMessagePage(messages: [message], nextCursor: id, hasNext: true)
    }

    func trySendMessage(chatRoomId: Int64, content: String) async throws -> Bool {
        value(\.socketWrites)
    }

    func tryMarkAsRead(chatRoomId: Int64, readMessageId: Int64) async throws -> Bool {
        true
    }

    func sendMessage(chatRoomId: Int64, content: String) async throws -> ChatMessage {
        update { $0.restSends.append(content) }
        if let failure = value(\.restFailure) { throw failure }
        guard let response = value(\.restResponse) else { throw CancellationError() }
        return response
    }

    func deleteMessage(chatRoomId: Int64, messageId: Int64) async throws {}

    func searchMessages(chatRoomId: Int64, keyword: String, cursor: Int64?, size: Int) async throws -> ChatMessagePage {
        update { $0.searchKeywords.append(keyword) }
        return value(\.searchPage)
    }

    func reportMessage(
        chatRoomId: Int64,
        chatMessageId: Int64,
        reason: ChatReportReason,
        description: String?
    ) async throws {
        update { $0.reportCalls += 1 }
        if let failure = value(\.reportFailure) { throw failure }
    }
}
