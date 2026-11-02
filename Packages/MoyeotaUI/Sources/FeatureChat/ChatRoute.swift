import Foundation
import MoyeotaDesignSystem
import MoyeotaDomain
import PresentationCore
import SwiftUI

/// 폴링 주기 — **소켓이 안 붙어 있을 때만** 돈다(미로그인·업그레이드 차단·재연결 중).
///
/// 소켓이 붙어 있으면 폴링하지 않는다. 서버가 지난 메시지를 다시 주지 않아 생기는 구멍(재연결 사이)은
/// 연결될 때마다 한 번 `after` 조회로 메운다(`ChatRealtimeEvent.connected`) — heartbeat 는 끊김을
/// 알려 줄 뿐 그 구멍을 메우지 못한다.
private let POLL_INTERVAL_MS = 3_000

/// 소켓으로 보낸 메시지가 **되돌아오기를** 기다리는 시간. 서버는 전송에 답하지 않고 저장된 메시지를
/// 구독으로 밀어 주므로, 이 시간이 지나도록 오지 않으면 실패로 본다.
/// 확인은 거의 즉시(수십 ms) 오므로 넉넉한 값이다. 놓쳤으면 다음 재연결의 공백 조회나 재진입이 실제 결과로 바로잡는다.
private let PENDING_TIMEOUT_MS = 8_000

/// 서버 한도(`SendMessageRequest @Size(max = 1000)`)와 같은 값.
///
/// `internal` 인 이유: 입력창(`ChatScreen`)이 **같은 숫자**를 봐야 한다. 예전엔 화면이 500자로 하드
/// 컷해서 이 1000자 검사와 그 안내가 영영 닿지 않는 죽은 코드였다 — 사용자는 500자에서 조용히
/// 막히고 왜 막혔는지 알 수 없었다.
let MAX_CONTENT_LENGTH = 1_000

/// 재연결 공백을 메울 때 한 번에 이어 읽는 **최대 페이지 수**(한 페이지 `ChatRepositoryDefaults.DEFAULT_PAGE_SIZE`=30건).
///
/// `hasNext` 가 거짓이 될 때까지 커서를 밀지만, 상한 없이 돌면 서버가 `hasNext=true` 를 잘못 내는 순간
/// 끝나지 않는 루프가 된다(여기서 멈추면 대화 화면이 통째로 멈춘다). 10페이지 = 300건으로 둔 근거:
/// - 이 함수가 메우는 건 **끊긴 몇 분 사이**의 공백이다. 300건이 비었다면 그건 공백이 아니라 「오랜만에
///   다시 열었다」에 가깝고, 그 경우는 첫 페이지 조회(최신 30건)가 더 싸고 적절하다.
/// - 상한에 닿아도 **잃지 않는다**: 읽은 만큼 커서가 전진해 있으므로 다음 재연결·다음 폴링 주기가
///   이어서 메운다.
private let MAX_GAP_FILL_PAGES = 10

/// 검색어를 치는 동안 서버를 두드리지 않고 기다리는 시간. 한 글자마다 요청하면 「부산역」 한 단어에
/// 세 번 나간다. 이 시간 안에 더 안 치면 그때 한 번 묻는다.
private let SEARCH_DEBOUNCE_MS = 350

/// 서버 규칙(`ChatMessageService.MIN_KEYWORD_LENGTH`) — 미만이면 400 CHAT_INVALID_KEYWORD 라 여기서 먼저 막는다
let SEARCH_MIN_LENGTH = 2

/// 아직 확인이 오지 않은 내 말풍선에 붙이는 표기
private let PENDING_LABEL = "보내는 중"
private let PENDING_FAILED_LABEL = "전송 실패"

// 발신자 닉네임이 없을 때 상대 말풍선에 붙이는 표기.
private let PEER_FALLBACK_NAME = "동승자"

/// 목록 한 줄. 서버 `GET /chat-rooms/me` 가 주지 않는 것(참여자)을 방별로 덧붙인 형태다.
///
/// - `peerTitle`: 나를 뺀 참여자 닉네임으로 지은 제목. **참여자 조회에 실패하면 nil** —
///   그때 화면은 예전처럼 「출발지 → 도착지」를 제목으로 쓴다(방 한 칸이 통째로 깨지지 않게).
/// - `peerImageUrl`: `peerTitle` 이 **맨 앞에 부르는 사람**의 프로필 사진(`chatRoomPeerImageUrl`).
///   제목과 **같은 멤버 목록**에서 뽑아 여기 실어 보낸다 — 행이 `membership.members` 를 보고 따로
///   고르면, 참여자를 방별로 따로 조회하는 구버전 서버 경로에서 제목은 이름인데 얼굴만 비게 된다.
public struct ChatRoomListItem: Equatable, Sendable {
    public var room: MyChatRoom
    public var peerTitle: String?
    public var peerImageUrl: String?

    public init(room: MyChatRoom, peerTitle: String?, peerImageUrl: String? = nil) {
        self.room = room
        self.peerTitle = peerTitle
        self.peerImageUrl = peerImageUrl
    }
}

/// 채팅방 표시 이름 — **나를 뺀 참여자 닉네임**.
///
/// 서버는 방에 이름을 붙여 주지 않아 앱이 짓는다. 예전 이름이었던 「출발지 → 도착지」는
/// 역지오코딩된 전체 주소가 그대로 들어와("부산광역시 부산진구 중앙대로 730 서면역 → …")
/// 목록에서 어느 방인지 가려내는 데 쓸 수가 없었다 — 사람 이름이 그 일을 한다.
/// 경로는 부제로 내려간다(사라지지 않는다).
///
/// 방을 나간 사람(active=false)은 제외하되, 그래서 아무도 안 남으면 **나간 사람이라도 쓴다** —
/// 대화 상대가 분명히 있었던 방을 「동승자 없음」으로 부르는 것보다 낫다.
func chatRoomPeerTitle(members: [ChatMember]) -> String {
    let names = chatRoomPeerMembers(members: members).map { $0.nickname.isBlank ? PEER_FALLBACK_NAME : $0.nickname }
    if names.isEmpty {
        return "동승자 없음"
    }
    if names.count <= 2 {
        return names.joined(separator: " · ")
    }
    // 셋 이상은 다 적으면 한 줄을 넘긴다 — 첫 사람 + 나머지 수
    return "\(names[0]) 외 \(names.count - 1)명"
}

/// 제목이 부르는 참여자 — **이름과 얼굴이 함께 쓰는 유일한 출처**다. 순서는 서버가 준 순서 그대로다.
///
/// `chatRoomPeerTitle` 과 `chatRoomPeerImageUrl` 이 각자 멤버를 고르면 한쪽에만 규칙이 빠지는 순간
/// 「A 이름 + B 얼굴」이 된다(나간 사람 제외가 대표적이다) — 고르는 일을 이 한 곳에만 둔다.
func chatRoomPeerMembers(members: [ChatMember]) -> [ChatMember] {
    let peers = members.filter { !$0.isMe }
    let active = peers.filter(\.active)
    return active.isEmpty ? peers : active
}

/// 목록 행 아바타에 그릴 사진 — `chatRoomPeerTitle` 이 **맨 앞에 적는 사람**의 것.
///
/// 여럿인 방도 얼굴 자리는 하나뿐이라 제목의 첫 사람으로 맞춘다(「스모크일 외 2명」이면 스모크일).
/// 사진을 고른 적 없는 사람에게도 서버는 기본 이미지 URL 을 주므로(백엔드 소스 기준) 여기서 nil 이
/// 되는 건 참여자를 못 받은 방과 빈 문자열 응답뿐이고, 그때 아바타는 회색 원으로 떨어진다.
func chatRoomPeerImageUrl(members: [ChatMember]) -> String? {
    guard let url = chatRoomPeerMembers(members: members).first?.imageUrl, !url.isBlank else { return nil }
    return url
}

/// 말풍선용 `publicId → 프로필 사진` 사전.
///
/// 메시지에는 발신자 publicId 만 실려 오고 사진은 참여자 응답에만 있다 — 이 사전이 없으면 상대
/// 말풍선 아바타는 영영 회색 원이다(닉네임을 잇는 길과 같은 구조다).
///
/// 방을 나간 사람(active=false)도 **담는다** — 남긴 메시지의 얼굴이 사라지면 대화가 누구와 한
/// 것인지 흐려진다(`chatRoomPeerTitle` 이 이름을 남기는 것과 같은 이유). 내 사진까지 담기지만
/// 내 말풍선에는 아바타 자리가 없어 쓰이지 않는다 — 거르는 조건을 하나 더 두지 않는다.
/// 서버는 사람당 한 줄만 주므로 같은 publicId 가 겹치지 않는다.
func chatMemberImageUrls(members: [ChatMember]) -> [String: String] {
    var urls: [String: String] = [:]
    for member in members {
        if let url = member.imageUrl, !url.isBlank {
            urls[member.publicId] = url
        }
    }
    return urls
}

/// 목록 정렬 키(**내림차순** = 최근 방이 위) — **마지막 활동 시각**(epoch ms).
///
/// 마지막 메시지가 있으면 그 시각, 없으면(방금 열린 방) 방 개설 시각이다. 카카오톡식 「최근에 대화한 방」
/// 정렬이며, 메시지가 없는 새 방은 개설 시각으로 자연스럽게 끼어든다. 두 시각 다 파싱이 안 되는
/// 깨진 응답은 방 id 로 떨어진다(epoch 와 자릿수가 달라 맨 아래로 가지만 목록이 죽진 않는다).
func chatRoomSortKey(item: MyChatRoom) -> Int64 {
    let lastAt = item.membership.lastMessage?.createdAt
    let stamp = (lastAt?.isBlank == false ? lastAt : nil) ?? item.room.createdAt
    return stamp.toEpochMillisOrNull() ?? item.room.id
}

/// Kotlin `sortedByDescending` 자리 — 키가 같으면 원래 순서를 지킨다. 표준 `sorted` 는 안정 정렬을 약속하지 않는다.
func sortedByDescendingSortKey(_ rooms: [MyChatRoom]) -> [MyChatRoom] {
    rooms.enumerated()
        .map { (offset: $0.offset, room: $0.element, key: chatRoomSortKey(item: $0.element)) }
        .sorted { $0.key != $1.key ? $0.key > $1.key : $0.offset < $1.offset }
        .map(\.room)
}

@MainActor
@Observable
final class ChatListViewModel {

    enum UiState: Equatable, Sendable {
        case loading
        case success(rooms: [ChatRoomListItem])
        case error(message: String)
    }

    private(set) var uiState: UiState = .loading

    @ObservationIgnored private let repository: any ChatRepository
    @ObservationIgnored private let scope = ViewModelScope()

    init(repository: any ChatRepository) {
        self.repository = repository
    }

    func refresh() {
        uiState = .loading
        let repository = self.repository
        scope.launch { [weak self] in
            do {
                let rooms = try await ChatListViewModel.loadRooms(repository: repository)
                self?.uiState = .success(rooms: rooms)
            } catch {
                guard let failure = chatFailureOnLiveTask(error: error) else { return }
                self?.uiState = .error(message: failure.toChatMessage(fallback: "채팅방 목록을 불러오지 못했어요"))
            }
        }
    }

