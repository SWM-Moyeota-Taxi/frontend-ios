import MoyeotaDomain
import Testing
@testable import PresentationCore

/// 동승(실배포) / 택시(개발 중) 모드 판정. 서버 값이 없으면 동승, 디버그 강제값이 있으면 그것을 따른다.
/// 모드가 어긋난 단계(동승 모드에 배차·운행)는 status 를 따르되 설정 재조회 신호로만 쓴다.
@Suite struct AppModeTest {
    @Test("설정을 못 받았을 때 기본값은 동승 모드다")
    func defaultIsCompanion() {
        #expect(!AppConfig.Default.taxiEnabled)
        #expect(AppMode.of(taxiEnabled: AppConfig.Default.taxiEnabled) == .companion)
    }

    @Test("강제값이 없으면 서버 값을 따른다")
    func followsServerWithoutOverride() {
        #expect(effectiveTaxiEnabled(server: true, override: nil))
        #expect(!effectiveTaxiEnabled(server: false, override: nil))
    }

    @Test("강제값이 있으면 서버 값보다 우선한다")
    func overrideWins() {
        #expect(effectiveTaxiEnabled(server: false, override: true))
        #expect(!effectiveTaxiEnabled(server: true, override: false))
    }

    @Test("동승 모드에서 배차·운행 단계는 모드 밖이다")
    func taxiStagesOutsideCompanion() {
        #expect(isStageOutsideMode(stage: .driverSearch, taxiEnabled: false))
        #expect(isStageOutsideMode(stage: .driverComing, taxiEnabled: false))
        #expect(isStageOutsideMode(stage: .ongoing, taxiEnabled: false))
    }

    @Test("대기·종료 단계는 어느 모드에서도 모드 밖이 아니다")
    func waitingAndNoneAlwaysInside() {
        for taxi in [true, false] {
            #expect(!isStageOutsideMode(stage: .waiting, taxiEnabled: taxi))
            #expect(!isStageOutsideMode(stage: .none, taxiEnabled: taxi))
        }
    }

    @Test("택시 모드에서는 모든 단계가 모드 안이다")
    func everyStageInsideTaxi() {
        for stage in ActiveStage.allCases {
            #expect(!isStageOutsideMode(stage: stage, taxiEnabled: true))
        }
    }
}
