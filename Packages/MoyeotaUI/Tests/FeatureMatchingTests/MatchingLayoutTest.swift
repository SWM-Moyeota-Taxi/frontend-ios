import MoyeotaDesignSystem
import MoyeotaDomain
import SwiftUI
import Testing
import UIKit
@testable import FeatureMatching

// 원본에 없는 테스트. 원본 렌더(UI 트리·스크린샷)에서 잰 값을 지킨다.

/// 씬이 없는 창에는 안전 영역이 없다. 실기 값(iPhone 17: 위 62, 아래 34)을 흉내 낸다.
private final class InsetWindow: UIWindow {
    override var safeAreaInsets: UIEdgeInsets { UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0) }
}

@Suite struct InlineTypeLineHeightTest {

    @Test("줄 상자는 16 이하에서 24 이고 그 위로는 원본 UI 트리의 높이를 따른다", arguments: [
        (CGFloat(11), CGFloat(24)), (12, 24), (13, 24), (14, 24), (15, 24), (16, 24),
        (17, 24.4), (18, 26.3), (19, 27.1), (20, 28.5), (22, 31.6), (24, 34.6),
    ])
    func matchesAndroidLineBox(fontSize: CGFloat, androidHeight: CGFloat) {
        let height = inlineType(fontSize, .bold).lineHeightPoints ?? 0
        #expect(abs(height - androidHeight) < 0.5, "\(fontSize)sp: \(height) 대 \(androidHeight)")
    }
}

@MainActor
@Suite struct DispatchStatusOverflowTest {

    @Test("25 내용이 화면보다 길어도 화면 높이를 넘지 않는다 - 넘으면 상단바가 상태바 밑으로 올라간다(iPhone SE)")
    func staysWithinScreenHeight() {
        let ride = Ride(
            id: "1", origin: "강남역 2호선", destination: "판교역 신분당선", departureLabel: "", capacity: 3, members: [],
            farePerPerson: 5300, totalFare: 15900, status: .dispatching, estimatedMinutes: 38
        )
        let screen = DispatchStatusScreen(ride: ride, onOpenChat: {})
        let height = UIHostingController(rootView: screen).sizeThatFits(in: CGSize(width: 375, height: 667)).height
        #expect(height <= 667)
    }
}

@MainActor
@Suite(.serialized) struct ConfirmDialogGeometryTest {

    private func brightness(_ window: UIWindow, x: CGFloat, y: CGFloat) -> CGFloat {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        guard let context else { return -1 }
        context.translateBy(x: -x, y: -y)
        window.layer.render(in: context)
        return (CGFloat(pixel[0]) + CGFloat(pixel[1]) + CGFloat(pixel[2])) / (3 * 255)
    }

    @Test("21 확인창은 본문이 접히면 폭 320 이고 시스템 바를 뺀 영역의 가운데에 놓인다")
    func widthAndPosition() async {
        let window = InsetWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UIHostingController(
            rootView: MatchWaitingScreen(ride: geometryRide).seeded(cancelConfirming: true).ignoresSafeArea(.container)
        )
        window.isHidden = false
        defer { window.isHidden = true }
        for _ in 0..<12 {
            window.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(25))
        }
        // 카드 왼쪽 안쪽 여백 세로줄에서 흰 구간을 찾는다. 글자는 안쪽 여백 24 안으로 들어오지 않는다.
        let white = (0..<874).filter { brightness(window, x: 55, y: CGFloat($0)) > 0.98 }
        let longest = white.reduce(into: [[Int]]()) { runs, y in
            if let last = runs.last?.last, last == y - 1 { runs[runs.count - 1].append(y) } else { runs.append([y]) }
        }.max { $0.count < $1.count } ?? []
        #expect(longest.count > 100, "카드를 찾아야 시험이 된다")
        let top = longest.first ?? 0
        let bottom = (longest.last ?? 0) + 1
        // (62 + (874 − 34)) / 2 = 451. 화면 가운데(437)가 아니다.
        #expect(abs(CGFloat(top + bottom) / 2 - 451) < 1, "카드 \(top)…\(bottom)")