    /// 목록 + 방마다 참여자 1회. **N+1 이지만 병렬로 돈다** — 방은 사람당 많아야 몇 개고,
    /// 순차로 돌면 방 수만큼 왕복이 쌓여 목록이 눈에 띄게 늦게 뜬다.
    ///
    /// 참여자 조회 실패는 **그 방만** nil 로 떨어뜨린다(목록 전체를 에러로 만들지 않는다).
    ///
    /// 뷰모델을 잡지 않으려고 `static` 이다(`ChatRoomViewModel` 의 「대기 구간」 주석).
    private static func loadRooms(repository: any ChatRepository) async throws -> [ChatRoomListItem] {
        let rooms = sortedByDescendingSortKey(try await repository.getMyChatRooms())
        // 목록 응답에 참여자가 함께 오면(서버 2026-09-14) **추가 조회 없이** 제목을 짓는다.
        // 다 채워져 있으면 화면 하나에 요청 1회로 끝난다 — 예전엔 1+2N 회였다.
        if rooms.allSatisfy({ !$0.membership.members.isEmpty }) {
            return rooms.map {
                ChatRoomListItem(
                    room: $0,
                    peerTitle: chatRoomPeerTitle(members: $0.membership.members),
                    peerImageUrl: chatRoomPeerImageUrl(members: $0.membership.members)
                )
            }
        }
        // 구버전 서버 폴백 — 방마다 참여자를 따로 읽는다. 순차로 돌면 방 수만큼 왕복이 쌓여 병렬로 돌린다.
        // 조회 실패는 **그 방만** nil 로 떨어뜨린다(목록 전체를 에러로 만들지 않는다).
        return await withTaskGroup(of: (Int, ChatRoomListItem).self) { group in
            for (index, room) in rooms.enumerated() {
                group.addTask {
                    // 멤버 목록을 먼저 확정하고 제목·얼굴을 **거기서 함께** 뽑는다 — 둘을 따로 구하면
                    // 조회가 한쪽에만 반영되는 틈이 생기고, 행은 이름과 얼굴이 어긋난 채로 그려진다.
                    let members: [ChatMember]?
                    if room.membership.members.isEmpty {
                        members = try? await repository.getChatRoomMembers(chatRoomId: room.room.id)
                    } else {
                        members = room.membership.members
                    }
                    return (
                        index,
                        ChatRoomListItem(
                            room: room,
                            peerTitle: members.map { chatRoomPeerTitle(members: $0) },
                            peerImageUrl: members.flatMap { chatRoomPeerImageUrl(members: $0) }
                        )
                    )
                }
            }
            var items: [(Int, ChatRoomListItem)] = []
            for await item in group {
                items.append(item)
            }
            return items.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }
}

/// 방 하나의 대화 상태. **한 인스턴스가 방을 갈아탄다** — 방마다 새 ViewModel 을 만들면
/// 각자 폴링을 돌린다(QA 결함-2).
///
/// 폴링은 `onScreenStart`/`stopPolling` 로만 돌고 멈춘다 — 화면이 보이지 않는 동안(탭 이동·백그라운드·
/// 로그아웃 뒤 남은 엔트리) 서버를 두드리지 않게 하기 위해서다(QA 결함-1).
///
/// 원본의 `viewModelScope` 는 `Main.immediate` 라 `launch` 첫 구간(첫 suspend 전까지)이 호출한 자리에서 바로
/// 돈다. Swift 태스크는 다음 차례에 시작하므로, 그 구간의 상태 변경은 `scope.launch` **앞으로** 옮겼다 —
/// 안 그러면 전송 버튼을 두 번 누르는 사이에 `sending` 이 아직 거짓이다.
///
/// **대기 구간에서는 `self` 를 잡지 않는다.** 원본은 뷰모델이 사라지면 `viewModelScope` 취소로 진행 중인 요청까지
/// 끊긴다. 여기서 `guard let self` 뒤에 `await` 하면 그 대기 내내 뷰모델이 해제되지 않아 `ViewModelScope.deinit` 의
/// 취소가 돌지 않고, 단독 목적지 방을 빠져나가도 나가기·신고·전송이 서버까지 간다. 그래서 태스크는 저장소를
/// 따로 들고 기다리고, 상태는 응답이 온 뒤 동기 함수로만 쓴다. 공백 메우기처럼 대기가 여러 번인 흐름은
/// `gapFill` 이 돌려주는 클로저로 돈다 — 호출부가 `self` 를 쥔 채 `await` 하지 않게 하기 위해서다.
@MainActor
@Observable
final class ChatRoomViewModel {

    enum UiState: Equatable, Sendable {
        case loading
        /// `pending`: 아직 서버에서 되돌아오지 않은 내 메시지. 소켓 전송(`/pub/…/messages`)은 **응답이 없어서**
        /// 화면이 먼저 그려 두고, 같은 내용이 `messages` 로 돌아오면 지운다.
        case success(messages: [ChatMessage], pending: [PendingMessage])
        /// `notParticipant`: 403 CHAT_NOT_PARTICIPANT — 이 방에 더는 참여자가 아니다(나갔거나 빠졌다). 호출자가 캐시를 버린다
        case error(message: String, notParticipant: Bool)

        var isSuccess: Bool {
            if case .success = self { return true }
            return false
        }
    }

    /// 보내 놓고 확인을 기다리는 메시지.
    ///
    /// - `localId`: 화면에서 구분하기 위한 임시 id(음수 — 서버 id 와 겹치지 않는다)
    /// - `sinceId`: 보낼 때 이미 있던 마지막 메시지 id. 예전에 보낸 **같은 문장**을 확인으로 착각하지 않게 한다
    /// - `failed`: 확인이 `PENDING_TIMEOUT_MS` 안에 오지 않았다
    struct PendingMessage: Equatable, Sendable {
        var localId: Int64
        var content: String
        var sinceId: Int64
        var failed: Bool

        init(localId: Int64, content: String, sinceId: Int64, failed: Bool = false) {
            self.localId = localId
            self.content = content
            self.sinceId = sinceId
            self.failed = failed
        }
    }

    struct InputState: Equatable, Sendable {
        var text: String = ""
        var sending: Bool = false
        var errorMessage: String?
    }

    /// 메시지 신고(`POST /chat-rooms/{id}/reports`)의 진행 상태.
    ///
    /// `outcome`: 직전 결과. **전송을 시작할 때 nil 로 되돌린다** — 같은 결과가 연달아 오면
    /// (같은 메시지를 또 신고 → 같은 409) 값이 안 바뀌어 화면의 `.onChange(of: reportOutcome)` 가
    /// 발화하지 않고 시트가 열린 채 남는다.
    struct ReportState: Equatable, Sendable {
        var submitting: Bool = false
        var outcome: ChatReportOutcome?
    }

    /// 방 안 메시지 검색(`GET /chat-rooms/{id}/messages/search`). 헤더의 검색 아이콘으로 열고 닫는다.
    ///
    /// - `results`: nil 이면 아직 검색하지 않았다(검색어가 짧거나 비어 있다). 빈 목록은 「결과 없음」이다 —
    ///   둘을 구분해야 안내 문구가 다르다.
    /// - `nextCursor`: 더 과거 결과를 받을 커서. 서버는 최신부터 준다(id 내림차순).
    struct SearchState: Equatable, Sendable {
        var open: Bool = false
        var query: String = ""
        var results: [ChatMessage]?
        var loading: Bool = false
        var loadingMore: Bool = false
        var hasNext: Bool = false
        var nextCursor: Int64?
        var errorMessage: String?
    }

    private(set) var uiState: UiState = .loading
    private(set) var inputState = InputState()
    private(set) var searchState = SearchState()
    private(set) var leftRoom = false

    /// 메시지 신고의 **전송 중 여부와 결과**. 고른 사유와 적던 상세는 화면이 들고 있다 —
    /// 여기 올려 두면 화면 상태가 두 곳으로 갈려 「시트는 닫혔는데 사유가 남아 있다」가 생긴다.
    private(set) var reportState = ReportState()

    /// 헤더 제목 — 나를 뺀 참여자 닉네임(`chatRoomPeerTitle`, 목록과 같은 규칙).
    /// 아직 못 받았거나 조회에 실패하면 nil 이고, 그때 화면은 「출발지 → 도착지」로 떨어진다.
    private(set) var peerTitle: String?

    /// 상대 말풍선 아바타용 `publicId → 사진`(`chatMemberImageUrls`). 제목과 **같은 조회 한 번**에서
    /// 나온다 — 메시지에는 사진이 실려 오지 않아 이 사전이 유일한 출처다.
    /// 못 받았으면 빈 사전이고, 그때 아바타는 회색 원으로 떨어진다.
    private(set) var peerImageUrls: [String: String] = [:]

    /// 이 방의 푸시 알림 음소거 여부(서버 `notificationMuted`). 서버 값을 받기 전엔 false 다 —
    /// 「알림 꺼짐」을 잘못 보여 주는 것보다 잠깐 켜진 것으로 보이는 편이 낫다(기본값이 켜짐이므로).
    private(set) var muted = false

    @ObservationIgnored private let repository: any ChatRepository
    @ObservationIgnored private let scope = ViewModelScope()

    /// 페이징 커서 — 화면이 들고 있는 **가장 마지막 메시지 id**. 읽음 처리의 성공 여부와 무관하게 전진한다.
    @ObservationIgnored private var lastMessageId: Int64?

    /// **서버에 읽음으로 반영된** 마지막 메시지 id. `lastMessageId` 와 **일부러 분리했다** —
    /// 예전엔 한 변수가 커서와 「보냈다」 표시를 겸해서, 읽음 호출이 실패해도 커서가 이미 전진해 있어
    /// **다시 보내지 않았다**(`if (id == lastMessageId) return` 에서 조기 반환). 그러면 새 메시지가 더
    /// 오지 않는 방은 읽음이 영영 반영되지 않아 목록 배지가 읽은 방에 계속 남는다.
    ///
    /// 서버는 읽음을 5초 버퍼에 모아 반영하므로(Backend #188) 다음 주기에 한 번 더 보내는 비용이 거의 없다.
    @ObservationIgnored private var readSentMessageId: Int64?

    /// 지금 서버로 **보내고 있는** 읽음 지점. 재시도 주기(3초)가 느린 응답과 겹쳐 같은 id 를 두 번
    /// 보내지 않게 한다 — 예전엔 커서를 먼저 세워 두는 것이 이 역할까지 겸했다.
    @ObservationIgnored private var readSendingMessageId: Int64?

    @ObservationIgnored private var nextLocalId: Int64 = -1
    @ObservationIgnored private var searchJob: Task<Void, Never>?
    @ObservationIgnored private(set) var chatRoomId: Int64?
    @ObservationIgnored private var pollingJob: Task<Void, Never>?
    @ObservationIgnored private var socketJob: Task<Void, Never>?
    @ObservationIgnored private var loadJob: Task<Void, Never>?

    /// 소켓 구독이 살아 있는가 — 살아 있으면 폴링하지 않는다
    @ObservationIgnored private var realtimeAlive = false

    init(repository: any ChatRepository) {
        self.repository = repository
    }

