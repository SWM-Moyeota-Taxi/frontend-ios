import MoyeotaDesignSystem
import SwiftUI
import Testing
import UIKit
@testable import FeatureOnboarding

// 원본에 없는 테스트. 글자 잉크의 자리를 원본 렌더(상태바 아래 기준)에 맞춰 지킨다.
// 건너뛰기 줄이 시스템 글꼴 높이로 돌아가면 일러스트 카드가 약 3pt, 헤드라인 아래가 약 7pt 위로 올라간다.

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
@Suite(.serialized) struct OnboardingVisualParityTest {

    @Test("01 건너뛰기·일러스트·헤드라인·본문은 원본 렌더의 자리에 있다")
    func savingScreen() async {
        let window = await hosted(OnboardingSavingScreen(onNext: {}, onSkip: {}))
        defer { window.isHidden = true }
        let skip = inkBands(window, x: 300...390, y: (62 + 2)...(62 + 60))
        #expect(skip.count == 1)
        #expect(abs((skip.first?.top ?? 0) - (62 + 20.2)) < 1, "건너뛰기 \((skip.first?.top ?? 0) - 62)")
        // 원 윗자리 147.8, 헤드라인 445.7, 본문 첫 줄 491.8, 페이지 점 563.0
        let circle = inkBands(window, x: 100...300, y: (62 + 130)...(62 + 300))
        #expect(abs((circle.first?.top ?? 0) - (62 + 147.8)) < 1, "원 \((circle.first?.top ?? 0) - 62)")
        let copy = inkBands(window, x: 40...370, y: (62 + 430)...(62 + 580))
        #expect(copy.count == 4)
        #expect(abs(copy[0].top - (62 + 445.7)) < 1.2, "헤드라인 \(copy[0].top - 62)")
        #expect(abs(copy[1].top - (62 + 491.8)) < 1.5, "본문 \(copy[1].top - 62)")
        #expect(abs(copy[3].top - (62 + 563.0)) < 1.5, "페이지 점 \(copy[3].top - 62)")
    }
}
