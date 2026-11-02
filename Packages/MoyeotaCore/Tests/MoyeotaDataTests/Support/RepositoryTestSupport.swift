import MoyeotaDomain
import os

/// 페이크가 호출 기록을 담는 칸. 프로토콜이 `Sendable` 이라 원본의 `mutableListOf` 를 그대로 둘 수 없다.
final class Locked<Value: Sendable>: Sendable {
    private let state: OSAllocatedUnfairLock<Value>

    init(_ initial: Value) {
        state = OSAllocatedUnfairLock(initialState: initial)
    }

    var value: Value {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }

    func update(_ transform: @Sendable (inout Value) -> Void) {
        state.withLock { transform(&$0) }
    }
}

extension Locked where Value: RangeReplaceableCollection, Value.Element: Sendable {
    func append(_ element: Value.Element) {
        update { $0.append(element) }
    }
}

/// `runCatching { … }.exceptionOrNull() as E` 의 자리. 다른 예외는 그대로 흘려 테스트를 실패시킨다.
func thrownError<E: Error>(_ type: E.Type, _ block: () async throws -> Void) async throws -> E {
    do {
        try await block()
    } catch let error as E {
        return error
    }
    throw IllegalStateException("\(type) 을 던지지 않았다")
}

/// `CompletableDeferred<Unit>` 의 자리 — 「여기까지 왔다」를 테스트에 알린다.
final class AsyncSignal: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: Void.self)
    }

    func complete() {
        continuation.yield()
        continuation.finish()
    }

    func wait() async {
        for await _ in stream { break }
    }
}
