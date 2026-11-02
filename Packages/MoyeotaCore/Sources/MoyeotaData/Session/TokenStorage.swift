/// 디스크에 남기는 세션 한 벌. 셋 중 하나라도 없으면 세션이 성립하지 않으므로 통째로 다룬다.
public struct StoredSession: Equatable, Sendable {
    public var userUuid: String
    public var accessToken: String
    public var refreshToken: String

    public init(userUuid: String, accessToken: String, refreshToken: String) {
        self.userUuid = userUuid
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }
}

/// 세션 영속화 경계. 구현체 교체와 테스트용 가짜를 위해 프로토콜로 둔다.
public protocol TokenStorage: Sendable {
    /// 저장된 세션이 없거나 일부만 남아 깨졌으면 null.
    func load() async throws -> StoredSession?

    func save(session: StoredSession) async throws

    func clear() async throws
}
