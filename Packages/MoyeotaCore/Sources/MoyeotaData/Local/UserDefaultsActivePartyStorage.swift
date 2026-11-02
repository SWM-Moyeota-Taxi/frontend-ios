import Foundation
import MoyeotaDomain

/// `UserDefaults` 기반 "진행 중인 방" 저장소. 원본 `DataStoreActivePartyStorage` 의 자리다.
///
/// 세션과 **저장소를 나눈** 이유: 로그아웃은 세션을 통째로 지우는데, 같은 곳에 방 id 를 두면
/// 그 순간 함께 날아간다. 반대로 방 기억이 세션 수명보다 오래 살아야 할 일도 없지만,
/// 계정 가드는 uuid 비교로 하는 편이 저장소 결합보다 명시적이다.
///
/// 두 값을 사전 하나로 함께 쓴다 — 원본 `dataStore.edit` 처럼 원자적이다. 값 타입이 어긋나 있어도
/// 읽기는 null 일 뿐 던지지 않으므로, 이 저장소를 읽는 앱 시작 경로가 손상으로 죽을 일이 없다.
/// 잃는 것은 진행 중 방 id 하나이고, 그건 서버 조회(`resolve()`)로 되살아난다.
public struct UserDefaultsActivePartyStorage: ActivePartyStorage {
    // `UserDefaults` 는 스레드 안전하다고 문서화돼 있지만 SDK 가 Sendable 로 표시하지 않는다.
    private nonisolated(unsafe) let defaults: UserDefaults

    private static let STORE_KEY = "moyeota_active_party"
    private static let KEY_PARTY_ID = "active_party_id"
    private static let KEY_OWNER_UUID = "active_party_owner_uuid"

    public init() {
        self.init(defaults: .standard)
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func load() -> RememberedParty? {
        let stored = defaults.dictionary(forKey: Self.STORE_KEY)
        // 주인을 모르는 기억은 계정 가드를 걸 수 없으니 없는 것으로 친다.
        guard let partyId = stored?[Self.KEY_PARTY_ID] as? String, !partyId.isBlank,
              let ownerUuid = stored?[Self.KEY_OWNER_UUID] as? String, !ownerUuid.isBlank
        else { return nil }
        return RememberedParty(partyId: partyId, ownerUuid: ownerUuid)
    }

    public func save(party: RememberedParty) {
        defaults.set(
            [Self.KEY_PARTY_ID: party.partyId, Self.KEY_OWNER_UUID: party.ownerUuid],
            forKey: Self.STORE_KEY
        )
    }

    public func clear() {
        defaults.removeObject(forKey: Self.STORE_KEY)
    }
}
