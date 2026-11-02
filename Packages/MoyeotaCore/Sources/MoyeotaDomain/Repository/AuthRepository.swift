/// 인증 경계면. presentation 이 보는 유일한 계약이며 토큰은 노출하지 않는다
/// — 토큰 부착·재발급·영속화는 전부 data 계층(HTTP 클라이언트)에서 끝난다.
///
/// 모든 실패는 `AuthException` 으로 던진다.
public protocol AuthRepository: Sendable {

    /// 로그인 상태의 단일 출처. 화면 진입 라우팅(스플래시 → 로그인/홈)의 근거이자,
    /// **재발급까지 실패했을 때 세션 만료를 통보받는 경로**다
    /// — 사용자가 아무 화면에 있든 `AuthState.unauthenticated` 로 바뀌면 로그인 화면으로 보낸다.
    ///
    /// 앱 시작 직후에는 `AuthState.unknown` 이며, 디스크 복원이 끝나면 확정 값으로 바뀐다.
    var authState: StateFlow<AuthState> { get }

    /// 문자 인증번호 발송. POST /api/v1/auth/sms/send (**204 No Content**, 토큰 불필요).
    ///
    /// 가입 전에 불리므로 Bearer 가 붙지 않는 인증 전용 클라이언트로 나간다
    /// (`/api/v1/auth/` 하위가 서버 permitAll 구간이다).
    ///
    /// 번호는 하이픈이 있든 없든 받아서 숫자열로 정규화해 보낸다
    /// (`AuthPolicy.normalizePhoneNumber`).
    ///
    /// **성공은 "문자를 보냈다"까지다.** 돌려받는 값이 없고, 코드는 서버만 안다.
    /// 로컬·dev 서버는 실제 문자를 보내지 않는다 — `provider=log` 면 서버 로그에 코드가 찍히고,
    /// dev 프로필은 `moyeota.sms.fixed-code` 가 `000000` 으로 고정돼 있다.
    ///
    /// 서버가 문자 비용을 쓰기 전에 **이미 가입된 번호인지 먼저 확인한다** — 그래서 이 단계에서
    /// 409 가 날 수 있고, 그건 "로그인하세요"라는 뜻이다.
    ///
    /// - Throws: `AuthException`
    ///   `AuthError.phoneNumberDuplicated` (409 `USER104`) /
    ///   `AuthError.smsCooldown` (429 `USER202`) /
    ///   `AuthError.smsDailyLimitExceeded` (429 `USER203`) /
    ///   `AuthError.smsUnavailable` (502 `USER201` / 503 `USER208`) /
    ///   `AuthError.invalidRequest` (400, 번호 형식 — 발송 쪽은 `@Pattern` 이 먼저 걸린다) /
    ///   `AuthError.network`
    func sendPhoneVerificationCode(phoneNumber: String) async throws

    /// 문자 인증번호 확인. POST /api/v1/auth/sms/verify (200, 토큰 불필요).
    ///
    /// - Parameter phoneNumber: `sendPhoneVerificationCode` 에 넣은 것과 같은 번호. 표기(하이픈)는 달라도 되지만
    ///   **번호 자체가 다르면 통과하지 않는다** — 서버가 번호 해시로 저장된 코드를 찾는다.
    /// - Parameter code: 숫자 6자리(`AuthPolicy.isValidVerificationCode`).
    ///
    /// - Returns: 가입에 실어 보낼 `verificationToken`. 이 값을 `NewUser.verificationToken` 에 넣는다
    ///   — 수명 10분, 가입 성공 시 소진된다(상세는 `NewUser.verificationToken` 주석).
    ///
    /// **성공하면 서버가 인증번호를 지운다.** 같은 코드로 다시 확인하면
    /// `AuthError.smsCodeExpired` 가 오므로, 화면은 받은 토큰을
    /// 가입 제출까지 들고 있어야 한다(재확인으로 다시 얻을 수 없다).
    ///
    /// - Throws: `AuthException`
    ///   `AuthError.smsCodeMismatch` (400 `USER205`) /
    ///   `AuthError.smsCodeExpired` (400 `USER204`) /
    ///   `AuthError.smsTooManyAttempts` (429 `USER206`) /
    ///   `AuthError.invalidPhoneNumber` (400 `USER105`) /
    ///   `AuthError.smsUnavailable` (503 `USER208`) /
    ///   `AuthError.network`
    func verifyPhoneCode(phoneNumber: String, code: String) async throws -> String

