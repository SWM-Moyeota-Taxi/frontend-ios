import MoyeotaDesignSystem
import SwiftUI
import Testing
import UIKit
@testable import FeatureAuth

// 원본에 없는 테스트. 글자 잉크의 자리를 원본 렌더(상태바 아래 기준)에 맞춰 지킨다.
// 토큰이 지정 줄 높이로 돌아가면 제목 아래가 약 3pt 위로 올라가고, 잉크를 내리지 않으면 제목이 약 1.5pt 위에 그려진다.

/// 씬이 없는 창에는 안전 영역이 없다. 실기 값(iPhone 17: 위 62, 아래 34)을 흉내 낸다.
private final class InsetWindow: UIWindow {
    override var safeAreaInsets: UIEdgeInsets { UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0) }
}

@MainActor
private func hosted<V: View>(_ view: V) async -> UIWindow {
    let window = InsetWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
    window.rootViewController = UIHostingController(rootView: view.ignoresSafeArea(.container))
    window.isHidden = false
    for _ in 0..<12 {
        window.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(25))
    }
    return window
}

/// `x` 범위 안에서 줄의 왼쪽 끝 색과 다른 픽셀이 있는 연속한 줄들의 (위, 아래). pt 단위.
@MainActor
private func inkBands(_ window: UIWindow, x: ClosedRange<CGFloat>, y: ClosedRange<CGFloat>) -> [(top: CGFloat, bottom: CGFloat)] {
    let scale: CGFloat = 3
    let width = Int(window.bounds.width * scale)
    let height = Int(window.bounds.height * scale)
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    bytes.withUnsafeMutableBytes { raw in
        guard let context = CGContext(
            data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        window.layer.render(in: context)
    }
    var bands: [(top: CGFloat, bottom: CGFloat)] = []
    var start: Int?
    for row in Int(y.lowerBound * scale)..<Int(y.upperBound * scale) {
        let base = row * width * 4
        let first = base + Int(x.lowerBound * scale) * 4
        let ink = (Int(x.lowerBound * scale)..<Int(x.upperBound * scale)).contains { column in
            let at = base + column * 4
            return (0..<3).contains { abs(Int(bytes[at + $0]) - Int(bytes[first + $0])) > 14 }
        }
        if ink, start == nil { start = row }
        if !ink, let begin = start {
            bands.append((CGFloat(begin) / scale, CGFloat(row) / scale))
            start = nil
        }
    }
    return bands
}

@MainActor
@Suite(.serialized) struct AuthVisualParityTest {

    @Test("04a 제목과 부제목 잉크는 원본 렌더의 자리에 있다")
    func loginFormHeadline() async {
        let window = await hosted(LoginFormScreen())
        defer { window.isHidden = true }
        // 잉크 폭 때문에 위쪽을 잰다. 원본 87.6, 128.8 (상태바 48.76 아래)
        let bands = inkBands(window, x: 16...300, y: (62 + 70)...(62 + 150))
        #expect(bands.count == 2)
        #expect(abs(bands[0].top - (62 + 87.6)) < 1, "제목 \(bands[0].top - 62)")
        #expect(abs(bands[1].top - (62 + 128.8)) < 1, "부제목 \(bands[1].top - 62)")
    }

    @Test("04 첫 줄 위 잉크와 카드 위치는 원본 렌더의 자리에 있다")
    func loginHeadline() async {
        let window = await hosted(LoginScreen(onEmailStart: {}, onLogin: {}))
        defer { window.isHidden = true }
        let bands = inkBands(window, x: 16...300, y: (62 + 80)...(62 + 200))
        #expect(bands.count == 3)
        #expect(abs(bands[0].top - (62 + 92.2)) < 1, "헤드라인 \(bands[0].top - 62)")
        #expect(abs(bands[2].top - (62 + 180.2)) < 1, "부제목 \(bands[2].top - 62)")
    }

    @Test("13 제목과 안내 머리말 잉크는 원본 렌더의 자리에 있다")
    func signupCompleteHeadline() async {
        let window = await hosted(SignupCompleteScreen(onStart: {}))
        defer { window.isHidden = true }
        let bands = inkBands(window, x: 16...300, y: (62 + 220)...(62 + 360))
        #expect(bands.count == 3)
        #expect(abs(bands[0].top - (62 + 232.0)) < 1, "제목 \(bands[0].top - 62)")
        #expect(abs(bands[2].top - (62 + 335.2)) < 1, "머리말 \(bands[2].top - 62)")
    }
}
