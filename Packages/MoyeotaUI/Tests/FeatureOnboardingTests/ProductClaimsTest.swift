import Foundation
import MoyeotaDomain
import Testing
@testable import FeatureOnboarding

/// 가입 전에 사용자가 읽는 문구(01~03 온보딩 · 04 시작 · 12 매너 서약)가 **없는 기능을 약속하지
/// 않는지** 못 박는다.
///
/// 문구를 테스트하는 게 과해 보일 수 있지만 여기서는 **문구가 고지**다(37 탈퇴 경고를
/// `AccountDeleteRulesTest` 가 못 박는 것과 같은 이유). 기능은 지웠는데 그걸 자랑하던 문구만 남는
/// 사고가 실제로 일어났고(2026-10-13, `_workspace/127_compose-builder_false-claims.md`),
/// 그때 지운 주장이 다시 들어오는 것을 막는 것이 이 테스트의 유일한 목적이다.
///
/// **금지어를 늘릴 때는 그 기능이 없다는 근거를 코드에서 확인하고 추가한다.** 기능이 생기면
/// 이 테스트에서 먼저 빼라 — 테스트가 사실보다 오래 남으면 그게 또 거짓이 된다.
///
/// 04·12 문구(`LoginTrustBullets`·`mannerPledgeItems`)는 `FeatureAuth` 에 있어 import 할 수 없고
/// `AuthCopySource` 가 소스에서 읽는다. 상수가 아직 포팅되지 않았으면 건너뛰지 않고 **원본 문구**
/// (`OriginalAuthCopy`)로 원본과 같은 13개 검사를 모두 돌린다 — 금지어 테스트가 서약 문구 없이 통과하면
/// 원본이 보던 것을 보지 않는 셈이다. 다만 그것은 실제 상수를 검사한 것이 아니므로, 미포팅 상태는
/// 아래 `pledgeConstantMatchesOriginal` 이 알려진 문제(known issue)로 결과 줄에 남긴다.
/// 상수가 생기면 자동으로 실제 상수를 본다.
struct ProductClaimsTest {
    private let onboardingPages = [
        OnboardingSavingCopy,
        OnboardingTrustCopy,
        OnboardingMeetingCopy,
    ]

