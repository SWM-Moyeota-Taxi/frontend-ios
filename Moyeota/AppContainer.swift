import Foundation
import MoyeotaData
import MoyeotaDomain
import os

private let logger = Logger(subsystem: "com.moyeota.app", category: "AppContainer")

/// 수동 DI 컨테이너.
///
/// `debugLogging`: HTTP 본문 로깅 여부. 디버그 빌드에서만 켠다(호출자가 판단해 주입).
///
/// 잘못된 base URL(스킴 없음 등)이면 `NetworkModule.create` 가 던진다 — 원본의 Retrofit 과 같다.
/// 끝의 `/` 누락은 잘못이 아니다. 원본 빌드처럼 `resolveBaseUrl` 이 보정한다.
@MainActor
final class AppContainer {

    /// 화면 생명주기와 무관하게 살아야 하는 작업(세션 디스크 복원·토큰 저장) 전용 스코프.
    ///
    /// 묶인 작업 하나가 실패해도 다른 작업은 계속된다(원본 `SupervisorJob`). 원본은 `launch` 의 미처리 예외가
    /// 프로세스를 죽일 수 있어 `CoroutineExceptionHandler` 를 마지막 방어선으로 붙였지만, `CoroutineScope.launch` 는
    /// 던지지 않는 클로저만 받으므로 그 경로는 컴파일에서 막힌다. 세션 복원·저장 경로는 각자 자기 예외를 잡는다
    /// (`SessionManager`).
    private let applicationScope = CoroutineScope()

    /// 세션 단일 출처. 생성 즉시 디스크 복원을 시작하므로 앱 재시작 후에도 로그인이 유지된다.
    private let sessionManager: SessionManager

    private let apis: NetworkModule.Apis

    /// 화면이 로그인 상태와 내 UUID 를 얻는 단일 출처(내부 사용자 PK 는 앱에 없다).
    let userSession: any UserSession

    /// 프로필 사진 로더가 쓰는 세션. **인증이 붙지 않은** 세션이다
    /// (근거는 `NetworkModule.Apis.imageClient` — 이미지는 모여타 API 가 아니라 CDN 에서 온다).
    ///
    /// `MoyeotaApplication` 이 이걸 `MoyeotaImageLoader` 에 넘긴다. 넘기지 않으면 로더가 `URLSession.shared` 를
    /// 쓰는데, **동작은 하기 때문에** 여기서 정한 타임아웃·디스크 캐시가 적용되지 않는 걸 눈치채기 어렵다.
    let imageClient: URLSession

    /// 긴급 신고에 싣는 실측 좌표 — 권한 없음/타임아웃이면 nil 을 돌려주고 신고는 계속된다.
    private let reportLocationProvider = ReportLocationProvider()

    /// FCM 기기 토큰 ↔ 서버 등록 상태를 맞추는 창구.
    ///
    /// 컨테이너 수명 = 앱 프로세스 수명이라 「보류 중인 토큰」이 화면 전환에도 살아남는다
    /// (매번 새로 만들면 로그인 화면에서 받아 둔 토큰을 로그인 시점에 잃는다).
    /// 등록/해제 호출 시점은 `authRepository` 안에 있고(`RemoteAuthRepository` 참조),
    /// 앱 시작·토큰 회전 경로만 `MoyeotaApplication` 이 직접 부른다.
    let fcmTokenRegistrar: FcmTokenRegistrar

    /// 「진행 중인 방」 로컬 기억. **인스턴스를 하나만 만들어 두 곳이 나눠 쓴다** —
    /// `activePartyRepository` 가 읽고 쓰며, `authRepository` 는 탈퇴 때 비운다
    /// (로그아웃은 비우지 않는다 — `RemoteAuthRepository.deleteAccount`).
    private let activePartyStorage = UserDefaultsActivePartyStorage()

    let authRepository: any AuthRepository
    /// 택시 모드 등 서버 운영 설정. 앱 시작 시 한 번 읽고(`AppConfigViewModel`), 실패하면 기본값(기사 모드).
    let appConfigRepository: any AppConfigRepository
    /// 세션을 넘기는 건 방 상세 멤버 중 「나」를 매퍼가 판정하기 위해서다(`RemoteRideRepository`).
    let rideRepository: any RideRepository
    let placeRepository: any PlaceRepository

    /// 34 지난 탑승 기록(`GET /api/v1/users/me/parties`). **끝난 탑승만 다룬다** —
    /// 「지금 타고 있는 방」은 `activePartyRepository` 쪽이고, 둘을 섞지 않는다.
    /// 이 응답에는 진행 중인 방이 들어오지 않아(실측 2026-11-01, 로컬 `:8080`) 서로를 대체할 수 없다.
    ///
    /// 세션을 넘기는 건 조회가 아니라 **번역** 때문이다 — 멤버마다 `isMe` 가 오지 않아 매퍼가
    /// `publicId == currentUserUuid` 로 「나」를 판정한다(`RemoteRideRecordRepository`).
    let rideRecordRepository: any RideRecordRepository

