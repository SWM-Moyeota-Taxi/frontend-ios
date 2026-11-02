import SwiftUI
import Testing
import UIKit
@testable import FeatureMyPage

/// 원본 `verticalScroll` 은 스크롤해도 키보드를 내리지 않는다. 37 은 키보드가 올라온 채 경고와 링크를 읽을 수 있다는
/// 전제로 만들어졌다(`AccountDeleteScreen` 주석).
///
/// 화면을 창에 올려 실제 `UIScrollView` 의 값을 읽는다. iOS 26.3 시뮬레이터에서는 `ScrollView` 기본값도 `.none` 이라
/// 이 테스트만으로는 `.scrollDismissesKeyboard(.never)` 가 빠진 것을 잡지 못한다. 잡는 건 다른 값으로 바뀐 경우와,
/// 기본값이 다른 런타임에서 돌렸을 때다(Apple 문서는 기본값이 스크롤에 키보드를 내린다고 적는다).
@MainActor
@Suite struct ScrollKeyboardTest {

    @Test("37 본문을 스크롤해도 키보드를 내리지 않는다")
    func accountDeleteKeepsKeyboard() async {
        let modes = await keyboardDismissModes(of: AccountDeleteScreen(password: ""))
        #expect(modes == [.none])
    }

    @Test("36 본문을 스크롤해도 키보드를 내리지 않는다")
    func profileEditKeepsKeyboard() async {
        let modes = await keyboardDismissModes(of: ProfileEditScreen(nickname: ""))
        #expect(modes == [.none])
    }

    private func keyboardDismissModes<V: View>(of view: V) async -> [UIScrollView.KeyboardDismissMode] {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        let host = UIHostingController(rootView: view)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        // SwiftUI 가 뷰 계층을 만들 차례를 준다.
        for _ in 0..<20 {
            window.layoutIfNeeded()
            await Task.yield()
            let found = scrollViews(in: host.view)
            if !found.isEmpty { return found.map(\.keyboardDismissMode) }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return []
    }

    private func scrollViews(in view: UIView) -> [UIScrollView] {
        let own = (view as? UIScrollView).map { [$0] } ?? []
        // 입력 칸 내부의 스크롤 뷰(`UITextField` 는 아니지만 `UITextView` 는 스크롤 뷰다)는 세지 않는다.
        if view is UITextView { return [] }
        return own + view.subviews.flatMap { scrollViews(in: $0) }
    }
}
