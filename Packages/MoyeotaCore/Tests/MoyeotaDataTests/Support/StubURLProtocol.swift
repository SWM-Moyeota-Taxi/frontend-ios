import Foundation
import os
@testable import MoyeotaData

/// MockWebServer 의 자리. `URLProtocol` 이 요청을 가로채므로 소켓이 열리지 않는다.
///
/// Swift Testing 은 테스트를 병렬로 돌린다. 전역 핸들러 하나를 나눠 쓰면 서로의 응답을 받게 되므로,
/// 서버마다 **자기만의 호스트**를 갖고 프로토콜이 호스트로 서버를 찾는다. 호스트는 `.invalid`(RFC 2606)라
/// 스텁을 빠져나가도 실제 네트워크에 닿을 수 없다.
final class StubServer: Sendable {
    let host = "stub-\(UUID().uuidString.lowercased()).invalid"
    private let recorded = OSAllocatedUnfairLock<[RecordedRequest]>(initialState: [])
    private let handler: @Sendable (RecordedRequest) -> StubResponse

    init(handler: @escaping @Sendable (RecordedRequest) -> StubResponse) {
        self.handler = handler
        StubURLProtocol.register(self)
    }

    convenience init(status: Int = 200, body: String = "", headers: [String: String] = [:]) {
        self.init { _ in StubResponse(status: status, body: body, headers: headers) }
    }

    var baseUrl: String { "http://\(host)/" }

    func url(_ path: String) -> String { baseUrl + path }

    var requests: [RecordedRequest] { recorded.withLock { $0 } }

    /// 인터셉터가 없는 순정 세션.
    func session(requestTimeout: TimeInterval = 20) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.timeoutIntervalForRequest = requestTimeout
        return URLSession(configuration: configuration)
    }

    /// Bearer 도 재발급도 없는 `RestClient`. 원본 테스트의 `Retrofit.Builder()` 자리.
    func rest() throws -> RestClient {
        try RestClient(baseUrl: baseUrl, client: HttpClient(session: session()))
    }

    fileprivate func handle(_ request: RecordedRequest) -> StubResponse {
        recorded.withLock { $0.append(request) }
        return handler(request)
    }
}

struct StubResponse: Sendable {
    var status = 200
    var body = Data()
    var headers: [String: String] = [:]
    var failure: URLError?
    var delay: Duration?

    init(status: Int = 200, body: String = "", headers: [String: String] = [:], delay: Duration? = nil) {
        self.status = status
        self.body = Data(body.utf8)
        self.headers = headers
        self.delay = delay
    }

    init(status: Int, bytes: Data) {
        self.status = status
        self.body = bytes
    }

    /// 응답 대신 전송 실패 — 연결 실패·타임아웃을 재현한다.
    init(failure: URLError) {
        self.failure = failure
    }
}

struct RecordedRequest: Sendable {
    let method: String
    let url: URL
    let headers: [String: String]
    let body: Data?

    var urlString: String { url.absoluteString }
    var path: String { url.path }
    var query: String? { URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery }
    var bodyString: String? { body.map { String(decoding: $0, as: UTF8.self) } }

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    func queryParameter(_ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let servers = OSAllocatedUnfairLock<[String: StubServer]>(initialState: [:])
    private let stopped = OSAllocatedUnfairLock(initialState: false)

    static func register(_ server: StubServer) {
        servers.withLock { $0[server.host] = server }
    }

    private static func server(for request: URLRequest) -> StubServer? {
        guard let host = request.url?.host else { return nil }
        return servers.withLock { $0[host] }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        server(for: request) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let server = Self.server(for: request), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let recorded = RecordedRequest(
            method: request.httpMethod ?? "GET",
            url: url,
            headers: request.allHTTPHeaderFields ?? [:],
            body: readBody()
        )
        let response = server.handle(recorded)
        if let delay = response.delay {
            let seconds = Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [self] in
                deliver(response, url: url)
            }
        } else {
            deliver(response, url: url)
        }
    }

    override func stopLoading() {
        stopped.withLock { $0 = true }
    }

    private func deliver(_ stub: StubResponse, url: URL) {
        if stopped.withLock({ $0 }) { return }
        if let failure = stub.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        guard let response = HTTPURLResponse(
            url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: stub.headers
        ) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !stub.body.isEmpty {
            client?.urlProtocol(self, didLoad: stub.body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    /// `URLSession` 은 `httpBody` 를 스트림으로 바꿔 넘긴다. 빈 본문은 null 로 본다 — OkHttp 의 「본문 없음」과
    /// 빈 본문을 여기서는 가를 수 없으므로, 그 차이는 `LoopbackWireTest` 가 실제 소켓에서 본다.
    private func readBody() -> Data? {
        if let body = request.httpBody { return body.isEmpty ? nil : body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        return data.isEmpty ? nil : data
    }
}

/// 조건이 참이 될 때까지 기다린다. 비동기로 뒤따르는 부수효과를 확인할 때만 쓴다.
func waitUntil(timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}