    /// 화면이 보이기 시작할 때 호출한다(최초 진입·뒤로 돌아옴·앱 복귀·다른 방으로 전환).
    /// 방이 바뀌었으면 상태를 갈아엎고, 같은 방이면 조용히 다시 읽는다 —
    /// 재진입 시 재조회가 없으면 내가 보낸 뒤 학습된 「내 메시지」 판정이 교정되지 않는다(QA 결함-2).
    func onScreenStart(roomId: Int64, knownMuted: Bool? = nil) {
        let roomChanged = chatRoomId != roomId
        if roomChanged {
            stopPolling()
            loadJob?.cancel()
            chatRoomId = roomId
            lastMessageId = nil
            readSentMessageId = nil
            readSendingMessageId = nil
            peerTitle = nil
            // 제목과 **같은 자리에서** 비운다 — 사전은 「이 방의 참여자」가 근거다. 앞 방 것을 남겨 두면
            // 새 방의 참여자 조회가 실패해(= 근거가 없어) 회색 원이어야 할 자리에 앞 방에서 본 얼굴이
            // 그려진다. 두 방에 겹치는 사람이 많아 눈에 잘 띄지도 않는다.
            peerImageUrls = [:]
            muted = false
            uiState = .loading
            inputState = InputState()
            // 신고 상태도 방 단위다 — 앞 방의 결과 배너가 새 방에 남으면 방금 신고한 것처럼
            // 읽히고, 방을 갈아타며 버린 전송(아래 roomId 가드) 때문에 submitting 이 참으로
            // 굳어 있으면 새 방에서 신고 버튼이 영영 잠긴다.
            reportState = ReportState()
            searchJob?.cancel()
            searchState = SearchState()
        }
        // 나가기 신호는 화면이 다시 열릴 때마다 내린다 — 남겨두면 재진입 즉시 또 나가진 것처럼 튕긴다.
        leftRoom = false
        // 이미 대화를 그리고 있으면 스피너로 되돌리지 않는다(깜빡임 방지)
        load(showLoading: roomChanged || !uiState.isSuccess)
        loadPeerMembers(roomId: roomId)
        if roomChanged { loadMuted(roomId: roomId, knownMuted: knownMuted) }
        startRealtime(roomId: roomId)
        startPolling()
    }

    /// 음소거 상태. 서버에 방 단건으로 묻는 길이 없어 **내 방 목록**에서 이 방을 찾아 읽는다.
    /// 목록에서 들어온 경우엔 그 값을 그대로 받아(knownMuted) 호출 자체를 생략한다 —
    /// 목록 API 는 방 정보·참여자까지 다 담고 있어 방을 열 때마다 다시 부르기엔 무겁다.
    /// 방을 처음 열 때 한 번이면 된다 — 이후 변경은 이 화면의 토글이 유일한 출처라 응답을 기다리지 않고 반영한다.
    /// 실패는 삼킨다(기본 「켜짐」으로 남을 뿐).
    private func loadMuted(roomId: Int64, knownMuted: Bool?) {
        if let knownMuted {
            muted = knownMuted
            return
        }
        let repository = self.repository
        scope.launch { [weak self] in
            guard let rooms = try? await repository.getMyChatRooms() else { return }
            guard let self else { return }
            if self.chatRoomId != roomId { return }
            if let room = rooms.first(where: { $0.room.id == roomId }) {
                self.muted = room.membership.notificationMuted
            }
        }
    }

    /// 알림 끄기/켜기. **낙관적으로** 먼저 바꾸고 서버가 거절하면 되돌린다 — 메뉴를 닫자마자
    /// 헤더의 「알림 꺼짐」이 따라와야 눌렀다는 느낌이 난다.
    func toggleMuted() {
        guard let roomId = chatRoomId else { return }
        let target = !muted
        muted = target
        let repository = self.repository
        scope.launch { [weak self] in
            do {
                try await repository.setNotificationMuted(chatRoomId: roomId, muted: target)
            } catch {
                guard let self else { return }
                if self.chatRoomId == roomId {
                    self.muted = !target
                    self.inputState.errorMessage = error.toChatMessage(fallback: "알림 설정을 바꾸지 못했어요")
                }
            }
        }
    }

    func retryLoad() {
        load(showLoading: true)
    }

    /// 참여자를 **한 번 읽어** 헤더 제목과 말풍선 아바타 사전을 함께 세운다. 실패는 삼킨다 —
    /// 제목이 경로로, 얼굴이 회색 원으로 남을 뿐 대화는 멀쩡하다.
    /// 방이 열려 있는 동안 참여자는 거의 바뀌지 않아 재진입마다 한 번이면 충분하다(폴링하지 않는다).
    private func loadPeerMembers(roomId: Int64) {
        let repository = self.repository
        scope.launch { [weak self] in
            let members = try? await repository.getChatRoomMembers(chatRoomId: roomId)
            guard let self else { return }
            // 늦게 온 응답이 그 사이 바뀐 방의 제목·얼굴을 덮어쓰지 않게 한다
            if self.chatRoomId != roomId { return }
            self.peerTitle = members.map { chatRoomPeerTitle(members: $0) }
            self.peerImageUrls = members.map { chatMemberImageUrls(members: $0) } ?? [:]
        }
    }

    private func load(showLoading: Bool) {
        guard let roomId = chatRoomId else { return }
        loadJob?.cancel()
        if showLoading { uiState = .loading }
        let repository = self.repository
        loadJob = scope.launch { [weak self] in
            do {
                let page = try await repository.getMessages(chatRoomId: roomId)
                // 취소된 조회의 결과는 쓰지 않는다 — 코루틴은 재개 지점에서 던지지만 Swift 는 저장소가 정상 반환할 수 있다.
                try Task.checkCancellation()
                let fill = self?.applyLoadedPage(page, roomId: roomId)
                await fill?()
            } catch {
                guard let failure = chatFailureOnLiveTask(error: error) else { return }
                self?.applyLoadFailure(failure, showLoading: showLoading)
            }
        }
    }

    /// 조회한 첫 페이지를 그린다. 이어서 메울 공백이 있으면 그 일을 돌려준다.
    private func applyLoadedPage(_ page: ChatMessagePage, roomId: Int64) -> GapFill? {
        // 서버 정렬을 신뢰하지 않고 id 오름차순으로 맞춘다 (커서 페이징은 최신부터 올 수 있다)
        let ordered = page.messages.sorted { $0.id < $1.id }
        publish(messages: ordered)
        markLastAsRead(messageId: ordered.last?.id)
        // 소켓이 이 조회보다 먼저 붙었으면 그 순간의 공백 조회는 화면이 아직 없어 건너뛰었다 — 지금 메운다
        return realtimeAlive ? gapFill(roomId: roomId) : nil
    }

    private func applyLoadFailure(_ failure: any Error, showLoading: Bool) {
        // 이미 대화가 떠 있는데(조용한 재조회) 실패하면 화면을 에러로 갈아치우지 않는다
        if showLoading || !uiState.isSuccess {
            uiState = .error(
                message: failure.toChatMessage(fallback: "대화를 불러오지 못했어요"),
                notParticipant: (failure as? ChatException)?.isNotParticipant == true
            )
        }
    }

    /// 실시간 수신(STOMP) 구독. 화면이 보이는 동안만 연결한다.
    ///
    /// 연결될 때마다(처음·재연결) 마지막 id 이후를 **한 번** 조회해 끊긴 사이의 공백을 메운다 — 서버 브로커는
    /// 지금 구독 중인 사람에게만 밀고 지난 메시지를 다시 주지 않는다. 연결이 살아 있는 동안은 폴링하지 않는다.
    /// 실패·끊김은 저장소가 재시도로 삼키므로 화면엔 아무것도 띄우지 않는다 — 끊긴 동안은 폴링이 메운다.
    private func startRealtime(roomId: Int64) {
        socketJob?.cancel()
        realtimeAlive = false
        let events = repository.observeRoom(chatRoomId: roomId)
        socketJob = scope.launch { [weak self] in
            for await event in events {
                // 취소된 뒤 버퍼에 남은 신호가 새 구독의 `realtimeAlive` 를 흔들지 않게 한다
                if Task.isCancelled { return }
                if self == nil { return }
                let fill = self?.applyRealtime(event: event, roomId: roomId)
                await fill?()
            }
        }
    }

    /// 소켓 신호 하나를 반영한다. 이어서 메울 공백이 있으면 그 일을 돌려준다.
    private func applyRealtime(event: ChatRealtimeEvent, roomId: Int64) -> GapFill? {
        if chatRoomId != roomId { return nil }
        switch event {
        case .connected:
            realtimeAlive = true
            return gapFill(roomId: roomId) // 구독이 걸린 뒤에 조회 — 겹치는 메시지는 id 로 합쳐진다
        case .disconnected:
            realtimeAlive = false
        case .message(let message):
            guard case .success(let held, let pending) = uiState else { return nil }
            // 같은 id 가 다시 오면(삭제 브로드캐스트) **새 사본이 이긴다** — mergeMessagesById 주석
            let merged = mergeMessagesById(held: held, incoming: [message])
            publish(messages: merged, pending: pending)
            markLastAsRead(messageId: merged.last?.id)
        }
        return nil
    }

    /// 화면이 가려지면(탭 이동·백그라운드·이탈) 폴링과 소켓을 함께 멈춘다. 안 그러면 로그아웃 뒤에도 계속 쏜다.
    func stopPolling() {
        pollingJob?.cancel()
        pollingJob = nil
        socketJob?.cancel()
        socketJob = nil
        realtimeAlive = false
    }

    // 소켓이 안 붙어 있을 때만 조회한다. 붙어 있으면 새 메시지는 소켓으로 오고, 공백은 연결 순간에 메웠다.
    private func startPolling() {
        // 이 태스크는 취소될 때만 끝나고, 취소하는 자리(`stopPolling`)가 곧바로 nil 로 비운다 — 원본 `isActive` 와 같다.
        if pollingJob != nil { return }
        pollingJob = scope.launch { [weak self] in
            while true {
                do {
                    try await Task.sleep(for: .milliseconds(POLL_INTERVAL_MS))
                } catch {
                    return
                }
                if self == nil { return }
                let fill = self?.applyPollTick()
                await fill?()
            }
        }
    }

    /// 폴링 한 주기. 메울 공백을 물어야 하면 그 일을 돌려준다.
    private func applyPollTick() -> GapFill? {
        guard let roomId = chatRoomId else { return nil }
        // 뒤처진 읽음 처리는 **소켓 생사와 무관하게** 다시 보낸다 — 실패한 읽음은 새 메시지가
        // 더 오지 않으면 스스로 나갈 기회가 없고, 그러면 이미 읽은 방에 목록 배지가 계속 남는다.
        // 이미 반영된 지점과 같으면 `markLastAsRead` 가 그 자리에서 되돌아간다(평상시 0회).
        markLastAsRead(messageId: lastMessageId)
        return realtimeAlive ? nil : gapFill(roomId: roomId)
    }

    /// 원본 `fetchNew` 한 번. 호출부가 `self` 를 쥐지 않고 기다리도록 일을 클로저로 돌려준다.
    private typealias GapFill = @MainActor () async -> Void

