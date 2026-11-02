import Foundation

/// 읽기 전용 상태 스트림. Kotlin `StateFlow` 의 자리다 — 항상 현재 값이 있고, 구독자는 **자기가 마지막으로
/// 받은 값**과 같은 값을 다시 받지 않으며, 느린 구독자는 중간 값을 건너뛰고 최신 값만 받는다.
public class StateFlow<Value: Sendable & Equatable>: @unchecked Sendable {
    fileprivate let lock = NSLock()
    fileprivate var current: Value
    fileprivate var subscribers: [UUID: AsyncStream<Value>.Continuation] = [:]

    fileprivate init(current: Value) {
        self.current = current
    }

    public var value: Value {
        lock.withLock { current }
    }

    /// 살아 있는 구독 수. 구독이 정리되는지 확인하는 테스트용이다.
    var subscriberCount: Int {
        lock.withLock { subscribers.count }
    }

    /// 현재 값을 먼저 내보내고, 이후 바뀔 때마다 내보낸다. 구독 태스크가 취소되면 끝난다.
    ///
    /// `update` 의 비교는 **쓰기 시점의 현재 값**과 하는 것이라 그것만으로는 모자란다. 구독자가 바쁜 동안
    /// A → B → A 로 돌아오면 버퍼에 A 가 남아 A 를 또 받는다(Kotlin 수집기는 이때 아무것도 내지 않는다).
    /// 그래서 받는 쪽에서 구독자마다 마지막으로 내준 값과 한 번 더 비교한다(`DistinctCursor`).
    public func values() -> AsyncStream<Value> {
        let cursor = DistinctCursor(subscribe())
        return AsyncStream(unfolding: { await cursor.next() })
    }

    private func subscribe() -> AsyncStream<Value> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            lock.withLock {
                continuation.yield(current)
                subscribers[id] = continuation
            }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { self.subscribers[id] = nil }
            }
        }
    }
}

/// 구독 하나의 읽기 위치. `AsyncStream(unfolding:)` 이 한 번에 하나의 `next` 만 부르므로 잠금이 필요 없다.
///
/// 구독자가 스트림을 버리면 이 객체와 함께 `iterator` 가 해제되고, 그때 `onTermination` 이 구독을 지운다.
private final class DistinctCursor<Value: Sendable & Equatable>: @unchecked Sendable {
    private var iterator: AsyncStream<Value>.Iterator
    private var lastDelivered: Value?

    init(_ upstream: AsyncStream<Value>) {
        iterator = upstream.makeAsyncIterator()
    }

    func next() async -> Value? {
        while let value = await iterator.next() {
            if value != lastDelivered {
                lastDelivered = value
                return value
            }
        }
        return nil
    }
}

public final class MutableStateFlow<Value: Sendable & Equatable>: StateFlow<Value>, @unchecked Sendable {
    public override init(current: Value) {
        super.init(current: current)
    }

    public convenience init(_ initial: Value) {
        self.init(current: initial)
    }

    public override var value: Value {
        get { super.value }
        set { update { _ in newValue } }
    }

    /// 원자적으로 값을 바꾼다. Kotlin `MutableStateFlow.update` 와 같다.
    public func update(_ transform: (Value) -> Value) {
        lock.withLock {
            let next = transform(current)
            guard next != current else { return }
            current = next
            for continuation in subscribers.values {
                continuation.yield(next)
            }
        }
    }

    public func asStateFlow() -> StateFlow<Value> { self }
}
