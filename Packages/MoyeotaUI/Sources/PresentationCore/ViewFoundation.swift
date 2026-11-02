import SwiftUI

/// `viewModelScope` 의 자리. 뷰모델이 해제되면 띄운 태스크를 모두 취소한다.
/// 태스크 클로저는 `[weak self]` 로 뷰모델을 잡아야 한다 — 강하게 잡으면 해제되지 않아 영영 취소되지 않는다.
public final class ViewModelScope: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [UUID: Task<Void, Never>] = [:]

    public init() {}

    deinit {
        cancelAll()
    }

    @discardableResult
    public func launch(
        priority: TaskPriority? = nil,
        @_inheritActorContext _ operation: sending @escaping @isolated(any) () async -> Void
    ) -> Task<Void, Never> {
        let id = UUID()
        let task = Task(priority: priority) { [weak self] in
            await operation()
            self?.finish(id)
        }
        lock.withLock { tasks[id] = task }
        return task
    }

    public func cancelAll() {
        let running = lock.withLock {
            let current = tasks
            tasks = [:]
            return current
        }
        running.values.forEach { $0.cancel() }
    }

    private func finish(_ id: UUID) {
        lock.withLock { tasks[id] = nil }
    }
}

/// `viewModel(factory = …)` 의 자리. 뷰 구조체가 다시 만들어져도 뷰모델은 처음 한 번만 만들어진다.
///
/// `@State var vm = X()` 를 쓰지 않는 이유: 그 식은 뷰 init 마다 평가돼, 버려질 인스턴스의 init 부수효과
/// (원본의 `init { refresh() }`)가 매번 실행된다. `@StateObject` 는 autoclosure 라 한 번만 평가한다.
@MainActor
@propertyWrapper
public struct HostedViewModel<VM: AnyObject>: DynamicProperty {
    @StateObject private var holder: ViewModelHolder<VM>

    public init(wrappedValue make: @autoclosure @escaping @MainActor () -> VM) {
        _holder = StateObject(wrappedValue: ViewModelHolder(make()))
    }

    public var wrappedValue: VM { holder.viewModel }
}

@MainActor
final class ViewModelHolder<VM: AnyObject>: ObservableObject {
    let viewModel: VM

    init(_ viewModel: VM) {
        self.viewModel = viewModel
    }
}

public extension EnvironmentValues {
    /// 이 화면이 내비게이션 스택의 맨 위 칸인가. 앱 내비게이션이 칸마다 넣어 주고, 스택 밖 화면은 기본값 true 다.
    ///
    /// `onAppear` 만으로는 알 수 없다. `NavigationStack` 은 화면을 쌓을 때 **새 화면 두 칸 아래의 덮인 화면**에 `onAppear` 를 한 번 더 부르고
    /// 짝이 되는 `onDisappear` 는 부르지 않는다(iOS 26.3 시뮬레이터, 14→21→22→23 에서 23 을 쌓는 순간 21). 그대로 믿으면 그 화면이 가로채기를
    /// 다시 걸어 23 의 스와이프가 홈으로 가고, 폴링이 덮인 채 돌고, 진입 `.task` 가 한 번 더 돈다.
    @Entry var isTopStackEntry = true
}

public extension View {
    /// 맨 위 칸일 때만 도는 진입 `.task`. 덮이면 취소되고 다시 맨 위가 되면 새로 돈다. 이유는 `isTopStackEntry` 에 적었다.
    func topEntryTask(_ action: @escaping @Sendable @MainActor () async -> Void) -> some View {
        modifier(TopEntryTaskModifier(action: action))
    }
}

private struct TopEntryTaskModifier: ViewModifier {
    @Environment(\.isTopStackEntry) private var isTop
    let action: @Sendable @MainActor () async -> Void

    func body(content: Content) -> some View {
        content.task(id: isTop) {
            if isTop { await action() }
        }
    }
}

