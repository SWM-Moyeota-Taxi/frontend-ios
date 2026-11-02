import CoreText
import MoyeotaDesignSystem
import SwiftUI
import Testing
import UIKit
@testable import FeatureChat

// 원본에 없는 테스트. 원본 렌더(UI 트리·스크린샷)에서 잰 값과 관찰한 동작을 지킨다.

private final class InsetWindow: UIWindow {
    override var safeAreaInsets: UIEdgeInsets { UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0) }
}

@Suite struct BodyLargeLineHeightTest {

    @Test("줄 상자는 16 이하에서 24 이고 그 위로는 원본 UI 트리의 높이를 따른다", arguments: [
        (CGFloat(11), CGFloat(24)), (12, 24), (13, 24), (14, 24), (15, 24),
        (17, 24.4), (18, 26.2), (20, 28.5), (26, 37.5),
    ])
    func matchesAndroidLineBox(fontSize: CGFloat, androidHeight: CGFloat) {
        let height = bodyLargeText(fontSize, .bold).lineHeightPoints ?? 0
        #expect(abs(height - androidHeight) < 0.5, "\(fontSize)sp: \(height) 대 \(androidHeight)")
    }
}

@Suite struct BodyLargeInkTest {

    @Test("16 이하는 잉크를 내리지 않고, 줄 상자가 24 를 넘는 크기부터 글자 크기 × 0.06 내린다", arguments: [
        (CGFloat(12), CGFloat(0)), (14, 0), (15, 0), (17, 1.02), (18, 1.08), (20, 1.2), (26, 1.56),
    ])
    func dropsInkLikeAndroid(fontSize: CGFloat, drop: CGFloat) {
        #expect(abs(bodyLargeText(fontSize, .bold).inkDrop - drop) < 0.01)
    }

    @Test("잉크를 내려도 줄 상자 높이는 그대로다")
    func boxUnchanged() {
        let type = bodyLargeText(26, .bold)
        let box = type.uiFont.lineHeight + type.edgePadding * 2
        #expect(abs(box - 37.44) < 0.01)
    }

    @Test("24 나가기·신고 시트 제목과 본문은 원본 토큰의 한글 상자를 쓴다")
    func dialogTokensAreTrimmed() {
        #expect(ChatDialogTitleType.trimsToHangulLineBox)
        #expect(ChatDialogTitleType.fontSize == 16)
        #expect(ChatDialogTitleType.fontWeight == .semibold)
    }
}

/// 폭은 양쪽 다 잉크 폭이다. 원본은 렌더 스크린샷에서 쟀고, 여기서는 글리프 윤곽으로 잰다.
@Suite struct BodyLargeWidthTest {

    private func width(_ text: String, _ type: MoyeotaType) -> CGFloat {
        let string = NSAttributedString(string: text, attributes: [.font: type.uiFont, .kern: type.letterSpacing])
        return CTLineGetBoundsWithOptions(CTLineCreateWithAttributedString(string), .useGlyphPathBounds).width
    }

    @Test("말풍선 밖 글자 폭도 원본 렌더의 폭과 1.5pt 안쪽으로 맞는다", arguments: [
        ("괜찮으세요?", CGFloat(26), Font.Weight.bold, CGFloat(134.1)),
        ("판교역 신분당선까지 약 38분", 20, .bold, 244.6),
        ("역삼직장인 · 선릉출근러", 18, .bold, 182.1),
        ("112와 실제로 통화하셨나요?", 18, .bold, 218.7),
        ("3초간 길게 눌러 신고", 17, .bold, 149.0),
        ("강남역 2호선 → 판교역 신분당선", 15, .bold, 209.9),
        ("역삼직장인 · 선릉출근러", 14, .bold, 140.6),
        ("신고하면 현재 위치와 운행 정보가 운영팀에 전달되고,", 14, .regular, 313.1),
        ("실제 통화 여부는 운영팀 대응에 사용돼요", 13, .regular, 225.1),
        ("네 챙겼어요! 차가 많이 막힐까요", 12, .medium, 167.2),
        ("3초를 채우면 즉시 112 통화 화면이 열려요", 12, .medium, 222.5),
    ])
    func matchesAndroidRender(text: String, fontSize: CGFloat, weight: Font.Weight, androidWidth: CGFloat) {
        let measured = width(text, bodyLargeText(fontSize, weight))
        #expect(abs(measured - androidWidth) < 1.5, "\(text): \(measured) 대 \(androidWidth)")
    }

