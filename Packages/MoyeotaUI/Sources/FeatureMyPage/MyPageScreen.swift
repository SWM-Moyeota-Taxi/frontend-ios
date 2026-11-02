import MoyeotaDesignSystem
import PresentationCore
import SwiftUI

// 와이어프레임 그레이 (core token 미정의 색 — 화면 재현용)
private let CanvasBg = Color(argb: 0xFFF5F7FA)
private let GrayMute = Color(argb: 0xFF8A93A0)
private let GrayAsh = Color(argb: 0xFF9AA1AC)
private let SoftDivider = Color(argb: 0xFFE4E9F0)
private let CardShadow = Color(argb: 0x0F1B2A4A)

/// 35 · 마이페이지 · 설정 [S24]
///
/// 진입: 하단탭 마이페이지
///
/// 구성: 프로필 카드 → 「설정」 카드 → 「안내」 카드 → 「계정」 카드 → 버전 → (디버그) 개발자 옵션
///
/// ```
/// 프로필 카드 (사진 · 이름 / 닉네임·사진 바꾸기)  ›
/// [탑승]  지난 탑승 기록                       ›   ← 2026-11-01 추가
/// [설정]  알림 설정                          ↗
/// [안내]  개인정보 처리방침 / 이용약관 / 문의하기   ↗   ← 한 카드, 구분선
/// [계정]  로그아웃 / 탈퇴하기(빨강)            ›   ← 한 카드, 구분선
///         탈퇴하면 계정과 저장한 정보가 사라지고…
///                      v1.0                      ← 가운데
/// (디버그) 개발자 옵션
/// ```
///
/// 이동(디스크립션):
/// - 하단탭 홈 / 합승 / 채팅 → 14 / 17 / 24 (onTabSelect)
/// - 프로필 카드 → 36 프로필 수정 (onEditProfile)
/// - 「지난 탑승 기록」 → 34 지난 탑승 기록 (onRideHistory)
/// - 「알림 설정」 → OS 앱 알림 설정 (앱 밖)
/// - 「개인정보 처리방침」 · 「이용약관」 → 브라우저 (앱 밖)
/// - 「문의하기」 → 메일 앱, 제목·환경 정보 자동 입력 (앱 밖)
/// - 「로그아웃」 → 확인 다이얼로그 후 04a 로그인 (onLogout)
/// - 「탈퇴하기」 → 37 회원 탈퇴 (onDeleteAccount)
///
/// ### 2026-10-14 재구성 — 무엇을 바꿨고 왜인가
/// 1. **「안내」 카드가 생겼다.** 약관·개인정보 주소가 없어 숨어 있던 행이 주소가 생겨 드러났다
///    (`SupportLinks`). 스토어 심사는 **앱 안에서 개인정보 처리방침에 닿는 경로**를 본다.
/// 2. **로그아웃이 카드 행이 됐다.** 그전엔 13sp 회색 글자 한 줄이어서, 탈퇴(번듯한 카드 행)보다
///    작았다 — 훨씬 자주 쓰는 기능이 더 작아 위계가 뒤집혀 있었다. 이제 탈퇴와 같은 56pt 행이고
///    **같은 「계정」 카드 안에** 나란히 있다. 둘을 가르는 것은 크기가 아니라 색(탈퇴만 빨강)과
///    확인 단계다: 로그아웃은 확인 다이얼로그, 탈퇴는 37 에서 비밀번호 + 또 한 번의 다이얼로그.
///    (그전의 오탭 보호는 40pt 간격이었는데, 간격으로 떼어 놓으려면 로그아웃을 작게 둬야 했다.)
/// 3. **버전은 맨 아래 가운데로.** 로그아웃 줄 오른쪽에 있던 값이라, 로그아웃이 카드로 들어가면서
///    같이 들어가면 행 안에 뜻이 다른 두 정보가 섞인다.
///
/// 상태(디스크립션):
/// - **없는 기능은 행을 만들지 않는다.** 고객센터는 서버 API 가 없어 빠져 있고
///   (`docs/BACKEND-GAP-CLEANUP.md`), 매너 점수 · 마일리지 · 결제 수단도 같은 이유로 없다.
///   **「지난 탑승 기록」만 2026-11-01 에 들어왔다** — 서버에 `GET /api/v1/users/me/parties` 가
///   생겨 「없다」가 더 이상 사실이 아니게 됐다(`docs/BACKEND-GAP-CLEANUP.md` §6).
///   레퍼런스에 있는 「로그인 수단 안내」도 두지 않았다 — 지금 이 화면이 아는 서버 값은 이름과
///   프로필 사진뿐이고, 로그인 수단은 추측해서 적을 값이 아니다.
/// - 「안내」 행은 `links` 의 주소가 nil 이면 그리지 않고, 셋 다 nil 이면 **카드와 머리말까지**
///   사라진다(`myPageGroups` 가 판정하고 `MyPageMenuRulesTest` 가 고정한다).
/// - 앱 안에 알림 토글을 두지 않는 이유는 `openAppNotificationSettings` 의 설명과 같다
///   (서버에 알림 설정 저장 API 가 없어 앱만의 토글은 지키지 못할 약속이 된다).
/// - 이름과 프로필 사진이 서버 값이다(GET /local/users/info — 이름은 닉네임, 없으면 실명).
///   둘 다 한 번의 조회에서 함께 오고, **조회 전에는 둘 다 자리만 비워 둔다**(스켈레톤·빈 원).
///   사진을 고른 적 없는 사용자에게도 서버는 기본 이미지 주소를 주므로, 로딩 중에 그리면
///   기본 이미지가 한 번 스쳐 보인다. 사진은 36 에서 서버가 주는 16장 중에 고른다.
/// - 하단 버전 표기는 설치된 앱의 표시 버전이다(읽기 실패 시 숨김).
/// - 개발자 옵션(동승/택시 모드 강제)은 `modeDebug` 가 있을 때만, 즉 디버그 빌드에서만 그린다.
public struct MyPageScreen: View {
    // 로그인 사용자의 표시 이름(닉네임)과 프로필 사진 주소. 조회 전에는 loading(이름·사진 자리를 비움),
    // 서버에 이름이 없으면 resolved(nil). 사진을 따로 받지 않는 이유는 아바타 호출부 주석에 적어 뒀다.
    private let userName: UserNameState
    private let onEditProfile: () -> Void          // → 36 프로필 수정
    private let onRideHistory: () -> Void          // → 34 지난 탑승 기록
    private let onLogout: () -> Void               // → 04a 로그인 (세션 정리 후)
    private let onDeleteAccount: () -> Void        // → 37 회원 탈퇴
    private let onTabSelect: (MoyeotaTab) -> Void  // → 14 / 17 / 24
    private let modeDebug: ModeDebugOptions?       // 디버그 빌드 전용 개발자 옵션. 릴리스는 nil
    // 「안내」 카드가 여는 주소. 기본값은 운영 값이고, 테스트가 빈 상태를 넣어 본다.
    private let links: SupportLinkTargets

