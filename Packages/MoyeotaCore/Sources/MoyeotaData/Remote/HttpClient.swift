import Foundation
import MoyeotaDomain
import os

/// `okhttp3.Response` 의 자리. 본문은 메모리에 이미 다 읽혀 있다.
///
/// `priorResponse` 는 OkHttp 처럼 재시도 앞의 응답을 이어 붙인다 — `TokenAuthenticator` 가 재시도 횟수를 여기서 센다.
public final class HttpRawResponse: Sendable {
    public let request: URLRequest
    public let code: Int
    /// 키는 소문자다. 서버·프록시마다 대소문자가 달라 비교를 한곳으로 모은다.
    public let headers: [String: String]
    public let body: Data
    public let priorResponse: HttpRawResponse?
    /// `HttpClient.stream` 의 2xx 응답일 때만 있다. 이때 `body` 는 비어 있다.
    public let bytes: URLSession.AsyncBytes?

    public init(
        request: URLRequest,
        code: Int,
        headers: [String: String] = [:],
        body: Data = Data(),
        priorResponse: HttpRawResponse? = nil,
        bytes: URLSession.AsyncBytes? = nil
    ) {
        self.request = request
        self.code = code
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
        self.body = body
        self.priorResponse = priorResponse
        self.bytes = bytes
    }

    public var isSuccessful: Bool { (200..<300).contains(code) }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }

    func withPrior(_ prior: HttpRawResponse?) -> HttpRawResponse {
        HttpRawResponse(request: request, code: code, headers: headers, body: body, priorResponse: prior, bytes: bytes)
    }
}

/// `okhttp3.Interceptor.Chain` 의 자리.
public struct InterceptorChain: Sendable {
    public let request: URLRequest
    let next: @Sendable (URLRequest) async throws -> HttpRawResponse

    public func proceed(_ request: URLRequest) async throws -> HttpRawResponse {
        try await next(request)
    }
}

/// `okhttp3.Interceptor` 의 자리. 재시도 바깥에서 **요청 한 건에 한 번** 돈다 — 재시도는 이 안쪽에서 일어난다.
public protocol Interceptor: Sendable {
    func intercept(chain: InterceptorChain) async throws -> HttpRawResponse
}

/// `okhttp3.Authenticator` 의 자리. 401 을 받으면 재시도할 요청을 돌려주고, 포기하면 null 이다.
public protocol Authenticator: Sendable {
    func authenticate(response: HttpRawResponse) async -> URLRequest?
}

/// `OkHttpClient` 의 자리 — `URLSession` 위에 OkHttp 의 인터셉터·재시도 순서를 그대로 얹는다.
///
/// 순서: 인터셉터(앞에서 뒤로) → 전송 → 후속 요청 판정(401·408·503). 후속 요청은 인터셉터를 다시 지나지 않는다.
/// `URLSession` 은 리다이렉트를 스스로 따라가므로 그 부분만 여기 없다(`HttpRedirectDelegate`).
public final class HttpClient: Sendable {
    public let session: URLSession
    private let interceptors: [any Interceptor]
    private let authenticator: (any Authenticator)?

    /// OkHttp `RetryAndFollowUpInterceptor.MAX_FOLLOW_UPS`.
    private static let maxFollowUps = 20

    public init(
        session: URLSession,
        interceptors: [any Interceptor] = [],
        authenticator: (any Authenticator)? = nil
    ) {
        self.session = session
        self.interceptors = interceptors
        self.authenticator = authenticator
    }

    /// 요청 한 건을 끝까지 보내고 응답 본문까지 읽는다. 2xx 가 아니어도 던지지 않는다 — 판정은 호출부 몫이다.
    public func execute(_ request: URLRequest) async throws -> HttpRawResponse {
        try await proceed(request, index: 0, streaming: false)
    }

    /// SSE 용. 인증·재시도는 `execute` 와 같고, 2xx 면 본문을 읽지 않은 채 `bytes` 로 돌려준다.
    /// 2xx 가 아니면 본문을 **읽지 않고** 연결을 닫아 상태 코드만 돌려준다(`bytes` 는 null, `body` 는 비어 있다).
    /// 원본 `onFailure(response)` 자리다 — okhttp-sse 도 본문을 읽지 않고, 판정은 상태 코드뿐이다. 본문을 기다리면
    /// 그게 멈추거나 깨질 때 받아 둔 403·404·401 까지 잃고 전송 실패(= 끊김, 재연결)로 뭉개진다.
    public func stream(_ request: URLRequest) async throws -> HttpRawResponse {
        try await proceed(request, index: 0, streaming: true)
    }

    private func proceed(_ request: URLRequest, index: Int, streaming: Bool) async throws -> HttpRawResponse {
        guard index < interceptors.count else {
            return try await sendWithFollowUps(request, streaming: streaming)
        }
        let chain = InterceptorChain(request: request) { [self] next in
            try await proceed(next, index: index + 1, streaming: streaming)
        }
        return try await interceptors[index].intercept(chain: chain)
    }

