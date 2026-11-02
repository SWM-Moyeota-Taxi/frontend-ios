import Foundation
import MoyeotaDomain
import Security

/// Keychain 기반 토큰 저장소. 원본 `DataStoreTokenStorage` 의 자리다.
///
/// **세 값을 항목 하나에 함께 쓴다.** 원본의 `dataStore.edit` 는 세 키를 원자적으로 쓴다. 항목을 셋으로 나누면
/// 회전 도중 죽었을 때 새 액세스 + 죽은 리프레시 조합이 남을 수 있어 같은 보장을 잃는다.
///
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: 첫 잠금 해제 이후에만 읽히고 다른 기기로 옮겨 가지 않는다.
///
/// **재설치 직후 첫 실행에는 남은 항목을 지운다.** Android 는 앱을 지우면 데이터도 사라지지만, iOS 의 Keychain 은
/// 앱을 지워도 남는다. 그대로 두면 재설치한 앱이 지운 앱의 세션으로 로그인된 채 켜진다. `UserDefaults` 는
/// 앱과 함께 지워지므로 거기 둔 표시로 「이 설치에서 처음」을 안다(docs/IOS-DIFFERENCES.md).
///
/// 지우기가 실패하면(첫 잠금 해제 전 등) 표시를 남기지 않고 던진다. 남은 토큰을 읽지 않고, 다음에 다시 시도한다.
public actor KeychainTokenStorage: TokenStorage {
    private let keychain: any KeychainItemStore
    private let installMarker: InstallMarker

    public init() {
        self.init(
            keychain: SystemKeychainItemStore(service: "moyeota_session", account: "session"),
            installMarker: InstallMarker(defaults: .standard)
        )
    }

    init(keychain: any KeychainItemStore, installMarker: InstallMarker) {
        self.keychain = keychain
        self.installMarker = installMarker
    }

    public func load() throws -> StoredSession? {
        try clearStaleItemsAfterReinstall()
        guard let data = try keychain.read() else { return nil }
        // 손상된 항목은 비우고 없는 것으로 친다. 어차피 건질 토큰이 없고, 최악이 "재로그인 한 번"이다.
        // 읽을 때마다 던지면 복원이 매번 실패해 복구 수단이 재설치뿐이다.
        guard let stored = try? JSONDecoder().decode(StoredItem.self, from: data) else {
            try? keychain.deleteAll()
            return nil
        }
        // 부분 저장은 세션으로 인정하지 않는다 — 반쪽 세션은 401 루프의 원인이 된다.
        guard let userUuid = stored.user_uuid, !userUuid.isBlank,
              let accessToken = stored.access_token, !accessToken.isBlank,
              let refreshToken = stored.refresh_token, !refreshToken.isBlank
        else { return nil }
        return StoredSession(userUuid: userUuid, accessToken: accessToken, refreshToken: refreshToken)
    }

    public func save(session: StoredSession) throws {
        try clearStaleItemsAfterReinstall()
        let item = StoredItem(
            user_uuid: session.userUuid,
            access_token: session.accessToken,
            refresh_token: session.refreshToken
        )
        try keychain.write(try JSONEncoder().encode(item))
    }

    public func clear() throws {
        try clearStaleItemsAfterReinstall()
        try keychain.deleteAll()
    }

    private func clearStaleItemsAfterReinstall() throws {
        if installMarker.isSet { return }
        try keychain.deleteAll()
        // 지운 뒤에 남긴다 — 사이에 죽어도 다음 실행이 다시 지운다.
        installMarker.set()
    }

    private struct StoredItem: Codable {
        var user_uuid: String?
        var access_token: String?
        var refresh_token: String?
    }
}

/// 「이 설치에서 Keychain 을 이미 정리했다」는 표시. 앱과 함께 지워지는 `UserDefaults` 에 둔다.
struct InstallMarker: Sendable {
    private static let KEY = "moyeota_session_keychain_install_marker"

    // `UserDefaults` 는 스레드 안전하다고 문서화돼 있지만 SDK 가 Sendable 로 표시하지 않는다.
    private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var isSet: Bool { defaults.bool(forKey: Self.KEY) }

    func set() {
        defaults.set(true, forKey: Self.KEY)
    }
}

/// Keychain 항목 하나의 읽기·쓰기. macOS 테스트 프로세스가 실제 Keychain 을 건드리지 않도록 끼워 둔 경계다.
protocol KeychainItemStore: Sendable {
    func read() throws -> Data?
    func write(_ data: Data) throws
    /// 이 서비스의 항목을 전부 지운다. 없으면 성공이다.
    func deleteAll() throws
}

public struct KeychainException: Throwable {
    public let status: OSStatus

    public var message: String? { "Keychain 실패: \(status)" }
    public var cause: (any Error)? { nil }
}

struct SystemKeychainItemStore: KeychainItemStore {
    let service: String
    let account: String

    private var itemQuery: [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
    }

    func read() throws -> Data? {
        var query = itemQuery
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainException(status: status)
        }
    }

    func write(_ data: Data) throws {
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updated = SecItemUpdate(itemQuery as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw KeychainException(status: updated) }

        let added = SecItemAdd(itemQuery.merging(attributes) { _, new in new } as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainException(status: added) }
    }

    func deleteAll() throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainException(status: status)
        }
    }
}