    // 오탭 한 번으로 세션이 날아가지 않도록 확인을 한 단계 둔다 (와이어프레임의 확인 다이얼로그)
    @State private var logoutConfirming = false

    public init(
        userName: UserNameState = .loading,
        onEditProfile: @escaping () -> Void = {},
        onRideHistory: @escaping () -> Void = {},
        onLogout: @escaping () -> Void = {},
        onDeleteAccount: @escaping () -> Void = {},
        onTabSelect: @escaping (MoyeotaTab) -> Void = { _ in },
        modeDebug: ModeDebugOptions? = nil,
        links: SupportLinkTargets = SupportLinkTargets()
    ) {
        self.userName = userName
        self.onEditProfile = onEditProfile
        self.onRideHistory = onRideHistory
        self.onLogout = onLogout
        self.onDeleteAccount = onDeleteAccount
        self.onTabSelect = onTabSelect
        self.modeDebug = modeDebug
        self.links = links
    }

    // 화면은 「무엇을 누르면 어디로 간다」만 안다. 앱 밖 이동은 ExternalIntents 가 맡는다.
    // switch 가 빠짐없이 갈라야 하므로, 행 종류가 늘면 여기서 컴파일이 막힌다.
    private func onAction(_ action: MyPageAction) {
        switch action {
        case .notificationSettings: openAppNotificationSettings()
        case .openWeb(let url): openWebPage(url: url)
        case .sendMail(let address): openSupportEmail(address: address)
        case .rideHistory: onRideHistory()
        case .logout: logoutConfirming = true
        case .deleteAccount: onDeleteAccount()
        }
    }