    /// 마지막 메시지 이후를 읽어 합친다 — 소켓 (재)연결 순간과, 소켓이 없을 때의 폴링이 같이 쓴다.
    ///
    /// 커서(마지막 메시지 id)가 없으면 **첫 페이지를 다시 읽는다**. 메시지가 하나도 없는 방은 커서가 영영 nil 인데,
    /// `after` 에 0 을 넘기면 서버가 cursor < 1 을 400 CHAT_INVALID_CURSOR 로 막는다(#30).
    ///
    /// **`hasNext` 를 끝까지 따라간다.** 예전에는 한 페이지(30건)만 읽고 `hasNext` 를 버렸다 — 끊긴 사이에
    /// 31건 이상이 오간 방은 그 뒤 `realtimeAlive` 가 참이 되면서 폴링도 건너뛰어, 31번째 이후가 **화면을
    /// 벗어나 다시 열 때까지 영구히 비어 있었다**(읽음 커서도 함께 뒤처져 목록 배지가 어긋났다).
    /// 서버는 `size + 1` 을 읽어 `hasNext` 를 정확히 내려준다(`ChatMessageService.findAfter`) —
    /// 「더 있다」는 신호가 오는데 앱이 버리고 있었다. 무한 루프 방어로 `MAX_GAP_FILL_PAGES` 까지만 돈다.
    ///
    /// **과거 방향(커서 없음)으로는 이어 읽지 않는다.** 그 응답의 `hasNext` 는 「더 **과거**가 있다」는
    /// 뜻이라 여기서 따라가면 올려 읽는 역방향 페이징이 되는데, 그건 이 함수의 일이 아니다.
    ///
    /// 합칠 때는 응답이 온 **뒤의** 상태를 다시 읽는다 — 조회하는 동안 소켓으로 들어온 메시지를 덮어쓰지 않게.
    /// 실패는 화면을 깨지 않는다 — 다음 연결·다음 주기가 메운다.
    private func gapFill(roomId: Int64) -> GapFill {
        let repository = self.repository
        return { [weak self] in
            guard self?.uiState.isSuccess == true else { return }
            var cursor = self?.lastMessageId
            var pagesRead = 0
            while true {
                // 커서가 있으면 「이후」 방향, 없으면 첫 페이지(= 과거 방향 최신 30건).
                let at = cursor
                let page: ChatMessagePage
                do {
                    if let at {
                        page = try await repository.getMessagesAfter(chatRoomId: roomId, cursor: at)
                    } else {
                        page = try await repository.getMessages(chatRoomId: roomId)
                    }
                } catch {
                    return
                }
                // 취소된 수집의 응답은 쓰지 않는다 — 코루틴은 재개 지점에서 던진다.
                if Task.isCancelled { return }
                guard self?.mergeGapPage(page, roomId: roomId) == true else { return }
                if at == nil || !page.hasNext { return }
                pagesRead += 1
                if pagesRead >= MAX_GAP_FILL_PAGES { return }
                // 커서는 서버가 준 nextCursor 를 쓴다(이 방향에서는 「방금 받은 마지막 id」다).
                // 안 주는 서버면 받은 페이지의 최대 id 로 떨어진다 — 화면의 마지막 id 를 쓰면 그 사이
                // 소켓으로 들어온 더 큰 id 때문에 중간을 건너뛸 수 있다.
                cursor = page.nextCursor ?? page.messages.map(\.id).max()
            }
        }
    }

    /// 공백 메우기 한 페이지를 합친다. 더 읽을 이유가 없어졌으면 거짓이다.
    private func mergeGapPage(_ page: ChatMessagePage, roomId: Int64) -> Bool {
        if page.messages.isEmpty || chatRoomId != roomId { return false }
        guard case .success(let held, let pending) = uiState else { return false }
        // 같은 id 의 새 사본이 이긴다(삭제 브로드캐스트) — mergeMessagesById 주석
        let merged = mergeMessagesById(held: held, incoming: page.messages)
        publish(messages: merged, pending: pending)
        markLastAsRead(messageId: merged.last?.id)
        return true
    }

    func onInputChange(text: String) {
        inputState.text = text
        inputState.errorMessage = nil
    }

    /// 전송. **소켓이 붙어 있으면 소켓으로**(`/pub/chat-rooms/{id}/messages`), 아니면 REST 로 보낸다.
    ///
    /// 둘 중 하나만 쓴다 — 소켓으로 보낸 뒤 확인이 늦다고 REST 로 다시 보내면 같은 메시지가 두 번 저장된다.
    /// 그래서 소켓 경로의 실패는 재전송이 아니라 **실패 표시**로 끝난다(사용자가 다시 보낼지 정한다).
    func send() {
        guard let roomId = chatRoomId else { return }
        let content = inputState.text.trim()
        if content.isEmpty || inputState.sending { return }
        if content.utf16.count > MAX_CONTENT_LENGTH {
            // 서버도 같은 한도로 거절한다(SendMessageRequest @Size). 프레임을 띄우기 전에 여기서 막는다.
            inputState.errorMessage = "메시지는 \(MAX_CONTENT_LENGTH)자까지 보낼 수 있어요"
            return
        }
        inputState.sending = true
        inputState.errorMessage = nil
        let repository = self.repository
        scope.launch { [weak self] in
            let overSocket = (try? await repository.trySendMessage(chatRoomId: roomId, content: content)) ?? false
            // `try?` 가 취소를 삼킨다. 코루틴은 다음 재개 지점에서 던져 요청이 나가지 않으므로, 여기서 끝낸다 —
            // 안 그러면 화면을 떠난 전송이 REST 로 한 번 더 나갈 수 있다.
            if Task.isCancelled { return }
            if overSocket {
                self?.addPending(content: content)
                return
            }
            // 소켓이 없을 때의 경로. 이쪽은 저장 결과가 응답으로 와서 그 자리에서 붙일 수 있다.
            do {
                let sent = try await repository.sendMessage(chatRoomId: roomId, content: content)
                self?.applyRestSent(sent)
            } catch {
                self?.applyRestSendFailure(error)
            }
        }
    }

    // 서버가 답을 주지 않는 전송이라 화면이 먼저 그린다. 같은 내용이 구독으로 돌아오면(또는 폴링이 물어 오면)
    // publish 가 이 말풍선을 걷어낸다.
    private func addPending(content: String) {
        var held: [ChatMessage]?
        var waiting: [PendingMessage] = []
        if case .success(let messages, let pending) = uiState {
            held = messages
            waiting = pending
        }
        let entry = PendingMessage(
            localId: nextLocalId,
            content: content,
            sinceId: held?.last?.id ?? 0
        )
        nextLocalId -= 1
        if let held {
            uiState = .success(messages: held, pending: waiting + [entry])
        }
        inputState = InputState() // 프레임은 이미 나갔다 — 입력창은 바로 비운다
        watchPending(localId: entry.localId)
    }

    /// 확인이 끝내 오지 않으면 실패로 바꿔 보여 준다. 그 전에 돌아오면 이미 목록에서 사라져 있다.
    private func watchPending(localId: Int64) {
        scope.launch { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(PENDING_TIMEOUT_MS))
            } catch {
                return
            }
            guard let self else { return }
            guard case .success(let held, let pending) = self.uiState else { return }
            if !pending.contains(where: { $0.localId == localId }) { return }
            self.uiState = .success(
                messages: held,
                pending: pending.map { waiting in
                    var updated = waiting
                    if waiting.localId == localId { updated.failed = true }
                    return updated
                }
            )
            self.inputState.errorMessage = "메시지를 보내지 못했어요"
        }
    }

    private func applyRestSent(_ sent: ChatMessage) {
        if case .success(let held, let pending) = uiState {
            // 같은 id 가 이미 있으면 **방금 받은 응답이 이긴다** — mergeMessagesById 주석
            let merged = mergeMessagesById(held: held, incoming: [sent])
            publish(messages: merged, pending: pending)
            markLastAsRead(messageId: merged.last?.id)
        }
        inputState = InputState() // 성공 시에만 입력창을 비운다
    }

    private func applyRestSendFailure(_ error: any Error) {
        inputState.sending = false
        inputState.errorMessage = error.toChatMessage(fallback: "메시지를 보내지 못했어요")
    }

    /// 목록을 새로 그린다. 서버에서 돌아온 메시지와 짝지어진 대기 말풍선은 여기서 사라진다.
    private func publish(messages: [ChatMessage], pending: [PendingMessage] = []) {
        uiState = .success(messages: messages, pending: reconcilePending(messages: messages, pending: pending))
    }

    // 채팅방 나가기(DELETE /chat-rooms/{id}/users). 실패하면 화면에 남기고 사유를 알린다.
    func leaveRoom() {
        guard let roomId = chatRoomId else { return }
        let repository = self.repository
        scope.launch { [weak self] in
            do {
                try await repository.leaveChatRoom(chatRoomId: roomId)
                self?.leftRoom = true
            } catch {
                guard let failure = chatFailureOnLiveTask(error: error) else { return }
                self?.inputState.errorMessage = failure.toChatMessage(fallback: "채팅방에서 나가지 못했어요")
            }
        }
    }

    /// 메시지 1건 신고. **성공해도 되돌릴 길이 없다** — 서버에 취소 엔드포인트가 없고, 같은
    /// 메시지를 다시 신고하면 사유를 바꿔도 409 다(실측). 그래서 재확인은 사유 시트가 맡고
    /// (사유를 고르는 것 자체가 확인이다) 여기서는 두 번 보내지 않는 것만 지킨다.
    ///
    /// `description` 은 호출부가 이미 공백을 접어서 넘긴다 — 저장소도 한 번 더 접는다(이중 방어).
    func reportMessage(chatMessageId: Int64, reason: ChatReportReason, description: String?) {
        guard let roomId = chatRoomId else { return }
        if reportState.submitting { return }
        // 보내는 동안 앞 결과를 지운다: 화면이 결과의 **변화**로 시트를 닫으므로, 같은 결과가
        // 두 번 올 때 nil 을 한 번 거치지 않으면 두 번째가 없던 일이 된다.
        reportState = ReportState(submitting: true, outcome: nil)
        let repository = self.repository
        scope.launch { [weak self] in
            let outcome: ChatReportOutcome
            do {
                try await repository.reportMessage(
                    chatRoomId: roomId,
                    chatMessageId: chatMessageId,
                    reason: reason,
                    description: description
                )
                outcome = ChatReportOutcome(
                    // 운영이 **언제 무엇을 하겠다**고는 쓰지 않는다(`ProductClaimsTest` 의 시한
                    // 금지와 같은 선). 서버가 실제로 보장하는 둘만 적는다: 접수됐고, 중복은 막힌다.
                    message: "신고를 접수했어요. 같은 메시지는 다시 신고할 수 없어요.",
                    accepted: true
                )
            } catch {
                guard let failure = chatFailureOnLiveTask(error: error) else { return }
                outcome = failure.toChatReportOutcome()
            }
            guard let self else { return }
            if self.chatRoomId != roomId { return }
            self.reportState = ReportState(submitting: false, outcome: outcome)
        }
    }

    func openSearch() {
        searchState.open = true
    }

    /// 닫으면 검색어·결과를 다 버린다 — 다시 열 때 지난 검색이 남아 있으면 「방금 친 것」으로 오해한다
    func closeSearch() {
        searchJob?.cancel()
        searchState = SearchState()
    }

    /// 검색어 변경. `SEARCH_MIN_LENGTH` 이상이면 `SEARCH_DEBOUNCE_MS` 뒤 첫 페이지를 묻는다.
    /// 짧아지면 결과를 비우고(nil) 요청도 보내지 않는다 — 서버가 어차피 400 으로 거절한다.
    func onSearchQueryChange(text: String) {
        searchJob?.cancel()
        let keyword = text.trim()
        if keyword.utf16.count < SEARCH_MIN_LENGTH {
            searchState.query = text
            searchState.results = nil
            searchState.loading = false
            searchState.loadingMore = false
            searchState.hasNext = false
            searchState.nextCursor = nil
            searchState.errorMessage = nil
            return
        }
        searchState.query = text
        searchState.loading = true
        searchState.errorMessage = nil
        searchJob = launchSearch(keyword: keyword, cursor: nil, debounce: true)
    }

    /// 에러 화면의 「다시 시도」 — 디바운스 없이 바로
    func retrySearch() {
        let keyword = searchState.query.trim()
        if keyword.utf16.count < SEARCH_MIN_LENGTH { return }
        searchJob?.cancel()
        searchState.loading = true
        searchState.errorMessage = nil
        searchJob = launchSearch(keyword: keyword, cursor: nil, debounce: false)
    }

    /// 다음 페이지(더 과거). 이미 받는 중이거나 더 없으면 무시한다
    func loadMoreSearch() {
        let current = searchState
        guard let cursor = current.nextCursor else { return }
        if !current.hasNext || current.loading || current.loadingMore { return }
        let keyword = current.query.trim()
        if keyword.utf16.count < SEARCH_MIN_LENGTH { return }
        searchJob?.cancel()
        searchState.loadingMore = true
        searchState.errorMessage = nil
        searchJob = launchSearch(keyword: keyword, cursor: cursor, debounce: false)
    }

    // cursor == nil 이면 첫 페이지(결과 교체), 아니면 이어 붙인다. 응답이 오기 전에 검색어가 바뀌면
    // 이 태스크는 onSearchQueryChange 가 취소하므로 낡은 결과가 새 검색어 위에 덮이지 않는다.
    private func launchSearch(keyword: String, cursor: Int64?, debounce: Bool) -> Task<Void, Never> {
        let repository = self.repository
        return scope.launch { [weak self] in
            if debounce {
                do {
                    try await Task.sleep(for: .milliseconds(SEARCH_DEBOUNCE_MS))
                } catch {
                    return
                }
            }
            guard let roomId = self?.chatRoomId else { return }
            do {
                let page = try await repository.searchMessages(chatRoomId: roomId, keyword: keyword, cursor: cursor)
                try Task.checkCancellation()
                self?.applySearchPage(page, cursor: cursor)
            } catch {
                guard let failure = chatFailureOnLiveTask(error: error) else { return }
                self?.applySearchFailure(failure)
            }
        }
    }

    private func applySearchPage(_ page: ChatMessagePage, cursor: Int64?) {
        let merged: [ChatMessage]
        if cursor == nil {
            merged = page.messages
        } else {
            var seen = Set<Int64>()
            merged = ((searchState.results ?? []) + page.messages).filter { seen.insert($0.id).inserted }
        }
        searchState.results = merged
        searchState.loading = false
        searchState.loadingMore = false
        searchState.hasNext = page.hasNext
        searchState.nextCursor = page.nextCursor
        searchState.errorMessage = nil
    }

    private func applySearchFailure(_ failure: any Error) {
        searchState.loading = false
        searchState.loadingMore = false
        searchState.errorMessage = failure.toChatMessage(fallback: "검색하지 못했어요")
    }

    /// 읽음 처리. 실패는 사용자에게 알리지 않는다(배지 정확도보다 대화 흐름이 우선) —
    /// 대신 **`readSentMessageId` 를 올리지 않아** 다음 폴링 주기가 같은 id 로 다시 보낸다.
    /// 메시지마다 한 번씩 일어나는 일이라 소켓이 붙어 있으면 그쪽으로 보내 REST 왕복을 아낀다.
    ///
    /// 커서(`lastMessageId`)는 성공 여부와 무관하게 전진한다 — 메시지를 다시 받아 오는 일과
    /// 읽음을 알리는 일은 서로의 재시도에 끼어들지 않아야 한다.
    private func markLastAsRead(messageId: Int64?) {
        guard let roomId = chatRoomId, let id = messageId else { return }
        lastMessageId = id
        // 이미 반영됐거나 지금 보내는 중인 지점이면 보낼 것이 없다(평상시 이 길로 되돌아간다)
        if id == readSentMessageId || id == readSendingMessageId { return }
        readSendingMessageId = id
        let repository = self.repository
        scope.launch { [weak self] in
            let sent: Bool
            do {
                if try await !repository.tryMarkAsRead(chatRoomId: roomId, readMessageId: id) {
                    try await repository.markAsRead(chatRoomId: roomId, readMessageId: id)
                }
                sent = true
            } catch {
                sent = false
            }
            guard let self else { return }
            // 방을 갈아탄 뒤 늦게 온 결과가 새 방의 지점을 더럽히지 않게 한다
            if self.chatRoomId != roomId { return }
            if self.readSendingMessageId == id { self.readSendingMessageId = nil }
            if sent { self.readSentMessageId = id }
        }
    }
}

