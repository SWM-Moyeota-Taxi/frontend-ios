import Foundation

/// 서버 이벤트 이름(`RedisPartyChangeNotifier` · `PartySseRegistry`). 이 문자열이 계약이다
let EVENT_CONNECTED = "connected"
let EVENT_MEMBER_JOINED = "member-joined"
let EVENT_MEMBER_LEFT = "member-left"
let EVENT_CLOSED = "closed"

/// SSE 프레임 하나를 **서버 shape 그대로** 담은 data 계층 이벤트.
///
/// 도메인 `PartyEvent` 와 따로 두는 이유는 하나다: `connected`·`member-joined` 의 도메인 변환에는
/// **"누가 나인지"를 판정할 세션 uuid** 가 필요한데, 그 값은 요청 시점에 읽어야 하고 단일 출처가
/// 저장소(`RemoteRideRepository`)에 있다. SSE 수신기에 세션을 들려 보내면 파싱이 세션에 묶여 테스트가
/// 어려워지므로, 수신기는 **파싱까지만** 하고 도메인 변환은 매퍼(`PartyMappers.toPartyEvent`)에 맡긴다.
public enum PartySseEvent: Equatable, Sendable {
    /// `connected` — data 가 방 상세 전체 JSON(`PartyDetailResult`)이다. 기존 상세 DTO 를 그대로 재사용한다
    case snapshot(detail: PartyDetailResponse)

    /// `member-joined` — `{"member": {...}, "status": "..."}`
    case memberJoined(payload: MemberJoinedPayload)

    /// `member-left` — `{"publicId": "..."|null, "status": "...", "hostPublicId": "..."|null}`.
    /// `hostPublicId` 는 **승계 후의 방장**이다(Backend #240) — `MemberLeftPayload` 참고.
    case memberLeft(payload: MemberLeftPayload)

    /// `closed` — data 는 partyId 숫자 문자열이라 실을 값이 없다
    case closed

    /// 서버 프레임이 아니라 **앱이 알아챈 끊김**. `PartyEventSource` 의 재연결 루프가 낸다
    case disconnected
}

/// 프레임 하나를 읽은 결과.
///
/// 파싱 실패를 예외로 올리지 않는 게 이 타입의 존재 이유다 — **한 프레임이 깨졌다고 스트림을 죽이면
/// 서버가 이벤트를 늘리거나 필드를 바꾼 순간 대기 화면이 통째로 멈춘다.** 건너뛴 이유는 로그로만 남긴다.
enum PartySseFrame: Equatable, Sendable {
    case received(event: PartySseEvent)

    /// 흘려보낼 프레임. `reason` 은 로그 경고에만 쓴다
    case skipped(reason: String)
}

/// SSE 프레임(이벤트 이름 + data 문자열) → `PartySseEvent`. **네트워크 없이 테스트할 수 있는 순수 함수다.**
///
/// `closed` 의 data 는 JSON 이 아니라 partyId 숫자 문자열("42")이다 — 역직렬화를 시도하면 실패하므로
/// 아예 보지 않는다. 주석 프레임(`:ping`)은 `ServerSentEventReader` 가 삼켜 여기까지 오지 않는다.
func parsePartySseFrame(type: String?, data: String) -> PartySseFrame {
    switch type {
    case EVENT_CONNECTED:
        return decode(type: EVENT_CONNECTED) { .snapshot(detail: try decodeSseData(data)) }
    case EVENT_MEMBER_JOINED:
        return decode(type: EVENT_MEMBER_JOINED) { .memberJoined(payload: try decodeSseData(data)) }
    case EVENT_MEMBER_LEFT:
        return decode(type: EVENT_MEMBER_LEFT) { .memberLeft(payload: try decodeSseData(data)) }
    case EVENT_CLOSED:
        return .received(event: .closed)
    default:
        // 모르는 이벤트는 흘려보낸다 — 서버가 종류를 늘려도 앱이 멈추지 않는다
        return .skipped(reason: "모르는 이벤트 type=\(type ?? "null")")
    }
}

// 서버가 필드를 추가해도 깨지지 않게 한다 — NetworkModule 의 REST 디코더와 같은 정책.
private func decodeSseData<T: Decodable>(_ data: String) throws -> T {
    try MoyeotaJSON.decoder.decode(T.self, from: Data(data.utf8))
}

private func decode(type: String, _ block: () throws -> PartySseEvent) -> PartySseFrame {
    do {
        return .received(event: try block())
    } catch {
        return .skipped(reason: "\(type) 파싱 실패: \(error)")
    }
}
