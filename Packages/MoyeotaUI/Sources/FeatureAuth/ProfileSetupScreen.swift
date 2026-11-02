import MoyeotaDesignSystem
import MoyeotaDomain
import PresentationCore
import SwiftUI

private let LabelGray = Color(argb: 0xFF8A93A0)
private let CounterGray = Color(argb: 0xFF9AA1AC)
private let SlateGray = Color(argb: 0xFF4B5563)
private let InfoCardBlue = Color(argb: 0xFFF1F5FD)
private let TrackGray = Color(argb: 0xFFE6EAF0)

/// 10 프로필 만들기의 입력 판정. 원본은 화면 본문 안의 지역 값들이고, 뷰 없이 확인하려고 값으로 모았다.
struct ProfileSetupValidation {
    let nicknameError: String?
    let realNameError: String?
    let birthDate: LocalDate?
    let birthError: String?
    let phoneError: String?
    let phoneVerified: Bool
    let loginIdError: String?
    let passwordError: String?
    let emailError: String?
    let isValid: Bool

    init(
        nickname: String,
        realName: String,
        birthDigits: String,
        gender: Gender?,
        phoneDigits: String,
        loginId: String,
        password: String,
        email: String,
        today: LocalDate,
        nicknameCheck: NicknameCheckState,
        phoneVerify: PhoneVerifyState
    ) {
        // [유효값 검증 · 프로필]
        // · 닉네임 2~10자 (카운터 「n / 10」 실시간 갱신) — 서버 Nickname VO 와 같은 규칙
        // · 한글·영문·숫자 허용, 공백·특수문자·이모지 불가
        // · 금칙어·욕설 필터, 운영자 사칭어(모여타·관리자) 차단 — 앱 자체 정책
        // · 중복은 서버가 판정한다: 입력이 멈추면 Route 가 조회해 `nicknameCheck` 로 돌려준다
        let nicknameFormatError = nickname.isEmpty ? nil : NicknamePolicy.validate(raw: nickname)
        let nicknameError: String?
        if let nicknameFormatError {
            nicknameError = nicknameFormatError
        } else {
            switch nicknameCheck {
            // 서버가 형식으로 400 을 준 경우 — 앱 규칙과 어긋난 문자가 있다는 뜻이라 같은 문구로 안내한다
            case .invalidFormat: nicknameError = "닉네임은 한글·영문·숫자 2~10자로 입력해 주세요"
            case .taken: nicknameError = "이미 사용 중인 닉네임이에요"
            default: nicknameError = nil
            }
        }
        self.nicknameError = nicknameError

        // [유효값 검증 · 기본 정보] — 09 에서 쓰던 규칙을 그대로 옮겼다
        let realNameValid = PersonNameRegex.matches(realName)
        realNameError = !realName.isEmpty && !realNameValid ? "이름은 한글 또는 영문 2~20자로 입력해 주세요" : nil

        // 8자리를 채웠을 때만 실제로 있는 날짜인지까지 본다(20250230 같은 값 차단)
        let birthDate = parseBirthDate(digits: birthDigits, today: today)
        self.birthDate = birthDate
        // 거절 사유 셋(없는 날짜 · 오늘 이후 · 만 14세 미만)을 각각 다른 문구로 말한다.
        // 규칙과 문구는 birthDateError 가 갖는다 — 09 본인 인증도 같은 함수를 쓰므로 두 화면이 어긋나지 않는다.
        let birthError = birthDateError(digits: birthDigits, today: today)
        self.birthError = birthError
        // 「다음」 판정은 문구와 같은 근거를 본다: 할 말이 남아 있으면 넘어가지 않는다
        let birthValid = birthDate != nil && birthError == nil

        // 휴대폰 — 010 + 숫자 8자리, 하이픈은 표시에만. 판정은 인증 블록과 같은 함수를 쓴다
        // (「인증번호 받기」는 활성인데 「다음」은 번호가 틀렸다고 막는 어긋남을 구조적으로 없앤다)
        let phoneValid = isCompletePhoneDigits(digits: phoneDigits)
        let phoneLength = phoneDigits.utf16.count
        if phoneDigits.isEmpty {
            phoneError = nil
        } else if phoneLength >= 3 && !phoneDigits.utf16.starts(with: "010".utf16) {
            phoneError = "010으로 시작하는 휴대폰 번호만 입력할 수 있어요"
        } else if (3...10).contains(phoneLength) || phoneValid {
            phoneError = nil
        } else {
            phoneError = "휴대폰 번호는 010 + 숫자 8자리로 입력해 주세요"
        }

        // [유효값 검증 · 로그인 정보] — 서버 Bean Validation 과 같은 규칙(AuthPolicy). 최종 판정은 서버
        let loginIdError: String? = !loginId.isEmpty && !AuthPolicy.isValidLoginId(value: loginId)
            ? "영소문자로 시작하는 영소문자·숫자·_ 4~20자로 입력해 주세요"
            : nil
        self.loginIdError = loginIdError
        let passwordError: String? = !password.isEmpty && !AuthPolicy.isValidPassword(value: password)
            ? "영문·숫자·특수문자를 각각 하나 이상 포함해 8자 이상"
            : nil
        self.passwordError = passwordError
        let emailError: String?
        if email.isEmpty {
            emailError = nil
        } else if !SimpleEmailRegex.matches(email) {
            emailError = "이메일 형식으로 입력해 주세요"
        } else if email.utf16.count > AuthPolicy.EMAIL_MAX_LENGTH {
            emailError = "이메일은 \(AuthPolicy.EMAIL_MAX_LENGTH)자를 넘을 수 없어요"
        } else {
            emailError = nil
        }
        self.emailError = emailError

        let basicValid = realNameValid && birthValid && gender != nil && phoneValid
        // 문자 인증 없이 제출하면 서버가 가입을 400 으로 전부 거절한다 — 여기서 먼저 막는다
        let phoneVerified = phoneVerify.stage == .verified
        self.phoneVerified = phoneVerified
        let accountValid = !loginId.isEmpty && loginIdError == nil &&
            !password.isEmpty && passwordError == nil &&
            !email.isEmpty && emailError == nil
        // 중복 확인이 아직 진행 중이거나 네트워크로 실패했어도 다음 단계는 막지 않는다
        // — 서버가 가입 시점에 409 로 최종 판정하고, 12 화면이 그 실패를 배너로 되돌려 준다.
        isValid = NicknamePolicy.isValid(raw: nickname) && nicknameError == nil &&
            basicValid && phoneVerified && accountValid
    }
}

