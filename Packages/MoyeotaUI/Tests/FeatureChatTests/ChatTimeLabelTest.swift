import Foundation
import Testing
@testable import FeatureChat

/// 말풍선 시각 표기. 서버 createdAt 은 UTC 라, 문자열을 그대로 자르면 한국에서 9시간 과거로 보인다
/// (QA 결함-3: KST 17:36 → 08:36).
@Suite struct ChatTimeLabelTest {

    private let seoul = TimeZone(identifier: "Asia/Seoul")!

    @Test("UTC Z 표기를 기기 시간대로 옮긴다")
    func utcMovesToDeviceZone() {
        #expect("2026-09-07T08:36:12Z".toTimeLabel(zone: seoul) == "17:36")
    }

    @Test("밀리초가 붙어도 분까지만 쓴다")
    func fractionIsDropped() {
        #expect("2026-09-07T15:05:59.123456Z".toTimeLabel(zone: seoul) == "00:05")
    }

    // 목록 시각 — 오늘은 시각, 올해는 월일, 그 전은 연월일 (기준 시각을 넣어 결정적으로 검사한다)
    private let now = Date(timeIntervalSince1970: 1_789_102_800) // 2026-09-11T05:00:00Z, KST 2026-09-11 14:00

    @Test("기준 시각 상수가 원본 테스트의 2026-09-11T05:00:00Z 와 같다")
    func nowMatchesOriginal() {
        #expect("2026-09-11T05:00:00Z".toInstantOrNull()?.epochSecond == Int64(now.timeIntervalSince1970))
    }

    @Test("목록 시각은 오늘이면 HH mm 이다")
    func listTodayIsTime() {
        #expect("2026-09-11T02:52:55.123Z".toListTimeLabel(now: now, zone: seoul) == "11:52")
    }

    @Test("목록 시각은 올해 다른 날이면 월일이다")
    func listThisYearIsMonthDay() {
        #expect("2026-09-10T14:59:00Z".toListTimeLabel(now: now, zone: seoul) == "9월 10일") // KST 9/10 23:59
    }

    @Test("목록 시각은 작년이면 연월일이다")
    func listLastYearIsFullDate() {
        #expect("2025-12-31T03:00:00Z".toListTimeLabel(now: now, zone: seoul) == "2025.12.31")
    }

    @Test("목록 시각도 날짜 경계는 기기 시간대로 판단한다")
    func listDateBoundaryUsesDeviceZone() {
        // UTC 로는 9/10 이지만 KST 로는 9/11 00:10 → 오늘
        #expect("2026-09-10T15:10:00Z".toListTimeLabel(now: now, zone: seoul) == "00:10")
    }

    @Test("목록 시각은 파싱이 안 되면 비운다")
    func listUnparsableIsNil() {
        #expect("어제".toListTimeLabel(now: now, zone: seoul) == nil)
    }

    @Test("오프셋 표기도 같은 순간으로 읽는다")
    func offsetIsSameInstant() {
        #expect("2026-09-07T17:36:12+09:00".toTimeLabel(zone: seoul) == "17:36")
    }

    @Test("시간대 정보가 없으면 문자열을 그대로 잘라 쓴다")
    func noZoneIsCut() {
        #expect("2026-09-07T17:36:12".toTimeLabel(zone: seoul) == "17:36")
    }

    @Test("형식을 알 수 없으면 null 이다")
    func unknownIsNil() {
        #expect("어제".toTimeLabel(zone: seoul) == nil)
    }
}