    /// 세션을 넘기는 건 메시지의 「내 것」 판정 때문이다(`RemoteChatRepository`).
    /// 채팅은 실시간(STOMP) + 폴링을 함께 쓴다 — 소켓이 앞서고, 끊긴 구간은 폴링이 메운다.
    let chatRepository: any ChatRepository
    let dispatchRepository: any DispatchRepository

    /// 「지금 내가 타고 있는 방」의 단일 출처. 서버에 `GET /matching/rooms/me` 가 없어
    /// 앱이 방 id 를 로컬에 기억했다가 상세 조회로 되살린다(`RemoteActivePartyRepository`).
    /// rideRepository·chatRepository 를 그대로 쓰므로 **둘의 선언 아래**에 둔다.
    let activePartyRepository: any ActivePartyRepository

    init(baseUrl: String, debugLogging: Bool) throws {
        let sessionManager = SessionManager(storage: KeychainTokenStorage(), scope: applicationScope)
        let apis = try NetworkModule.create(baseUrl: baseUrl, debugLogging: debugLogging, tokenHolder: sessionManager)
        let fcmTokenRegistrar = FcmTokenRegistrar(userApi: apis.user, session: sessionManager)
        let reportLocationProvider = reportLocationProvider

        self.sessionManager = sessionManager
        self.apis = apis
        self.userSession = sessionManager
        self.imageClient = apis.imageClient
        self.fcmTokenRegistrar = fcmTokenRegistrar
        self.authRepository = RemoteAuthRepository(
            api: apis.auth,
            userApi: apis.user,
            session: sessionManager,
            fcmTokenRegistrar: fcmTokenRegistrar,
            activePartyStorage: activePartyStorage
        )
        self.appConfigRepository = RemoteAppConfigRepository(api: apis.config)
        let rideRepository = RemoteRideRepository(
            api: apis.matching,
            session: sessionManager,
            reportApi: apis.report,
            currentLocation: { try await reportLocationProvider.current() },
            partyEvents: PartyEventSource(baseUrl: baseUrl, client: apis.streamClient)
        )
        self.rideRepository = rideRepository
        self.placeRepository = RemotePlaceRepository(api: apis.place)
        self.rideRecordRepository = RemoteRideRecordRepository(api: apis.user, session: sessionManager)
        let chatRepository = RemoteChatRepository(
            api: apis.chat,
            session: sessionManager,
            socket: ChatSocket(baseUrl: baseUrl, session: apis.socketClient, tokens: sessionManager)
        )
        self.chatRepository = chatRepository
        self.dispatchRepository = RemoteDispatchRepository(api: apis.dispatch)
        self.activePartyRepository = RemoteActivePartyRepository(
            rideRepository: rideRepository,
            chatRepository: chatRepository,
            storage: activePartyStorage,
            session: sessionManager
        )
    }

    /// 백엔드 base URL. 기본값은 `Info.plist` 의 `MOYEOTA_BASE_URL`(빌드 설정 `Config/Base.xcconfig` →
    /// `Config/Secrets.xcconfig` 가 덮어쓴다). Android 의 `BuildConfig.BASE_URL` 자리다.
    ///
    /// ### 디버그 빌드 오버라이드 — 로컬 서버와 동작을 비교할 때 쓴다
    /// 빌드를 다시 하지 않고 같은 앱을 로컬 서버로 돌린다. 둘 중 하나로 넘긴다.
    ///
    ///     xcrun simctl launch <기기> com.moyeota -MOYEOTA_BASE_URL_OVERRIDE http://localhost:8080/
    ///     SIMCTL_CHILD_MOYEOTA_BASE_URL_OVERRIDE=http://localhost:8080/ xcrun simctl launch <기기> com.moyeota
    ///
    /// **릴리스 바이너리에는 이 코드가 없다**(`#if DEBUG`). 릴리스에 남기면 실행 인자 하나로 토큰이 실린 요청을
    /// 다른 서버로 돌릴 수 있고, 평문 허용도 디버그 빌드에만 있어(프로젝트의 「Allow cleartext in Debug」 단계)
    /// 함께 있어야 말이 되는 값이다.
    static func resolveBaseUrl(bundle: Bundle = .main) -> String {
        #if DEBUG
        if let override = debugBaseUrlOverride() {
            logger.notice("디버그 base URL 오버라이드 사용: \(override, privacy: .public)")
            return NetworkModule.normalizedBaseUrl(override)
        }
        #endif
        return NetworkModule.normalizedBaseUrl(bundle.object(forInfoDictionaryKey: "MOYEOTA_BASE_URL") as? String ?? "")
    }

    #if DEBUG
    private static func debugBaseUrlOverride() -> String? {
        let key = "MOYEOTA_BASE_URL_OVERRIDE"
        // `UserDefaults.string(forKey:)` 로 읽지 않는다. 인자 영역만 본다 — 저장된 값이 남아 다음 실행으로 새면
        // 인자 없이 켠 앱이 조용히 로컬 서버를 본다.
        let argument = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[key] as? String
        let value = argument ?? ProcessInfo.processInfo.environment[key]
        guard let value, !value.isBlank else { return nil }
        return value
    }
    #endif
}