/// 10 · 프로필 만들기 [S05] — **가입 1단계(1/2), 가입 플로우의 첫 화면**
///
/// 진입: 04 「이메일로 시작하기」 · 04a 「가입하기」 / 뒤로 → 진입 화면 / 「다음」 → 12 매너 서약
///
/// 이 화면 하나가 서버 가입(`POST /api/v1/users`)이 요구하는 7개 필드를 **모두** 받는다.
/// 원래 실명·생년월일·성별·휴대폰은 09 본인 인증에서 받았지만, 그 화면의 전제였던 통신사
/// 휴대폰 인증이 MVP 범위에서 빠지면서 인증 없이 값만 묻는 화면이 됐다. 그래서 09 를 경로에서
/// 들어내고 입력만 여기로 옮겼다 — 물어보는 값의 개수는 그대로고, 화면 하나가 줄었다.
///
/// 필드가 8개라 세 절로 끊어 읽게 했다:
/// - **프로필** — 닉네임 (상대에게 보이는 유일한 이름). 아바타는 단일 기본색 실루엣이다 —
///   아바타 색을 저장할 서버 필드가 없어 고르게 하지 않는다
/// - **기본 정보** — 이름(실명) · 생년월일 · 성별 · 휴대폰 번호 (서버 가입 필수값)
/// - **로그인 정보** — 아이디 · 비밀번호 · 이메일 (계정 자격증명)
///
/// 이용약관·개인정보 동의 체크는 여기 두지 않는다 — 12 매너 서약의 동의 묶음으로 합쳤다.
/// 한 가입에서 동의를 두 화면이 나눠 받으면 무엇에 동의했는지가 흩어진다.
///
/// 2026-09 서버 변경으로 **닉네임이 가입 필수 필드**가 됐다. 예전 「표시 이름」은 가입 API 에
/// 자리가 없어 어디로도 가지 않는 값이었지만, 이제 `SignupDraft.nickname` 으로 그대로 서버에 간다.
/// 규칙도 서버 VO 와 같은 `NicknamePolicy` 로 맞췄다(2~10자 한글·영문·숫자).
///
/// **만 `AuthPolicy.MIN_AGE` 세 미만은 이 화면에서 막는다.** 개인정보 보호법상 법정대리인 동의 없이는
/// 가입시킬 수 없고, 동의 절차를 만드는 대신 가입 자체를 받지 않기로 했다(개인정보 처리방침의
/// 고지와 동작이 같아야 한다). 서버에는 연령 제한이 없어 **앱이 유일한 방어선**이다 —
/// 판정은 `AuthPolicy.isOldEnough`, 문구는 `birthDateError` 가 갖는다.
///
/// 2026-10 서버 변경으로 **휴대폰 문자 인증이 가입 선행 조건**이 됐다. 인증을 별도 화면으로 빼지 않고
/// 휴대폰 입력란 바로 아래 `PhoneVerificationBlock` 으로 넣었다 — 이유는 그 타입 주석에 적었다.
/// 그래서 이 화면은 서버 가입 **9개 값**(기존 8 + `verificationToken`)을 모두 책임지고,
/// 인증을 끝내지 않으면 「다음」이 열리지 않는다(토큰 없이 제출하면 가입이 전부 400 이다).
public struct ProfileSetupScreen: View {
    private let onBack: () -> Void
    private let onNext: (SignupDraft) -> Void
    private let today: LocalDate
    private let nicknameCheck: NicknameCheckState
    private let onNicknameChange: (String) -> Void
    private let phoneVerify: PhoneVerifyState
    private let nowMillis: Int64
    private let onPhoneDigitsChange: (String) -> Void
    private let onRequestVerificationCode: (_ phoneDigits: String) -> Void
    private let onVerificationCodeChange: (String) -> Void
    private let onSubmitVerificationCode: () -> Void
    private let onPhoneEditRequested: () -> Void
    private let onGoToLogin: () -> Void

