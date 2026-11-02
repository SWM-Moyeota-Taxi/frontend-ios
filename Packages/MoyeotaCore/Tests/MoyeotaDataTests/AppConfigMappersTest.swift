import Foundation
import MoyeotaDomain
import Testing
@testable import MoyeotaData

/// `GET /api/v1/config` — 서버 `AppConfigResponse(boolean taxiEnabled)` 기준.
///
/// 업데이트 기준만 원본과 다른 키로 읽는다 — 근거는 `AppConfigResponse` 주석과 `docs/IOS-DIFFERENCES.md`.
@Suite struct AppConfigMappersTest {

    @Test("taxiEnabled false 를 그대로 옮긴다")
    func taxiDisabled() throws {
        let response = try decodeJSON(AppConfigResponse.self, #"{"taxiEnabled":false}"#)
        #expect(!response.toAppConfig().taxiEnabled)
    }

    @Test("taxiEnabled true 를 그대로 옮긴다")
    func taxiEnabled() throws {
        let response = try decodeJSON(AppConfigResponse.self, #"{"taxiEnabled":true}"#)
        #expect(response.toAppConfig().taxiEnabled)
    }

    @Test("필드가 빠지면 동승 모드(false) 다 — 모를 땐 실배포 모드")
    func missingTaxiEnabled() throws {
        let response = try decodeJSON(AppConfigResponse.self, "{}")
        #expect(!response.toAppConfig().taxiEnabled)
    }

    @Test("모르는 필드가 늘어나도 깨지지 않는다")
    func unknownFields() throws {
        let response = try decodeJSON(AppConfigResponse.self, #"{"taxiEnabled":true,"minVersion":"1.2.0"}"#)
        #expect(response.toAppConfig().taxiEnabled)
    }

    // ─────────────── 강제 업데이트 기준 (서버가 아직 주지 않는 필드) ───────────────

    @Test("지금 서버 응답에는 버전 기준이 없어 둘 다 null 이다")
    func noVersionFields() throws {
        // 2026-11-01 로컬 :8080 실측 응답 모양. null 이면 게이트가 아무도 막지 않는다.
        let config = try decodeJSON(AppConfigResponse.self, #"{"taxiEnabled":false}"#).toAppConfig()

        #expect(config.minVersionCode == nil)
        #expect(config.recommendedVersionCode == nil)
    }

    @Test("서버가 iOS 버전 기준을 주기 시작하면 그대로 옮긴다")
    func iosVersionFields() throws {
        // 백엔드에 필드를 더하는 날 앱 배포 없이 바로 걸려야 한다 — 그게 이 필드를 미리 둔 이유다.
        let config = try decodeJSON(
            AppConfigResponse.self,
            #"{"taxiEnabled":false,"iosMinVersionCode":26110102,"iosRecommendedVersionCode":26110103}"#
        ).toAppConfig()

        #expect(config.minVersionCode == 26110102)
        #expect(config.recommendedVersionCode == 26110103)
    }

    // iOS 에서 더한 경우. 원본 기대값의 키(minVersionCode)는 Android versionCode 수열이라
    // iOS 에서는 게이트에 닿지 않아야 한다 — 위 테스트만으로는 두 키를 함께 읽어도 통과한다.
    @Test("Android 버전 기준은 iOS 를 막지 않는다")
    func androidVersionFieldsAreIgnored() throws {
        let androidOnly = try decodeJSON(
            AppConfigResponse.self,
            #"{"taxiEnabled":false,"minVersionCode":26110102,"recommendedVersionCode":26110103}"#
        ).toAppConfig()

        #expect(androidOnly.minVersionCode == nil)
        #expect(androidOnly.recommendedVersionCode == nil)

        let both = try decodeJSON(
            AppConfigResponse.self,
            #"{"taxiEnabled":false,"minVersionCode":26110102,"recommendedVersionCode":26110103,"iosMinVersionCode":7,"iosRecommendedVersionCode":8}"#
        ).toAppConfig()

        #expect(both.minVersionCode == 7)
        #expect(both.recommendedVersionCode == 8)
    }
}
