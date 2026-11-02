import MoyeotaDesignSystem
import SwiftUI

// 08 · 직장인 재직 인증 [S26]
//
// ⚠️ 현재 어떤 그래프에도 등록되어 있지 않다 (06 과 같은 이유 — 인증은 마이페이지로 이동 예정).
//
// (원래 배선) 진입: 05에서 「직장인」 선택 / 뒤로 → 05 / 「인증 요청 보내기」 → 09 본인 인증
// 유효값 검증: 회사 이메일 — RFC 형식 + 무료 메일 도메인(gmail·naver 등) 차단
let CompanyEmailRegex = JavaRegex(#"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#)
let FreeMailDomains: Set<String> = [
    "gmail.com", "naver.com", "daum.net", "hanmail.net", "kakao.com",
    "nate.com", "outlook.com", "hotmail.com", "yahoo.com", "icloud.com",
]

private let LabelGray = Color(argb: 0xFF8A93A0)
private let SlateGray = Color(argb: 0xFF4B5563)
private let FooterGray = Color(argb: 0xFF9AA1AC)
private let InfoCardBlue = Color(argb: 0xFFF1F5FD)
private let DocCardGray = Color(argb: 0xFFF6F8FB)

/// 회사 이메일 판정. 원본은 화면 본문 안의 지역 값들이고, 뷰 없이 확인하려고 값으로 모았다.
struct WorkEmailValidation: Equatable {
    let emailValid: Bool
    let fieldError: String?

    init(email: String) {
        let formatValid = CompanyEmailRegex.matches(email)
        // `substringAfterLast('@', "")` 자리. 스칼라로 찾아 결합 문자가 붙어도 놓치지 않는다.
        let scalars = email.unicodeScalars
        let domain = scalars.lastIndex(of: "@")
            .map { String(scalars[scalars.index(after: $0)...]).lowercased() } ?? ""
        let isFreeMail = formatValid && FreeMailDomains.contains(domain)
        emailValid = formatValid && !isFreeMail
        if email.isEmpty {
            fieldError = nil
        } else if !formatValid {
            fieldError = "이메일 형식이 올바르지 않아요"
        } else if isFreeMail {
            fieldError = "무료 메일(gmail·naver 등)은 사용할 수 없어요"
        } else {
            fieldError = nil
        }
    }
}

public struct WorkVerifyScreen: View {
    private let onBack: () -> Void
    private let onSubmit: (_ companyEmail: String) -> Void

    @State private var email = ""
    @State private var submitting = false

    public init(
        onBack: @escaping () -> Void = {},
        onSubmit: @escaping (_ companyEmail: String) -> Void = { _ in }
    ) {
        self.onBack = onBack
        self.onSubmit = onSubmit
    }

    public var body: some View {
        let validation = WorkEmailValidation(email: email)
        // 회사 메일과 재직 서류 중 최소 1개 필수 — 서류 업로드가 미연결이므로 회사 메일이 사실상 필수다
        let ctaEnabled = validation.emailValid

        VStack(spacing: 0) {
            StatusBarSpacer()
            MoyeotaTopBar(title: "", onBack: onBack) {
                // 08 은 학생 경로의 06·07 과 같은 「인증」 1단계다 — 09 가 2단계이므로 여기는 1/5
                Text("1 / 5")
                    .moyeotaText(.BodySm, color: LabelGray)
            }
            WorkVerifyProgressBar(progress: 1.0 / 5.0)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Spacer().frame(height: 24)
                    Text("신원을 확인할게요")
                        .moyeotaText(.DisplayMd, color: MoyeotaColor.InkPrimary)
                    Spacer().frame(height: 10)
                    Text("재직 정보로 직장인 인증을 진행해요")
                        .moyeotaText(MoyeotaType.BodySm.copy(fontSize: 14), color: MoyeotaColor.TextMute)
                    Spacer().frame(height: 24)
                    Text("직장인 재직 인증 · 05 계정 유형 선택에서 선택함")
                        .moyeotaText(MoyeotaType.BodySm.copy(fontWeight: .bold), color: MoyeotaColor.Primary500)
                    Spacer().frame(height: 28)

                    MoyeotaTextField(
                        value: email,
                        onValueChange: { email = withoutWhitespace($0) },
                        label: "회사 이메일",
                        placeholder: "name@company.com",
                        errorText: validation.fieldError,
                        keyboardOptions: KeyboardOptions(keyboardType: .email),
                        enabled: !submitting
                    )

                    Spacer().frame(height: 24)
                    Text("재직 서류 (선택)")
                        .moyeotaText(.BodySm, color: LabelGray)
                    Spacer().frame(height: 8)
                    // 미연결: 재직 서류 탭 → 파일/카메라 선택 시트 — 클릭해도 동작 없음
                    HStack(alignment: .center, spacing: 0) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .circular).fill(MoyeotaColor.Primary50)
                            WorkVerifyCameraIcon()
                        }
                        .frame(width: 44, height: 44)
                        Spacer().frame(width: 16, height: 0)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("재직증명서 · 사원증 촬영")
                                .moyeotaText(
                                    MoyeotaType.BodySm.copy(fontSize: 14, fontWeight: .bold),
                                    color: MoyeotaColor.InkPrimary
                                )
                            Spacer().frame(height: 4)
                            Text("회사 메일이 없으면 서류로 인증할 수 있어요")
                                .moyeotaText(.CaptionMd, color: LabelGray)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DocCardGray, in: RoundedRectangle(cornerRadius: 16, style: .circular))

                    Spacer().frame(height: 24)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("이렇게 보호해요")
                            .moyeotaText(
                                MoyeotaType.BodySm.copy(fontSize: 14, fontWeight: .bold),
                                color: MoyeotaColor.InkPrimary
                            )
                        Spacer().frame(height: 13)
                        WorkVerifyProtectRow(text: "회사명과 서류는 인증 후 즉시 삭제해요")
                        Spacer().frame(height: 5)
                        WorkVerifyProtectRow(text: "직업은 「직장인 인증」 배지로만 표시돼요")
                        Spacer().frame(height: 5)
                        WorkVerifyProtectRow(text: "동료에게 가입 사실이 알려지지 않아요")
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(InfoCardBlue, in: RoundedRectangle(cornerRadius: 18, style: .circular))
                    Spacer().frame(height: 24)
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 0) {
                PrimaryCtaButton(
                    text: "인증 요청 보내기",
                    onClick: {
                        submitting = true
                        onSubmit(email)
                    },
                    enabled: ctaEnabled,
                    loading: submitting
                )
                Spacer().frame(height: 14)
                Text("재직 확인은 보통 1일 안에 끝나요")
                    .moyeotaText(.CaptionMd, color: FooterGray)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            NavigationBarSpacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MoyeotaColor.SurfaceSoft)
        // 원본 `remember` 는 화면이 컴포지션에서 빠지면 사라진다. `@State` 는 스택에 있는 동안 남으므로 직접 비운다.
        .onDisappear {
            email = ""
            submitting = false
        }
    }
}

