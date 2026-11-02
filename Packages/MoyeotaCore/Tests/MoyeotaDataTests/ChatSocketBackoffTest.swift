import Testing
@testable import MoyeotaData

/// STOMP 재연결 간격(`ChatSocket.reconnectDelayMs`).
///
/// 예전에는 **고정 3초**였다. 서버가 5xx 로 누워 있는 동안 한 단말이 분당 20번 WebSocket 업그레이드를
/// 시도하는 하드 루프가 되어, **서버가 아플 때 가장 세게** 때리는 모양이었다. 같은 레포의
/// `AppConfigViewModel.RETRY_DELAYS_MS`(2s·5s·15s)는 이미 증가 간격을 쓴다.
///
/// 값은 SSE 쪽(`PartyEventSource` 의 같은 이름 함수)과 **같게** 뒀다 — 두 실시간 통로가
/// 같은 장애에 다르게 반응할 이유가 없다. 화면에는 아무 증상이 없는 종류의 회귀라(끊긴 동안은 호출부
/// 폴링이 메시지를 메운다) 숫자로 못 박는다.
///
/// 지터를 인자로 받으므로 난수 없이 확정적으로 확인한다.
@Suite struct ChatSocketBackoffTest {

    @Test("첫 실패는 예전과 같은 3초다")
    func firstFailure() {
        // 서버가 잠깐 재시작한 경우 — 흔하고, 몇 초 안에 돌아온다. 이 경우를 느리게 만들지 않는다.
        #expect(ChatSocket.reconnectDelayMs(failures: 1, jitter: 0.0) == 3_000)
    }

    @Test("연속 실패마다 간격이 늘어난다")
    func growsWithFailures() {
        #expect(ChatSocket.reconnectDelayMs(failures: 2, jitter: 0.0) == 6_000)
        #expect(ChatSocket.reconnectDelayMs(failures: 3, jitter: 0.0) == 12_000)
        #expect(ChatSocket.reconnectDelayMs(failures: 4, jitter: 0.0) == 30_000)
    }

    @Test("표를 다 쓰면 마지막 값에 머문다")
    func staysAtLastValue() {
        #expect(ChatSocket.reconnectDelayMs(failures: 5, jitter: 0.0) == 30_000)
        #expect(ChatSocket.reconnectDelayMs(failures: 50, jitter: 0.0) == 30_000)
    }

    /// 지터는 **더하기만** 한다 — 하한(3초)·상한(30초)은 둘 다 지키려는 값이다
    @Test("지터는 간격을 늘리기만 하고 20퍼센트를 넘지 않는다")
    func jitterOnlyAdds() {
        #expect(ChatSocket.reconnectDelayMs(failures: 1, jitter: 0.0) == 3_000)
        #expect(ChatSocket.reconnectDelayMs(failures: 1, jitter: 1.0) == 3_600)
        #expect(ChatSocket.reconnectDelayMs(failures: 9, jitter: 1.0) == 36_000)
    }

    /// 범위를 벗어난 지터가 들어와도 간격을 음수·무한으로 만들지 않는다
    @Test("지터가 범위를 벗어나도 접어 넣는다")
    func jitterIsClamped() {
        #expect(ChatSocket.reconnectDelayMs(failures: 1, jitter: -5.0) == 3_000)
        #expect(ChatSocket.reconnectDelayMs(failures: 1, jitter: 9.0) == 3_600)
    }

    /// 세는 쪽이 틀려도 0ms 하드 루프가 되지 않아야 한다
    @Test("0 이하는 첫 간격과 같다")
    func nonPositiveIsFirstInterval() {
        #expect(ChatSocket.reconnectDelayMs(failures: 0, jitter: 0.0) == 3_000)
        #expect(ChatSocket.reconnectDelayMs(failures: -1, jitter: 0.0) == 3_000)
    }

    @Test("아무리 쌓여도 3초에서 36초 사이다")
    func alwaysWithinBounds() {
        for failures in 1...1_000 {
            let delay = ChatSocket.reconnectDelayMs(failures: failures, jitter: 1.0)
            #expect((3_000...36_000).contains(delay), "failures=\(failures) 에서 \(delay)")
        }
    }

    /// 원본에는 SSE 쪽 표에 대한 테스트가 없다. 「일부러 같게 뒀다」는 주석을 숫자로 묶어 둔다.
    @Test("SSE 쪽 간격도 같은 표를 쓴다")
    func sseUsesSameTable() {
        for failures in -1...8 {
            for jitter in [-1.0, 0.0, 0.5, 1.0, 2.0] {
                #expect(
                    PartyEventSource.reconnectDelayMs(failures: failures, jitter: jitter)
                        == ChatSocket.reconnectDelayMs(failures: failures, jitter: jitter)
                )
            }
        }
    }
}
