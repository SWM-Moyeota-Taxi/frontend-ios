import Foundation
import Mixpanel
import MoyeotaDomain
import os

private let logger = Logger(subsystem: "com.moyeota.app", category: "Analytics")

/// `Analytics` 가 올린 이벤트를 Mixpanel 로 보낸다. `CrashlyticsErrorReporter` 와 같은 자리다 —
/// domain 은 「무엇을」 정하고, 여기서 「어디로」만 꽂는다. Mixpanel 을 아는 파일은 이것 하나다.
///
/// ### 토큰이 없으면 아무것도 하지 않는다
/// `Info.plist` 의 `MixpanelToken`(← `Config/Secrets.xcconfig` 의 `MIXPANEL_TOKEN`)이 비어 있으면 SDK 를
/// 초기화하지 않고 sink 도 꽂지 않는다. 그러면 `Analytics.track` 은 무동작이다 — 토큰 없이 빌드한 앱
/// (fork·CI·새 팀원)이 깨지거나 남의 프로젝트로 이벤트를 쏘는 일이 없다. 운영·개발은 지금 한 프로젝트에
/// 들어가고 super property `build`(debug/release)로 가른다 — 개발 중 찍은 가입·매칭이 운영 퍼널에 섞이면
/// 「가입 당일 매칭 완료율」이 무의미해지므로 보고서에 `build = release` 필터를 건다. 완전히 나누려면
/// `MIXPANEL_TOKEN[config=Debug]` 에 개발 프로젝트 토큰을 주면 Debug 빌드만 그쪽으로 간다.
///
/// ### 사용자 식별 — `identify` 는 세션 상태를 따라간다
/// 특강의 규칙 그대로다: 로그인 전에는 SDK 가 만든 기기 익명 id, 로그인하면 서버 `publicId`(uuid) 로
/// `identify`, 로그아웃·탈퇴면 `reset`. Mixpanel 은 익명 id 와 publicId 를 자동으로 합치므로(ID merge)
/// 가입 전 온보딩 화면 조회가 가입 뒤의 같은 사람으로 이어진다 — 「가입 당일 매칭 완료율」·리텐션이
/// 성립하는 전제다. 어디서 로그인·로그아웃이 일어났든 `UserSession.authState` 하나만 보면 되므로
/// 화면 코드에는 식별 호출이 없다.
///
/// **이건 Crashlytics 와 반대의 결정이다.** `MoyeotaApplication` 은 Crashlytics 에 `setUserID` 를 넣지 않았다
/// (계정 식별자의 국외 이전·삭제 요구 대응 비용). Mixpanel 은 사용자 단위 퍼널·리텐션이 목적 자체라 식별자
/// 없이는 쓸 수 없다. 그래서 **처리방침과 App Store 개인정보 라벨에 Mixpanel 수집 항목을 적어야 하고**
/// (`PrivacyInfo.xcprivacy` 에 선언해 두었다), 탈퇴 요청이 오면 Mixpanel 쪽 프로필도 지워야 한다
/// (`docs/ANALYTICS.md`).
///
/// ### 보내는 값
/// 이벤트 프로퍼티는 `AnalyticsEvent.properties` 가 전부다 — 여기서 덧붙이는 건 빌드 종류(`build`)뿐이다.
/// 가입 때의 성별·연령대는 사람 프로필(People)에도 올린다 — 「20대 남성이 많다」를 코호트로 묶어 보려면
/// 이벤트가 아니라 프로필에 있어야 한다. `identify` 전에 올라온 프로필 값은 SDK 가 쥐고 있다가 식별되면 보낸다.
///
/// 자동 이벤트(`trackAutomaticEvents`)는 끈다 — 앱 실행·세션 같은 SDK 기본 이벤트는 우리 퍼널 이름과
/// 섞여 대시보드만 어지럽히고, 화면 조회는 `MainNavGraph` 가 `view_screen` 으로 직접 보낸다.
enum MixpanelAnalyticsReporter {

    /// `identify`·`reset` 을 세션에 맞추는 구독. 프로세스 수명만큼 산다. `install` 과 같은 메인 액터에 묶어 둔다.
    @MainActor private static var sessionObserver: Task<Void, Never>?

    /// `Analytics` 에 sink 를 꽂고 세션을 따라 사용자를 식별한다. `MoyeotaApplication` 이 컨테이너를 조립한 뒤 한 번 부른다.
    ///
    /// - Returns: SDK 를 켰는가. 토큰이 비어 있으면 false 다.
    @MainActor
    @discardableResult
    static func install(token: String?, session: any UserSession, debuggable: Bool) -> Bool {
        guard let token, !token.isBlank else {
            logger.notice("MixpanelToken 이 비어 있다 — 이벤트를 보내지 않는다")
            return false
        }
        let mixpanel = Mixpanel.initialize(token: token, trackAutomaticEvents: false)
        // 콘솔에 보낸 이벤트가 찍힌다 — 「이벤트가 심어졌나」를 Mixpanel 콘솔까지 가지 않고 확인하는 길이다.
        mixpanel.loggingEnabled = debuggable
        mixpanel.registerSuperProperties(["build": debuggable ? "debug" : "release"])

        // 아래 두 클로저는 `@Sendable` 이라 `MixpanelInstance`(Sendable 아님)를 잡아 둘 수 없다. 그때마다
        // `mainInstance()` 로 다시 찾는다 — 위에서 초기화한 그 인스턴스이고, SDK 안에서 잠금으로 보호된 조회다.
        Analytics.install { event in
            // `track` 은 SDK 안의 직렬 큐로 넘어가므로 어느 스레드에서 불러도 되고 호출부를 기다리게 하지 않는다.
            let mixpanel = Mixpanel.mainInstance()
            mixpanel.track(event: event.name, properties: mixpanelProperties(event.properties))
            if case .signupCompleted(let gender, let ageBand) = event {
                mixpanel.people.set(properties: ["gender": gender.name.lowercased(), "age_band": ageBand])
            }
        }

        sessionObserver?.cancel()
        sessionObserver = Task {
            var identified = false
            for await state in session.authState.values() {
                switch state {
                case .authenticated(let userUuid):
                    Mixpanel.mainInstance().identify(distinctId: userUuid)
                    identified = true
                case .unauthenticated:
                    // 앱 시작 때의 「미로그인」에는 reset 하지 않는다 — 익명 id 가 실행마다 바뀌면 가입 전 행동이 끊긴다.
                    // 로그아웃·탈퇴·세션 만료로 **로그인 상태에서 빠져나온 때**만 끊는다.
                    if identified {
                        Mixpanel.mainInstance().reset()
                        identified = false
                    }
                case .unknown:
                    break
                }
            }
        }
        return true
    }

    private static func mixpanelProperties(_ properties: [String: AnalyticsValue]) -> Properties {
        properties.mapValues { value -> MixpanelType in
            switch value {
            case .string(let string): string
            case .int(let int): int
            case .bool(let bool): bool
            }
        }
    }
}
