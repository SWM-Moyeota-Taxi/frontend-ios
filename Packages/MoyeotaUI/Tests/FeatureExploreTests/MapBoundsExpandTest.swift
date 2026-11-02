@testable import FeatureExplore
import Foundation
import Testing

/// 조회 영역은 **가시 영역보다 넓어야** 한다.
///
/// 서버는 출발지가 영역 안인 방만 돌려준다. 보이는 만큼만 물으면 카메라가 조금만 움직여도
/// 가장자리의 방이 빠졌다 들어오며 마커가 깜빡인다(실기 QA). 여유를 두면 그 경계가 화면 밖에 있다.
struct MapBoundsExpandTest {
    private let seomyeon = MapBounds(swLat: 35.15, swLng: 129.05, neLat: 35.17, neLng: 129.07)

    private func assertClose(_ expected: Double, _ actual: Double, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(abs(expected - actual) <= 1e-9, "expected \(expected), got \(actual)", sourceLocation: sourceLocation)
    }

    @Test("사방으로 넓어지고 원래 영역을 포함한다")
    func expandsEveryDirection() {
        let e = seomyeon.expanded(ratio: 0.3)

        #expect(e.swLat < seomyeon.swLat)
        #expect(e.swLng < seomyeon.swLng)
        #expect(e.neLat > seomyeon.neLat)
        #expect(e.neLng > seomyeon.neLng)
    }

    @Test("여유는 각 변의 길이에 비례한다")
    func marginIsProportional() {
        let e = seomyeon.expanded(ratio: 0.5)

        // 위도 폭 0.02 의 50% = 0.01 씩 양쪽
        assertClose(35.14, e.swLat)
        assertClose(35.18, e.neLat)
        assertClose(129.04, e.swLng)
        assertClose(129.08, e.neLng)
    }

    @Test("극지방·날짜변경선을 넘지 않는다")
    func clampsAtWorldEdges() {
        let edge = MapBounds(swLat: -89.0, swLng: -179.0, neLat: 89.0, neLng: 179.0).expanded(ratio: 1.0)

        assertClose(-90.0, edge.swLat)
        assertClose(90.0, edge.neLat)
        assertClose(-180.0, edge.swLng)
        assertClose(180.0, edge.neLng)
    }
}
