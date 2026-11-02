import Foundation
import Testing
@testable import MoyeotaData

/// krossbow 의 인코더·디코더가 맡던 부분. 서버(Spring)가 읽는 바이트가 계약이다.
@Suite struct StompFrameTest {

    // MARK: - 인코딩

    @Test("프레임은 명령, 헤더, 빈 줄, 본문, NUL 순서다")
    func encodesFrame() {
        let frame = StompFrame(
            command: .send,
            headers: [StompHeader("destination", "/pub/a"), StompHeader("content-length", "2")],
            body: Data("hi".utf8)
        )

        #expect(frame.encodeToText() == "SEND\ndestination:/pub/a\ncontent-length:2\n\nhi\0")
    }

    @Test("본문이 없어도 빈 줄과 NUL 은 있다")
    func encodesWithoutBody() {
        #expect(StompFrame(command: .disconnect, headers: [StompHeader("receipt", "r")]).encodeToText() == "DISCONNECT\nreceipt:r\n\n\0")
    }

    @Test("헤더 순서를 지킨다")
    func keepsHeaderOrder() {
        let frame = StompFrame(command: .subscribe, headers: [StompHeader("z", "1"), StompHeader("a", "2"), StompHeader("m", "3")])

        #expect(frame.encodeToText() == "SUBSCRIBE\nz:1\na:2\nm:3\n\n\0")
    }

    @Test("SEND 헤더는 이스케이프한다")
    func escapesSendHeaders() {
        let frame = StompFrame(command: .send, headers: [StompHeader("a:b", "c\\d\ne\rf")])

        #expect(frame.encodeToText() == "SEND\na\\cb:c\\\\d\\ne\\rf\n\n\0")
    }

    /// 토큰에 콜론이 있어도 CONNECT 는 이스케이프하지 않는다 — 1.0 서버와도 말이 통해야 하는 프레임이다.
    @Test("CONNECT 헤더는 이스케이프하지 않는다")
    func doesNotEscapeConnect() {
        let frame = StompFrame(command: .connect, headers: [StompHeader("Authorization", "Bearer a:b")])

        #expect(frame.encodeToText() == "CONNECT\nAuthorization:Bearer a:b\n\n\0")
    }

    // MARK: - 디코딩

    @Test("MESSAGE 를 읽는다")
    func decodesMessage() throws {
        let frame = try StompFrame.decode(text: "MESSAGE\nsubscription:s\nmessage-id:m\ndestination:/sub/a\n\n{\"id\":1}\0")

        #expect(frame.command == .message)
        #expect(frame.header("subscription") == "s")
        #expect(frame.header("destination") == "/sub/a")
        #expect(frame.bodyAsText == "{\"id\":1}")
    }

    @Test("없는 헤더는 null 이다")
    func missingHeader() throws {
        #expect(try StompFrame.decode(text: "RECEIPT\n\n\0").header("receipt-id") == nil)
    }

    @Test("content-length 가 없으면 첫 NUL 까지가 본문이다")
    func bodyUntilFirstNul() throws {
        #expect(try StompFrame.decode(text: "MESSAGE\n\nabc\0").bodyAsText == "abc")
    }

    /// 바이트 수다. 글자 수로 세면 한글 본문에서 프레임이 어긋난다.
    @Test("content-length 는 바이트 수로 읽는다")
    func contentLengthInBytes() throws {
        let body = "안녕 hello"
        let frame = try StompFrame.decode(text: "MESSAGE\ncontent-length:\(body.utf8.count)\n\n\(body)\0")

        #expect(frame.bodyAsText == body)
    }

    @Test("content-length 가 있으면 본문의 NUL 을 끝으로 보지 않는다")
    func nulInsideBody() throws {
        let frame = try StompFrame.decode(text: "MESSAGE\ncontent-length:3\n\na\0b\0")

        #expect(frame.body == Data([0x61, 0x00, 0x62]))
    }

    @Test("빈 본문은 null 이다")
    func emptyBodyIsNil() throws {
        #expect(try StompFrame.decode(text: "RECEIPT\nreceipt-id:r\n\n\0").body == nil)
        #expect(try StompFrame.decode(text: "RECEIPT\ncontent-length:0\n\n\0").body == nil)
        #expect(try StompFrame.decode(text: "RECEIPT\n\n\0").bodyAsText == "")
    }

    @Test("CRLF 줄 끝도 읽는다")
    func acceptsCrlf() throws {
        let frame = try StompFrame.decode(text: "MESSAGE\r\nsubscription:s\r\n\r\nbody\0")

        #expect(frame.command == .message)
        #expect(frame.header("subscription") == "s")
        #expect(frame.bodyAsText == "body")
    }

    @Test("NUL 뒤의 개행은 허용한다")
    func trailingEolsAllowed() throws {
        #expect(try StompFrame.decode(text: "RECEIPT\n\n\0\n\r\n\n").command == .receipt)
    }