    /// 읽지 못했으면 테스트를 실패시킨다 — 검사가 조용히 사라지면 안 된다.
    private func value<V>(
        _ lookup: AuthCopySource.Lookup<V>,
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> V? {
        switch lookup {
        case .found(let value):
            return value
        case .notPorted:
            return nil
        case .unreadable(let reason):
            Issue.record("FeatureAuth 문구를 읽지 못했다: \(reason)", sourceLocation: sourceLocation)
            return nil
        }
    }

    /// 실제 상수. 미포팅이면 원본 문구다(읽기 실패는 `value` 가 이미 테스트를 실패시켰다).
    private func bullets(sourceLocation: SourceLocation = #_sourceLocation) -> [String] {
        value(AuthCopySource.bullets, sourceLocation: sourceLocation) ?? OriginalAuthCopy.bullets
    }

    private func pledges(sourceLocation: SourceLocation = #_sourceLocation) -> [AuthCopySource.Pledge] {
        value(AuthCopySource.pledges, sourceLocation: sourceLocation) ?? OriginalAuthCopy.pledges
    }

    /// 가입 전에 읽히는 모든 문구를 한 덩어리로 본다 — 어느 화면에 섞여 들어와도 걸린다.
    private func preSignupCopy(sourceLocation: SourceLocation = #_sourceLocation) -> String {
        let parts: [String] = onboardingPages.flatMap { [$0.headline, $0.body] }
            + bullets(sourceLocation: sourceLocation)
            + pledges(sourceLocation: sourceLocation).flatMap(\.copyParts)
        return parts.joined(separator: " ")
    }

    // ─────────────────────────── 없는 기능 ───────────────────────────

    /// **성별 조건 매칭은 없다.** 성별은 가입 때 받아 서버 `UserProfile` 에 저장될 뿐이고, 백엔드
    /// `matching` 패키지에 성별이 한 번도 등장하지 않는다(`grep -i gender` 로 확인: user/local ·
    /// user/profile · user/users/domain/enums 에만 있다). 앱 쪽도 `Gender` 가 가입 요청
    /// (`AuthMappers`·`AuthDtos`)에만 쓰이고 파티 DTO 에는 성별 필드가 아예 없다.
    ///
    /// 성별 **입력란은 지우지 않는다** — 서버 가입 API 가 필수로 받는다. 여기서 막는 것은 성별이
    /// 매칭에 쓰인다고 **말하는** 것뿐이다.
    @Test("가입 전 문구는 성별로 매칭한다고 말하지 않는다")
    func noGenderMatchingClaim() {
        let copy = preSignupCopy()
        for forbidden in ForbiddenClaims.genderMatching {
            #expect(!copy.contains(forbidden), "없는 성별 조건 매칭을 약속한다: \(forbidden)")
        }
    }

    /// **위치 공유 기능이 없다.** `docs/BACKEND-GAP-CLEANUP.md` §1 이 `RideRepository`의
    /// `reportMyLocation`·`getMemberLocations` 와 보호자 공유 카드를 모두 지웠다. 지금 도메인에
    /// 남은 위치 조회는 `DispatchRepository.getDriverLocation`(기사 위치, 택시 모드) 하나다.
    ///
    /// 12 매너 서약의 「운행 중 내 위치를 동승자와 공유하는 데 동의해요」 항목도 같은 이유로 지웠다 —
    /// 없는 기능에 동의를 받고 그 동의마저 서버에 보내지 않고 있었다.
    @Test("가입 전 문구는 위치 공유를 약속하지 않는다")
    func noLocationSharingClaim() {
        let copy = preSignupCopy()
        for forbidden in ForbiddenClaims.locationSharing {
            #expect(!copy.contains(forbidden), "없는 위치 공유를 약속한다: \(forbidden)")
        }
    }

    /// **평가·매너 점수가 없다.** 평가 API 자체가 서버에 없어 `User.rating` 은 항상 0.0 이다
    /// (`User` KDoc). 상대에 대해 실제로 보이는 것은 닉네임과 탑승 횟수뿐이다.
    @Test("가입 전 문구는 평가나 매너 점수를 약속하지 않는다")
    func noRatingClaim() {
        let copy = preSignupCopy()
        for forbidden in ForbiddenClaims.rating {
            #expect(!copy.contains(forbidden), "없는 평가 기능을 약속한다: \(forbidden)")
        }
    }

    /// **결제·정산이 없다.** 28~32 결제 화면 5개가 삭제됐고 요금 확정·결제·영수증 API 가 전무하다.
    /// 앱이 보여 줄 수 있는 것은 「예상 요금 / 정원」이라는 **추정치**뿐이다.
    ///
    /// 01 의 「요금이 1/N로 줄어요」는 그 추정치를 말하는 것이라 통과해야 한다 — 금지하는 것은
    /// 앱이 정산해 준다는 주장이다.
    @Test("가입 전 문구는 앱이 정산해 준다고 말하지 않는다")
    func noSettlementClaim() {
        let copy = preSignupCopy()
        for forbidden in ForbiddenClaims.settlement {
            #expect(!copy.contains(forbidden), "없는 결제·정산을 약속한다: \(forbidden)")
        }
    }

    /// **동승 모드는 26 운행 중에 닿지 않아 27 긴급 신고로 들어갈 길이 없다**(`docs/MODE-ROUTES.md`).
    /// 서버도 `POST /reports` 를 `isRidingMember` 가 아니면 403 `REPORT_NOT_ALLOWED` 로 막는다
    /// (`ReportService.report`).
    ///
    /// **메시지 신고는 2026-11-01 에 생겼다**(24 채팅방 롱프레스 →
    /// `POST /api/v1/chat-rooms/{id}/reports`, `ChatRepository.reportMessage`). 그래서 매너 서약은
    /// 「신고할 수 있어요」를 말해도 된다 — 여기서 계속 막는 것은 **112 로 이어지는 긴급 신고**와
    /// 「신고가 바로 ~된다」는 **즉시성 주장**뿐이다. 둘은 여전히 가입 전 화면에서 닿을 수 없다.
    @Test("가입 전 문구는 긴급 신고를 약속하지 않는다")
    func noEmergencyReportClaim() {
        let copy = preSignupCopy()
        for forbidden in ForbiddenClaims.emergencyReport {
            #expect(!copy.contains(forbidden), "닿을 수 없는 화면의 기능을 약속한다: \(forbidden)")
        }
    }

    // ─────────────────────────── 지킬 수 없는 약속 ───────────────────────────

    /// 운영이 **몇 시간 안에 무엇을 하겠다**고 약속하지 않는다.
    ///
    /// 창구가 없어서가 아니다 — `SupportLinks.CONTACT_EMAIL` 은 채워져 있어 35 「안내」 카드에
    /// 「문의하기」 행이 보이고, 채팅 메시지 신고도 붙었다. 없는 것은 **시한을 지킬 사람**이다.
    /// 받을 곳이 생겼다고 「몇 시간 안에」를 쓰면 그때부터 어기는 약속이 된다.
    ///
    /// 기술적으로 즉시인 것(SSE 반영 등)은 이 금지의 대상이 아니다. 여기서 보는 문구에는 그런 말이 없다.
    @Test("가입 전 문구는 운영 대응 시한을 약속하지 않는다")
    func noResponseDeadlineClaim() {
        let copy = preSignupCopy()
        for forbidden in ForbiddenClaims.responseDeadline {
            #expect(!copy.contains(forbidden), "지킬 수단이 없는 시한을 약속한다: \(forbidden)")
        }
    }

    // ─────────────────────────── 남아야 하는 사실 ───────────────────────────

    /// 거짓을 지운 자리를 빈 채로 두지 않는다. 온보딩 세 장은 **코드로 확인한 네 가지**를 말해야 한다.
    /// 하나라도 빠지면 가입 전에 서비스가 무엇을 해 주는지 알 수 없는 화면이 된다.
    @Test("온보딩은 실제로 참인 것을 말한다")
    func onboardingStatesVerifiedFacts() {
        let all = onboardingPages.map { $0.headline + " " + $0.body }.joined(separator: " ")

        // 1인 부담 = 예상 요금 / 정원 (Ride.farePerPerson)
        #expect(all.contains("1/N"), "\(all)")
        // 서버가 USER207 PHONE_NOT_VERIFIED 로 가입을 막는다
        #expect(all.contains("휴대폰 인증"), "\(all)")
        // ChatRoomMatchingListener.on(PartyMemberJoinedEvent) — 합류 즉시 방이 열린다
        #expect(all.contains("채팅방이 열려요"), "\(all)")
        // PartyDetailResult.MemberInfo.rideCount
        #expect(all.contains("탑승 횟수"), "\(all)")
    }

    @Test("온보딩 세 장이 모두 헤드라인과 본문을 갖는다")
    func everyOnboardingPageHasCopy() {
        #expect(onboardingPages.count == 3)
        for page in onboardingPages {
            #expect(!page.headline.isBlank, "빈 헤드라인: \(page)")
            #expect(!page.body.isBlank, "빈 본문: \(page)")
        }
    }

    /// 04 시작의 신뢰 불릿은 **두 줄**이다 — 카드 여백이 두 줄 기준으로 맞춰져 있다.
    @Test("시작 화면 신뢰 불릿은 두 줄이고 비어 있지 않다")
    func loginTrustBulletsAreTwoLines() {
        let bullets = bullets()

        #expect(bullets.count == 2)
        for bullet in bullets {
            #expect(!bullet.isBlank, "빈 불릿")
        }
    }

    // ─────────────────────────── 12 매너 서약 ───────────────────────────

    /// 동의 항목은 **전부 체크해야 가입 버튼이 열린다.** 즉 항목을 하나 넣는 것은 "이걸 동의하지
    /// 않으면 가입시키지 않겠다"는 뜻이라, 없는 기능에 대한 동의를 넣으면 사용자가 존재하지 않는
    /// 것에 동의해야 가입할 수 있게 된다.
    @Test("매너 서약 항목은 전부 제목이 있고 네 개다")
    func mannerPledgeHasFourTitledItems() {
        let pledges = pledges()

        #expect(pledges.count == 4)
        for pledge in pledges {
            #expect(!pledge.title.isBlank, "빈 제목")
        }
    }

    /// 설명을 비울 수는 있어도 **공백 문자열로 비우면** 안 된다 — 빈 줄이 그려진다.
    @Test("매너 서약 설명은 없거나 내용이 있다")
    func mannerPledgeDescriptionIsAbsentOrFilled() {
        for description in pledges().compactMap(\.description) {
            #expect(!description.isBlank, "공백만 있는 설명")
        }
    }

    /// **창구는 생겼지만 처리는 여전히 약속하지 못한다.**
    ///
    /// 2026-11-01 에 24 채팅방 메시지 신고가 붙어(`ChatRepository.reportMessage` →
    /// `POST /api/v1/chat-rooms/{id}/reports`, 실측 201) 「불쾌한 말과 행동을 하지 않을게요」에
    /// 설명이 돌아왔다 — 그래서 이 테스트는 **설명이 없어야 한다**를 더 이상 요구하지 않는다.
    ///
    /// 계속 막는 것은 **신고 뒤에 일어나는 일**이다. 코드가 보장하는 것은 거기서 끝난다:
    /// 서버가 `chat_report` 에 한 줄 저장하고 피신고자 인덱스를 걸어 둔다. 그 뒤에 사람이 언제
    /// 무엇을 하는지(확인·경고·정지)는 어느 코드도 정하지 않는다 — 백엔드에 제재 수단 자체가
    /// 없다(`docs/BACKEND-GAP-CLEANUP.md` §1). 2026-10-13 에 지운 「신고가 들어오면 24시간 안에
    /// 확인해요」가 **모양만 바꿔 돌아오는 것**을 막는 것이 이 테스트의 일이다.
    @Test("매너 서약은 신고 뒤 운영 대응을 약속하지 않는다")
    func mannerPledgePromisesNoFollowUp() {
        let all = pledges().map { $0.title + " " + ($0.description ?? "") }.joined(separator: " ")

        for forbidden in ForbiddenClaims.pledgeFollowUp {
            #expect(!all.contains(forbidden), "\(all)")
        }
    }

    /// 반대 방향도 못 박는다 — **창구가 있다는 사실은 남아 있어야 한다.**
    ///
    /// 2026-10-13 에 이 줄은 「기능이 없으니 문구도 지운다」로 비워졌다. 기능이 생긴 지금 비어
    /// 있으면 같은 어긋남이 뒤집힌 꼴이다: 전부 동의해야 가입되는 화면에서 「불쾌한 말과 행동을
    /// 하지 않을게요」만 홀로 설명이 없으면, 어겼을 때 무엇을 할 수 있는지 **알려 줄 자리가
    /// 있는데 비워 둔** 상태가 된다. 그리고 이 줄이 가리키는 길(24 채팅방 롱프레스)은 실제로
    /// 있다 — `ChatUiMessage.canReport` · `ChatRepository.reportMessage`.
    @Test("매너 서약은 신고 창구가 생긴 것을 말한다")
    func mannerPledgeMentionsReporting() throws {
        let matches = pledges().filter { $0.title.contains("불쾌한 말과 행동") }
        #expect(matches.count == 1)
        let pledge = try #require(matches.first)

        #expect(!(pledge.description ?? "").isBlank, "신고 창구가 생겼는데 설명이 비어 있다")
        #expect((pledge.description ?? "").contains("신고"), "\(pledge.description ?? "")")
    }

    // ─────────────────────────── 실제 상수 (원본에 없는 테스트) ───────────────────────────

    /// 위 검사가 미포팅 상수 대신 원본 문구를 본다는 사실을 초록불 뒤에 숨기지 않는다.
    /// 미포팅이면 결과 줄에 「with 1 known issue」가 남고, 상수가 생기면 원본과 글자까지 같아야 한다.
    private func expectMatchesOriginal<V: Equatable & Sendable>(
        _ lookup: AuthCopySource.Lookup<V>,
        original: V,
        name: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        switch lookup {
        case .found(let real):
            #expect(real == original, "`\(name)` 가 원본 문구와 다르다", sourceLocation: sourceLocation)
        case .notPorted:
            withKnownIssue("`\(name)` 미포팅 — 금지어 검사가 실제 상수가 아니라 원본 문구를 본다") {
                Issue.record("`\(name)` 없음", sourceLocation: sourceLocation)
            }
        case .unreadable(let reason):
            Issue.record("FeatureAuth 문구를 읽지 못했다: \(reason)", sourceLocation: sourceLocation)
        }
    }

    @Test("실제 신뢰 불릿이 원본 문구와 같다")
    func trustBulletsConstantMatchesOriginal() {
        expectMatchesOriginal(AuthCopySource.bullets, original: OriginalAuthCopy.bullets, name: "LoginTrustBullets")
    }

    @Test("실제 매너 서약이 원본 문구와 같다")
    func pledgeConstantMatchesOriginal() {
        expectMatchesOriginal(AuthCopySource.pledges, original: OriginalAuthCopy.pledges, name: "mannerPledgeItems")
    }
}

/// 금지어. 근거는 `ProductClaimsTest` 각 테스트의 주석에 있다.
enum ForbiddenClaims {
    static let genderMatching = ["같은 성별", "동성 매칭", "동성끼리", "성별끼리"]
    static let locationSharing = ["위치를 공유", "위치 공유", "실시간 위치", "지인과 공유", "보호자"]
    static let rating = ["매너 점수", "매너 기록", "별점", "후기", "평가"]
    static let settlement = ["정산", "결제", "카드", "자동으로 나눠"]
    static let emergencyReport = ["긴급 신고", "신고가 바로", "112"]
    static let responseDeadline = ["시간 안에", "시간 내", "분 안에", "일 안에", "즉시 확인"]

