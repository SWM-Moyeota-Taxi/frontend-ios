import Foundation
import MoyeotaDomain
import Testing
@testable import MoyeotaData

private let UUID_ME = "uuid-me"
private let UUID_OTHER = "uuid-other"

/// 서버가 메시지에 발신자 `publicId` 를 실어 주면서 이 저장소의 판정 책임은 **이름 하나**로 줄었다
/// (내 메시지 여부는 매퍼의 문자열 비교로 끝난다 — `ChatMappersTest`).
/// 그래서 여기서 지키는 건 두 가지다: 참여자 사전이 없거나 실패해도 **isMine 이 흔들리지 않을 것**,
/// 그리고 사전 조회가 필요 이상으로 반복되지 않을 것.
@Suite struct RemoteChatRepositoryTest {

    /// 예전에는 "이번 세션에 한 번 보내기 전"까지 내 메시지가 상대 쪽에 있었다(학습 폴백의 대가).
    /// 그 대가는 사라졌다 — 방에 처음 들어간 첫 프레임부터 정확해야 한다.
    @Test("참여자 목록 없이 첫 진입부터 내 메시지를 가린다")
    func marksMineWithoutMembers() async throws {
        let api = FakeChatApi(history: [message(id: 1, publicId: UUID_ME), message(id: 2, publicId: UUID_OTHER)])

        let page = try await RemoteChatRepository(api: api, session: FakeChatSession()).getMessages(chatRoomId: 5)

        #expect(page.messages.map(\.isMine) == [true, false])
    }

    @Test("방금 보낸 메시지는 응답만으로 내 것이 된다")
    func sentIsMine() async throws {
        let api = FakeChatApi()

        let sent = try await RemoteChatRepository(api: api, session: FakeChatSession())
            .sendMessage(chatRoomId: 5, content: "안녕하세요")

        #expect(sent.isMine, "전송 응답의 publicId 를 읽지 못했다")
        #expect(sent.content == "안녕하세요")
    }

    @Test("전송 본문에는 내용만 담고 사용자 id 는 싣지 않는다")
    func sendBodyContentOnly() async throws {
        let api = FakeChatApi()

        _ = try await RemoteChatRepository(api: api, session: FakeChatSession()).sendMessage(chatRoomId: 5, content: "안녕")

        #expect(api.sentBody.value == SendMessageRequestDto(content: "안녕"))
        #expect(api.sentRoomId.value == 5)
    }

    @Test("참여자 목록으로 보낸 사람 이름을 채운다")
    func fillsSenderName() async throws {
        let api = FakeChatApi(
            history: [message(id: 1, publicId: UUID_ME), message(id: 2, publicId: UUID_OTHER)],
            members: [
                memberDto(publicId: UUID_ME, nickname: "스모크일"),
                memberDto(publicId: UUID_OTHER, nickname: "스모크이"),
            ]
        )

        let page = try await RemoteChatRepository(api: api, session: FakeChatSession()).getMessages(chatRoomId: 5)

        #expect(page.messages.map(\.senderName) == ["스모크일", "스모크이"])
        #expect(api.memberCalls.value == 1)
    }

    // 나간 사람도 active=false 로 목록에 남는다 — 이름이 사라지면 대화가 "동승자"로 뭉개진다.
    @Test("방을 나간 참여자의 메시지도 이름을 유지한다")
    func leftMemberKeepsName() async throws {
        let api = FakeChatApi(
            history: [message(id: 1, publicId: "uuid-gone")],
            members: [memberDto(publicId: "uuid-gone", nickname: "먼저내림", active: false)]
        )

        let page = try await RemoteChatRepository(api: api, session: FakeChatSession()).getMessages(chatRoomId: 5)

        #expect(page.messages.count == 1)
        #expect(page.messages.first?.senderName == "먼저내림")
    }

