import MoyeotaDomain
import Testing
@testable import MoyeotaData

@Suite struct RemoteAuthRepositoryTest {
    private let newUser: NewUser

    init() throws {
        newUser = NewUser(
            loginId: "moyeota_test",
            password: "Passw0rd!",
            nickname: "모여타",
            name: "홍길동",
            birthDate: try LocalDate.of(2000, 1, 1),
            phoneNumber: "010-1234-5678",
            gender: .male,
            email: "test@moyeota.com",
            verificationToken: "3f2b8c1e-0000-4000-8000-000000000001"
        )
    }

    // `join` 이 원본 `Dispatchers.Unconfined` 의 자리다: 복원이 끝난 뒤에 돌려줘 테스트가 결정적이 된다.
    private func session(_ initial: StoredSession? = nil) async -> SessionManager {
        await session(storage: FakeTokenStorage(initial))
    }

    private func session(storage: FakeTokenStorage) async -> SessionManager {
        let scope = CoroutineScope()
        let manager = SessionManager(storage: storage, scope: scope)
        await scope.join()
        return manager
    }

    private func loggedInSession() async -> SessionManager {
        await session(StoredSession(userUuid: "uuid-1", accessToken: "access.jwt", refreshToken: "refresh.jwt"))
    }

    // 내 정보 조회 API 는 가입/로그인/로그아웃 경로와 무관하다 — 그쪽 테스트가 신경 쓰지 않게 기본값으로 채운다.
    // activePartyStorage 도 같다: 탈퇴 경로만 건드리므로 나머지 테스트는 빈 기억으로 둔다.
    private func repository(
        _ api: any AuthApi,
        _ session: SessionManager,
        _ userApi: any UserApi = FakeUserApi(),
        registrar: FcmTokenRegistrar? = nil,
        activePartyStorage: any ActivePartyStorage = SpyActivePartyStorage()
    ) -> RemoteAuthRepository {
        RemoteAuthRepository(
            api: api,
            userApi: userApi,
            session: session,
            fcmTokenRegistrar: registrar ?? FcmTokenRegistrar(userApi: userApi, session: session),
            activePartyStorage: activePartyStorage
        )
    }

    @Test("내 정보는 uuid 와 이름을 그대로 도메인으로 넘긴다")
    func profilePassesThrough() async throws {
        let profile = try await repository(FakeAuthApi(), await session(), FakeUserApi(name: "김성윤")).getMyProfile()

        #expect(profile.uuid == "01a06145-3caf-7614-a3bd-cee6e25316b1")
        #expect(profile.name == "김성윤")
    }

    /// 닉네임도 실명도 없는 사용자에게 서버는 `"name":null` 을 내려보낸다(`orElse(null)`).
    /// 이걸 에러로 바꾸면 멀쩡한 사용자가 화면을 못 연다 — 이름 없는 프로필은 정상 경우다.
    @Test("이름이 없어도 실패하지 않는다")
    func profileWithoutName() async throws {
        let profile = try await repository(FakeAuthApi(), await session(), FakeUserApi(name: nil)).getMyProfile()

        #expect(profile.name == nil)
    }

