import MoyeotaDesignSystem
import PresentationCore
import SwiftUI

// 06 · 학교 이메일 [S02]
//
// ⚠️ 현재 어떤 그래프에도 등록되어 있지 않다 — 가입 필수 경로에서 05~08 을 걷어냈다.
// 가입 API 에 학교 인증 개념이 없고, 인증은 마이페이지에서 나중에 붙이는 컨셉이다.
// 그때 이 화면을 그대로 재사용하기 위해 파일은 남겨 둔다(MainNavGraph 의 C 절 주석 참고).
//
// (원래 배선) 진입: 05에서 「학생」 선택 / 뒤로 → 05 / 「인증 메일 보내기」 → 07 인증 코드
let SupportedDomains = ["@pusan.ac.kr", "@pukyong.ac.kr", "@donga.ac.kr"]

// 유효값 검증: 로컬파트 — 영문·숫자·. _ - 만 허용, 2~64자, 공백 불가
let LocalPartRegex = JavaRegex("^[A-Za-z0-9._-]{2,64}$")

private let LabelGray = Color(argb: 0xFF8A93A0)
private let SlateGray = Color(argb: 0xFF4B5563)
private let FooterGray = Color(argb: 0xFF9AA1AC)
private let InfoCardBlue = Color(argb: 0xFFF1F5FD)

public struct SchoolEmailScreen: View {
    private let onBack: () -> Void
    private let onSendMail: (_ email: String) -> Void

    @State private var localPart = ""
    @State private var domain = SupportedDomains[0]
    @State private var domainMenuOpen = false
    @State private var submitting = false

    public init(
        onBack: @escaping () -> Void = {},
        onSendMail: @escaping (_ email: String) -> Void = { _ in }
    ) {
        self.onBack = onBack
        self.onSendMail = onSendMail
    }

    public var body: some View {
        let localPartValid = LocalPartRegex.matches(localPart)
        let fieldError: String? = !localPart.isEmpty && !localPartValid
            ? "영문·숫자·. _ - 만 2~64자로 입력할 수 있어요"
            : nil

        VStack(spacing: 0) {
            StatusBarSpacer()
            MoyeotaTopBar(title: "", onBack: onBack) {
                Text("1 / 5")
                    .moyeotaText(.BodySm, color: LabelGray)
            }
            SchoolEmailProgressBar(progress: 1.0 / 5.0)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Spacer().frame(height: 24)
                    Text("학교 이메일을 알려주세요")
                        .moyeotaText(.DisplayMd, color: MoyeotaColor.InkPrimary)
                    Spacer().frame(height: 10)
                    Text(verbatim: "\(domain) 메일로 인증 코드를 보내드려요")
                        .moyeotaText(MoyeotaType.BodySm.copy(fontSize: 14), color: MoyeotaColor.TextMute)
                    Spacer().frame(height: 30)

                    MoyeotaTextField(
                        value: localPart,
                        onValueChange: { localPart = withoutWhitespace($0) },
                        label: "학교 이메일",
                        placeholder: "moyeota",
                        errorText: fieldError,
                        helperText: "인증 메일은 5분 안에 도착해요",
                        keyboardOptions: KeyboardOptions(keyboardType: .email),
                        enabled: !submitting
                    ) {
                        // 도메인 셀렉트 → @pusan.ac.kr / @pukyong.ac.kr / @donga.ac.kr — 지원 3개 외 선택 불가
                        Button {
                            domainMenuOpen = true
                        } label: {
                            Text(domain)
                                .moyeotaText(.BodyMd, color: LabelGray)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PressFeedbackStyle())
                        .anchorPreference(key: DomainMenuAnchorKey.self, value: .bounds) { $0 }
                    }

                    Spacer().frame(height: 24)

                    // 이렇게 보호해요 카드
                    VStack(alignment: .leading, spacing: 0) {
                        Text("이렇게 보호해요")
                            .moyeotaText(
                                MoyeotaType.BodySm.copy(fontSize: 14, fontWeight: .bold),
                                color: MoyeotaColor.InkPrimary
                            )
                        Spacer().frame(height: 14)
                        SchoolEmailProtectRow(text: "이름과 학번은 저장하지 않아요")
                        Spacer().frame(height: 13)
                        SchoolEmailProtectRow(text: "메일 주소는 암호화해 보관해요")
                        Spacer().frame(height: 13)
                        SchoolEmailProtectRow(text: "다른 이용자에게 공개하지 않아요")
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(InfoCardBlue, in: RoundedRectangle(cornerRadius: 18, style: .circular))

                    Spacer().frame(height: 24)

                    // 다른 학교 메일 안내 → 도메인 셀렉트 열기
                    otherSchoolRow
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
                    text: "인증 메일 보내기",
                    onClick: {
                        submitting = true
                        onSendMail(localPart + domain)
                    },
                    enabled: localPartValid,
                    loading: submitting
                )
                Spacer().frame(height: 14)
                // 미연결: 학생증 인증 — 클릭해도 동작 없음 (대체 인증 플로우 필요)
                Text("학생증으로 인증하기")
                    .moyeotaText(MoyeotaType.BodySm.copy(fontWeight: .bold), color: MoyeotaColor.Primary500)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                Spacer().frame(height: 10)
                Text("인증 정보는 매칭 확인 외에 쓰이지 않아요")
                    .moyeotaText(.CaptionSm, color: FooterGray)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            NavigationBarSpacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MoyeotaColor.SurfaceSoft)
        .overlayPreferenceValue(DomainMenuAnchorKey.self) { anchor in
            GeometryReader { geometry in
                if domainMenuOpen, let anchor {
                    DomainDropdownMenu(
                        anchor: geometry[anchor],
                        container: geometry.size,
                        onSelect: { candidate in
                            domain = candidate
                            domainMenuOpen = false
                        },
                        onDismiss: { domainMenuOpen = false }
                    )
                }
            }
        }
        .moyeotaBackHandler(enabled: domainMenuOpen) { domainMenuOpen = false }
        // 원본 `remember` 는 화면이 컴포지션에서 빠지면 사라진다. `@State` 는 스택에 있는 동안 남으므로 직접 비운다.
        .onDisappear {
            localPart = ""
            domain = SupportedDomains[0]
            domainMenuOpen = false
            submitting = false
        }
    }

