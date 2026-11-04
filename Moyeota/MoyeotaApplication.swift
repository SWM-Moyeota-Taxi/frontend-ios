import FirebaseCore
import FirebaseCrashlytics
import FirebaseMessaging
import Foundation
import MoyeotaDesignSystem
import MoyeotaDomain
import Observation
import os
import UIKit

private let logger = Logger(subsystem: "com.moyeota.app", category: "MoyeotaFcm")

/// HTTP 본문 로깅·크래시 수집·개발자 옵션을 가르는 판단 근거. 원본 `isDebuggableBuild`(`FLAG_DEBUGGABLE`) 자리다.
/// 앱 타깃의 빌드 구성을 본다 — 모듈마다 다른 값을 보는 함정을 피해 한곳에서만 판단한다.
var isDebuggableBuild: Bool {
    #if DEBUG
    true
    #else
    false
    #endif
}

/// Firebase 를 이 실행에서 쓸 수 있는가.
///
/// `GoogleService-Info.plist` 는 git 에 없고 없어도 앱은 돌아야 한다. 없을 때 `FirebaseApp.configure()` 는
/// NSException 을 던지고(Swift 로 잡지 못한다), `Messaging.messaging()`·`Crashlytics.crashlytics()` 도 앱 없이
/// 부르면 터진다. 그래서 **모든 Firebase 호출이 이 값 뒤에 있다.**
///
/// `FirebaseApp.app()` 으로 판정하지 않는다 — 미구성 상태에서 부르면 그 자체가 오류 로그(I-COR000005)를 남긴다.
enum FirebaseRuntime {
    /// 첫 접근에서 구성을 끝낸다. `static let` 이라 두 번 구성되지 않는다(두 번째 `configure` 도 NSException 이다).
    static let isConfigured: Bool = {
        // 파일 유무를 먼저 본다. `defaultOptions()` 는 파일이 없으면 nil 을 돌려주면서 오류 로그(I-COR000012)도 남긴다 —
        // 없는 것이 정상인 실행이 매번 오류를 남기면 진짜 Firebase 오류가 묻힌다. 사전이 아닌 파일은 여기서 nil 이다.
        guard Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil,
              let options = FirebaseOptions.defaultOptions() else {
            logger.notice("GoogleService-Info.plist 없음 — Firebase 없이 실행한다")
            return false
        }
        FirebaseApp.configure(options: options)
        return true
    }()
}

/// 알림 탭으로 열어 달라는 채팅방 id. 원본 `MainActivity.pendingChatRoomId` 의 자리다.
///
/// 원본은 액티비티가 들고 있지만 여기서는 프로세스가 든다 — 콜드 스타트 탭은 **뷰가 만들어지기 전에** 도착할 수 있어,
/// 뷰가 들고 있으면 그 탭을 잃는다.
/// `MainNavGraph` 가 이동을 마치면 nil 로 되돌린다 — 안 그러면 뷰가 다시 그려질 때 같은 방으로 또 간다.
@MainActor
@Observable
final class PendingChatRoom {
    var roomId: Int64?
}

/// 앱 프로세스 단위의 시작 순서를 맡는다. 원본 `MoyeotaApplication` 의 자리다.
///
/// `shared` 를 처음 읽는 순간 `onCreate` 가 끝까지 돈다. `AppDelegate` 가 시작할 때 읽지만, SwiftUI 가 먼저
/// 화면을 만들어도 같은 순서가 지켜진다 — 호출 순서에 의존하는 경로를 두지 않는다.
@MainActor
final class MoyeotaApplication {
    static let shared = MoyeotaApplication()

    let appContainer: AppContainer

    let pendingChatRoom = PendingChatRoom()

    /// 화면 수명과 무관하게 살아야 하는 앱 차원의 백그라운드 작업(FCM 토큰 서버 등록) 전용 스코프.
    /// 등록 실패 하나가 이후 등록까지 막지 않는다.
    private let appScope = CoroutineScope()