    @Test("24 나가기 확인 제목 폭이 원본과 맞는다")
    func dialogTitle() {
        let measured = width("채팅방을 나갈까요?", ChatDialogTitleType)
        #expect(abs(measured - 128.8) < 1.5, "\(measured)")
    }

    @Test("11 은 자간을 더하지 않는다(시각·날짜의 SF 숫자가 이미 넓다)")
    func timesStayAtBase() {
        #expect(bodyLargeText(11, .medium).letterSpacing == 0.5)
    }

    @Test("말풍선은 표의 14 값을 쓴다")
    func bubbleUsesTable() {
        #expect(abs(BubbleTextType.letterSpacing - 0.8) < 0.001)
    }
}

@Suite struct CharacterWrapTest {

    @Test("한글 사이와 한글·숫자 사이에 폭 없는 공백이 들어가고 원문은 그대로 복원된다")
    func marksBreaks() {
        let text = "5분이면 될 것 같아요"
        let marked = text.characterWrapped
        #expect(marked == "5\u{200B}분\u{200B}이\u{200B}면 될 것 같\u{200B}아\u{200B}요")
        #expect(marked.replacingOccurrences(of: "\u{200B}", with: "") == text)
    }

    @Test("문장부호 앞과 영문 단어 안은 꺾지 않는다")
    func keepsPunctuationAndWords() {
        #expect("요?".characterWrapped == "요?")
        #expect("hello world".characterWrapped == "hello world")
        #expect("「가」".characterWrapped == "「가」")
    }

    @Test("한 줄에 들어가면 그대로이고 폭은 줄지 않는다")
    func shortTextStaysOneLine() {
        let wrap = BubbleTextType.softWrappedLines("네 반갑습니다 :)", width: BubbleTextMaxWidth)
        #expect(wrap == SoftWrappedText(text: "네 반갑습니다 :)", wrapped: false))
    }

    @Test("줄 끝까지 채우고 마지막 한 글자도 다음 줄로 넘긴다", arguments: [
        ("오늘 비 온다고 하던데 우산 챙기셨어요?", "오늘 비 온다고 하던데 우산 챙기셨어\n요?"),
        ("저도 곧 도착해요. 5분이면 될 것 같아요", "저도 곧 도착해요. 5분이면 될 것 같아\n요"),
    ])
    func wrapsLikeAndroidRender(text: String, expected: String) {
        let wrap = BubbleTextType.softWrappedLines(text, width: BubbleTextMaxWidth)
        #expect(wrap == SoftWrappedText(text: expected, wrapped: true))
    }

    @Test("말풍선 글자 폭은 원본 UI 트리의 폭과 2pt 안쪽으로 맞는다", arguments: [
        ("네 챙겼어요! 차가 많이 막힐까요", CGFloat(190.5)),
        ("좋아요, 스타벅스 앞으로 갈게요", 186.3),
        ("스타벅스 앞에서 모일까요?", 158.9),
        ("저는 강남역 11번 출구 쪽에 있어요", 205.7),
    ])
    func widthMatchesAndroidTree(text: String, androidWidth: CGFloat) {
        let width = NSAttributedString(
            string: text,
            attributes: [.font: BubbleTextType.uiFont, .kern: BubbleTextType.letterSpacing]
        ).size().width
        #expect(abs(width - androidWidth) < 2, "\(text): \(width) 대 \(androidWidth)")
    }

