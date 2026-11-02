import MoyeotaDomain
import Testing
@testable import MoyeotaData

/// `GET /api/v1/users/me/parties` 저장소.
///
/// 이 저장소가 하는 일은 둘뿐이다 — **쿼리를 그대로 넘기는 것**과 **세션 uuid 로 「나」를 만드는 것**.
/// 그래서 테스트도 그 둘과, 이 저장소에서 가장 비싼 사고(취소를 에러로 바꾸기)만 본다.
@Suite struct RemoteRideRecordRepositoryTest {

    private func session(_ uuid: String? = "me-uuid") -> any UserSession {
        StubUserSession(uuid: uuid)
    }

    private func page(
        _ records: [RideRecordResponse],
        nextCursor: Int64? = nil,
        hasNext: Bool = false
    ) -> RideRecordPageResponse {
        RideRecordPageResponse(rides: records, nextCursor: nextCursor, hasNext: hasNext)
    }

    private func record(_ partyId: Int64, memberUuid: String?) -> RideRecordResponse {
        RideRecordResponse(
            partyId: partyId,
            departure: "강남역",
            destination: "판교역",
            pickupTime: "2026-10-31T19:15:17.550211Z",
            dropoffTime: "2026-10-31T19:15:17.571486Z",
            totalFare: 16500,
            farePerPerson: 16500,
            currentMembers: 1,
            members: [RideRecordMemberResponse(publicId: memberUuid, nickname: "프로브9911")]
        )
    }

    @Test("페이지를 그대로 도메인으로 옮긴다")
    func mapsPage() async throws {
        let api = FakeRideRecordUserApi(page([record(69, memberUuid: "me-uuid")], nextCursor: 69, hasNext: true))
        let repository = RemoteRideRecordRepository(api: api, session: session())

        let result = try await repository.getMyRecords()

        #expect(result.records.map(\.partyId) == [69])
        #expect(result.nextCursor == 69)
        #expect(result.hasNext)
        #expect(result.records.count == 1)
        #expect(result.records.first?.farePerPerson == 16500)
    }

    /// 커서·개수를 저장소가 다듬지 않는다. 서버 범위는 1~50 이고 밖이면 400 `INVALID_PAGE_SIZE` 다.
    @Test("커서와 개수를 서버에 그대로 넘긴다")
    func passesCursorAndSize() async throws {
        let api = FakeRideRecordUserApi(page([]))
        let repository = RemoteRideRecordRepository(api: api, session: session())

        _ = try await repository.getMyRecords(cursor: 69, size: 1)

        #expect(api.calls.value == [RecordQuery(cursor: 69, size: 1)])
    }

    /// 인자 없이 부르면 서버 기본값과 같은 20 이 나간다 — 0·100 이 새면 목록이 통째로 빈다.
    @Test("기본 조회 개수는 서버 기본값과 같은 20 이다")
    func defaultPageSize() async throws {
        let api = FakeRideRecordUserApi(page([]))
        let repository = RemoteRideRecordRepository(api: api, session: session())

        _ = try await repository.getMyRecords()

        #expect(api.calls.value == [RecordQuery(cursor: nil, size: 20)])
        #expect(RideRecordRepositoryDefaults.DEFAULT_PAGE_SIZE == 20)
    }

    /// 서버가 `isMe` 를 주지 않으므로 세션 uuid 가 그 판정의 유일한 근거다.
    @Test("세션 uuid 와 같은 멤버를 나로 표시한다")
    func marksMe() async throws {
        let api = FakeRideRecordUserApi(page([record(69, memberUuid: "me-uuid")]))
        let repository = RemoteRideRecordRepository(api: api, session: session("me-uuid"))

        let records = try await repository.getMyRecords().records

        #expect(records.count == 1)
        #expect(records.first?.members.count == 1)
        #expect(records.first?.members.first?.isMe == true)
    }

    /// 미로그인이면 전원 false — 요약 없는 멤버가 「나」로 넘어오는 경로까지 막는다.
    @Test("미로그인 세션에서는 아무도 나로 표시되지 않는다")
    func nobodyIsMeWhenLoggedOut() async throws {
        let api = FakeRideRecordUserApi(page([record(69, memberUuid: nil)]))
        let repository = RemoteRideRecordRepository(api: api, session: session(nil))

        let records = try await repository.getMyRecords().records

        #expect(records.count == 1)
        #expect(records.first?.members.count == 1)
        #expect(records.first?.members.first?.isMe == false)
    }