    /// `Messaging.delegate` 는 약한 참조다. 프로세스 수명만큼 여기서 붙잡는다.
    private let messagingService = MoyeotaFirebaseMessagingService()

    private init() {
        // 컨테이너보다 **먼저** 켠다. 컨테이너 조립이 터지면 그 크래시도 받아야 하는데,
        // 수집 스위치가 뒤에 있으면 바로 그 사고만 영영 못 본다.
        Self.configureCrashReporting()
        // 지도 뷰가 만들어지기 전에 끝나야 한다. 아래 조립보다 먼저 두어 어떤 화면보다도 앞선다.
        Self.configureNaverMaps()
        do {
            appContainer = try AppContainer(
                baseUrl: AppContainer.resolveBaseUrl(),
                debugLogging: isDebuggableBuild
            )
        } catch {
            // 빌드 설정 오류다(원본도 Retrofit 이 IllegalArgumentException 으로 앱 시작 때 죽는다).
            // 서버 없는 앱으로 띄워 봐야 모든 화면이 실패할 뿐이라 여기서 알린다.
            fatalError("MOYEOTA_BASE_URL 이 올바르지 않습니다: \(type(of: error))")
        }
        // 인증 클라이언트가 섞이면 액세스 토큰이 CDN 액세스 로그로 새어 나간다. 기본값에 의존하지 않고 코드로 못 박는다.
        MoyeotaImageLoader.configure(session: appContainer.imageClient)
        // 행동 이벤트(Mixpanel). 세션을 따라 사용자를 식별하므로 컨테이너 뒤, 첫 화면(`view_screen`)보다는 앞이다.
        // 토큰이 없으면 꺼진다 — Firebase 와 같은 「없어도 돈다」 규칙(`MixpanelAnalyticsReporter`).
        MixpanelAnalyticsReporter.install(
            token: Bundle.main.object(forInfoDictionaryKey: "MixpanelToken") as? String,
            session: appContainer.userSession,
            debuggable: isDebuggableBuild
        )
        // 원본의 `createNotificationChannel` 은 옮길 것이 없다 — iOS 에는 알림 채널이 없다(docs/IOS-DIFFERENCES.md).
        if FirebaseRuntime.isConfigured {
            Messaging.messaging().delegate = messagingService
        }
    }

    /// 크래시 수집 스위치.
    ///
    /// **디버그 빌드에서는 끈다.** 개발 중 일부러 낸 크래시가 운영 대시보드에 섞이면
    /// 「크래시 없는 사용자 %」가 무의미해지고, 진짜 사고가 개발 소음에 묻힌다.
    ///
    /// ### setUserID 를 부르지 않는다
    /// `publicId`(uuid)를 넣으면 「누가 겪은 크래시인가」를 알 수 있어 편하지만, 그 값은 서버에서
    /// 실명·휴대폰번호로 되짚히는 **계정 식별자**다. 보내는 순간 크래시 보고가 「이용자와 연결된
    /// 데이터」가 되어 처리방침에 계정 식별자의 국외 이전을 따로 적어야 하고, 삭제 요구가 오면
    /// Google 쪽 기록까지 지워야 한다. 얻는 것보다 비용이 크다.
    ///
    /// ### 보고에 넣으면 안 되는 것
    /// `log`·커스텀 키·오류 설명 어디에도 **로그인 토큰·휴대폰번호·이메일·실명·좌표·채팅 본문**을
    /// 넣지 않는다. 특히 서버 응답에서 온 오류를 그대로 넘기면 안 된다 — `DecodingError` 의 설명은
    /// 키 경로와 값 조각을 담을 수 있다. 그래서 `CrashlyticsErrorReporter` 가 원본 오류를 넘기지 않고
    /// 종류와 지점만 남긴 보고를 새로 만든다.
    ///
    /// 앱 시작을 막으면 안 된다. 최악은 크래시를 못 보는 것뿐이므로 Firebase 가 없으면 그냥 지나간다.
    private static func configureCrashReporting() {
        guard FirebaseRuntime.isConfigured else { return }
        Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(!isDebuggableBuild)
        // 삼켜진 실패를 non-fatal 로 받는 통로. 꽂기 전의 보고는 조용히 버려지므로
        // 수집 스위치 바로 뒤, 컨테이너 조립보다 먼저 꽂는다.
        CrashlyticsErrorReporter.install()
    }