    private var otherSchoolRow: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .circular)
        return Button {
            domainMenuOpen = true
        } label: {
            HStack(alignment: .center, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("다른 학교 메일을 쓰나요?")
                        .moyeotaText(
                            MoyeotaType.BodySm.copy(fontSize: 14, fontWeight: .bold),
                            color: MoyeotaColor.InkPrimary
                        )
                    Spacer().frame(height: 4)
                    Text("부산대 · 부경대 · 동아대 메일을 지원해요")
                        .moyeotaText(.CaptionMd, color: LabelGray)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                SchoolEmailChevronIcon()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(Color.white, in: shape)
        }
        .buttonStyle(PressOverlayStyle(shape: shape))
        .moyeotaShadow(elevation: 2, shape: shape)
    }
}

extension SchoolEmailScreen {
    /// 테스트가 CTA 를 누른 뒤의 상태를 만드는 입구. 창에 올린 화면이라도 코드로는 SwiftUI 버튼을 누를 수 없다.
    func seeded(submitting: Bool) -> Self {
        var copy = self
        copy._submitting = State(initialValue: submitting)
        return copy
    }
}

private struct DomainMenuAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// 머티리얼 3 `DropdownMenu` 의 자리. 값은 머티리얼 1.4.0 그대로다 — 모서리 4, 위아래 여백 8, 고도 3,
/// 항목 높이 최소 48·폭 112~280·좌우 여백 12, 배경은 기본 `surfaceContainer`(#F3EDF7).
/// 이 테마는 그 색을 지정하지 않아 머티리얼 기본값이 그대로 나온다.
private struct DomainDropdownMenu: View {
    let anchor: CGRect
    let container: CGSize
    let onSelect: (String) -> Void
    let onDismiss: () -> Void

    /// 원본 `MenuVerticalMargin`. 위아래로 이만큼은 비우고 놓는다.
    private let verticalMargin: CGFloat = 48

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .circular)
        ZStack(alignment: .topLeading) {
            // 메뉴 밖을 누르면 닫는다
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(SupportedDomains, id: \.self) { candidate in
                    Button {
                        onSelect(candidate)
                    } label: {
                        Text(candidate)
                            .moyeotaText(.BodySm, color: MoyeotaColor.InkPrimary)
                            .padding(.horizontal, 12)
                            .frame(minWidth: 112, maxWidth: 280, minHeight: 48, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressOverlayStyle(shape: Rectangle()))
                }
            }
            .padding(.vertical, 8)
            .background(Color(argb: 0xFFF3EDF7), in: shape)
            .moyeotaShadow(elevation: 3, shape: shape)
            .fixedSize()
            // 원본 위치 규칙: 앵커 왼쪽에 맞추되 넘치면 오른쪽에 맞추고, 앵커 아래에 놓되 넘치면 위에 놓는다.
            .alignmentGuide(.leading) { size in
                let fitsFromLeft = anchor.minX + size.width <= container.width
                return -(fitsFromLeft ? anchor.minX : anchor.maxX - size.width)
            }
            .alignmentGuide(.top) { size in
                let fitsBelow = anchor.maxY + size.height <= container.height - verticalMargin
                return -(fitsBelow ? anchor.maxY : anchor.minY - size.height)
            }
        }
        .frame(width: container.width, height: container.height, alignment: .topLeading)
    }
}

private struct SchoolEmailProgressBar: View {
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

private struct SchoolEmailProtectRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            SchoolEmailCheckIcon()
            Text(text)
                .moyeotaText(.BodySm, color: SlateGray)
        }
    }
}

private struct SchoolEmailCheckIcon: View {
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
        .frame(width: 15, height: 15)
    }
}

private struct SchoolEmailChevronIcon: View {
    var body: some View {
        Canvas { context, size in
            let color = Color(argb: 0xFFB6BEC9)
            let style = StrokeStyle(lineWidth: 2, lineCap: .round)
            var upper = Path()
            upper.move(to: CGPoint(x: size.width * 0.35, y: size.height * 0.2))
            upper.addLine(to: CGPoint(x: size.width * 0.7, y: size.height * 0.5))
            context.stroke(upper, with: .color(color), style: style)
            var lower = Path()
            lower.move(to: CGPoint(x: size.width * 0.7, y: size.height * 0.5))
            lower.addLine(to: CGPoint(x: size.width * 0.35, y: size.height * 0.8))
            context.stroke(lower, with: .color(color), style: style)
        }
        .frame(width: 16, height: 16)
    }
}
