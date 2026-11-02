import Foundation
import MoyeotaDomain

/// Retrofit 애노테이션(`@GET`·`@POST`·`@HTTP` …)의 자리. 메서드 한 개의 선언이다.
///
/// 각 API 구현은 이 값으로만 요청을 만든다. 그래서 `AuthenticatedPathContractTest` 가 읽는 경로·동사가
/// 실제로 나가는 값과 어긋날 수 없다 — 원본이 애노테이션을 리플렉션으로 못 박던 것과 같은 효력이다.
struct ApiRoute: Equatable, Sendable {
    enum Method: String, Sendable {
        case GET, POST, PUT, PATCH, DELETE
    }

    let method: Method
    let path: String
    let hasBody: Bool
    /// `@Query` 이름. 선언 순서대로 URL 에 실린다.
    let queryNames: [String]

    /// `{partyId}` 같은 경로 자리표시자 이름.
    var pathParameterNames: [String] {
        path.split(separator: "{", omittingEmptySubsequences: false).dropFirst().compactMap { piece in
            piece.split(separator: "}", omittingEmptySubsequences: false).first.map(String.init)
        }
    }

    static func GET(_ path: String, query: [String] = []) -> ApiRoute {
        ApiRoute(method: .GET, path: path, hasBody: false, queryNames: query)
    }

    static func POST(_ path: String) -> ApiRoute {
        ApiRoute(method: .POST, path: path, hasBody: true, queryNames: [])
    }

    static func PUT(_ path: String) -> ApiRoute {
        ApiRoute(method: .PUT, path: path, hasBody: true, queryNames: [])
    }

    static func PATCH(_ path: String) -> ApiRoute {
        ApiRoute(method: .PATCH, path: path, hasBody: true, queryNames: [])
    }

    /// Retrofit `@DELETE` 처럼 본문을 실을 수 없다. 본문이 필요하면 `HTTP(method:path:hasBody:)` 를 쓴다.
    static func DELETE(_ path: String) -> ApiRoute {
        ApiRoute(method: .DELETE, path: path, hasBody: false, queryNames: [])
    }

    /// Retrofit `@HTTP(method = ..., path = ..., hasBody = ...)`.
    static func HTTP(method: Method, path: String, hasBody: Bool) -> ApiRoute {
        ApiRoute(method: method, path: path, hasBody: hasBody, queryNames: [])
    }
}

/// API 하나의 메서드 전체. `allCases` 가 원본의 `declaredMethods` 자리다.
/// 케이스 이름(`rawValue`)은 원본 메서드 이름이다.
protocol ApiRouteSet: CaseIterable {
    var route: ApiRoute { get }
}

/// `Retrofit` 의 자리 — base URL 결합, 본문 직렬화, 응답 해석.
struct RestClient: Sendable {
    let baseUrl: String
    let client: HttpClient

    /// Retrofit 처럼 잘못된 base URL 은 만드는 시점에 거부한다. 끝의 `/` 가 없으면 상대 경로가 마지막 조각을 덮어쓴다.
    init(baseUrl: String, client: HttpClient) throws {
        guard let url = URL(string: baseUrl), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host?.isEmpty == false
        else {
            throw IllegalArgumentException("Illegal URL: \(baseUrl)")
        }
        guard baseUrl.hasSuffix("/") else {
            throw IllegalArgumentException("baseUrl must end in /: \(baseUrl)")
        }
        self.baseUrl = baseUrl
        self.client = client
    }

