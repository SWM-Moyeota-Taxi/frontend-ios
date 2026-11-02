@testable import FeatureMatching
import Testing

/// 21 매칭 대기가 **SSE 프레임 순서 역전**을 순번(version)으로 가려내는지.
///
/// 서버는 구독을 레지스트리에 **먼저 등록한 뒤** DB 를 읽어 `connected` 를 보낸다
/// (`PartySseRegistry.subscribe` → `partyService.getPartyDetail`). 그 사이 창(쿼리 3개 길이)에
/// 커밋된 변경분이 Redis 리스너 스레드를 타고 **같은 emitter 로 먼저** 나간다. 그래서 Swagger 가
/// 「연결 중에 방이 바뀌면 변경분이 connected 보다 먼저 올 수 있다」고 못 박아 두었다.
///
/// 순번 없이 받는 대로 얹던 동안의 결말이 이것이다:
///
/// ```
/// member-joined(N+1) 반영  →  뒤늦게 connected(N) 이 방을 통째로 덮음  →  그 합류가 사라짐
/// ```
///
/// 사라진 합류가 **정원을 채운 사람**이면 서버는 이미 배차를 시작했는데 화면은 모집 중에 멈춘다.
/// 스트림이 살아 있어 재연결 스냅샷이 없고, `realtimeAlive` 가 true 라 폴백 폴링도 돌지 않으며,
/// `hasMemberDrift` 는 정원 모순만 보는데 이 경우 목록도 status 도 N 시점이라 모순이 없다.
/// 자가 복구는 30분 만료뿐이었다.
///
/// 여기서 고정하는 것은 **판정**이다. 수집 루프는 iOS 에서 추가한 `MatchWaitingViewModelTest` 가 본다.
struct WaitingFrameOrderTest {
    // ─── 변경분 판정 ────────────────────────────────────────────────────────

    /// 바로 다음 프레임이면 그대로 얹는다 — 평상시 경로다.
    @Test("다음 순번이면 반영한다")
    func nextVersionApplies() {
        #expect(deltaVerdict(held: 7, incoming: 8) == .apply)
    }

    /// 이미 반영한 프레임을 다시 얹으면 과거로 되돌아간다.
    @Test("같은 순번은 버린다")
    func sameVersionDrops() {
        #expect(deltaVerdict(held: 7, incoming: 7) == .drop)
    }

    @Test("지난 순번은 버린다")
    func pastVersionDrops() {
        #expect(deltaVerdict(held: 7, incoming: 3) == .drop)
    }

    /// 중간을 놓쳤다 — 증분으로는 메울 수 없으니 상세를 믿는다.
    @Test("순번이 건너뛰면 상세를 다시 읽는다")
    func gapResyncs() {
        #expect(deltaVerdict(held: 7, incoming: 9) == .resync)
        #expect(deltaVerdict(held: 7, incoming: 100) == .resync)
    }

    /// **이 테스트가 이 파일의 핵심이다.** 스냅샷을 받기 전에 온 변경분 = 서버가 말한 「틈」.
    ///
    /// 그대로 얹으면 바탕이 없어 상세를 읽게 되는데(applyDelta 의 held == nil 경로), 그 뒤에 올
    /// 낡은 스냅샷을 막을 근거가 없다. resync 로 떨어뜨려 순번을 먼저 확보해야 한다.
    @Test("스냅샷 전에 온 변경분은 틈으로 보고 상세를 다시 읽는다")
    func deltaBeforeSnapshotResyncs() {
        #expect(deltaVerdict(held: nil, incoming: 1) == .resync)
    }

    /// 순번을 모르는 **옛 서버**. 가릴 근거가 없으니 예전처럼 그대로 얹는다 —
    /// 여기서 resync 로 떨어뜨리면 변경분이 올 때마다 상세를 읽어 폴링 지옥이 된다.
    @Test("순번 없는 프레임은 옛 서버로 보고 그대로 반영한다")
    func noVersionApplies() {
        #expect(deltaVerdict(held: nil, incoming: nil) == .apply)
        #expect(deltaVerdict(held: 7, incoming: nil) == .apply)
    }

