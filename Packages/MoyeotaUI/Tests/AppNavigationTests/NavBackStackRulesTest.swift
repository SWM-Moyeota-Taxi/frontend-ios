import Foundation
import Testing

/// 백스택·뒤로가기·탈퇴 안내에 대해 **`MainNavGraph` 가 내린 결정**을 못 박는다.
///
/// 2026-10-28 결함 묶음이 출발점이다:
/// - 26 운행 중이 `resetTo`(목적지 1개 스택)로 진입해, 뒤로가기가 그 한 장을 pop 해 **빈 화면**이 됐다.
/// - 21·25·26 의 **시스템** 뒤로가기가 기본 pop 이라 화면이 정한 규칙을 전부 우회했다 — 21 에서 누르면 15 목적지 검색으로
///   떨어지고, 거기서 방을 또 만들면 서버가 409.
/// - 홈이 스택 바닥이 아니게 되면 하단탭이 「교체」가 아니라 「쌓기」가 됐다.
/// - 홈 탭 복귀만 `saveState` 가 없어 지도 카메라·스크롤이 홈 경유에서만 초기화됐다.
/// - 가입 초안이 `remember` 라 회전하면 12 매너 서약에서 가입을 마칠 수 없었다.
/// - 탈퇴 플래그가 "요청을 보냈다"에 섰던 탓에, 401 로 끝난 탈퇴에도 「탈퇴가 처리됐어요」가 떴다.
///
/// 여기서 보는 것은 **소스에 적힌 결정**이다 — 원본에 실행 테스트 도구가 없어 생긴 모양이고, iOS 의 실제 스택 모양은
/// `MoyeotaNavControllerTest`·`MainNavGraphRuntimeTest` 가 실행해서 본다. 원본과 같은 결정을 같은 문구로 지킨다.
///
/// 소스를 문자열로 읽는 테스트라 서식을 크게 바꾸면 깨질 수 있다. 깨지면 **먼저 결정이 그대로인지
/// 확인하고** 정규식을 고쳐라 — 결정을 되돌리면서 테스트를 지우는 것이 이 테스트가 막는 일이다.
@Suite struct NavBackStackRulesTest {
    private func source(_ path: String) throws -> String {
        try #require(SourceTree.read(path), "소스 파일이 없다: \(path)")
    }

    /// 원본 `MainNavGraph.kt` 한 파일이 iOS 에서는 호스트(뷰)와 컨트롤러(스택 이동) 둘로 나뉘었다.
    private func navGraph() throws -> String {
        try source("AppNavigation/MainNavGraph.swift") + "\n" + source("AppNavigation/MoyeotaNavController.swift")
    }

    /// `case .<route>` 하나의 블록만 잘라낸다 — 다음 `case .` 선언이 경계다.
    /// 중괄호를 세는 대신 이렇게 자르는 이유: 목적지 선언이 파일에서 순서대로 나열돼 있어 충분하고,
    /// 정규식으로 균형 잡힌 괄호를 세는 쪽이 더 깨지기 쉽다.
    private func destinationBlock(_ source: String, route: String) throws -> String {
        let marker = "        case .\(route):"
        let start = try #require(source.range(of: marker), "\(marker) 선언이 없다")
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n        case .")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    // ─────────────── 1. 구성 변경에서 살아남아야 하는 가입 상태 ───────────────

    /// 가입 초안이 사라지면 12 매너 서약의 「동의하고 가입 완료」가 `toNewUser() == nil` 로 떨어져
    /// 「가입 정보가 부족해요」에서 더 나아갈 수 없다 — 사용자는 **가입 직전에** 원인 불명의 거절을 본다.
    /// 재인증 신호(카운터)는 비교 상대가 뷰모델이라, 이쪽만 0 으로 돌아가면 이후 신호가
    /// 「이미 처리한 번호」로 조용히 버려진다.
    @Test("가입 초안과 재인증 신호는 구성 변경에서 살아남는다")
    func signupStateSurvives() throws {
        let navGraph = try navGraph()
        #expect(
            SourceTree.contains(#"@State\s+private\s+var\s+signupDraft\b"#, in: navGraph),
            "signupDraft 가 rememberSaveable 이 아니다 — 회전하면 12 에서 가입을 마칠 수 없다"
        )
        #expect(
            SourceTree.contains(#"@State\s+private\s+var\s+reverifyPhoneRequest\b"#, in: navGraph),
            "reverifyPhoneRequest 가 rememberSaveable 이 아니다 — 회전 뒤 재인증 신호가 버려진다"
        )
    }

    // ─────────────── 2. 진행 화면의 뒤로가기 ───────────────

    /// 21·25·26 은 뒤로가기를 **화면이 정한 규칙**으로 받아야 한다. 헤더 ← 만 배선하면 시스템
    /// 뒤로가기가 기본 pop 으로 빠져나가 15·16 방 생성 플로우나 빈 화면으로 떨어진다.
    @Test("진행 화면 셋은 시스템 뒤로가기를 직접 받는다")
    func progressScreensHandleBack() throws {
        let navGraph = try navGraph()
        for route in ["matchWaiting", "dispatchStatus", "rideOngoing"] {
            #expect(
                try destinationBlock(navGraph, route: route).contains("moyeotaBackHandler"),
                "\(route) 에 BackHandler 가 없다 — 시스템 뒤로가기가 화면 규칙을 우회한다"
            )
        }
    }

