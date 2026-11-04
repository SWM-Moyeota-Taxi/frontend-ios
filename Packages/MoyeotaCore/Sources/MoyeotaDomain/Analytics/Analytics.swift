import Foundation
import os

/// 사용자 행동 이벤트를 밖(Mixpanel)으로 보내는 통로. `Diagnostics` 와 같은 구조다.
///
/// **무엇을 기록할지**는 여기(`AnalyticsEvent`)서 닫힌 enum 으로 정하고, **어디로 보낼지**만 앱 타깃이
/// `install` 로 꽂는다. domain 은 Mixpanel 을 모른다. 생성자 주입이 아니라 전역인 이유는 `Diagnostics` 의
/// 주석과 같다 — 열 몇 곳의 뷰모델 생성자와 그만큼의 테스트 fake 를 함께 바꿀 만한 값어치가 없고,
/// `os.Logger` 처럼 **부수효과 없는 진단 출력**이기 때문이다. 기본값이 무동작이라 아무것도 꽂지 않은
/// 단위 테스트는 그대로 통과한다.
///
/// ### 이벤트를 enum 으로 닫아 두는 이유
/// 자리마다 문자열을 새로 지으면 같은 행동이 `match_request`·`request_match`·`matchRequested` 로 흩어져
/// Mixpanel 퍼널이 끊긴다. 이름과 프로퍼티 키는 `AnalyticsEvent.name`·`properties` 한 곳이 결정하고,
/// 대시보드가 그 이름을 보고 있으므로 **바꾸면 대시보드도 함께 고쳐야 한다**(`AnalyticsTest` 가 못 박는다).
///
/// ### 보내면 안 되는 것
/// 실명·휴대폰·이메일·좌표·채팅 본문·방 id·동승자 식별자. 지역은 **시/구 단위**(`administrativeArea`)까지만,
/// 나이는 **연령대**(`ageBand`)까지만 싣는다. 사용자 식별자(publicId)는 앱 타깃의 리포터가 `identify` 로
/// 따로 다루고, 이벤트 프로퍼티에는 넣지 않는다.
public enum Analytics {

    public typealias Sink = @Sendable (AnalyticsEvent) -> Void

    /// 설치는 메인 스레드(앱 시작), 기록은 아무 스레드에서나 일어난다.
    private static let installedSink = OSAllocatedUnfairLock<Sink?>(initialState: nil)

    /// app 모듈이 앱 시작 때 한 번 꽂는다. 꽂기 전의 기록은 조용히 버린다.
    public static func install(sink: @escaping Sink) {
        installedSink.withLock { $0 = sink }
    }

    /// 테스트끼리 설치가 새지 않게 비운다.
    public static func reset() {
        installedSink.withLock { $0 = nil }
    }

    /// 이벤트를 기록한다. **절대 던지지 않고, 호출부를 기다리게 하지 않는다** — 분석은 부가 기능이라
    /// 여기서 터지거나 느려지면 사용자가 하려던 일이 막힌다.
    public static func track(_ event: AnalyticsEvent) {
        let sink = installedSink.withLock { $0 }
        sink?(event)
    }
}

/// 이벤트 프로퍼티 값. Mixpanel 이 받는 원시 타입만 둔다 — 중첩 구조를 허용하면 모델 통째로 실어 보내는
/// 자리가 생기고, 그 안에 개인정보가 섞여 들어가는 걸 타입이 막지 못한다.
public enum AnalyticsValue: Hashable, Sendable {
    case string(String)
    case int(Int)
    case bool(Bool)
}

/// 매칭 신청의 두 길. 16 도착지 확인에서 **방을 만드는** 쪽과 20 합류 확인에서 **남의 방에 들어가는** 쪽.
public enum MatchRequestMethod: String, Sendable {
    case create
    case join
}

/// 앱이 기록하는 모든 이벤트. 특강 정리의 네이밍(동작 + 대상)을 따른다 — `view_screen`, `click_create_party`.
///
/// 핵심 가치 퍼널은 **가입 → 매칭 신청 → 매칭 완료**다:
/// `complete_signup` → `request_match` → `complete_match`. Mixpanel 퍼널·리텐션 보고서는 이 세 이름을 본다.
///
/// | 종류 | 이벤트 | 어디서 |
/// |---|---|---|
/// | View | `view_screen` | 내비게이션 스택의 맨 위가 바뀔 때(`MainNavGraph`) |
/// | Click | `click_create_party`·`click_join_party` | 버튼을 눌러 요청이 **나가는 순간** |
/// | Action | 나머지 | 서버가 성공을 돌려준 **뒤** — 눌렀다와 됐다를 가른다 |
public enum AnalyticsEvent: Hashable, Sendable {
    /// 화면이 맨 위에 올라왔다. `screen` 은 `Route.destination`(예: `matching/waiting`) — 인자를 채우기 전
    /// 패턴이라 채팅방 id 같은 값이 섞이지 않는다.
    case screenViewed(screen: String)