    /// 갓 만든 방은 0 에서 시작한다 — 0 을 "없음"으로 뭉개면 안 된다.
    @Test("0 은 없음이 아니라 첫 순번이다")
    func zeroIsAVersion() {
        #expect(deltaVerdict(held: 0, incoming: 1) == .apply)
        #expect(deltaVerdict(held: 0, incoming: 0) == .drop)
    }

    // ─── 스냅샷 판정 ────────────────────────────────────────────────────────

    /// 첫 연결 — 비교할 게 없으면 받는다.
    @Test("들고 있는 순번이 없으면 스냅샷을 받는다")
    func noHeldAcceptsSnapshot() {
        #expect(acceptsSnapshot(held: nil, incoming: 5))
        #expect(acceptsSnapshot(held: nil, incoming: nil))
    }

    /// **회귀 방지 본체.** 변경분을 먼저 반영한 뒤 도착한 낡은 스냅샷을 버린다.
    /// 이 한 줄이 없으면 정원을 채운 합류가 지워지고 화면이 21 에 갇힌다.
    @Test("들고 있는 것보다 과거인 스냅샷은 버린다")
    func pastSnapshotRejected() {
        #expect(!acceptsSnapshot(held: 8, incoming: 7))
    }

    /// 같은 순번이면 받는다 — 내용이 같아 화면은 안 흔들리고(값 동등비교), 재연결 복구가 막히지 않는다.
    @Test("같은 순번의 스냅샷은 받는다")
    func sameSnapshotAccepted() {
        #expect(acceptsSnapshot(held: 8, incoming: 8))
    }

    /// 스냅샷은 변경분과 달리 **+1 을 요구하지 않는다.** 한 덩어리로 완결돼 있어 중간을 건너뛰어도 된다 —
    /// 끊겼다 붙은 재연결이 정확히 이 모양이다.
    @Test("순번이 건너뛴 스냅샷도 받는다")
    func skippedSnapshotAccepted() {
        #expect(acceptsSnapshot(held: 2, incoming: 99))
    }

    /// 옛 서버의 스냅샷은 가릴 수 없으니 받는다 — 안 받으면 그 서버에서 화면이 영영 안 갱신된다.
    @Test("순번 없는 스냅샷은 받는다")
    func noVersionSnapshotAccepted() {
        #expect(acceptsSnapshot(held: 8, incoming: nil))
    }

    // ─── 두 판정이 함께 만드는 시나리오 ──────────────────────────────────────

    /// 사고 재현 — 순서 역전 한 판을 통째로 돌린다.
    ///
    /// 1. 구독 직후, 스냅샷보다 먼저 `member-joined(1)` 이 온다 → 틈 → 상세를 읽어 순번 1 확보
    /// 2. 뒤늦게 `connected(0)` 이 온다 → **버린다**(이게 예전엔 방을 덮어 합류를 지웠다)
    /// 3. 이어서 `member-joined(2)` → 바로 다음 순번이라 반영
    @Test("스냅샷이 뒤집혀 와도 합류가 지워지지 않는다")
    func reorderedSnapshotKeepsJoin() {
        var held: Int64?

        #expect(deltaVerdict(held: held, incoming: 1) == .resync)
        held = 1 // readDetail 이 상세에서 읽어 온 순번

        #expect(!acceptsSnapshot(held: held, incoming: 0), "낡은 스냅샷이 방을 덮으면 안 된다")

        #expect(deltaVerdict(held: held, incoming: 2) == .apply)
    }

    /// 끊겼다 붙는 평범한 재연결은 **막히지 않아야 한다.** 순번을 들고 있어도 재연결 스냅샷이
    /// 더 최신이면 받아서 통째로 맞춘다 — 끊긴 사이의 변화를 메우는 유일한 길이다.
    @Test("재연결 스냅샷은 들고 있는 순번을 넘어서면 받는다")
    func reconnectSnapshotAccepted() {
        let held: Int64 = 4
        #expect(acceptsSnapshot(held: held, incoming: 9))
    }
}