    @Test("글 안의 줄바꿈은 꺾인 줄로 세지 않는다")
    func hardBreaksAreNotSoftWraps() {
        let wrap = BubbleTextType.softWrappedLines("가\n나\n", width: BubbleTextMaxWidth)
        #expect(wrap == SoftWrappedText(text: "가\n나\n", wrapped: false))
    }
}

@MainActor
@Suite struct ChatScrollTrackerOpenTest {

    @Test("탭에서 연 방은 처음부터 바닥을 따라간다")
    func tabFollows() {
        let tracker = ChatScrollTracker()
        #expect(tracker.shouldFollow(maxScroll: 0))
        #expect(tracker.shouldFollow(maxScroll: 2_000))
    }

    @Test("독립 목적지는 넘치는 첫 내용에서 움직이지 않고 따라가기를 끈다")
    func destinationDetaches() {
        let tracker = ChatScrollTracker(followsBottomOnOpen: false)
        #expect(!tracker.shouldFollow(maxScroll: 0), "첫 내용 전에는 움직일 이유가 없다")
        #expect(!tracker.shouldFollow(maxScroll: 2_000))
        #expect(!tracker.shouldFollow(maxScroll: 2_060), "새 메시지가 와도 그대로다")
    }

    @Test("독립 목적지도 슬롭 안으로 넘치면 바닥을 따라간다")
    func destinationFollowsWhenShort() {
        let tracker = ChatScrollTracker(followsBottomOnOpen: false)
        #expect(tracker.shouldFollow(maxScroll: 100))
        #expect(tracker.shouldFollow(maxScroll: 2_000))
    }

    @Test("독립 목적지에서 바닥까지 내려가 멈추면 다시 따라간다")
    func destinationReattaches() async {
        let tracker = ChatScrollTracker(followsBottomOnOpen: false)
        tracker.viewportHeight = 500
        #expect(!tracker.shouldFollow(maxScroll: 2_000))
        tracker.scrolled(to: ChatScrollMetrics(top: 0, bottom: 2_500))
        tracker.scrolled(to: ChatScrollMetrics(top: -2_000, bottom: 500))
        try? await Task.sleep(for: .milliseconds(400))
        #expect(tracker.shouldFollow(maxScroll: 2_060))
    }
}

@MainActor
@Suite(.serialized) struct CallConfirmDialogGeometryTest {

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

    @Test("27 통화 여부 다이얼로그는 폭 320 이고 시스템 바를 뺀 영역의 가운데에 놓인다")
    func widthAndPosition() async {
        let window = InsetWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UIHostingController(
            rootView: CallConfirmDialog(saving: false, errorText: nil, onCalled: {}, onNotCalled: {}, onLater: {})
                .ignoresSafeArea(.container)
        )
        window.isHidden = false
        defer { window.isHidden = true }
        for _ in 0..<12 {
            window.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(25))
        }
        // 카드 왼쪽 안쪽 여백(22) 세로줄에서 흰 구간을 찾는다.
        let white = (0..<874).filter { brightness(window, x: 52, y: CGFloat($0)) > 0.98 }
        #expect(white.count > 100, "카드를 찾아야 시험이 된다")
        let top = white.first ?? 0
        let bottom = (white.last ?? 0) + 1
        // (62 + (874 − 34)) / 2 = 451. 화면 가운데(437)가 아니다.
        #expect(abs(CGFloat(top + bottom) / 2 - 451) < 1, "카드 \(top)…\(bottom)")

        let xs = (0..<402).filter { brightness(window, x: CGFloat($0), y: CGFloat(top + 22)) > 0.98 }
        let width = CGFloat((xs.last ?? 0) + 1 - (xs.first ?? 0))
        #expect(abs(width - 320) < 1, "카드 폭 \(width)")
    }
}