    // `@State` 여야 하는 이유: 12 매너 서약에서 가입이 409(닉네임 중복)로 실패하면
    // 「닉네임 바꾸기」가 이 화면으로 되돌아온다. 그 사이 이 화면은 스택에 남아 값을 들고 있어야 한다 —
    // 잃으면 여기 여덟 값이 전부 날아가고 사용자는 가입 폼을 처음부터 다시 채워야 한다.
    @State private var nickname = ""

    @State private var realName = ""
    @State private var birthDigits = ""
    @State private var gender: Gender?
    @State private var phoneDigits = ""

    @State private var loginId = ""
    @State private var password = ""
    @State private var email = ""
    @State private var passwordVisible = false

    /// - Parameter today: 만 나이 계산 기준일. 기기 시계를 기본값으로 두되 **파라미터로 받는다** —
    ///   연령 판정의 경계값(생일 당일)은 시계를 고정하지 않으면 검증할 수 없다.
    /// - Parameter nicknameCheck: 중복 확인 결과. 입력이 멈춘 뒤 `ProfileSetupRoute` 가 서버에 물어 갱신한다.
    /// - Parameter onNicknameChange: 입력이 바뀔 때마다 호출 — 디바운스는 Route 가 한다.
    /// - Parameter phoneVerify: 문자 인증 상태. 전이 규칙은 `PhoneVerifyState` 의 순수 함수들이 갖고,
    ///   이 화면은 그 결과를 그리고 번호 입력란을 잠그는 일만 한다.
    /// - Parameter nowMillis: 카운트다운(인증번호 3분·재전송 1분) 기준 시각. Route 의 뷰모델이 틱마다 올려 준다.
    /// - Parameter onPhoneDigitsChange: 번호가 바뀔 때마다 호출 — 다른 번호가 되면 인증이 무효가 된다.
    /// - Parameter onRequestVerificationCode: 「인증번호 받기」. 번호를 인자로 넘기는 이유는 입력값의 주인이
    ///   이 화면이기 때문이다 — 뷰모델이 번호를 따로 들고 있으면 두 곳이 어긋날 수 있다.
    /// - Parameter onNext: 「다음」 → 12 매너 서약. `SignupDraft` 가 서버로 갈 9개 값 전부다.
    public init(
        onBack: @escaping () -> Void,
        onNext: @escaping (SignupDraft) -> Void,
        today: LocalDate = LocalDate.now(),
        nicknameCheck: NicknameCheckState = .idle,
        onNicknameChange: @escaping (String) -> Void = { _ in },
        phoneVerify: PhoneVerifyState = PhoneVerifyState(),
        nowMillis: Int64 = 0,
        onPhoneDigitsChange: @escaping (String) -> Void = { _ in },
        onRequestVerificationCode: @escaping (_ phoneDigits: String) -> Void = { _ in },
        onVerificationCodeChange: @escaping (String) -> Void = { _ in },
        onSubmitVerificationCode: @escaping () -> Void = {},
        onPhoneEditRequested: @escaping () -> Void = {},
        onGoToLogin: @escaping () -> Void = {}
    ) {
        self.onBack = onBack
        self.onNext = onNext
        self.today = today
        self.nicknameCheck = nicknameCheck
        self.onNicknameChange = onNicknameChange
        self.phoneVerify = phoneVerify
        self.nowMillis = nowMillis
        self.onPhoneDigitsChange = onPhoneDigitsChange
        self.onRequestVerificationCode = onRequestVerificationCode
        self.onVerificationCodeChange = onVerificationCodeChange
        self.onSubmitVerificationCode = onSubmitVerificationCode
        self.onPhoneEditRequested = onPhoneEditRequested
        self.onGoToLogin = onGoToLogin
    }

