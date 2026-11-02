import SwiftUI
import Testing
import UIKit
@testable import FeatureExplore

/// 원본에는 없는 테스트. 17 접힘 요약과 18·19 목록 헤더의 높이가 원본 렌더(19sp 줄 상자 27.8 + 부제 24, 17sp 줄 상자 25.1)와 같은지 잰다.
/// 24 로 눌리면 행 가운데가 약 2pt 올라가 점·화살표·부제가 함께 위로 간다.
@MainActor
@Suite struct ExploreSheetRowLayoutTest {
    private func height(_ view: some View) -> CGFloat {
        UIHostingController(rootView: view)
            .sizeThatFits(in: CGSize(width: 402, height: 2000))
            .height
    }

    @Test("접힘 요약 행은 제목 27.8 + 부제 24 다")
    func peekRowHeight() {
        let filled = height(PeekSummaryRow(count: 3, myPartyHidden: false, onRaise: {}))
        let empty = height(PeekSummaryRow(count: 0, myPartyHidden: false, onRaise: {}))
        #expect(abs(filled - 51.8) < 0.4)
        #expect(abs(empty - 51.8) < 0.4)
    }

    @Test("목록 헤더 행은 25.1 이다")
    func listHeaderHeight() {
        let half = height(ListHeaderRow(count: 3, mapShown: true, onToggleMap: {}))
        let full = height(ListHeaderRow(count: 3, mapShown: false, onToggleMap: {}))
        #expect(abs(half - 25.1) < 0.4)
        #expect(abs(full - 25.1) < 0.4)
    }
}
