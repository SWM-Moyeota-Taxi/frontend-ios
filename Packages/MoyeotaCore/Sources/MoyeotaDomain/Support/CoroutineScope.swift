import os

/// Kotlin `CoroutineScope` 의 자리 — 호출부보다 오래 사는 작업을 묶어 두는 그릇.
///
/// `launch` 는 호출한 태스크의 취소를 물려받지 않는다(원본의 `applicationScope` 가 호출한 코루틴과 무관하게
/// 도는 것과 같다). `cancel()` 은 묶인 작업 전부에 취소를 전한다.
///
/// `join()` 은 원본 테스트의 `Dispatchers.Unconfined` 자리다. Swift 는 작업을 생성자 안에서 끝낼 방법이 없으므로,
/// 테스트가 「지금까지 시킨 일이 끝날 때까지」를 명시적으로 기다린다.
public final class CoroutineScope: Sendable {
    private struct Entry: Sendable {
        let cancel: @Sendable () -> Void
        let join: @Sendable () async -> Void
    }

    private struct State: Sendable {
        var isCancelled = false
        var nextId = 0
        var entries: [Int: Entry] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    @discardableResult
    public func launch<T: Sendable>(_ operation: @escaping @Sendable () async -> T) -> Task<T, Never> {
        state.withLock { state in
            let id = state.nextId
            state.nextId += 1
            // 잠금 안에서 등록까지 끝낸다 — 작업이 먼저 끝나 finish 가 등록보다 앞서면 항목이 영영 남는다.
            let task = Task<T, Never> { [self] in
                let result = await operation()
                finish(id)
                return result
            }
            state.entries[id] = Entry(cancel: { task.cancel() }, join: { _ = await task.value })
            if state.isCancelled { task.cancel() }
            return task
        }
    }

    public func cancel() {
        let entries = state.withLock { state in
            state.isCancelled = true
            return Array(state.entries.values)
        }
        entries.forEach { $0.cancel() }
    }

    /// 지금까지 시킨 일, 그리고 그 일이 다시 시킨 일까지 끝날 때까지 기다린다.
    public func join() async {
        while true {
            let entries = state.withLock { Array($0.entries.values) }
            if entries.isEmpty { return }
            for entry in entries { await entry.join() }
        }
    }

    private func finish(_ id: Int) {
        state.withLock { _ = $0.entries.removeValue(forKey: id) }
    }
}
