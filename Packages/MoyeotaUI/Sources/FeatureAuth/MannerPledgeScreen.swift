import MoyeotaDesignSystem
import PresentationCore
import SwiftUI

/// 12 · 매너 서약 [S07]
///
/// 진입: 10 프로필 만들기 / 뒤로 → 10 / 「동의하고 가입 완료」 → 13 가입 완료
/// 개별 항목 탭 → 해당 정책 상세 (미연결)
///
/// **가입 플로우의 유일한 서버 제출 지점**이다 — `onComplete` 가 회원가입 + 자동 로그인을
/// 실행하고, 성공했을 때만 호출부가 13 으로 넘긴다. 그래서 진행 상태와 실패 사유를
/// 화면이 직접 만들지 않고 `submitting` · `errorMessage` 로 받는다
/// (예전엔 500ms 딜레이 후 무조건 다음 화면으로 넘어갔다).
public struct MannerPledgeScreen: View {
    private let onBack: () -> Void
    private let onComplete: () -> Void
    private let submitting: Bool
    private let errorMessage: String?
    private let onEditNickname: (() -> Void)?
    private let onReverifyPhone: (() -> Void)?

    // 전체 항목 동의 필수 → 하나라도 미체크면 CTA 비활성.
    // 개수를 `mannerPledgeItems` 에서 끌어온다 — 항목을 늘렸을 때 체크 배열이 짧아 터지는 일이 없도록.
    @State private var checks = Array(repeating: false, count: mannerPledgeItems.count)

    /// - Parameter onEditNickname: 닉네임 중복(409)처럼 **이 화면에서 고칠 수 없는** 실패일 때만 채워진다 —
    ///   배너 아래 「닉네임 바꾸기」 가 붙고, 누르면 10 프로필 만들기로 돌아간다.
    ///   nil 이면 배너만 뜬다(여기서 재시도하면 되는 실패).
    /// - Parameter onReverifyPhone: 가입이 `phoneNotVerified`(400 `USER207`) 로 거절됐을 때만 채워진다 — 문자 인증 토큰이
    ///   만료·소진됐거나 번호가 달라졌다는 뜻이고, 여기서 다시 눌러도 같은 400 이다.
    ///   누르면 10 으로 돌아가 인증 블록이 초기화된다.
    ///
    ///   `onEditNickname` 과 동시에 채워지는 일은 없다 — 서버가 토큰을 중복 검사보다 먼저 보므로
    ///   두 실패는 같은 요청에서 함께 오지 않는다.
    public init(
        onBack: @escaping () -> Void,
        onComplete: @escaping () -> Void,
        submitting: Bool = false,
        errorMessage: String? = nil,
        onEditNickname: (() -> Void)? = nil,
        onReverifyPhone: (() -> Void)? = nil
    ) {
        self.onBack = onBack
        self.onComplete = onComplete
        self.submitting = submitting
        self.errorMessage = errorMessage
        self.onEditNickname = onEditNickname
        self.onReverifyPhone = onReverifyPhone
    }

    public var body: some View {
        let allChecked = checks.allSatisfy { $0 }
        VStack(spacing: 0) {
            StatusBarSpacer()
            MoyeotaTopBar(title: "", onBack: onBack) {
                Text("2 / 2")
                    .moyeotaText(MoyeotaType.BodySm.copy(fontWeight: .medium), color: Color(argb: 0xFF8A93A0))
            }
            PledgeStepProgressBar(progress: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Spacer().frame(height: 24)
                    Text("마지막으로 약속 하나만")
                        .moyeotaText(MoyeotaType.DisplayMd.hangulTrimmed, color: MoyeotaColor.InkPrimary)
                    Spacer().frame(height: 10)
                    Text("모여타는 서로를 믿고 타는 서비스예요")
                        .moyeotaText(MoyeotaType.BodySm.copy(fontSize: 14).hangulTrimmed, color: MoyeotaColor.TextMute)

                    Spacer().frame(height: 24)
                    allAgreeRow(allChecked: allChecked)

                    Spacer().frame(height: 6)
                    Text("동의 내용은 가입 시점 기준으로 적용돼요")
                        .moyeotaText(MoyeotaType.CaptionMd.copy(fontWeight: .medium).hangulTrimmed, color: Color(argb: 0xFF9AA1AC))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    Spacer().frame(height: 6)

                    pledgeCard
                    Spacer().frame(height: 24)
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 0) {
                // 실패는 화면을 갈아엎지 않고 CTA 바로 위에 남긴다 — 다시 누를 곳이 아래 있기 때문
                if let errorMessage {
                    NoticeBanner(kind: .error, text: errorMessage)
                    // 10 으로 되돌려야 고칠 수 있는 실패에만 링크가 붙는다. 둘은 동시에 오지 않는다.
                    if let recovery {
                        Spacer().frame(height: 8)
                        Button(action: recovery.action) {
                            Text(recovery.label)
                                .moyeotaText(
                                    MoyeotaType.BodySm.copy(fontWeight: .bold).hangulTrimmed,
                                    color: MoyeotaColor.Primary500
                                )
                        }
                        .buttonStyle(NoIndicationButtonStyle())
                    }
                    Spacer().frame(height: 12)
                }
                PrimaryCtaButton(
                    text: "동의하고 가입 완료",
                    onClick: onComplete,
                    enabled: allChecked && !submitting,
                    loading: submitting
                )
            }
            .padding(.horizontal, 16)
            NavigationBarSpacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MoyeotaColor.SurfaceSoft)
        // 원본 `remember` 는 화면이 컴포지션에서 빠지면 사라진다. `@State` 는 스택에 있는 동안 남으므로 직접 비운다.
        .onDisappear { checks = Array(repeating: false, count: mannerPledgeItems.count) }
    }