    /// 가입 + 자동 로그인까지 끝났다(12 매너 서약). 성별·연령대는 가입 폼의 값에서 **여기서 한 번만** 나온다 —
    /// 서버가 프로필 조회로 돌려주지 않아 나중에는 알 수 없다.
    case signupCompleted(gender: Gender, ageBand: String)

    /// 아이디 로그인 성공(04a).
    case loginCompleted

    /// 16 「방 만들기」를 눌러 요청이 나갔다.
    case partyCreateClicked(capacity: Int)

    /// 20 「합류하기」를 눌러 요청이 나갔다.
    case partyJoinClicked

    /// 매칭 신청이 서버에 받아들여졌다 — 방을 만들었거나 남의 방에 들어갔다. 핵심 퍼널 2단계.
    ///
    /// `originArea`·`destinationArea` 는 시/구 단위(`administrativeArea`). 합류 쪽은 방 상세에 주소가 없어
    /// nil 이다. `estimatedFare` 는 서버가 방 생성 응답에 실어 준 경로 전체 예상 요금(원)이다.
    /// `capacity` 가 nil 인 건 합류 응답에 정원이 없고 상세도 못 읽은 드문 경우뿐이다 — 0 으로 지어내지 않는다.
    case matchRequested(
        method: MatchRequestMethod,
        capacity: Int?,
        originArea: String?,
        destinationArea: String?,
        estimatedFare: Int?
    )

    /// 매칭 신청이 거절됐다. `reason` 은 서버 코드가 아니라 도메인 예외의 판정을 옮긴 짧은 상수다
    /// (`already_in_party`·`party_full`·`network` …). 「왜 신청이 안 되는가」를 세는 자리다.
    case matchRequestFailed(method: MatchRequestMethod, reason: String)

    /// 정원이 찼다 — 「4명 모이면 택시비가 싸진다」를 사용자가 **경험하는 순간**. 핵심 퍼널 3단계.
    ///
    /// 21 매칭 대기가 방 상태를 정원 충족(MATCHED) 이상으로 처음 보았을 때 기록한다. 그 화면에 들어온 뒤
    /// 얼마나 기다렸는지가 `waitedSeconds` 다(신청 시점이 아니라 화면 진입 기준).
    case matchCompleted(capacity: Int, memberCount: Int, waitedSeconds: Int)

    /// 21 「그만 찾기」·「방 나가기」가 성공했다 — 퍼널에서 빠져나간 사람과 그때의 인원.
    case matchCanceled(capacity: Int, memberCount: Int)

    /// 동승 모드의 「합승 완료」가 성공했다(방장이 방을 닫음).
    case partyFinished(memberCount: Int)

    /// 택시 모드에서 기사가 운행을 끝낸 것을 26 운행 중이 감지했다 → 33 도착 완료.
    case rideFinished

    /// 27 긴급 신고의 3초 홀드가 끝나 신고가 나갔다.
    case emergencyTriggered

    /// 37 회원 탈퇴가 204 를 받았다.
    case accountDeleted

    /// Mixpanel 이벤트 이름. **대시보드가 이 문자열을 본다** — 바꾸면 보고서도 함께 고친다.
    public var name: String {
        switch self {
        case .screenViewed: "view_screen"
        case .signupCompleted: "complete_signup"
        case .loginCompleted: "complete_login"
        case .partyCreateClicked: "click_create_party"
        case .partyJoinClicked: "click_join_party"
        case .matchRequested: "request_match"
        case .matchRequestFailed: "fail_match_request"
        case .matchCompleted: "complete_match"
        case .matchCanceled: "cancel_match"
        case .partyFinished: "finish_party"
        case .rideFinished: "finish_ride"
        case .emergencyTriggered: "trigger_emergency"
        case .accountDeleted: "delete_account"
        }
    }