    /// 참여자 목록은 이름을 위한 것뿐이다. 조회가 실패해도 채팅방은 열려야 하고,
    /// **무엇보다 내 말풍선 위치가 흔들리면 안 된다** — 예전 구조에서는 여기서 판정이 무너졌다.
    @Test("참여자 조회에 실패해도 메시지와 내 메시지 판정은 그대로다")
    func membersFailureKeepsIsMine() async throws {
        let api = FakeChatApi(
            history: [message(id: 1, publicId: UUID_ME)],
            membersFailure: IllegalStateException("참여자 조회 실패")
        )

        let page = try await RemoteChatRepository(api: api, session: FakeChatSession()).getMessages(chatRoomId: 5)

        let only = try #require(page.messages.first)
        #expect(page.messages.count == 1)
        #expect(only.isMine, "사전이 없다고 내 메시지를 놓쳤다")
        #expect(only.senderName == nil)
    }

    // 사전에 없는 발신자를 폴링마다 다시 물으면 트래픽이 두 배가 된다. 한 번만 묻고 적어 둔다.
    @Test("못 찾은 발신자를 폴링마다 다시 조회하지 않는다")
    func unresolvedNotRequeried() async throws {
        let api = FakeChatApi(
            history: [message(id: 1, publicId: "uuid-ghost")],
            members: [memberDto(publicId: UUID_OTHER, nickname: "자동에이")]
        )
        let repository = RemoteChatRepository(api: api, session: FakeChatSession())

        _ = try await repository.getMessages(chatRoomId: 5)
        let afterInitialLoad = api.memberCalls.value

        _ = try await repository.getMessagesAfter(chatRoomId: 5, cursor: 1)
        _ = try await repository.getMessagesAfter(chatRoomId: 5, cursor: 1)

        #expect(afterInitialLoad == 1, "초기 로드에서 한 번만 불러야 한다")
        #expect(api.memberCalls.value == 1, "모르는 발신자를 폴링마다 다시 조회하고 있다")
    }

    // 방에 뒤늦게 합류한 사람의 첫 메시지. 사전에 없는 발신자가 나오면 그 로드에서 한 번 다시 받는다.
    @Test("새 참여자가 나타나면 한 번만 재조회해 이름을 채운다")
    func newMemberRefreshedOnce() async throws {
        let api = FakeChatApi(
            history: [message(id: 1, publicId: UUID_ME)],
            members: [memberDto(publicId: UUID_ME, nickname: "스모크일")]
        )
        let repository = RemoteChatRepository(api: api, session: FakeChatSession())
        _ = try await repository.getMessages(chatRoomId: 5)

        // 중간 합류자가 말을 걸었다.
        api.members.value = api.members.value + [memberDto(publicId: UUID_OTHER, nickname: "늦게탄사람")]
        api.afterMessages.value = [message(id: 2, publicId: UUID_OTHER)]

        let fresh = try await repository.getMessagesAfter(chatRoomId: 5, cursor: 1)
        #expect(fresh.messages.count == 1)
        #expect(fresh.messages.first?.senderName == "늦게탄사람")
        #expect(api.memberCalls.value == 2)

        // 이제 사전에 있으니 다음 폴링은 조용해야 한다.
        _ = try await repository.getMessagesAfter(chatRoomId: 5, cursor: 2)
        #expect(api.memberCalls.value == 2)
    }

    /// 계정이 바뀌면 참여자 캐시는 남의 것이다. 캐시를 버리는지 확인하려면 **캐시에만 있는 이름**이
    /// 사라지는지 봐야 한다(isMine 은 이제 캐시와 무관하게 세션 uuid 로 판정되므로 근거가 못 된다).
    @Test("계정이 바뀌면 참여자 캐시를 버린다")
    func accountChangeDropsCache() async throws {
        let api = FakeChatApi(
            history: [message(id: 1, publicId: UUID_ME)],
            members: [memberDto(publicId: UUID_ME, nickname: "스모크일")]
        )
        let session = FakeChatSession()
        let repository = RemoteChatRepository(api: api, session: session)

        let first = try #require(try await repository.getMessages(chatRoomId: 5).messages.first)
        #expect(first.isMine)
        #expect(first.senderName == "스모크일")

        // 로그아웃: 캐시를 쓰지 않고, 그 계정의 메시지도 더는 내 것이 아니다.
        session.state.value = .unauthenticated
        api.membersFailure.value = IllegalStateException("401")
        let loggedOut = try #require(try await repository.getMessages(chatRoomId: 5).messages.first)
        #expect(!loggedOut.isMine)
        #expect(loggedOut.senderName == nil, "로그아웃 후에도 이전 계정의 참여자 캐시를 썼다")

        // 다른 계정으로 로그인해도 앞 사람의 캐시가 되살아나면 안 된다.
        session.state.value = .authenticated(userUuid: UUID_OTHER)
        let switched = try #require(try await repository.getMessages(chatRoomId: 5).messages.first)
        #expect(!switched.isMine)
        #expect(switched.senderName == nil)
    }

