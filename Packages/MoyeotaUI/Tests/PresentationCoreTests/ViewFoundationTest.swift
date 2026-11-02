import Foundation
import Testing
@testable import PresentationCore

@Suite struct ViewFoundationTest {
    @MainActor
    @Test("가로채기가 없으면 뒤로가기를 처리하지 않는다")
    func handleBackWithoutHandlers() {
        let center = BackInterceptionCenter()
        #expect(center.handleBack() == false)
        #expect(center.isIntercepting == false)
    }

    @MainActor
    @Test("가장 최근에 등록한 가로채기가 뒤로가기를 받는다")
    func latestHandlerWins() {
        let center = BackInterceptionCenter()
        var called: [String] = []
        let first = UUID()
        let second = UUID()
        center.register(id: first) { called.append("first") }
        center.register(id: second) { called.append("second") }
        #expect(center.handleBack())
        #expect(called == ["second"])
        center.unregister(id: second)
        #expect(center.handleBack())
        #expect(called == ["second", "first"])
    }

    @Test("ViewModelScope 를 해제하면 띄운 태스크가 취소된다")
    func scopeCancelsOnDeinit() async {
        var scope: ViewModelScope? = ViewModelScope()
        let task = scope!.launch {
            try? await Task.sleep(for: .seconds(60))
        }
        scope = nil
        await task.value
        #expect(task.isCancelled)
    }
}
