/// "지금 내가 타고 있는 방"의 단일 출처.
///
/// 백엔드에 `GET /matching/rooms/me` 가 없다 — 서버에 물어 "내 진행 중인 방"을 바로 받을 수 없으므로
/// 앱이 방 id 를 **로컬에 기억**했다가 상세 조회로 되살린다. 기억은 어디까지나 힌트이고,
/// 진실은 언제나 서버 상세 응답이다(`resolve` 가 매번 검증한다).
///
/// 기억을 심고 지우는 시점은 **호출부(ViewModel)** 의 몫이다 — `RideRepository` 안에서 몰래
/// 부수효과를 내면 "왜 여기서 방 id 가 저장되지" 를 추적할 수 없게 된다.
/// - 방 생성 성공(`createParty`) 직후 → `remember`
/// - 합류 성공(`joinParty`) 직후 → `remember`
/// - 나가기 성공(`leaveParty`) 직후 → `clear`
public protocol ActivePartyRepository: Sendable {

    /// 진행 중인 방으로 `partyId` 를 기억한다(로컬 저장소 영속 — 앱을 껐다 켜도 남는다).
    /// 기억은 **그때 로그인해 있던 계정의 것**으로 함께 적힌다. 미로그인 상태면 아무것도 하지 않는다.
    func remember(partyId: String) async throws

    /// 기억을 지운다. 나가기 성공·FINISHED/CANCELED 확인 시.
    func clear() async throws

    /// 로컬 기억 → 상세 조회로 검증(내가 멤버 && 진행 중 상태) → 없으면
    /// `GET /chat-rooms/me` 의 partyId 들을 순회해 같은 조건으로 탐색. 못 찾으면 null + 로컬 기억 삭제.
    ///
    /// "진행 중"은 `Ride.status` 가
    /// `recruiting` ·
    /// `matched` ·
    /// `dispatching` ·
    /// `ongoing` 중 하나인 경우다.
    /// (COMPLETED·CANCELED 는 끝난 방이다.)
    ///
    /// **네트워크 실패로는 예외를 던지지 않고 null 을 돌려준다** — 호출부는 배너를 숨기기만 하면 된다.
    /// 다만 그때 기억은 지우지 않는다: 서버에 닿지 못한 것과 방이 끝난 것은 다르다.
    func resolve() async throws -> Ride?
}