    /// 네이버 지도 NCP 키. 원본은 매니페스트 meta-data 다. 신규 키 체계라 `ncpKeyId` 를 쓴다(구 clientId 아님).
    ///
    /// 값이 비어 있으면 지정하지 않는다 — 빌드는 되고 지도만 런타임 인증 실패한다(`Config/Base.xcconfig`).
    private static func configureNaverMaps() {
        let key = Bundle.main.object(forInfoDictionaryKey: "NMFNcpKeyId") as? String
        guard let key, !key.isBlank else {
            logger.notice("NMFNcpKeyId 가 비어 있다 — 지도 인증이 실패한다")
            return
        }
        NMFAuthManager.shared().ncpKeyId = key
    }

    /// APNs 등록이 끝났을 때. 이게 원본 `fetchFcmToken` 의 시점이다.
    ///
    /// 토큰 콜백은 토큰이 신규 발급되거나 회전될 때만 믿을 수 있고, 최초 설치 시점을 지난 기존 설치분은 콜백이
    /// 오지 않을 수 있으므로 앱 시작마다 명시 조회한다. iOS 에서는 APNs 토큰을 넘기기 전의 조회가 실패하므로
    /// 앱 시작 즉시가 아니라 `registerForRemoteNotifications` 의 결과가 온 뒤에 조회한다.
    func onApnsTokenAvailable(_ deviceToken: Data) {
        guard FirebaseRuntime.isConfigured else { return }
        Messaging.messaging().apnsToken = deviceToken
        fetchFcmToken()
    }

    /// `token(completion:)` 은 SDK 13.x 에서 deprecated 이나 후속 API 인 `register(completion:)` 은
    /// `Info.plist` 의 `FirebaseMessagingInstallationIdEnabled` 로 opt-in 해야 하고, 켜는 순간 FCM 토큰이 아예 발급되지
    /// 않는다. 서버가 받는 값이 토큰이라 등록 방식 자체가 바뀌는 변경이므로 원본처럼 현행을 유지한다.
    private func fetchFcmToken() {
        Messaging.messaging().token { [weak self] token, error in
            // 실패한 조회의 token 은 nil 이므로 오류를 먼저 본다
            if let error {
                logger.warning("FCM 토큰 조회 실패: \(String(reflecting: type(of: error)), privacy: .public)")
                return
            }
            guard let token, !token.isBlank else {
                logger.warning("FCM 토큰이 비어 있음")
                return
            }
            Task { @MainActor in self?.onFcmTokenAvailable(token) }
        }
    }

    /// 기기 FCM 토큰이 확인됐을 때의 단일 진입점. 앱 시작 시 명시 조회와
    /// `MoyeotaFirebaseMessagingService` 의 회전 콜백이 모두 여기로 들어온다.
    ///
    /// 서버 등록은 정의상 실패해도 좋은 작업이라 결과를 기다리지 않는다 — 여기서 붙잡으면
    /// 앱 시작이나 FCM 콜백이 네트워크를 기다리게 된다. 로그인 상태가 아직 확정되지 않았다면
    /// 등록은 `FcmTokenRegistrar` 안에서 보류됐다가 로그인 직후 이어진다.
    func onFcmTokenAvailable(_ token: String) {
        logger.debug("FCM 토큰 확인, 서버 등록 시도")
        let registrar = appContainer.fcmTokenRegistrar
        appScope.launch {
            // 던지는 것은 취소뿐이고, 이 스코프를 취소하는 곳이 없다.
            try? await registrar.onTokenAvailable(token: token)
        }
    }
}
