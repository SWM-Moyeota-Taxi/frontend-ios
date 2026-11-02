import Foundation
import Testing
@testable import MoyeotaData

/// okhttp-sse 가 해 주던 줄 파싱. 이 층이 틀리면 프레임 파서까지 아무것도 도달하지 않아 **대기 화면이 말없이 멈춘다.**
@Suite struct ServerSentEventReaderTest {
    private func read(_ stream: String) -> [ServerSentEvent] {
        var reader = ServerSentEventReader()
        return stream.utf8.compactMap { reader.read($0) }
    }

    @Test("event 와 data 를 빈 줄에서 내보낸다")
    func dispatchesOnBlankLine() {
        #expect(read("event: connected\ndata: {\"id\":7}\n\n") == [
            ServerSentEvent(id: nil, type: "connected", data: "{\"id\":7}"),
        ])
    }

    @Test("빈 줄 전에는 아무것도 내보내지 않는다")
    func nothingBeforeBlankLine() {
        #expect(read("event: connected\ndata: {}\n").isEmpty)
    }

    @Test("여러 줄 data 는 개행으로 잇는다")
    func joinsMultilineData() {
        #expect(read("event: connected\ndata: {\ndata:   \"id\": 7\ndata: }\n\n").first?.data == "{\n  \"id\": 7\n}")
    }

    /// 서버의 `:ping` 은 살아있음 확인일 뿐 — 호출부에 이벤트로 보이면 안 된다.
    @Test("주석은 흘려보낸다")
    func ignoresComments() {
        #expect(read(":ping\n\n").isEmpty)
        #expect(read(":ping\n\nevent: closed\ndata: 7\n\n") == [ServerSentEvent(id: nil, type: "closed", data: "7")])
        #expect(read("event: closed\n:ping\ndata: 7\n\n") == [ServerSentEvent(id: nil, type: "closed", data: "7")])
    }

    @Test("줄 끝은 LF, CR, CRLF 모두 받는다")
    func acceptsAllLineEndings() {
        let expected = [ServerSentEvent(id: nil, type: "a", data: "1\n2")]
        #expect(read("event: a\ndata: 1\ndata: 2\n\n") == expected)
        #expect(read("event: a\rdata: 1\rdata: 2\r\r") == expected)
        #expect(read("event: a\r\ndata: 1\r\ndata: 2\r\n\r\n") == expected)
    }

    /// `\r` 와 `\n` 이 다른 청크로 와도 줄 끝 하나다. 빈 줄로 잘못 읽으면 이벤트가 data 없이 끝나 사라진다.
    @Test("CRLF 가 청크 경계에 걸려도 한 줄 끝이다")
    func crlfAcrossChunks() {
        var reader = ServerSentEventReader()
        var events: [ServerSentEvent] = []
        for chunk in ["event: a\r", "\ndata: 1\r", "\n\r", "\n"] {
            events += chunk.utf8.compactMap { reader.read($0) }
        }
        #expect(events == [ServerSentEvent(id: nil, type: "a", data: "1")])
    }

    @Test("값 앞 공백은 한 칸만 뗀다")
    func stripsOneLeadingSpace() {
        #expect(read("data:x\n\n").first?.data == "x")
        #expect(read("data: x\n\n").first?.data == "x")
        #expect(read("data:  x\n\n").first?.data == " x")
        #expect(read("data: x \n\n").first?.data == "x ")
    }

    @Test("값 안의 콜론은 값이다")
    func colonInValue() {
        #expect(read("event: a:b\ndata: {\"k\":\"v:w\"}\n\n") == [ServerSentEvent(id: nil, type: "a:b", data: "{\"k\":\"v:w\"}")])
    }

    /// `data` 줄이 있었으면 값이 비어도 이벤트다 — 없는 것과 다르다.
    @Test("빈 data 줄도 이벤트를 만든다")
    func emptyDataDispatches() {
        #expect(read("data\n\n") == [ServerSentEvent(id: nil, type: nil, data: "")])
        #expect(read("data:\n\n") == [ServerSentEvent(id: nil, type: nil, data: "")])
        #expect(read("data: \n\n") == [ServerSentEvent(id: nil, type: nil, data: "")])
        #expect(read("data\ndata\n\n").first?.data == "\n")
    }

    @Test("data 없는 묶음은 내보내지 않고 event 도 다음으로 넘기지 않는다")
    func eventWithoutDataIsDropped() {
        #expect(read("event: a\n\n").isEmpty)
        #expect(read("event: a\n\ndata: 1\n\n") == [ServerSentEvent(id: nil, type: nil, data: "1")])
    }

    @Test("event 는 이벤트마다 초기화된다")
    func eventResetsEachDispatch() {
        #expect(read("event: a\ndata: 1\n\ndata: 2\n\n").map(\.type) == ["a", nil])
    }

    @Test("값이 빈 event 는 없는 것과 같다")
    func emptyEventIsNil() {
        #expect(read("event:\ndata: 1\n\n").first?.type == nil)
        #expect(read("event: a\nevent\ndata: 1\n\n").first?.type == nil)
    }

    @Test("id 는 내보낸 뒤 다음 이벤트로 이어진다")
    func idCarriesOver() {
        #expect(read("id: 1\ndata: a\n\ndata: b\n\n").map(\.id) == ["1", "1"])
    }

    @Test("이벤트가 안 나간 묶음의 id 는 이어지지 않는다")
    func idNotCarriedWithoutDispatch() {
        #expect(read("id: 1\n\ndata: a\n\n").map(\.id) == [nil])
    }

    @Test("빈 id 는 이어받은 값을 지운다")
    func emptyIdClears() {
        #expect(read("id: 1\ndata: a\n\nid:\ndata: b\n\ndata: c\n\n").map(\.id) == ["1", nil, nil])
        #expect(read("id: 1\ndata: a\n\nid\ndata: b\n\n").map(\.id) == ["1", nil])
    }

    /// 재연결 간격은 앱의 표가 정한다 — 서버의 `retry:` 를 따르지 않는다.
    @Test("retry 와 모르는 필드는 흘려보낸다")
    func ignoresUnknownFields() {
        #expect(read("retry: 100\nfoo: bar\ndata: a\n\n") == [ServerSentEvent(id: nil, type: nil, data: "a")])
    }

    @Test("이름이 앞만 같은 필드는 다른 필드다")
    func fieldNameMustMatchExactly() {
        #expect(read("database: x\neventual: y\nidle: z\ndata: a\n\n") == [ServerSentEvent(id: nil, type: nil, data: "a")])
        #expect(read("Data: x\n\n").isEmpty)
    }

    /// 서버가 끊어 프레임이 잘린 경우 — 반쪽짜리 JSON 을 파서에 넘기지 않는다.
    @Test("빈 줄 없이 끝난 묶음은 버린다")
    func truncatedEventIsDropped() {
        #expect(read("event: a\ndata: 1\n\nevent: b\ndata: {\"id\":").map(\.type) == ["a"])
    }

    @Test("한글이 청크 경계에서 쪼개져도 그대로 읽는다")
    func utf8AcrossBytes() {
        #expect(read("event: 입장\ndata: 서울시청\n\n") == [ServerSentEvent(id: nil, type: "입장", data: "서울시청")])
    }

    @Test("연속 이벤트를 순서대로 내보낸다")
    func multipleEvents() {
        let stream = """
            event: connected
            data: {"id":7}

            :ping

            event: member-left
            data: {"publicId":null,"status":"ACTIVE"}

            event: closed
            data: 7


            """
        #expect(read(stream).map(\.type) == ["connected", "member-left", "closed"])
    }
}
