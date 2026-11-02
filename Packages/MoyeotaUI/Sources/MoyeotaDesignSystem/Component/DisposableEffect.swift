import SwiftUI

/// Compose `DisposableEffect(keys) { …; onDispose { … } }` 의 자리. 크기 없는 뷰로 화면에 얹는다.
///
/// 지도 오버레이처럼 화면 밖 자원을 키에 맞춰 붙였다 떼는 자리에 쓴다. 키가 바뀌면 정리 후 다시 실행하고,
/// 화면을 떠나면 정리한다. `NavigationStack` 으로 다른 화면이 덮으면 사라짐으로 처리되며, 돌아오면 다시 실행된다
/// (원본도 스택 아래 화면은 컴포지션에서 빠졌다가 복귀 때 다시 실행된다).
public struct DisposableEffect<Key: Equatable>: View {
    let key: Key
    let effect: @MainActor () -> (@MainActor () -> Void)?

    @State private var holder = Holder()

    public init(key: Key, effect: @escaping @MainActor () -> (@MainActor () -> Void)?) {
        self.key = key
        self.effect = effect
    }

    public var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear { holder.run(effect) }
            .onChange(of: key) { _, _ in
                holder.dispose()
                holder.run(effect)
            }
            .onDisappear { holder.dispose() }
    }

    @MainActor
    private final class Holder {
        private var onDispose: (@MainActor () -> Void)?

        func run(_ effect: @MainActor () -> (@MainActor () -> Void)?) {
            onDispose = effect()
        }

        func dispose() {
            onDispose?()
            onDispose = nil
        }
    }
}
