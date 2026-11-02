import PresentationCore
import SwiftUI
import UIKit

/// 가장자리 스와이프가 들어왔을 때 할 일.
enum BackGestureDecision: Equatable {
    /// 스택을 한 칸 pop 한다(시스템 제스처를 그대로 시작).
    case pop
    /// 시스템 pop 은 시작하지 않고 화면이 건 가로채기를 부른다 — 원본 시스템 뒤로가기가 `BackHandler` 에 닿는 것과 같다.
    case intercept
    /// pop 도 가로채기도 없다. 터치는 가장자리 제스처가 받아 끝낸다(손가락 아래 행이 눌리면 안 된다).
    case ignore
}

/// 순수 판정.
///
/// - 전환 중에는 아무것도 하지 않는다. UIKit 은 전환 중에 제스처가 시작되면 화면이 멈출 수 있다.
/// - 가로채기는 쌓인 화면 수보다 먼저 본다. 탭 뿌리에서 방을 연 24 처럼 쌓인 게 없어도 가로채기는 살아 있다.
func backGestureDecision(
    viewControllerCount: Int,
    isIntercepting: Bool,
    isTransitioning: Bool
) -> BackGestureDecision {
    if isTransitioning { return .ignore }
    if isIntercepting { return .intercept }
    return viewControllerCount > 1 ? .pop : .ignore
}

/// 시스템 내비게이션 바를 숨겨 꺼진 스와이프 뒤로가기를 되살린다.
///
/// `.toolbar(.hidden)` 은 기본 대리자가 pop 제스처를 막게 만든다. 그래서 `NavigationStack` 안의 `UINavigationController` 를
/// 찾아 대리자를 이쪽으로 바꾼다. **`BackInterceptionCenter` 를 읽는 쪽은 앱에서 여기뿐이다** —
/// 여기가 빠지면 `moyeotaBackHandler` 를 건 21·25·26 이 스와이프로 그냥 pop 돼 15·16 으로 떨어진다.
///
/// `pathCount` 를 받는 이유: 화면이 쌓일 때 UIKit·SwiftUI 가 제스처 설정을 건드릴 수 있어 경로가 바뀔 때마다 다시 맞춘다.
struct BackGestureBridge: UIViewControllerRepresentable {
    let pathCount: Int

    func makeUIViewController(context: Context) -> BackGestureBridgeController {
        BackGestureBridgeController()
    }

    func updateUIViewController(_ controller: BackGestureBridgeController, context: Context) {
        controller.install()
    }
}

final class BackGestureBridgeController: UIViewController, UIGestureRecognizerDelegate {
    /// 시스템 pop 이 시작되지 않는 가장자리 스와이프(가로채기·탭 뿌리)를 받아 끝내는 제스처.
    ///
    /// 시스템 제스처의 `gestureRecognizerShouldBegin` 이 false 면 그 터치는 그대로 아래 화면으로 간다. 그러면 탭 뿌리에서 손가락 아래의 행이
    /// 눌리고(35 알림 설정이면 앱을 떠난다) 지도가 끌린다. 원본은 시스템 뒤로가기가 터치를 가져가 앱에 닿지 않는다. 그래서 pop 이 아닌 경우는
    /// 이 제스처가 시작돼 터치를 취소시킨다.
    ///
    /// 창에 붙이는 이유: 16 은 스택 밖 오버레이라 그 위의 터치는 내비게이션 뷰에 붙은 시스템 제스처에 닿지 않는다.
    let edgeConsumer: UIScreenEdgePanGestureRecognizer = {
        let recognizer = UIScreenEdgePanGestureRecognizer()
        recognizer.edges = .left
        recognizer.name = edgeConsumerName
        return recognizer
    }()

    override func loadView() {
        view = UIView()
        view.isUserInteractionEnabled = false
        view.isHidden = true
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        install()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        install()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        install()
    }

    func install() {
        guard let navigationController else { return }
        if let pop = navigationController.interactivePopGestureRecognizer {
            // 대리자는 약한 참조다. 이 컨트롤러는 뿌리 화면과 함께 살아 있어 스택 수명 동안 남는다.
            if pop.delegate !== self { pop.delegate = self }
            pop.isEnabled = true
        }
        disableContentPopGesture(navigationController)
        installEdgeConsumer(in: navigationController.view.window)
    }

    private func installEdgeConsumer(in window: UIWindow?) {
        guard let window, edgeConsumer.view !== window else { return }
        // 내비게이션이 새로 서면(같은 창) 앞 브리지의 제스처가 남아 있다. 대리자가 비면 무엇이든 시작하므로 함께 뺀다.
        for stale in window.gestureRecognizers ?? [] where stale.name == edgeConsumerName {
            window.removeGestureRecognizer(stale)
        }
        edgeConsumer.delegate = self
        window.addGestureRecognizer(edgeConsumer)
    }

    /// iOS 26 은 화면 어디서나 끌어 pop 하는 제스처를 더한다. 지도 팬·시트 드래그·가로 제스처와 싸우고 원본에도 없는 동작이라 끄고
    /// 가장자리 스와이프만 남긴다. 배포 대상이 iOS 17 이라 API 를 가드한다.
    private func disableContentPopGesture(_ navigationController: UINavigationController) {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            navigationController.interactiveContentPopGestureRecognizer?.isEnabled = false
        }
        #endif
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let navigationController else { return false }
        let decision = backGestureDecision(
            viewControllerCount: navigationController.viewControllers.count,
            isIntercepting: BackInterceptionCenter.shared.isIntercepting,
            isTransitioning: navigationController.transitionCoordinator != nil
        )
        guard gestureRecognizer === edgeConsumer else { return decision == .pop }
        switch decision {
        case .pop:
            return false
        case .intercept:
            BackInterceptionCenter.shared.handleBack()
            return true
        case .ignore:
            return true
        }
    }

    /// 가장자리 제스처가 판정을 낼 때까지 다른 제스처를 기다리게 한다. 지도의 팬은 가장자리 제스처보다 먼저 인식돼, 지도 위에서 시작한 스와이프가
    /// 뒤로 가지 못하고 지도만 끌었다. 가장자리에서 시작하지 않은 터치에서는 가장자리 제스처가 곧바로 실패해 기다림이 없다.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        !(otherGestureRecognizer is UIScreenEdgePanGestureRecognizer)
    }
}

private let edgeConsumerName = "moyeota.edgeBackConsumer"
