import MoyeotaDomain

// 서버가 enum 을 새로 추가해도 앱이 죽지 않도록 알 수 없는 값은 기본값으로 흡수한다.
public func chatRoomStatusOf(raw: String) -> ChatRoomStatus {
    switch raw {
    case "ACTIVE": return .active
    case "CLOSED": return .closed
    case "ARCHIVED": return .archived
    default: return .active
    }
}

public func chatMessageTypeOf(raw: String) -> ChatMessageType {
    switch raw {
    case "LOCATION": return .location
    default: return .text
    }
}

extension ChatRoomResponse {
    public func toChatRoom() -> ChatRoom {
        ChatRoom(
            id: id,
            partyId: partyId,
            departure: departure,
            destination: destination,
            createdAt: createdAt ?? "",
            status: chatRoomStatusOf(raw: status)
        )
    }
}

extension ChatRoomUserResponse {
    /// - Parameter myUuid: 세션 공개 UUID. 마지막 메시지가 내 것인지(`isMine`) 가리는 데만 쓴다 —
    ///   빈 값끼리의 비교로 남의 메시지가 내 것이 되지 않게 빈 문자열은 "없음"으로 접는다.
    public func toMembership(myUuid: String? = nil) -> ChatRoomMembership {
        ChatRoomMembership(
            chatRoomId: chatRoomId,
            lastReadMessageId: lastReadMessageId,
            notificationMuted: notificationMuted,
            joinedAt: joinedAt ?? "",
            lastMessage: lastMessage?.toLastMessage(myUuid: myUuid),
            // 음수는 서버 결함이다 — 배지에 「-1」을 그리느니 0 으로 접는다. Int 범위를 넘을 일은 없다.
            unreadCount: unreadCount.map { Int(max($0, 0)) },
            members: (members ?? []).map { $0.toChatMember(myUuid: myUuid) }
        )
    }

    /// 목록 항목에 방 정보가 함께 왔으면 `ChatRoom` 으로 옮긴다. 안 왔으면(구버전 서버) null —
    /// 호출부가 방 상세를 한 번 더 읽는다.
    ///
    /// 목록 응답에는 `partyId` 가 없어 `UNKNOWN_PARTY_ID` 를 채운다 — 「모른다」는 표시이고
    /// **비교에 쓰면 안 되는 값**이다(그 주석). 여기서는 목록 표시에 필요한 것만 채운다.
    public func toChatRoomOrNull() -> ChatRoom? {
        guard let departure, let destination else { return nil }
        return ChatRoom(
            id: chatRoomId,
            partyId: UNKNOWN_PARTY_ID,
            departure: departure,
            destination: destination,
            createdAt: joinedAt ?? "",
            status: chatRoomStatusOf(raw: status ?? "")
        )
    }
}

extension ChatLastMessageResponse {
    public func toLastMessage(myUuid: String?) -> ChatLastMessage {
        let sender = senderPublicId?.takeIfNotBlank()
        return ChatLastMessage(
            id: id,
            senderPublicId: sender,
            content: content,
            type: chatMessageTypeOf(raw: type),
            createdAt: createdAt ?? "",
            isMine: sender != nil && sender == myUuid
        )
    }
}

// "이 메시지가 누구 것인가"를 판정할 때 쓰는 근거.
//
// 예전에는 근거가 셋이었다(메시지 publicId / 참여자 사전 / 내가 보낸 메시지에서 학습한 내부 PK).
// 서버가 메시지에 발신자 publicId 를 실어 주면서 **하나로 줄었다** — 세션 uuid 와의 문자열 비교.
// 학습 폴백은 근거가 사라져 삭제했다(서버가 userId 를 더 이상 주지 않는다).
//
// myUuid: 세션의 공개 UUID. 미로그인/복원 전이면 null 이고, 그때는 어떤 메시지도 내 것이 아니다.
// members: 방 참여자 목록(publicId → 참여자). 이제 신원 판정에는 쓰이지 않고 **닉네임 사전**으로만 쓴다.
public struct ChatIdentity: Equatable, Sendable {
    public var myUuid: String?
    public var members: [String: ChatMember]

