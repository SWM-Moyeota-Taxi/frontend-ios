/// SSE 이벤트 하나. okhttp-sse 의 `onEvent(id, type, data)` 인자 자리다.
struct ServerSentEvent: Equatable, Sendable {
    var id: String?
    var type: String?
    var data: String
}

/// `text/event-stream` 줄 파서 — okhttp-sse 의 `ServerSentEventReader` 자리. **네트워크 없이 테스트할 수 있다.**
///
/// 바이트를 하나씩 먹이고, 빈 줄에서 이벤트가 완성되면 돌려준다. 청크 경계가 어디에 떨어져도 결과가 같아야
/// 하므로 줄 끝(`\n`, `\r`, `\r\n`)도 상태로 들고 있다 — `\r` 과 `\n` 이 다른 청크로 와도 빈 줄이 두 번 생기지 않는다.
///
/// 원본과 같게 읽는 규칙:
/// - `data:` 는 앞에 개행을 붙여 쌓고 첫 개행을 떼어 낸다 — 여러 줄이 `\n` 으로 이어지고, 값이 비어 있어도
///   `data` 줄이 있었으면 빈 문자열 이벤트가 나간다. **`data` 줄이 없으면 이벤트도 없다**(`event:` 만 있는 묶음).
/// - 값 앞의 공백은 **한 칸만** 뗀다(`data:  x` → ` x`).
/// - `event` 는 이벤트마다 초기화되고, `id` 는 이벤트가 **나갈 때만** 다음 이벤트로 이어진다.
/// - 값이 빈 `event:`·`id:` 와 콜론 없는 `event`·`id` 줄은 null 이다. `id:` 는 이어받은 값을 지운다.
/// - 주석(`:ping`)과 모르는 필드, `retry:` 는 흘려보낸다 — 재연결 간격은 `reconnectDelayMs` 표가 정한다.
/// - 스트림이 빈 줄 없이 끝나면 쌓던 이벤트는 **버린다**(완성되지 않은 프레임이다).
struct ServerSentEventReader {
    private var line: [UInt8] = []
    private var skipNextLineFeed = false

    private var lastId: String?
    private var id: String?
    private var type: String?
    /// 첫 `data` 줄의 앞에도 개행이 붙는다. 비어 있으면 `data` 줄이 없었다는 뜻이다.
    private var data: [UInt8] = []

    /// 바이트 하나를 먹인다. 이 바이트로 이벤트가 완성되면 돌려준다.
    mutating func read(_ byte: UInt8) -> ServerSentEvent? {
        if skipNextLineFeed {
            skipNextLineFeed = false
            if byte == Self.lineFeed { return nil }
        }
        switch byte {
        case Self.lineFeed:
            return endLine()
        case Self.carriageReturn:
            skipNextLineFeed = true
            return endLine()
        default:
            line.append(byte)
            return nil
        }
    }

    private mutating func endLine() -> ServerSentEvent? {
        defer { line.removeAll(keepingCapacity: true) }
        if line.isEmpty { return completeEvent() }

        guard let colon = line.firstIndex(of: Self.colon) else {
            processField(name: line[...], value: nil)
            return nil
        }
        // 주석은 콜론으로 시작한다 — 이름이 비어 어느 필드와도 맞지 않아 그대로 흘러간다.
        var valueStart = line.index(after: colon)
        if valueStart < line.endIndex, line[valueStart] == Self.space {
            valueStart = line.index(after: valueStart)
        }
        processField(name: line[..<colon], value: line[valueStart...])
        return nil
    }

    private mutating func processField(name: ArraySlice<UInt8>, value: ArraySlice<UInt8>?) {
        if name.elementsEqual(Self.dataField) {
            data.append(Self.lineFeed)
            if let value { data.append(contentsOf: value) }
        } else if name.elementsEqual(Self.idField) {
            id = value.flatMap(Self.nonEmptyText)
        } else if name.elementsEqual(Self.eventField) {
            type = value.flatMap(Self.nonEmptyText)
        }
    }

    private mutating func completeEvent() -> ServerSentEvent? {
        defer {
            id = lastId
            type = nil
            data.removeAll(keepingCapacity: true)
        }
        guard !data.isEmpty else { return nil }
        lastId = id
        return ServerSentEvent(id: id, type: type, data: String(decoding: data.dropFirst(), as: UTF8.self))
    }

    private static func nonEmptyText(_ bytes: ArraySlice<UInt8>) -> String? {
        bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
    }

    private static let lineFeed = UInt8(ascii: "\n")
    private static let carriageReturn = UInt8(ascii: "\r")
    private static let colon = UInt8(ascii: ":")
    private static let space = UInt8(ascii: " ")
    private static let dataField = Array("data".utf8)
    private static let idField = Array("id".utf8)
    private static let eventField = Array("event".utf8)
}
