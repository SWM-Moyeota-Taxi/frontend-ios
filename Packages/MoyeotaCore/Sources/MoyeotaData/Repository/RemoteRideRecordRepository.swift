import MoyeotaDomain

/// `GET /api/v1/users/me/parties` 하나만 읽는 저장소.
///
/// `session` 이 필요한 이유는 조회가 아니라 **번역**이다 — 서버가 멤버마다 `isMe` 를 주지 않으므로
/// 매퍼가 `publicId == currentUserUuid` 로 「나」를 만든다. 주체 자체는 Bearer 토큰이 정하므로
/// 요청에는 아무 식별자도 싣지 않는다.
///
/// **`ActivePartyRepository` 를 참조하지 않는다.** 이 응답에는
/// 진행 중인 방이 들어오지 않아(실측 2026-11-01, 로컬 `:8080`: `status=MATCHING` 방을 가진 계정도
/// 빈 배열) 그 로컬 기억을 대체할 수 없다. 둘을 엮으면 진행 중인 방을 전부 잃는다 —
/// 홈·탐색 배너가 사라지고 매칭 화면 복귀가 끊긴다. 이 생성자에 그쪽이 들어오면
/// `RemoteRideRecordRepositoryTest` 가 먼저 깨진다.
public final class RemoteRideRecordRepository: RideRecordRepository {
    private let api: any UserApi
    private let session: any UserSession

    public init(api: any UserApi, session: any UserSession) {
        self.api = api
        self.session = session
    }

    /// **실패를 감싸지 않는다.** 이 화면의 실패 대응이 종류와 무관하게 하나이기 때문이다
    /// (「기록을 불러오지 못했어요 · 다시 시도」). 사유별 문구가 필요한 액션(합류·방 생성·탈퇴)만
    /// 전용 예외로 번역하는 것이 이 저장소의 결이고, 조회는 `RemotePlaceRepository` 처럼 맨몸으로 던진다.
    ///
    /// `do`/`catch` 를 두지 않는 것 자체가 취소 보존 장치다 — 감싸는 순간
    /// 일반 `catch` 가 취소까지 에러로 바꿔 화면 이탈이 에러 문구로 보이게 된다
    /// (이 저장소 전반의 규칙이고, 그래서 다른 저장소들은 자리마다 재던지기 가드를 둔다).
    /// `RemoteRideRecordRepositoryTest` 가 취소 전파를 값으로 못 박는다.
    public func getMyRecords(cursor: Int64?, size: Int) async throws -> RideRecordPage {
        try await api.getMyRideRecords(cursor: cursor, size: size).toRideRecordPage(currentUuid: session.currentUserUuid)
    }
}
