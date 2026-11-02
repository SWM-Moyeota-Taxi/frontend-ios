/// 서버가 앱 시작 시 알려주는 운영 설정(`GET /api/v1/config`).
///
/// - Parameter taxiEnabled: 기사(택시) 기능이 켜져 있는가. **false 면 동승 모드(실배포)** — 정원이 차도 기사를 부르지 않고
///   방은 `COMPLETED` 에 머문다. 참여자가 「합승 완료」로 닫거나 30분 방치 시 서버가 닫는다.
///   true(택시 모드 — 개발·발표·평가) 면 정원이 차는 즉시 서버가 기사 매칭을 시작하고 25 배차 → 26 운행으로 이어진다.
///
///   앱은 이 값으로 **문구와 버튼만** 가른다. 어느 화면으로 갈지는 서버가 주는 방 status 가 정한다
///   (동승 모드 서버는 `DISPATCHING`·`ONGOING` 을 내지 않으므로 택시 화면에 닿을 길이 없다).
public struct AppConfig: Hashable, Sendable {
    public var taxiEnabled: Bool
    /// 이 값보다 낮은 `versionCode` 는 **더 못 쓰게 막는다**. 서버가 안 주면 null 이고, 그러면 통과다.
    ///
    /// 왜 자리를 미리 만드나: 앱이 한 번 스토어에 나가면 그 코호트는 영영 업데이트를 강제할 수 없다.
    /// 나중에 서버가 이 필드를 내려줘도 **그 필드를 모르는 빌드**는 조용히 무시한다
    /// (JSON 디코더가 모르는 키를 무시한다). 2026-11-01 현재 서버는 이 필드를 주지 않는다(실측).
    public var minVersionCode: Int?
    /// 막지는 않고 한 번 알리기만 할 기준. 서버가 안 주면 null 이고, 그러면 안내도 없다.
    public var recommendedVersionCode: Int?

    public init(
        taxiEnabled: Bool,
        minVersionCode: Int? = nil,
        recommendedVersionCode: Int? = nil
    ) {
        self.taxiEnabled = taxiEnabled
        self.minVersionCode = minVersionCode
        self.recommendedVersionCode = recommendedVersionCode
    }

    /// 설정을 못 받았을 때의 값 — **동승 모드(false)**.
    ///
    /// 실사용자가 쓰는 서버는 동승 모드다. 서버가 응답하지 못하는 순간(장애·네트워크)에 택시 모드 문구
    /// (「기사님을 찾고 있어요」)가 뜨면 실제 서비스와 다른 화면을 보여주게 된다. 반대로 택시 모드 서버에서
    /// 이 기본값에 걸리면 정원이 찬 짧은 순간 「합승 완료」 버튼이 보일 뿐이고, 서버는 기사 매칭이 시작된
    /// 방의 완료 호출을 409 로 거절한다 — 사고가 아니라 문구 어긋남이다.
    ///
    /// `minVersionCode`·`recommendedVersionCode` 가 **null 이라 아무도 막히지 않는다** —
    /// 서버 장애로 전원이 잠기는 쪽이 낡은 앱이 도는 것보다 훨씬 나쁘다.
    public static let Default = AppConfig(taxiEnabled: false)
}
