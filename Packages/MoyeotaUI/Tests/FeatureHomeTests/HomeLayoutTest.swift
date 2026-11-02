import MoyeotaDomain
import SwiftUI
import Testing
import UIKit
@testable import FeatureHome

/// 원본에는 없는 테스트. 스타일 없는 Compose `Text` 가 물려받는 줄 높이 24sp 가 실제 높이로 옮겨졌는지 잰다.
///
/// 기대값은 원본 `HomeScreen.kt` 의 값을 더한 것이다. 시트의 접힘 높이와 목록의 밀도가 여기서 정해진다.
@MainActor
@Suite struct HomeLayoutTest {

    private func height(_ view: some View) -> CGFloat {
        UIHostingController(rootView: view)
            .sizeThatFits(in: CGSize(width: 393, height: 2000))
            .height
    }

    private func place(roadName: String) -> FavoritePlace {
        FavoritePlace(id: 1, name: "집", roadName: roadName, latitude: 35, longitude: 129, sequence: 1)
    }

    private func row(roadName: String, distanceLabel: String? = "850m") -> FavoritePlaceRow {
        FavoritePlaceRow(
            place: place(roadName: roadName),
            distanceLabel: distanceLabel,
            editing: false,
            selected: false,
            enabled: true,
            onClick: {}
        )
    }

    private func detail(
        loadFailed: Bool = false,
        errorMessage: String? = nil
    ) -> FavoritesDetail {
        FavoritesDetail(
            myLocation: nil,
            favoritePlaces: [],
            editingFavorites: false,
            selectedFavoriteIds: [],
            deletingFavorites: false,
            favoriteErrorMessage: errorMessage,
            favoritesLoaded: !loadFailed,
            favoritesLoadFailed: loadFailed,
            onRetryFavorites: {},
            onFavoritePlaceClick: { _ in },
            onEditFavoritesToggle: {},
            onFavoriteSelectToggle: { _ in },
            onConfirm: { _ in }
        )
    }

    /// 18.5 + 인사 24 + 제목 38.86 + 6 + 부제 24 + 20 + 검색 바 64 + 20. 18.5 는 원본 렌더에 맞춘 값이고(코드는 18), 제목은 코드의 34sp 가 아니라 원본 UI 트리에서 잰 실제 높이다
    /// (한글 대체 폰트의 줄 상자가 34sp 를 넘는다). 원본 `14_no_banner` 렌더의 히어로와 같은 높이다.
    @Test("히어로 높이는 원본 값의 합 210 이다")
    func heroHeight() {
        #expect(abs(height(HeroSection(userName: "민준", onSearchClick: {})) - 215.36) < 1)
    }

    /// 상태바 인셋별 배너 위 여백. 62 는 iPhone 17, 48.8 은 원본 렌더의 인셋이다.
    @Test("배너 위 여백은 원본 자리까지만 줄어든다")
    func bannerTopPadding() {
        #expect(homeBannerTopPadding(statusBarHeight: 62) == 0)
        #expect(homeBannerTopPadding(statusBarHeight: 20) == 8)
        #expect(homeBannerTopPadding(statusBarHeight: 48.8) == 8)
        #expect(abs(homeBannerTopPadding(statusBarHeight: 54) - 2.8) < 0.01)
    }

    /// 배너 묶음 높이 118 은 iPhone 17 렌더의 값(상태바 62 + 배너 48 + 아래 8)이다. 가시 영역 끝은 지도 노출 높이 200 이다.
    @Test("줌 컨트롤은 배너와 겹치지 않는 만큼만 올라간다")
    func zoomControlOffset() {
        #expect(homeZoomControlOffsetY(bannerHeight: 118, visibleBottom: 200) == -2)
        // 컨트롤 위 끝 (136 + 200 − 89) / 2 = 123.5, 배너 아래 끝 128: 이미 겹치면 더 올리지 않는다.
        #expect(homeZoomControlOffsetY(bannerHeight: 136, visibleBottom: 200) == 0)
        // 컨트롤 위 끝 117.5, 배너 아래 끝 116: 그 사이 1.5 만큼만 올라간다.
        #expect(homeZoomControlOffsetY(bannerHeight: 124, visibleBottom: 200) == -1.5)
    }

    /// 위아래 12 + 이름 24 + 도로명 24.
    @Test("즐겨찾기 행 높이는 72 이다")
    func rowHeight() {
        #expect(abs(height(row(roadName: "부산 금정구 부산대학로 63번길 2")) - 72) < 1)
    }

    /// Compose 의 빈 `Text` 는 한 줄을 차지한다. 도로명이 빈 즐겨찾기는 실제로 있어(`favoritePlaceQuery` 참고)
    /// 그 행만 낮아지면 목록의 행 높이가 들쭉날쭉해진다.
    @Test("도로명이 빈 행도 높이가 같다")
    func rowHeightWithBlankRoad() {
        #expect(abs(height(row(roadName: "")) - 72) < 1)
    }

    /// 위 24 + 머리줄 32(「편집」 24 + 위아래 4) + 10 + 안내 24 + 아래 16.
    @Test("빈 목록 안내까지의 상세 높이는 106 이다")
    func emptyDetailHeight() {
        #expect(abs(height(detail()) - 106) < 1)
    }

    /// 안내 24 + 4 + 「다시 시도」 48 자리.
    @Test("조회 실패 상세 높이는 158 이다")
    func failedDetailHeight() {
        #expect(abs(height(detail(loadFailed: true)) - 158) < 1)
    }

    /// 실패 문구 한 줄은 위 8 + 줄 높이 24 를 더한다.
    @Test("삭제 실패 문구는 한 줄 24 를 차지한다")
    func errorMessageHeight() {
        #expect(abs(height(detail(errorMessage: "즐겨찾기를 지우지 못했어요")) - 138) < 1)
    }
}