/// 24 채팅 **탭** — 방 목록에서 고르면 같은 라우트 안에서 방으로 전환한다.
///
/// 21·25·26 의 「채팅 열기」는 이 경로로 오지 않는다 — 탭으로 보내면 매칭 화면이 스택에서 빠진다.
/// 그쪽은 `ChatRoomDestinationRoute` 를 독립 목적지로 쌓아 뒤로가기가 원래 화면으로 돌아가게 한다.
///
/// - `activeChatRoomId`: 진행 중인 방의 **채팅방 id**(`ActivePartyViewModel.chatRoomId`). 열린 채팅방이
///   이것이면 헤더에 「매칭 화면으로 →」를 띄우고 「나가기」를 감춘다. 이 경로의 방은 목록 응답으로 만든
///   것이어서 `partyId` 가 0(모름)이라 **이 값만이 판정 근거다**(`ChatRoom.isActiveParty`).
/// - `activePartyId`: 진행 중인 방의 id(`Ride.id`). 이 경로에서는 사실상
///   판정에 기여하지 못한다(위 참조) — 그래도 같은 판정 함수를 쓰므로 함께 넘긴다. 없으면 nil.
public struct ChatRoute: View {
    private let activeChatRoomId: Int64?
    private let activePartyId: String?
    private let onOpenMatching: () -> Void
    private let onOpenRideOngoing: () -> Void
    private let onLeaveChat: () -> Void
    private let onTabSelect: (MoyeotaTab) -> Void
    private let onNotParticipant: () -> Void

    @HostedViewModel private var state: ChatTabState
    @Environment(\.tabSavedState) private var tabSavedState

    /// - Parameter onNotParticipant: 열린 방에서 403(참여자 아님) — 진행 화면의 채팅방 id 캐시를 버리게 한다
    public init(
        repository: any ChatRepository,
        activeChatRoomId: Int64? = nil,
        activePartyId: String? = nil,
        onOpenMatching: @escaping () -> Void = {},
        onOpenRideOngoing: @escaping () -> Void = {},
        onLeaveChat: @escaping () -> Void = {},
        onTabSelect: @escaping (MoyeotaTab) -> Void = { _ in },
        onNotParticipant: @escaping () -> Void = {}
    ) {
        self.activeChatRoomId = activeChatRoomId
        self.activePartyId = activePartyId
        self.onOpenMatching = onOpenMatching
        self.onOpenRideOngoing = onOpenRideOngoing
        self.onLeaveChat = onLeaveChat
        self.onTabSelect = onTabSelect
        self.onNotParticipant = onNotParticipant
        _state = HostedViewModel(wrappedValue: ChatTabState(repository: repository))
    }

    /// 호스트가 탭 상태를 들고 있는 경로 — 원본 탭 엔트리의 `ViewModelStore`·저장 상태 자리(`ChatTabState`).
    ///
    /// 뷰 수명 동안 처음 받은 인스턴스를 쓴다.
    public init(
        state: ChatTabState,
        activeChatRoomId: Int64? = nil,
        activePartyId: String? = nil,
        onOpenMatching: @escaping () -> Void = {},
        onOpenRideOngoing: @escaping () -> Void = {},
        onLeaveChat: @escaping () -> Void = {},
        onTabSelect: @escaping (MoyeotaTab) -> Void = { _ in },
        onNotParticipant: @escaping () -> Void = {}
    ) {
        self.activeChatRoomId = activeChatRoomId
        self.activePartyId = activePartyId
        self.onOpenMatching = onOpenMatching
        self.onOpenRideOngoing = onOpenRideOngoing
        self.onLeaveChat = onLeaveChat
        self.onTabSelect = onTabSelect
        self.onNotParticipant = onNotParticipant
        _state = HostedViewModel(wrappedValue: state)
    }

    public var body: some View {
        let state = state
        ZStack {
            if let room = state.openedRoom {
                ChatRoomRoute(
                    viewModel: state.roomViewModel,
                    room: room,
                    knownMuted: state.openedMuted,
                    onBack: { state.openedRoom = nil },
                    onOpenMatching: room.isActiveParty(activeChatRoomId: activeChatRoomId, activePartyId: activePartyId)
                        ? onOpenMatching
                        : nil,
                    onOpenRideOngoing: onOpenRideOngoing,
                    // 나간 방을 열어둔 채로 홈에 보내면, 채팅 탭에 돌아왔을 때 참여자가 아닌 방을 다시 연다.
                    onLeaveChat: {
                        state.openedRoom = nil
                        onLeaveChat()
                    },
                    onTabSelect: onTabSelect,
                    onNotParticipant: onNotParticipant
                )
            } else {
                ChatListRoute(
                    viewModel: state.listViewModel,
                    onRoomClick: { picked in
                        // 원본은 방을 열면 목록이 컴포지션에서 빠져 스크롤 위치가 사라진다. 탭 이동으로는 사라지면 안 되므로 여기서만 지운다.
                        // 방 대화의 스크롤은 맡기지 않는다 — 원본 `stickToBottom` 은 `remember` 라 복귀하면 어차피 바닥으로 따라간다.
                        tabSavedState?.remove(ChatListScrollKey)
                        state.openedMuted = picked.membership.notificationMuted
                        state.openedRoom = picked.room
                    },
                    onTabSelect: onTabSelect
                )
            }
        }
        // 방이 열린 상태의 시스템 뒤로가기는 탭을 빠져나가지 않고 목록으로 돌아간다 (화면 ← 와 동일)
        .moyeotaBackHandler(enabled: state.openedRoom != nil) { state.openedRoom = nil }
    }
}

/// 채팅 탭이 화면 밖에 남겨 두는 상태 — 원본 탭 엔트리의 `ViewModelStore`(뷰모델 둘)와 `rememberSaveable`(연 방·음소거) 자리.
///
/// 원본은 `popUpTo(HOME) { saveState = true }` + `restoreState = true` 로 탭을 떠나도 이 값들이 남아, 돌아오면 같은 방의
/// 쓰던 입력·대화로 복귀한다. 탭을 `switch` 로 갈아 끼우는 호스트는 뷰가 없어지므로 `ChatRoute(repository:…)` 를 쓰면
/// 방이 닫혀 목록으로 돌아가고 스피너부터 다시 돈다. 그런 호스트는 탭 바깥에서 이 객체를 하나 들고
/// `ChatRoute(state:…)` 로 넘기고, 로그아웃 때 버린다(`clearBackStack` 자리).
/// `TabView` 처럼 뷰를 살려 두는 호스트는 `ChatRoute(repository:…)` 로 충분하다.
@MainActor
@Observable
public final class ChatTabState {
    // 두 뷰모델을 여기(탭 상태)에 둔다 — 원본은 둘 다 채팅 탭 엔트리에 묶여 목록↔방을 오가도 살아 있다.
    // 방 뷰모델을 방 화면에 두면 나갔다 들어올 때마다 새로 만들어져, 쓰던 입력·대화가 사라지고 스피너부터 다시 돈다.
    @ObservationIgnored let listViewModel: ChatListViewModel
    // 방이 바뀌어도 인스턴스는 하나다 — 방별로 만들면 각자 폴링한다(QA 결함-2).
    @ObservationIgnored let roomViewModel: ChatRoomViewModel

    var openedRoom: ChatRoom?
    // 목록에서 고른 방의 음소거 상태 — 방 화면이 목록 API 를 다시 부르지 않게 함께 들고 간다
    var openedMuted: Bool?

    public init(repository: any ChatRepository) {
        listViewModel = ChatListViewModel(repository: repository)
        roomViewModel = ChatRoomViewModel(repository: repository)
    }
}

private struct ChatListRoute: View {
    let viewModel: ChatListViewModel
    let onRoomClick: (MyChatRoom) -> Void
    let onTabSelect: (MoyeotaTab) -> Void