    public init(myUuid: String?, members: [String: ChatMember] = [:]) {
        self.myUuid = myUuid
        self.members = members
    }
}

extension ChatMemberResponse {
    // publicId 가 빈 문자열인 참여자는 서버 응답이 깨진 경우다 — isMe 를 참으로 만들지 않는다
    // (myUuid 도 null 이면 "빈 값끼리 같다"로 남의 메시지가 내 것이 될 수 있다).
    //
    // nickname 이 null 로 오는 경우(서버 `users.nickname` 에 NOT NULL 이 없다 —
    // `ChatMemberResponse.nickname` 주석)는 **빈 문자열**로 떨어뜨린다. 필드가 아예 없던 구버전 응답과
    // 같은 자리이고, 읽는 쪽이 이미 "빈 닉네임 = 이름을 모른다"로 다룬다 —
    // 목록·헤더 제목은 「동승자」로 떨어지고(`ChatRoute.chatRoomPeerTitle`), 말풍선 이름도 같다
    // (`toChatMessage` 의 빈 값 검사).
    //
    // `WithdrawnMemberNames` 를 쓰지 않는다: 저쪽은 **유저 요약 자체가 없거나 탈퇴한** 멤버의 자리값인데
    // (`PartyMappers.toUser` 가 그 경우에 NO_SUMMARY 를 채운다) 여기서 null 로 오는 건 publicId 가 멀쩡한
    // **「닉네임 미설정」**이다. 요약 없는 멤버는 채팅 응답까지 오지 않는다(서버가 걸러낸다).
    // 멀쩡히 참여 중인 사람을 「탈퇴한 회원」으로 부르면 그게 더 틀린 말이다.
    public func toChatMember(myUuid: String?) -> ChatMember {
        ChatMember(
            userId: userId,
            publicId: publicId,
            nickname: nickname ?? "",
            imageUrl: imageUrl,
            active: active,
            isMe: !publicId.isBlank && publicId == myUuid
        )
    }
}

extension ChatMessageResponse {
    /// 발신자 공개 UUID. 서버 필드명이 흔들려서(`senderPublicId` 요청 → `publicId` 구현) 둘 다 읽는다.
    /// 빈 문자열은 "없음"으로 접는다 — 빈 값끼리의 비교가 남의 메시지를 내 것으로 만들면 안 된다.
    private var effectiveSenderPublicId: String? {
        senderPublicId?.takeIfNotBlank() ?? publicId?.takeIfNotBlank()
    }

    // isMine 은 발신자 publicId 와 세션 uuid 의 비교 하나로 끝난다. 둘 다 서버가 준 공개 신원이라
    // 계정 전환 직후에도 어긋나지 않는다(캐시된 ChatMember.isMe 를 믿지 않는 이유이기도 하다).
    //
    // senderName 은 참여자 사전(publicId → 닉네임)이 우선이고, 서버가 senderNickname 을 실어 주면
    // 그걸 폴백으로 쓴다. 방을 나간 참여자(active=false)도 사전에 남아 있어 이름이 유지된다.
    public func toChatMessage(identity: ChatIdentity) -> ChatMessage {
        let senderPublicId = effectiveSenderPublicId
        let member = senderPublicId.flatMap { identity.members[$0] }
        return ChatMessage(
            id: id,
            chatRoomId: chatRoomId,
            senderPublicId: senderPublicId,
            content: content,
            type: chatMessageTypeOf(raw: type),
            createdAt: createdAt ?? "",
            deleted: deleted,
            isMine: senderPublicId != nil && senderPublicId == identity.myUuid,
            senderName: member?.nickname.takeIfNotBlank() ?? senderNickname?.takeIfNotBlank()
        )
    }
}