/// `onAppear`·`onDisappear` 를 「맨 위 화면이 됐다·덮였다」로 읽되 `isTopStackEntry` 로 한 번 더 거른다. 창 밖에서 처음 만들어진 뷰는 `onAppear` 만
/// 받아 이 전제가 깨지므로, 앱 내비게이션(`CoveredEntryGate`)이 그런 칸의 내용을 창에 들어올 때까지 만들지 않는다. `moyeotaBackHandler` 도 같다.
private struct LifecycleEffectModifier: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isTopStackEntry) private var isTop
    @State private var isVisible = false
    @State private var isStarted = false

    let onStart: @MainActor () -> Void
    let onStop: @MainActor () -> Void

    func body(content: Content) -> some View {
        content
            .onAppear {
                isVisible = true
                sync()
            }
            .onDisappear {
                isVisible = false
                sync()
            }
            .onChange(of: scenePhase) { _, _ in
                sync()
            }
            .onChange(of: isTop) { _, _ in
                sync()
            }
    }

    private func sync() {
        // .inactive(제어 센터·알림 패널을 내린 순간)는 Android 의 STARTED 에 가깝다 — .background 에서만 멈춘다.
        let shouldRun = isVisible && isTop && scenePhase != .background
        guard shouldRun != isStarted else { return }
        isStarted = shouldRun
        if shouldRun {
            onStart()
        } else {
            onStop()
        }
    }
}


/// 현재 화면이 뒤로가기를 가로채고 있는지를 스와이프 제스처 제어기에 알리는 중앙 저장소.
@MainActor
@Observable
public final class BackInterceptionCenter {
    public static let shared = BackInterceptionCenter()

    private var handlers: [(id: UUID, action: @MainActor () -> Void)] = []

    public var isIntercepting: Bool { !handlers.isEmpty }

    public func register(id: UUID, action: @escaping @MainActor () -> Void) {
        handlers.removeAll { $0.id == id }
        handlers.append((id, action))
    }

    public func unregister(id: UUID) {
        handlers.removeAll { $0.id == id }
    }

    /// 가장 최근에 등록한 가로채기를 실행한다. 가로챈 것이 없으면 false.
    @discardableResult
    public func handleBack() -> Bool {
        guard let handler = handlers.last else { return false }
        handler.action()
        return true
    }
}

/// 등록해 둔 가로채기가 늘 마지막 `body` 의 동작을 부르게 하는 상자 — 원본 `BackHandler` 의 `rememberUpdatedState` 자리.
@MainActor
private final class LatestBackAction {
    var action: @MainActor () -> Void = {}
}

/// 원본 `BackHandler` 는 **맨 위 엔트리의 것만** 뒤로가기를 받는다(덮인 엔트리는 컴포지션에서 빠진다).
/// 여기서는 위에 화면이 쌓이면 불리는 `onDisappear` 로 등록을 풀고, 돌아오면 `onAppear` 로 다시 건다.
/// 덮여 있는 동안 `enabled` 가 바뀌어도 등록하지 않는다 — 등록하면 위 화면의 뒤로가기를 아래 화면이 가로챈다.
private struct BackHandlerModifier: ViewModifier {
    let enabled: Bool
    let action: @MainActor () -> Void
    @State private var id = UUID()
    @State private var latest = LatestBackAction()
    @State private var visible = false
    @Environment(\.isTopStackEntry) private var isTop

    func body(content: Content) -> some View {
        let latest = self.latest
        latest.action = action
        return content
            .onAppear {
                visible = true
                sync(visible: true)
            }
            .onChange(of: enabled) { _, _ in sync(visible: visible) }
            .onChange(of: isTop) { _, _ in sync(visible: visible) }
            .onDisappear {
                visible = false
                BackInterceptionCenter.shared.unregister(id: id)
            }
    }

    private func sync(visible: Bool) {
        if enabled && visible && isTop {
            let latest = self.latest
            BackInterceptionCenter.shared.register(id: id, action: { latest.action() })
        } else {
            BackInterceptionCenter.shared.unregister(id: id)
        }
    }
}

public extension View {
    /// `LifecycleStartEffect` 의 자리. 화면이 보이고 앱이 전면에 있으면 `onStart`, 어느 하나가 깨지면 `onStop`.
    func lifecycleEffect(
        onStart: @escaping @MainActor () -> Void,
        onStop: @escaping @MainActor () -> Void = {}
    ) -> some View {
        modifier(LifecycleEffectModifier(onStart: onStart, onStop: onStop))
    }

    /// `BackHandler` 의 자리. 켜져 있는 동안 시스템 스와이프 뒤로가기가 막히고, 뒤로가기 시도는 `action` 으로 간다.
    func moyeotaBackHandler(
        enabled: Bool = true,
        action: @escaping @MainActor () -> Void
    ) -> some View {
        modifier(BackHandlerModifier(enabled: enabled, action: action))
    }
}
