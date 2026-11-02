import MoyeotaDesignSystem
import SwiftUI
import Testing
import UIKit

// 원본에 없는 테스트. 칸을 창에 올려 실제 `UITextField` 의 `isEnabled` 를 읽는다.
//
// SwiftUI 는 `UIControl` 인 플랫폼 뷰의 `isEnabled` 를 환경의 `isEnabled`(`.disabled`)로 덮어쓴다. 호출부 값만
// `updateUIView` 에서 넣으면 첫 배치에 환경 값(true)이 그 위를 덮어, 잠겨야 할 칸이 다음 갱신까지 열려 있었다.

@MainActor
@Observable
private final class EnabledInputs {
    var enabled: Bool
    var value = ""
    var focused = false

    init(enabled: Bool) {
        self.enabled = enabled
    }
}

private struct EnabledHarness: View {
    let inputs: EnabledInputs
    let singleLine: Bool

    var body: some View {
        BasicTextField(
            value: inputs.value,
            onValueChange: { inputs.value = $0 },
            singleLine: singleLine,
            enabled: inputs.enabled,
            onFocusChanged: { inputs.focused = $0 }
        )
        .frame(width: 200, height: 48)
    }
}

/// `MoyeotaTextField` 처럼 포커스를 `@State` 로 들고 있는 호출부. 뷰 갱신 중에 쓴 값은 버려지므로 이 꼴로 확인해야 한다.
private struct FocusStateHarness: View {
    let inputs: EnabledInputs
    let singleLine: Bool
    @State private var focused = false

    var body: some View {
        BasicTextField(
            value: inputs.value,
            onValueChange: { inputs.value = $0 },
            singleLine: singleLine,
            enabled: inputs.enabled,
            onFocusChanged: { focused = $0 }
        )
        .frame(width: 200, height: 48)
        .onChange(of: focused) { inputs.focused = focused }
    }
}

@MainActor
private final class HostedInput {
    private let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
    private let host: UIViewController

    init<Root: View>(_ root: Root) {
        host = UIHostingController(rootView: root)
        window.rootViewController = host
        window.isHidden = false
    }

    func close() {
        window.isHidden = true
    }

    func layout() {
        window.layoutIfNeeded()
    }

    var field: UITextField? {
        find(in: host.view)
    }

    var area: UITextView? {
        find(in: host.view)
    }