    public var body: some View {
        let versionLabel = appVersionName().map { "v\($0)" }
        let groups = myPageGroups(links: links)

        ZStack {
            VStack(spacing: 0) {
                StatusBarSpacer()

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        Spacer().frame(height: 16)
                        Text("마이페이지")
                            .moyeotaText(
                                MaterialTextStyle.bodyLarge(fontSize: 20, fontWeight: .bold),
                                color: MoyeotaColor.InkPrimary
                            )
                            .padding(.horizontal, 16)

                        Spacer().frame(height: 17)
                        profileCard

                        Spacer().frame(height: 24)
                        // 머리말 + 흰 카드 + 구분선으로 나뉜 행들. 같은 그룹의 행은 한 카드 안에 묶는다
                        // — 카드가 그룹의 경계고, 그래서 머리말이 무엇에 걸리는 말인지가 눈에 보인다.
                        ForEach(groups, id: \.label) { group in
                            MyPageMenuCard(group: group, onAction: onAction)
                        }

                        // 버전은 맨 아래 가운데. 사용자가 찾는 값이 아니라 **물어볼 때 읽어 주는** 값이라
                        // 눈에 걸리지 않는 자리에 둔다(문의 메일에도 같은 값이 자동으로 들어간다).
                        if let versionLabel {
                            Text(versionLabel)
                                .moyeotaText(MaterialTextStyle.bodyLarge(fontSize: 11), color: GrayAsh)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                                .padding(.horizontal, 16)
                        }

                        if let modeDebug {
                            Spacer().frame(height: 32)
                            ModeDebugSection(options: modeDebug)
                        }

                        Spacer().frame(height: 24)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // 원본 `rememberScrollState` 는 저장 상태라 탭을 다녀와도 읽던 자리가 남는다
                    .savedScrollOffset("mypage.scroll")
                }
                .scrollBounceBehavior(.basedOnSize)
                // 원본 `verticalScroll` 은 자기 칸에서 잘린다. SwiftUI `ScrollView` 는 안전 영역까지 그려 내용이 상태바에 겹친다.
                .clipped()

                // 하단탭 홈 / 합승 / 채팅 → 14 / 17 / 24
                MoyeotaBottomBar(selected: .mypage, onSelect: onTabSelect)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(CanvasBg)

            if logoutConfirming {
                MaterialAlertDialog(
                    onDismissRequest: { logoutConfirming = false },
                    title: {
                        Text("로그아웃할까요?")
                            .moyeotaText(
                                MaterialTextStyle.headlineSmall(fontSize: 17, fontWeight: .bold),
                                color: MoyeotaColor.InkPrimary
                            )
                    },
                    text: {
                        Text("다시 이용하려면 아이디로 로그인해야 해요")
                            .moyeotaText(MaterialTextStyle.bodyMedium(), color: MoyeotaColor.TextMute)
                    },
                    confirmButton: {
                        MaterialTextButton(
                            text: "로그아웃",
                            style: MaterialTextStyle.labelLarge(fontWeight: .bold),
                            color: MoyeotaColor.Danger500
                        ) {
                            logoutConfirming = false
                            onLogout()
                        }
                    },
                    dismissButton: {
                        MaterialTextButton(text: "취소", color: GrayMute) {
                            logoutConfirming = false
                        }
                    }
                )
            }
        }
        // 원본 `remember` 는 화면이 컴포지션에서 빠지면 사라진다. `@State` 는 스택에 있는 동안 남으므로 직접 비운다.
        .onDisappear { logoutConfirming = false }
    }