    /// 가입 전 문구 전체에 적용되는 금지어.
    static let preSignup = genderMatching + locationSharing + rating + settlement + emergencyReport + responseDeadline

    /// 12 매너 서약에만 적용되는 금지어.
    static let pledgeFollowUp = [
        // 시한 — 지킬 수단이 없다
        "24시간", "시간 안에",
        // 「신고가 들어오면 (운영이) …」 꼴 — 주체가 운영으로 넘어가는 순간 약속이 된다
        "신고가 들어오면", "접수되면",
        // 제재 — 서버에 수단이 없다
        "경고", "정지",
    ]
}

/// `AuthCopySource` 자체의 검사. `FeatureAuth` 포팅 전에도 읽기 경로를 확인한다(원본에 없는 테스트).
struct AuthCopySourceTest {
    /// 원본 `LoginScreen.kt`·`MannerPledgeScreen.kt` 의 문구 그대로. 금지어에 걸리지 않음은
    /// `sourceFixtureHasNoForbiddenClaims` 가 함께 본다.
    private static let portedSource = #"""
    // 「같은 성별끼리만 매칭돼요」는 지웠다 — 주석은 읽지 않는다.
    internal let LoginTrustBullets = [
        "휴대폰 인증을 마친 사람만 가입해요",
        "함께 탈 사람의 탑승 횟수가 보여요",
    ]

