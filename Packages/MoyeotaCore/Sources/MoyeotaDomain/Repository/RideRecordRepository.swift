/// 끝난 탑승의 기록만 다룬다 — `GET /api/v1/users/me/parties`.
///
/// ### `RideRepository` 에 끼워 넣지 않은 이유
/// `RideRepository` 는 **진행 중인 방**(상세·생성·합류·나가기)을 다룬다. 섞으면 호출부가 매번
/// 「이 Repository 가 주는 방이 진행 중인지 끝난 건지」를 되물어야 하고, 경로 이름이
/// `users/me/parties` 라 「내 방 목록」으로 읽히는 만큼 그 혼동은 실제로 일어난다.
///
/// ### `ActivePartyRepository` 를 대체하지 않는다
/// 이 엔드포인트에는 **진행 중인 방이 들어오지 않는다.** 실측(2026-11-01, 로컬 `:8080`):
/// 내가 유일 멤버인 `status=MATCHING` 방을 하나 들고 불러도
/// `{"rides":[],"nextCursor":null,"hasNext":false}` 였다. 서버가 하차 시각이 찍힌 기록만 거르기
/// 때문이다. 「지금 내가 타고 있는 방」은 여전히 `ActivePartyRepository` 의 로컬 기억 + 상세 조회로만
/// 알 수 있고, 그 공백은 서버에 `GET /matching/rooms/me` 가 생겨야 메워진다.
///
/// **그래서 이 계약은 `ActivePartyRepository` 를 참조하지 않고, 그쪽도 이쪽을 참조하지 않는다.**
/// 이 엔드포인트로 로컬 기억을 걷어내려 하면 진행 중인 방을 전부 잃는다 — 홈·탐색 배너가 사라지고
/// 매칭 화면 복귀가 끊긴다.
public protocol RideRecordRepository: Sendable {

    /// 내 탑승 기록 한 페이지. `cursor` 가 null 이면 첫 페이지, `size` 범위는 **1~50**.
    ///
    /// 다음 페이지는 응답의 `hasNext` 가 true 일 때만 `nextCursor` 로 부른다. false 인데 부르면
    /// 커서 없이 첫 페이지를 다시 받아 목록이 무한히 중복된다.
    func getMyRecords(cursor: Int64?, size: Int) async throws -> RideRecordPage
}

/// Kotlin `RideRecordRepository.Companion` 의 자리. Swift 프로토콜은 메타타입에서 정적 멤버를 꺼낼 수 없어
/// (`RideRecordRepository.DEFAULT_PAGE_SIZE` 가 안 된다) 값을 여기 둔다. 구현 타입에서는 `Self.DEFAULT_PAGE_SIZE` 로도 읽는다.
public enum RideRecordRepositoryDefaults {
    /// 서버 기본값과 같은 값. 1~50 밖이면 400 `INVALID_PAGE_SIZE` 다(실측).
    public static let DEFAULT_PAGE_SIZE = 20
}

// Kotlin 인터페이스의 기본 인자 자리.
extension RideRecordRepository {
    public static var DEFAULT_PAGE_SIZE: Int { RideRecordRepositoryDefaults.DEFAULT_PAGE_SIZE }

    public func getMyRecords(cursor: Int64? = nil) async throws -> RideRecordPage {
        try await getMyRecords(cursor: cursor, size: RideRecordRepositoryDefaults.DEFAULT_PAGE_SIZE)
    }

    public func getMyRecords(size: Int) async throws -> RideRecordPage {
        try await getMyRecords(cursor: nil, size: size)
    }
}