    @Test("참여자 목록을 그대로 돌려주고 나를 표시한다")
    func membersMarkMe() async throws {
        let api = FakeChatApi(
            members: [
                memberDto(publicId: UUID_ME, nickname: "스모크일"),
                memberDto(publicId: UUID_OTHER, nickname: "스모크이"),
            ]
        )

        let members = try await RemoteChatRepository(api: api, session: FakeChatSession()).getChatRoomMembers(chatRoomId: 5)

        #expect(members.map(\.nickname) == ["스모크일", "스모크이"])
        #expect(members.map(\.isMe) == [true, false])
        #expect(members.map(\.userId) == [nil, nil], "서버가 안 주는 userId 가 채워졌다")
    }

    // 목록을 이미 받아 왔으면 이어지는 메시지 조회가 그 캐시를 그대로 쓴다(중복 호출 금지).
    @Test("참여자를 조회해 두면 다음 메시지 조회가 캐시를 쓴다")
    func membersCacheUsed() async throws {
        let api = FakeChatApi(
            history: [message(id: 1, publicId: UUID_OTHER)],
            members: [memberDto(publicId: UUID_OTHER, nickname: "자동에이")]
        )
        let repository = RemoteChatRepository(api: api, session: FakeChatSession())
        _ = try await repository.getChatRoomMembers(chatRoomId: 5)

        let page = try await repository.getMessagesAfter(chatRoomId: 5, cursor: 0)

        #expect(page.messages.count == 1)
        #expect(page.messages.first?.senderName == "자동에이")
        #expect(api.memberCalls.value == 1)
    }

    @Test("검색은 keyword 와 페이징 파라미터를 그대로 넘긴다")
    func searchPassesParameters() async throws {
        let api = FakeChatApi()

        _ = try await RemoteChatRepository(api: api, session: FakeChatSession())
            .searchMessages(chatRoomId: 5, keyword: "약속", cursor: 42, size: 10)

        #expect(api.searchCall.value == SearchCall(chatRoomId: 5, keyword: "약속", cursor: 42, size: 10))
    }

    @Test("조회 기본값은 커서 없음과 서버 기본 크기 30 이다")
    func defaultCursorAndSize() async throws {
        let api = FakeChatApi()

        _ = try await RemoteChatRepository(api: api, session: FakeChatSession()).getMessages(chatRoomId: 5)

        #expect(api.messagesCursor.value == nil)
        #expect(api.messagesSize.value == 30)
    }

    /// 목록은 membership 만 오므로 방 상세를 합쳐 준다. 상세가 깨진 방은 목록 전체를 죽이지 않고 빠진다.
    @Test("상세 조회에 실패한 방은 목록에서 제외한다")
    func brokenRoomDropped() async throws {
        let api = FakeChatApi(memberships: [1, 2], brokenRoomIds: [2])

        let rooms = try await RemoteChatRepository(api: api, session: FakeChatSession()).getMyChatRooms()

        #expect(rooms.map(\.room.id) == [1])
    }

    /// 음소거는 같은 경로의 POST/DELETE 다 — 불리언 하나가 어느 메서드로 가는지가 계약이다.
    @Test("알림 끄기는 mute, 켜기는 unmute 로 간다")
    func muteRouting() async throws {
        let api = FakeChatApi()
        let repository = RemoteChatRepository(api: api, session: FakeChatSession())

        try await repository.setNotificationMuted(chatRoomId: 5, muted: true)
        try await repository.setNotificationMuted(chatRoomId: 5, muted: false)

        #expect(api.muteCalls.value == [MuteCall(chatRoomId: 5, muted: true), MuteCall(chatRoomId: 5, muted: false)])
    }

