import Testing
@testable import MoyeotaDomain

@Suite struct StateFlowTest {
    @Test("구독하면 현재 값을 먼저 받고 이후 변경을 받는다")
    func emitsCurrentThenChanges() async {
        let flow = MutableStateFlow(1)
        var iterator = flow.values().makeAsyncIterator()
        #expect(await iterator.next() == 1)
        flow.value = 2
        #expect(await iterator.next() == 2)
    }

    @Test("같은 값은 다시 흘리지 않는다")
    func dropsEqualValues() async {
        let flow = MutableStateFlow(1)
        var iterator = flow.values().makeAsyncIterator()
        #expect(await iterator.next() == 1)
        flow.value = 1
        flow.value = 3
        #expect(await iterator.next() == 3)
    }

    @Test("느린 구독자는 최신 값만 받는다")
    func conflates() async {
        let flow = MutableStateFlow(0)
        var iterator = flow.values().makeAsyncIterator()
        #expect(await iterator.next() == 0)
        flow.value = 1
        flow.value = 2
        flow.value = 3
        #expect(await iterator.next() == 3)
    }

    /// Kotlin 수집기는 **자기가 마지막으로 받은 값**과 비교한다. 쓰기 시점 비교만 하면 바쁜 동안
    /// 1 → 2 → 1 로 돌아온 값을 다시 받아, 한 값에 묶인 부수효과(내비게이션 초기화 등)가 두 번 돈다.
    @Test("바쁜 동안 값이 갔다가 돌아오면 다시 흘리지 않는다")
    func dropsValueThatCameBack() async {
        let flow = MutableStateFlow(1)
        var iterator = flow.values().makeAsyncIterator()
        #expect(await iterator.next() == 1)
        flow.value = 2
        flow.value = 1
        // 1 을 다시 흘리면 `next` 가 바로 1 로 돌아온다. 흘리지 않으면 아래 3 이 깨워 준다.
        let later = Task {
            try await Task.sleep(for: .milliseconds(100))
            flow.value = 3
        }
        #expect(await iterator.next() == 3)
        _ = await later.result
    }

    @Test("마지막으로 받은 값은 구독자마다 따로 센다")
    func tracksLastDeliveredPerSubscriber() async {
        let flow = MutableStateFlow(1)
        var slow = flow.values().makeAsyncIterator()
        var fast = flow.values().makeAsyncIterator()
        #expect(await slow.next() == 1)
        #expect(await fast.next() == 1)
        flow.value = 2
        #expect(await fast.next() == 2)
        flow.value = 1
        // 빠른 구독자에게 1 은 2 다음의 새 값이다.
        #expect(await fast.next() == 1)
        flow.value = 3
        // 느린 구독자는 2 도 돌아온 1 도 보지 못하고 최신 값만 받는다.
        #expect(await slow.next() == 3)
    }

    @Test("중간 값을 건너뛰어도 마지막으로 받은 값과 다르면 받는다")
    func deliversLatestAfterConflation() async {
        let flow = MutableStateFlow(1)
        var iterator = flow.values().makeAsyncIterator()
        #expect(await iterator.next() == 1)
        flow.value = 2
        flow.value = 3
        flow.value = 2
        #expect(await iterator.next() == 2)
    }

    @Test("구독 태스크를 취소하면 끝나고 구독을 지운다")
    func cancellationRemovesSubscriber() async {
        let flow = MutableStateFlow(1)
        let collector = Task {
            var seen: [Int] = []
            for await value in flow.values() { seen.append(value) }
            return seen
        }
        while flow.subscriberCount == 0 { await Task.yield() }
        collector.cancel()
        _ = await collector.value
        #expect(flow.subscriberCount == 0)
    }

    /// `FcmTokenRegistrar` 처럼 값 하나만 보고 `break` 하는 구독자가 흔적을 남기면 안 된다.
    @Test("for await 를 빠져나오기만 해도 구독을 지운다")
    func breakRemovesSubscriber() async {
        let flow = MutableStateFlow(1)
        for await _ in flow.values() { break }
        #expect(flow.subscriberCount == 0)
    }

    @Test("update 는 이전 값으로 새 값을 만든다")
    func updateTransforms() {
        let flow = MutableStateFlow(2)
        flow.update { $0 * 5 }
        #expect(flow.value == 10)
    }
}
