import Foundation
import Network
import os

/// 응답을 **나눠서** 보내는 HTTP 서버(127.0.0.1). `LoopbackServer` 는 한 번에 답하고 끝이라, 열어 둔 채
/// 조금씩 흘리는 SSE 를 재현하지 못한다. 요청 헤더까지 받으면 `onRequest` 를 부른다.
final class LoopbackStreamServer: Sendable {
    final class Exchange: Sendable {
        let index: Int
        let request: String
        private let connection: NWConnection
        private let peerClosed = OSAllocatedUnfairLock(initialState: false)

        fileprivate init(index: Int, request: String, connection: NWConnection) {
            self.index = index
            self.request = request
            self.connection = connection
        }

        func send(_ text: String) {
            connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in })
        }

        func close() {
            connection.send(content: nil, isComplete: true, completion: .contentProcessed { [connection] _ in connection.cancel() })
        }

        /// 클라이언트가 연결을 끊었는가.
        var isPeerClosed: Bool { peerClosed.withLock { $0 } }

        fileprivate func markPeerClosed() {
            peerClosed.withLock { $0 = true }
        }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "moyeota.test.loopback-stream")
    private let onRequest: @Sendable (Exchange) -> Void
    private let exchangesLock = OSAllocatedUnfairLock<[Exchange]>(initialState: [])

    init(onRequest: @escaping @Sendable (Exchange) -> Void) throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        listener = try NWListener(using: parameters)
        self.onRequest = onRequest
    }

    var exchanges: [Exchange] { exchangesLock.withLock { $0 } }

    func start() async throws -> String {
        let port = try await startListener(listener, queue: queue) { [self] connection in
            connection.start(queue: queue)
            readHead(connection, buffer: Data())
        }
        return "http://127.0.0.1:\(port)/"
    }

    func stop() {
        listener.cancel()
        exchanges.forEach { $0.close() }
    }

    private func readHead(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, isComplete, error in
            var next = buffer
            if let data { next.append(data) }
            if next.range(of: Data("\r\n\r\n".utf8)) != nil {
                let request = String(decoding: next, as: UTF8.self)
                let exchange = exchangesLock.withLock { list -> Exchange in
                    let exchange = Exchange(index: list.count, request: request, connection: connection)
                    list.append(exchange)
                    return exchange
                }
                watchForClose(connection, exchange)
                onRequest(exchange)
            } else if !isComplete, error == nil {
                readHead(connection, buffer: next)
            }
        }
    }

    private func watchForClose(_ connection: NWConnection, _ exchange: Exchange) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] _, _, isComplete, error in
            if isComplete || error != nil {
                exchange.markPeerClosed()
            } else {
                watchForClose(connection, exchange)
            }
        }
    }
}

/// 진짜 웹소켓 서버(127.0.0.1). 업그레이드와 프레임 처리는 `Network` 가 맡으므로, `URLSessionWebSocketTask` 가
/// 소켓에 실제로 쓰는 메시지를 그대로 본다.
final class LoopbackWebSocketServer: Sendable {
    /// 서버가 본 웹소켓 프레임. 핑·클로즈까지 순서대로 남는다.
    enum Received: Equatable, Sendable {
        case text(String)
        case ping
        case close(code: UInt16?)
    }

    final class Peer: Sendable {
        let index: Int
        private let connection: NWConnection
        private let log = OSAllocatedUnfairLock<[Received]>(initialState: [])
        fileprivate let onText: @Sendable (Peer, String) -> Void

        fileprivate init(index: Int, connection: NWConnection, onText: @escaping @Sendable (Peer, String) -> Void) {
            self.index = index
            self.connection = connection
            self.onText = onText
        }

        var received: [Received] { log.withLock { $0 } }
        var texts: [String] {
            received.compactMap { if case .text(let text) = $0 { text } else { nil } }
        }

        fileprivate func record(_ item: Received) {
            log.withLock { $0.append(item) }
        }

        func send(_ text: String) {
            let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
            connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
        }

        /// Close 프레임을 보내고 소켓을 닫는다.
        func close(code: NWProtocolWebSocket.CloseCode = .protocolCode(.normalClosure)) {
            let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
            metadata.closeCode = code
            let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
            connection.send(content: nil, contentContext: context, isComplete: true, completion: .contentProcessed { [connection] _ in
                connection.cancel()
            })
        }

        fileprivate func cancel() {
            connection.cancel()
        }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "moyeota.test.loopback-ws")
    private let onText: @Sendable (Peer, String) -> Void
    private let peersLock = OSAllocatedUnfairLock<[Peer]>(initialState: [])
    private let offeredLock = OSAllocatedUnfairLock<[[String]]>(initialState: [])
    private let headersLock = OSAllocatedUnfairLock<[[String]]>(initialState: [])

    /// `answerPings = false` 면 pong 을 보내지 않는다(조용히 죽은 소켓 재현).
    init(answerPings: Bool = true, onText: @escaping @Sendable (Peer, String) -> Void) throws {
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = answerPings
        options.setClientRequestHandler(queue) { [offeredLock, headersLock] subprotocols, additionalHeaders in
            offeredLock.withLock { $0.append(subprotocols) }
            headersLock.withLock { $0.append(additionalHeaders.map { $0.name.lowercased() }) }
            return NWProtocolWebSocket.Response(status: .accept, subprotocol: subprotocols.first)
        }
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        listener = try NWListener(using: parameters)
        self.onText = onText
    }

    var peers: [Peer] { peersLock.withLock { $0 } }
    /// 연결마다 클라이언트가 내민 서브프로토콜.
    var offeredProtocols: [[String]] { offeredLock.withLock { $0 } }
    /// 연결마다 업그레이드 요청에 실린 추가 헤더 이름(소문자).
    var upgradeHeaderNames: [[String]] { headersLock.withLock { $0 } }

    func start() async throws -> String {
        let port = try await startListener(listener, queue: queue) { [self] connection in
            let peer = peersLock.withLock { list -> Peer in
                let peer = Peer(index: list.count, connection: connection, onText: onText)
                list.append(peer)
                return peer
            }
            connection.start(queue: queue)
            receive(connection, peer)
        }
        return "http://127.0.0.1:\(port)/"
    }

    func stop() {
        listener.cancel()
        peers.forEach { $0.cancel() }
    }

    private func receive(_ connection: NWConnection, _ peer: Peer) {
        connection.receiveMessage { [self] content, context, _, error in
            if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata {
                switch metadata.opcode {
                case .text:
                    let text = String(decoding: content ?? Data(), as: UTF8.self)
                    peer.record(.text(text))
                    peer.onText(peer, text)
                case .ping:
                    peer.record(.ping)
                case .close:
                    if case .protocolCode(let code) = metadata.closeCode {
                        peer.record(.close(code: code.rawValue))
                    } else if case .applicationCode(let code) = metadata.closeCode {
                        peer.record(.close(code: code))
                    } else {
                        peer.record(.close(code: nil))
                    }
                default:
                    break
                }
            }
            if error == nil { receive(connection, peer) }
        }
    }
}

/// 리스너가 준비되면 포트를 돌려준다.
private func startListener(
    _ listener: NWListener,
    queue: DispatchQueue,
    onConnection: @escaping @Sendable (NWConnection) -> Void
) async throws -> UInt16 {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, any Error>) in
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
        listener.newConnectionHandler = onConnection
        listener.start(queue: queue)
    }
}
