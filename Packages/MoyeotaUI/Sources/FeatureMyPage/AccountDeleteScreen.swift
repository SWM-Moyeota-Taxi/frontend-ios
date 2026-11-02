import MoyeotaDesignSystem
import PresentationCore
import SwiftUI

/// 37 · 회원 탈퇴 (신규, 2026-10)
///
/// 진입: 35 마이페이지 「탈퇴하기」 / 뒤로 → 35 / 성공 → 04a 로그인(세션이 사라져 내비게이션 층이 보낸다)
///
/// 구성: 상단바 「회원 탈퇴」 → 「무엇이 지워지는가」 목록 → 비밀번호 확인 입력 → 「탈퇴하기」(확인 다이얼로그)
///
/// ### 왜 다이얼로그가 아니라 화면인가
/// 서버가 본인 확인 비밀번호를 **본문으로** 요구한다(`DELETE /api/v1/users/me`). 그러면 (a) 입력란과
/// (b) 비밀번호 틀림(400 `USER111`)·진행 중 합승(409 `USER110`) 두 가지 실패 표시가 필요하고,
/// (c) 지워지는 것 네 줄을 사용자가 읽을 자리도 있어야 한다. 다이얼로그에 그걸 다 넣으면
/// 키보드가 올라온 순간 경고 문구가 화면 밖으로 밀려 **읽히지 않는 경고**가 된다.
///
/// 비밀번호 입력 자체가 이미 "한 번 더 확인"이지만 최종 다이얼로그를 **하나 더** 둔다 —
/// 되돌릴 수 없는 동작이고, 비밀번호는 기억해서 치는 값이라 의도 확인으로는 약하다.
///
/// ### 경고 문구의 원칙
/// `AccountDeletionWarnings` 의 네 줄은 **서버가 실제로 하는 일만** 적는다. 지난 합승 기록은 서버가
/// 지우지 않으므로 "모든 기록이 사라져요" 같은 말을 쓰지 않는다 — 근거는 그 상수의 주석에 있다.
/// 진행 중인 합승 제약은 여기 적지 않는다: 앱이 미리 알 수 없는 값이라 경고가 아니라 실패 사유다
/// (누르면 `bannerError` 로 온다).
///
/// ### 「자세히 보기」를 35 가 아니라 여기 둔 이유 (2026-10-14)
/// 계정 삭제 안내 웹페이지(`SupportLinks.ACCOUNT_DELETION_URL`)는 스토어 데이터 안전 섹션에
/// 등록하는 주소이자, 네 줄 요약의 **전문**(보관 기간·남는 데이터·처리 절차)이다. 그 링크를
/// 35 마이페이지 「안내」 카드에 행으로 두면 「탈퇴하기」와 뜻이 겹치는 입구가 두 개 생긴다 —
/// 하나는 브라우저로 나가고(↗) 하나는 앱 안에서 계정을 지우는 길인데(›), 둘 다 「계정 삭제」로
/// 읽혀 파괴적인 오탭 면적만 넓어진다. **자세히 알고 싶어지는 자리는 네 줄을 읽은 직후**라,
/// 경고 카드 바로 아래 한 줄로 둔다. 네 줄을 되풀이하지 않고 "무엇이 남는지"까지 있다고만 알린다.
///
/// 주소가 nil 이면 이 줄을 그리지 않는다 — 35 의 메뉴 행과 같은 규칙이다(죽은 링크를 보여 주지 않는다).
///
/// - Parameter passwordError: 비밀번호 입력란 아래 오류. 비밀번호 불일치만 여기 온다.
/// - Parameter bannerError: 버튼 위 배너. 진행 중 합승·네트워크·세션 만료처럼 이 화면에서 못 고치는 실패.
/// - Parameter guideUrl: 계정 삭제 안내 페이지. nil 이면 「자세히 보기」 줄을 그리지 않는다.
public struct AccountDeleteScreen: View {
    private let password: String
    private let submitting: Bool
    private let passwordError: String?
    private let bannerError: String?
    private let guideUrl: String?
    private let onPasswordChange: (String) -> Void
    private let onDelete: () -> Void
    private let onBack: () -> Void

