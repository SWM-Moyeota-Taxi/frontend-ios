import Foundation
import MoyeotaDomain

/// STOMP 1.2 프레임 코덱 — krossbow `StompFrame`·`StompEncoder`·`StompDecoder`·`HeaderEscaper` 의 자리.
/// **네트워크 없이 테스트할 수 있다.**
enum StompCommand: String, Sendable {
    case connect = "CONNECT"
    case connected = "CONNECTED"
    case send = "SEND"
    case subscribe = "SUBSCRIBE"
    case unsubscribe = "UNSUBSCRIBE"
    case ack = "ACK"
    case nack = "NACK"
    case begin = "BEGIN"
    case commit = "COMMIT"
    case abort = "ABORT"
    case disconnect = "DISCONNECT"
    case message = "MESSAGE"
    case receipt = "RECEIPT"
    case error = "ERROR"
    case stomp = "STOMP"

    /// STOMP 1.2: CONNECT·CONNECTED 는 1.0 서버와도 말이 통해야 해서 헤더를 이스케이프하지 않는다.
    /// `Authorization: Bearer …` 는 이 규칙 덕에 프레임에 그대로 실린다.
    var supportsHeaderEscapes: Bool {
        self != .connect && self != .connected
    }
}

struct StompHeader: Equatable, Sendable {
    var name: String
    var value: String

    init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }
}

struct InvalidStompFrameException: Throwable {
    let message: String?
    var cause: (any Error)? { nil }

    init(_ message: String) {
        self.message = message
    }
}

struct StompFrame: Equatable, Sendable {
    var command: StompCommand
    /// 순서를 지킨다 — 나가는 프레임의 헤더 순서가 원본과 같아야 패킷이 같다. 받은 쪽은 중복을 뺀 상태다.
    var headers: [StompHeader]
    /// 비어 있으면 null 이다.
    var body: Data?

    init(command: StompCommand, headers: [StompHeader] = [], body: Data? = nil) {
        self.command = command
        self.headers = headers
        self.body = body
    }

    func header(_ name: String) -> String? {
        headers.first { $0.name == name }?.value
    }

