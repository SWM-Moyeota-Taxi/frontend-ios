import MoyeotaDesignSystem
import SwiftUI
import Testing
import UIKit
@testable import FeatureMyPage

// 원본에 없는 테스트. 원본 렌더(UI 트리·스크린샷)에서 잰 값을 지킨다.

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

@MainActor
private func pixel(_ window: UIWindow, x: CGFloat, y: CGFloat) -> (r: UInt8, g: UInt8, b: UInt8) {
    var bytes = [UInt8](repeating: 0, count: 4)
    let context = CGContext(
        data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
    guard let context else { return (0, 0, 0) }
    context.translateBy(x: -x, y: -y)
    window.layer.render(in: context)
    return (bytes[0], bytes[1], bytes[2])
}

private func findScrollView(in view: UIView) -> UIScrollView? {
    if let scroll = view as? UIScrollView { return scroll }
    for child in view.subviews {
        if let found = findScrollView(in: child) { return found }
    }
    return nil
}

@MainActor
@Suite(.serialized) struct MyPageLineBoxTest {

    @Test("머티리얼 글자의 줄 상자는 16 이하에서 24 이고 그 위로는 원본 UI 트리의 높이를 따른다", arguments: [
        (CGFloat(11), CGFloat(24)), (12, 24), (13, 24), (15, 24), (18, 26.3), (20, 28.5), (24, 34.6),
    ])
    func bodyLarge(fontSize: CGFloat, android: CGFloat) {
        let height = MaterialTextStyle.bodyLarge(fontSize: fontSize, fontWeight: .bold).lineHeightPoints ?? 0
        #expect(abs(height - android) < 0.5, "\(fontSize)sp: \(height) 대 \(android)")
    }

    private func textHeight(_ text: String, _ style: MoyeotaType) -> CGFloat {
        UIHostingController(rootView: Text(text).moyeotaText(style).fixedSize())
            .sizeThatFits(in: CGSize(width: 400, height: 400)).height
    }

    @Test("토큰의 한 줄 상자는 지정 줄 높이가 아니라 한글 글꼴 상자다", arguments: [
        (MoyeotaType.CaptionMd, CGFloat(17.1)), (.BodySm, 18.7), (.HeadingMd, 23.2), (.HeadingLg, 26.2),
    ])
    func trimmedSingleLine(style: MoyeotaType, android: CGFloat) {
        let height = textHeight("탈퇴하면", style.hangulTrimmed)
        #expect(abs(height - android) < 0.5, "\(style.fontSize)sp: \(height) 대 \(android)")
    }

    @Test("줄 간격은 지정 줄 높이다. 37 둘째 경고 두 줄 = 38.4")
    func trimmedTwoLines() {
        let height = textHeight("참여 중인\n함께 탄", MoyeotaType.BodySm.hangulTrimmed)
        #expect(abs(height - 38.4) < 0.5, "\(height)")
    }

    @Test("고르지 않은 토큰은 그대로다 — 다른 화면이 이 값 위에서 맞춰져 있다")
    func untouchedTokens() {
        #expect(abs(textHeight("탈퇴하면", .BodySm) - 19.5) < 0.4)
        #expect(abs(textHeight("탈퇴하면", .HeadingMd) - 21.6) < 0.4)
    }

    @Test("34 카드 하나의 글자 줄이 원본 UI 트리와 같다")
    func historyCardRows() {
        // 원본: 날짜 17.1 + 6 + 경로 23.2 + 10 + 아바타 28 + 12 + 선 1 + 12 + 요금 23.2 + 위아래 32 = 165.3(렌더 165.3)
        let rows = textHeight("10월 30일 오후 2:00", MoyeotaType.CaptionMd.hangulTrimmed)
            + textHeight("교대역 → 홍대입구역", MoyeotaType.HeadingMd.hangulTrimmed) * 2
        #expect(abs(rows + 101 - 165.3) < 1.5, "\(rows)")
    }
}

@MainActor
@Suite(.serialized) struct MaterialDialogGeometryTest {

    /// 카드 안쪽 세로줄에서 가장 긴 흰 구간.
    private func cardRows(_ window: UIWindow, x: CGFloat) -> (top: Int, bottom: Int) {
        let white = (0..<874).filter {
            let c = pixel(window, x: x, y: CGFloat($0))
            return min(c.r, c.g, c.b) > 250
        }
        let longest = white.reduce(into: [[Int]]()) { runs, y in
            if let last = runs.last?.last, last == y - 1 { runs[runs.count - 1].append(y) } else { runs.append([y]) }
        }.max { $0.count < $1.count } ?? []
        return (longest.first ?? 0, (longest.last ?? 0) + 1)
    }

    private func cardWidth(_ window: UIWindow, y: Int) -> CGFloat {
        let xs = (0..<402).filter {
            let c = pixel(window, x: CGFloat($0), y: CGFloat(y))
            return min(c.r, c.g, c.b) > 250
        }
        return CGFloat((xs.last ?? 0) + 1 - (xs.first ?? 0))
    }

    @Test("37 확인창은 본문이 접혀 폭 320 이고 시스템 바를 뺀 영역의 가운데에 놓인다")
    func deleteConfirm() async {
        let window = await hosted(AccountDeleteScreen(password: "").seeded(confirming: true))
        defer { window.isHidden = true }
        let rows = cardRows(window, x: 60)
        #expect(rows.bottom - rows.top > 100, "카드를 찾아야 시험이 된다")
        // (62 + (874 − 34)) / 2 = 451. 화면 가운데(437)가 아니다.
        #expect(abs(CGFloat(rows.top + rows.bottom) / 2 - 451) < 1, "\(rows)")
        #expect(abs(cardWidth(window, y: rows.top + 40) - 320) < 1)
    }

    @Test("35 확인창은 내용이 상한보다 짧아 내용 폭이다")
    func logoutConfirm() async {
        let window = await hosted(MyPageScreen().seeded(logoutConfirming: true))
        defer { window.isHidden = true }
        let rows = cardRows(window, x: 70)
        #expect(rows.bottom - rows.top > 100, "카드를 찾아야 시험이 된다")
        #expect(abs(CGFloat(rows.top + rows.bottom) / 2 - 451) < 1, "\(rows)")
        let width = cardWidth(window, y: rows.top + 40)
        #expect(width > 280 && width < 319, "\(width)")
    }

    @Test("37 본문은 원본과 같은 자리에서 꺾인다")
    func deleteBodyBreak() {
        let lines = MoyeotaType.BodySm.hangulTrimmed.softWrappedLines(
            "탈퇴하면 계정과 저장한 정보가 사라지고 되돌릴 수 없어요",
            width: 272
        )
        #expect(lines.wrapped)
        #expect(lines.text == "탈퇴하면 계정과 저장한 정보가 사라지고 되돌릴 수\n없어요")
    }
}

@MainActor
@Suite(.serialized) struct ScrollClipTest {

    @Test("35 를 스크롤해도 내용이 상태바 자리에 그려지지 않는다")
    func myPageStaysBelowStatusBar() async throws {
        let window = await hosted(MyPageScreen())
        defer { window.isHidden = true }
        let scroll = try #require(findScrollView(in: window))
        scroll.setContentOffset(CGPoint(x: 0, y: 140), animated: false)
        for _ in 0..<6 {
            window.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(25))
        }
        // 카드 흰색(255)이 상태바 자리까지 올라오면 바탕색 F5F7FA 와 달라진다. 카드가 지나가는 x 를 세로로 훑는다.
        let drawn = (0..<62).filter {
            let c = pixel(window, x: 200, y: CGFloat($0))
            return c.r != 0xF5 || c.g != 0xF7 || c.b != 0xFA
        }
        #expect(drawn.isEmpty, "상태바 자리에 그려진 줄: \(drawn)")
    }
}
