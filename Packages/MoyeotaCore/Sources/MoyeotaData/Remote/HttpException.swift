import Foundation
import MoyeotaDomain

/// `retrofit2.Response` 의 자리 — 상태 코드와 성공 본문 또는 에러 본문.
///
/// 원본의 `Response<T>` 를 돌려주는 API(`PlaceApi.reverseGeocode`)는 4xx 를 예외 없이 그대로 받아
/// 호출부가 판정한다. 그 판정을 옮기려면 같은 모양이 필요하다.
public struct Response<T> {
    private let statusCode: Int
    private let successBody: T?
    private let rawErrorBody: Data?

    private init(statusCode: Int, successBody: T?, rawErrorBody: Data?) {
        self.statusCode = statusCode
        self.successBody = successBody
        self.rawErrorBody = rawErrorBody
    }

    public static func success(_ body: T?, code: Int = 200) -> Response<T> {
        Response(statusCode: code, successBody: body, rawErrorBody: nil)
    }

    public static func error(_ code: Int, _ errorBody: String?) -> Response<T> {
        Response(statusCode: code, successBody: nil, rawErrorBody: errorBody.map { Data($0.utf8) })
    }

    public static func error(_ code: Int, bytes: Data) -> Response<T> {
        Response(statusCode: code, successBody: nil, rawErrorBody: bytes)
    }

    public var isSuccessful: Bool { (200..<300).contains(statusCode) }

    public func code() -> Int { statusCode }

    public func body() -> T? { successBody }

    /// 에러 본문 원문. OkHttp 와 달리 이미 메모리에 있는 값이라 다시 읽어도 사라지지 않지만, 호출 규칙은
    /// 원본과 같다 — 한 번 읽어 결과를 들고 다닌다.
    public func errorBody() -> String? {
        rawErrorBody.map { String(decoding: $0, as: UTF8.self) }
    }

    /// 에러 본문 바이트 그대로. 게이트웨이가 UTF-8 이 아닌 본문을 줘도 손실 없이 볼 수 있다.
    public func errorBodyBytes() -> Data? { rawErrorBody }
}

extension Response: Sendable where T: Sendable {}

/// `retrofit2.HttpException` 의 자리 — 서버가 2xx 가 아닌 응답을 줬다.
///
/// 전송 계층 실패(`URLError` 등, 원본의 `IOException`)와 갈라야 화면이 「서버가 거절했다」와 「응답을 못 받았다」를
/// 다르게 안내할 수 있다.
public struct HttpException: Throwable {
    private let statusCode: Int
    private let rawErrorBody: Data?

    public init<T>(_ response: Response<T>) {
        statusCode = response.code()
        rawErrorBody = response.errorBodyBytes()
    }

    public func code() -> Int { statusCode }

    /// 에러 본문 원문(원본의 `response()?.errorBody()?.string()`).
    public func errorBody() -> String? {
        rawErrorBody.map { String(decoding: $0, as: UTF8.self) }
    }

    /// 에러 본문 바이트 그대로.
    public func errorBodyBytes() -> Data? { rawErrorBody }

    public var message: String? { "HTTP \(statusCode)" }

    public var cause: (any Error)? { nil }
}
