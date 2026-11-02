import MoyeotaDesignSystem
import MoyeotaDomain
import PresentationCore
import SwiftUI

// 09 · 본인 인증 [S04] — ⚠️ **현재 어떤 그래프에도 등록되어 있지 않다 (미연결)**
//
// 휴대폰(통신사) 본인 인증은 MVP 범위 밖으로 빠졌다. 이 화면은 인증 없이 값만 묻는 폼이
// 되어 있었으므로 가입 경로에서 들어냈고, 받던 값(실명·휴대폰·생년월일·성별)은 그대로
// 10 프로필 만들기의 「기본 정보」 절로 옮겼다. 검증 규칙은 SignupFieldSupport 로 공용화했다.
//
// 파일을 남긴 이유: 실제 본인 인증(SMS·PASS)을 붙일 때 통신사 선택 UI 와 폼 배치를 재사용한다.
// 되살릴 때는 (a) 내비게이션 그래프에 다시 등록, (b) 진행 표시 「1 / 4」 재계산,
// (c) 10 과 중복되는 입력 정리, (d) 약관 동의(현재 12 매너 서약에 통합됨) 중복 여부 확인이 필요하다.
private let Carriers = ["SKT", "KT", "LG U+", "알뜰폰"]

private let LabelGray = Color(argb: 0xFF8A93A0)
private let SlateGray = Color(argb: 0xFF4B5563)
private let InfoCardBlue = Color(argb: 0xFFF1F5FD)

public struct IdentityVerifyScreen: View {
    private let onBack: () -> Void
    private let onRequestCode: (_ name: String, _ phone: String, _ birthDate: LocalDate, _ gender: Gender) -> Void

    @State private var carrier: String?
    @State private var phoneDigits = ""
    @State private var name = ""
    @State private var birthDigits = ""
    @State private var gender: Gender?
    @State private var agreed = false
    @State private var submitting = false

    /// - Parameter onRequestCode: 「다음」 → 10 프로필 만들기. 서버 가입에 그대로 들어갈 값들이다.
    ///   (이름은 SMS 인증을 보내던 시절의 잔재다 — 실제 발송은 없다)
    public init(
        onBack: @escaping () -> Void = {},
        onRequestCode: @escaping (_ name: String, _ phone: String, _ birthDate: LocalDate, _ gender: Gender) -> Void = { _, _, _, _ in }
    ) {
        self.onBack = onBack
        self.onRequestCode = onRequestCode
    }