    /// 이벤트 프로퍼티. 키는 snake_case 로 고정한다. nil 인 값은 **키를 빼고** 보낸다 — Mixpanel 에서
    /// 「값 없음」과 「빈 문자열」이 다른 집계가 되지 않게.
    public var properties: [String: AnalyticsValue] {
        switch self {
        case .screenViewed(let screen):
            ["screen": .string(screen)]
        case .signupCompleted(let gender, let ageBand):
            ["gender": .string(gender.name.lowercased()), "age_band": .string(ageBand)]
        case .loginCompleted, .partyJoinClicked, .rideFinished, .emergencyTriggered, .accountDeleted:
            [:]
        case .partyCreateClicked(let capacity):
            ["capacity": .int(capacity)]
        case .matchRequested(let method, let capacity, let originArea, let destinationArea, let estimatedFare):
            compact([
                "method": .string(method.rawValue),
                "capacity": capacity.map { .int($0) },
                "origin_area": originArea.map { .string($0) },
                "destination_area": destinationArea.map { .string($0) },
                "estimated_fare": estimatedFare.map { .int($0) },
            ])
        case .matchRequestFailed(let method, let reason):
            ["method": .string(method.rawValue), "reason": .string(reason)]
        case .matchCompleted(let capacity, let memberCount, let waitedSeconds):
            ["capacity": .int(capacity), "member_count": .int(memberCount), "waited_seconds": .int(waitedSeconds)]
        case .matchCanceled(let capacity, let memberCount):
            ["capacity": .int(capacity), "member_count": .int(memberCount)]
        case .partyFinished(let memberCount):
            ["member_count": .int(memberCount)]
        }
    }

    private func compact(_ values: [String: AnalyticsValue?]) -> [String: AnalyticsValue] {
        values.compactMapValues { $0 }
    }
}

/// 도로명 주소에서 **시/도 + 시/군/구** 까지만 잘라 낸다. 그 아래(동·도로명·번지)는 버린다.
///
///     "경기 안양시 만안구 성결대학로 53" → "경기 안양시 만안구"
///     "서울 강남구 테헤란로 123"        → "서울 강남구"
///     "부산대로"                        → nil (주소가 아니다)
///
/// 「관악구 출발이 많다」 같은 지역 분석에 쓸 만큼은 남기고, 사람을 특정할 만큼은 남기지 않는다 — 번지까지
/// 실으면 출발지가 곧 집 주소가 된다. 서버 `PlaceSearchResponse.roadName` 이 전체 도로명 주소라서
/// 첫 토큰이 시/도, 그다음이 시/군/구다(광역시 산하 구, 도 산하 시의 구 모두 포함).
///
/// 판정이 서지 않으면 nil 이다 — 지어내지 않는다. 첫 토큰이 시·도로 끝나지 않으면 주소가 아니라고 본다.
public func administrativeArea(fromAddress address: String) -> String? {
    let tokens = address.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    guard let province = tokens.first, isProvinceToken(province) else { return nil }
    var parts = [province]
    for token in tokens.dropFirst() {
        guard isDistrictToken(token) else { break }
        parts.append(token)
        // 「경기 안양시 만안구」처럼 시 아래 구까지 두 단계. 그 아래 읍·면·동은 버린다.
        if parts.count == 3 { break }
    }
    // 시/도만 있고 시/군/구가 없으면 지역이라 부를 것이 없다(세종은 서버 주소도 「세종특별자치시 …동」 꼴이다).
    guard parts.count >= 2 else { return nil }
    return parts.joined(separator: " ")
}

private func isProvinceToken(_ token: String) -> Bool {
    // 축약형(서울·경기·부산…)과 정식 명칭(서울특별시·경기도·부산광역시…) 둘 다 온다.
    let short: Set<String> = ["서울", "부산", "대구", "인천", "광주", "대전", "울산", "세종", "경기", "강원", "충북", "충남", "전북", "전남", "경북", "경남", "제주"]
    if short.contains(token) { return true }
    return token.hasSuffix("특별시") || token.hasSuffix("광역시") || token.hasSuffix("특별자치시")
        || token.hasSuffix("특별자치도") || token.hasSuffix("도")
}

private func isDistrictToken(_ token: String) -> Bool {
    // 한 글자짜리 「구」·「시」는 지명이 아니다.
    token.count >= 2 && (token.hasSuffix("구") || token.hasSuffix("시") || token.hasSuffix("군"))
}

/// 생년월일을 **연령대**로 접는다 — `"10s"`·`"20s"`·…·`"60s+"`. 만 나이 기준이고 생일 당일부터 다음 나이다
/// (`AuthPolicy.isOldEnough` 와 같은 판정).
///
/// 생년월일 자체를 보내지 않는 이유: 생년월일 + 성별 + 출발 지역이면 사람이 좁혀진다. 「20대 남성이 많다」를
/// 알기에는 연령대로 충분하다. `today` 를 받는 건 경계값(생일 전날·당일)을 검증하기 위해서다.
public func ageBand(birthDate: LocalDate, today: LocalDate) -> String {
    var age = today.year - birthDate.year
    if today.isBefore(birthDate.plusYears(age)) { age -= 1 }
    if age < 20 { return "10s" }
    if age >= 60 { return "60s+" }
    return "\(age / 10 * 10)s"
}