    func newRequest(
        _ route: ApiRoute,
        path: KeyValuePairs<String, Int64> = [:],
        query: KeyValuePairs<String, String?> = [:],
        body: (any Encodable)? = nil
    ) throws -> URLRequest {
        if body != nil, !route.hasBody {
            throw IllegalArgumentException("Non-body HTTP method cannot contain @Body or @Field parameters.")
        }
        guard path.map(\.key) == route.pathParameterNames else {
            throw IllegalArgumentException("경로 인자가 선언과 다르다: \(route.path)")
        }
        guard query.map(\.key) == route.queryNames else {
            throw IllegalArgumentException("쿼리 인자가 선언과 다르다: \(route.path)")
        }

        var urlString = baseUrl + path.reduce(route.path) { partial, parameter in
            partial.replacingOccurrences(of: "{\(parameter.key)}", with: String(parameter.value))
        }
        // Retrofit 은 `@Query` 의 null 을 **아예 싣지 않는다**(`cursor=` 도 아니다).
        let items = query.compactMap { item in
            item.value.map { "\(encodeQueryComponent(item.key))=\(encodeQueryComponent($0))" }
        }
        if !items.isEmpty {
            urlString += "?" + items.joined(separator: "&")
        }
        guard let url = URL(string: urlString) else {
            throw IllegalArgumentException("Illegal URL: \(urlString)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = route.method.rawValue
        if let body {
            request.httpBody = try MoyeotaJSON.encoder.encode(body)
            // OkHttp `String.toRequestBody` 가 charset 을 붙인 그대로다.
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        } else if route.hasBody {
            // 본문 없는 POST 도 Retrofit 은 빈 본문을 싣는다(`Content-Length: 0`).
            request.httpBody = Data()
        }
        return request
    }

    /// `suspend fun x(): T`. 2xx 가 아니면 `HttpException`, 204/205 면 Retrofit 처럼 예외다.
    func call<T: Decodable>(
        _ route: ApiRoute,
        path: KeyValuePairs<String, Int64> = [:],
        query: KeyValuePairs<String, String?> = [:],
        body: (any Encodable)? = nil
    ) async throws -> T {
        let request = try newRequest(route, path: path, query: query, body: body)
        let raw = try await client.execute(request)
        guard raw.isSuccessful else {
            throw HttpException(Response<Void>.error(raw.code, bytes: raw.body))
        }
        guard !isNoContent(raw.code) else {
            throw IllegalStateException(
                "Response from \(route.method.rawValue) \(route.path) was null but response body type was declared as non-null"
            )
        }
        return try MoyeotaJSON.decoder.decode(T.self, from: raw.body)
    }

    /// `suspend fun x()`(반환형 Unit). 2xx 면 본문을 보지 않고 끝난다.
    func callUnit(
        _ route: ApiRoute,
        path: KeyValuePairs<String, Int64> = [:],
        query: KeyValuePairs<String, String?> = [:],
        body: (any Encodable)? = nil
    ) async throws {
        let request = try newRequest(route, path: path, query: query, body: body)
        let raw = try await client.execute(request)
        guard raw.isSuccessful else {
            throw HttpException(Response<Void>.error(raw.code, bytes: raw.body))
        }
    }

    /// `suspend fun x(): Response<T>` / `Call<T>.execute()`. 2xx 가 아니어도 던지지 않는다.
    /// 전송 실패와 2xx 본문의 파싱 실패만 던진다. 204/205 면 `body()` 가 null 이다.
    func response<T: Decodable>(
        _ route: ApiRoute,
        path: KeyValuePairs<String, Int64> = [:],
        query: KeyValuePairs<String, String?> = [:],
        body: (any Encodable)? = nil
    ) async throws -> Response<T> {
        let request = try newRequest(route, path: path, query: query, body: body)
        let raw = try await client.execute(request)
        guard raw.isSuccessful else {
            return .error(raw.code, bytes: raw.body)
        }
        if isNoContent(raw.code) {
            return .success(nil, code: raw.code)
        }
        return .success(try MoyeotaJSON.decoder.decode(T.self, from: raw.body), code: raw.code)
    }

    private func isNoContent(_ code: Int) -> Bool {
        code == 204 || code == 205
    }
}

/// OkHttp `HttpUrl.addQueryParameter` 와 같은 인코딩.
///
/// `URLQueryItem` 을 쓰면 안 된다 — `+` 를 그대로 두는데 Spring 은 쿼리의 `+` 를 공백으로 읽어,
/// 장소 검색어나 채팅 검색어의 `+` 가 사라진다. 그대로 두는 문자는 영숫자와 `*`·`-`·`.`·`_` 뿐이다.
func encodeQueryComponent(_ value: String) -> String {
    var encoded = ""
    for byte in value.utf8 {
        switch byte {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2A, 0x2D, 0x2E, 0x5F:
            encoded.unicodeScalars.append(Unicode.Scalar(byte))
        default:
            encoded += String(format: "%%%02X", byte)
        }
    }
    return encoded
}

/// Retrofit `ToStringConverter` 자리. Java `Double.toString` 과 Swift 표기는 0.001 미만·1e7 이상에서만 갈리는데
/// (`1.0E-4` / `0.0001`) 좌표는 그 범위에 없고, 어느 쪽이든 서버가 같은 값으로 읽는다.
func queryValue(_ value: Double) -> String {
    String(value)
}
