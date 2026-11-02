import SwiftUI
import Testing
import UIKit
@testable import MoyeotaDesignSystem

/// 원본에 없는 테스트. iOS SDK 기본 아이콘의 후광을 지우는 계산을 그림으로 잰다. 실제 SDK 그림은 렌더로 확인했다.
@MainActor
@Suite struct LocationOverlayIconTest {

    private func icon(haloAlpha: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = false
        let side: CGFloat = 88
        func circle(_ radius: CGFloat) -> CGRect {
            CGRect(x: side / 2 - radius, y: side / 2 - radius, width: radius * 2, height: radius * 2)
        }
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            context.cgContext.setFillColor(UIColor.blue.withAlphaComponent(haloAlpha).cgColor)
            context.cgContext.fillEllipse(in: circle(18))
            context.cgContext.setBlendMode(.copy)
            context.cgContext.setFillColor(UIColor.white.cgColor)
            context.cgContext.fillEllipse(in: circle(8))
            context.cgContext.setFillColor(UIColor.blue.cgColor)
            context.cgContext.fillEllipse(in: circle(5))
        }
    }

    /// 그림 중심에서 오른쪽으로 `pointsFromCenter` 떨어진 자리의 불투명도 0…255.
    private func alpha(_ image: UIImage, pointsFromCenter: CGFloat) -> UInt8 {
        guard let source = image.cgImage else { return 0 }
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        let x = CGFloat(source.width) / 2 + pointsFromCenter * image.scale
        let y = CGFloat(source.height) / 2
        context?.draw(source, in: CGRect(x: -x, y: -y, width: CGFloat(source.width), height: CGFloat(source.height)))
        return pixel[3]
    }

    @Test("후광은 지우고 점과 테두리는 남긴다")
    func removesHalo() throws {
        let original = icon(haloAlpha: 0.1)
        #expect(alpha(original, pointsFromCenter: 15) > 0, "후광이 있어야 시험이 된다")

        let result = try #require(removingFlatHalo(from: original))
        #expect(alpha(result, pointsFromCenter: 15) == 0)
        #expect(alpha(result, pointsFromCenter: 6.5) == 255)
        #expect(alpha(result, pointsFromCenter: 0) == 255)
        #expect(result.scale == original.scale)
        #expect(result.size == original.size)
    }

    @Test("후광이 없는 그림은 그대로 둔다")
    func keepsImageWithoutHalo() throws {
        let original = icon(haloAlpha: 0)
        #expect(try #require(removingFlatHalo(from: original)) === original)
    }
}
