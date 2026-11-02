import Testing
@testable import MoyeotaDesignSystem

/// 원본에 없는 테스트. 축척 값 고르기를 안드로이드 `ScaleBarView.a(NaverMap)` 바이트코드에서 손으로 푼 값과 비교한다.
@Suite struct ScaleBarSpecTest {

    /// 기준 폭 80 에 든 거리(m)를 주고 고른 값을 본다.
    private func make(metersIn80: Double) -> ScaleBarSpec? {
        ScaleBarSpec(metersPerPoint: metersIn80 / 80)
    }

    @Test("20 합류 확인 축척에서 원본처럼 5km 를 고른다 (100pt 기준이면 10km)")
    func joinConfirmScale() throws {
        let spec = try #require(ScaleBarSpec(metersPerPoint: 5000 / 42.3))
        #expect(spec.value == "5")
        #expect(spec.unit == "km")
        #expect(abs(spec.length - 42.3) < 0.001)
    }

    @Test("17 탐색 축척에서 100m 를 고른다")
    func exploreScale() throws {
        let spec = try #require(ScaleBarSpec(metersPerPoint: 1.895))
        #expect(spec.value == "100")
        #expect(spec.unit == "m")
        #expect(abs(spec.length - 100 / 1.895) < 0.001)
    }

    @Test(
        "1·2·5 중 기준 폭에 드는 가장 큰 값",
        arguments: [
            (2.5, "2", "m"),
            (19.9, "10", "m"),
            (54.0, "50", "m"),
            (999.0, "500", "m"),
            (1000.0, "1", "km"),
            (1999.0, "1", "km"),
            (9368.0, "5", "km"),
            (10000.0, "10", "km"),
            (25000.0, "20", "km"),
        ]
    )
    func picksLargestNiceValue(metersIn80: Double, value: String, unit: String) throws {
        let spec = try #require(make(metersIn80: metersIn80))
        #expect(spec.value == value)
        #expect(spec.unit == unit)
    }

    @Test("막대는 원본처럼 32 에서 80 사이다")
    func lengthStaysWithinBase() throws {
        for metersIn80 in stride(from: 3.0, to: 400_000.0, by: 137.0) {
            let spec = try #require(make(metersIn80: metersIn80))
            #expect(spec.length <= 80)
            #expect(spec.length > 32)
        }
    }

    @Test("지도가 레이아웃되기 전의 0·NaN·무한대는 그리지 않는다", arguments: [0.0, -1.0, Double.nan, Double.infinity])
    func invalidScale(metersPerPoint: Double) {
        #expect(ScaleBarSpec(metersPerPoint: metersPerPoint) == nil)
    }
}
