import NMapsMap
import UIKit

/// 축척 바에 적을 값과 막대 길이. 안드로이드 `ScaleBarView.a(NaverMap)`(SDK 3.23.3 바이트코드)를 옮겼다.
///
/// 기준 폭 80 안에 들어가는 가장 큰 1·2·5×10ⁿ 를 고른다. iOS `NMFScaleView` 는 기준이 100pt 라 같은 지도에서
/// 다른 값을 고른다(20 합류 확인: 원본 5km·42pt, `NMFScaleView` 10km·85pt). 값을 바꿀 공개 API 가 없어 직접 그린다.
struct ScaleBarSpec: Equatable {
    /// 막대 끝에 적는 글자. 「5」 + 「km」
    let value: String
    let unit: String
    let length: CGFloat

    private static let baseWidth = 80.0

    /// 지도가 레이아웃되기 전에는 `metersPerPoint` 가 0·NaN 이라 nil 이다. 이때는 아무것도 그리지 않는다.
    init?(metersPerPoint: Double) {
        let meters = metersPerPoint * Self.baseWidth
        guard meters.isFinite, meters >= 1 else { return nil }
        let digits = Int(floor(log10(meters))) + 1
        let magnitude = Int(pow(10, Double(digits - 1)))
        let leading = Int(meters / Double(magnitude))
        let step = [5, 2, 1].first { leading >= $0 } ?? 1
        let total = step * magnitude
        value = String(digits >= 4 ? total / 1000 : total)
        unit = digits >= 4 ? "km" : "m"
        length = CGFloat(Double(total) / metersPerPoint)
    }
}

/// 축척 바 컨트롤. 치수는 안드로이드 `navermap_scale_bar_view.xml`·`navermap_scale_bar_light.9.png` 값이다
/// (오른쪽 정렬: 막대 위 오른쪽 끝에 「0」, 왼쪽 끝에 값).
final class ScaleBarControl: UIView, @preconcurrency NMFMapViewCameraDelegate {
    /// 원본 뷰의 높이. 글자가 막대 왼쪽으로 삐져나와도 잘리지 않게 뷰 자체는 더 크게 잡고 아래쪽 이만큼에 그린다.
    private static let contentHeight: CGFloat = 16
    private static let ink = UIColor(red: 0x44 / 255.0, green: 0x44 / 255.0, blue: 0x44 / 255.0, alpha: 1)
    private static let font = UIFont.systemFont(ofSize: 9)

    private weak var mapView: NMFMapView?
    private var spec: ScaleBarSpec?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func attach(to mapView: NMFMapView) {
        self.mapView = mapView
        mapView.addCameraDelegate(delegate: self)
        update()
    }

    func detach() {
        mapView?.removeCameraDelegate(delegate: self)
        mapView = nil
    }

    private func update() {
        guard let mapView else { return }
        let next = ScaleBarSpec(metersPerPoint: mapView.projection.metersPerPixel())
        guard next != spec else { return }
        spec = next
        setNeedsDisplay()
    }

    func mapView(_ mapView: NMFMapView, cameraWillChangeByReason reason: Int, animated: Bool) {
        update()
    }

    func mapView(_ mapView: NMFMapView, cameraIsChangingByReason reason: Int) {
        update()
    }

    func mapView(_ mapView: NMFMapView, cameraDidChangeByReason reason: Int, animated: Bool) {
        update()
    }

    override func draw(_ rect: CGRect) {
        guard let spec, let context = UIGraphicsGetCurrentContext() else { return }
        let top = bounds.height - Self.contentHeight
        let right = bounds.width
        let scale = window?.screen.scale ?? traitCollection.displayScale
        // 원본은 막대 길이를 정수 픽셀로 자른다.
        let length = (spec.length * scale).rounded(.down) / scale
        let inkRight = right - 2
        let inkLeft = inkRight - length

        // 막대 — 9-patch 그대로: 잉크 둘레 1 은 흰색 50%, 눈금 사이 위쪽은 비어 있다
        let edges = [inkLeft, inkRight - 1]
        context.setFillColor(UIColor.white.withAlphaComponent(0.5).cgColor)
        var halo = edges.map { CGRect(x: $0 - 1, y: top + 10, width: 3, height: 6) }
        let bandLeft = inkLeft + 2
        let bandRight = inkRight - 2
        if bandRight > bandLeft {
            halo.append(CGRect(x: bandLeft, y: top + 13, width: bandRight - bandLeft, height: 3))
        }
        context.fill(halo)
        context.setFillColor(Self.ink.cgColor)
        context.fill(edges.map { CGRect(x: $0, y: top + 11, width: 1, height: 4) })
        context.fill(CGRect(x: inkLeft, y: top + 14, width: length, height: 1))

        // 글자 — 원본 `OutlinedTextView`: 흰 외곽선 1 위에 글자. 값과 단위는 막대 왼쪽 끝 + 2 에서 만난다
        let baseline = top + 9.5
        let meet = right - length
        let zero = text("0")
        drawOutlined(zero, at: CGPoint(x: right - 2.5 - zero.width / 2, y: baseline), in: context)
        let value = text(spec.value)
        drawOutlined(value, at: CGPoint(x: meet - value.width, y: baseline), in: context)
        drawOutlined(text(spec.unit), at: CGPoint(x: meet, y: baseline), in: context)
    }

    private func text(_ string: String) -> (string: String, width: CGFloat) {
        let width = (string as NSString).size(withAttributes: [.font: Self.font]).width
        return (string, width)
    }

    private func drawOutlined(
        _ text: (string: String, width: CGFloat),
        at baseline: CGPoint,
        in context: CGContext
    ) {
        let origin = CGPoint(x: baseline.x, y: baseline.y - Self.font.ascender)
        // 양수 strokeWidth 는 글꼴 크기의 퍼센트이고 외곽선만 그린다.
        (text.string as NSString).draw(at: origin, withAttributes: [
            .font: Self.font,
            .strokeColor: UIColor.white,
            .strokeWidth: 100.0 / Self.font.pointSize,
        ])
        (text.string as NSString).draw(at: origin, withAttributes: [
            .font: Self.font,
            .foregroundColor: Self.ink,
        ])
    }
}
