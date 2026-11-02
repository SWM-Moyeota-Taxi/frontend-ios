import Foundation

public enum NetworkModule {

    /// SSE 읽기 타임아웃(초). 서버 heartbeat 30초의 1.5배 — 끊김 감지 수단이 이것뿐이라 유한값이어야 한다.
    /// 자세한 근거는 `create` 안 `streamClient` 주석 참고.
    static let SSE_READ_TIMEOUT_SECONDS: TimeInterval = 45

    /// 채팅 웹소켓의 ping 주기(초). `URLSessionWebSocketTask` 에는 설정이 없어 소켓 쪽이 직접 보낸다.
    static let SOCKET_PING_INTERVAL_SECONDS: TimeInterval = 20

    /// 채팅 웹소켓의 연결 타임아웃(초). 읽기 타임아웃을 끈 세션에서는 이 값을 소켓 쪽이 직접 지켜야 한다.
    static let SOCKET_CONNECT_TIMEOUT_SECONDS: TimeInterval = 10

    private static let IMAGE_MEMORY_CACHE_BYTES = 32 * 1024 * 1024
    private static let IMAGE_DISK_CACHE_BYTES = 32 * 1024 * 1024

    /// 빌드 설정의 base URL 을 `create` 가 받는 꼴로 보정한다. 원본 `app/build.gradle.kts` 의
    /// `if (it.endsWith("/")) it else "$it/"` 자리다 — Retrofit baseUrl 규약상 `/` 로 끝나야 하므로 빌드가 보정해 둔다.
    /// 그 밖의 잘못된 값(빈 값, 스킴 없음)은 고치지 않고 `create` 가 던지게 둔다.
    public static func normalizedBaseUrl(_ baseUrl: String) -> String {
        baseUrl.hasSuffix("/") ? baseUrl : baseUrl + "/"
    }

    /// API 별로 클라이언트를 새로 만들지 않도록 baseUrl 단위로 한 번만 구성한다.
    ///
    /// **클라이언트는 둘이다.**
    /// - `authClient`: 인증 엔드포인트(가입/로그인/재발급/로그아웃) 전용. Bearer 도 401 재발급도 붙지 않는다.
    ///   재발급 요청이 401 을 맞았을 때 다시 재발급을 트리거하는 무한 루프를 구조적으로 차단한다.
    /// - `apiClient`: 나머지 도메인 API. Bearer 부착 + 401 시 재발급 후 1회 재시도.
    ///
    /// 두 클라이언트는 같은 `URLSession` 을 공유해 커넥션 풀을 나눠 쓴다.
    ///
    /// `debugLogging` 은 호출자가 주입한다. 이 패키지는 앱의 빌드 타입을 모르므로 여기서 판단하지 않는다.
    /// 켜지면 요청/응답 본문 전체가 로그에 남는다 — 채팅 메시지와 **인증 토큰**이 포함되므로
    /// 릴리즈에서는 반드시 꺼져야 한다.
    ///
    /// 잘못된 `baseUrl`(끝의 `/` 누락 등)이면 `IllegalArgumentException` 을 던진다 — 원본의 Retrofit 과 같다.
    /// 앱은 빌드 설정 값을 `normalizedBaseUrl` 로 보정해 넘기므로 `/` 누락으로 여기까지 오지 않는다.
    public static func create(baseUrl: String, debugLogging: Bool, tokenHolder: any TokenHolder) throws -> Apis {
        try create(
            baseUrl: baseUrl,
            debugLogging: debugLogging,
            tokenHolder: tokenHolder,
            protocolClasses: nil,
            logSink: HttpLoggingInterceptor.defaultSink
        )
    }