    private var validation: ProfileSetupValidation {
        ProfileSetupValidation(
            nickname: nickname,
            realName: realName,
            birthDigits: birthDigits,
            gender: gender,
            phoneDigits: phoneDigits,
            loginId: loginId,
            password: password,
            email: email,
            today: today,
            nicknameCheck: nicknameCheck,
            phoneVerify: phoneVerify
        )
    }

    public var body: some View {
        let validation = self.validation
        VStack(spacing: 0) {
            StatusBarSpacer()
            MoyeotaTopBar(title: "", onBack: onBack) {
                // 가입은 10 → 12 두 단계다 (09 본인 인증은 MVP 범위에서 빠졌다)
                Text("1 / 2")
                    .moyeotaText(MoyeotaType.BodySm.copy(fontWeight: .medium), color: LabelGray)
            }
            ProfileStepProgressBar(progress: 1.0 / 2.0)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Spacer().frame(height: 24)
                    Text("가입 정보를 알려주세요")
                        .moyeotaText(MoyeotaType.DisplayMd.hangulTrimmed, color: MoyeotaColor.InkPrimary)
                    Spacer().frame(height: 10)
                    // 실명·성별은 가입 시 서버에 저장된다 — "저장하지 않아요"로 안내하면 사실과 다르다.
                    // 「매칭 안전을 위해서만」은 지웠다 — 성별은 매칭에 쓰이지 않는다(2026-10-13).
                    Text("실명은 본인 확인에만 쓰고 탑승 상대에게는 보이지 않아요")
                        .moyeotaText(MoyeotaType.BodySm.copy(fontSize: 14).hangulTrimmed, color: MoyeotaColor.TextMute)

                    Spacer().frame(height: 22)
                    ProfileAvatarPlaceholder()
                        .frame(maxWidth: .infinity)
                    Spacer().frame(height: 28)
                    profileSection(validation)

                    Spacer().frame(height: 28)
                    basicInfoSection(validation)

                    Spacer().frame(height: 28)
                    accountSection(validation)

                    Spacer().frame(height: 24)
                    infoCard
                    Spacer().frame(height: 24)
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 0) {
                // 미입력·규칙 위반 시 「다음」 비활성
                PrimaryCtaButton(
                    text: "다음",
                    onClick: { submit(validation) },
                    enabled: validation.isValid
                )
                Spacer().frame(height: 16)
                Text("닉네임은 나중에 바꿀 수 있어요")
                    .moyeotaText(MoyeotaType.CaptionMd.copy(fontWeight: .medium).hangulTrimmed, color: CounterGray)
            }
            .padding(.horizontal, 16)
            NavigationBarSpacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MoyeotaColor.SurfaceSoft)
        // 복원되어 돌아온 닉네임은 중복 확인을 다시 받아야 한다. 뷰모델은 살아남아 직전 결과
        // (예: available)를 그대로 들고 있는데, 되돌아온 이유가 바로 그 닉네임이 이미 선점됐다는
        // 409 이기 때문이다 — 다시 묻지 않으면 선점된 닉네임에 초록 「사용 가능」이 남는다.
        //
        // 맨 위 칸일 때만 묻는다. 13 을 쌓는 순간 SwiftUI 가 덮인 이 화면에 `onAppear` 를 다시 불러, 가입이 끝난 뒤 중복 확인이 한 번 더 나갔다.
        .topEntryTask {
            if !nickname.isBlank { onNicknameChange(nickname) }
        }
        // 여덟 입력값과 달리 이 값만 원본이 `remember` 다 — 돌아오면 비밀번호는 다시 가려져 있어야 한다.
        .onDisappear { passwordVisible = false }
    }

    @ViewBuilder
    private func profileSection(_ validation: ProfileSetupValidation) -> some View {
        ProfileSectionHeader(
            title: "프로필",
            description: "탑승 상대에게는 실명 대신 닉네임으로 보여요"
        )
        Spacer().frame(height: 16)
        MoyeotaTextField(
            value: nickname,
            // 공백은 규칙상 못 쓰는 문자다 — 오류로 튕기기보다 조용히 걸러 받는다
            onValueChange: { new in
                nickname = takeUtf16(withoutWhitespace(new), NicknamePolicy.MAX_LENGTH)
                onNicknameChange(nickname)
            },
            label: "닉네임",
            placeholder: "2~10자 한글·영문·숫자",
            errorText: validation.nicknameError,
            helperText: nicknameHelperText(validation)
        ) {
            Text(verbatim: "\(nickname.utf16.count) / \(NicknamePolicy.MAX_LENGTH)")
                .moyeotaText(MoyeotaType.CaptionMd.copy(fontWeight: .medium), color: CounterGray)
        }
        // 사용 가능 확인만 초록으로 따로 세운다 — 나머지 상태는 필드가 자기 색으로 그린다.
        // 확인에 실패한 경우(네트워크)는 아무 말도 하지 않는다: 사용자가 고칠 수 있는 게 없다.
        if validation.nicknameError == nil && nicknameCheck == .available {
            Spacer().frame(height: 6)
            Text("사용 가능한 닉네임이에요")
                .moyeotaText(MoyeotaType.CaptionMd.copy(fontWeight: .medium).hangulTrimmed, color: MoyeotaColor.Success500)
        }
    }

    private func nicknameHelperText(_ validation: ProfileSetupValidation) -> String? {
        if validation.nicknameError != nil { return nil }
        if nicknameCheck == .checking { return "사용할 수 있는지 확인하고 있어요" }
        if !nickname.isEmpty { return "탑승 상대에게는 「\(nickname)」 으로 보여요" }
        return nil
    }

    @ViewBuilder
    private func basicInfoSection(_ validation: ProfileSetupValidation) -> some View {
        ProfileSectionHeader(
            title: "기본 정보",
            // 「동성 매칭」은 지웠다 — 성별 조건 매칭이 없다(2026-10-13)
            description: "가입할 때 본인 확인에 쓰는 정보예요"
        )

        Spacer().frame(height: 16)
        MoyeotaTextField(
            value: realName,
            onValueChange: { realName = takeUtf16($0, 20) },
            label: "이름",
            placeholder: "실명을 입력해 주세요",
            errorText: validation.realNameError
        )

        Spacer().frame(height: 20)
        // value 는 원시 숫자만. 하이픈은 표시 변환이 그린다 — 표시 문자열을 value 로
        // 넘기면 길이가 튀는 순간 커서가 옛 인덱스에 남아 입력 순서가 뒤집힌다(D-7).
        MoyeotaTextField(
            value: birthDigits,
            onValueChange: { birthDigits = digitsOnly($0, maxDigits: 8) },
            label: "생년월일",
            placeholder: "2000-01-01",
            errorText: validation.birthError,
            // 다 쓰고 나서 "가입할 수 없어요"를 보는 대신 미리 안다. 오류가 있으면 필드가 그쪽을 띄운다
            helperText: BirthDateHelperText,
            keyboardOptions: KeyboardOptions(keyboardType: .number),
            visualTransformation: BirthDateTransformation.visualTransformation
        )

        Spacer().frame(height: 20)
        Text("성별")
            .moyeotaText(MoyeotaType.BodySm.hangulTrimmed, color: LabelGray)
        Spacer().frame(height: 8)
        // 칩 셋이 **한 묶음의 선택**이라는 사실을 스크린리더에 싣는 자리(원본 `selectableGroup`).
        HStack(spacing: 8) {
            // 선택지·라벨·순서는 `SignupGenderChoices` 가 갖는다 — 화면이 칩을 직접 나열하면
            // 「선택 안 함」 노출 여부가 목록과 화면 두 곳에서 갈린다.
            // 균등 3분할: 360pt 폭에서도 칩 하나가 104pt 라 「선택 안 함」이 한 줄로 들어간다.
            ForEach(SignupGenderChoices, id: \.label) { choice in
                SignupChoiceChip(
                    text: choice.label,
                    // 고르지 않은 상태(gender == nil)에서는 **어느 칩도** 선택으로 그려지지
                    // 않는다 — 「선택 안 함」 칩이 기본 선택처럼 보이면 안 되기 때문이다.
                    selected: gender == choice.gender,
                    onClick: { gender = choice.gender }
                )
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        Spacer().frame(height: 8)
        // 09 의 안내 카드를 필드 바로 아래 한 줄로 옮긴 자리다
        // — 필드가 7개인 화면에서 카드를 하나 더 세우면 읽는 흐름이 끊긴다.
        // 성별은 가입 시 서버에 저장되지만 **매칭에는 쓰이지 않는다** — 백엔드 matching
        // 패키지에 성별이 한 번도 등장하지 않는다(user/profile 의 저장·복원 경로에만 있다).
        // 그래서 용도를 말하지 않고, 프로필에 안 보인다는 사실만 적는다(2026-10-13).
        Text("프로필에는 표시되지 않아요")
            .moyeotaText(MoyeotaType.CaptionMd.copy(fontWeight: .medium).hangulTrimmed, color: LabelGray)

        Spacer().frame(height: 20)
        MoyeotaTextField(
            value: phoneDigits,
            onValueChange: { new in
                phoneDigits = digitsOnly(new, maxDigits: 11)
                // 번호가 바뀌면 인증이 무효다 — 무효화 판정은 Route 의 순수 전이가 한다
                onPhoneDigitsChange(phoneDigits)
            },
            label: "휴대폰 번호",
            placeholder: "010-1234-5678",
            // 형식 오류(앱 판정)를 서버 응답 문구보다 앞세운다 — 고칠 곳이 더 구체적이다
            errorText: validation.phoneError ?? phoneVerify.phoneMessage,
            // 「다음」이 왜 잠겨 있는지를 비활성 버튼만으로는 알 수 없다 — 아직 인증을 시작하지
            // 않았을 때만 한 줄로 알려준다(인증 중·완료 상태는 블록이 스스로 말한다)
            helperText: phoneVerify.stage == .idle ? "인증번호를 받아 확인해야 가입할 수 있어요" : nil,
            keyboardOptions: KeyboardOptions(keyboardType: .phone),
            visualTransformation: PhoneNumberTransformation.visualTransformation,
            // 인증을 끝낸 번호는 잠근다: 서버가 토큰을 번호에 묶으므로 한 글자만 고쳐도 가입이 400 이다.
            // 고치려면 블록의 「번호 변경」을 눌러 인증을 버리는 쪽으로만 길을 둔다.
            enabled: !validation.phoneVerified
        )
        PhoneVerificationBlock(
            state: phoneVerify,
            nowMillis: nowMillis,
            phoneDigits: phoneDigits,
            onRequestCode: { onRequestVerificationCode(phoneDigits) },
            onCodeChange: onVerificationCodeChange,
            onSubmitCode: onSubmitVerificationCode,
            onPhoneEditRequested: onPhoneEditRequested,
            onGoToLogin: onGoToLogin
        )
    }

    @ViewBuilder
    private func accountSection(_ validation: ProfileSetupValidation) -> some View {
        ProfileSectionHeader(
            title: "로그인 정보",
            description: "다음에 로그인할 때 쓰는 아이디와 비밀번호예요"
        )

        Spacer().frame(height: 16)
        MoyeotaTextField(
            value: loginId,
            // 규칙상 영소문자만 허용된다 — 대문자를 눌러도 조용히 낮춰 받는다
            onValueChange: { loginId = takeUtf16(loginIdInput(raw: $0), 20) },
            label: "아이디",
            placeholder: "moyeota",
            errorText: validation.loginIdError,
            keyboardOptions: KeyboardOptions(keyboardType: .ascii)
        )

        Spacer().frame(height: 20)
        MoyeotaTextField(
            value: password,
            onValueChange: { password = takeUtf16($0, AuthPolicy.PASSWORD_MAX_LENGTH) },
            label: "비밀번호",
            placeholder: "영문·숫자·특수문자 조합 8자 이상",
            errorText: validation.passwordError,
            keyboardOptions: KeyboardOptions(keyboardType: .password),
            visualTransformation: passwordVisible ? .None : PasswordVisualTransformation()
        ) {
            Button {
                passwordVisible.toggle()
            } label: {
                Text(passwordVisible ? "숨기기" : "보기")
                    .moyeotaText(MoyeotaType.CaptionMd.copy(fontWeight: .bold).hangulTrimmed, color: CounterGray)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressFeedbackStyle())
        }

        Spacer().frame(height: 20)
        MoyeotaTextField(
            value: email,
            onValueChange: { email = withoutWhitespace($0) },
            label: "이메일",
            placeholder: "moyeota@example.com",
            errorText: validation.emailError,
            helperText: "비밀번호를 잊었을 때 쓰는 주소예요",
            keyboardOptions: KeyboardOptions(keyboardType: .email)
        )
    }

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 여전히 참이다 — 업로드 경로는 서버에 없다. 2026-10-15 배포로 생긴 건
            // **제공 이미지 16장 중 고르기**이고, 그것도 가입이 아니라 36 프로필 수정에서 한다.
            Text("사진은 올리지 않아요")
                .moyeotaText(
                    MoyeotaType.BodySm.copy(fontSize: 14, fontWeight: .bold).hangulTrimmed,
                    color: MoyeotaColor.InkPrimary
                )
            Spacer().frame(height: 4)
            // 가입 중에는 어떤 인증 배지도 발급되지 않는다(학교·재직 인증은 가입 경로에 없다).
            // 「매너 기록」도 없다 — 평가 API 자체가 서버에 없어 User.rating 은 항상 0.0 이다
            // (`User` 주석).
            //
            // **프로필 사진을 2026-11-01 에 더했다.** 그전까지 보이는 건 닉네임과 탑승 횟수뿐이었다.
            // 지금은 서버가 고른 적 없는 사용자에게도 기본 이미지 URL 을 주고
            // (`UserProfileInfo.imageUrl`) `MemberAvatar` 가 그것을 그리므로, 20 합류 확인 ·
            // 21 매칭 대기 · 22 탑승 상세 · 23 동승자 프로필 · 24 채팅에서 **전원에게 사진이 보인다.**
            // 가입 시점의 이 고지를 빼면 「닉네임과 탑승 횟수만」을 읽고 가입한 사용자가
            // 자기 사진이 노출되는 걸 모르게 된다 — 이 저장소가 거짓 문구를 들어낸 이유다.
            Text("탑승 상대에게는 닉네임·프로필 사진·탑승 횟수만 보여요")
                .moyeotaText(MoyeotaType.BodySm.copy(fontWeight: .medium).hangulTrimmed, color: SlateGray)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(InfoCardBlue, in: RoundedRectangle(cornerRadius: 18, style: .circular))
    }

    private func submit(_ validation: ProfileSetupValidation) {
        guard let birth = validation.birthDate, let genderValue = gender else { return }
        onNext(
            SignupDraft(
                email: email,
                nickname: nickname.trim(),
                name: realName.trim(),
                // 하이픈 없는 숫자열로 넘긴다 — **문자 인증에 쓴 번호와 글자 단위로 같은 값**이다.
                // 서버는 번호를 해시해 토큰과 대조하므로(하이픈은 서버도 떼므로 결과는 같다)
                // 표기가 갈리면 "인증은 됐는데 가입이 400" 을 디버깅할 때 번호부터 의심하게 된다.
                phoneNumber: phoneDigits,
                birthDate: birth,
                gender: genderValue,
                loginId: loginId,
                password: password,
                // 인증 블록이 받아 둔 토큰. 비어 있으면 「다음」이 열리지 않는다(isValid)
                verificationToken: phoneVerify.token
            )
        )
    }
}

