import SwiftUI
import UIKit

/// 탭 화면이 뷰 수명 너머로 맡겨 두는 값 — 원본 `rememberSaveable`(`rememberScrollState` 포함)의 탭 자리.
///
/// 원본은 탭을 떠나도 `saveState` 가 저장 상태를 보관한다. iOS 호스트는 탭 뿌리를 갈아 끼워 `@State` 가 사라지므로 탭 칸마다 이 객체를
/// 하나 두고 `.environment(\.tabSavedState, …)` 로 준다. 칸이 죽을 때(로그아웃 포함) 함께 버린다.
/// 환경에 없으면(탭이 아닌 화면, 20·21 의 시트 등) 아무것도 맡기지 않는다 — 그 화면들은 원본처럼 스택에 있는 동안만 남는다.
@MainActor
public final class TabSavedState {
    private var values: [String: Any] = [:]

    public init() {}

    public func value<Value>(_ key: String) -> Value? {
        values[key] as? Value
    }

    public func set(_ key: String, _ value: Any) {
        values[key] = value
    }

    public func remove(_ key: String) {
        values[key] = nil
    }
}

public extension EnvironmentValues {
    @Entry var tabSavedState: TabSavedState?
}

public extension View {
    /// `ScrollView` **내용**에 붙여 세로 스크롤 위치를 `TabSavedState` 에 맡긴다.
    ///
    /// iOS 17 에는 위치를 값으로 다루는 API(`ScrollPosition`)가 없어 둘러싼 `UIScrollView` 를 직접 읽고 쓴다.
    func savedScrollOffset(_ key: String) -> some View {
        modifier(SavedScrollOffsetModifier(key: key))
    }
}

private struct SavedScrollOffsetModifier: ViewModifier {
    let key: String
    @Environment(\.tabSavedState) private var memory

    func body(content: Content) -> some View {
        if let memory {
            content.background(SavedScrollOffsetProbe(key: key, memory: memory))
        } else {
            content
        }
    }
}

private struct SavedScrollOffsetProbe: UIViewRepresentable {
    let key: String
    let memory: TabSavedState

    func makeUIView(context: Context) -> SavedScrollOffsetView {
        let view = SavedScrollOffsetView()
        view.isUserInteractionEnabled = false
        view.key = key
        view.memory = memory
        return view
    }

    func updateUIView(_ view: SavedScrollOffsetView, context: Context) {
        view.key = key
        view.memory = memory
    }
}

/// 복원 직후 SwiftUI 가 위치를 되돌리면 다시 맞추는 시간. 첫 레이아웃이 끝나는 몇 프레임만 덮으면 된다.
private let restoreSettleSeconds: CFTimeInterval = 0.3

private final class SavedScrollOffsetView: UIView {
    var key = ""
    var memory: TabSavedState?

    private var offsetObservation: NSKeyValueObservation?
    private var sizeObservation: NSKeyValueObservation?
    private var pendingRestore: CGFloat?
    private var settling: (target: CGFloat, deadline: CFTimeInterval)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        offsetObservation = nil
        sizeObservation = nil
        guard window != nil, let scrollView = enclosingScrollView() else { return }
        pendingRestore = memory?.value(key)
        // 내용이 아직 짧으면 값을 줄여 쓰지 않고 내용이 자랄 때까지 기다린다 — 복귀 직후 레이아웃이 끝나기 전에 맨 위로 잘리면 자리를 잃는다.
        sizeObservation = scrollView.observe(\.contentSize, options: [.initial]) { [weak self] scrollView, _ in
            MainActor.assumeIsolated { self?.restoreIfPossible(scrollView) }
        }
        offsetObservation = scrollView.observe(\.contentOffset) { [weak self] scrollView, _ in
            MainActor.assumeIsolated { self?.offsetChanged(scrollView) }
        }
    }

    private func enclosingScrollView() -> UIScrollView? {
        var current = superview
        while let view = current {
            if let scrollView = view as? UIScrollView { return scrollView }
            current = view.superview
        }
        return nil
    }

    private func restoreIfPossible(_ scrollView: UIScrollView) {
        guard let target = pendingRestore else { return }
        let maxOffset = scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
        guard scrollView.bounds.height > 0, maxOffset >= target else { return }
        pendingRestore = nil
        settling = (target, CACurrentMediaTime() + restoreSettleSeconds)
        scrollView.contentOffset.y = target
    }

    private func offsetChanged(_ scrollView: UIScrollView) {
        // 복원 전의 0 을 적으면 맡겨 둔 값이 지워진다. 사용자가 먼저 끌면 복원을 포기하고 그 위치를 따른다.
        if pendingRestore != nil {
            if scrollView.isTracking { pendingRestore = nil } else { return }
        }
        if let current = settling {
            let maxOffset = scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
            if scrollView.isTracking || CACurrentMediaTime() > current.deadline || current.target > maxOffset {
                settling = nil
            } else if scrollView.contentOffset.y != current.target {
                // `LazyVStack` 은 복원 직후 첫 레이아웃에서 위치를 0 으로 되돌린다(시뮬레이터 앱의 17 목록에서 314·630 위치로 확인). 그대로 두면 칸은
                // 복원한 자리 기준으로 그려져 목록이 빈 채로 멈추고, 맡긴 값도 0 으로 지워진다.
                scrollView.contentOffset.y = current.target
                return
            }
        }
        memory?.set(key, scrollView.contentOffset.y)
    }
}