    var body: some View {
        // 로딩·에러에서도 하단탭 유지 (QA F-1)
        ZStack {
            switch viewModel.uiState {
            case .loading:
                TabStateScaffold(selectedTab: .chat, onTabSelect: onTabSelect) {
                    LoadingBox()
                }
            case .error(let message):
                TabStateScaffold(selectedTab: .chat, onTabSelect: onTabSelect) {
                    ErrorBox(message: message, onRetry: { viewModel.refresh() })
                }
            case .success(let rooms):
                ChatListScreen(rooms: rooms, onRoomClick: onRoomClick, onTabSelect: onTabSelect)
            }
        }
        // 방에 들어갔다 돌아오면 안읽음 배지가 갱신돼야 해서 매 진입마다 다시 읽는다
        .topEntryTask { viewModel.refresh() }
    }
}

private struct ChatRoomRoute: View {
    let viewModel: ChatRoomViewModel
    let room: ChatRoom
    /// 목록에서 들어왔다면 이미 알고 있는 음소거 상태 — 방을 열 때 목록 API 를 다시 부르지 않는다
    var knownMuted: Bool?
    let onBack: () -> Void
    let onOpenMatching: (() -> Void)?
    let onOpenRideOngoing: () -> Void
    let onLeaveChat: () -> Void
    let onTabSelect: (MoyeotaTab) -> Void
    /// 서버가 「참여자 아님」(403)을 답했다 — 호출자는 이 방 id 캐시를 버려야 한다
    let onNotParticipant: () -> Void
    /// 독립 목적지는 false — `ChatScrollTracker` 주석
    var followsBottomOnOpen = true

    var body: some View {
        // 방 화면의 이동 수단은 뒤로가기(목록 복귀) + 하단탭 둘 다다.
        // 대화를 못 불러와도 둘 다 남긴다 — Success 일 때의 골격과 같게 (QA F-1)
        //
        // 제목은 **참여자 닉네임**이고 경로는 부제로 내려간다(목록과 같은 규칙 — chatRoomPeerTitle 주석).
        // 참여자를 아직/끝내 못 받았으면 예전처럼 경로가 제목이고, 그때 부제는 메시지 수다
        // (제목과 부제에 같은 문장을 두 번 적지 않는다).
        let routeLabel = "\(room.departure) → \(room.destination)"
        let peerTitle = viewModel.peerTitle
        let roomTitle = peerTitle ?? routeLabel
        ZStack {
            switch viewModel.uiState {
            case .loading:
                TabStateScaffold(selectedTab: .chat, onTabSelect: onTabSelect) {
                    NestedBackStateScaffold(title: roomTitle, onBack: onBack) { LoadingBox() }
                }
            case .error(let message, _):
                TabStateScaffold(selectedTab: .chat, onTabSelect: onTabSelect) {
                    NestedBackStateScaffold(title: roomTitle, onBack: onBack) {
                        ErrorBox(message: message, onRetry: { viewModel.retryLoad() })
                    }
                }
            case .success(let messages, let pending):
                chatScreen(
                    roomTitle: roomTitle,
                    roomSubtitle: peerTitle != nil ? routeLabel : "메시지 \(messages.count)개",
                    messages: messages,
                    pending: pending
                )
            }
        }
        // 화면이 보이는 동안만 조회·폴링한다. 탭을 옮기거나 앱이 백그라운드로 가면 즉시 멈춘다.
        // 같은 구간 동안 「이 방을 보고 있다」를 알려 푸시 알림이 겹치지 않게 한다(`ChatForeground`).
        .lifecycleEffect(
            onStart: {
                viewModel.onScreenStart(roomId: room.id, knownMuted: knownMuted)
                ChatForeground.visibleRoomId = room.id
            },
            onStop: {
                // 키가 바뀌는 경우(아래 `.id`) 새 방의 시작이 앞 방의 정지보다 먼저 올 수 있다 — 새 방을 멈추지 않는다.
                if viewModel.chatRoomId == room.id { viewModel.stopPolling() }
                if ChatForeground.visibleRoomId == room.id { ChatForeground.visibleRoomId = nil }
            }
        )
        .onChange(of: viewModel.leftRoom) { _, left in
            if left { onLeaveChat() }
        }
        .onChange(of: viewModel.uiState, initial: true) { _, state in
            if case .error(_, true) = state { onNotParticipant() }
        }
        // 원본 `LifecycleStartEffect(room.id)` 의 키 — 방이 바뀌면 정지 후 다시 시작한다.
        .id(room.id)
    }

    private func chatScreen(
        roomTitle: String,
        roomSubtitle: String,
        messages: [ChatMessage],
        pending: [ChatRoomViewModel.PendingMessage]
    ) -> some View {
        let input = viewModel.inputState
        let search = viewModel.searchState
        let report = viewModel.reportState
        let peerImageUrls = viewModel.peerImageUrls
        return ChatScreen(
            roomTitle: roomTitle,
            roomSubtitle: roomSubtitle,
            // 아직 확인이 안 온 내 메시지는 목록 끝에 「보내는 중」으로 붙는다 — 소켓 전송은 응답이 없다.
            messages: messages.map { $0.toUiMessage(imageUrls: peerImageUrls) } + pending.map { $0.toUiMessage() },
            input: input.text,
            sending: input.sending,
            errorMessage: input.errorMessage,
            onInputChange: { viewModel.onInputChange(text: $0) },
            onSend: { viewModel.send() },
            onBack: onBack,
            onOpenRideOngoing: onOpenRideOngoing,
            onOpenMatching: onOpenMatching,
            onLeaveChat: { viewModel.leaveRoom() }, // 서버에서 빠진 뒤 14 홈으로
            onTabSelect: onTabSelect,
            muted: viewModel.muted,
            onToggleMute: { viewModel.toggleMuted() },
            // 진행 중인 내 방의 채팅방에서는 「나가기」를 **아예 두지 않는다** — 서버가 나간 참여자를
            // 되살리지 못해(chat_room_user 복합키에 leftAt 만 찍힘) 한 번 나가면 운행 내내 대화에
            // 못 돌아온다(실기 QA). 진행 중 판정이 onOpenMatching 의 유무와 같은 근거라 그걸 그대로 본다.
            //
            // 진행 중이 아닌 방에서도 나가기는 되돌릴 수 없다(재합류 경로가 없다) — 그쪽은 메뉴에
            // 남겨 두되 ChatScreen 이 재확인을 받는다.
            canLeave: onOpenMatching == nil,
            search: ChatSearchUi(
                open: search.open,
                query: search.query,
                results: search.results?.map { $0.toUiMessage(imageUrls: peerImageUrls) },
                loading: search.loading,
                loadingMore: search.loadingMore,
                hasMore: search.hasNext,
                errorMessage: search.errorMessage
            ),
            onOpenSearch: { viewModel.openSearch() },
            onCloseSearch: { viewModel.closeSearch() },
            onSearchQueryChange: { viewModel.onSearchQueryChange(text: $0) },
            onSearchRetry: { viewModel.retrySearch() },
            onSearchLoadMore: { viewModel.loadMoreSearch() },
            reportSubmitting: report.submitting,
            reportOutcome: report.outcome,
            onReportMessage: { messageId, reason, description in
                viewModel.reportMessage(chatMessageId: messageId, reason: reason, description: description)
            },
            followsBottomOnOpen: followsBottomOnOpen
        )
    }
}

/// 원본의 `TabStateScaffold { BackStateScaffold { … } }` 에서 안쪽 골격 자리.
///
/// 원본의 `StatusBarSpacer` 는 놓인 위치와 상관없이 상태바 인셋 전체 높이다. 그래서 이 조합은 회색 상태바 띠 아래에
/// 흰 띠가 한 번 더 깔리고 그 아래에 상단바가 온다. iOS 의 `BackStateScaffold` 는 겹침만큼만 재는 여백을 써서
/// 흰 띠가 0 으로 접히므로, 이 자리만 위치를 보지 않는 여백으로 그린다. 그 밖의 모양은 `BackStateScaffold` 와 같다.
private struct NestedBackStateScaffold<Content: View>: View {
    let title: String
    let onBack: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                StatusBarSpacer(ignoringPosition: true)
                MoyeotaTopBar(title: title, onBack: onBack)
            }
            .frame(maxWidth: .infinity)
            // 기본 `.background` 는 안전 영역까지 번져 위의 회색 상태바 띠를 흰색으로 덮는다
            .background(MoyeotaColor.SurfaceCanvas, ignoresSafeAreaEdges: [])
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MoyeotaColor.SurfaceSoft)
    }
}

/// 24 채팅방 — **독립 목적지**(`Routes.CHAT_ROOM`). 21·25·26 의 「채팅 열기」가 이걸 스택에 쌓는다.
///
/// 대화 자체는 탭 안의 방 화면과 **완전히 같은 것**을 쓴다(`ChatRoomRoute`) — 방 하나에 화면이 둘이면
/// 폴링·읽음 처리·나가기 규칙이 두 벌이 된다. 여기서 더 하는 일은 하나뿐이다: 라우트 인자로 받은
/// roomId 로 방 이름(출발지 → 목적지)을 한 번 조회하는 것. 탭 경로는 목록에서 이미 `ChatRoom` 을
/// 통째로 들고 오지만, 진행 화면에서는 id 밖에 없다.
///
/// - `activeChatRoomId`: 진행 중인 방의 **채팅방 id**. 이 화면의 `roomId` 가 그것이면 헤더에
///   「매칭 화면으로 →」가 뜨고 「나가기」가 사라진다 — 판정의 1순위 근거다(`ChatRoom.isActiveParty`).
/// - `activePartyId`: 진행 중인 방 id. 이 경로의 `ChatRoom` 은 방 상세에서 온 **진짜** partyId 를
///   들고 있어 보조 근거가 된다(채팅방 id 를 아직 못 찾은 구간을 메운다).
///   뒤로가기로도 돌아갈 수 있지만, 채팅방에 오래 머문 뒤에는 「어디로 돌아가는 뒤로가기인지」가
///   사라진다 — 이름 붙은 길을 함께 둔다.
public struct ChatRoomDestinationRoute: View {
    private let repository: any ChatRepository
    private let roomId: Int64
    private let activeChatRoomId: Int64?
    private let activePartyId: String?
    private let onBack: () -> Void
    private let onOpenMatching: () -> Void
    private let onOpenRideOngoing: () -> Void
    private let onLeaveChat: () -> Void
    private let onTabSelect: (MoyeotaTab) -> Void
    private let onNotParticipant: () -> Void

    @HostedViewModel private var viewModel: ChatRoomViewModel

    @State private var room: ChatRoom?
    @State private var failure: String?
    // 「다시 시도」로 같은 roomId 를 한 번 더 읽기 위한 손잡이 — key 가 같으면 task 가 다시 돌지 않는다
    @State private var retryKey = 0

    /// - Parameter onNotParticipant: 이 방에 참여자가 아니라는 403 — 진행 화면이 들고 있던 채팅방 id 캐시를 버리게 한다
    public init(
        repository: any ChatRepository,
        roomId: Int64,
        activeChatRoomId: Int64? = nil,
        activePartyId: String? = nil,
        onBack: @escaping () -> Void = {},
        onOpenMatching: @escaping () -> Void = {},
        onOpenRideOngoing: @escaping () -> Void = {},
        onLeaveChat: @escaping () -> Void = {},
        onTabSelect: @escaping (MoyeotaTab) -> Void = { _ in },
        onNotParticipant: @escaping () -> Void = {}
    ) {
        self.repository = repository
        self.roomId = roomId
        self.activeChatRoomId = activeChatRoomId
        self.activePartyId = activePartyId
        self.onBack = onBack
        self.onOpenMatching = onOpenMatching
        self.onOpenRideOngoing = onOpenRideOngoing
        self.onLeaveChat = onLeaveChat
        self.onTabSelect = onTabSelect
        self.onNotParticipant = onNotParticipant
        _viewModel = HostedViewModel(wrappedValue: ChatRoomViewModel(repository: repository))
    }

