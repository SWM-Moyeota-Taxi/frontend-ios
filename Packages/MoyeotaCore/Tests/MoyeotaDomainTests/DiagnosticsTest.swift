import Foundation
import Testing
@testable import MoyeotaDomain

/// 보고 기준이 틀리면 대시보드가 **지하철로 가득 차고** 진짜 결함이 소음에 묻힌다.
/// 켜 두나 마나인 상태가 되지 않게 규칙을 여기서 못 박는다.
///
/// 공개 경로인 `Diagnostics.report` 로 검증한다. sink 가 불렸는지로 「걸렀는가」를 본다
/// — 내부 함수를 직접 부르는 것보다 실제 동작에 가깝다.
///
/// 전역 sink 라 테스트끼리 샌다 — 그래서 `.serialized` 이고, 끝날 때 `deinit` 에서 반드시 비운다.
/// 다른 스위트(데이터 계층 테스트)가 동시에 보고해도 섞이지 않도록 이 테스트 태스크의 보고만 기록한다.
@Suite(.serialized)
final class DiagnosticsTest {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(site: FailureSite, throwable: any Error)] = []

        func add(_ site: FailureSite, _ throwable: any Error) {
            lock.withLock { entries.append((site, throwable)) }
        }

        var seen: [(site: FailureSite, throwable: any Error)] {
            lock.withLock { entries }
        }
    }

    @TaskLocal private static var current: Recorder?

    private let recorder = Recorder()

    private func installRecorder() {
        Diagnostics.install { site, throwable in
            Self.current?.add(site, throwable)
        }
    }

    /// `Self.current` 를 이 테스트의 기록기로 두고 몸통을 돌린다.
    private func recording(_ body: () throws -> Void) rethrows {
        try Self.$current.withValue(recorder, operation: body)
    }

    deinit {
        // 전역 sink 라 테스트끼리 샌다. 반드시 비운다.
        Diagnostics.reset()
    }

    /// `IllegalArgumentException` · `NullPointerException` 의 자리 — 매퍼 결함.
    private struct MapperDefect: Error, Equatable {
        let detail: String
    }

    // ───────────────────────── 걸러야 하는 것 ─────────────────────────

    @Test("코루틴 취소는 보고하지 않고 그대로 되던진다")
    func cancellationIsRethrownAndNotReported() {
        installRecorder()

        recording {
            // 삼키면 구조적 동시성이 깨진다 — 호출부가 취소를 알아야 한다.
            #expect(throws: CancellationError.self) {
                try Diagnostics.report(site: .favoritePlaces, throwable: CancellationError())
            }
        }
        #expect(recorder.seen.isEmpty, "취소는 한 건도 올라가면 안 된다")
    }

    @Test("네트워크 끊김은 보고하지 않는다")
    func networkFailuresAreNotReported() throws {
        installRecorder()

        try recording {
            // 지하철이지 결함이 아니다.
            try Diagnostics.report(site: .rideHistory, throwable: IOException("unexpected end of stream"))
            try Diagnostics.report(site: .rideHistory, throwable: URLError(.timedOut))
        }

        #expect(recorder.seen.isEmpty)
    }

    @Test("4xx 는 서버의 정상 판단이라 보고하지 않는다")
    func clientErrorsAreNotReported() throws {
        installRecorder()

        try recording {
            for code in [400, 401, 403, 404, 409, 429] {
                try Diagnostics.report(site: .favoritePlaces, throwable: IllegalStateException(), httpStatus: code)
            }
        }
        #expect(recorder.seen.isEmpty, "호출부가 이미 처리하는 응답이다")
    }

    // ───────────────────────── 올려야 하는 것 ─────────────────────────

    @Test("5xx 는 서버 결함이라 보고한다")
    func serverErrorsAreReported() throws {
        installRecorder()

        try recording {
            for code in [500, 502, 503] {
                try Diagnostics.report(site: .favoritePlaces, throwable: IllegalStateException(), httpStatus: code)
            }
        }
        #expect(recorder.seen.count == 3, "앱이 서버 결함을 아는 유일한 창구다")
    }

    @Test("응답 파싱 실패와 매퍼 결함은 보고한다")
    func parsingAndMapperDefectsAreReported() throws {
        installRecorder()

        try recording {
            // 계약이 깨졌다는 뜻이라 반드시 보여야 한다.
            let parsing = DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: [], debugDescription: "Unexpected JSON token")
            )
            try Diagnostics.report(site: .rideHistory, throwable: parsing)
            try Diagnostics.report(site: .rideHistory, throwable: MapperDefect(detail: "nickname was null"))
            try Diagnostics.report(site: .rideHistory, throwable: MapperDefect(detail: "null"))
        }

        #expect(recorder.seen.count == 3)
    }

    // ───────────────────────── sink 계약 ─────────────────────────

    @Test("sink 를 꽂기 전의 보고는 조용히 버린다")
    func reportBeforeInstallIsDropped() throws {
        // 앱 시작 직후나 단위 테스트에서 터지면 안 된다.
        Diagnostics.reset()
        try Diagnostics.report(site: .rideHistory, throwable: IllegalStateException("too early"))
    }

    @Test("sink 가 던져도 호출부로 새어 나가지 않는다")
    func throwingSinkDoesNotLeak() throws {
        // 이 함수는 전부 catch 안에서 불린다 — 여기서 터지면 삼켜져 있던 실패가 크래시로 승격된다.
        Diagnostics.install { _, _ in throw IllegalStateException("Firebase 초기화 실패") }

        try Diagnostics.report(site: .tokenRefreshRejected, throwable: IllegalStateException("rejected"))
    }

    @Test("보고가 지점과 예외를 그대로 넘긴다")
    func reportPassesSiteAndThrowableThrough() throws {
        installRecorder()
        let boom = MapperDefect(detail: "boom")

        try recording {
            try Diagnostics.report(site: .activePartyRestore, throwable: boom)
        }

        #expect(recorder.seen.count == 1)
        #expect(recorder.seen.first?.site == .activePartyRestore)
        #expect(recorder.seen.first?.throwable as? MapperDefect == boom)
    }

    // ───────────────────────── iOS 사정(원본에 없는 테스트) ─────────────────────────

    @Test("URLSession 의 취소도 취소다 — 보고하지 않고 그대로 되던진다")
    func urlSessionCancellationIsRethrown() {
        installRecorder()

        recording {
            #expect(throws: URLError.self) {
                try Diagnostics.report(site: .favoritePlaces, throwable: URLError(.cancelled))
            }
        }
        #expect(recorder.seen.isEmpty)
    }

    @Test("소켓 오류로 올라오는 NSError 는 네트워크 끊김이다")
    func socketNSErrorIsNetworkFailure() throws {
        installRecorder()

        try recording {
            let socket = NSError(domain: NSPOSIXErrorDomain, code: 57)
            try Diagnostics.report(site: .chatSocketReconnect, throwable: socket)
        }
        #expect(recorder.seen.isEmpty)
    }
}