    private var recovery: (label: String, action: () -> Void)? {
        if let onEditNickname { return ("닉네임 바꾸기", onEditNickname) }
        if let onReverifyPhone { return ("휴대폰 인증 다시 하기", onReverifyPhone) }
        return nil
    }

    // 「아래 내용에 모두 동의해요」 체크 시 하위 4개 일괄 on/off
    private func allAgreeRow(allChecked: Bool) -> some View {
        Button {
            let target = !allChecked
            for index in checks.indices { checks[index] = target }
        } label: {
            HStack(alignment: .center, spacing: 0) {
                PledgeCheckCircle(checked: allChecked, size: 26)
                Spacer().frame(width: 13, height: 0)
                Text("아래 내용에 모두 동의해요")
                    .moyeotaText(MoyeotaType.BodyMd.copy(fontWeight: .bold).hangulTrimmed, color: MoyeotaColor.Primary600)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 17)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MoyeotaColor.Primary50, in: RoundedRectangle(cornerRadius: 16, style: .circular))
        }
        .buttonStyle(NoIndicationButtonStyle())
    }

    private var pledgeCard: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .circular)
        return VStack(spacing: 0) {
            ForEach(Array(mannerPledgeItems.enumerated()), id: \.offset) { index, item in
                PledgeItemRow(
                    item: item,
                    checked: checks[index],
                    onToggle: { checks[index].toggle() }
                )
                if index != mannerPledgeItems.count - 1 {
                    HorizontalDivider(color: MoyeotaColor.Hairline)
                        .padding(.leading, 56)
                        .padding(.trailing, 20)
                }
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(MoyeotaColor.SurfaceCanvas, in: shape)
        .moyeotaShadow(elevation: 4, shape: shape, spotColor: Color(argb: 0x0F1B2A4A))
    }
}

/// 12 매너 서약의 동의 항목 하나.
///
/// `description` 이 옵셔널인 이유: **보조 설명이 약속이 되는 자리**라서다. 운영이 지킬 수단이
/// 없는 말을 적을 바에는 줄을 비우는 쪽이 맞다 — 아래 「불쾌한 말과 행동」 항목이 그 경우다.
struct PledgeItem: Equatable, Sendable {
    let title: String
    let description: String?

    init(_ title: String, _ description: String? = nil) {
        self.title = title
        self.description = description
    }
}