    /// `protocolClasses`·`logSink` 는 테스트 전용 주입 지점이다(MockWebServer·로그 확인의 자리).
    static func create(
        baseUrl: String,
        debugLogging: Bool,
        tokenHolder: any TokenHolder,
        protocolClasses: [AnyClass]?,
        logSink: @escaping @Sendable (String) -> Void
    ) throws -> Apis {
        let logging: [any Interceptor] = debugLogging ? [HttpLoggingInterceptor(sink: logSink)] : []

        // 배포 서버(CloudFront 뒤 오리진)는 콜드 상태에서 첫 응답이 7~8초까지 걸려 기본 10초가 빠듯하다.
        // `URLSession` 은 연결 타임아웃을 따로 두지 못해 읽기·쓰기 20초에 연결 10초까지 함께 맡긴다
        // (docs/IOS-DIFFERENCES.md).
        let baseSession = makeSession(requestTimeout: 20, protocolClasses: protocolClasses)

        let publicClient = HttpClient(session: baseSession, interceptors: logging)
        let publicRest = try RestClient(baseUrl: baseUrl, client: publicClient)
        let authApi = RestAuthApi(rest: publicRest)
        // 앱 설정은 permitAll — 토큰을 붙이지 않는다. 만료 토큰이 붙으면 401 재발급이 끼어들어 앱 시작이 늦어진다.
        let configApi = RestConfigApi(rest: publicRest)

        let authentication: [any Interceptor] = logging + [AuthHeaderInterceptor(tokens: tokenHolder)]
        let authenticator = TokenAuthenticator(tokens: tokenHolder, refresher: RetrofitTokenRefresher(authApi: authApi))
        let apiClient = HttpClient(session: baseSession, interceptors: authentication, authenticator: authenticator)
        let rest = try RestClient(baseUrl: baseUrl, client: apiClient)

        // SSE(매칭방 변화 신호) 전용 — 보통 API 와 같은 인증(Bearer + 401 재발급)을 쓰되 읽기 타임아웃만 늘린다.
        //
        // **무제한이 아니라 유한값인 게 핵심이다.** SSE 에는 WebSocket 의 ping 프레임이 없다 — 즉 소켓이 조용히
        // 죽어도(NAT 만료·셀↔와이파이 핸드오프) 알아챌 수단이 읽기 타임아웃뿐이다. 무제한으로 두면 실패가
        // 영영 올라오지 않아 앱이 "SSE 살아있음"으로 굳고, 폴링을 끈 대기 화면이 영구히 멈춘다.
        //
        // 값은 서버 heartbeat 주기에서 나온다: 서버가 **30초**마다 `:ping` 주석을 보내므로(Backend #218,
        // 이전 5초) 연결이 살아 있으면 읽기가 30초 안에 반드시 깨어난다. 45초는 그 1.5배 —
        // 한 번 흘린 ping 은 견디고, 두 번 연달아 없으면 끊긴 것으로 보고 재연결에 들어간다.
        // 30초보다 짧게 두면 멀쩡한 연결을 매번 끊고, 훨씬 길게 두면 죽은 연결을 그만큼 오래 붙들고 있는다.
        let streamClient = HttpClient(
            session: makeSession(requestTimeout: SSE_READ_TIMEOUT_SECONDS, protocolClasses: protocolClasses),
            interceptors: authentication,
            authenticator: authenticator
        )

        // 웹소켓 전용 세션. 인증을 붙이지 않는다 — STOMP 인증은 CONNECT **프레임** 헤더이고,
        // 401 재발급이 업그레이드 요청에 끼어들 이유도 없다.
        // 읽기 타임아웃은 끈다(상시 연결이라 "응답이 늦다"는 개념이 없다). 대신 ping 으로 살아있음을 확인한다
        // (`SOCKET_PING_INTERVAL_SECONDS`). `URLSession` 에 0 은 없어서 충분히 큰 값으로 끈다.
        let socketClient = makeSession(requestTimeout: 7 * 24 * 60 * 60, protocolClasses: protocolClasses)

        // 프로필 사진 전용. 인증도 디버그 로깅도 없는 별도 세션이다 — 두 가지 이유다.
        // (1) 로깅이 붙으면 아바타 한 장마다 요청/응답 헤더가 로그에 쌓인다.
        // (2) 커넥션 풀을 공유할 이득이 없다. 이미지는 cdn.moyeota.co.kr 에서 오고 API 는 다른 호스트라
        //     어차피 커넥션이 재사용되지 않는다.
        // 타임아웃은 짧게 잡는다 — 아바타는 실패해도 이니셜 원으로 떨어지면 되는 장식이라
        // 오래 붙들고 있을 이유가 없다.
        //
        // 프리셋 PNG 는 512x512 에 장당 약 160KB 이고 CDN 이 `cache-control: max-age=31536000, immutable`
        // 을 주므로, 한 번 받으면 디스크 캐시에서 끝난다. 원본은 이미지 로더(Coil)가 디스크 32MB 를 맡는다.
        let imageClient = makeSession(
            requestTimeout: 15,
            protocolClasses: protocolClasses,
            urlCache: URLCache(
                memoryCapacity: IMAGE_MEMORY_CACHE_BYTES,
                diskCapacity: IMAGE_DISK_CACHE_BYTES,
                directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                    .appendingPathComponent("moyeota_image_cache", isDirectory: true)
            )
        )

        return Apis(
            socketClient: socketClient,
            streamClient: streamClient,
            imageClient: imageClient,
            auth: authApi,
            config: configApi,
            matching: RestMatchingApi(rest: rest),
            place: RestPlaceApi(rest: rest),
            chat: RestChatApi(rest: rest),
            dispatch: RestDispatchApi(rest: rest),
            // 신고 두 엔드포인트 모두 @CurrentUser — 반드시 Bearer 가 붙는 apiClient 로 만든다.
            report: RestReportApi(rest: rest),
            // 인증 API 와 이름이 비슷하지만 반드시 이쪽(apiClient) 이다 — 내 정보 조회는 토큰 필수다.
            user: RestUserApi(rest: rest)
        )
    }

