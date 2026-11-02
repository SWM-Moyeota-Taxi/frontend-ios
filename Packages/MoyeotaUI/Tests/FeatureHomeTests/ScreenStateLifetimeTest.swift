import SwiftUI
import Testing
import UIKit
@testable import FeatureHome

// 원본에 없는 테스트. 원본 `remember` 는 화면이 컴포지션에서 빠지면 사라지지만 `@State` 는 스택에 있는 동안 남는다.
// 화면을 실제 `NavigationStack` 에 올려 위에 다른 화면을 덮었다가 돌아온 뒤, 어둡기(60%)가 걷혔는지 화면 픽셀로 읽는다
// — SwiftUI `@State` 는 바깥에서 읽을 길이 없고, 이 창에는 씬이 없어 접근성 트리도 읽을 수 없다.

@MainActor
@Observable
private final class CoverRouter {
    var covered = false
}

private struct CoverHarness<Root: View>: View {
    @Bindable var router: CoverRouter
    let root: Root

    var body: some View {
        NavigationStack {
            root
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(isPresented: $router.covered) { Color.red }
        }
    }
}

@MainActor
private final class CoveredScreen {
    private let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
    private let router = CoverRouter()
    private let host: UIViewController

    init<Root: View>(_ root: Root) {
        host = UIHostingController(rootView: CoverHarness(router: router, root: root))
        window.rootViewController = host
        window.isHidden = false
    }

    func close() {
        window.isHidden = true
    }

    func settle() async {
        for _ in 0..<12 {
            window.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    /// 덮은 화면이 올라왔다 내려갈 시간을 넉넉히 주고 돌아온다.
    func coverAndReturn() async {
        router.covered = true
        for _ in 0..<40 {
            window.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(25))
        }
        router.covered = false
        for _ in 0..<40 {
            window.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    /// 창 왼쪽 위 안쪽(어둡기가 덮는 자리)의 밝기 0…1.
    func brightness(at point: CGPoint = CGPoint(x: 6, y: 300)) -> CGFloat {
        // 씬이 없는 창이라 `drawHierarchy` 는 검게 나온다. 레이어를 직접 그린다.
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        guard let context else { return -1 }
        context.translateBy(x: -point.x, y: point.y - window.bounds.height + 1)
        window.layer.render(in: context)
        return (CGFloat(pixel[0]) + CGFloat(pixel[1]) + CGFloat(pixel[2])) / (3 * 255)
    }
}

/// 씬이 없는 창에는 안전 영역이 없다. 실기 값(iPhone 17: 위 62, 아래 34)을 흉내 낸다.
private final class InsetWindow: UIWindow {
    override var safeAreaInsets: UIEdgeInsets { UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0) }
}

@MainActor
@Suite(.serialized) struct DeleteDialogPositionTest {

    private func brightness(_ window: UIWindow, x: CGFloat, y: CGFloat) -> CGFloat {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        guard let context else { return -1 }
        // `render(in:)` 는 레이어 좌표(y 아래로 증가)를 뒤집지 않고 그린다. 잰 y 를 비트맵 첫 줄로 옮긴다.
        context.translateBy(x: -x, y: -y)
        window.layer.render(in: context)
        return (CGFloat(pixel[0]) + CGFloat(pixel[1]) + CGFloat(pixel[2])) / (3 * 255)
    }

    @Test("14 삭제 확인창은 시스템 바를 뺀 영역의 가운데에 놓인다(원본 대화상자 창의 자리)")
    func centeredInsideSystemBars() async {
        let window = InsetWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        // 앱 루트처럼 가장자리까지 그린다
        window.rootViewController = UIHostingController(
            rootView: HomeScreen().seeded(confirming: .all).ignoresSafeArea(.container)
        )
        window.isHidden = false
        defer { window.isHidden = true }
        for _ in 0..<12 {
            window.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(25))
        }
        // 카드 왼쪽 안쪽 여백 세로줄에서 흰 구간을 찾는다. 글자는 안쪽 여백 24 안으로 들어오지 않는다.
        let white = (0..<874).filter { brightness(window, x: 75, y: CGFloat($0)) > 0.98 }
        let longest = white.reduce(into: [[Int]]()) { runs, y in
            if let last = runs.last?.last, last == y - 1 { runs[runs.count - 1].append(y) } else { runs.append([y]) }
        }.max { $0.count < $1.count } ?? []
        #expect(longest.count > 100, "카드를 찾아야 시험이 된다")
        let center = CGFloat((longest.first ?? 0) + (longest.last ?? 0) + 1) / 2
        // (62 + (874 − 34)) / 2 = 451. 화면 가운데(437)가 아니다.
        #expect(abs(center - 451) < 1, "카드 \(longest.first ?? 0)…\(longest.last ?? 0)")
    }
}

@MainActor
@Suite(.serialized) struct ScreenStateLifetimeTest {

    @Test("14 는 삭제 확인창을 연 채 가렸다 돌아오면 닫혀 있다")
    func homeForgetsDialog() async {
        let closed = CoveredScreen(HomeScreen())
        await closed.settle()
        let bright = closed.brightness(at: CGPoint(x: 6, y: 830))
        closed.close()

        let screen = CoveredScreen(HomeScreen().seeded(confirming: .all))
        defer { screen.close() }
        await screen.settle()
        #expect(screen.brightness(at: CGPoint(x: 6, y: 830)) < bright - 0.2, "확인창이 어둡기를 깔아야 시험이 된다")

        await screen.coverAndReturn()

        #expect(abs(screen.brightness(at: CGPoint(x: 6, y: 830)) - bright) < 0.05)
    }
}