    /// 401 은 재발급이 이미 실패했다는 뜻이다(Authenticator 가 apiClient 에서 한 번 시도한다).
    /// sessionExpired 로 좁혀야 화면이 "다시 로그인"으로 보낸다.
    @Test("내 정보 조회의 401 은 세션 만료로 좁힌다")
    func profile401() async {
        let failing = FakeUserApi(failure: httpException(401, #"{"code":"USER005","message":"로그인이 필요합니다."}"#))
        let repository = repository(FakeAuthApi(), await session(), failing)

        let thrown = await #expect(throws: AuthException.self) { try await repository.getMyProfile() }

        #expect(thrown?.error == .sessionExpired)
    }

    // uuid 없이 "나"를 화면에 흘려보내면 잘못된 상태가 조용히 굳는다 — 여기서 끊는다.
    @Test("내 정보 응답에 uuid 가 없으면 실패로 끊는다")
    func profileWithoutUuid() async {
        let repository = repository(FakeAuthApi(), await session(), FakeUserApi(uuid: ""))

        let thrown = await #expect(throws: AuthException.self) { try await repository.getMyProfile() }

        #expect(thrown?.error == .unknown)
    }

    /// 204 라 본문이 없다 — "돌려받을 게 없는 성공"이 예외 없이 끝나는지만 확인한다.
    /// 번호는 하이픈을 떼고 보낸다(발송·확인·가입 세 곳을 같은 형태로 맞추려는 것).
    @Test("인증번호 발송은 하이픈을 뗀 번호로 나가고 204 를 성공으로 끝낸다")
    func smsSendNormalizes() async throws {
        let api = FakeAuthApi()

        try await repository(api, await session()).sendPhoneVerificationCode(phoneNumber: "010-1234-5678")

        #expect(api.smsSendRequest.value == SmsSendRequestDto(phoneNumber: "01012345678"))
    }

    /// **발송 단계에서 409 가 난다** — 서버가 문자 비용을 쓰기 전에 가입된 번호를 거른다.
    /// 화면은 인증번호 입력칸을 열기 전에 "이미 가입된 번호"를 말해야 한다.
    @Test("발송 409 USER104 는 이미 가입된 번호로 올라온다")
    func smsSend409() async {
        let api = FakeAuthApi(
            smsSendFailure: httpException(409, #"{"code":"USER104","message":"이미 가입된 전화번호입니다."}"#)
        )
        let repository = repository(api, await session())

        let thrown = await #expect(throws: AuthException.self) {
            try await repository.sendPhoneVerificationCode(phoneNumber: "01012345678")
        }

        #expect(thrown?.error == .phoneNumberDuplicated)
    }

    /// 429 가 셋이라 코드를 봐야 갈린다 — 쿨다운과 하루 한도는 화면 대응이 정반대다.
    @Test("발송 429 는 쿨다운과 하루 한도로 갈린다")
    func smsSend429() async {
        let cooldown = repository(
            FakeAuthApi(
                smsSendFailure: httpException(429, #"{"code":"USER202","message":"인증번호는 1분에 한 번만 요청할 수 있습니다."}"#)
            ),
            await session()
        )
        let daily = repository(
            FakeAuthApi(
                smsSendFailure: httpException(429, #"{"code":"USER203","message":"오늘 인증번호 요청 횟수를 초과했습니다."}"#)
            ),
            await session()
        )

        let cooldownError = await #expect(throws: AuthException.self) {
            try await cooldown.sendPhoneVerificationCode(phoneNumber: "01012345678")
        }
        let dailyError = await #expect(throws: AuthException.self) {
            try await daily.sendPhoneVerificationCode(phoneNumber: "01012345678")
        }

        #expect(cooldownError?.error == .smsCooldown)
        #expect(dailyError?.error == .smsDailyLimitExceeded)
    }

    @Test("인증 확인은 토큰을 돌려주고 번호와 코드를 그대로 싣는다")
    func smsVerify() async throws {
        let api = FakeAuthApi()

        let token = try await repository(api, await session()).verifyPhoneCode(phoneNumber: "010-1234-5678", code: " 123456 ")

        #expect(token == "3f2b8c1e-0000-4000-8000-000000000001")
        // 번호는 정규화하고 코드는 앞뒤 공백만 다듬는다(붙여넣기 대비).
        #expect(api.smsVerifyRequest.value == SmsVerifyRequestDto(phoneNumber: "01012345678", code: "123456"))
    }

    /// 빈 토큰을 통과시키면 화면은 "인증 완료"로 넘어가고, 400 은 한참 뒤 가입 제출에서야 터진다.
    /// uuid 를 끊는 것과 같은 이유로 여기서 끊는다.
    @Test("인증 응답에 토큰이 없으면 실패로 끊는다")
    func smsVerifyWithoutToken() async {
        let repository = repository(FakeAuthApi(verificationToken: ""), await session())

        let thrown = await #expect(throws: AuthException.self) {
            try await repository.verifyPhoneCode(phoneNumber: "01012345678", code: "123456")
        }

        #expect(thrown?.error == .unknown)
    }

    /// 만료·불일치·시도 초과는 모두 "재발송"이냐 "다시 입력"이냐가 달라 각각 올라와야 한다.
    @Test("인증 확인 실패는 코드별 사유로 올라온다")
    func smsVerifyFailures() async {
        let cases: [(status: Int, body: String, expected: AuthError)] = [
            (400, #"{"code":"USER204","message":"인증번호가 만료되었습니다. 다시 요청해 주세요."}"#, .smsCodeExpired),
            (400, #"{"code":"USER205","message":"인증번호가 일치하지 않습니다."}"#, .smsCodeMismatch),
            (429, #"{"code":"USER206","message":"입력 횟수를 초과했습니다. 인증번호를 다시 요청해 주세요."}"#, .smsTooManyAttempts),
            (400, #"{"code":"USER105","message":"전화번호 형식이 올바르지 않습니다."}"#, .invalidPhoneNumber),
            (503, #"{"code":"USER208","message":"지금은 인증을 진행할 수 없습니다. 잠시 후 다시 시도해 주세요."}"#, .smsUnavailable),
        ]

        for (status, body, expected) in cases {
            let api = FakeAuthApi(smsVerifyFailure: httpException(status, body))
            let repository = repository(api, await session())

            let thrown = await #expect(throws: AuthException.self, "\(body)") {
                try await repository.verifyPhoneCode(phoneNumber: "01012345678", code: "123456")
            }

            #expect(thrown?.error == expected, "\(body)")
        }
    }

    /// 토큰이 본문에 실리지 않으면 가입이 **전부** 400 이다(서버 `@NotBlank`).
    /// 서버가 중복 검사보다 먼저 토큰을 보므로, 이 필드가 비면 다른 입력이 멀쩡해도 끝이다.
    @Test("가입 요청에 문자 인증 토큰을 싣는다")
    func registerCarriesToken() async throws {
        let api = FakeAuthApi()

        _ = try await repository(api, await session()).register(newUser: newUser)

        #expect(api.registerRequest.value?.verificationToken == "3f2b8c1e-0000-4000-8000-000000000001")
        // 인증·가입이 같은 번호 형태를 쓰는지 — 다르면 서버 해시 비교가 어긋날 소지를 남긴다.
        #expect(api.registerRequest.value?.phoneNumber == "01012345678")
    }

    /// 토큰 만료·소진·번호 불일치가 한 코드로 뭉쳐 온다. 400 폴백(invalidRequest)에 맡기면
    /// "입력한 정보를 다시 확인해 주세요"가 떠서, 인증 단계로 되돌아가야 할 사용자가
    /// 아이디·비밀번호만 고치며 맴돈다.
    @Test("가입 400 USER207 은 휴대폰 미인증으로 올라온다")
    func register207() async {
        let repository = repository(
            FakeAuthApi(registerFailure: httpException(400, #"{"code":"USER207","message":"휴대폰 인증이 필요합니다."}"#)),
            await session()
        )

        let thrown = await #expect(throws: AuthException.self) { try await repository.register(newUser: newUser) }

        #expect(thrown?.error == .phoneNotVerified)
    }

    @Test("가입은 uuid 만 돌려주고 로그인시키지는 않는다")
    func registerDoesNotLogin() async throws {
        let api = FakeAuthApi()
        let session = await session()

        let uuid = try await repository(api, session).register(newUser: newUser)

        #expect(uuid == "uuid-1")
        #expect(api.registerRequest.value?.birthDate == "2000-01-01T00:00:00Z")
        // 서버가 토큰을 주지 않으므로 화면은 이어서 login 을 호출해야 한다.
        #expect(session.authState.value == .unauthenticated)
    }

    /// 서버 응답에는 사용자 식별자가 없다 — UUID 는 액세스 토큰의 `sub` 에서 나와야 한다.
    /// 저장된 세션의 userUuid 가 그 값과 같은지까지 확인한다.
    @Test("로그인 성공 시 액세스 토큰 sub 를 UUID 로 삼아 영속화한다")
    func loginPersists() async throws {
        let api = FakeAuthApi()
        let storage = FakeTokenStorage(nil)
        let session = await session(storage: storage)

        let uuid = try await repository(api, session).login(loginId: "moyeota_test", password: "Passw0rd!")

        #expect(uuid == "uuid-1")
        #expect(api.loginRequest.value == LoginRequestDto(loginId: "moyeota_test", password: "Passw0rd!"))
        #expect(session.authState.value == .authenticated(userUuid: "uuid-1"))
        #expect(
            storage.saved
                == StoredSession(userUuid: "uuid-1", accessToken: ACCESS_TOKEN_WITH_SUB, refreshToken: "refresh.jwt")
        )
    }

    /// `sub` 를 못 읽으면 "로그인은 됐는데 내가 누군지 모르는" 세션이 열린다.
    /// 그런 상태는 조용히 굳으므로 여기서 끊고, 세션도 열지 않는다.
    @Test("토큰에서 sub 를 읽지 못하면 세션을 열지 않는다")
    func loginWithoutSub() async {
        let storage = FakeTokenStorage(nil)
        let session = await session(storage: storage)
        let repository = repository(FakeAuthApi(accessToken: ACCESS_TOKEN_WITHOUT_SUB), session)

        let thrown = await #expect(throws: AuthException.self) {
            try await repository.login(loginId: "moyeota_test", password: "Passw0rd!")
        }

        #expect(thrown?.error == .unknown)
        #expect(session.authState.value == .unauthenticated)
        #expect(storage.saved == nil)
    }

    @Test("로그인 401 은 LOGIN_FAILED AuthException 으로 올라온다")
    func login401() async {
        let session = await session()
        let repository = repository(
            FakeAuthApi(loginFailure: httpException(401, #"{"code":"USER102","message":"아이디나 비밀번호가 다릅니다."}"#)),
            session
        )

        let thrown = await #expect(throws: AuthException.self) {
            try await repository.login(loginId: "moyeota_test", password: "wrong")
        }

        #expect(thrown?.error == .loginFailed)
        #expect(session.authState.value == .unauthenticated)
    }

    @Test("가입 409 는 중복 아이디로 올라온다")
    func register409() async {
        let repository = repository(
            FakeAuthApi(registerFailure: httpException(409, #"{"code":"USER101","message":"이미 존재하는 아이디입니다."}"#)),
            await session()
        )

        let thrown = await #expect(throws: AuthException.self) { try await repository.register(newUser: newUser) }

        #expect(thrown?.error == .loginIdDuplicated)
    }

    /// 가입 요청에 닉네임이 실려야 한다 — 서버 필수 필드이고, 이름(name)과는 다른 값이다.
    @Test("가입 요청에 닉네임을 싣는다")
    func registerCarriesNickname() async throws {
        let api = FakeAuthApi()

        _ = try await repository(api, await session()).register(newUser: newUser)

        #expect(api.registerRequest.value?.nickname == "모여타")
        #expect(api.registerRequest.value?.name == "홍길동")
    }

    /// 아이디·전화번호·닉네임 중복이 **전부 409** 다. 코드를 보지 않고 상태 코드로 폴백하면
    /// 전화번호가 겹쳤는데 "이미 사용 중인 아이디예요"가 떠서 사용자가 아이디만 계속 바꾸게 된다.
    @Test("가입 409 USER104 는 전화번호 중복으로 올라온다")
    func register104() async {
        let repository = repository(
            FakeAuthApi(registerFailure: httpException(409, #"{"code":"USER104","message":"이미 가입된 전화번호입니다."}"#)),
            await session()
        )

        let thrown = await #expect(throws: AuthException.self) { try await repository.register(newUser: newUser) }

        #expect(thrown?.error == .phoneNumberDuplicated)
        #expect(thrown?.serverMessage == "이미 가입된 전화번호입니다.")
    }

    /// 서버 검사 순서는 아이디 → 전화번호 → 닉네임이라 **닉네임 중복도 409 로 온다**.
    /// 코드를 보지 않고 상태 코드로 폴백하면 "이미 사용 중인 아이디예요"가 떠서
    /// 사용자가 아이디만 계속 바꾸게 된다.
    @Test("가입 409 USER108 은 닉네임 중복으로 올라온다")
    func register108() async {
        let repository = repository(
            FakeAuthApi(registerFailure: httpException(409, #"{"code":"USER108","message":"이미 사용 중인 닉네임입니다."}"#)),
            await session()
        )

        let thrown = await #expect(throws: AuthException.self) { try await repository.register(newUser: newUser) }

        #expect(thrown?.error == .nicknameDuplicated)
    }

    @Test("닉네임 중복 확인은 서버 exists 를 그대로 돌려준다")
    func nicknameExists() async throws {
        let taken = FakeAuthApi(nicknameExists: true)
        let free = FakeAuthApi(nicknameExists: false)

        #expect(try await repository(taken, await session()).isNicknameTaken(nickname: "모여타"))
        #expect(try await !repository(free, await session()).isNicknameTaken(nickname: "모여타"))
        #expect(taken.nicknameRequest.value == NicknameCheckRequestDto(nickname: "모여타"))
    }

    /// 서버는 앞뒤 공백을 strip 한 뒤 검사하고 저장한다. 앱이 다듬지 않으면 `"모여타 "` 가
    /// "사용 가능"으로 보이고선 가입 때 같은 닉네임으로 409 를 맞는다.
    @Test("닉네임 중복 확인은 앞뒤 공백을 다듬어 보낸다")
    func nicknameTrimmed() async throws {
        let api = FakeAuthApi()

        _ = try await repository(api, await session()).isNicknameTaken(nickname: "  모여타  ")

        #expect(api.nicknameRequest.value?.nickname == "모여타")
    }

    /// 형식이 틀리면 서버가 exists 판정 전에 400 USER107 을 낸다 — "중복"이 아니라 "형식 오류"다.
    @Test("닉네임 중복 확인의 400 USER107 은 형식 오류로 올라온다")
    func nickname107() async {
        let repository = repository(
            FakeAuthApi(
                nicknameFailure: httpException(400, #"{"code":"USER107","message":"닉네임은 2~10자의 한글, 영문, 숫자만 가능합니다."}"#)
            ),
            await session()
        )

        let thrown = await #expect(throws: AuthException.self) { try await repository.isNicknameTaken(nickname: "!") }

        #expect(thrown?.error == .invalidNickname)
    }

    // ───────────────────────── 전화번호 가입 여부 선확인 ─────────────────────────

    /// 서버도 하이픈을 지우지만(`PhoneNumber` VO), 앱이 발송·확인·가입과 **다른 형태**를 보내면
    /// 「발송은 되는데 선확인만 400」처럼 번호 표기부터 의심해야 하는 어긋남이 생긴다.
    /// 네 경로가 모두 `AuthPolicy.normalizePhoneNumber` 를 거치는지를 여기서 못 박는다.
    @Test("가입 여부 확인은 하이픈을 떼고 보낸다")
    func phoneCheckNormalizes() async throws {
        let api = FakeAuthApi()

        _ = try await repository(api, await session()).isPhoneRegistered(phoneNumber: "010-1234-5678")

        #expect(api.phoneRequest.value == PhoneCheckRequestDto(phoneNumber: "01012345678"))
    }

    @Test("가입 여부 확인은 exists 를 그대로 돌려준다")
    func phoneCheckExists() async throws {
        #expect(try await repository(FakeAuthApi(phoneExists: true), await session()).isPhoneRegistered(phoneNumber: "01012345678"))
        #expect(try await !repository(FakeAuthApi(phoneExists: false), await session()).isPhoneRegistered(phoneNumber: "01012345678"))
    }

    /// **발송과 확인의 형식 오류 코드가 다르다.** 발송 요청에는 `@Pattern` 이 있어 Bean Validation 이
    /// 먼저 걸려 `INVALID_REQUEST` 이고, 확인 요청에는 없어 서버 `PhoneNumber` VO 가 걸러
    /// 400 `USER105` 다(실측 2026-11-01, 로컬 :8080).
    ///
    /// 매핑을 놓치면 400 폴백이 `invalidRequest` 인데 serverMessage 가 `"phoneNumber"` 로 시작하지도
    /// 않아 화면의 분기에 걸리지 않고 서버 원문이 그대로 뜬다.
    @Test("가입 여부 확인의 400 USER105 는 INVALID_PHONE_NUMBER 로 올라온다")
    func phoneCheck105() async {
        let repository = repository(
            FakeAuthApi(phoneCheckFailure: httpException(400, #"{"code":"USER105","message":"전화번호 형식이 올바르지 않습니다."}"#)),
            await session()
        )

        let thrown = await #expect(throws: AuthException.self) { try await repository.isPhoneRegistered(phoneNumber: "abc") }

        #expect(thrown?.error == .invalidPhoneNumber)
    }

    /// null 필드는 본문에서 빠진다 — 서버가 "넘어온 것만 갱신"하므로 null 로 지우기를 표현할 수 없다.
    @Test("프로필 수정은 넘어온 값만 서버로 보낸다")
    func updateProfilePassesGivenValues() async throws {
        let userApi = FakeUserApi()

        try await repository(FakeAuthApi(), await session(), userApi).updateProfile(nickname: " 새닉 ", imageKey: nil)

        #expect(userApi.profileUpdates.value == [UpdateProfileRequest(nickname: "새닉", imageKey: nil)])
    }

    @Test("프로필 수정 실패도 AuthException 으로 좁힌다")
    func updateProfileFailure() async {
        let userApi = FakeUserApi(
            profileFailure: httpException(409, #"{"code":"USER108","message":"이미 사용 중인 닉네임입니다."}"#)
        )
        let repository = repository(FakeAuthApi(), await session(), userApi)

        let thrown = await #expect(throws: AuthException.self) {
            try await repository.updateProfile(nickname: "겹치는닉", imageKey: nil)
        }

        #expect(thrown?.error == .nicknameDuplicated)
    }

    // ───────────────────────────── 프로필 이미지 ─────────────────────────────

    /// **오늘 실제로 났던 결함을 못 박는 자리다** — 앱이 이미지를 골라도 `imageKey = null` 만 보내
    /// PATCH 가 아무것도 바꾸지 않고 204 로 끝났다. 서버는 빠진 필드를 건드리지 않으므로
    /// 요청은 성공으로 보이고, 사용자는 「저장됐어요」를 본 뒤 화면을 다시 열면 옛 이미지를 만난다.
    ///
    /// 닉네임이 `null` **그대로** 남는 것도 함께 본다. 빈 문자열로 바뀌면 서버가 닉네임까지 갱신하려 들어
    /// 400 이고, 서버는 imageKey 를 닉네임보다 먼저 검사하므로 거절되면 **이미지도 함께 안 바뀐다**.
    @Test("이미지 키만 바꿀 때 닉네임을 싣지 않는다")
    func updateImageKeyOnly() async throws {
        let userApi = FakeUserApi()

        try await repository(FakeAuthApi(), await session(), userApi)
            .updateProfile(nickname: nil, imageKey: "profile/presets/03.png")

        #expect(userApi.profileUpdates.value == [UpdateProfileRequest(nickname: nil, imageKey: "profile/presets/03.png")])
    }

    /// 서버가 준 순서가 곧 격자에 그려지는 순서다 — 정렬하거나 뒤섞으면 서버가 정한 순서가 사라진다.
    /// 같은 단언이 key·url 이 뒤집히지 않는 것까지 본다(뒤집히면 PATCH 가 400 `USER112` 다).
    @Test("프로필 이미지 목록을 서버 순서 그대로 도메인으로 넘긴다")
    func profileImagesInServerOrder() async throws {
        let images = try await repository(FakeAuthApi(), await session(), FakeUserApi()).getProfileImages()

        #expect(
            images == [
                ProfileImage(key: "profile/presets/01.png", url: "https://cdn.moyeota.co.kr/profile/presets/01.png"),
                ProfileImage(key: "profile/presets/02.png", url: "https://cdn.moyeota.co.kr/profile/presets/02.png"),
            ]
        )
    }

    /// 설정이 비어 0장이 와도 **정상 응답**이다. 여기서 예외로 바꾸면 이미지와 상관없는
    /// 닉네임 수정까지 같은 화면에서 막힌다.
    @Test("빈 이미지 목록도 그대로 통과한다")
    func emptyProfileImages() async throws {
        let userApi = FakeUserApi(profileImages: [])

        #expect(try await repository(FakeAuthApi(), await session(), userApi).getProfileImages().isEmpty)
    }

    /// 되돌리기는 204·멱등이라 돌려받을 값이 없고, 확인할 수 있는 건 「정확히 한 번 나갔는가」뿐이다.
    /// 재시도를 끼워 넣지 않는지까지 보는 이유는 경로가 **회원 탈퇴와 한 조각 차이**이기 때문이다
    /// (`DELETE /users/me/profile-image` 대 `DELETE /users/me`) — 경로 검사는
    /// `AuthenticatedPathContractTest` 쪽이 맡는다.
    @Test("되돌리기는 DELETE 를 한 번만 부른다")
    func resetOnce() async throws {
        let userApi = FakeUserApi()

        try await repository(FakeAuthApi(), await session(), userApi).resetProfileImage()

        #expect(userApi.resetCount.value == 1)
    }

    /// 새로 들어온 두 메서드도 `HttpException` 을 밖으로 흘리지 않아야 한다. 화면은 `AuthException` 만
    /// 다루므로 그대로 새면 「다시 로그인」 안내로 이어지지 못하고 처리되지 않은 예외가 된다.
    @Test("프로필 이미지 조회와 되돌리기 실패도 AuthException 으로 좁힌다")
    func profileImageFailures() async {
        let expired = httpException(401, #"{"code":"USER005","message":"로그인이 필요합니다."}"#)
        let listing = repository(FakeAuthApi(), await session(), FakeUserApi(profileImagesFailure: expired))
        let resetting = repository(FakeAuthApi(), await session(), FakeUserApi(resetProfileImageFailure: expired))

        let listFailure = await #expect(throws: AuthException.self) { try await listing.getProfileImages() }
        let resetFailure = await #expect(throws: AuthException.self) { try await resetting.resetProfileImage() }

        #expect(listFailure?.error == .sessionExpired)
        #expect(resetFailure?.error == .sessionExpired)
    }

    /// FCM 토큰은 로그인 전에 도착해 보류돼 있는 게 정상이다(앱 최초 실행·로그인 화면에서의 회전).
    /// 세션이 열리는 이 순간이 서버에 실어 보낼 수 있는 첫 시점이라, 로그인 경로가 직접 이어 준다.
    @Test("로그인 성공 시 보류된 푸시 토큰을 서버에 등록한다")
    func loginRegistersPendingToken() async throws {
        let userApi = FakeUserApi()
        let session = await session()
        let registrar = FcmTokenRegistrar(userApi: userApi, session: session)
        try await registrar.onTokenAvailable(token: "device-token")
        #expect(userApi.fcmCalls.value.isEmpty, "로그인 전인데 보냈다")

        _ = try await repository(FakeAuthApi(), session, userApi, registrar: registrar)
            .login(loginId: "moyeota_test", password: "Passw0rd!")

        #expect(userApi.fcmCalls.value == ["PUT:device-token"])
    }

    /// 등록 실패로 로그인이 실패한 것처럼 보이면 안 된다 — 잃는 건 도착 알림 하나뿐이다.
    @Test("푸시 등록이 실패해도 로그인은 성공한다")
    func loginSurvivesPushFailure() async throws {
        let userApi = FakeUserApi(fcmFailure: IOException("offline"))
        let session = await session()
        let registrar = FcmTokenRegistrar(userApi: userApi, session: session)
        try await registrar.onTokenAvailable(token: "device-token")

        let uuid = try await repository(FakeAuthApi(), session, userApi, registrar: registrar)
            .login(loginId: "moyeota_test", password: "Passw0rd!")

        #expect(uuid == "uuid-1")
        #expect(session.authState.value == .authenticated(userUuid: "uuid-1"))
    }

    /// **순서가 이 테스트의 전부다.** 서버는 `@CurrentUser` 로 대상을 찾으므로 세션을 먼저 비우면
    /// Bearer 가 사라져 401 이 나고, 서버에는 죽은 토큰이 남아 다음 사용자의 도착 알림이
    /// 이 기기로 온다. 그래서 해제 시점에 액세스 토큰이 아직 살아 있는지를 직접 붙잡아 확인한다.
    @Test("로그아웃은 세션을 비우기 전에 푸시 토큰을 해제한다")
    func logoutUnregistersBeforeClearing() async throws {
        let session = await loggedInSession()
        let userApi = TokenProbingUserApi { await session.currentAccessToken() }

        try await repository(FakeAuthApi(), session, userApi).logout()

        #expect(userApi.deleteCount.value == 1)
        #expect(userApi.accessTokenAtDelete.value == "access.jwt")
        #expect(session.authState.value == .unauthenticated)
    }

    /// **로그아웃이 중간에 취소돼도 세션은 비워져야 한다.** 호출부는 화면에 묶인 태스크라, 푸시 해제를
    /// 기다리는 최대 2초 안에 화면이 사라지면 취소된다. `FcmTokenRegistrar` 는 취소만은 되던지므로,
    /// 원본의 예전 구현은 그 취소가 `session.onLoggedOut()` 에 닿지 못해 **세션이 그대로 남았다** —
    /// 사용자는 로그아웃된 줄 아는데 토큰은 살아 있었다(공용 기기면 안전 문제다).
    ///
    /// 해제가 매달려 있는 동안 정확히 취소를 걸어 그 창을 재현한다. `entered` 를 기다리는 게 중요하다
    /// — 그냥 취소하면 `logout()` 에 들어가기도 전에 끝나 다른 상황을 검증하게 된다.
    @Test("로그아웃 중 호출부가 취소돼도 세션은 비워진다")
    func logoutSurvivesCancellation() async {
        let session = await loggedInSession()
        let entered = AsyncSignal()
        let userApi = SuspendingFcmUserApi(entered: entered, hanging: .milliseconds(100))
        let api = FakeAuthApi()
        let repository = repository(api, session, userApi)

        let job = Task { try await repository.logout() }
        await entered.wait()
        // 화면이 사라져 호출 태스크가 취소된 순간.
        job.cancel()
        _ = try? await job.value

        #expect(session.authState.value == .unauthenticated)
        #expect(await session.currentAccessToken() == nil)
        // iOS 추가 단언: 묶음 전체가 취소를 물려받지 않아야 서버 무효화 요청도 취소되지 않고 나간다.
        #expect(api.logoutRequest.value == RefreshTokenRequestDto(refreshToken: "refresh.jwt"))
        #expect(api.logoutSawCancellation.value == false, "서버 무효화가 호출부 취소를 물려받았다")
    }

    /// iOS 추가분. 원본은 `withTimeoutOrNull` 이라 상한이 라이브러리 몫이지만 여기서는 직접 경합시킨다.
    /// 해제가 끝나지 않아도 세션을 비우고 서버 무효화까지 가는지 실제 2초를 들여 확인한다.
    @Test("푸시 해제가 매달려도 로그아웃은 상한 안에 끝난다")
    func logoutBoundsUnregister() async throws {
        let api = FakeAuthApi()
        let session = await loggedInSession()
        let userApi = SuspendingFcmUserApi(entered: AsyncSignal(), hanging: .seconds(60))
        let repository = repository(api, session, userApi)

        let elapsed = try await ContinuousClock().measure { try await repository.logout() }

        #expect(elapsed >= .milliseconds(1900))
        #expect(elapsed < .seconds(10))
        #expect(session.authState.value == .unauthenticated)
        #expect(api.logoutRequest.value == RefreshTokenRequestDto(refreshToken: "refresh.jwt"))
    }

    /// 보낼 Bearer 가 없으니 401 만 받는다. 로그아웃 경로에 헛된 왕복을 끼워 넣지 않는다.
    @Test("미로그인 상태의 로그아웃은 푸시 해제도 부르지 않는다")
    func loggedOutLogoutSkipsPush() async throws {
        let userApi = FakeUserApi()

        try await repository(FakeAuthApi(), await session(), userApi).logout()

        #expect(userApi.fcmCalls.value.isEmpty)
    }

    /// 오프라인에서 해제가 실패해도 로그아웃은 그대로 끝나야 한다 — "절대 실패 안 함" 계약.
    @Test("푸시 해제가 실패해도 로그아웃은 완료된다")
    func logoutSurvivesPushFailure() async throws {
        let userApi = FakeUserApi(fcmFailure: IOException("offline"))
        let session = await loggedInSession()

        try await repository(FakeAuthApi(), session, userApi).logout()

        #expect(session.authState.value == .unauthenticated)
        #expect(await session.currentAccessToken() == nil)
    }

    @Test("로그아웃은 서버에 리프레시 무효화를 요청한다")
    func logoutInvalidatesRefresh() async throws {
        let api = FakeAuthApi()
        let session = await loggedInSession()

        try await repository(api, session).logout()

        #expect(api.logoutRequest.value == RefreshTokenRequestDto(refreshToken: "refresh.jwt"))
        #expect(session.authState.value == .unauthenticated)
    }

    @Test("서버 로그아웃이 실패해도 로컬 세션은 비워지고 예외를 올리지 않는다")
    func logoutSurvivesServerFailure() async throws {
        let api = FakeAuthApi(logoutFailure: IOException("offline"))
        let session = await loggedInSession()

        // 여기서 던지면 오프라인 사용자가 로그아웃하지 못하고 갇힌다.
        try await repository(api, session).logout()

        #expect(session.authState.value == .unauthenticated)
        #expect(await session.currentAccessToken() == nil)
    }

    @Test("미로그인 상태의 로그아웃은 서버를 부르지 않는다")
    func loggedOutLogoutSkipsServer() async throws {
        let api = FakeAuthApi()

        try await repository(api, await session()).logout()

        #expect(api.logoutRequest.value == nil)
    }

    // ─────────────────────────────── 회원 탈퇴 ───────────────────────────────

    /// 서버 `UserDeletionRequest` 는 `password` 하나다. 다듬지 않고 그대로 싣는다 — trim 하면 다른 값이 된다.
    @Test("탈퇴는 입력한 비밀번호를 그대로 본문에 싣는다")
    func deleteCarriesPassword() async throws {
        let userApi = FakeUserApi()

        try await repository(FakeAuthApi(), await loggedInSession(), userApi).deleteAccount(password: " Passw0rd! ")

        #expect(userApi.deletions.value == [AccountDeletionRequest(password: " Passw0rd! ")])
    }

    /// **204 를 받으면 세션이 비워져야 한다.** 서버가 리프레시를 전량 취소하고 인증 캐시까지 비우므로
    /// 그 뒤의 모든 요청은 401 이다 — 로컬 토큰을 들고 있으면 다음 화면 조회가 401 을 맞고
    /// `AuthError.sessionExpired` 가 올라와 스스로 탈퇴한 사용자에게 「세션이 만료됐어요」가 뜬다.
    @Test("탈퇴가 성공하면 세션이 비워지고 미로그인으로 전이한다")
    func deleteClearsSession() async throws {
        let session = await loggedInSession()

        try await repository(FakeAuthApi(), session).deleteAccount(password: "Passw0rd!")

        #expect(session.authState.value == .unauthenticated)
        #expect(await session.currentAccessToken() == nil)
        #expect(await session.currentRefreshToken() == nil)
    }

    /// **로그아웃보다 한 가지 넓다.** `logout()` 은 "진행 중인 방" 기억을 일부러 남기지만
    /// (계정에 매인 값이라 같은 계정 재로그인 시 되살아나야 한다) 탈퇴한 계정은 다시 로그인할 길이 없다.
    /// 남겨 두면 다음 사용자의 기기에 앞 사람의 방 id 가 그대로 남는다.
    @Test("탈퇴는 진행 중인 방 기억까지 지운다")
    func deleteClearsActiveParty() async throws {
        let storage = SpyActivePartyStorage(RememberedParty(partyId: "42", ownerUuid: "uuid-1"))

        try await repository(FakeAuthApi(), await loggedInSession(), activePartyStorage: storage)
            .deleteAccount(password: "Passw0rd!")

        #expect(try await storage.load() == nil)
    }

    /// 반대쪽 못 박기 — 로그아웃은 그 기억을 남긴다. 둘이 같아지면 재로그인 복귀가 깨진다.
    @Test("로그아웃은 진행 중인 방 기억을 남긴다")
    func logoutKeepsActiveParty() async throws {
        let remembered = RememberedParty(partyId: "42", ownerUuid: "uuid-1")
        let storage = SpyActivePartyStorage(remembered)

        try await repository(FakeAuthApi(), await loggedInSession(), activePartyStorage: storage).logout()

        #expect(try await storage.load() == remembered)
    }

    /// 비밀번호를 틀렸거나 진행 중인 합승이 있으면 **아무 일도 없었던 것처럼** 계속 쓸 수 있어야 한다.
    /// 세션을 먼저 비우는 구현(= 로그아웃과 같은 순서)이면 400 한 번에 사용자가 로그아웃된다.
    @Test("탈퇴가 실패하면 세션과 방 기억이 그대로 남는다")
    func deleteFailureKeepsEverything() async throws {
        let failures: [(failure: any Error, expected: AuthError)] = [
            (httpException(400, #"{"code":"USER111","message":"비밀번호가 일치하지 않습니다."}"#), .passwordMismatch),
            (httpException(409, #"{"code":"USER110","message":"진행 중인 합승이 있어 탈퇴할 수 없습니다."}"#), .ongoingPartyExists),
            (IOException("offline"), .network),
        ]

        for (failure, expected) in failures {
            let remembered = RememberedParty(partyId: "42", ownerUuid: "uuid-1")
            let storage = SpyActivePartyStorage(remembered)
            let session = await loggedInSession()
            let userApi = FakeUserApi(deleteAccountFailure: failure)
            let repository = repository(FakeAuthApi(), session, userApi, activePartyStorage: storage)

            let thrown = await #expect(throws: AuthException.self) {
                try await repository.deleteAccount(password: "wrong")
            }

            #expect(thrown?.error == expected)
            #expect(session.authState.value == .authenticated(userUuid: "uuid-1"), "\(expected) 에서 세션이 날아갔다")
            #expect(try await storage.load() == remembered, "\(expected) 에서 방 기억이 날아갔다")
        }
    }

    /// **탈퇴는 푸시 토큰을 따로 해제하지 않는다.** 서버 `User.delete()` 가 `fcmToken` 을 비우므로
    /// 왕복이 필요 없고, 미리 불러 두면 400·409 로 탈퇴가 실패했을 때 멀쩡한 사용자의 알림만 끊긴다
    /// (로그아웃은 반대로 반드시 불러야 한다 — 그쪽은 계정이 남기 때문이다).
    @Test("탈퇴는 푸시 토큰 해제를 부르지 않는다")
    func deleteSkipsPushUnregister() async throws {
        let userApi = FakeUserApi()
        let session = await loggedInSession()
        let registrar = FcmTokenRegistrar(userApi: userApi, session: session)
        try await registrar.onTokenAvailable(token: "device-token")
        userApi.fcmCalls.value = []

        try await repository(FakeAuthApi(), session, userApi, registrar: registrar).deleteAccount(password: "Passw0rd!")

        #expect(userApi.fcmCalls.value.isEmpty, "탈퇴가 FCM 해제를 불렀다: \(userApi.fcmCalls.value)")
    }

    /// 서버 토큰은 이미 전량 취소됐다 — `POST /auth/logout` 을 더 보내는 건 401 만 받는 헛된 왕복이다.
    @Test("탈퇴는 로그아웃 API 를 덧붙여 부르지 않는다")
    func deleteSkipsLogoutApi() async throws {
        let api = FakeAuthApi()

        try await repository(api, await loggedInSession()).deleteAccount(password: "Passw0rd!")

        #expect(api.logoutRequest.value == nil)
    }

    /// 로컬 저장소가 터져도(디스크 꽉 참·손상) 탈퇴는 성공으로 끝나야 한다 —
    /// 서버 계정은 이미 사라졌으므로 "실패"로 올리면 사용자가 이미 없는 계정의 탈퇴를 다시 시도한다.
    @Test("방 기억 삭제가 실패해도 탈퇴는 성공으로 끝난다")
    func deleteSurvivesStorageFailure() async throws {
        let storage = SpyActivePartyStorage(RememberedParty(partyId: "42", ownerUuid: "uuid-1"), failOnClear: true)
        let session = await loggedInSession()

        try await repository(FakeAuthApi(), session, activePartyStorage: storage).deleteAccount(password: "Passw0rd!")

        #expect(session.authState.value == .unauthenticated)
    }

    /// iOS 추가분. 원본 `withContext(NonCancellable)` 을 별도 태스크로 옮긴 자리의 반대쪽 구간이다 —
    /// 204 뒤에 호출부가 취소돼도 방 기억과 세션을 끝까지 비우는지, 저장소를 매달아 그 창을 재현한다.
    @Test("탈퇴 204 뒤에 호출부가 취소돼도 기억과 세션을 비운다")
    func deleteCleanupSurvivesCancellation() async throws {
        let entered = AsyncSignal()
        let storage = SuspendingActivePartyStorage(entered: entered)
        let session = await loggedInSession()
        let repository = repository(FakeAuthApi(), session, activePartyStorage: storage)

        let job = Task { try await repository.deleteAccount(password: "Passw0rd!") }
        await entered.wait()
        job.cancel()
        _ = try? await job.value

        #expect(storage.cleared.value)
        #expect(session.authState.value == .unauthenticated)
    }

    private func httpException(_ code: Int, _ body: String) -> HttpException {
        HttpException(Response<Void>.error(code, body))
    }
}

/// 인메모리 "진행 중인 방" 기억. `failOnClear` 로 디스크 실패를 흉내 낸다.
private final class SpyActivePartyStorage: ActivePartyStorage {
    private let value: Locked<RememberedParty?>
    private let failOnClear: Bool

    init(_ remembered: RememberedParty? = nil, failOnClear: Bool = false) {
        value = Locked(remembered)
        self.failOnClear = failOnClear
    }

    func load() async throws -> RememberedParty? { value.value }

    func save(party: RememberedParty) async throws { value.value = party }

    func clear() async throws {
        if failOnClear { throw IOException("디스크 실패") }
        value.value = nil
    }
}

/// `clear` 를 잠시 매달아 둔다. 호출부 취소가 전해지면 `Task.sleep` 이 던져 `cleared` 가 켜지지 않는다.
private final class SuspendingActivePartyStorage: ActivePartyStorage {
    private let entered: AsyncSignal
    let cleared = Locked(false)

    init(entered: AsyncSignal) {
        self.entered = entered
    }

    func load() async throws -> RememberedParty? { nil }

    func save(party: RememberedParty) async throws {}

    func clear() async throws {
        entered.complete()
        try await Task.sleep(for: .milliseconds(100))
        cleared.value = true
    }
}

/// 페이로드 `{"sub":"uuid-1","tokenType":"ACCESS"}` 를 base64url 로 담은 가짜 액세스 토큰. 서명은 검증되지 않는다.
private let ACCESS_TOKEN_WITH_SUB = "header.eyJzdWIiOiJ1dWlkLTEiLCJ0b2tlblR5cGUiOiJBQ0NFU1MifQ.signature"

/// 페이로드 `{"tokenType":"ACCESS"}` — sub 가 없는 비정상 토큰.
private let ACCESS_TOKEN_WITHOUT_SUB = "header.eyJ0b2tlblR5cGUiOiJBQ0NFU1MifQ.signature"

private final class FakeAuthApi: AuthApi {
    private let accessToken: String
    private let registerFailure: (any Error)?
    private let loginFailure: (any Error)?
    private let logoutFailure: (any Error)?
    private let nicknameExists: Bool
    private let nicknameFailure: (any Error)?
    private let phoneExists: Bool
    private let phoneCheckFailure: (any Error)?
    private let smsSendFailure: (any Error)?
    private let smsVerifyFailure: (any Error)?
    private let verificationToken: String

    let registerRequest = Locked<RegisterRequestDto?>(nil)
    let nicknameRequest = Locked<NicknameCheckRequestDto?>(nil)
    let phoneRequest = Locked<PhoneCheckRequestDto?>(nil)
    let loginRequest = Locked<LoginRequestDto?>(nil)
    let logoutRequest = Locked<RefreshTokenRequestDto?>(nil)
    let logoutSawCancellation = Locked(false)
    let smsSendRequest = Locked<SmsSendRequestDto?>(nil)
    let smsVerifyRequest = Locked<SmsVerifyRequestDto?>(nil)

    init(
        accessToken: String = ACCESS_TOKEN_WITH_SUB,
        registerFailure: (any Error)? = nil,
        loginFailure: (any Error)? = nil,
        logoutFailure: (any Error)? = nil,
        nicknameExists: Bool = false,
        nicknameFailure: (any Error)? = nil,
        phoneExists: Bool = false,
        phoneCheckFailure: (any Error)? = nil,
        smsSendFailure: (any Error)? = nil,
        smsVerifyFailure: (any Error)? = nil,
        verificationToken: String = "3f2b8c1e-0000-4000-8000-000000000001"
    ) {
        self.accessToken = accessToken
        self.registerFailure = registerFailure
        self.loginFailure = loginFailure
        self.logoutFailure = logoutFailure
        self.nicknameExists = nicknameExists
        self.nicknameFailure = nicknameFailure
        self.phoneExists = phoneExists
        self.phoneCheckFailure = phoneCheckFailure
        self.smsSendFailure = smsSendFailure
        self.smsVerifyFailure = smsVerifyFailure
        self.verificationToken = verificationToken
    }

    func sendSmsCode(request: SmsSendRequestDto) async throws {
        smsSendRequest.value = request
        if let smsSendFailure { throw smsSendFailure }
    }

    func verifySmsCode(request: SmsVerifyRequestDto) async throws -> SmsVerifyResponse {
        smsVerifyRequest.value = request
        if let smsVerifyFailure { throw smsVerifyFailure }
        return SmsVerifyResponse(verificationToken: verificationToken)
    }

    func register(request: RegisterRequestDto) async throws -> RegisterResponse {
        registerRequest.value = request
        if let registerFailure { throw registerFailure }
        return RegisterResponse(uuid: "uuid-1")
    }

    func login(request: LoginRequestDto) async throws -> TokenResponse {
        loginRequest.value = request
        if let loginFailure { throw loginFailure }
        // 서버는 사용자 식별자를 주지 않는다 — 토큰 쌍이 전부다.
        return TokenResponse(accessToken: accessToken, refreshToken: "refresh.jwt")
    }

    // 재발급은 Authenticator 경로 전용이라 Repository 테스트에서는 호출되지 않는다.
    func reissue(request: RefreshTokenRequestDto) async throws -> Response<TokenResponse> {
        throw IllegalStateException("reissue 는 TokenAuthenticator 가 호출한다")
    }

    func logout(request: RefreshTokenRequestDto) async throws {
        logoutRequest.value = request
        logoutSawCancellation.value = Task.isCancelled
        if let logoutFailure { throw logoutFailure }
    }

    func checkNickname(request: NicknameCheckRequestDto) async throws -> NicknameCheckResponse {
        nicknameRequest.value = request
        if let nicknameFailure { throw nicknameFailure }
        return NicknameCheckResponse(exists: nicknameExists)
    }

    func checkPhone(request: PhoneCheckRequestDto) async throws -> PhoneCheckResponse {
        phoneRequest.value = request
        if let phoneCheckFailure { throw phoneCheckFailure }
        return PhoneCheckResponse(exists: phoneExists)
    }
}

/// 목록 응답 픽스처. 백엔드 `ProfileImages` 설정 기준이다 — **실서버로 확인한 값이 아니다**
/// (원본 작성 때 로컬 DB 가 죽어 API 를 호출하지 못했다). key 는 `profile/presets/NN.png` 로
/// 제로패딩이고, url 은 같은 key 를 CDN 주소에 붙인 값이다.
///
/// 실제 목록은 16장이지만 두 장만 둔다 — 여기서 확인하는 건 「서버 순서가 보존되는가」와
/// 「key·url 이 뒤집히지 않는가」뿐이고, 장수는 그 둘과 무관하다.
private let PRESET_PROFILE_IMAGES = [
    ProfileImageResponse(key: "profile/presets/01.png", url: "https://cdn.moyeota.co.kr/profile/presets/01.png"),
    ProfileImageResponse(key: "profile/presets/02.png", url: "https://cdn.moyeota.co.kr/profile/presets/02.png"),
]

/// 기본값은 실서버 실측 응답 그대로(testuser1).
private final class FakeUserApi: UserApi {
    private let uuid: String
    private let name: String?
    private let failure: (any Error)?
    private let fcmFailure: (any Error)?
    private let profileFailure: (any Error)?
    private let deleteAccountFailure: (any Error)?
    private let profileImages: [ProfileImageResponse]
    private let profileImagesFailure: (any Error)?
    private let resetProfileImageFailure: (any Error)?

    /// 푸시 토큰 호출이 **일어난 순서**. 어떤 호출이 실제로 나갔는지를 그대로 남긴다.
    let fcmCalls = Locked<[String]>([])

    /// PATCH 로 실제 나간 본문. null 필드가 어떻게 실렸는지까지 확인한다.
    let profileUpdates = Locked<[UpdateProfileRequest]>([])

    /// 탈퇴 요청으로 나간 본문. 비밀번호가 다듬어지지 않았는지까지 본다.
    let deletions = Locked<[AccountDeletionRequest]>([])

    /// 되돌리기가 나간 횟수. 204 라 돌려받을 값이 없어 **"몇 번 나갔는가"만이 검증 대상**이다 —
    /// 경로가 회원 탈퇴(`DELETE /users/me`)와 한 조각 차이라 왕복이 늘어나는 것 자체가 위험 신호다.
    let resetCount = Locked(0)

    init(
        uuid: String = "01a06145-3caf-7614-a3bd-cee6e25316b1",
        name: String? = "김성윤",
        failure: (any Error)? = nil,
        fcmFailure: (any Error)? = nil,
        profileFailure: (any Error)? = nil,
        deleteAccountFailure: (any Error)? = nil,
        profileImages: [ProfileImageResponse] = PRESET_PROFILE_IMAGES,
        profileImagesFailure: (any Error)? = nil,
        resetProfileImageFailure: (any Error)? = nil
    ) {
        self.uuid = uuid
        self.name = name
        self.failure = failure
        self.fcmFailure = fcmFailure
        self.profileFailure = profileFailure
        self.deleteAccountFailure = deleteAccountFailure
        self.profileImages = profileImages
        self.profileImagesFailure = profileImagesFailure
        self.resetProfileImageFailure = resetProfileImageFailure
    }

    func getMyProfile() async throws -> UserProfileResponse {
        if let failure { throw failure }
        return UserProfileResponse(uuid: uuid, name: name)
    }

    func updateProfile(request: UpdateProfileRequest) async throws {
        profileUpdates.append(request)
        if let profileFailure { throw profileFailure }
    }

    func getProfileImages() async throws -> [ProfileImageResponse] {
        if let profileImagesFailure { throw profileImagesFailure }
        return profileImages
    }

    func resetProfileImage() async throws {
        // 실패해도 세어 둔다 — "몇 번 나갔는가"는 실패 경로에서도 검증 대상이다(탈퇴와 경로가 비슷하다).
        resetCount.update { $0 += 1 }
        if let resetProfileImageFailure { throw resetProfileImageFailure }
    }

    func registerFcmToken(request: FcmTokenRequest) async throws {
        if let fcmFailure { throw fcmFailure }
        fcmCalls.append("PUT:\(request.token)")
    }

    func deleteFcmToken() async throws {
        if let fcmFailure { throw fcmFailure }
        fcmCalls.append("DELETE")
    }

    func deleteAccount(request: AccountDeletionRequest) async throws {
        // 실패해도 기록은 남긴다 — "무엇을 보내려 했는가"가 실패 경로에서도 검증 대상이다.
        deletions.append(request)
        if let deleteAccountFailure { throw deleteAccountFailure }
    }

    // UserApi 에 탑승 기록 조회(GET /users/me/parties)가 들어와 생긴 구현. 인증 흐름과 무관하다.
    func getMyRideRecords(cursor: Int64?, size: Int) async throws -> RideRecordPageResponse {
        throw IllegalStateException("인증 흐름과 무관하다")
    }
}

/// 해제가 불린 **그 순간의** 액세스 토큰을 붙잡아 둔다.
/// "세션 정리보다 먼저 해제했는가"는 호출 횟수로는 알 수 없고, 이렇게 시점을 찍어야만 드러난다.
private final class TokenProbingUserApi: UserApi {
    private let accessToken: @Sendable () async -> String?
    let accessTokenAtDelete = Locked<String?>(nil)
    let deleteCount = Locked(0)

    init(accessToken: @escaping @Sendable () async -> String?) {
        self.accessToken = accessToken
    }

    func getMyProfile() async throws -> UserProfileResponse { throw IllegalStateException("푸시 해제 순서 검증 전용 페이크다") }
    func updateProfile(request: UpdateProfileRequest) async throws { throw IllegalStateException("푸시 해제 순서 검증 전용 페이크다") }
    func getProfileImages() async throws -> [ProfileImageResponse] { throw IllegalStateException("푸시 해제 순서 검증 전용 페이크다") }
    func resetProfileImage() async throws { throw IllegalStateException("푸시 해제 순서 검증 전용 페이크다") }
    func registerFcmToken(request: FcmTokenRequest) async throws {}

    func deleteFcmToken() async throws {
        accessTokenAtDelete.value = await accessToken()
        deleteCount.update { $0 += 1 }
    }

    func deleteAccount(request: AccountDeletionRequest) async throws { throw IllegalStateException("푸시 해제 순서 검증 전용 페이크다") }
    func getMyRideRecords(cursor: Int64?, size: Int) async throws -> RideRecordPageResponse {
        throw IllegalStateException("푸시 해제 순서 검증 전용 페이크다")
    }
}

/// 푸시 해제를 잠시 **매달아 둔다.** 그 사이에 호출부를 취소해 "로그아웃이 세션을 비우기 전에
/// 취소되는" 창을 정확히 재현한다. `entered` 는 "해제 호출이 실제로 들어왔다"는 신호다.
///
/// 매달아 두는 수단이 `Task.sleep` 인 것이 중요하다 — **취소 가능한 지점**이라, 취소를 무시하지 않는
/// 구현에서는 반드시 여기서 `CancellationError` 가 나고 `session.onLoggedOut()` 까지 가지 못한다.
/// 완료 신호로 깨우는 방식은 경합에 따라 취소를 비껴갈 수 있어 회귀 테스트로서 믿을 수 없다.
private final class SuspendingFcmUserApi: UserApi {
    private let entered: AsyncSignal
    private let hanging: Duration

    /// `hanging` 은 FCM 해제 상한(2초)보다 충분히 짧아야 취소를 검증한다 — 타임아웃이 먼저 터지면
    /// 취소를 검증하지 못한다. 상한 자체를 재는 테스트만 더 길게 준다.
    init(entered: AsyncSignal, hanging: Duration) {
        self.entered = entered
        self.hanging = hanging
    }

    func getMyProfile() async throws -> UserProfileResponse { throw IllegalStateException("로그아웃 취소 검증 전용 페이크다") }
    func updateProfile(request: UpdateProfileRequest) async throws { throw IllegalStateException("로그아웃 취소 검증 전용 페이크다") }
    func getProfileImages() async throws -> [ProfileImageResponse] { throw IllegalStateException("로그아웃 취소 검증 전용 페이크다") }
    func resetProfileImage() async throws { throw IllegalStateException("로그아웃 취소 검증 전용 페이크다") }
    func registerFcmToken(request: FcmTokenRequest) async throws {}

    func deleteFcmToken() async throws {
        entered.complete()
        try await Task.sleep(for: hanging)
    }

    func deleteAccount(request: AccountDeletionRequest) async throws { throw IllegalStateException("로그아웃 취소 검증 전용 페이크다") }
    func getMyRideRecords(cursor: Int64?, size: Int) async throws -> RideRecordPageResponse {
        throw IllegalStateException("로그아웃 취소 검증 전용 페이크다")
    }
}