extension ChatMessageSliceResponse {
    public func toPage(identity: ChatIdentity) -> ChatMessagePage {
        ChatMessagePage(
            messages: messages.map { $0.toChatMessage(identity: identity) },
            nextCursor: nextCursor,
            hasNext: hasNext
        )
    }
}

extension Error {
    /// 전송 계층 예외를 `ChatException` 으로 좁힌다. presentation 이 HTTP 를 알 필요가 없게 하는 경계다.
    ///
    /// 채팅은 `ChatExceptionHandler` 가 `ErrorResponse(code, message)` 를 내려주는데 code 가
    /// **enum 이름 그대로**다(`CHAT_NOT_PARTICIPANT` 등) — 인증 쪽 `USER102` 같은 번호 체계와 다르므로
    /// `toAuthException` 의 매핑을 재사용할 수 없다. 본문 shape 만 같아 `ApiErrorDto` 를 공유한다.
    ///
    /// 상태 코드만으로는 갈리지 않는 조합이 있어 code 를 우선 본다 — 403 은 참여자 아님과
    /// 남의 메시지 삭제 둘 다, 409 는 종료된 방·중복 참여·이미 삭제된 메시지가 겹친다.
    func toChatException() -> ChatException {
        if let failure = self as? ChatException { return failure }

        if let http = self as? HttpException {
            let body = http.readApiError()
            return ChatException(
                code: body?.code,
                serverMessage: body?.message,
                httpStatus: http.code(),
                cause: http
            )
        }

        // 응답 자체를 못 받은 경우(연결 거부·타임아웃·DNS). 사용자에게는 재시도를 안내한다.
        // URLError(.cancelled) 는 취소이지 전송 실패가 아니다 — 그 도메인이 같아 먼저 거른다.
        if !isCancellation(throwable: self), isIOFailure(throwable: self) {
            return ChatException(code: nil, serverMessage: nil, isNetwork: true, cause: self)
        }

        return ChatException(code: nil, serverMessage: nil, cause: self)
    }
}

/// 채팅 호출을 감싸 실패를 `ChatException` 으로 통일한다.
/// 취소는 그대로 통과시킨다 — 취소를 에러로 바꾸면 화면 이탈이 에러 토스트로 보인다.
func chatCall<T>(
    isolation: isolated (any Actor)? = #isolation,
    _ block: () async throws -> T
) async throws -> T {
    do {
        return try await block()
    } catch let error where isCancellation(throwable: error) {
        throw error
    } catch {
        throw error.toChatException()
    }
}

/// 목록 응답으로 만든 방의 `ChatRoom.partyId` 자리값 — **「모른다」는 뜻이다.**
///
/// `GET /chat-rooms/me` 는 partyId 를 주지 않는데 `ChatRoom.partyId` 는 non-null `Int64` 라 무언가는
/// 채워야 한다. 그래서 「없음」을 0 으로 적는다.
///
/// **이 값으로 아무것도 비교하지 말 것.** 0 인지 보는 것(= 모르는지 보는 것) 말고는 쓸 데가 없다.
/// 예전에 「지금 진행 중인 방인가」를 `partyId.toString() == activePartyId` 로 가리던 코드가 있었는데,
/// 목록에서 연 방은 여기서 0 을 받으므로 그 판정이 **언제나 거짓**이었다 — 진행 중인 방인데도 「매칭
/// 화면으로 →」가 안 뜨고 되돌릴 수 없는 「나가기」가 노출됐다(실기 QA). 지금은 믿을 수 있는 값인
/// **채팅방 id** 로 가린다(`ChatRoute.isActiveParty`).
///
/// partyId 가 실제로 필요한 경로(`ActivePartyRepository`)는 여전히 **방 상세**에서 받은 값만 쓴다.
let UNKNOWN_PARTY_ID: Int64 = 0