    /// 회원가입. POST /api/v1/auth/register (201).
    ///
    /// **가입은 로그인시키지 않는다** — 서버가 토큰이 아니라 uuid 만 준다.
    /// 성공 후 화면은 같은 자격증명으로 `login` 을 이어서 호출해야 한다.
    ///
    /// `NewUser.nickname` 은 **필수다** — 서버가 닉네임 없이는 가입을 받지 않는다.
    ///
    /// `NewUser.verificationToken` 도 **필수다**(2026-10 서버 변경). 비어 있으면 서버 검증에서
    /// 400 `INVALID_REQUEST` 로 튕기므로, 화면은 `sendPhoneVerificationCode` →
    /// `verifyPhoneCode` 를 먼저 끝내고 그 토큰을 실어야 한다.
    ///
    /// **실패가 토큰을 태우지는 않는다** — 서버는 세 테이블 저장이 다 끝난 뒤에야 토큰을 지운다.
    /// 아이디·닉네임 중복(409)으로 되돌아온 사용자는 입력만 고쳐 같은 토큰으로 재시도할 수 있고,
    /// 문자 인증을 다시 받게 할 이유는 `AuthError.phoneNotVerified` 뿐이다.
    ///
    /// - Returns: 생성된 사용자의 UUID 문자열
    /// - Throws: `AuthException`
    ///   `AuthError.phoneNotVerified` (400 `USER207`, 토큰 만료·소진·번호 불일치) /
    ///   `AuthError.loginIdDuplicated` (409) /
    ///   `AuthError.phoneNumberDuplicated` (409 `USER104`) /
    ///   `AuthError.nicknameDuplicated` (409 `USER108`) /
    ///   `AuthError.invalidNickname` (400 `USER107`) /
    ///   `AuthError.invalidRequest` (400, serverMessage 가 "필드: 사유")
    func register(newUser: NewUser) async throws -> String

    /// 닉네임 중복 확인. POST /api/v1/auth/nickname/check (200, **토큰 불필요**).
    ///
    /// 가입 폼의 실시간 확인용이라 로그인 전에 불린다 — 그래서 Bearer 가 붙지 않는 인증 전용
    /// 클라이언트로 나간다. 화면은 입력이 멈춘 뒤(디바운스) 호출해야 한다: 타자마다 부르면
    /// 서버 왕복이 글자 수만큼 쌓인다.
    ///
    /// **여기서 false 를 받아도 가입이 성공한다는 보장은 없다** — 확인과 가입 사이에 누가 먼저
    /// 그 닉네임을 가져갈 수 있다. 최종 판정은 `register` 의 409 `USER108` 다.
    ///
    /// - Returns: true 면 이미 사용 중
    /// - Throws: `AuthException`
    ///   `AuthError.invalidNickname` (400 `USER107`, 형식 위반) /
    ///   `AuthError.network`
    func isNicknameTaken(nickname: String) async throws -> Bool

