/// 로컬에 기억해 둔 "진행 중인 방" 한 벌.
///
/// `ownerUuid` 를 함께 적는 게 핵심이다. 기억은 기기가 아니라 **계정**의 것이라,
/// 로그아웃 후 다른 계정으로 로그인했을 때 앞 사람의 방으로 끌려가면 안 된다
/// (`RemoteActivePartyRepository` 가 uuid 로 가드한다).
public struct RememberedParty: Equatable, Sendable {
    public var partyId: String
    public var ownerUuid: String

    public init(partyId: String, ownerUuid: String) {
        self.partyId = partyId
        self.ownerUuid = ownerUuid
    }
}

/// `RememberedParty` 영속 창구. 토큰의 `TokenStorage` 와 같은 모양이며,
/// 테스트가 디스크 없이 인메모리 구현으로 갈아끼울 수 있게 프로토콜로 둔다.
public protocol ActivePartyStorage: Sendable {
    /// 기억이 없거나 반쪽(둘 중 하나가 빔)이면 null.
    func load() async throws -> RememberedParty?

    func save(party: RememberedParty) async throws

    func clear() async throws
}