    public var body: some View {
        // 유효값 검증: 휴대폰 — 010 + 숫자 8자리, 하이픈 자동 삽입, 그 외 형식 거부
        let phoneLength = phoneDigits.utf16.count
        let startsWith010 = phoneDigits.utf16.starts(with: "010".utf16)
        let phoneValid = phoneLength == 11 && startsWith010
        let phoneError: String? = {
            if phoneDigits.isEmpty { return nil }
            if phoneLength >= 3 && !startsWith010 { return "010으로 시작하는 휴대폰 번호만 인증할 수 있어요" }
            if (3...10).contains(phoneLength) || phoneValid { return nil }
            return "휴대폰 번호는 010 + 숫자 8자리로 입력해 주세요"
        }()
        let nameValid = PersonNameRegex.matches(name)
        let nameError: String? = !name.isEmpty && !nameValid ? "이름은 한글 또는 영문 2~20자로 입력해 주세요" : nil

        // 유효값 검증: 생년월일 — 8자리를 채웠을 때만 실제 날짜인지까지 본다(20250230 같은 값 차단).
        // 판정·문구는 10 프로필 만들기와 **같은 함수**를 쓴다(SignupFieldSupport): 만 14세 미만 가입 차단이
        // 10 에만 있으면, 이 화면이 가입 경로로 되살아날 때 연령 제한이 빠진 채 돌아온다.
        let birthDate = parseBirthDate(digits: birthDigits)
        let birthError = birthDateError(digits: birthDigits)

        // 모든 필수 값 + 약관 동의 → 미충족 시 CTA 비활성
        // birthError 까지 보는 이유: 만 14세 미만은 "실제로 있는 과거 날짜"라 파싱만으로는 걸러지지 않는다
        let ctaEnabled = carrier != nil && phoneValid && nameValid &&
            birthDate != nil && birthError == nil && gender != nil && agreed

        VStack(spacing: 0) {
            StatusBarSpacer()
            MoyeotaTopBar(title: "", onBack: onBack) {
                // 가입은 09 → 10 → 11 → 12 네 단계다 (05~08 부가 인증은 가입 경로에서 빠졌다)
                Text("1 / 4")
                    .moyeotaText(.BodySm, color: LabelGray)
            }
            IdentityVerifyProgressBar(progress: 1.0 / 4.0)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Spacer().frame(height: 24)
                    Text("휴대폰으로 본인 확인할게요")
                        .moyeotaText(.DisplayMd, color: MoyeotaColor.InkPrimary)
                    Spacer().frame(height: 10)
                    // 실명·성별은 가입 시 서버에 저장된다 — "저장하지 않아요"로 안내하면 사실과 다르다.
                    // 「매칭 안전을 위해서만」은 지웠다 — 성별은 매칭에 쓰이지 않는다(2026-10-13).
                    Text("실명은 본인 확인에만 쓰고 탑승 상대에게는 보이지 않아요")
                        .moyeotaText(MoyeotaType.BodySm.copy(fontSize: 14), color: MoyeotaColor.TextMute)
                    Spacer().frame(height: 26)

                    Text("통신사")
                        .moyeotaText(.BodySm, color: LabelGray)
                    Spacer().frame(height: 8)
                    HStack(spacing: 4) {
                        ForEach(Carriers, id: \.self) { candidate in
                            SignupChoiceChip(
                                text: candidate,
                                selected: carrier == candidate,
                                onClick: { carrier = candidate }
                            )
                        }
                    }
                    .frame(maxWidth: .infinity)

                    Spacer().frame(height: 24)
                    // value 는 원시 숫자만. 하이픈은 표시 변환이 그린다 — 표시 문자열을 value 로
                    // 넘기면 길이가 튀는 순간 커서가 옛 인덱스에 남아 입력 순서가 뒤집힌다(D-7).
                    MoyeotaTextField(
                        value: phoneDigits,
                        onValueChange: { phoneDigits = digitsOnly($0, maxDigits: 11) },
                        label: "휴대폰 번호",
                        placeholder: "010-1234-5678",
                        errorText: phoneError,
                        keyboardOptions: KeyboardOptions(keyboardType: .phone),
                        visualTransformation: PhoneNumberTransformation.visualTransformation,
                        enabled: !submitting
                    )

                    Spacer().frame(height: 20)
                    MoyeotaTextField(
                        value: name,
                        onValueChange: { name = takeUtf16($0, 20) },
                        label: "이름",
                        placeholder: "실명을 입력해 주세요",
                        errorText: nameError,
                        enabled: !submitting
                    )

                    Spacer().frame(height: 20)
                    MoyeotaTextField(
                        value: birthDigits,
                        onValueChange: { birthDigits = digitsOnly($0, maxDigits: 8) },
                        label: "생년월일",
                        placeholder: "2000-01-01",
                        errorText: birthError,
                        // 10 과 같은 안내 — 오류가 있으면 필드가 errorText 를 대신 띄운다
                        helperText: BirthDateHelperText,
                        keyboardOptions: KeyboardOptions(keyboardType: .number),
                        visualTransformation: BirthDateTransformation.visualTransformation,
                        enabled: !submitting
                    )

                    Spacer().frame(height: 20)
                    Text("성별")
                        .moyeotaText(.BodySm, color: LabelGray)
                    Spacer().frame(height: 8)
                    HStack(spacing: 8) {
                        SignupChoiceChip(
                            text: "남성",
                            selected: gender == .male,
                            onClick: { gender = .male }
                        )
                        SignupChoiceChip(
                            text: "여성",
                            selected: gender == .female,
                            onClick: { gender = .female }
                        )
                    }
                    .frame(maxWidth: .infinity)

                    Spacer().frame(height: 24)
                    // 제목이던 「성별은 동성 매칭에만 써요」는 지웠다 — 성별 조건 매칭이 없다.
                    // 백엔드 matching 패키지에 성별이 0건이고, user/profile 에 저장만 된다(2026-10-13).
                    Text("성별은 프로필에 표시되지 않아요")
                        .moyeotaText(MoyeotaType.BodySm.copy(fontWeight: .bold), color: MoyeotaColor.InkPrimary)
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(InfoCardBlue, in: RoundedRectangle(cornerRadius: 18, style: .circular))

                    Spacer().frame(height: 20)
                    HStack(alignment: .center, spacing: 0) {
                        IdentityAgreeCheckbox(checked: agreed, onToggle: { agreed.toggle() })
                        Spacer().frame(width: 10, height: 0)
                        Button {
                            agreed.toggle()
                        } label: {
                            Text("이용약관 · 개인정보 수집에 동의해요")
                                .moyeotaText(.BodySm, color: SlateGray)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PressFeedbackStyle())
                        // 미연결: 「보기」(약관) — 클릭해도 동작 없음 (약관 상세 필요)
                        Text("보기")
                            .moyeotaText(MoyeotaType.BodySm.copy(fontWeight: .bold), color: LabelGray)
                    }
                    .frame(maxWidth: .infinity)
                    Spacer().frame(height: 24)
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 0) {
                // 「인증 문자 받기」가 아니라 「다음」이다 — 백엔드에 본인인증(SMS) API 가 없어
                // 실제로 문자를 보내지 않고 곧장 10 으로 넘어간다. 보내지 않는 것을 보낸다고 쓰지 않는다.
                PrimaryCtaButton(
                    text: "다음",
                    onClick: {
                        guard let birth = birthDate, let genderValue = gender else { return }
                        submitting = true
                        // 서버에는 지금까지와 같이 하이픈이 든 형식으로 보낸다 — 표시용 포매터를 그대로 재사용
                        onRequestCode(
                            name.trim(),
                            PhoneNumberTransformation.format(phoneDigits),
                            birth,
                            genderValue
                        )
                    },
                    enabled: ctaEnabled,
                    loading: submitting
                )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            NavigationBarSpacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MoyeotaColor.SurfaceSoft)
        // 원본 `remember` 는 화면이 컴포지션에서 빠지면 사라진다. `@State` 는 스택에 있는 동안 남으므로 직접 비운다.
        .onDisappear {
            carrier = nil
            phoneDigits = ""
            name = ""
            birthDigits = ""
            gender = nil
            agreed = false
            submitting = false
        }
    }
}

