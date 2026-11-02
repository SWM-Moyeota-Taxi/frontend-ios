import MoyeotaDesignSystem
import SwiftUI
import Testing
import UIKit
@testable import PresentationCore

// 원본에 없는 테스트. 스타일 없는 글자의 줄 상자와, 칸 가운데 놓이는 두 화면의 자리를 원본 렌더에 맞춰 지킨다.

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
@Suite(.serialized) struct LineBoxParityTest {

    @Test("스타일 없는 글자의 줄 상자는 16 이하에서 24 이고 그 위로는 한글 글꼴 상자다", arguments: [
        (CGFloat(13), CGFloat(24)), (15, 24), (22, 31.7),
    ])
    func inherited(fontSize: CGFloat, android: CGFloat) {
        let height = inheritedBodyLargeType(fontSize, .bold).lineHeightPoints ?? 0
        #expect(abs(height - android) < 0.1, "\(fontSize)sp: \(height) 대 \(android)")
    }

    @Test("업데이트 안내의 제목·본문·CTA 는 화면 가운데 기준으로 원본 렌더의 자리에 있다")
    func updateRequired() async {
        let window = await hosted(UpdateRequiredScreen())
        defer { window.isHidden = true }
        let bands = inkBands(window, x: 10...390, y: 300...600)
        #expect(bands.count == 4)
        // 원본: 제목 -77.7 ~ -56.8, 본문 첫 줄 -35.0, CTA +32.0 ~ +84.2
        #expect(abs(bands[0].top - 437 + 77.7) < 1, "제목 \(bands[0].top - 437)")
        #expect(abs(bands[1].top - 437 + 35.0) < 1, "본문 \(bands[1].top - 437)")
        #expect(abs(bands[3].top - 437 - 32.0) < 1, "CTA 위 \(bands[3].top - 437)")
        #expect(abs(bands[3].bottom - 437 - 84.2) < 1, "CTA 아래 \(bands[3].bottom - 437)")
    }

    @Test("시작 화면 제목은 화면 가운데 기준으로 원본 렌더의 자리에 있다")
    func splash() async {
        let window = await hosted(SplashScreen())
        defer { window.isHidden = true }
        let bands = inkBands(window, x: 150...260, y: 380...430)
        #expect(bands.count == 1)
        #expect(abs((bands.first?.top ?? 0) - 437 + 33.9) < 1, "제목 \((bands.first?.top ?? 0) - 437)")
    }
}

// MARK: - 커서

@MainActor
private func textField(in view: UIView) -> UITextField? {
    if let field = view as? UITextField { return field }
    for child in view.subviews {
        if let found = textField(in: child) { return found }
    }
    return nil
}

@MainActor
@Suite(.serialized) struct CaretPlacementTest {

    @Test("커서는 첫 자리에서 칸 왼쪽 끝, 글자가 있으면 글자 끝에서 시작한다")
    func caretStartsAtTextEnd() async throws {
        let style = MoyeotaType.BodyMd
        let window = await hosted(
            BasicTextField(value: "a", onValueChange: { _ in }, textStyle: style, singleLine: true)
                .frame(width: 200, height: 48)
        )
        defer { window.isHidden = true }
        let field = try #require(textField(in: window))
        field.becomeFirstResponder()
        window.layoutIfNeeded()
        defer { field.resignFirstResponder() }
        let start = field.caretRect(for: field.beginningOfDocument)
        let end = field.caretRect(for: field.endOfDocument)
        let advance = ("a" as NSString).size(withAttributes: [.font: style.uiFont, .kern: style.letterSpacing]).width
        #expect(abs(start.minX) < 0.5, "첫 자리 \(start.minX)")
        // 원본 10 「a」: 칸 왼쪽에서 8.0 에 커서가 시작한다. 재정의가 빠지면 1 왼쪽으로 가 글자에 붙는다.
        #expect(abs(end.minX - advance) < 0.5, "글자 끝 \(end.minX) 대 \(advance)")
    }
}