    private struct LoadKey: Equatable {
        let roomId: Int64
        let retryKey: Int
    }

    public var body: some View {
        ZStack {
            if let current = room {
                ChatRoomRoute(
                    viewModel: viewModel,
                    room: current,
                    onBack: onBack,
                    onOpenMatching: current.isActiveParty(activeChatRoomId: activeChatRoomId, activePartyId: activePartyId)
                        ? onOpenMatching
                        : nil,
                    onOpenRideOngoing: onOpenRideOngoing,
                    onLeaveChat: onLeaveChat,
                    onTabSelect: onTabSelect,
                    onNotParticipant: onNotParticipant,
                    followsBottomOnOpen: false
                )
            } else if let failure {
                // 탭바가 아니라 뒤로가기가 이 화면의 이동 수단이다 — 어느 상태에서도 원래 화면으로 돌아갈 수 있어야 한다
                BackStateScaffold(title: "채팅", onBack: onBack) {
                    ErrorBox(message: failure, onRetry: { retryKey += 1 })
                }
            } else {
                BackStateScaffold(title: "채팅", onBack: onBack) { LoadingBox() }
            }
        }
        .task(id: LoadKey(roomId: roomId, retryKey: retryKey)) {
            if room?.id == roomId { return }
            failure = nil
            do {
                let loaded = try await repository.getChatRoom(chatRoomId: roomId)
                try Task.checkCancellation()
                room = loaded
            } catch {
                guard let live = chatFailureOnLiveTask(error: error) else { return }
                failure = live.toChatMessage(fallback: "채팅방을 불러오지 못했어요")
            }
        }
    }
}

extension ChatRoom {
    /// 이 채팅방이 **지금 진행 중인 방**의 것인가 — 「매칭 화면으로 →」 배너와 「나가기」 노출을 가르는 판정.
    ///
    /// 기준은 **채팅방 id** 다(`activeChatRoomId`). 예전에는 `ChatRoom.partyId` 와 진행 중인 방 id 를
    /// 비교했는데, 채팅 **탭 목록**에서 연 방은 그 값이 0 이다 — 목록 응답(`GET /chat-rooms/me`)에 partyId 가
    /// 없어 매퍼가 「모른다」로 0 을 채운다(`UNKNOWN_PARTY_ID`). 그래서 목록 경로에서는 판정이 **언제나
    /// 거짓**이었고, 진행 중인 방인데도 배너가 안 뜨고(목록에서 들어온 사용자에게는 그게 유일한 복귀 길이다)
    /// 되돌릴 수 없는 「나가기」가 노출됐다(실기 QA). 채팅방 id 는 두 경로 모두 서버가 준 값이라 믿을 수 있다.
    ///
    /// `activePartyId` 는 **보조 근거**다. 진행 중인 방은 알지만 그 방의 채팅방 id 를 아직 못 찾은 구간이
    /// 있어(`ActivePartyViewModel.pollChatRoom` 이 10초 주기로 찾는다) 그동안에도 단독 목적지 경로는
    /// 판정할 수 있어야 한다 — 그쪽 `ChatRoom` 은 방 상세에서 온 **진짜** partyId 를 들고 있다.
    /// 그래서 partyId 는 `UNKNOWN_PARTY_ID` 가 아닐 때만 본다 — 0 은 「모른다」이고 비교에 쓰면 안 된다.
    ///
    /// 둘 다 모르면 거짓이다. 그래도 「확인 없는 나가기」로는 새지 않는다 — 재확인은 `ChatScreen` 이
    /// **모든 방에** 대해 받는다(나가기는 어느 방에서든 되돌릴 수 없다).
    func isActiveParty(activeChatRoomId: Int64?, activePartyId: String? = nil) -> Bool {
        (activeChatRoomId != nil && id == activeChatRoomId)
            || (activePartyId != nil && partyId != UNKNOWN_PARTY_ID && String(partyId) == activePartyId)
    }
}

/// 목록 응답으로 만든 방의 `partyId` 자리값 — 「모른다」는 뜻이다
/// (데이터 계층의 `UNKNOWN_PARTY_ID` 와 같은 값).
/// 이 값과 **같은지만** 보고, 이 값으로 다른 무엇과 비교하지 않는다.
private let UNKNOWN_PARTY_ID: Int64 = 0

/// 메시지 목록을 id 로 합친다 — 겹치면 **나중에 온 사본(`incoming`)이 이긴다.**
///
/// 예전에는 `(held + incoming).distinctBy { it.id }` 였는데 `distinctBy` 는 **먼저 등장한** 쪽을
/// 남긴다. 그래서 동승자가 메시지를 지우면 서버가 **같은 id** 를 `deleted = true`,
/// `content = "삭제된 메시지입니다"` 로 다시 밀어 주는데도(`ChatMessageBroadcaster.onMessageDeleted`)
/// 화면은 삭제 전 사본을 그대로 들고 있었다 — **지운 말이 그대로 남았다.**
///
/// 같은 키에 **나중 값**을 덮어쓴다. 반환 순서는 믿지 않고 마지막에 다시
/// id 오름차순으로 정렬한다(말풍선 순서는 이 정렬이 유일한 근거다).
func mergeMessagesById(held: [ChatMessage], incoming: [ChatMessage]) -> [ChatMessage] {
    var byId: [Int64: ChatMessage] = [:]
    for message in held + incoming {
        byId[message.id] = message
    }
    return byId.values.sorted { $0.id < $1.id }
}

extension ChatMessage {
    /// 서버 메시지 → 화면 표시 모델.
    ///
    /// "내 메시지" 판정은 Repository 가 계산한 isMine 을 그대로 믿는다(토큰 주체 기준).
    /// 발신자 닉네임이 아직 없는 응답은 "동승자" 로 표기한다.
    ///
    /// `imageUrls`: 참여자 조회로 세운 `publicId → 사진` 사전(`chatMemberImageUrls`). 메시지에는
    /// 사진이 실려 오지 않아 이것 말고는 얼굴을 알 길이 없다. 내 말풍선에는 아바타 자리가 없어
    /// 내 메시지는 찾아보지 않고, 사전에 없는 발신자(탈퇴·신원 누락)는 회색 원으로 떨어진다.
    func toUiMessage(imageUrls: [String: String]) -> ChatUiMessage {
        ChatUiMessage(
            text: content,
            isMine: isMine,
            senderName: isMine ? nil : (senderName ?? PEER_FALLBACK_NAME),
            timeLabel: createdAt.toTimeLabel(),
            senderImageUrl: isMine ? nil : senderPublicId.flatMap { imageUrls[$0] },
            // 신고가 서버에 보낼 `chatMessageId` 다. 서버에서 온 메시지에는 **항상** 있다.
            id: id
        )
    }
}

extension ChatRoomViewModel.PendingMessage {
    // 확인을 기다리는(또는 실패한) 내 메시지 → 말풍선. 시간 대신 상태를 메타로 보여 준다.
    // id 를 싣지 않는다(= NO_SERVER_MESSAGE_ID) — 서버 id 가 아직 없다. 내 메시지라 신고 길도
    // 애초에 안 생기지만, 음수 localId 를 그 자리에 넣으면 「id 가 있다」로 보여 판정이 갈린다.
    fileprivate func toUiMessage() -> ChatUiMessage {
        ChatUiMessage(
            text: content,
            isMine: true,
            meta: failed ? PENDING_FAILED_LABEL : PENDING_LABEL
        )
    }
}

/// 서버에서 돌아온 메시지와 짝지어진 대기 말풍선을 걷어낸다.
///
/// 짝의 조건은 **내 메시지 + 보낸 뒤에 생긴 id + 같은 내용**이다. id 조건이 없으면 예전에 보낸 같은 문장
/// (“네”, “도착했어요”)이 확인으로 오해된다. 같은 문장을 연달아 두 번 보낼 수도 있으므로
/// 서버 메시지 하나는 대기 하나만 지운다.
func reconcilePending(
    messages: [ChatMessage],
    pending: [ChatRoomViewModel.PendingMessage]
) -> [ChatRoomViewModel.PendingMessage] {
    if pending.isEmpty { return pending }
    var matched = Set<Int64>()
    return pending.filter { waiting in
        let echo = messages.first { message in
            message.isMine
                && message.id > waiting.sinceId
                && message.content == waiting.content
                && !matched.contains(message.id)
        }
        if let echo { matched.insert(echo.id) }
        return echo == nil
    }
}

/// `failureOnLiveTask` 의 채팅 판. 원본 `chatCall` 처럼 살아 있는 태스크의 `URLError(.cancelled)` 를 네트워크 실패로 옮긴다.
/// 끝내 버리면 신고는 「보내는 중」에 잠기고, 목록·대화·첫 검색은 재시도 버튼 없는 스피너에 머문다.
func chatFailureOnLiveTask(error: any Error) -> (any Error)? {
    failureOnLiveTask(error: error) { ChatException(code: nil, serverMessage: nil, isNetwork: true, cause: $0) }
}

extension Error {
    /// 신고 실패 → **문구 + 시트를 열어 둘지**.
    ///
    /// `retryable` 이 정하는 것은 하나뿐이다: 같은 내용으로 **다시 보내서 달라질 수 있는가.**
    /// - 연결 실패만 참이다. 그래서 적어 둔 상세를 들고 시트가 열려 있는다.
    /// - 「이미 신고한 메시지」는 거짓이다 — 사유를 바꿔 보내도 같은 409 다(실측). 열어 두면
    ///   사용자가 빠져나갈 수 없는 시트에 갇힌다.
    /// - 참여자 아님·메시지 없음·본인 신고도 거짓이다. 재시도가 아니라 **대상이 틀렸다**는 뜻이라
    ///   다시 눌러 봐야 같은 답이다.
    ///
    /// `INVALID_REQUEST` 의 서버 message 는 필드명을 담고 있어(「chatMessageId: 메시지 ID는 1 이상…」)
    /// **그대로 보여 주지 않는다** — 그 상태는 화면이 전송 버튼으로 미리 막는 것이므로, 여기까지
    /// 왔다면 막는 쪽이 틀린 것이고 사용자에게는 「보낼 수 없었다」만 말한다.
    func toChatReportOutcome() -> ChatReportOutcome {
        guard let chat = self as? ChatException else {
            return ChatReportOutcome(message: "신고를 보내지 못했어요", accepted: false, retryable: true)
        }
        if chat.isAlreadyReported {
            return ChatReportOutcome(message: "이미 신고한 메시지예요", accepted: false)
        }
        if chat.isCannotReportSelf {
            return ChatReportOutcome(message: "내가 보낸 메시지는 신고할 수 없어요", accepted: false)
        }
        if chat.isMessageNotFound {
            return ChatReportOutcome(message: "메시지를 찾을 수 없어요. 이미 지워졌을 수 있어요", accepted: false)
        }
        if chat.isNotParticipant {
            return ChatReportOutcome(message: "이 방의 참여자가 아니라 신고할 수 없어요", accepted: false)
        }
        if chat.isReportDescriptionRequired {
            return ChatReportOutcome(message: "「그 밖의 이유예요」는 상세 내용을 적어야 보낼 수 있어요", accepted: false, retryable: true)
        }
        if chat.isInvalidRequest {
            return ChatReportOutcome(message: "신고 내용을 보낼 수 없어요. 사유를 다시 골라 주세요", accepted: false, retryable: true)
        }
        if chat.isNetwork {
            return ChatReportOutcome(message: "연결이 끊겼어요. 잠시 뒤 다시 시도해 주세요", accepted: false, retryable: true)
        }
        // 남는 것은 토큰 만료(401)·서버 오류(5xx) 같은 「다음에 되는」 실패다.
        return ChatReportOutcome(message: "신고를 보내지 못했어요", accepted: false, retryable: true)
    }