    @Test("NUL 뒤에 다른 내용이 있으면 실패한다")
    func trailingGarbageRejected() {
        #expect(throws: InvalidStompFrameException.self) {
            try StompFrame.decode(text: "RECEIPT\n\n\0MESSAGE\n\n\0")
        }
    }

    @Test("같은 헤더가 반복되면 처음 값이 이긴다")
    func firstHeaderWins() throws {
        let frame = try StompFrame.decode(text: "MESSAGE\na:1\na:2\n\n\0")

        #expect(frame.header("a") == "1")
        #expect(frame.headers.count == 1)
    }

    @Test("헤더 값의 콜론은 첫 번째로만 나눈다")
    func splitsOnFirstColon() throws {
        #expect(try StompFrame.decode(text: "CONNECTED\nserver:a:b\n\n\0").header("server") == "a:b")
    }

    @Test("이스케이프된 헤더를 푼다")
    func unescapesHeaders() throws {
        let frame = try StompFrame.decode(text: "MESSAGE\na\\cb:c\\\\d\\ne\\rf\n\n\0")

        #expect(frame.header("a:b") == "c\\d\ne\rf")
    }

    /// STOMP 1.2: CONNECTED 는 이스케이프가 없다. `\` 를 풀려 하면 정상 프레임에서 세션이 죽는다.
    @Test("CONNECTED 헤더는 풀지 않는다")
    func doesNotUnescapeConnected() throws {
        #expect(try StompFrame.decode(text: "CONNECTED\nserver:a\\b\n\n\0").header("server") == "a\\b")
    }

    @Test("모르는 이스케이프는 실패한다")
    func invalidEscapeRejected() {
        #expect(throws: InvalidStompFrameException.self) {
            try StompFrame.decode(text: "MESSAGE\na:b\\t\n\n\0")
        }
    }

    @Test("끝에 걸린 이스케이프는 실패한다")
    func danglingEscapeRejected() {
        #expect(throws: InvalidStompFrameException.self) {
            try StompFrame.decode(text: "MESSAGE\na:b\\\n\n\0")
        }
    }

    @Test("모르는 명령은 실패한다")
    func unknownCommandRejected() {
        #expect(throws: InvalidStompFrameException.self) {
            try StompFrame.decode(text: "HELLO\n\n\0")
        }
    }

    @Test("빈 메시지는 실패한다")
    func emptyRejected() {
        #expect(throws: InvalidStompFrameException.self) {
            try StompFrame.decode(text: "")
        }
    }

    @Test("콜론 없는 헤더는 실패한다")
    func headerWithoutColonRejected() {
        #expect(throws: InvalidStompFrameException.self) {
            try StompFrame.decode(text: "MESSAGE\nnocolon\n\n\0")
        }
    }

    @Test("NUL 이 없으면 실패한다")
    func missingNulRejected() {
        #expect(throws: InvalidStompFrameException.self) {
            try StompFrame.decode(text: "MESSAGE\n\nbody")
        }
    }

    @Test("헤더 도중 끝나면 실패한다")
    func truncatedHeadersRejected() {
        #expect(throws: InvalidStompFrameException.self) {
            try StompFrame.decode(text: "MESSAGE\na:b\n")
        }
    }

    @Test("content-length 가 실제보다 길면 실패한다")
    func contentLengthTooLong() {
        #expect(throws: InvalidStompFrameException.self) {
            try StompFrame.decode(text: "MESSAGE\ncontent-length:50\n\nabc\0")
        }
    }

    @Test("content-length 가 실제보다 짧으면 실패한다")
    func contentLengthTooShort() {
        #expect(throws: InvalidStompFrameException.self) {
            try StompFrame.decode(text: "MESSAGE\ncontent-length:1\n\nabc\0")
        }
    }

    @Test("content-length 가 숫자가 아니면 실패한다")
    func contentLengthNotNumber() {
        #expect(throws: InvalidStompFrameException.self) {
            try StompFrame.decode(text: "MESSAGE\ncontent-length:abc\n\n\0")
        }
        #expect(throws: InvalidStompFrameException.self) {
            try StompFrame.decode(text: "MESSAGE\ncontent-length:-1\n\n\0")
        }
    }

    @Test("바이너리 메시지도 같게 읽는다")
    func decodesBytes() throws {
        let frame = try StompFrame.decode(bytes: Array("MESSAGE\nsubscription:s\n\n채팅\0".utf8))

        #expect(frame.bodyAsText == "채팅")
    }

    @Test("인코딩한 것을 그대로 읽는다")
    func roundTrip() throws {
        let body = Data("{\"content\":\"안녕\\n:\"}".utf8)
        let frame = StompFrame(
            command: .send,
            headers: [
                StompHeader("destination", "/pub/a:b\\c"),
                StompHeader("x\ny", "1\r2"),
                StompHeader("content-length", String(body.count)),
            ],
            body: body
        )

        #expect(try StompFrame.decode(text: frame.encodeToText()) == frame)
    }

    @Test("이스케이프는 서로 되돌린다")
    func escaperRoundTrip() throws {
        let original = "a:b\\c\nd\re한글"
        #expect(HeaderEscaper.escape(original) == "a\\cb\\\\c\\nd\\re한글")
        #expect(try HeaderEscaper.unescape(HeaderEscaper.escape(original)) == original)
    }
}