    private func find<T: UIView>(in view: UIView) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews {
            if let match: T = find(in: child) { return match }
        }
        return nil
    }

    func settle() async {
        for _ in 0..<8 {
            layout()
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    func waitForField(sourceLocation: SourceLocation = #_sourceLocation) async -> UITextField? {
        for _ in 0..<200 {
            layout()
            if let field { return field }
            try? await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("칸이 뜨지 않았다", sourceLocation: sourceLocation)
        return nil
    }
}

@MainActor
@Suite(.serialized) struct BasicTextFieldEnabledTest {

    @Test("처음부터 enabled: false 인 한 줄 칸은 다른 갱신 없이도 잠겨 있다")
    func disabledFromTheStart() async throws {
        let screen = HostedInput(EnabledHarness(inputs: EnabledInputs(enabled: false), singleLine: true))
        defer { screen.close() }

        let field = try #require(await screen.waitForField())
        #expect(!field.isEnabled, "첫 배치 직후")

        await screen.settle()
        #expect(!field.isEnabled, "자리 잡은 뒤")
    }

    @Test("값만 바뀌어도, 잠금을 풀고 다시 걸어도 호출부 값을 따른다")
    func followsCallerValue() async throws {
        let inputs = EnabledInputs(enabled: false)
        let screen = HostedInput(EnabledHarness(inputs: inputs, singleLine: true))
        defer { screen.close() }
        let field = try #require(await screen.waitForField())

        inputs.value = "1"
        await screen.settle()
        #expect(!field.isEnabled)

        inputs.enabled = true
        await screen.settle()
        #expect(field.isEnabled)

        inputs.enabled = false
        await screen.settle()
        #expect(!field.isEnabled)
    }

    @Test("바깥의 .disabled 도 그대로 먹는다")
    func outerDisabledStillApplies() async throws {
        let screen = HostedInput(EnabledHarness(inputs: EnabledInputs(enabled: true), singleLine: true).disabled(true))
        defer { screen.close() }

        let field = try #require(await screen.waitForField())
        await screen.settle()

        #expect(!field.isEnabled)
    }

    @Test("포커스를 가진 칸이 잠기면 포커스를 놓고, 잠금을 풀어도 되찾지 않는다")
    func disablingDropsFocus() async throws {
        let inputs = EnabledInputs(enabled: true)
        let screen = HostedInput(FocusStateHarness(inputs: inputs, singleLine: true))
        defer { screen.close() }
        let field = try #require(await screen.waitForField())
        await screen.settle()

        #expect(field.becomeFirstResponder())
        await screen.settle()
        #expect(field.isFirstResponder)
        #expect(inputs.focused)

        inputs.enabled = false
        await screen.settle()
        #expect(!field.isFirstResponder, "잠근 뒤")
        #expect(!inputs.focused, "포커스 콜백도 false 로 끝난다")

        inputs.enabled = true
        await screen.settle()
        #expect(!field.isFirstResponder, "잠금을 푼 뒤")
    }

    @Test("확인 키는 키보드만 내리고 포커스를 둔다. 다시 누르면 키보드가 돌아온다")
    func doneKeepsFocus() async throws {
        let inputs = EnabledInputs(enabled: true)
        let screen = HostedInput(FocusStateHarness(inputs: inputs, singleLine: true))
        defer { screen.close() }
        let field = try #require(await screen.waitForField())
        await screen.settle()

        #expect(field.becomeFirstResponder())
        await screen.settle()
        #expect(field.inputView == nil, "처음에는 시스템 키보드")

        _ = field.delegate?.textFieldShouldReturn?(field)
        await screen.settle()
        #expect(field.isFirstResponder, "원본 ImeAction.Done 은 포커스를 두어 테두리와 커서가 남는다")
        #expect(inputs.focused)
        #expect(field.inputView != nil, "키보드 자리를 비운다")

        // 07 인증 코드처럼 호출부가 포커스를 다시 부르면 키보드가 돌아온다(칸 위의 탭도 같은 길이다).
        #expect(field.becomeFirstResponder())
        await screen.settle()
        #expect(field.isFirstResponder)
        #expect(field.inputView == nil, "키보드가 돌아온다")

        _ = field.delegate?.textFieldShouldReturn?(field)
        await screen.settle()
        #expect(field.resignFirstResponder())
        await screen.settle()
        #expect(field.inputView == nil, "포커스를 놓으면 다음 포커스에 키보드가 뜬다")
        #expect(!inputs.focused)
    }

    @Test("키보드를 내린 칸이 잠기면 포커스를 놓고 다음 포커스에 키보드가 뜬다")
    func disablingAfterDone() async throws {
        let inputs = EnabledInputs(enabled: true)
        let screen = HostedInput(FocusStateHarness(inputs: inputs, singleLine: true))
        defer { screen.close() }
        let field = try #require(await screen.waitForField())
        await screen.settle()

        #expect(field.becomeFirstResponder())
        await screen.settle()
        _ = field.delegate?.textFieldShouldReturn?(field)
        await screen.settle()
        #expect(field.inputView != nil)

        inputs.enabled = false
        await screen.settle()
        #expect(!field.isFirstResponder)
        #expect(!inputs.focused)
        #expect(field.inputView == nil)
    }

    @Test("숫자 자판의 「완료」 막대도 키보드와 함께 내려가고 함께 돌아온다")
    func doneHidesAccessory() async throws {
        let inputs = EnabledInputs(enabled: true)
        let screen = HostedInput(
            BasicTextField(
                value: inputs.value,
                onValueChange: { inputs.value = $0 },
                keyboardOptions: KeyboardOptions(keyboardType: .number, imeAction: .done),
                singleLine: true
            )
            .frame(width: 200, height: 48)
        )
        defer { screen.close() }
        let field = try #require(await screen.waitForField())
        await screen.settle()

        #expect(field.becomeFirstResponder())
        await screen.settle()
        #expect(field.inputAccessoryView != nil)

        _ = field.delegate?.textFieldShouldReturn?(field)
        await screen.settle()
        #expect(field.inputAccessoryView == nil, "막대만 화면에 남지 않는다")

        #expect(field.becomeFirstResponder())
        await screen.settle()
        #expect(field.inputAccessoryView != nil)
    }

    @Test("여러 줄 칸도 잠기면 포커스를 놓는다")
    func disablingDropsFocusMultiLine() async throws {
        let inputs = EnabledInputs(enabled: true)
        let screen = HostedInput(FocusStateHarness(inputs: inputs, singleLine: false))
        defer { screen.close() }
        for _ in 0..<200 where screen.area == nil {
            screen.layout()
            try? await Task.sleep(for: .milliseconds(25))
        }
        let area = try #require(screen.area)
        await screen.settle()

        #expect(area.becomeFirstResponder())
        await screen.settle()
        #expect(inputs.focused)

        inputs.enabled = false
        await screen.settle()
        #expect(!area.isFirstResponder)
        #expect(!inputs.focused)
    }

    @Test("여러 줄 칸도 처음부터 편집이 막혀 있다")
    func multiLineDisabledFromTheStart() async throws {
        let screen = HostedInput(EnabledHarness(inputs: EnabledInputs(enabled: false), singleLine: false))
        defer { screen.close() }

        for _ in 0..<200 where screen.area == nil {
            screen.layout()
            try? await Task.sleep(for: .milliseconds(25))
        }
        let area = try #require(screen.area)

        #expect(!area.isEditable)
        #expect(!area.isSelectable)
    }
}