    // 채팅 서버 실패 → 사용자 문구. 코드 문자열 비교는 도메인(ChatException)에 두고
    // 화면은 의미만 본다. 매핑이 없는 실패는 호출부의 기본 문구를 쓴다.
    fileprivate func toChatMessage(fallback: String) -> String {
        guard let chat = self as? ChatException else { return fallback }
        if chat.isNotParticipant { return "이 채팅방에 참여하고 있지 않아요" }
        if chat.isRoomClosed { return "종료된 채팅방이에요" }
        return fallback
    }
}

// ─── 서버 시각 ───────────────────────────────────────────────────────────────

/// `java.time.Instant` 자리. `Date` 는 초를 `Double` 로 들고 있어 밀리초로 내릴 때 1ms 어긋날 수 있다
/// (정렬 키·표시 모두 원본과 같은 값을 내야 한다).
struct ChatInstant: Equatable, Sendable {
    let epochSecond: Int64
    let nano: Int

    /// 표현 범위를 넘으면 nil 이다. 원본은 `ArithmeticException` 이지만 그런 연도의 응답으로 화면이 죽을 이유가 없다.
    var epochMillis: Int64? {
        let (millis, overflow) = epochSecond.multipliedReportingOverflow(by: 1_000)
        if overflow { return nil }
        return millis + Int64(nano / 1_000_000)
    }

    /// 기기 시간대의 달력 값. java.time 과 같이 그레고리력을 과거로 그대로 늘린 달력이다.
    func local(zone: TimeZone) -> ChatLocalDateTime {
        let probe = Date(timeIntervalSince1970: TimeInterval(epochSecond))
        let seconds = epochSecond + Int64(zone.secondsFromGMT(for: probe))
        let days = floorDiv(seconds, 86_400)
        let secondOfDay = seconds - days * 86_400
        let (year, month, day) = civilFromDays(days)
        return ChatLocalDateTime(
            year: year,
            month: month,
            day: day,
            hour: Int(secondOfDay / 3_600),
            minute: Int(secondOfDay % 3_600 / 60)
        )
    }
}

struct ChatLocalDateTime: Equatable, Sendable {
    let year: Int64
    let month: Int
    let day: Int
    let hour: Int
    let minute: Int
}

private func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
    let quotient = a / b
    return (a % b != 0 && (a < 0) != (b < 0)) ? quotient - 1 : quotient
}

/// 1970-01-01 부터의 일 수 ← 달력 날짜 (Howard Hinnant `days_from_civil`).
private func daysFromCivil(year: Int64, month: Int, day: Int) -> Int64 {
    let y = month <= 2 ? year - 1 : year
    let era = floorDiv(y, 400)
    let yearOfEra = y - era * 400
    let shiftedMonth = Int64(month > 2 ? month - 3 : month + 9)
    let dayOfYear = (153 * shiftedMonth + 2) / 5 + Int64(day) - 1
    let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
    return era * 146_097 + dayOfEra - 719_468
}

/// 달력 날짜 ← 1970-01-01 부터의 일 수 (Howard Hinnant `civil_from_days`).
private func civilFromDays(_ days: Int64) -> (year: Int64, month: Int, day: Int) {
    let shifted = days + 719_468
    let era = floorDiv(shifted, 146_097)
    let dayOfEra = shifted - era * 146_097
    let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
    let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
    let shiftedMonth = (5 * dayOfYear + 2) / 153
    let day = Int(dayOfYear - (153 * shiftedMonth + 2) / 5 + 1)
    let month = Int(shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9)
    let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
    return (year, month, day)
}

private func daysInMonth(year: Int64, month: Int) -> Int {
    switch month {
    case 2:
        let leap = (year % 4 == 0) && (year % 100 != 0 || year % 400 == 0)
        return leap ? 29 : 28
    case 4, 6, 9, 11:
        return 30
    default:
        return 31
    }
}

/// `Instant.parse` 실패 시 `OffsetDateTime.parse` 로 넘어가는 원본의 두 단계를 한 번에 받는 해석기.
/// `ISO8601DateFormatter` 는 소수 초 유무를 옵션으로 갈라야 하고 자릿수·소문자·오프셋 초 처리도 달라 쓰지 않는다.
///
/// 받는 꼴(JDK `Instant.parse` · `OffsetDateTime.parse` 와 대조해 `ServerInstantParseTest` 에 못 박았다):
/// `연-월-일 T 시:분[:초[.소수 0~9자리]] (Z | ±시[:분[:초]])`, `T`·`Z` 는 소문자도 된다.
/// 연도는 부호 없이 4자리, `+` 면 5자리 이상, `-` 면 4자리 이상이다. `24:00:00`(다음 날 0시)과 `23:59:60`(윤초)을 받는다.
private struct InstantScanner {
    private let bytes: [UInt8]
    private var index = 0

    init(_ text: String) {
        bytes = Array(text.utf8)
    }

    private var isAtEnd: Bool { index >= bytes.count }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard !isAtEnd, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    private mutating func consumeIgnoringCase(_ upper: UInt8) -> Bool {
        consume(upper) || consume(upper + 32)
    }

    /// 숫자 정확히 `count` 자리.
    private mutating func digits(_ count: Int) -> Int? {
        guard index + count <= bytes.count else { return nil }
        var value = 0
        for offset in 0..<count {
            let byte = bytes[index + offset]
            guard byte >= 0x30, byte <= 0x39 else { return nil }
            value = value * 10 + Int(byte - 0x30)
        }
        index += count
        return value
    }

    private mutating func digitRun() -> [UInt8] {
        let start = index
        while !isAtEnd, bytes[index] >= 0x30, bytes[index] <= 0x39 {
            index += 1
        }
        return Array(bytes[start..<index])
    }

    private mutating func year() -> Int64? {
        let negative = consume(0x2D)
        let positive = !negative && consume(0x2B)
        let run = digitRun()
        if positive {
            guard run.count >= 5 else { return nil }
        } else if negative {
            guard run.count >= 4 else { return nil }
        } else {
            guard run.count == 4 else { return nil }
        }
        // java.time 의 연도 범위(±999,999,999)
        guard run.count <= 9 else { return nil }
        let value = run.reduce(Int64(0)) { $0 * 10 + Int64($1 - 0x30) }
        return negative ? -value : value
    }

    /// `Z` 또는 `±시[:분[:초]]` → 초. 범위는 `ZoneOffset` 과 같이 ±18:00 이다.
    private mutating func offsetSeconds() -> Int? {
        if consumeIgnoringCase(0x5A) { return 0 }
        let sign: Int
        if consume(0x2B) {
            sign = 1
        } else if consume(0x2D) {
            sign = -1
        } else {
            return nil
        }
        guard let hours = digits(2) else { return nil }
        var minutes = 0
        var seconds = 0
        if consume(0x3A) {
            guard let parsedMinutes = digits(2), parsedMinutes <= 59 else { return nil }
            minutes = parsedMinutes
            if consume(0x3A) {
                guard let parsedSeconds = digits(2), parsedSeconds <= 59 else { return nil }
                seconds = parsedSeconds
            }
        }
        let total = hours * 3_600 + minutes * 60 + seconds
        guard total <= 18 * 3_600 else { return nil }
        return sign * total
    }

    mutating func parse() -> ChatInstant? {
        guard let year = year(), consume(0x2D),
              let month = digits(2), (1...12).contains(month), consume(0x2D),
              let day = digits(2), day >= 1, day <= daysInMonth(year: year, month: month),
              consumeIgnoringCase(0x54),
              let hour = digits(2), consume(0x3A),
              let minute = digits(2)
        else { return nil }

        var second = 0
        var nano = 0
        var hasSeconds = false
        if consume(0x3A) {
            guard let parsedSecond = digits(2) else { return nil }
            second = parsedSecond
            hasSeconds = true
            if consume(0x2E) {
                let fraction = digitRun()
                guard fraction.count <= 9 else { return nil }
                nano = fraction.reduce(0) { $0 * 10 + Int($1 - 0x30) }
                for _ in fraction.count..<9 {
                    nano *= 10
                }
            }
        }
        guard let offset = offsetSeconds(), isAtEnd else { return nil }

        var dayCarry: Int64 = 0
        var resolvedHour = hour
        var resolvedSecond = second
        if hour == 24, minute == 0, second == 0, nano == 0, hasSeconds {
            // `Instant.parse` 는 하루의 끝 24:00:00 을 다음 날 0시로 받는다.
            resolvedHour = 0
            dayCarry = 1
        } else if hour == 23, minute == 59, second == 60 {
            // 윤초 — `Instant.parse` 는 59초로 접는다.
            resolvedSecond = 59
        } else {
            guard hour <= 23, minute <= 59, second <= 59 else { return nil }
        }

        let days = daysFromCivil(year: year, month: month, day: day) + dayCarry
        let secondOfDay = Int64(resolvedHour * 3_600 + minute * 60 + resolvedSecond)
        return ChatInstant(epochSecond: days * 86_400 + secondOfDay - Int64(offset), nano: nano)
    }
}

extension String {
    /// 서버 ISO-8601(Instant 또는 오프셋 표기) → Instant. 그 외 형식은 nil.
    func toInstantOrNull() -> ChatInstant? {
        var scanner = InstantScanner(self)
        return scanner.parse()
    }

    func toEpochMillisOrNull() -> Int64? {
        toInstantOrNull()?.epochMillis
    }

    /// 채팅 **목록**의 시각 표기 — 오늘이면 `HH:mm`, 올해면 `M월 d일`, 그 전이면 `yyyy.M.d`.
    /// 말풍선(`toTimeLabel`)과 달리 날짜가 필요하다 — 목록에서 「17:36」만 보면 어제인지 지난주인지 모른다.
    /// 파싱이 안 되면 nil(그 칸을 비운다 — 틀린 시각보다 없는 편이 낫다).
    func toListTimeLabel(now: Date = Date(), zone: TimeZone = .current) -> String? {
        guard let at = toInstantOrNull()?.local(zone: zone) else { return nil }
        let today = ChatInstant(epochSecond: Int64(now.timeIntervalSince1970.rounded(.down)), nano: 0).local(zone: zone)
        if at.year == today.year, at.month == today.month, at.day == today.day {
            return twoDigitTime(hour: at.hour, minute: at.minute)
        }
        if at.year == today.year {
            return "\(at.month)월 \(at.day)일"
        }
        return "\(at.year).\(at.month).\(at.day)"
    }

    // createdAt 은 서버가 UTC 기준으로 내려주는 ISO-8601 문자열이다.
    // 문자열을 그대로 자르면 KST 17:36 이 08:36 으로 보인다(QA 결함-3) — 기기 시간대로 변환해 HH:mm 만 쓴다.
    // 파싱할 수 없는 형식(오프셋 없는 LocalDateTime 등)이면 예전처럼 잘라 쓴다 — 화면은 살아야 한다.
    func toTimeLabel(zone: TimeZone = .current) -> String? {
        if let local = toInstantOrNull()?.local(zone: zone) {
            return twoDigitTime(hour: local.hour, minute: local.minute)
        }
        // Kotlin `substringAfter('T', "").take(5)` — 첫 'T' 뒤의 앞 다섯 UTF-16 칸.
        let units = Array(utf16)
        guard let separator = units.firstIndex(of: 0x54) else { return nil }
        let time = units[(separator + 1)...].prefix(5)
        guard time.count == 5 else { return nil }
        return String(decoding: time, as: UTF16.self)
    }
}

private func twoDigitTime(hour: Int, minute: Int) -> String {
    String(format: "%02d:%02d", hour, minute)
}
