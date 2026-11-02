import MoyeotaDesignSystem
import SwiftUI
import Testing
import UIKit

// 원본에 없는 테스트. 원본 `Column` 은 부모 높이를 넘지 않게 재고 자식을 위에서부터 쌓아, 시트가 지도 영역보다 길면
// **아래쪽 푸터만** 잘린다. 창에 올려 실제 배치를 읽는다.

@MainActor
private final class SheetProbe {
    var top: CGRect?
    var footer: CGRect?
    var sheetHeight: CGFloat?
}

private let LongFooterText = String(repeating: "방장의 합승 완료 요청이 실패했어요 잠시 후 다시 시도해 주세요 ", count: 16)

private struct OverflowHarness: View {
    let probe: SheetProbe
    let containerHeight: CGFloat
    var footerText = LongFooterText

    var body: some View {
        MapSheetScaffold(
            mapRevealHeight: 160,
            collapsedSheetHeight: 176,
            background: { sheet in
                Color.clear.onChange(of: sheet.sheetHeight, initial: true) { _, height in
                    probe.sheetHeight = height
                }
            },
            sheetTop: {
                Color.red
                    .frame(height: 60)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("probe")) } action: { probe.top = $0 }
            },
            sheetDetail: {
                Color.blue.frame(height: 40)
            },
            sheetFooter: {
                Text(footerText)
                    .moyeotaText(.BodyMd, color: MoyeotaColor.InkPrimary)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("probe")) } action: { probe.footer = $0 }
            }
        )
        .frame(width: 393, height: containerHeight)
        .coordinateSpace(name: "probe")
    }
}

private func scrollViews(in view: UIView) -> [UIScrollView] {
    ((view as? UIScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) }
}

@MainActor
private func measure(containerHeight: CGFloat, footerText: String = LongFooterText) async -> SheetProbe {
    let probe = SheetProbe()
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
    window.rootViewController = UIHostingController(rootView: OverflowHarness(probe: probe, containerHeight: containerHeight, footerText: footerText))
    window.isHidden = false
    defer { window.isHidden = true }
    for _ in 0..<40 {
        window.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(25))
    }
    return probe
}

@MainActor
@Suite(.serialized) struct MapSheetOverflowTest {

    /// 핸들 줄(위아래 12 + 핸들) 다음에 top 이 온다. 컨테이너 위로 넘치면 음수로 나온다.
    @Test("시트가 넘치면 위가 아니라 아래쪽 푸터만 잘린다")
    func overflowKeepsTopAligned() async throws {
        let short = await measure(containerHeight: 400)
        let top = try #require(short.top)
        let footer = try #require(short.footer)

        #expect(top.minY >= 0, "시트 위쪽이 컨테이너 밖으로 넘쳤다: \(top)")
        #expect(top.minY < 40, "핸들 줄 바로 아래여야 한다: \(top)")
        #expect(footer.maxY > 400, "이 높이면 푸터 아래쪽이 넘쳐야 시험이 된다: \(footer)")
        #expect(abs(footer.minY - (top.maxY + 64)) < 1, "top → 상세(detailMax 64) → 푸터 순으로 쌓인다")
    }

    @Test("넘쳐도 푸터 글자는 줄어들지 않는다")
    func overflowDoesNotShrinkFooter() async throws {
        let short = try #require(await measure(containerHeight: 400).footer)
        let natural = UIHostingController(rootView: Text(LongFooterText).moyeotaText(.BodyMd))
            .sizeThatFits(in: CGSize(width: 393, height: 5000))

        #expect(abs(short.height - natural.height) < 1, "시트 안 \(short.height), 글자 본래 높이 \(natural.height)")
    }

    /// 원본 `onSizeChanged` 는 부모에 맞춰 잰 Column 높이를 받는다. 지도 위 플로팅 버튼이 이 값으로 자리를 잡는다.
    @Test("넘치면 실측 높이는 컨테이너 높이다")
    func overflowReportsContainerHeight() async throws {
        let height = try #require(await measure(containerHeight: 400).sheetHeight)
        #expect(abs(height - 400) < 1, "실측 \(height)")
    }

    /// 원본 `verticalScroll` 은 스크롤 막대를 그리지 않는다. 호출부가 따로 끄지 않아도 꺼져 있어야 한다.
    @Test("상세 영역의 스크롤 막대는 호출부 설정 없이 꺼져 있다")
    func detailHidesScrollIndicators() async throws {
        let probe = SheetProbe()
        let host = UIHostingController(rootView: OverflowHarness(probe: probe, containerHeight: 850))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        for _ in 0..<40 where scrollViews(in: host.view).isEmpty {
            window.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(25))
        }

        let scroll = try #require(scrollViews(in: host.view).first)
        #expect(!scroll.showsVerticalScrollIndicator)
    }

    @Test("넘치지 않으면 시트는 콘텐츠 높이이고 아래에 붙는다")
    func fitsAtBottom() async throws {
        let tall = await measure(containerHeight: 850, footerText: "짧은 푸터")
        let footer = try #require(tall.footer)

        #expect(abs(footer.maxY - 850) < 1, "푸터가 시트 바닥에 붙는다: \(footer)")
        #expect(try #require(tall.sheetHeight) < 850, "시트는 콘텐츠 높이다")
    }
}
