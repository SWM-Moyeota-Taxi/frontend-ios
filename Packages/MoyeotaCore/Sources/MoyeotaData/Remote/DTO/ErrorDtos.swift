/// 백엔드 common/exception/ErrorResponse(code, message) 대응 — 모든 도메인의 4xx/5xx 공통 본문.
/// 실측: 404 {"code":"ADDRESS_NOT_FOUND","message":"해당 좌표의 주소를 찾을 수 없습니다."}
///
/// 스프링이 직접 만드는 404(잘못된 경로 등)는 이 shape 이 아니라 code 가 없다.
/// 그래서 "서버가 의도한 에러"인지 판별하려면 상태 코드만이 아니라 `code` 까지 봐야 한다.
public struct ApiErrorDto: Decodable, Equatable, Sendable {
    public var code: String?
    public var message: String?

    public init(code: String? = nil, message: String? = nil) {
        self.code = code
        self.message = message
    }
}