    /// 취소를 에러로 바꾸면 **화면 이탈이 에러 문구로 보인다**(이 저장소 전반의 규칙).
    /// 이 저장소는 `do`/`catch` 를 아예 두지 않는 쪽으로 그 규칙을 지키는데, 나중에 누군가
    /// 「에러 메시지를 예쁘게」 하려고 일반 `catch` 를 두면 이 테스트가 먼저 깨진다.
    @Test("취소는 삼키지 않고 다시 던진다")
    func cancellationPropagates() async {
        let api = FakeRideRecordUserApi(page([]), failure: CancellationError())
        let repository = RemoteRideRecordRepository(api: api, session: session())

        await #expect(throws: CancellationError.self, "취소가 다른 예외로 바뀌었다") {
            try await repository.getMyRecords()
        }
    }

    /// ★ 이번 조사의 결론을 구조로 못 박는다 — **탑승 기록은 「지금 내가 타고 있는 방」을 대신하지 않는다.**
    ///
    /// 실측(2026-11-01, 로컬 `:8080`): 내가 유일 멤버인 `status=MATCHING` 방을 하나 들고
    /// `GET /api/v1/users/me/parties` 를 불러도 `{"rides":[],"nextCursor":null,"hasNext":false}` 였다.
    /// 서버가 하차 시각이 찍힌 기록만 거르기 때문이다(`dropoffTime is not null`).
    ///
    /// 다음 사람이 경로 이름(`users/me/parties`)만 보고 「내 방 목록」으로 읽어
    /// `ActivePartyRepository` 의 로컬 기억을 이것으로 걷어내려 할 확률이 높다. 그러면
    /// **진행 중인 방을 전부 잃는다** — 홈·탐색 배너가 사라지고, 매칭 화면 복귀가 끊기고,
    /// 채팅방 탐색 게이트가 `ride == nil` 에서 멈춰 「채팅 열기」가 영영 안 뜬다.
    ///
    /// 그래서 두 타입이 **서로를 모르는 것**을 값으로 확인한다. 엮으려면 이 테스트를 먼저 지워야 하고,
    /// 지우려면 위 실측을 읽게 된다.
    ///
    /// Swift 에는 `Class.isAssignableFrom` 이 없어, 한쪽 프로토콜만 채택한 타입이 다른 쪽으로 보이는지로 잰다.
    /// 프로토콜을 잇는 순간 스텁이 컴파일되지 않거나 이 단언이 깨진다.
    @Test("탑승 기록은 진행 중인 방을 대신하지 않는다")
    func rideRecordsAreNotActiveParty() {
        let rideRecord: Any = StubRideRecordRepository()
        let activeParty: Any = StubActivePartyRepository()
        #expect(
            !(rideRecord is any ActivePartyRepository),
            "RideRecordRepository 가 ActivePartyRepository 로 넘어갔다 — 진행 중인 방은 이 응답에 없다"
        )
        #expect(
            !(activeParty is any RideRecordRepository),
            "ActivePartyRepository 가 RideRecordRepository 를 상속했다 — 두 계약을 섞으면 안 된다"
        )

        // 구현도 진행 중 방 쪽을 주입받지 않는다. 생성자 인자는 UserApi + UserSession 둘뿐이다.
        let constructor: (any UserApi, any UserSession) -> RemoteRideRecordRepository =
            RemoteRideRecordRepository.init(api:session:)
        let stored = Mirror(reflecting: constructor(FakeRideRecordUserApi(page([])), session())).children.map(\.value)
        #expect(stored.count == 2)
        #expect(stored.first is any UserApi)
        #expect(stored.last is any UserSession)
    }

    /// 기록이 없는 계정(실측: `moyeota2`)에서 빈 페이지가 예외 없이 나와야 한다.
    @Test("기록이 없으면 빈 페이지를 돌려준다")
    func emptyPage() async throws {
        let api = FakeRideRecordUserApi(page([]))
        let repository = RemoteRideRecordRepository(api: api, session: session())

        let result = try await repository.getMyRecords()

        #expect(result.records.isEmpty)
        #expect(!result.hasNext)
        #expect(result.nextCursor == nil)
    }
}

private struct StubUserSession: UserSession {
    let authState: StateFlow<AuthState>

    init(uuid: String?) {
        authState = MutableStateFlow<AuthState>(uuid.map { .authenticated(userUuid: $0) } ?? .unauthenticated)
    }
}

private struct StubRideRecordRepository: RideRecordRepository {
    func getMyRecords(cursor: Int64?, size: Int) async throws -> RideRecordPage {
        throw IllegalStateException("이 테스트에서 부를 일이 없다")
    }
}

private struct StubActivePartyRepository: ActivePartyRepository {
    func remember(partyId: String) async throws {}
    func clear() async throws {}
    func resolve() async throws -> Ride? { nil }
}

private struct RecordQuery: Equatable, Sendable {
    let cursor: Int64?
    let size: Int
}

/// 탑승 기록만 돌려주는 가짜 `UserApi`. 나머지 메서드는 이 테스트의 관심이 아니라 부르면 터진다
/// — 조용히 기본값을 돌려주면 「저장소가 엉뚱한 호출을 하고 있다」를 못 잡는다.
private final class FakeRideRecordUserApi: UserApi {
    private let page: RideRecordPageResponse
    private let failure: (any Error)?

    /// 나간 호출의 `(cursor, size)`. 저장소가 값을 다듬지 않는지 보는 자리다.
    let calls = Locked<[RecordQuery]>([])

    init(_ page: RideRecordPageResponse, failure: (any Error)? = nil) {
        self.page = page
        self.failure = failure
    }

    func getMyRideRecords(cursor: Int64?, size: Int) async throws -> RideRecordPageResponse {
        calls.append(RecordQuery(cursor: cursor, size: size))
        if let failure { throw failure }
        return page
    }

    func getMyProfile() async throws -> UserProfileResponse { throw IllegalStateException("이 테스트에서 부를 일이 없다") }
    func updateProfile(request: UpdateProfileRequest) async throws { throw IllegalStateException("이 테스트에서 부를 일이 없다") }
    func getProfileImages() async throws -> [ProfileImageResponse] { throw IllegalStateException("이 테스트에서 부를 일이 없다") }
    func resetProfileImage() async throws { throw IllegalStateException("이 테스트에서 부를 일이 없다") }
    func registerFcmToken(request: FcmTokenRequest) async throws { throw IllegalStateException("이 테스트에서 부를 일이 없다") }
    func deleteFcmToken() async throws { throw IllegalStateException("이 테스트에서 부를 일이 없다") }
    func deleteAccount(request: AccountDeletionRequest) async throws { throw IllegalStateException("이 테스트에서 부를 일이 없다") }
}