    // 프로필 카드 → 36 프로필 수정. 꺾쇠는 "눌러서 갈 곳이 있다"는 표시다
    // — 갈 화면이 없던 동안에는 일부러 꺾쇠도 탭 동작도 두지 않았다.
    private var profileCard: some View {
        Button(action: onEditProfile) {
            HStack(spacing: 0) {
                // 아바타의 인증 체크 배지는 두지 않는다 — 서버가 학교·재직 인증 여부를 주지 않는
                // 지금은 체크 표시 자체가 거짓 신호다.
                //
                // 사진 주소를 따로 받지 않고 `userName` 에서 꺼낸다 — 이름과 사진은 같은 한 번의
                // 조회(GET /local/users/info)에서 함께 오는 값이라, 파라미터를 하나 더 두면
                // "이름은 왔는데 사진은 아직"이라는 있을 수 없는 조합이 타입으로 표현돼 버린다.
                //
                // loading 이면 nil 이고, 그래서 **로딩 중에는 요청조차 만들지 않는다.**
                // 바로 아래 이름이 스켈레톤인 것과 같은 이유다 — 서버는 고른 적 없는 사용자에게도
                // 기본 이미지 주소를 주므로, 로딩 중에 그리면 기본 이미지가 한 번 스쳐 보인다.
                //
                // label 은 비워 둔다. 이니셜을 깔면 사진 로드에 실패했을 때 옆 18pt 이름과 같은 글자가
                // 두 번 보인다 — 여기는 이름이 바로 옆에 있는 자리라 이니셜이 주는 정보가 없다.
                AvatarCircle(size: 56, imageUrl: resolvedImageUrl)
                Spacer().frame(width: 14, height: 14)
                VStack(alignment: .leading, spacing: 0) {
                    switch userName {
                    // 조회 전 — 폴백 문구가 스쳐 보이지 않게 자리만 잡아 둔다
                    case .loading:
                        SoftDivider
                            .frame(width: 88, height: 18)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .circular))
                    case .resolved(let name, _):
                        Text(name ?? "이름 미설정")
                            .moyeotaText(
                                MaterialTextStyle.bodyLarge(fontSize: 18, fontWeight: .bold),
                                color: name != nil ? MoyeotaColor.InkPrimary : GrayMute
                            )
                    }
                    Spacer().frame(height: 4)
                    // 36 에서 바꿀 수 있는 것을 **빠짐없이 적는다.** 사진을 고를 수 있게 되면서
                    // 「닉네임 바꾸기」는 거짓이 됐지만, 그렇다고 「프로필 수정」으로 넓히지는 않았다
                    // — 실명·생년월일·성별·휴대폰·이메일은 서버에 수정 경로가 아예 없어서
                    // 「프로필 수정」을 보고 전화번호를 바꾸려 들어온 사람은 헛걸음을 한다.
                    // 바꿀 수 있는 둘을 그대로 적는 쪽이 들어가기 전에 알려 준다.
                    // (36 의 상단바 제목은 「프로필 수정」이다 — 그쪽은 들어온 뒤에 보는 글이라
                    //  무엇을 바꿀 수 있는지는 화면 안의 입력칸이 이미 말하고 있다.)
                    // 세 번째 값이 수정 가능해지면 이 라벨은 더 못 늘어난다. 그때가 「프로필 수정」
                    // 으로 넓힐 자리다.
                    Text("닉네임·사진 바꾸기")
                        .moyeotaText(MaterialTextStyle.bodyLarge(fontSize: 12, fontWeight: .medium), color: GrayMute)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ChevronRightIcon()
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
            .frame(height: 104)
            .background(MoyeotaColor.SurfaceCanvas)
        }
        .buttonStyle(PressOverlayStyle(shape: Rectangle()))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .circular))
        .moyeotaShadow(elevation: 4, shape: RoundedRectangle(cornerRadius: 18, style: .circular), spotColor: CardShadow)
        .padding(.horizontal, 16)
    }

    private var resolvedImageUrl: String? {
        if case .resolved(_, let imageUrl) = userName { imageUrl } else { nil }
    }
}