    /// 전화번호 가입 여부. POST /api/v1/auth/phone/check (200, **토큰 불필요**).
    ///
    /// `isNicknameTaken` 과 쓰임이 같다 — 입력이 멈춘 뒤(디바운스) 번호당 한 번만 묻는다.
    ///
    /// ### true 만 믿을 수 있다
    /// false 는 「가입할 수 있다」가 아니라 「지금 그 번호를 쓰는 **활성** 계정이 없다」는 뜻뿐이다.
    /// 서버가 보는 건 활성 프로필 한 테이블이고 탈퇴 기록은 보지 않는다 — **탈퇴한 번호도 false 로
    /// 온다**(실측 2026-11-01, 로컬 :8080 — `010-7777-0101` → `{"exists":false}` 200인데 같은 번호의
    /// `sendPhoneVerificationCode` 는 409 `USER109`
    /// = `AuthError.rejoinRestricted`).
    /// 그래서 이 값으로 **무엇을 열어 주면 안 되고, 막는 데만 써야 한다.** false 를 보고 「쓸 수 있는
    /// 번호」라고 안심시키면, 사용자는 그 뒤에 「30일 동안 가입 불가」를 듣는다 — 선확인을 붙인 탓에
    /// 지금보다 나빠지는 유일한 경로다.
    ///
    /// 최종 판정은 어차피 `sendPhoneVerificationCode` 의 409 `USER104` 다 — 그쪽은 문자도 보내지
    /// 않고 쿨다운도 걸지 않으므로(실측: 같은 번호로 연속 발송해도 전부 즉시 409, 429 가 나지 않는다)
    /// 이 선확인을 건너뛰어도 사용자가 잃는 것은 버튼 한 번이다.
    ///
    /// - Parameter phoneNumber: 하이픈 유무 무관(서버가 "-" 를 제거하고 앞뒤 공백을 strip 한다)
    /// - Returns: true 면 이미 가입된 번호
    /// - Throws: `AuthException`
    ///   `AuthError.invalidPhoneNumber` (400 `USER105`, 형식 위반 —
    ///     발송 쪽은 같은 상황에서 `INVALID_REQUEST` 라 **코드가 다르다**) /
    ///   `AuthError.invalidRequest` (400, 빈 값·필드 누락) /
    ///   `AuthError.network`
    func isPhoneRegistered(phoneNumber: String) async throws -> Bool

    /// 내 프로필 수정. PATCH /api/v1/users/me (204, **토큰 필수**).
    ///
    /// **null 인 값은 보내지 않는다** — 서버는 넘어온 필드만 갱신하므로, null 로 "지우기"를 표현할 수 없다.
    /// 둘 다 null 이면 서버는 아무것도 하지 않고 204 를 준다. 이미지를 **지우는** 건 이 메서드로 표현할 수
    /// 없고 `resetProfileImage` 가 따로 있다.
    ///
    /// - Parameter imageKey: `getProfileImages` 가 준 `ProfileImage.key` 그대로.
    ///   URL 을 넣으면 400 `USER112` 다.
    /// - Throws: `AuthException`
    ///   `AuthError.invalidNickname` (400 `USER107`) /
    ///   `AuthError.nicknameDuplicated` (409 `USER108`) /
    ///   `AuthError.invalidProfileImage` (400 `USER112`,
    ///     목록 밖의 키 — **닉네임 중복보다 먼저 검사되고, 거절되면 닉네임도 함께 안 바뀐다**) /
    ///   `AuthError.sessionExpired` (401)
    func updateProfile(nickname: String?, imageKey: String?) async throws

    /// 고를 수 있는 프로필 이미지 목록. GET /api/v1/users/profile-images (200, **토큰 필수**).
    ///
    /// 사용자와 무관한 정적 목록인데도 보호 구간이다(`/api/v1/users` 하위 전체가 permitAll 이 아니다) —
    /// 즉 **로그인 전에는 받을 수 없다**. 서버 순서가 곧 표시 순서다. 지금은 16장이지만 수를 가정하지 마라.
    ///
    /// 반환되는 key 만 `updateProfile` 의 `imageKey` 로 보낼 수 있다. 기본 이미지는 이 목록에 없다
    /// (`ProfileImage` 주석).
    ///
    /// - Throws: `AuthException`
    ///   `AuthError.sessionExpired` (401) /
    ///   `AuthError.network` (연결 실패)
    func getProfileImages() async throws -> [ProfileImage]

