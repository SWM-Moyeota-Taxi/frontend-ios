import SwiftUI
import UIKit

/// 덮여 있는 칸을 그리지 않는 문. 원본 NavHost 는 **맨 위 엔트리만** 컴포지션에 둔다.
///
/// 평소에는 필요 없다. 화면이 하나씩 쌓이면 SwiftUI 가 덮인 화면에 `onDisappear` 를 부르고, 그것으로 `lifecycleEffect`·
/// `moyeotaBackHandler`·`.task` 가 멈춘다. 문제는 **창 밖에서 처음 만들어지는 칸**이다. SwiftUI 는 창에 없는 호스팅 뷰에도
/// `onAppear` 를 부르는데, 화면에 오른 적이 없으니 짝이 되는 `onDisappear` 는 오지 않는다. 그런 칸은 두 가지다.
///
/// - 탭 스택 복원(`restoreState`): 여러 칸이 한 갱신에 경로로 들어온다. 문이 없으면 24 아래의 21 이 가로채기를 걸어 24 의
///   스와이프가 홈으로 가고, 폴링과 SSE 를 돌리다 배차 전이를 보면 읽고 있던 채팅방을 걷어낸다.
/// - 쌓인 화면이 빠지면서 바뀌는 탭 뿌리(단독 24 → 하단탭): 새 뿌리가 창 밖에서 만들어져 시작·정지·시작을 겪고,
///   목록을 두 번 읽고 채팅 소켓을 끊었다 다시 붙인다.
///
/// 그래서 그런 칸은 내용을 만들지 않고 있다가 **호스팅 뷰가 창에 들어와 스택 맨 위일 때** 연다. 내비게이션 상태만 보지 않는 이유는
/// 둘이다. 경로가 바뀐 시점의 뷰는 아직 창 밖이라 똑같이 시작·정지·시작을 겪고, 스와이프는 경로가 바뀌기 전에 아래 화면을
/// 드러내므로 끝날 때까지 빈 화면이 보인다. 창만 보지도 않는다. 복원 때 뿌리 호스팅 뷰는 밀기 전환이 끝날 때까지 창에 남아 있다.
///
/// 한 번 연 칸은 닫지 않는다. 그 뒤로는 일반 화면처럼 SwiftUI 가 `onDisappear`·`onAppear` 를 짝지어 부른다.
struct CoveredEntryGate<Content: View>: View {
    @State private var revealed: Bool
    private let isTop: Bool
    private let content: () -> Content

    /// - Parameters:
    ///   - startsCovered: `State` 초기값이라 칸이 처음 만들어질 때의 값만 쓴다.
    ///   - isTop: 내비게이션 상태로 이 칸이 맨 위인가. 뿌리가 창에 남아 있는 채 맨 위가 되면(전환 도중의 pop) 창 드나듦이 없어 이 값이 연다.
    init(startsCovered: Bool, isTop: Bool, @ViewBuilder content: @escaping () -> Content) {
        _revealed = State(initialValue: !startsCovered)
        self.isTop = isTop
        self.content = content
    }

    var body: some View {
        if revealed {
            content()
        } else {
            Color.clear.background(VisibleTopProbe(isTop: isTop) { _ in revealed = true })
        }
    }
}

/// 호스팅 뷰가 창에 있고 스택 맨 위(또는 스택 밖)가 되면 그 창을 알려 주는 보이지 않는 뷰.
struct VisibleTopProbe: UIViewRepresentable {
    var isTop = false
    let onVisible: @MainActor (UIWindow) -> Void

    func makeUIView(context: Context) -> VisibleTopProbeView {
        VisibleTopProbeView()
    }

    func updateUIView(_ view: VisibleTopProbeView, context: Context) {
        view.isTop = isTop
        view.onVisible = onVisible
        view.check()
    }
}

final class VisibleTopProbeView: UIView {
    var isTop = false
    var onVisible: (@MainActor (UIWindow) -> Void)?
    private var fired = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("코드로만 만든다")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        check()
    }

    /// SwiftUI 갱신 도중에 불릴 수 있다. 그 안에서 `@State` 를 쓰면 무시되고 스택도 아직 안 바뀌었을 수 있어 다음 차례로 미룬다.
    func check() {
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.fired, let window = self.window, self.isTop || self.isStackTop else { return }
            self.fired = true
            self.onVisible?(window)
        }
    }

    /// 대화형 pop 은 시작하는 순간 아래 화면이 `topViewController` 가 된다. 스택 밖이면 가릴 것이 없어 맨 위로 본다.
    private var isStackTop: Bool {
        var controller = sequence(first: self as UIResponder, next: \.next).lazy.compactMap { $0 as? UIViewController }.first
        while let current = controller, let parent = current.parent {
            if let navigationController = parent as? UINavigationController {
                return navigationController.topViewController === current
            }
            controller = parent
        }
        return true
    }
}