    /// 원본은 Binary 본문의 문자셋을 `content-type` 에서 찾지만 이 앱의 서버는 텍스트 프레임만 보낸다. 늘 UTF-8 로 읽는다.
    var bodyAsText: String {
        body.map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    // MARK: - 인코딩

    /// `COMMAND\nname:value\n\nbody\0`. 본문이 있어도 `content-length` 는 여기서 붙이지 않는다 — 호출부 몫이다.
    func encodeToText() -> String {
        var text = command.rawValue + "\n"
        for header in headers {
            text += maybeEscape(header.name) + ":" + maybeEscape(header.value) + "\n"
        }
        text += "\n"
        text += bodyAsText
        text += "\0"
        return text
    }

    private func maybeEscape(_ text: String) -> String {
        command.supportsHeaderEscapes ? HeaderEscaper.escape(text) : text
    }

    // MARK: - 디코딩

    /// 잘못된 프레임이면 `InvalidStompFrameException` 을 던진다. 원본처럼 세션을 끝낼 사유다.
    static func decode(text: String) throws -> StompFrame {
        try decode(bytes: Array(text.utf8))
    }

    static func decode(bytes: [UInt8]) throws -> StompFrame {
        var reader = Reader(bytes: bytes)

        guard let commandLine = reader.readLine() else {
            throw InvalidStompFrameException("Missing command in STOMP frame")
        }
        guard let command = StompCommand(rawValue: commandLine) else {
            throw InvalidStompFrameException("Unknown STOMP command '\(commandLine)'")
        }

        var headers: [StompHeader] = []
        while true {
            guard let line = reader.readLine() else {
                throw InvalidStompFrameException("Unexpected end of frame in headers")
            }
            if line.isEmpty { break }
            guard let colon = line.firstIndex(of: ":") else {
                throw InvalidStompFrameException("Missing ':' in STOMP header '\(line)'")
            }
            var name = String(line[..<colon])
            var value = String(line[line.index(after: colon)...])
            if command.supportsHeaderEscapes {
                name = try HeaderEscaper.unescape(name)
                value = try HeaderEscaper.unescape(value)
            }
            // STOMP 1.2: 같은 헤더가 반복되면 **처음 값**이 이긴다.
            if !headers.contains(where: { $0.name == name }) {
                headers.append(StompHeader(name, value))
            }
        }

        let contentLength = try parseContentLength(headers)
        let body = try reader.readBody(contentLength: contentLength)

        guard reader.readByte() == 0 else {
            throw InvalidStompFrameException("Expected NULL byte at end of frame")
        }
        // NUL 뒤에는 개행만 허용된다(STOMP 1.2 의 frame = ... NULL *( EOL )).
        guard reader.remaining.allSatisfy({ $0 == UInt8(ascii: "\n") || $0 == UInt8(ascii: "\r") }) else {
            throw InvalidStompFrameException("Unexpected non-EOL content after NULL byte")
        }
        return StompFrame(command: command, headers: headers, body: body)
    }

    private static func parseContentLength(_ headers: [StompHeader]) throws -> Int? {
        guard let raw = headers.first(where: { $0.name == "content-length" })?.value else { return nil }
        guard let value = Int(raw), value >= 0 else {
            throw InvalidStompFrameException("Invalid content-length header '\(raw)'")
        }
        return value
    }

    private struct Reader {
        let bytes: [UInt8]
        var position = 0

        var remaining: ArraySlice<UInt8> { bytes[position...] }

        /// `\n` 또는 `\r\n` 으로 끝나는 한 줄. 끝에 개행이 없으면 null 이다(프레임이 잘렸다).
        mutating func readLine() -> String? {
            guard let lineFeed = bytes[position...].firstIndex(of: UInt8(ascii: "\n")) else { return nil }
            var end = lineFeed
            if end > position, bytes[end - 1] == UInt8(ascii: "\r") { end -= 1 }
            defer { position = lineFeed + 1 }
            return String(decoding: bytes[position..<end], as: UTF8.self)
        }

        /// `content-length` 가 있으면 그만큼(본문에 NUL 이 있어도 된다), 없으면 첫 NUL 앞까지.
        mutating func readBody(contentLength: Int?) throws -> Data? {
            let length: Int
            if let contentLength {
                length = contentLength
            } else {
                guard let nul = bytes[position...].firstIndex(of: 0) else {
                    throw InvalidStompFrameException("Expected NULL byte at end of frame")
                }
                length = nul - position
            }
            guard length <= bytes.count - position else {
                throw InvalidStompFrameException("Frame is shorter than its content-length")
            }
            defer { position += length }
            return length == 0 ? nil : Data(bytes[position..<(position + length)])
        }

        mutating func readByte() -> UInt8? {
            guard position < bytes.count else { return nil }
            defer { position += 1 }
            return bytes[position]
        }
    }
}

/// STOMP 1.2 헤더 이스케이프: `\r`·`\n`·`:`·`\` 네 개뿐이고 그 밖의 `\x` 는 잘못된 프레임이다.
enum HeaderEscaper {
    static func escape(_ text: String) -> String {
        var escaped = ""
        for character in text.unicodeScalars {
            switch character {
            case "\r": escaped += "\\r"
            case "\n": escaped += "\\n"
            case ":": escaped += "\\c"
            case "\\": escaped += "\\\\"
            default: escaped.unicodeScalars.append(character)
            }
        }
        return escaped
    }

    static func unescape(_ text: String) throws -> String {
        var unescaped = ""
        var isEscaping = false
        for character in text.unicodeScalars {
            if isEscaping {
                switch character {
                case "r": unescaped += "\r"
                case "n": unescaped += "\n"
                case "c": unescaped += ":"
                case "\\": unescaped += "\\"
                default: throw InvalidStompFrameException("Invalid escape sequence '\\\(character)' in '\(text)'")
                }
                isEscaping = false
            } else if character == "\\" {
                isEscaping = true
            } else {
                unescaped.unicodeScalars.append(character)
            }
        }
        if isEscaping {
            throw InvalidStompFrameException("Invalid dangling escape character at end of '\(text)'")
        }
        return unescaped
    }
}