    /// 프로필 이미지를 기본값으로 되돌린다. DELETE /api/v1/users/me/profile-image (204, **토큰 필수**).
    ///
    /// **멱등하다** — 이미 기본 상태여도 그냥 204 다. 그래서 "지금 기본인가"를 몰라도 부를 수 있다.
    ///
    /// `updateProfile` 에 `imageKey = null` 을 보내는 것과 **다르다**: 그쪽 null 은 "건드리지 마라"는
    /// 뜻이라 아무 일도 일어나지 않는다. 되돌리기는 반드시 이 요청이어야 한다.
    ///
    /// 경로를 `updateProfile` 과 헷갈리지 말 것 — 되돌리기는 `/users/me/profile-image`(단수),
    /// 목록은 `/users/profile-images`(복수, `/me` 없음), 그리고 `/users/me` 의 DELETE 는 **회원 탈퇴**다.
    ///
    /// - Throws: `AuthException`
    ///   `AuthError.sessionExpired` (401) /
    ///   `AuthError.network` (연결 실패)
    func resetProfileImage() async throws

    /// 로그인. POST /api/v1/auth/login.
    /// 성공 시 토큰을 영속화하고 `authState` 를 `AuthState.authenticated` 로 바꾼다
    /// — 호출부가 별도로 세션을 저장할 필요는 없다.
    ///
    /// - Returns: 로그인한 사용자의 UUID 문자열.
    ///   서버 응답에는 없고 **액세스 토큰의 `sub` 클레임에서 읽는다** — 응답이 토큰 쌍만 주기 때문이다.
    /// - Throws: `AuthException`
    ///   `AuthError.loginFailed` (401)
    func login(loginId: String, password: String) async throws -> String

    /// 로그아웃. POST /api/v1/auth/logout (204, 멱등).
    ///
    /// **로컬 세션을 먼저 비우고 서버 무효화를 시도하므로 절대 실패하지 않는다** —
    /// 서버 호출이 실패해도 사용자가 로그아웃 못 하고 갇히는 일이 없어야 한다.
    /// 이미 발급된 액세스 토큰은 남은 수명(최대 30분) 동안 서버에서 유효한 채로 남는다.
    func logout() async throws

