public protocol DispatchRepository: Sendable {
    /// GET /api/v1/dispatch/rides/{partyId} — 나에게 오는 기사의 현재 위치.
    /// "나"는 로그인 토큰이 정한다(@CurrentUser) — memberId 를 넘기지 않는다.
    ///
    /// 서버가 거절하는 경우: 미로그인(401 UNAUTHORIZED) / 내가 그 방의 멤버가 아님 /
    /// 기사 미배정(실측 409 `DRIVER_NOT_ASSIGNED`) /
    /// 기사가 아직 위치를 보고하지 않음("현재 기사님의 위치를 확인할 수 없습니다").
    /// 뒤의 두 경우는 정상 상황이라 폴링 중 간헐적 실패로 취급하고 화면을 에러로 덮지 않는 게 좋다.
    func getDriverLocation(partyId: Int64) async throws -> DriverLocation
}
