import Foundation

/// Kotlin `Throwable` 의 자리 — 도메인 예외가 공통으로 들고 있는 `message`·`cause`.
///
/// Swift `Error` 에는 없는 두 프로퍼티다. `LocalizedError` 를 함께 채택해 `error.localizedDescription` 도
/// 같은 `message` 를 돌려준다(원본 `e.message` 를 그대로 쓰던 자리).
public protocol Throwable: LocalizedError, Sendable {
    var message: String? { get }
    var cause: (any Error)? { get }
}

extension Throwable {
    public var errorDescription: String? { message }
}

/// `java.lang.IllegalStateException` 의 자리. `RideRepository.reportEmergency` 처럼 **한국어 메시지를 실어**
/// 던지는 계약이 있고, 그 메시지를 화면이 보여 준다.
public struct IllegalStateException: Throwable {
    public let message: String?
    public let cause: (any Error)?

    public init(_ message: String? = nil, cause: (any Error)? = nil) {
        self.message = message
        self.cause = cause
    }
}

/// `java.lang.IllegalArgumentException` 의 자리. 원본에서 Retrofit 이 잘못된 선언·base URL 을 거부할 때 던진다.
public struct IllegalArgumentException: Throwable {
    public let message: String?
    public let cause: (any Error)?

    public init(_ message: String? = nil, cause: (any Error)? = nil) {
        self.message = message
        self.cause = cause
    }
}

/// `java.io.IOException` 의 자리. `URLSession` 이 던지는 `URLError` 말고, 앱이 직접 만드는 전송 실패
/// (응답 없이 끊긴 스트림·소켓 등)에 쓴다. `Diagnostics` 는 이것을 결함으로 보고하지 않는다.
public struct IOException: Throwable {
    public let message: String?
    public let cause: (any Error)?

    public init(_ message: String? = nil, cause: (any Error)? = nil) {
        self.message = message
        self.cause = cause
    }
}