    /* 「신고가 들어오면 24시간 안에 확인해요」 /* 중첩 */ */
    let mannerPledgeItems: [PledgeItem] = [
        // 09 본인 인증에 있던 체크를 합쳤다.
        PledgeItem("이용약관 · 개인정보 수집에 동의해요", "실명·생년월일·연락처는 본인 확인에만 써요"),
        PledgeItem(title: "약속한 시간과 장소를 지킬게요", description: "무단 취소가 반복되면 이용이 제한돼요"),
        PledgeItem("불쾌한 말과 행동을 하지 않을게요", "채팅방에서 메시지를 길게 눌러 신고할 수 있어요"),
        PledgeItem("매칭이 확정되면 꼭 나갈게요", "매칭 확정 후 오지 않으면 이용이 제한될 수 있어요"),
    ]
    """#

    private func withFakeSources<T>(
        authFiles: [String: String],
        _ body: (URL) throws -> T
    ) throws -> T {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let auth = root.appendingPathComponent("FeatureAuth")
        try FileManager.default.createDirectory(at: auth, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, content) in authFiles {
            try content.write(to: auth.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return try body(root)
    }

    @Test("상수가 살 파일이 없으면 미포팅이다")
    func missingHomeFileMeansNotPorted() throws {
        try withFakeSources(authFiles: ["Placeholder.swift": "// 자리표시자"]) {
            #expect(AuthCopySource.loadBullets(sourcesRoot: $0) == .notPorted)
            #expect(AuthCopySource.loadPledges(sourcesRoot: $0) == .notPorted)
        }
    }

    @Test("파일은 있는데 상수가 없으면 읽기 실패다 — 검사가 조용히 꺼지지 않는다")
    func missingDeclarationIsAFailure() throws {
        try withFakeSources(authFiles: ["LoginScreen.swift": "let LoginTrustBulletsRenamed = [\"a\"]"]) {
            guard case .unreadable = AuthCopySource.loadBullets(sourcesRoot: $0) else {
                Issue.record("unreadable 이어야 한다")
                return
            }
        }
    }

    @Test("소스 폴더를 못 찾으면 미포팅이 아니라 읽기 실패다")
    func missingSourcesFolderIsAFailure() {
        let nowhere = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        guard case .unreadable = AuthCopySource.loadPledges(sourcesRoot: nowhere) else {
            Issue.record("unreadable 이어야 한다")
            return
        }
    }

    @Test("상수는 하나씩 켜진다 — 불릿만 포팅돼도 불릿은 읽는다")
    func constantsTurnOnIndependently() throws {
        try withFakeSources(authFiles: ["LoginScreen.swift": "let LoginTrustBullets = [\"a\", \"b\"]"]) {
            #expect(AuthCopySource.loadBullets(sourcesRoot: $0) == .found(["a", "b"]))
            #expect(AuthCopySource.loadPledges(sourcesRoot: $0) == .notPorted)
        }
    }

    @Test("선언에서 문구를 읽고 주석은 버린다")
    func readsDeclarationsAndIgnoresComments() throws {
        try withFakeSources(authFiles: ["Copy.swift": Self.portedSource]) {
            #expect(AuthCopySource.loadBullets(sourcesRoot: $0) == .found(OriginalAuthCopy.bullets))
            #expect(AuthCopySource.loadPledges(sourcesRoot: $0) == .found(OriginalAuthCopy.pledges))
        }
    }

    @Test("원본 문구 fixture 는 금지어에 걸리지 않는다")
    func sourceFixtureHasNoForbiddenClaims() throws {
        try withFakeSources(authFiles: ["Copy.swift": Self.portedSource]) {
            guard case .found(let bullets) = AuthCopySource.loadBullets(sourcesRoot: $0),
                  case .found(let pledges) = AuthCopySource.loadPledges(sourcesRoot: $0) else {
                Issue.record("fixture 를 읽지 못했다")
                return
            }
            let copy = (bullets + pledges.flatMap(\.copyParts)).joined(separator: " ")
            let pledgeCopy = pledges.flatMap(\.copyParts).joined(separator: " ")
            #expect(ForbiddenClaims.preSignup.filter(copy.contains).isEmpty, "\(copy)")
            #expect(ForbiddenClaims.pledgeFollowUp.filter(pledgeCopy.contains).isEmpty, "\(pledgeCopy)")
        }
    }

    /// 2026-10-13 에 지운 문구가 돌아오면 소스에서 읽어 금지어에 걸리는 데까지 이어지는지 본다.
    @Test("서약 상수에 지운 거짓 주장이 돌아오면 금지어에 걸린다")
    func removedClaimInPledgeSourceIsCaught() throws {
        let source = #"let mannerPledgeItems = [PledgeItem("불쾌한 말과 행동을 하지 않을게요", "신고가 들어오면 24시간 안에 확인해요")]"#
        try withFakeSources(authFiles: ["MannerPledgeScreen.swift": source]) {
            guard case .found(let pledges) = AuthCopySource.loadPledges(sourcesRoot: $0) else {
                Issue.record("found 여야 한다")
                return
            }
            let copy = pledges.flatMap(\.copyParts).joined(separator: " ")
            #expect(ForbiddenClaims.preSignup.filter(copy.contains) == ["시간 안에"])
            #expect(ForbiddenClaims.pledgeFollowUp.filter(copy.contains) == ["24시간", "시간 안에", "신고가 들어오면"])
        }
    }

    @Test("다른 파일에 읽을 수 없는 꼴로 선언하면 미포팅이 아니라 읽기 실패다")
    func unparsableDeclarationElsewhereIsAFailure() throws {
        try withFakeSources(authFiles: ["PledgeCopy.swift": "let mannerPledgeItems: [PledgeItem] = makeItems()"]) {
            guard case .unreadable = AuthCopySource.loadPledges(sourcesRoot: $0) else {
                Issue.record("unreadable 이어야 한다")
                return
            }
        }
    }

    @Test("계산 프로퍼티 뒤의 다른 배열을 상수로 읽지 않는다")
    func computedPropertyDoesNotBorrowLaterArray() throws {
        let source = #"var LoginTrustBullets: [String] { ["실제"] }"# + "\n" + #"let other = ["다른 배열"]"#
        try withFakeSources(authFiles: ["Copy.swift": source]) {
            guard case .unreadable = AuthCopySource.loadBullets(sourcesRoot: $0) else {
                Issue.record("unreadable 이어야 한다")
                return
            }
        }
    }

    @Test("상수 이름을 바꿔도 PledgeItem 이 쓰이면 미포팅이 아니라 읽기 실패다")
    func renamedConstantIsAFailure() throws {
        try withFakeSources(authFiles: ["PledgeCopy.swift": #"let pledgeRows = [PledgeItem("제목")]"#]) {
            guard case .unreadable = AuthCopySource.loadPledges(sourcesRoot: $0) else {
                Issue.record("unreadable 이어야 한다")
                return
            }
        }
    }

    @Test("주석에서 이름만 말하는 것은 미포팅이다")
    func commentMentionIsStillNotPorted() throws {
        try withFakeSources(authFiles: ["SignupDraft.swift": "// mannerPledgeItems · PledgeItem 은 12 화면에 있다"]) {
            #expect(AuthCopySource.loadPledges(sourcesRoot: $0) == .notPorted)
        }
    }

    @Test("설명이 없거나 nil 인 항목과 이스케이프를 읽는다")
    func readsOptionalDescriptionsAndEscapes() throws {
        let tokens = try #require(AuthCopySource.arrayTokens(
            named: "mannerPledgeItems",
            source: #"let mannerPledgeItems = [PledgeItem("한 줄\n두 줄"), PledgeItem("따옴표 \"안\"", nil)]"#
        ))
        #expect(try AuthCopySource.parsePledges(tokens) == [
            .init(title: "한 줄\n두 줄", description: nil),
            .init(title: "따옴표 \"안\"", description: nil),
        ])
    }

    @Test("값을 알 수 없는 문자열은 읽기 실패다")
    func interpolationIsAFailure() throws {
        try withFakeSources(authFiles: ["LoginScreen.swift": #"let LoginTrustBullets = ["a", "b\(suffix)"]"#]) {
            guard case .unreadable = AuthCopySource.loadBullets(sourcesRoot: $0) else {
                Issue.record("unreadable 이어야 한다")
                return
            }
        }
    }

    @Test("실제 소스 폴더를 찾는다")
    func locatesRealSourcesFolder() {
        let onboarding = AuthCopySource.sourcesRoot().appendingPathComponent("FeatureOnboarding/OnboardingCopy.swift")
        #expect(FileManager.default.fileExists(atPath: onboarding.path), "\(onboarding.path)")
    }
}