    private func sendWithFollowUps(_ initial: URLRequest, streaming: Bool) async throws -> HttpRawResponse {
        var request = initial
        var prior: HttpRawResponse?
        var followUps = 0
        while true {
            try Task.checkCancellation()
            let response = try await send(request, streaming: streaming).withPrior(prior)
            guard let next = try await followUpRequest(for: response) else { return response }
            followUps += 1
            if followUps > Self.maxFollowUps {
                throw IOException("Too many follow-up requests: \(followUps)")
            }
            request = next
            prior = response
        }
    }

    /// OkHttp `followUpRequest` 중 `URLSession` 이 대신해 주지 않는 세 갈래.
    private func followUpRequest(for response: HttpRawResponse) async throws -> URLRequest? {
        switch response.code {
        case 401:
            guard let authenticator else { return nil }
            // 부른 쪽의 취소를 재발급에 물려주지 않는다. 회전 방식이라, 재발급이 서버에 닿은 뒤 응답만 버리면
            // 옛 리프레시는 이미 죽어 다음 재발급이 거절되고 **멀쩡한 세션이 날아간다.**
            // 원본도 같다 — 호출 취소는 재발급(별도 Call)을 멈추지 않고 호출부만 먼저 풀어 준다.
            let authentication = Task { await authenticator.authenticate(response: response) }
            return try await authentication.valueUnlessCancelled()

        case 408:
            // 서버가 「이번 요청은 시간이 넘었다, 다시 보내라」고 답한 경우. 연달아 408 이면 그만둔다.
            if response.priorResponse?.code == 408 { return nil }
            if retryAfter(response, defaultDelay: 0) > 0 { return nil }
            return response.request

        case 503:
            // `Retry-After: 0` 일 때만 곧바로 다시 보낸다. 헤더가 없으면 재시도하지 않는다.
            if response.priorResponse?.code == 503 { return nil }
            return retryAfter(response, defaultDelay: Int.max) == 0 ? response.request : nil

        default:
            return nil
        }
    }

    private func retryAfter(_ response: HttpRawResponse, defaultDelay: Int) -> Int {
        guard let header = response.header("Retry-After") else { return defaultDelay }
        let isDigits = !header.isEmpty && header.utf8.allSatisfy { (48...57).contains($0) }
        return isDigits ? (Int(header) ?? Int.max) : Int.max
    }

    private func send(_ request: URLRequest, streaming: Bool) async throws -> HttpRawResponse {
        do {
            if streaming {
                let (bytes, response) = try await session.bytes(for: request)
                let http = try httpResponse(response)
                if (200..<300).contains(http.statusCode) {
                    return HttpRawResponse(
                        request: request, code: http.statusCode, headers: headers(of: http), bytes: bytes
                    )
                }
                bytes.task.cancel()
                return HttpRawResponse(request: request, code: http.statusCode, headers: headers(of: http))
            }
            let (body, response) = try await session.data(for: request)
            let http = try httpResponse(response)
            return HttpRawResponse(request: request, code: http.statusCode, headers: headers(of: http), body: body)
        } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
            throw CancellationError()
        }
    }

    private func httpResponse(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else {
            throw IOException("HTTP 응답이 아니다: \(type(of: response))")
        }
        return http
    }

    private func headers(of response: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        return headers
    }
}

extension Task where Failure == Never {
    /// 태스크의 결과를 기다리되, **기다리는 쪽이 취소되면 먼저 풀려난다.** 태스크 자체는 멈추지 않는다.
    func valueUnlessCancelled() async throws -> Success {
        let waiter = OSAllocatedUnfairLock<CheckedContinuation<Success, any Error>?>(initialState: nil)
        @Sendable func take() -> CheckedContinuation<Success, any Error>? {
            waiter.withLock { current in
                defer { current = nil }
                return current
            }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter.withLock { $0 = continuation }
                // 핸들러가 등록 전에 이미 돌았을 수 있다.
                if Task<Never, Never>.isCancelled {
                    take()?.resume(throwing: _Concurrency.CancellationError())
                    return
                }
                Task<Void, Never> {
                    let value = await self.value
                    take()?.resume(returning: value)
                }
            }
        } onCancel: {
            take()?.resume(throwing: _Concurrency.CancellationError())
        }
    }
}

/// `URLSession` 이 따라가는 리다이렉트에서 OkHttp 와 같이 **다른 출처로는 `Authorization` 을 넘기지 않는다.**
///
/// 액세스 토큰은 30분 동안 전 API 를 호출할 수 있는 자격증명이다 — 남의 호스트 로그에 남으면 안 된다
/// (`NetworkModule.Apis.imageClient` 주석과 같은 근거).
final class HttpRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(Self.redirected(request, from: task.originalRequest?.url))
    }

    static func redirected(_ request: URLRequest, from origin: URL?) -> URLRequest {
        guard let origin, let target = request.url else { return request }
        let sameOrigin = origin.scheme == target.scheme && origin.host == target.host && origin.port == target.port
        if sameOrigin { return request }
        var stripped = request
        stripped.setValue(nil, forHTTPHeaderField: HEADER_AUTHORIZATION)
        return stripped
    }
}
