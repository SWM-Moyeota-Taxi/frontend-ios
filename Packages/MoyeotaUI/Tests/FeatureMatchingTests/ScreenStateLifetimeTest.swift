import MoyeotaDomain
import SwiftUI
import Testing
import UIKit
@testable import FeatureMatching

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

@MainActor
@Suite(.serialized) struct ScreenStateLifetimeTest {

    @Test("21 은 그만 찾기 확인창을 연 채 가렸다 돌아오면 닫혀 있다")
    func waitingForgetsDialog() async {
        let closed = CoveredScreen(MatchWaitingScreen(ride: lifetimeRide))
        await closed.settle()
        let bright = closed.brightness()
        closed.close()

        let screen = CoveredScreen(MatchWaitingScreen(ride: lifetimeRide).seeded(cancelConfirming: true))
        defer { screen.close() }
        await screen.settle()
        #expect(screen.brightness() < bright - 0.2, "확인창이 어둡기를 깔아야 시험이 된다")

        await screen.coverAndReturn()

        #expect(abs(screen.brightness() - bright) < 0.05)
    }
}

private let lifetimeRide = Ride(
    id: "1", origin: "센텀시티역", destination: "서면역", departureLabel: "지금 출발",
    capacity: 3, members: [], farePerPerson: 3600, totalFare: 10800, status: .recruiting
)