    /// 26 은 **홈을 바닥에 남기고** 진입한다 — 목적지 1개 스택에서는 뒤로가기가 빈 화면을 만든다.
    @Test("26 운행 중은 스택을 비우고 진입하지 않는다")
    func rideOngoingKeepsHome() throws {
        let navGraph = try navGraph()
        #expect(
            !navGraph.contains("resetTo(.rideOngoing)"),
            "resetTo(.rideOngoing) 이 돌아왔다 — 뒤로가기가 화면 없는 빈 그래프를 만든다"
        )
        #expect(
            SourceTree.contains(#"navigate\(\.rideOngoing\)\s*\{\s*\$0\.popUpTo\(\.home\)"#, in: navGraph),
            "25 → 26 이동이 홈을 바닥에 남기지 않는다"
        )
    }

    // ─────────────── 3. 하단탭 ───────────────

    /// 홈 복귀는 pop 이라 **떠나는 탭 엔트리를 폐기한다.** `saveState` 가 없으면 다른 탭 경유
    /// (합승→채팅→합승)에서는 보존되는 지도 카메라·스크롤이 홈 경유에서만 초기화된다.
    ///
    /// 반대로 **무조건** 켜서도 안 된다 — `saveState = true` 인 pop 은 엔트리의 상태를 버리지 않으므로,
    /// 21·25·26 에서 홈으로 나오는 길까지 켜면 이미 떠난 방의 뷰모델이 남는다. 그래서 「떠나는 화면이 탭인가」로 가른다.
    @Test("홈 탭 복귀도 떠나는 탭의 상태를 보관한다")
    func homeTabReturnSavesLeavingTab() throws {
        let navGraph = try navGraph()
        let pop = SourceTree.firstMatch(
            #"popBackStack\(\s*\.home,\s*inclusive:\s*false,\s*saveState:\s*(\w+)\s*\)"#,
            in: navGraph
        )
        #expect(pop != nil, "홈 복귀 popBackStack 에 saveState 인자가 없다 — 홈 경유에서만 탭 상태가 초기화된다")
        #expect(pop?[1] != "true", "saveState 가 무조건 true 다 — 진행 화면에서 홈으로 나올 때 그 엔트리의 뷰모델이 남는다")
        #expect(navGraph.contains("TabRoutes.contains"), "떠나는 화면이 탭인지 보지 않는다 — 보관 여부를 가릴 근거가 없다")
    }

    /// 홈이 스택에 없을 때의 폴백 — 없으면 탭이 교체가 아니라 쌓인다.
    @Test("홈이 스택에 없으면 탭 이동이 스택부터 다시 세운다")
    func navigateTabRebuildsWithoutHome() throws {
        let navGraph = try navGraph()
        let start = try #require(navGraph.range(of: "func navigateTab(_ tab: MoyeotaTab) {", options: .backwards))
        let rest = navGraph[start.upperBound...]
        let end = try #require(rest.range(of: "func navigateToStage"))
        let navigateTab = String(rest[..<end.lowerBound])
        #expect(navigateTab.contains("backStack.contains"), "navigateTab 이 홈의 존재를 확인하지 않는다 — 홈이 없으면 popUpTo(.home) 가 무효다")
        #expect(navigateTab.contains("resetTo(.home)"), "홈이 없을 때 스택을 다시 세우지 않는다")
    }

    // ─────────────── 4. 37 탈퇴 안내 ───────────────

    /// 「탈퇴가 처리됐어요」의 근거는 **204 수신**뿐이다. "요청을 보냈다"에 세우면 401 → 재발급 실패로
    /// 끝난 탈퇴에도 그 안내가 떠, 계정이 살아 있는 사람에게 거짓을 말한다.
    @Test("탈퇴 안내는 204 를 받았을 때만 뜬다")
    func deleteNoticeOnlyOn204() throws {
        let navGraph = try navGraph()
        #expect(
            SourceTree.contains(#"onSessionEndExpected:\s*\{\s*accountDeleteRequested\s*=\s*true"#, in: navGraph),
            "요청 직전 콜백이 「탈퇴됐다」를 세운다 — 401 로 끝난 탈퇴에도 안내가 뜬다"
        )
        #expect(
            SourceTree.contains(#"onDeleted:\s*\{\s*accountDeleted\s*=\s*true"#, in: navGraph),
            "204 수신 콜백(onDeleted)이 배선돼 있지 않다"
        )
        let noticeStart = try #require(navGraph.range(of: "let notice: String? = if"))
        let noticeRest = navGraph[noticeStart.lowerBound...]
        let noticeEnd = try #require(noticeRest.range(of: "signOutNotice = notice"))
        let notice = String(noticeRest[..<noticeEnd.lowerBound])
        #expect(
            SourceTree.contains(#"if\s+accountDeleted\s*\{(\s*//[^\n]*)*\s*"탈퇴가 처리됐어요"#, in: notice),
            "탈퇴 안내의 근거가 accountDeleted 가 아니다: \(notice)"
        )
        #expect(
            SourceTree.contains(#"if\s+accountDeleteRequested\s*\{(\s*//[^\n]*)*\s*nil"#, in: notice),
            "결과를 모르는 상태에서도 「세션이 만료됐어요」를 말한다 — 둘 중 하나는 거짓말이다"
        )
        let route = try source("FeatureMyPage/AccountDeleteRoute.swift")
        #expect(
            SourceTree.contains(#"repository\.deleteAccount\([^)]*\)\s*(//[^\n]*\n\s*)*onDeleted\(\)"#, in: route),
            "탈퇴 성공 직후에 onDeleted() 를 부르지 않는다"
        )
    }
}