        // 원본은 문구와 상관없이 320 이다. 가장 긴 줄로 줄어들면 이 값이 달라진다.
        let xs = (0..<402).filter { brightness(window, x: CGFloat($0), y: CGFloat(top + 40)) > 0.98 }
        let width = CGFloat((xs.last ?? 0) + 1 - (xs.first ?? 0))
        #expect(abs(width - 320) < 1, "카드 폭 \(width)")
    }
}

@MainActor
@Suite(.serialized) struct RenderedGeometryTest {

    private func hosted(_ view: some View) async -> UIWindow {
        let window = InsetWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UIHostingController(rootView: AnyView(view.ignoresSafeArea(.container)))
        window.isHidden = false
        for _ in 0..<12 {
            window.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(25))
        }
        return window
    }

    private func brightness(_ window: UIWindow, x: CGFloat, y: CGFloat) -> CGFloat {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        guard let context else { return -1 }
        context.translateBy(x: -x, y: -y)
        window.layer.render(in: context)
        return (CGFloat(pixel[0]) + CGFloat(pixel[1]) + CGFloat(pixel[2])) / (3 * 255)
    }

    private func statValueInkWidth(rideCount: Int) async -> CGFloat {
        let window = await hosted(PartnerProfileScreen(user: geometryUser(rideCount: rideCount)))
        defer { window.isHidden = true }
        // 값 글자는 지표 카드 안 줄이다. 진한 글자는 이 화면에서 닉네임과 이 줄뿐이고, 닉네임은 위에 있다.
        var xs: [Int] = []
        for y in stride(from: CGFloat(305), to: 332, by: 1) {
            for x in 100..<302 where brightness(window, x: CGFloat(x) + 0.5, y: y) < 0.4 { xs.append(x) }
        }
        return CGFloat((xs.max() ?? 0) + 1 - (xs.min() ?? 0))
    }

    @Test("23 「11회」는 1 이 좁아지지 않아 「88회」와 폭이 같다(원본 Roboto 숫자는 폭이 같다)")
    func statValueDigitsAreTabular() async {
        let eleven = await statValueInkWidth(rideCount: 11)
        let eightyEight = await statValueInkWidth(rideCount: 88)
        #expect(eleven > 25, "값 줄을 찾아야 시험이 된다: \(eleven)")
        #expect(abs(eleven - eightyEight) < 3, "11회 \(eleven) 대 88회 \(eightyEight)")
    }

    @Test("25c 마지막 버튼은 홈 인디케이터 영역에 들어가지 않고 바로 위까지 내려온다")
    func assignedLastButtonClearsHomeIndicator() async {
        let window = await hosted(DriverAssignedScreen(ride: geometryRide, onOpenChat: {}))
        defer { window.isHidden = true }
        // 버튼 안쪽 세로줄에서 맨 아래 칠해진 칸. 그 아래로는 시트의 흰 바탕뿐이다.
        let painted = (500..<874).filter { brightness(window, x: 60, y: CGFloat($0)) < 0.985 }
        let bottom = CGFloat((painted.last ?? 0) + 1)
        #expect(bottom <= 840, "버튼 아래 끝 \(bottom), 안전 영역 840")
        #expect(bottom > 830, "버튼 아래 끝 \(bottom): 지도를 필요 이상 줄이면 안 된다")
    }

    @Test("25c 지도는 시트가 들어가는 선에서 최대이고 원본 220 을 넘지 않는다", arguments: [
        (CGFloat(748), CGFloat(548), CGFloat(200)), // iPhone 17 근사
        (CGFloat(830), CGFloat(548), CGFloat(220)), // 큰 화면은 원본 그대로
        (CGFloat(500), CGFloat(548), CGFloat(0)),   // 작은 화면은 음수가 되지 않는다
    ])
    func mapHeight(available: CGFloat, sheetMinimum: CGFloat, expected: CGFloat) {
        #expect(pickupMapHeight(available: available, sheetMinimum: sheetMinimum) == expected)
    }
}

private func geometryUser(rideCount: Int) -> User {
    User(id: "1", nickname: "모여타이", verifiedLabel: "", rating: 0, rideCount: rideCount)
}

private let geometryRide = Ride(
    id: "1", origin: "센텀시티역", destination: "서면역", departureLabel: "지금 출발",
    capacity: 3, members: [], farePerPerson: 3600, totalFare: 10800, status: .recruiting
)
