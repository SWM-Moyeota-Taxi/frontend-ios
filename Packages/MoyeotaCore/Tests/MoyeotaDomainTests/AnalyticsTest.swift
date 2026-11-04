import Foundation
import Testing
@testable import MoyeotaDomain

/// 이벤트 이름·프로퍼티 키는 **Mixpanel 대시보드가 보는 문자열**이다. 여기서 못 박아 두면 이름을 고칠 때
/// 테스트가 먼저 깨져 「보고서도 같이 고쳐야 한다」를 알려 준다. 전역 sink 라 `DiagnosticsTest` 와 같은 틀을 쓴다
/// (`.serialized`, 끝날 때 `reset`).
@Suite(.serialized)
final class AnalyticsTest {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [AnalyticsEvent] = []

        func add(_ event: AnalyticsEvent) {
            lock.withLock { entries.append(event) }
        }

        var seen: [AnalyticsEvent] {
            lock.withLock { entries }
        }
    }

    @TaskLocal private static var current: Recorder?

    private let recorder = Recorder()

    private func installRecorder() {
        Analytics.install { event in Self.current?.add(event) }
    }

    private func recording(_ body: () -> Void) {
        Self.$current.withValue(recorder, operation: body)
    }

    deinit {
        Analytics.reset()
    }

    // ───────────────────────── 통로 ─────────────────────────

    @Test("sink 를 꽂기 전의 기록은 조용히 버린다")
    func noSinkIsSilent() {
        Analytics.reset()
        Analytics.track(.loginCompleted) // 던지지도, 멈추지도 않는다
        #expect(recorder.seen.isEmpty)
    }

    @Test("꽂은 sink 가 이벤트를 그대로 받는다")
    func sinkReceivesEvents() {
        installRecorder()
        recording {
            Analytics.track(.loginCompleted)
            Analytics.track(.screenViewed(screen: "home"))
        }
        #expect(recorder.seen == [.loginCompleted, .screenViewed(screen: "home")])
    }

    @Test("reset 뒤에는 다시 버린다")
    func resetDetaches() {
        installRecorder()
        Analytics.reset()
        recording { Analytics.track(.loginCompleted) }
        #expect(recorder.seen.isEmpty)
    }

    // ───────────────────────── 이름 — 대시보드 계약 ─────────────────────────

    @Test("이벤트 이름은 Mixpanel 보고서가 보는 값이다 — 바꾸면 보고서도 고친다")
    func eventNames() {
        let expected: [(AnalyticsEvent, String)] = [
            (.screenViewed(screen: "home"), "view_screen"),
            (.signupCompleted(gender: .female, ageBand: "20s"), "complete_signup"),
            (.loginCompleted, "complete_login"),
            (.partyCreateClicked(capacity: 3), "click_create_party"),
            (.partyJoinClicked, "click_join_party"),
            (.matchRequested(method: .create, capacity: 3, originArea: nil, destinationArea: nil, estimatedFare: nil), "request_match"),
            (.matchRequestFailed(method: .join, reason: "party_full"), "fail_match_request"),
            (.matchCompleted(capacity: 3, memberCount: 3, waitedSeconds: 10), "complete_match"),
            (.matchCanceled(capacity: 3, memberCount: 1), "cancel_match"),
            (.partyFinished(memberCount: 3), "finish_party"),
            (.rideFinished, "finish_ride"),
            (.emergencyTriggered, "trigger_emergency"),
            (.accountDeleted, "delete_account"),
        ]
        for (event, name) in expected {
            #expect(event.name == name)
        }
    }

    @Test("핵심 퍼널 세 이벤트의 이름은 서로 다르다 — 퍼널 단계가 합쳐지면 전환율이 100% 로 보인다")
    func funnelStepsAreDistinct() {
        let steps: Set<String> = [
            AnalyticsEvent.signupCompleted(gender: .male, ageBand: "20s").name,
            AnalyticsEvent.matchRequested(method: .create, capacity: 3, originArea: nil, destinationArea: nil, estimatedFare: nil).name,
            AnalyticsEvent.matchCompleted(capacity: 3, memberCount: 3, waitedSeconds: 0).name,
        ]
        #expect(steps.count == 3)
    }

    // ───────────────────────── 프로퍼티 ─────────────────────────

    @Test("request_match 는 방식·정원·지역·요금을 싣고, 모르는 값은 키를 뺀다")
    func matchRequestedProperties() {
        let full = AnalyticsEvent.matchRequested(
            method: .create, capacity: 3, originArea: "서울 관악구", destinationArea: "서울 강남구", estimatedFare: 12_300
        )
        #expect(full.properties == [
            "method": .string("create"),
            "capacity": .int(3),
            "origin_area": .string("서울 관악구"),
            "destination_area": .string("서울 강남구"),
            "estimated_fare": .int(12_300),
        ])

        let join = AnalyticsEvent.matchRequested(method: .join, capacity: nil, originArea: nil, destinationArea: nil, estimatedFare: nil)
        #expect(join.properties == ["method": .string("join")])
    }

    @Test("complete_signup 은 성별을 소문자 상수로, 나이는 연령대로만 싣는다")
    func signupProperties() {
        let event = AnalyticsEvent.signupCompleted(gender: .undisclosed, ageBand: "30s")
        #expect(event.properties == ["gender": .string("undisclosed"), "age_band": .string("30s")])
    }

    @Test("프로퍼티 키는 전부 snake_case 다")
    func propertyKeysAreSnakeCase() {
        let events: [AnalyticsEvent] = [
            .screenViewed(screen: "home"),
            .signupCompleted(gender: .male, ageBand: "20s"),
            .partyCreateClicked(capacity: 2),
            .matchRequested(method: .create, capacity: 3, originArea: "a", destinationArea: "b", estimatedFare: 1),
            .matchRequestFailed(method: .create, reason: "unknown"),
            .matchCompleted(capacity: 3, memberCount: 3, waitedSeconds: 1),
            .matchCanceled(capacity: 3, memberCount: 1),
            .partyFinished(memberCount: 2),
        ]
        for event in events {
            for key in event.properties.keys {
                #expect(key.allSatisfy { $0.isLowercase || $0 == "_" }, "\(event.name).\(key)")
            }
        }
    }

    // ───────────────────────── 지역 — 시/구까지만 ─────────────────────────

    @Test("도로명 주소에서 시/도 + 시/군/구만 남기고 번지는 버린다")
    func administrativeAreaTrimsAddress() {
        #expect(administrativeArea(fromAddress: "서울 강남구 테헤란로 123") == "서울 강남구")
        #expect(administrativeArea(fromAddress: "경기 안양시 만안구 성결대학로 53") == "경기 안양시 만안구")
        #expect(administrativeArea(fromAddress: "경기 성남시 분당구 판교역로 166") == "경기 성남시 분당구")
        #expect(administrativeArea(fromAddress: "부산광역시 금정구 부산대학로 63") == "부산광역시 금정구")
        #expect(administrativeArea(fromAddress: "강원특별자치도 춘천시 중앙로 1") == "강원특별자치도 춘천시")
        #expect(administrativeArea(fromAddress: "충남 천안시 동남구 대흥로 1") == "충남 천안시 동남구")
    }

    @Test("주소가 아니면 지어내지 않고 nil 이다")
    func administrativeAreaRejectsNonAddress() {
        #expect(administrativeArea(fromAddress: "부산대로") == nil)
        #expect(administrativeArea(fromAddress: "") == nil)
        #expect(administrativeArea(fromAddress: "서면역") == nil)
        // 시/도만 있고 시/군/구가 없으면 지역이라 부를 것이 없다
        #expect(administrativeArea(fromAddress: "서울 테헤란로 123") == nil)
    }

    // ───────────────────────── 연령대 — 생일 당일부터 다음 나이 ─────────────────────────

    @Test("연령대는 만 나이 기준이고 생일 당일에 바뀐다")
    func ageBandBoundaries() {
        let birth = LocalDate(year: 1996, month: 5, dayOfMonth: 20)!
        #expect(ageBand(birthDate: birth, today: LocalDate(year: 2026, month: 5, dayOfMonth: 19)!) == "20s") // 29세
        #expect(ageBand(birthDate: birth, today: LocalDate(year: 2026, month: 5, dayOfMonth: 20)!) == "30s") // 30세 당일
        #expect(ageBand(birthDate: LocalDate(year: 2010, month: 1, dayOfMonth: 1)!, today: LocalDate(year: 2026, month: 1, dayOfMonth: 1)!) == "10s")
        #expect(ageBand(birthDate: LocalDate(year: 1960, month: 1, dayOfMonth: 1)!, today: LocalDate(year: 2026, month: 1, dayOfMonth: 1)!) == "60s+")
        #expect(ageBand(birthDate: LocalDate(year: 1980, month: 12, dayOfMonth: 31)!, today: LocalDate(year: 2026, month: 1, dayOfMonth: 1)!) == "40s")
    }
}