    @State private var confirming = false
    @State private var passwordVisible = false

    public init(
        password: String,
        submitting: Bool = false,
        passwordError: String? = nil,
        bannerError: String? = nil,
        guideUrl: String? = SupportLinks.ACCOUNT_DELETION_URL,
        onPasswordChange: @escaping (String) -> Void = { _ in },
        onDelete: @escaping () -> Void = {},
        onBack: @escaping () -> Void = {}
    ) {
        self.password = password
        self.submitting = submitting
        self.passwordError = passwordError
        self.bannerError = bannerError
        self.guideUrl = guideUrl
        self.onPasswordChange = onPasswordChange
        self.onDelete = onDelete
        self.onBack = onBack
    }

    public var body: some View {
        let canSubmit = canSubmitAccountDeletion(password: password, submitting: submitting)

        ZStack {
            VStack(spacing: 0) {
                StatusBarSpacer()
                MoyeotaTopBar(title: "회원 탈퇴", onBack: onBack)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        Spacer().frame(height: 16)
                        Text("탈퇴하면 되돌릴 수 없어요")
                            .moyeotaText(MoyeotaType.HeadingLg.hangulTrimmed, color: MoyeotaColor.InkPrimary)
                        Spacer().frame(height: 8)
                        Text("아래 내용을 확인한 뒤 비밀번호를 입력해 주세요")
                            .moyeotaText(MoyeotaType.BodySm.hangulTrimmed, color: MoyeotaColor.TextMute)

                        Spacer().frame(height: 20)
                        // 경고를 카드로 묶어 "읽어야 하는 덩어리"로 보이게 한다. 배너(NoticeBanner)로 쓰지 않는 이유는
                        // 네 줄이라 한 문단으로 뭉쳐 보이고, 줄마다 다른 사실이라는 게 사라지기 때문이다.
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(AccountDeletionWarnings.enumerated()), id: \.offset) { index, warning in
                                if index > 0 {
                                    Spacer().frame(height: 10)
                                }
                                WarningLine(text: warning)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(MoyeotaColor.Danger50, in: RoundedRectangle(cornerRadius: 14, style: .circular))

                        // 경고 카드 바로 아래 — 네 줄의 전문으로 가는 한 줄. 입력란보다 위에 둬서 키보드가
                        // 올라와도 밀려 사라지지 않는다(이 화면을 다이얼로그로 만들지 않은 것과 같은 이유다).
                        if let guideUrl {
                            Button {
                                openWebPage(url: guideUrl)
                            } label: {
                                HStack(spacing: 0) {
                                    Text("지워지는 것과 남는 것 자세히 보기")
                                        .moyeotaText(
                                            MoyeotaType.BodySm.copy(fontWeight: .bold).hangulTrimmed,
                                            color: MoyeotaColor.Link
                                        )
                                    Spacer().frame(width: 4, height: 4)
                                    // ↗ = 앱 밖으로 나간다. 35 마이페이지와 같은 기호를 그대로 쓴다.
                                    ExternalLinkIcon(tint: MoyeotaColor.Link)
                                }
                                // 글자만 눌리면 터치 영역이 20pt 밖에 안 된다 — 위아래로 넓혀 둔다
                                .padding(.vertical, 10)
                                .padding(.horizontal, 2)
                            }
                            .buttonStyle(NoIndicationStyle())
                            .padding(.top, 12)
                        }

                        Spacer().frame(height: 24)
                        MoyeotaTextField(
                            value: password,
                            onValueChange: onPasswordChange,
                            label: "비밀번호",
                            placeholder: "지금 쓰고 있는 비밀번호",
                            errorText: passwordError,
                            helperText: passwordError == nil ? "본인 확인을 위해 한 번 더 입력해요" : nil,
                            keyboardOptions: KeyboardOptions(keyboardType: .password, imeAction: .done),
                            visualTransformation: passwordVisible ? .None : PasswordVisualTransformation(),
                            enabled: !submitting
                        ) {
                            // 04a 로그인과 같은 방식 — 비밀번호를 못 보고 치다 틀리는 쪽이 더 흔한 사고다
                            Button {
                                passwordVisible.toggle()
                            } label: {
                                Text(passwordVisible ? "숨기기" : "보기")
                                    .moyeotaText(
                                        MoyeotaType.CaptionMd.copy(fontWeight: .bold),
                                        color: MoyeotaColor.TextMute
                                    )
                            }
                            .buttonStyle(NoIndicationStyle())
                        }

                        // 이 화면에서 고칠 수 없는 실패(진행 중 합승·네트워크)는 버튼 위 배너로 둔다 — 입력란을
                        // 빨갛게 만들면 사용자가 비밀번호를 계속 다시 친다.
                        if let bannerError {
                            Spacer().frame(height: 16)
                            NoticeBanner(kind: .error, text: bannerError)
                        }
                        Spacer().frame(height: 24)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                }
                .scrollBounceBehavior(.basedOnSize)
                // 원본 `verticalScroll` 은 자기 칸에서 잘린다.
                .clipped()
                // 원본 `verticalScroll` 은 스크롤해도 키보드를 내리지 않는다 — 비밀번호를 치다 경고를 다시 읽어도 입력이 이어진다.
                .scrollDismissesKeyboard(.never)

                DangerCtaButton(
                    text: "탈퇴하기",
                    onClick: { confirming = true },
                    enabled: canSubmit,
                    loading: submitting
                )
                .padding(.horizontal, 16)
                Spacer().frame(height: 16)
                NavigationBarSpacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(MoyeotaColor.SurfaceSoft)

            if confirming {
                MaterialAlertDialog(
                    onDismissRequest: { confirming = false },
                    title: {
                        Text("정말 탈퇴할까요?")
                            .moyeotaText(MoyeotaType.HeadingMd.hangulTrimmed, color: MoyeotaColor.InkPrimary)
                    },
                    text: {
                        // 다이얼로그는 목록을 되풀이하지 않는다 — 바로 위에서 읽은 것을 다시 읽히면
                        // 사용자는 둘 중 하나만 읽고 넘긴다. 여기서는 "되돌릴 수 없다" 하나만 말한다.
                        MaterialDialogBodyText(
                            text: "탈퇴하면 계정과 저장한 정보가 사라지고 되돌릴 수 없어요",
                            style: MoyeotaType.BodySm.hangulTrimmed,
                            color: MoyeotaColor.TextBody
                        )
                    },
                    confirmButton: {
                        MaterialTextButton(
                            text: "탈퇴하기",
                            style: MaterialTextStyle.labelLarge(fontWeight: .bold),
                            color: MoyeotaColor.Danger500
                        ) {
                            confirming = false
                            onDelete()
                        }
                    },
                    dismissButton: {
                        MaterialTextButton(text: "취소", color: MoyeotaColor.TextMute) {
                            confirming = false
                        }
                    }
                )
            }
        }
        // 원본 `remember` 는 화면이 컴포지션에서 빠지면 사라진다. `@State` 는 스택에 있는 동안 남으므로 직접 비운다.
        .onDisappear {
            confirming = false
            passwordVisible = false
        }
    }

    /// 테스트가 「보기」·확인창을 켠 상태를 만드는 입구. 창에 올린 화면이라도 코드로는 SwiftUI 버튼을 누를 수 없다.
    func seeded(confirming: Bool = false, passwordVisible: Bool = false) -> Self {
        var copy = self
        copy._confirming = State(initialValue: confirming)
        copy._passwordVisible = State(initialValue: passwordVisible)
        return copy
    }
}

/// 경고 한 줄. 불릿은 글꼴에 따라 빠질 수 있는 문자 대신 작은 점으로 그린다(35 의 아이콘 방침과 같다).
private struct WarningLine: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Circle()
                .fill(MoyeotaColor.Danger500)
                .frame(width: 4, height: 4)
                .padding(.top, 7)
            Spacer().frame(width: 10, height: 10)
            Text(text)
                .moyeotaText(MoyeotaType.BodySm.hangulTrimmed, color: MoyeotaColor.Danger600)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }
}

/// `Modifier.clickable(indication = null)` 자리. 눌러도 아무 표시가 없고, 글자 영역 전체가 탭 영역이다.
private struct NoIndicationStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
    }
}