    /// OkHttp 기본값에 맞춘 세션 — 쿠키 저장소도 HTTP 캐시도 없다. `URLSession` 기본값은 둘 다 켜져 있어
    /// 그대로 두면 응답 쿠키가 다음 요청에 실리고 GET 이 캐시에서 답한다(폴링이 멈춘다).
    /// `urlCache` 는 이미지 세션만 넘긴다.
    ///
    /// OkHttp 는 `Accept-Language` 를 싣지 않아 서버가 기본 로케일로 답한다. `URLSession` 은 헤더가 없으면 기기
    /// 언어를 채우고, 뺄 방법은 없어 빈 값으로 막는다 — 기기 언어가 영어라고 서버 기본 문구(`@NotBlank` 등)가
    /// 영어로 오면 안 된다(docs/IOS-DIFFERENCES.md).
    private static func makeSession(
        requestTimeout: TimeInterval,
        protocolClasses: [AnyClass]?,
        urlCache: URLCache? = nil
    ) -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.httpAdditionalHeaders = ["Accept-Language": ""]
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.urlCache = urlCache
        configuration.requestCachePolicy = urlCache == nil ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy
        if let protocolClasses {
            configuration.protocolClasses = protocolClasses
        }
        return URLSession(configuration: configuration, delegate: HttpRedirectDelegate(), delegateQueue: nil)
    }

    public struct Apis: Sendable {
        /// 채팅 실시간 수신(STOMP)이 쓰는 세션. 인증이 붙지 않은 순정 세션이다
        public let socketClient: URLSession
        /// SSE 수신이 쓰는 클라이언트. 인증은 붙어 있고 읽기 타임아웃만 `SSE_READ_TIMEOUT_SECONDS` 로 늘렸다
        public let streamClient: HttpClient
        /// 프로필 사진이 쓰는 세션. 인증이 붙지 않은 순정 세션이다.
        ///
        /// ### `apiClient`/`streamClient` 를 쓰면 안 되는 이유
        /// 프로필 이미지 URL 은 모여타 API 가 아니라 **서버가 내려주는 제3자 전체 주소**다
        /// (`https://cdn.moyeota.co.kr/profile/presets/03.png` — S3 + CloudFront). 거기에 Bearer 를
        /// 실으면 액세스 토큰이 남의 호스트로 나가 CloudFront·S3 액세스 로그에 남는다. 30분 수명이지만
        /// 그 안에 전 API 를 호출할 수 있는 자격증명이다.
        ///
        /// (실측 보강: 이 CDN 은 `Authorization` 을 **무시하고 200** 을 주므로 "CDN 의 401 이 토큰
        /// 재발급을 깨운다"는 경로는 실재하지 않는다 — 없는 키는 403 이다. 즉 이 분리는 기능 문제가 아니라
        /// **토큰을 새게 하지 않기 위한 것**이다.)
        ///
        /// ### `socketClient` 를 재사용하면 안 되는 이유
        /// 인증이 안 붙은 건 같지만 읽기 타임아웃이 **사실상 무제한**이다. 멈춘 이미지 다운로드가 영영
        /// 실패하지 않아 자리표시가 그대로 남고 에러도 재시도도 없이 커넥션을 붙든다.
        ///
        /// ### 캐시
        /// 이 세션에만 `URLCache`(디스크 32MB)가 있다. 원본에서 이미지 로더(Coil)가 맡던 캐시의 자리다.
        public let imageClient: URLSession
        public let auth: any AuthApi
        /// 서버 운영 설정(택시 모드 등). 토큰 없는 클라이언트
        public let config: any ConfigApi
        public let matching: any MatchingApi
        public let place: any PlaceApi
        public let chat: any ChatApi
        public let dispatch: any DispatchApi
        public let report: any ReportApi
        public let user: any UserApi
    }
}