/// 동의 항목 — **전부 체크해야 가입 버튼이 열린다**(체크 배열 길이를 이 목록에서 끌어온다).
/// 즉 여기 한 줄을 넣는 것은 "이걸 동의하지 않으면 가입시키지 않겠다"는 뜻이다.
///
/// 2026-10-13 에 지운 것:
/// - 「불쾌한 말과 행동을 하지 않을게요」의 설명 **「신고가 들어오면 24시간 안에 확인해요」** —
///   앱에 신고 UI 가 없다. 사용자 신고·메시지 신고 API 를 앱이 부르지 않고(27 긴급 신고만
///   `POST /reports` 를 쓰는데 그것도 운행 중인 방의 승객만이고 동승 모드는 26 에 닿지 않는다),
///   받을 창구는 문의 메일뿐이다. **24시간을 지킬 수단이 없다.** 대체 문구를 새로 만들지 않고
///   줄을 비웠다 — 창구가 없는 상태에서 「확인해요」라고만 줄여도 없는 창구를 있다고 말하는 셈이다.
///   (2026-10-14: `SupportLinks.CONTACT_EMAIL` 이 채워져 35 「안내」 카드에 「문의하기」 행이
///   보이게 됐다. 메일 창구가 **생긴** 것이지 신고 UI 와 응답 시간이 생긴 것은 아니라, 이 줄은
///   여전히 비워 둔다.)
///
/// 2026-11-01 에 되살린 것 (`docs/BACKEND-GAP-CLEANUP.md` §6):
/// - 같은 항목의 설명을 **「채팅방에서 메시지를 길게 눌러 신고할 수 있어요」**로 다시 채웠다.
///   24 채팅방에 메시지 신고가 붙어(`POST /api/v1/chat-rooms/{id}/reports`, 실측 201) 창구가
///   생겼기 때문이다. **되살린 것은 「창구가 있다」는 사실 하나뿐이다** — 지운 문구의
///   「24시간 안에 확인해요」는 돌아오지 않았고 돌아올 수도 없다: 서버가 신고를 `chat_report` 에
///   저장하고 피신고자 인덱스를 거는 것까지가 코드가 보장하는 전부이고, 그 뒤에 사람이 언제
///   무엇을 하는지는 어느 코드도 약속하지 못한다. 처리 **시한**이나 **제재**를 적으면 2026-10-13
///   에 지운 거짓이 모양만 바꿔 돌아온다.
///   사용자가 할 일을 말하는 줄이라 「~할 수 있어요」로 적는다(「~해 주세요」는 요청일 때만).
/// - 항목 **「운행 중 내 위치를 동승자와 공유하는 데 동의해요」** — 위치 공유 기능이 아예 없고
///   (`docs/BACKEND-GAP-CLEANUP.md` §1 이 `reportMyLocation`·`getMemberLocations` 를 지웠다;
///   남은 위치 API 는 기사 위치 조회뿐이다) **그 동의도 서버에 저장되지 않았다**(저장 필드가 없어
///   전송하지 않았다). 없는 기능에 동의를 받아 버리고 있었다. 개인정보 처리방침의 「실시간 위치를
///   동승자에게 공유하는 기능이 현재 없습니다」와도 정면으로 어긋났다.
///
/// 남긴 「이용이 제한돼요」류는 운영이 약관으로 유보하는 조치라 기능 주장이 아니다 — 다만 백엔드에
/// 제재 수단이 아직 없어 운영자 판단 대상이다(산출물 보고서 참고).
let mannerPledgeItems = [
    // 09 본인 인증에 있던 「이용약관 · 개인정보 수집에 동의해요」 체크를 여기로 합쳤다.
    // 09 가 가입 경로에서 빠지기도 했지만, 그 전에도 동의를 두 화면이 나눠 받고 있었다
    // — 무엇에 동의했는지는 제출 버튼이 있는 이 화면에 모여 있어야 한다.
    PledgeItem("이용약관 · 개인정보 수집에 동의해요", "실명·생년월일·연락처는 본인 확인에만 써요"),
    PledgeItem("약속한 시간과 장소를 지킬게요", "무단 취소가 반복되면 이용이 제한돼요"),
    PledgeItem("불쾌한 말과 행동을 하지 않을게요", "채팅방에서 메시지를 길게 눌러 신고할 수 있어요"),
    PledgeItem("매칭이 확정되면 꼭 나갈게요", "매칭 확정 후 오지 않으면 이용이 제한될 수 있어요"),
]

private struct PledgeItemRow: View {
    let item: PledgeItem
    let checked: Bool
    let onToggle: () -> Void

    // 항목 텍스트 탭 → 해당 정책 상세 (미연결). 원본의 빈 `clickable` 은 눌림 표시도 동작도 없어 옮기지 않는다.
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Button(action: onToggle) {
                PledgeCheckCircle(checked: checked, size: 24)
            }
            .buttonStyle(NoIndicationButtonStyle())
            Spacer().frame(width: 12, height: 0)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.title)
                    .moyeotaText(MoyeotaType.BodyMd.copy(fontWeight: .bold).hangulTrimmed, color: MoyeotaColor.InkPrimary)
                // 설명이 없는 항목은 제목만 — 빈 줄을 띄우면 문구가 지워진 자리가 드러난다
                if let description = item.description {
                    Spacer().frame(height: 2)
                    Text(description)
                        .moyeotaText(MoyeotaType.CaptionMd.copy(fontWeight: .medium).hangulTrimmed, color: Color(argb: 0xFF8A93A0))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
    }
}

// 와이어프레임 모양 그대로의 원형 체크 (체크 시 Primary 채움 + 흰 체크표시)
private struct PledgeCheckCircle: View {
    let checked: Bool
    let size: CGFloat

    var body: some View {
        ZStack {
            if checked {
                Circle().fill(MoyeotaColor.Primary500)
                Canvas { context, canvasSize in
                    let w = canvasSize.width
                    let h = canvasSize.height
                    var path = Path()
                    path.move(to: CGPoint(x: w * 0.08, y: h * 0.55))
                    path.addLine(to: CGPoint(x: w * 0.38, y: h * 0.85))
                    var tail = Path()
                    tail.move(to: CGPoint(x: w * 0.38, y: h * 0.85))
                    tail.addLine(to: CGPoint(x: w * 0.92, y: h * 0.18))
                    let style = StrokeStyle(lineWidth: 2, lineCap: .round)
                    context.stroke(path, with: .color(.white), style: style)
                    context.stroke(tail, with: .color(.white), style: style)
                }
                .frame(width: size / 2, height: size / 2)
            } else {
                Circle().fill(MoyeotaColor.SurfaceCanvas)
                Circle().strokeBorder(Color(argb: 0xFFD1D5DB), lineWidth: 1.5)
            }
        }
        .frame(width: size, height: size)
    }
}

private struct PledgeStepProgressBar: View {
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