extension ProfileSetupScreen {
    /// 테스트가 「보기」를 켠 상태를 만드는 입구. 창에 올린 화면이라도 코드로는 SwiftUI 버튼을 누를 수 없다.
    func seeded(passwordVisible: Bool) -> Self {
        var copy = self
        copy._passwordVisible = State(initialValue: passwordVisible)
        return copy
    }
}

/// 필드 묶음의 머리말 — 8개 필드를 세 덩어리로 끊어 읽게 한다
private struct ProfileSectionHeader: View {
    let title: String
    let description: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .moyeotaText(MoyeotaType.BodyMd.copy(fontWeight: .bold).hangulTrimmed, color: MoyeotaColor.InkPrimary)
            Spacer().frame(height: 4)
            Text(description)
                .moyeotaText(MoyeotaType.CaptionMd.copy(fontWeight: .medium).hangulTrimmed, color: LabelGray)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// 아바타 기본색 (와이어프레임 톤 — core token 미정의)
private let AvatarOuter = Color(argb: 0xFFD8E0F2)
private let AvatarInner = Color(argb: 0xFF8296C8)

// 와이어프레임의 사람 실루엣 아바타 (사진 업로드 없음 — 정책상 미지원)
private struct ProfileAvatarPlaceholder: View {
    var body: some View {
        Canvas { context, size in
            func circle(radius: CGFloat, center: CGPoint) -> Path {
                Path(ellipseIn: CGRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                ))
            }
            context.fill(Path(ellipseIn: CGRect(origin: .zero, size: size)), with: .color(AvatarOuter))
            // 머리
            context.fill(
                circle(radius: size.width * 0.155, center: CGPoint(x: size.width / 2, y: size.height * 0.40)),
                with: .color(AvatarInner)
            )
            // 어깨
            context.fill(
                circle(radius: size.width * 0.30, center: CGPoint(x: size.width / 2, y: size.height * 0.98)),
                with: .color(AvatarInner)
            )
        }
        .frame(width: 88, height: 88)
        .clipShape(Circle())
    }
}

private struct ProfileStepProgressBar: View {
    let progress: CGFloat

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2, style: .circular).fill(TrackGray)
                RoundedRectangle(cornerRadius: 2, style: .circular)
                    .fill(MoyeotaColor.Primary500)
                    .frame(width: geometry.size.width * progress)
            }
        }
        .frame(height: 4)
        .padding(.horizontal, 16)
    }
}