    /// 회원 탈퇴. DELETE /api/v1/users/me (**204 No Content**, 토큰 필수, 본문에 비밀번호).
    ///
    /// App Store 의 계정 삭제 요건을 채우는 경로다(Backend #206 / PR #216).
    ///
    /// ### 성공은 되돌릴 수 없다
    /// 서버가 한 트랜잭션에서 하는 일(`UserDeletionService.delete`):
    /// - `users.deleted_at` 기록 + 닉네임·프로필 사진·FCM 토큰 비우기
    ///   → 남에게는 **「탈퇴한 사용자」**로 보인다(`User.DELETED_DISPLAY_NAME`)
    /// - 프로필(실명·생년월일·번호·성별·메일)과 로컬 계정(아이디·비밀번호 해시) **삭제**
    ///   → 같은 아이디로 다시 로그인할 수 없다
    /// - 번호 해시를 탈퇴 기록에 남김 → 같은 번호의 재가입을
    ///   `AuthPolicy.REJOIN_RESTRICTED_DAYS`일간 차단
    ///   (`sendPhoneVerificationCode` 가 409 `USER109` 로 거절한다)
    /// - 리프레시 토큰 전량 취소 + 인증 캐시 축출
    /// - 커밋 후 비동기로 **참여 중인 채팅방 전부 나가기**와 **즐겨찾기 삭제**
    ///   (`ChatRoomUserDeletionListener` · `FavoritePlaceUserDeletionListener`)
    ///
    /// **서버가 하지 않는 일**: 지난 합승 기록 삭제. 끝난 방의 멤버로는 남고 이름만 가려진다.
    /// 화면 문구가 "모든 기록이 사라진다"고 약속하면 안 된다.
    ///
    /// ### 토큰이 즉시 죽는다 — 그래서 성공 자리에서 로컬을 비운다
    /// 취소되는 건 리프레시만이 아니다. 서버가 인증 캐시까지 축출해 **남은 수명이 있는 액세스 토큰도
    /// 바로 401** 이 된다(백엔드 통합 테스트 `만료 전 access 토큰도 캐시가 비워져 바로 막힌다`).
    /// 그 401 을 앱이 맞으면 재발급이 실패하고 `AuthError.sessionExpired` 가 올라와
    /// "세션이 만료됐어요"가 뜬다 — 스스로 탈퇴한 사용자에게는 오해를 주는 말이다.
    /// 그래서 구현은 204 를 받은 즉시 세션과 로컬 기억을 비우고 `authState` 를
    /// `AuthState.unauthenticated` 로 바꾼다. 화면은 `logout` 과 **똑같은 전이**를 받는다.
    ///
    /// 비우는 범위는 `logout` 보다 넓다 — "진행 중인 방" 로컬 기억까지 지운다. `logout` 은 그 기억을
    /// 계정에 매인 값으로 보고 남겨 두지만(같은 계정으로 다시 로그인하면 되살아나야 한다),
    /// 탈퇴한 계정은 다시 로그인할 길이 없어 남겨 둘 이유가 없다.
    ///
    /// ### 푸시 토큰은 따로 해제하지 않는다
    /// `logout` 은 세션을 비우기 전에 `DELETE /users/me/fcm-token` 을 부르지만 탈퇴는 부르지 않는다
    /// — 서버 `User.delete()` 가 `fcmToken` 을 직접 비운다. 미리 불러 두면 409·400 으로 탈퇴가
    /// 실패했을 때 **멀쩡한 사용자의 알림만 끊긴 상태**가 남는다.
    ///
    /// - Parameter password: 본인 확인용 **현재 비밀번호**. 서버는 `@NotBlank` 만 보고 해시를 비교하므로
    ///   앱이 길이·형식을 미리 검사하지 않는다 — 틀림은 서버가 판정한다.
    /// - Throws: `AuthException`
    ///   `AuthError.passwordMismatch` (400 `USER111`, 비밀번호 불일치 — 입력란 오류) /
    ///   `AuthError.ongoingPartyExists` (409 `USER110`, 진행 중 합승 — 먼저 나가야 한다) /
    ///   `AuthError.sessionExpired` (401) /
    ///   `AuthError.network` (연결 실패 — **세션은 그대로 남는다**) /
    ///   `AuthError.unknown`
    func deleteAccount(password: String) async throws

    /// 로그인한 본인의 정보 조회. GET /api/v1/local/users/info (200, **토큰 필수**).
    ///
    /// `authState` 가 이미 uuid 를 들고 있으므로 이 호출의 목적은 `UserProfileInfo.name` 과
    /// `UserProfileInfo.imageUrl` 이다 — 둘 다 null 일 수 있고, 그 조건은 그쪽 주석 에 있다.
    ///
    /// **결과를 받을 때 `.name` 만 바로 꺼내지 마라.** 2026-11-01 에 `imageUrl` 이 붙기 전까지
    /// 이 주석 이 「주는 건 이름 하나뿐」이라고 적고 있었고, 그 말을 믿은 호출부가 `getMyProfile().name`
    /// 으로 써서 사진을 영영 못 가져왔다. 응답 객체째로 받아 두 필드를 함께 쓸 것.
    ///
    /// 로그인 상태에서만 부를 것. 미로그인으로 부르면 401 이 나고 `AuthError.sessionExpired` 로 올라온다
    /// — 재발급으로 풀리지 않는 401 이라(재시도할 토큰 자체가 없다) 화면 에러가 된다.
    ///
    /// 캐시하지 않는다. 매번 서버에 묻는다 — 화면이 필요할 때만 부르고, 결과는 화면이 보관한다.
    ///
    /// - Throws: `AuthException`
    ///   `AuthError.sessionExpired` (401) /
    ///   `AuthError.network` (연결 실패) /
    ///   `AuthError.unknown`
    func getMyProfile() async throws -> UserProfileInfo
}