extension IdentityVerifyScreen {
    /// 테스트가 CTA 를 누른 뒤의 상태를 만드는 입구. 창에 올린 화면이라도 코드로는 SwiftUI 버튼을 누를 수 없다.
    func seeded(submitting: Bool) -> Self {
        var copy = self
        copy._submitting = State(initialValue: submitting)
        return copy
    }
}

private struct IdentityAgreeCheckbox: View {
    let checked: Bool
    let onToggle: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .circular)
        Button(action: onToggle) {
            ZStack {
                if checked {
                    shape.fill(MoyeotaColor.Primary500)
                    Canvas { context, size in
                        let style = StrokeStyle(lineWidth: 2, lineCap: .round)
                        var head = Path()
                        head.move(to: CGPoint(x: size.width * 0.15, y: size.height * 0.55))
                        head.addLine(to: CGPoint(x: size.width * 0.4, y: size.height * 0.8))
                        context.stroke(head, with: .color(.white), style: style)
                        var tail = Path()
                        tail.move(to: CGPoint(x: size.width * 0.4, y: size.height * 0.8))
                        tail.addLine(to: CGPoint(x: size.width * 0.85, y: size.height * 0.25))
                        context.stroke(tail, with: .color(.white), style: style)
                    }
                    .frame(width: 14, height: 14)
                } else {
                    shape.fill(Color.white)
                    shape.strokeBorder(MoyeotaColor.Hairline, lineWidth: 1.5)
                }
            }
            .frame(width: 22, height: 22)
            .contentShape(shape)
        }
        .buttonStyle(PressFeedbackStyle())
    }
}

private struct IdentityVerifyProgressBar: View {
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
