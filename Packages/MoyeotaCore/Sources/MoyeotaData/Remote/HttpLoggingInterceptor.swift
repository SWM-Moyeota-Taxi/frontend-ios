import Foundation
import os

/// `HttpLoggingInterceptor(Level.BODY)` 의 자리. `NetworkModule` 이 `debugLogging` 일 때만 붙인다.
///
/// 요청/응답 본문 전체가 남는다 — 채팅 메시지와 **인증 토큰**이 포함되므로 릴리즈에서는 반드시 꺼져야 한다.
/// 기본 싱크의 `os.Logger` 는 문자열을 `private` 로 남겨, Xcode 콘솔에서는 보이고 기기 로그 수집에서는 가려진다.
///
/// 인터셉터 체인의 맨 앞에 붙으므로 원본과 같이 `AuthHeaderInterceptor` 가 붙이기 전의 헤더를 찍는다.
struct HttpLoggingInterceptor: Interceptor {
    private static let logger = Logger(subsystem: "com.moyeota.data", category: "Http")

    static let defaultSink: @Sendable (String) -> Void = { line in
        logger.debug("\(line)")
    }

    private let sink: @Sendable (String) -> Void

    init(sink: @escaping @Sendable (String) -> Void = HttpLoggingInterceptor.defaultSink) {
        self.sink = sink
    }

    func intercept(chain: InterceptorChain) async throws -> HttpRawResponse {
        let request = chain.request
        let method = request.httpMethod ?? "GET"
        let url = request.url?.absoluteString ?? ""

        sink("--> \(method) \(url)")
        for (name, value) in (request.allHTTPHeaderFields ?? [:]).sorted(by: { $0.key < $1.key }) {
            sink("\(name): \(value)")
        }
        if let body = request.httpBody, !body.isEmpty { sink(describe(body)) }
        sink("--> END \(method)")

        let startedAt = ContinuousClock.now
        let response: HttpRawResponse
        do {
            response = try await chain.proceed(request)
        } catch {
            sink("<-- HTTP FAILED: \(error)")
            throw error
        }
        let elapsed = startedAt.duration(to: .now)
        let millis = elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000

        sink("<-- \(response.code) \(url) (\(millis)ms)")
        for (name, value) in response.headers.sorted(by: { $0.key < $1.key }) {
            sink("\(name): \(value)")
        }
        if response.bytes != nil {
            sink("<-- END HTTP (streaming body omitted)")
        } else {
            if !response.body.isEmpty { sink(describe(response.body)) }
            sink("<-- END HTTP (\(response.body.count)-byte body)")
        }
        return response
    }

    private func describe(_ body: Data) -> String {
        String(data: body, encoding: .utf8) ?? "(binary \(body.count)-byte body omitted)"
    }
}
