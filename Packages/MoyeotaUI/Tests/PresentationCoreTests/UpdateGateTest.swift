import MoyeotaDomain
import Testing
@testable import PresentationCore

/// 강제 업데이트 게이트.
///
/// **막는 쪽보다 안 막는 쪽이 중요하다.** 여기서 한 줄이 틀리면 멀쩡한 사용자가 스토어 화면에
/// 갇히고, 그 상태를 서버에서 되돌릴 수단이 없다(막힌 앱은 설정을 다시 받아도 같은 판정이다).
/// 그래서 「통과해야 하는 경우」를 전부 못 박는다.
@Suite struct UpdateGateTest {
    private func config(min: Int? = nil, recommended: Int? = nil) -> AppConfig {
        AppConfig(taxiEnabled: false, minVersionCode: min, recommendedVersionCode: recommended)
    }

    // ───────────────────── 반드시 통과해야 하는 경우 ─────────────────────

    @Test("서버가 기준을 안 주면 통과한다")
    func passesWithoutThreshold() {
        // 2026-11-01 현재 서버 응답이 이 상태다 — taxiEnabled 하나뿐.
        #expect(updateRequirement(config: config(), installedVersionCode: 26110101) == .none)
    }

    @Test("설정 조회에 실패해도 통과한다")
    func passesOnConfigFailure() {
        // 서버 장애로 전원이 잠기는 쪽이 낡은 앱이 도는 것보다 훨씬 나쁘다.
        #expect(updateRequirement(config: AppConfig.Default, installedVersionCode: 26110101) == .none)
    }

    @Test("설치 버전을 못 읽으면 통과한다")
    func passesWithUnknownVersion() {
        #expect(updateRequirement(config: config(min: 99999999), installedVersionCode: UNKNOWN_VERSION_CODE) == .none)
    }

    @Test("서버가 0 이나 음수를 주면 통과한다")
    func passesWithNonPositiveThreshold() {
        // 실수로 0 을 넣어 전원을 잠그는 사고를 막는다.
        #expect(updateRequirement(config: config(min: 0), installedVersionCode: 26110101) == .none)
        #expect(updateRequirement(config: config(min: -1), installedVersionCode: 26110101) == .none)
    }

    @Test("기준과 같은 버전은 통과한다")
    func passesAtThreshold() {
        // 경계값 — `<` 가 `<=` 로 바뀌면 방금 올린 최신 빌드가 스스로를 막는다.
        #expect(updateRequirement(config: config(min: 26110101), installedVersionCode: 26110101) == .none)
    }

    @Test("기준보다 높은 버전은 통과한다")
    func passesAboveThreshold() {
        #expect(updateRequirement(config: config(min: 26110101), installedVersionCode: 26110102) == .none)
    }

    // ───────────────────── 막아야 하는 경우 ─────────────────────

    @Test("기준보다 낮으면 차단한다")
    func blocksBelowThreshold() {
        #expect(updateRequirement(config: config(min: 26110102), installedVersionCode: 26110101) == .blocked)
    }

    @Test("권장 기준만 밑돌면 막지 않고 알리기만 한다")
    func recommendsBelowRecommended() {
        #expect(updateRequirement(config: config(recommended: 26110102), installedVersionCode: 26110101) == .recommended)
    }

    @Test("둘 다 밑돌면 차단이 이긴다")
    func blockedWinsOverRecommended() {
        // 차단이 권장보다 먼저 판정돼야 한다 — 순서가 뒤집히면 못 쓰는 버전이 안내만 받고 계속 돈다.
        #expect(
            updateRequirement(config: config(min: 26110102, recommended: 26110103), installedVersionCode: 26110101)
                == .blocked
        )
    }

    // ─── iOS (원본에 없는 것) ───

    @Test("CFBundleVersion 이 정수가 아니면 못 읽은 것으로 본다")
    func parsesBundleVersion() {
        #expect(parseVersionCode("42") == 42)
        #expect(parseVersionCode("1.2.3") == UNKNOWN_VERSION_CODE)
        #expect(parseVersionCode("") == UNKNOWN_VERSION_CODE)
        #expect(parseVersionCode(nil) == UNKNOWN_VERSION_CODE)
    }
}