extension WorkVerifyScreen {
    /// 테스트가 CTA 를 누른 뒤의 상태를 만드는 입구. 창에 올린 화면이라도 코드로는 SwiftUI 버튼을 누를 수 없다.
    func seeded(submitting: Bool) -> Self {
        var copy = self
        copy._submitting = State(initialValue: submitting)
        return copy
    }
}

private struct WorkVerifyProgressBar: View {
    let progress: CGFloat

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2, style: .circular).fill(Color(argb: 0xFFE6EAF0))
                RoundedRectangle(cornerRadius: 2, style: .circular)
                    .fill(MoyeotaColor.Primary500)
                    .frame(width: geometry.size.width * progress)
            }
        }
        .frame(height: 4)
        .padding(.horizontal, 16)
    }
}

private struct WorkVerifyProtectRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            WorkVerifyCheckIcon()
            Text(text)
                .moyeotaText(.BodySm, color: SlateGray)
        }
    }
}

private struct WorkVerifyCheckIcon: View {
    var body: some View {
        Canvas { context, size in
            let style = StrokeStyle(lineWidth: 2, lineCap: .round)
            var head = Path()
            head.move(to: CGPoint(x: size.width * 0.1, y: size.height * 0.55))
            head.addLine(to: CGPoint(x: size.width * 0.4, y: size.height * 0.85))
            context.stroke(head, with: .color(MoyeotaColor.Primary500), style: style)
            var tail = Path()
            tail.move(to: CGPoint(x: size.width * 0.4, y: size.height * 0.85))
            tail.addLine(to: CGPoint(x: size.width * 0.9, y: size.height * 0.2))
            context.stroke(tail, with: .color(MoyeotaColor.Primary500), style: style)
        }
        .frame(width: 14, height: 14)
    }
}

private struct WorkVerifyCameraIcon: View {
    var body: some View {
        Canvas { context, size in
            let stroke: CGFloat = 1.5
            let color = MoyeotaColor.Primary500
            let bodyTop = size.height * 0.25
            context.stroke(
                Path(
                    roundedRect: CGRect(
                        x: 0,
                        y: bodyTop,
                        width: size.width,
                        height: size.height - bodyTop - size.height * 0.08
                    ),
                    cornerRadius: 3,
                    style: .circular
                ),
                with: .color(color),
                style: StrokeStyle(lineWidth: stroke)
            )
            let line = StrokeStyle(lineWidth: stroke, lineCap: .round)
            // 뷰파인더 돌출부
            for (from, to) in [
                (CGPoint(x: size.width * 0.32, y: bodyTop), CGPoint(x: size.width * 0.42, y: size.height * 0.1)),
                (CGPoint(x: size.width * 0.42, y: size.height * 0.1), CGPoint(x: size.width * 0.58, y: size.height * 0.1)),
                (CGPoint(x: size.width * 0.58, y: size.height * 0.1), CGPoint(x: size.width * 0.68, y: bodyTop)),
            ] {
                var segment = Path()
                segment.move(to: from)
                segment.addLine(to: to)
                context.stroke(segment, with: .color(color), style: line)
            }
            // 렌즈
            let radius = size.width * 0.17
            context.stroke(
                Path(ellipseIn: CGRect(
                    x: size.width * 0.5 - radius,
                    y: size.height * 0.58 - radius,
                    width: radius * 2,
                    height: radius * 2
                )),
                with: .color(color),
                style: StrokeStyle(lineWidth: stroke)
            )
        }
        .frame(width: 20, height: 20)
    }
}