/// 머리말 + 카드 + (있으면) 카드 아래 한 줄.
///
/// 행마다 아이콘을 두지 않는다 — 이 앱에는 아이콘 자산이 없고, 글자 네 개짜리 목록에서 급조한
/// 아이콘은 구분이 아니라 장식이다. 대신 오른쪽 기호 두 개에만 뜻을 준다
/// (`MyPageRowMark`: ↗ = 앱 밖, › = 앱 안).
///
/// 빈 그룹은 `myPageGroups` 가 미리 걸러내므로 여기 오지 않는다. 그래도 방어로 한 줄 둔다
/// — 빈 카드는 "고장난 메뉴"로 보이고, 머리말만 남으면 더 이상하다.
private struct MyPageMenuCard: View {
    let group: MyPageGroup
    let onAction: (MyPageAction) -> Void

    var body: some View {
        if !group.rows.isEmpty {
            Text(group.label)
                .moyeotaText(MaterialTextStyle.bodyLarge(fontSize: 12, fontWeight: .bold), color: GrayAsh)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            VStack(spacing: 0) {
                ForEach(Array(group.rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 {
                        // 구분선은 글자 시작선에 맞춰 들여 둔다 — 카드 폭을 꽉 채우면 행이 카드에서 떨어져 보인다
                        SoftDivider
                            .frame(height: 1)
                            .padding(.horizontal, 20)
                    }
                    Button {
                        onAction(row.action)
                    } label: {
                        HStack(spacing: 0) {
                            Text(row.text)
                                .moyeotaText(
                                    MaterialTextStyle.bodyLarge(fontSize: 15, fontWeight: .medium),
                                    // 되돌릴 수 없는 행만 색이 다르다. 카드 안에서 유일한 빨강이라야 경고로 읽힌다.
                                    color: row.danger ? MoyeotaColor.Danger500 : MoyeotaColor.InkPrimary
                                )
                                .frame(maxWidth: .infinity, alignment: .leading)
                            switch row.mark {
                            case .external: ExternalLinkIcon()
                            case .chevron: ChevronRightIcon()
                            }
                        }
                        .padding(.horizontal, 20)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressOverlayStyle(shape: Rectangle()))
                }
            }
            .frame(maxWidth: .infinity)
            .background(MoyeotaColor.SurfaceCanvas)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .circular))
            .moyeotaShadow(elevation: 4, shape: RoundedRectangle(cornerRadius: 18, style: .circular), spotColor: CardShadow)
            .padding(.horizontal, 16)
            if let caption = group.caption {
                // 카드 **아래**에 둔다. 행 안에 넣으면 56pt 행이 두 줄로 늘어나 다른 행과 높이가 달라지고,
                // 카드 위에 두면 머리말과 붙어 무엇에 걸리는 말인지 흐려진다.
                Text(caption)
                    .moyeotaText(MaterialTextStyle.bodyLarge(fontSize: 11), color: GrayAsh)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
            }
            Spacer().frame(height: 24)
        }
    }
}

// 아이콘 라이브러리 없이 그리는 꺾쇠(›) — 앱 안에서 다음 화면으로 간다는 표시
private struct ChevronRightIcon: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            var path = Path()
            path.move(to: CGPoint(x: w * 0.38, y: h * 0.24))
            path.addLine(to: CGPoint(x: w * 0.66, y: h * 0.5))
            path.move(to: CGPoint(x: w * 0.38, y: h * 0.76))
            path.addLine(to: CGPoint(x: w * 0.66, y: h * 0.5))
            context.stroke(path, with: .color(GrayAsh), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
    }
}

/// 외부로 나간다는 표시(↗). 글꼴에 따라 빠질 수 있는 유니코드 화살표 대신 직접 그린다.
///
/// 같은 모듈의 37 회원 탈퇴도 이것을 쓴다(「자세히 보기」) — 기호의 뜻이 두 화면에서 어긋나면
/// 규칙 자체가 무의미해진다. 세 번째 화면이 쓰게 되면 `MoyeotaDesignSystem` 으로 올릴 자리다.
struct ExternalLinkIcon: View {
    private let tint: Color

