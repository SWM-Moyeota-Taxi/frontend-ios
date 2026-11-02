import MoyeotaDesignSystem
import NMapsMap
import PresentationCore
import SwiftUI
import Testing
import UIKit
@testable import MoyeotaDesignSystem

// 원본에 없는 테스트. `NavigationStack` 이 덮인 화면에 `onAppear` 를 다시 부르는 일(`isTopStackEntry` 참고)과 탭 복귀의 복원을 실제 뷰로 시험한다.

@MainActor
private func host(_ view: some View, height: CGFloat = 852) async -> UIWindow {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: height))
    window.rootViewController = UIHostingController(rootView: view)
    window.isHidden = false
    await settle(window)
    return window
}

@MainActor
private func settle(_ window: UIWindow, rounds: Int = 16) async {
    for _ in 0..<rounds {
        window.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(25))
    }
}

@MainActor
private final class Counter {
    var started = 0
    var stopped = 0
    var tasks = 0
    var backs = 0
}

private struct GateHarness: View {
    let isTop: Bool
    let counter: Counter

    var body: some View {
        Color.clear
            .lifecycleEffect(onStart: { counter.started += 1 }, onStop: { counter.stopped += 1 })
            .moyeotaBackHandler { counter.backs += 1 }
            .topEntryTask { @MainActor in counter.tasks += 1 }
            .environment(\.isTopStackEntry, isTop)
            .environment(\.scenePhase, .active) // 씬 없는 창은 늘 background 다
    }
}

@MainActor
@Suite(.serialized) struct StackTopGateTest {

    @Test("맨 위 칸이 아니면 나타나도 시작·가로채기·진입 태스크가 돌지 않는다")
    func coveredEntryStaysQuiet() async {
        let counter = Counter()
        let window = await host(GateHarness(isTop: false, counter: counter))
        #expect(counter.started == 0)
        #expect(counter.tasks == 0)
        #expect(!BackInterceptionCenter.shared.isIntercepting)
        window.isHidden = true
        window.rootViewController = nil
        await settle(window)
    }

    @Test("맨 위가 되면 시작하고 덮이면 멈춘다")
    func followsTopFlag() async {
        let counter = Counter()
        let controller = UIHostingController(rootView: GateHarness(isTop: false, counter: counter))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = controller
        window.isHidden = false
        await settle(window)

        controller.rootView = GateHarness(isTop: true, counter: counter)
        await settle(window)
        #expect(counter.started == 1)
        #expect(counter.tasks == 1)
        #expect(BackInterceptionCenter.shared.isIntercepting)

        controller.rootView = GateHarness(isTop: false, counter: counter)
        await settle(window)
        #expect(counter.stopped == 1)
        #expect(!BackInterceptionCenter.shared.isIntercepting)

        controller.rootView = GateHarness(isTop: true, counter: counter)
        await settle(window)
        #expect(counter.started == 2)
        #expect(counter.tasks == 2, "돌아오면 다시 묻는다")
        window.isHidden = true
        window.rootViewController = nil
        await settle(window)
    }
}

private struct LazyListHarness: View {
    let memory: TabSavedState

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 12) {
                ForEach(0..<7, id: \.self) { index in
                    Text("방 \(index)").frame(maxWidth: .infinity).frame(height: 144)
                }
            }
            .savedScrollOffset("list")
        }
        .frame(height: 236)
        .environment(\.tabSavedState, memory)
    }
}

private func enclosedScrollView(in root: UIView) -> UIScrollView? {
    if let found = root as? UIScrollView { return found }
    for child in root.subviews {
        if let found = enclosedScrollView(in: child) { return found }
    }
    return nil
}

@MainActor
@Suite(.serialized) struct SavedScrollRestoreTest {

    @Test("지연 목록의 위치는 한 칸 넘게 내려간 자리에서도 복원되고 맡긴 값이 지워지지 않는다", arguments: [CGFloat(64), 314, 630])
    func restoresDeepOffsetInLazyList(offset: CGFloat) async throws {
        let memory = TabSavedState()
        memory.set("list", offset)
        let window = await host(LazyListHarness(memory: memory))
        let scrollView = try #require(enclosedScrollView(in: window))
        #expect(scrollView.contentOffset.y == offset)
        #expect(memory.value("list") == offset)
        window.isHidden = true
    }
}

@MainActor
@Suite(.serialized) struct MapCameraMemoryTest {

    @Test("사용자가 지도를 건드리지 않아도 처음 적용한 카메라가 맡겨진다 - 안 맡기면 탭 복귀에 기본 카메라(부산)로 간다")
    func firstCameraIsRemembered() async throws {
        let memory = MapCameraMemory()
        let window = await host(
            NaverMapView(center: LatLng(37.49794, 127.0276), zoom: 15)
                .environment(\.mapCameraMemory, memory)
        )
        let camera = try #require(memory.camera)
        #expect(abs(camera.target.lat - 37.49794) < 0.0001)
        #expect(abs(camera.zoom - 15) < 0.001)
        window.isHidden = true
    }
}