    @Test("음소거 실패도 ChatException 으로 좁혀진다")
    func muteFailureNarrowed() async throws {
        let api = FakeChatApi(
            failure: httpException(403, #"{"code":"CHAT_NOT_PARTICIPANT","message":"채팅방 참여자가 아닙니다."}"#)
        )

        let error = try await thrownError(ChatException.self) {
            try await RemoteChatRepository(api: api, session: FakeChatSession()).setNotificationMuted(chatRoomId: 5, muted: true)
        }

        #expect(error.isNotParticipant)
    }

    /// 채팅 실패 본문은 `{code, message}` 이고 code 가 enum 이름이다. 이걸 도메인 예외로 좁혀 두지 않으면
    /// 화면이 HttpException 을 직접 뒤져야 하고, 403 두 종류(참여자 아님/남의 메시지)가 구분되지 않는다.
    @Test("403 CHAT_NOT_PARTICIPANT 는 참여자 아님 예외로 좁혀진다")
    func notParticipantNarrowed() async throws {
        let api = FakeChatApi(
            failure: httpException(403, #"{"code":"CHAT_NOT_PARTICIPANT","message":"채팅방 참여자가 아닙니다."}"#)
        )

        let chat = try await thrownError(ChatException.self) {
            _ = try await RemoteChatRepository(api: api, session: FakeChatSession()).getMessages(chatRoomId: 5)
        }

        #expect(chat.isNotParticipant)
        #expect(!chat.isRoomClosed)
        #expect(chat.serverMessage == "채팅방 참여자가 아닙니다.")
    }

    @Test("409 CHAT_ROOM_CLOSED 는 종료된 방 예외로 좁혀진다")
    func roomClosedNarrowed() async throws {
        let api = FakeChatApi(
            failure: httpException(409, #"{"code":"CHAT_ROOM_CLOSED","message":"종료된 채팅방입니다."}"#)
        )

        let chat = try await thrownError(ChatException.self) {
            _ = try await RemoteChatRepository(api: api, session: FakeChatSession()).sendMessage(chatRoomId: 5, content: "안녕")
        }

        #expect(chat.isRoomClosed)
        #expect(!chat.isNotParticipant)
    }

    /// 스프링이 직접 만드는 404 처럼 본문에 code 가 없을 때도 상태 코드로 최소한의 분기는 서야 한다.
    @Test("code 없는 404 도 방 없음으로 읽힌다")
    func codelessNotFound() async throws {
        let api = FakeChatApi(failure: httpException(404, ""))

        let chat = try await thrownError(ChatException.self) {
            _ = try await RemoteChatRepository(api: api, session: FakeChatSession()).getChatRoom(chatRoomId: 5)
        }

        #expect(chat.code == nil)
        #expect(chat.isRoomNotFound)
    }

    // MARK: - 메시지 신고

    /// 사유는 **대문자 enum 이름**으로 나가야 한다 — 소문자를 보내면 서버가 400
    /// 「요청 본문이 없거나 형식이 잘못되었습니다」로 거절하고(실측) 무엇이 틀렸는지 말해 주지
    /// 않는다. 방 id 가 경로로, 메시지 id 가 본문으로 가는 것도 함께 고정한다(둘을 뒤집으면 403).
    @Test("신고는 방 id 를 경로로 사유를 대문자로 보낸다")
    func reportShape() async throws {
        let api = FakeChatApi()

        try await RemoteChatRepository(api: api, session: FakeChatSession())
            .reportMessage(chatRoomId: 8, chatMessageId: 12, reason: .sexual)

        #expect(api.reportRoomId.value == 8)
        #expect(api.reportBody.value?.chatMessageId == 12)
        #expect(api.reportBody.value?.reason == "SEXUAL")
        #expect(api.reportBody.value?.description == nil, "상세를 안 넘겼는데 본문에 들어갔다")
    }

    /// 공백만 적은 상세는 **없는 것과 같게 접는다.**
    ///
    /// 안 접으면 「기타」 사유에서 서버 `isBlank` 검사에 걸려 400
    /// `CHAT_REPORT_DESCRIPTION_REQUIRED` 다(실측) — 사용자는 **뭔가 적었는데** 「상세 내용을
    /// 입력해야 합니다」를 받는다. 그 밖의 사유에서는 공백을 실어 보낼 이유 자체가 없다.
    @Test("공백만 있는 상세는 없는 것으로 접는다")
    func blankDescriptionFolded() async throws {
        let api = FakeChatApi()

        try await RemoteChatRepository(api: api, session: FakeChatSession())
            .reportMessage(chatRoomId: 8, chatMessageId: 12, reason: .abuse, description: "   \n ")

        #expect(api.reportBody.value != nil)
        #expect(api.reportBody.value?.description == nil)
    }

    /// 적어 둔 상세는 앞뒤 공백만 빼고 그대로 간다 — 서버가 500자까지 받는다.
    @Test("상세를 적었으면 그대로 보낸다")
    func descriptionKept() async throws {
        let api = FakeChatApi()

        try await RemoteChatRepository(api: api, session: FakeChatSession())
            .reportMessage(chatRoomId: 8, chatMessageId: 12, reason: .etc, description: "같은 말을 계속 보내요")

        #expect(api.reportBody.value?.reason == "ETC")
        #expect(api.reportBody.value?.description == "같은 말을 계속 보내요")
    }

    /// 신고 실패도 `ChatException` 으로 좁혀 올라와야 한다 — 화면이 `isAlreadyReported` 로 분기해
    /// 「이미 신고한 메시지예요」를 띄우는 근거가 이 변환이다. `chatCall` 을 빼먹으면 날것의
    /// `HttpException` 이 올라와 그 분기가 **전부 else 로 떨어진다**(원문 메시지만 보인다).
    @Test("중복 신고 409 는 이미 신고함으로 읽힌다")
    func duplicateReport() async throws {
        let api = FakeChatApi(
            failure: httpException(409, #"{"code":"CHAT_ALREADY_REPORTED","message":"이미 신고한 메시지입니다."}"#)
        )

        let chat = try await thrownError(ChatException.self) {
            try await RemoteChatRepository(api: api, session: FakeChatSession())
                .reportMessage(chatRoomId: 8, chatMessageId: 12, reason: .abuse)
        }

        #expect(chat.isAlreadyReported)
        // 종료된 방(409 CHAT_ROOM_CLOSED)과 섞이지 않는다 — 둘 다 409 라 상태 코드만으로는 못 가린다.
        #expect(!chat.isRoomClosed)
    }
}

/// 원본에 대응 테스트가 없는 iOS 쪽 경계. 목록의 동시 조회, 소켓 신호 변환, 취소 전파는 원본에서
/// 코루틴이 해 주던 일을 직접 옮긴 자리다.
@Suite(.timeLimit(.minutes(1)))
struct RemoteChatRepositoryBoundaryTest {

    /// 동시에 돌려도 서버가 준 순서를 지킨다(원본 `awaitAll`). 먼저 끝난 방이 앞으로 오면 안 된다.
    @Test("목록은 상세 조회가 끝난 순서가 아니라 서버 순서다")
    func roomsKeepServerOrder() async throws {
        let api = FakeChatApi(memberships: [3, 1, 2], roomDelays: [3: .milliseconds(60), 1: .milliseconds(30)])

        let rooms = try await RemoteChatRepository(api: api, session: FakeChatSession()).getMyChatRooms()

        #expect(rooms.map(\.room.id) == [3, 1, 2])
    }

    @Test("목록에 방 정보와 참여자가 함께 오면 방별 추가 조회를 하지 않는다")
    func roomsWithInlineInfoAvoidExtraCalls() async throws {
        let api = FakeChatApi(
            history: [message(id: 1, publicId: UUID_OTHER)],
            myRooms: [
                ChatRoomUserResponse(
                    chatRoomId: 5,
                    departure: "서울시청",
                    destination: "강남역",
                    status: "ACTIVE",
                    members: [memberDto(publicId: UUID_OTHER, nickname: "자동에이")]
                ),
            ]
        )
        let repository = RemoteChatRepository(api: api, session: FakeChatSession())

        let rooms = try await repository.getMyChatRooms()
        let page = try await repository.getMessagesAfter(chatRoomId: 5, cursor: 0)

        #expect(rooms.map(\.room.departure) == ["서울시청"])
        #expect(api.roomCalls.value == 0)
        #expect(api.memberCalls.value == 0)
        #expect(page.messages.first?.senderName == "자동에이")
    }

    /// 원본의 `runCatching` 은 여기서 취소를 null 로 접지만 바깥 `coroutineScope` 가 다시 던진다.
    /// 태스크 그룹에는 그 장치가 없어 자식이 직접 던져야 빈 목록으로 끝나지 않는다.
    @Test("방 상세 조회 중 취소는 방 제외가 아니라 취소다")
    func roomCancellationPropagates() async {
        let api = FakeChatApi(memberships: [1], roomFailure: CancellationError())

        await #expect(throws: CancellationError.self) {
            _ = try await RemoteChatRepository(api: api, session: FakeChatSession()).getMyChatRooms()
        }
    }

    @Test("목록 조회 태스크가 취소되면 결과 대신 취소가 올라온다")
    func roomsTaskCancellation() async {
        let api = FakeChatApi(myRooms: [])
        let repository = RemoteChatRepository(api: api, session: FakeChatSession())

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await repository.getMyChatRooms()
        }

        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test("참여자 조회 중 취소는 조용히 삼키지 않고 ChatException 으로도 바꾸지 않는다")
    func membersCancellationPropagates() async {
        let api = FakeChatApi(membersFailure: CancellationError())

        await #expect(throws: CancellationError.self) {
            _ = try await RemoteChatRepository(api: api, session: FakeChatSession()).getMessages(chatRoomId: 5)
        }
    }

    @Test("소켓이 없으면 실시간 흐름은 바로 끝나고 소켓 전송은 거짓이다")
    func noSocket() async throws {
        let repository = RemoteChatRepository(api: FakeChatApi(), session: FakeChatSession())

        var events: [ChatRealtimeEvent] = []
        for await event in repository.observeRoom(chatRoomId: 5) {
            events.append(event)
        }

        #expect(events.isEmpty)
        #expect(try await repository.trySendMessage(chatRoomId: 5, content: "안녕") == false)
        #expect(try await repository.tryMarkAsRead(chatRoomId: 5, readMessageId: 1) == false)
    }

    @Test("소켓 메시지도 조회와 같은 경로로 이름과 내 메시지를 푼다")
    func socketMessageResolvesIdentity() async throws {
        let client = FakeWebSocketClient()
        let socket = ChatSocket(
            baseUrl: "https://api.example.com/",
            webSocketClient: client,
            tokens: FakeTokenHolder(accessToken: "tok", refreshToken: "refresh"),
            sleep: RecordingSleep().sleep,
            report: { _, _ in }
        )
        let api = FakeChatApi(members: [memberDto(publicId: UUID_OTHER, nickname: "늦게탄사람")])
        let repository = RemoteChatRepository(api: api, session: FakeChatSession(), socket: socket)

        var iterator = repository.observeRoom(chatRoomId: 5).makeAsyncIterator()
        #expect(await iterator.next() == .connected)

        let connection = try #require(client.connections.first)
        let isRoomSubscription: @Sendable (StompFrame) -> Bool = {
            $0.command == .subscribe && $0.header("destination") == "/sub/chat-rooms/5"
        }
        _ = await waitUntil { connection.sentFrames.contains(where: isRoomSubscription) }
        let id = try #require(connection.sentFrames.first(where: isRoomSubscription)?.header("id"))
        let body = #"{"id":11,"chatRoomId":5,"publicId":"\#(UUID_OTHER)","content":"안녕","type":"TEXT"}"#
        connection.push("MESSAGE\nsubscription:\(id)\nmessage-id:m\ndestination:/sub/chat-rooms/5\n\n\(body)\0")

        guard case .message(let received)? = await iterator.next() else {
            Issue.record("메시지가 아니다")
            return
        }
        #expect(received.id == 11)
        #expect(!received.isMine)
        // 사전에 없는 발신자라 참여자 목록을 한 번 읽어 이름을 채웠다.
        #expect(received.senderName == "늦게탄사람")
        #expect(api.memberCalls.value == 1)
        // 살아 있는 세션에 써 넣었으니 참이다 — 저장 결과는 구독으로 돌아온다.
        #expect(try await repository.trySendMessage(chatRoomId: 5, content: "답장"))
        #expect(try await repository.tryMarkAsRead(chatRoomId: 5, readMessageId: 11))
        #expect(try await repository.trySendMessage(chatRoomId: 6, content: "다른 방") == false)
    }
}

private func httpException(_ code: Int, _ body: String) -> HttpException {
    HttpException(Response<Void>.error(code, body))
}

private func memberDto(
    publicId: String,
    nickname: String,
    active: Bool = true
) -> ChatMemberResponse {
    ChatMemberResponse(
        publicId: publicId,
        nickname: nickname,
        imageUrl: nil,
        active: active
    )
}

// 배포 서버 실측 shape: userId 없이 publicId 로 발신자를 밝힌다.
private func message(
    id: Int64,
    publicId: String,
    senderNickname: String? = nil
) -> ChatMessageResponse {
    ChatMessageResponse(
        id: id,
        chatRoomId: 5,
        publicId: publicId,
        content: "본문 \(id)",
        type: "TEXT",
        createdAt: "2026-09-07T09:0\(id):00Z",
        deleted: false,
        senderNickname: senderNickname
    )
}

private final class FakeChatSession: UserSession {
    let state: MutableStateFlow<AuthState>
    var authState: StateFlow<AuthState> { state }

    init(initial: AuthState = .authenticated(userUuid: UUID_ME)) {
        state = MutableStateFlow(initial)
    }
}

private struct SearchCall: Equatable, Sendable {
    let chatRoomId: Int64
    let keyword: String
    let cursor: Int64?
    let size: Int
}

private struct MuteCall: Equatable, Sendable {
    let chatRoomId: Int64
    let muted: Bool
}

/// 헤더 검증은 여기서 하지 않는다 — `ChatApi` 프로토콜에 헤더 인자가 되살아나는 건
/// `AuthenticatedPathContractTest` 가 잡는다.
/// 이 페이크는 저장소가 **무엇을 넘기는지**만 기록한다.
private final class FakeChatApi: ChatApi {
    private let history: [ChatMessageResponse]
    private let memberships: [Int64]
    private let brokenRoomIds: Set<Int64>
    private let failure: (any Error)?
    private let myRooms: [ChatRoomUserResponse]?
    private let roomFailure: (any Error)?
    private let roomDelays: [Int64: Duration]

    // 참여자 목록은 테스트 도중 바뀔 수 있다(중간 합류자·로그아웃). 칸을 열어 두고 갈아 끼운다.
    let members: Locked<[ChatMemberResponse]>
    let membersFailure: Locked<(any Error)?>

    // 재조회가 정말 "한 번만" 일어나는지 세려면 호출 횟수가 필요하다.
    let memberCalls = Locked(0)
    let roomCalls = Locked(0)
    let afterMessages = Locked<[ChatMessageResponse]?>(nil)

    let sentRoomId = Locked<Int64?>(nil)
    let sentBody = Locked<SendMessageRequestDto?>(nil)
    let messagesCursor = Locked<Int64?>(nil)
    let messagesSize = Locked<Int?>(nil)
    let searchCall = Locked<SearchCall?>(nil)
    let muteCalls = Locked<[MuteCall]>([])
    let reportRoomId = Locked<Int64?>(nil)
    let reportBody = Locked<ChatReportRequestDto?>(nil)

    init(
        history: [ChatMessageResponse] = [],
        memberships: [Int64] = [],
        brokenRoomIds: Set<Int64> = [],
        failure: (any Error)? = nil,
        members: [ChatMemberResponse] = [],
        membersFailure: (any Error)? = nil,
        myRooms: [ChatRoomUserResponse]? = nil,
        roomFailure: (any Error)? = nil,
        roomDelays: [Int64: Duration] = [:]
    ) {
        self.history = history
        self.memberships = memberships
        self.brokenRoomIds = brokenRoomIds
        self.failure = failure
        self.members = Locked(members)
        self.membersFailure = Locked(membersFailure)
        self.myRooms = myRooms
        self.roomFailure = roomFailure
        self.roomDelays = roomDelays
    }

    private func failIfNeeded() throws {
        if let failure { throw failure }
    }

    func getRoom(chatRoomId: Int64) async throws -> ChatRoomResponse {
        roomCalls.update { $0 += 1 }
        try failIfNeeded()
        if let roomFailure { throw roomFailure }
        if let delay = roomDelays[chatRoomId] { try await Task.sleep(for: delay) }
        if brokenRoomIds.contains(chatRoomId) { throw IllegalStateException("방 상세 조회 실패") }
        return ChatRoomResponse(
            id: chatRoomId,
            partyId: 100 + chatRoomId,
            departure: "서울시청",
            destination: "강남역",
            createdAt: "2026-09-07T08:00:00Z",
            status: "ACTIVE"
        )
    }

    func getMyRooms() async throws -> [ChatRoomUserResponse] {
        try failIfNeeded()
        return myRooms ?? memberships.map { ChatRoomUserResponse(chatRoomId: $0, lastReadMessageId: nil) }
    }

    func joinRoom(chatRoomId: Int64) async throws { try failIfNeeded() }

    func leaveRoom(chatRoomId: Int64) async throws { try failIfNeeded() }

    func getMembers(chatRoomId: Int64) async throws -> [ChatMemberResponse] {
        memberCalls.update { $0 += 1 }
        if let failure = membersFailure.value { throw failure }
        return members.value
    }

    func readRoom(chatRoomId: Int64, readMessageId: Int64) async throws { try failIfNeeded() }

    func muteNotification(chatRoomId: Int64) async throws {
        try failIfNeeded()
        muteCalls.append(MuteCall(chatRoomId: chatRoomId, muted: true))
    }

    func unmuteNotification(chatRoomId: Int64) async throws {
        try failIfNeeded()
        muteCalls.append(MuteCall(chatRoomId: chatRoomId, muted: false))
    }

    func getMessages(chatRoomId: Int64, cursor: Int64?, size: Int) async throws -> ChatMessageSliceResponse {
        try failIfNeeded()
        messagesCursor.value = cursor
        messagesSize.value = size
        return ChatMessageSliceResponse(messages: history, nextCursor: nil, hasNext: false)
    }

    func getMessagesAfter(chatRoomId: Int64, cursor: Int64, size: Int) async throws -> ChatMessageSliceResponse {
        try failIfNeeded()
        return ChatMessageSliceResponse(messages: afterMessages.value ?? history, nextCursor: nil, hasNext: false)
    }

    // 서버는 전송 응답에도 발신자 publicId 를 담아 준다 — 조회와 같은 shape 이다.
    func sendMessage(chatRoomId: Int64, request: SendMessageRequestDto) async throws -> ChatMessageResponse {
        try failIfNeeded()
        sentRoomId.value = chatRoomId
        sentBody.value = request
        var sent = message(id: 99, publicId: UUID_ME)
        sent.content = request.content
        return sent
    }

    func deleteMessage(chatRoomId: Int64, messageId: Int64) async throws { try failIfNeeded() }

    func searchMessages(
        chatRoomId: Int64,
        keyword: String,
        cursor: Int64?,
        size: Int
    ) async throws -> ChatMessageSliceResponse {
        try failIfNeeded()
        searchCall.value = SearchCall(chatRoomId: chatRoomId, keyword: keyword, cursor: cursor, size: size)
        return ChatMessageSliceResponse(messages: history, nextCursor: nil, hasNext: false)
    }

    func reportMessage(chatRoomId: Int64, request: ChatReportRequestDto) async throws {
        try failIfNeeded()
        reportRoomId.value = chatRoomId
        reportBody.value = request
    }
}