    init(tint: Color = GrayAsh) {
        self.tint = tint
    }

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            var path = Path()
            // 대각선 ↗
            path.move(to: CGPoint(x: w * 0.22, y: h * 0.78))
            path.addLine(to: CGPoint(x: w * 0.78, y: h * 0.22))
            // 화살머리 두 변
            path.move(to: CGPoint(x: w * 0.42, y: h * 0.22))
            path.addLine(to: CGPoint(x: w * 0.78, y: h * 0.22))
            path.move(to: CGPoint(x: w * 0.78, y: h * 0.22))
            path.addLine(to: CGPoint(x: w * 0.78, y: h * 0.58))
            context.stroke(path, with: .color(tint), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }
}

/// 디버그 빌드 전용 개발자 옵션 — 서버 모드와 무관하게 동승/택시 화면을 강제한다.
///
/// 택시 화면(25·26)은 서버가 배차 status 를 줘야 열리므로, 동승 서버에 택시를 강제해도 21 의 문구·버튼만
/// 바뀐다. 25·26 까지 보려면 `TAXI_ENABLED=true` 로 띄운 로컬 서버가 필요하다(docs/MODE-ROUTES.md).
public struct ModeDebugOptions {
    /// 서버가 준 값(강제 미적용).
    public var serverTaxiEnabled: Bool
    /// 서버 응답을 받았는가. false 면 서버 값은 아직 기본값이다.
    public var serverResolved: Bool
    /// 강제값. nil 이면 서버 값을 따른다.
    public var override: Bool?
    public var onOverride: (Bool?) -> Void

    public init(
        serverTaxiEnabled: Bool,
        serverResolved: Bool,
        override: Bool?,
        onOverride: @escaping (Bool?) -> Void
    ) {
        self.serverTaxiEnabled = serverTaxiEnabled
        self.serverResolved = serverResolved
        self.override = override
        self.onOverride = onOverride
    }
}

private struct ModeDebugSection: View {
    let options: ModeDebugOptions

    var body: some View {
        let serverLabel = if !options.serverResolved {
            "미수신 (기본값 동승)"
        } else if options.serverTaxiEnabled {
            "택시"
        } else {
            "동승"
        }
        VStack(alignment: .leading, spacing: 0) {
            Text("개발자 옵션 · 디버그 빌드에만 보여요")
                .moyeotaText(MaterialTextStyle.bodyLarge(fontSize: 11, fontWeight: .medium), color: GrayAsh)
            Spacer().frame(height: 8)
            Text("서버 모드: \(serverLabel)")
                .moyeotaText(
                    MaterialTextStyle.bodyLarge(fontSize: 13, fontWeight: .medium),
                    color: MoyeotaColor.InkPrimary
                )
            Spacer().frame(height: 8)
            HStack(spacing: 8) {
                ModeChip(text: "서버 값", selected: options.override == nil) { options.onOverride(nil) }
                ModeChip(text: "동승 강제", selected: options.override == false) { options.onOverride(false) }
                ModeChip(text: "택시 강제", selected: options.override == true) { options.onOverride(true) }
            }
            Spacer().frame(height: 6)
            Text("강제값은 앱을 완전히 종료하면 풀려요. 25 배차·26 운행 화면은 택시 모드 서버가 있어야 열려요.")
                .moyeotaText(MaterialTextStyle.bodyLarge(fontSize: 11), color: GrayAsh)
        }
        .padding(.horizontal, 16)
    }
}

private struct ModeChip: View {
    let text: String
    let selected: Bool
    let onClick: () -> Void

    var body: some View {
        Button(action: onClick) {
            Text(text)
                .moyeotaText(
                    MaterialTextStyle.bodyLarge(fontSize: 12, fontWeight: .bold),
                    color: selected ? .white : GrayMute
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(selected ? MoyeotaColor.Primary500 : MoyeotaColor.SurfaceCanvas, in: Capsule(style: .circular))
        }
        .buttonStyle(PressOverlayStyle(shape: Capsule(style: .circular)))
    }
}

extension MyPageScreen {
    /// 테스트가 확인창이 열린 상태를 만드는 입구. 창에 올린 화면이라도 코드로는 SwiftUI 버튼을 누를 수 없다.
    func seeded(logoutConfirming: Bool) -> Self {
        var copy = self
        copy._logoutConfirming = State(initialValue: logoutConfirming)
        return copy
    }
}
