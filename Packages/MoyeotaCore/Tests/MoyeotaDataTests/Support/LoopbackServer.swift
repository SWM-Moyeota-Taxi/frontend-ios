import Foundation
import Network
import os

/// 이 프로세스 안의 진짜 TCP 서버(127.0.0.1 전용). `URLProtocol` 스텁은 `URLSession` 이 실제로 소켓에 쓰는 바이트를
/// 보여 주지 못하므로, 그 차이가 서버 계약인 자리(`LoopbackWireTest`)에서만 쓴다.
final class LoopbackServer: Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "moyeota.test.loopback")
    private let responses: @Sendable (Int) -> String?
    private let recorded = OSAllocatedUnfairLock<[String]>(initialState: [])

    /// `responses` 는 요청 순번을 받아 응답 원문을 준다. null 이면 답하지 않는다(타임아웃 재현).
    init(responses: @escaping @Sendable (Int) -> String?) throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        listener = try NWListener(using: parameters)
        self.responses = responses
    }

    var requests: [String] { recorded.withLock { $0 } }

    func start() async throws -> String {
        let port = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, any Error>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            listener.stateUpdateHandler = { [listener] state in
                let result: Result<UInt16, any Error>
                switch state {
                case .ready: result = .success(listener.port?.rawValue ?? 0)
                case .failed(let error): result = .failure(error)
                default: return
                }
                let isFirst = resumed.withLock { value -> Bool in
                    defer { value = true }
                    return !value
                }
                if isFirst { continuation.resume(with: result) }
            }
            listener.newConnectionHandler = { [self] connection in
                connection.start(queue: queue)
                receive(connection, buffer: Data())
            }
            listener.start(queue: queue)
        }
        return "http://127.0.0.1:\(port)/"
    }

    func stop() {
        listener.cancel()
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, isComplete, error in
            var next = buffer
            if let data { next.append(data) }
            if isRequestComplete(next) {
                respond(connection, request: String(decoding: next, as: UTF8.self))
                // 같은 연결로 다음 요청이 올 수 있다.
                receive(connection, buffer: Data())
            } else if !isComplete, error == nil {
                receive(connection, buffer: next)
            }
        }
    }

    private func isRequestComplete(_ data: Data) -> Bool {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return false }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self)
        let contentLength = head.split(separator: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
        return data.count - end.upperBound >= contentLength
    }

    private func respond(_ connection: NWConnection, request: String) {
        let index = recorded.withLock { requests -> Int in
            requests.append(request)
            return requests.count - 1
        }
        guard let response = responses(index) else { return }
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in })
    }
}
