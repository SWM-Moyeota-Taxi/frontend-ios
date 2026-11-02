import MoyeotaDomain
import SwiftUI
import Testing
import UIKit
@testable import FeatureAuth

// 원본에 없는 테스트. 원본 `remember` 는 화면이 컴포지션에서 빠지면 사라지고 `rememberSaveable` 은 남는다
// (`ProfileSetupScreen.kt` 의 주석). `@State` 는 둘을 가리지 않고 스택에 있는 동안 남으므로,
// 화면을 실제 `NavigationStack` 에 올려 위에 다른 화면을 덮었다가 돌아온 뒤의 입력 칸을 읽는다.

@MainActor
@Observable
private final class CoverRouter {
    var covered = false
}

private struct CoverHarness<Root: View>: View {
    @Bindable var router: CoverRouter
    let root: Root

    var body: some View {
        NavigationStack {
            root
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(isPresented: $router.covered) { Color.red }
        }
    }
}

/// 창에 올린 화면. 값은 `UITextField` 에서 읽는다 — SwiftUI `@State` 는 바깥에서 읽을 길이 없다.
@MainActor
private final class HostedScreen {
    private let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
    private let router = CoverRouter()
    private let host: UIViewController

    init<Root: View>(_ root: Root) {
        host = UIHostingController(rootView: CoverHarness(router: router, root: root))
        window.rootViewController = host
        window.isHidden = false
    }

    func close() {
        window.isHidden = true
    }

    var fields: [UITextField] {
        textFields(in: host.view)
    }

    private func textFields(in view: UIView) -> [UITextField] {
        ((view as? UITextField).map { [$0] } ?? []) + view.subviews.flatMap { textFields(in: $0) }
    }

    func waitUntil(
        _ what: String,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: () -> Bool
    ) async {
        for _ in 0..<200 {
            window.layoutIfNeeded()
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("기다려도 되지 않았다: \(what)", sourceLocation: sourceLocation)
    }

    /// 사용자가 친 것처럼 값을 넣는다. 이 창에는 씬이 없어 `sendActions` 가 전달되지 않아 대상을 직접 부른다.
    func type(_ text: String, into field: UITextField) {
        field.text = text
        for target in field.allTargets {
            for action in field.actions(forTarget: target, forControlEvent: .editingChanged) ?? [] {
                _ = (target as? NSObject)?.perform(Selector(action), with: field)
            }
        }
    }

    /// 위에 다른 화면을 덮었다가 뒤로 돌아온다.
    func coverAndReturn() async {
        router.covered = true
        await waitUntil("덮은 화면이 올라온다") { fields.isEmpty }
        router.covered = false
        await waitUntil("아래 화면으로 돌아온다") { !fields.isEmpty }
    }

    /// 돌아온 뒤 화면이 다시 그려질 시간을 준다. 값이 **그대로 남는** 것을 확인할 때 쓴다.
    func settle() async {
        for _ in 0..<10 {
            window.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(25))
        }
    }
}

@MainActor
@Suite(.serialized) struct ScreenStateLifetimeTest {

    @Test("04a 를 가렸다 돌아오면 아이디·비밀번호가 비어 있고 비밀번호가 다시 가려진다")
    func loginFormForgets() async {
        let screen = HostedScreen(LoginFormScreen().seeded(passwordVisible: true))
        defer { screen.close() }
        await screen.waitUntil("입력 칸 두 개") { screen.fields.count == 2 }
        screen.type("moyeota", into: screen.fields[0])
        screen.type("abcd1234!", into: screen.fields[1])
        await screen.settle()
        #expect(screen.fields[1].text == "abcd1234!")
        #expect(!screen.fields[1].isSecureTextEntry, "「보기」를 켠 상태에서 시작한다")

        await screen.coverAndReturn()
        await screen.settle()

        #expect(screen.fields[0].text == "")
        #expect(screen.fields[1].text == "")
        #expect(screen.fields[1].isSecureTextEntry)
    }

    @Test("10 을 가렸다 돌아오면 입력값은 남고 비밀번호 가림만 돌아온다")
    func profileSetupKeepsInputsAndForgetsVisibility() async {
        let screen = HostedScreen(
            ProfileSetupScreen(onBack: {}, onNext: { _ in }, today: date(2026, 11, 2)).seeded(passwordVisible: true)
        )
        defer { screen.close() }
        // 닉네임 · 이름 · 생년월일 · 휴대폰 · 아이디 · 비밀번호 · 이메일
        await screen.waitUntil("입력 칸 일곱 개") { screen.fields.count == 7 }
        screen.type("모여타", into: screen.fields[0])
        screen.type("abcd1234!", into: screen.fields[5])
        await screen.settle()
        #expect(screen.fields[5].text == "abcd1234!")
        #expect(!screen.fields[5].isSecureTextEntry, "「보기」를 켠 상태에서 시작한다")

        await screen.coverAndReturn()
        await screen.settle()

        #expect(screen.fields[5].isSecureTextEntry)
        #expect(screen.fields[0].text == "모여타", "rememberSaveable 자리는 남는다")
        #expect(screen.fields[5].text == "abcd1234!", "rememberSaveable 자리는 남는다")
    }

    @Test("06 을 제출한 뒤 가렸다 돌아오면 다시 제출할 수 있다")
    func schoolEmailUnlocks() async {
        let screen = HostedScreen(SchoolEmailScreen().seeded(submitting: true))
        defer { screen.close() }
        await screen.waitUntil("입력 칸") { screen.fields.count == 1 }
        await screen.settle()
        #expect(!screen.fields[0].isEnabled, "제출 중이라 잠겨 있다")

        await screen.coverAndReturn()
        await screen.settle()

        #expect(screen.fields[0].isEnabled)
    }

    @Test("08 을 제출한 뒤 가렸다 돌아오면 다시 제출할 수 있다")
    func workVerifyUnlocks() async {
        let screen = HostedScreen(WorkVerifyScreen().seeded(submitting: true))
        defer { screen.close() }
        await screen.waitUntil("입력 칸") { screen.fields.count == 1 }
        await screen.settle()
        #expect(!screen.fields[0].isEnabled, "제출 중이라 잠겨 있다")

        await screen.coverAndReturn()
        await screen.settle()

        #expect(screen.fields[0].isEnabled)
    }

    @Test("09 를 제출한 뒤 가렸다 돌아오면 다시 제출할 수 있다")
    func identityVerifyUnlocks() async {
        let screen = HostedScreen(IdentityVerifyScreen().seeded(submitting: true))
        defer { screen.close() }
        await screen.waitUntil("입력 칸 세 개") { screen.fields.count == 3 }
        await screen.settle()
        #expect(!screen.fields[0].isEnabled, "제출 중이라 잠겨 있다")

        await screen.coverAndReturn()
        await screen.settle()

        #expect(screen.fields[0].isEnabled)
    }

    @Test("06·08·09 의 입력값도 가렸다 돌아오면 비어 있다")
    func formsForgetInput() async {
        let school = HostedScreen(SchoolEmailScreen())
        let work = HostedScreen(WorkVerifyScreen())
        let identity = HostedScreen(IdentityVerifyScreen())
        defer {
            school.close()
            work.close()
            identity.close()
        }
        for (screen, count) in [(school, 1), (work, 1), (identity, 3)] {
            await screen.waitUntil("입력 칸") { screen.fields.count == count }
            let typed = "01012345678"
            screen.type(typed, into: screen.fields[0])
            await screen.settle()
            #expect(screen.fields[0].text?.isEmpty == false)

            await screen.coverAndReturn()
            await screen.settle()

            #expect(screen.fields[0].text == "")
        }
    }

    @Test("07 은 자동 제출 뒤 가렸다 돌아오면 빈 칸이고 같은 코드를 다시 보낼 수 있다")
    func emailCodeForgetsAfterAutoSubmit() async {
        var verified: [String] = []
        let screen = HostedScreen(EmailCodeScreen(onVerified: { verified.append($0) }))
        defer { screen.close() }
        await screen.waitUntil("입력 칸") { screen.fields.count == 1 }
        screen.type("123456", into: screen.fields[0])
        await screen.waitUntil("6자리 자동 제출") { verified == ["123456"] }
        await screen.waitUntil("제출 중 잠금") { !screen.fields[0].isEnabled }

        await screen.coverAndReturn()
        await screen.settle()

        #expect(screen.fields[0].text == "")
        #expect(screen.fields[0].isEnabled)

        screen.type("123456", into: screen.fields[0])
        await screen.waitUntil("다시 자동 제출") { verified == ["123456", "123456"] }
    }

    @Test("07 은 만료된 채 가렸다 돌아오면 새 기한으로 입력 칸이 열린다")
    func emailCodeRestartsExpiry() async {
        let screen = HostedScreen(EmailCodeScreen().seeded(expiryRemaining: 0))
        defer { screen.close() }
        await screen.waitUntil("입력 칸") { screen.fields.count == 1 }
        await screen.settle()
        #expect(!screen.fields[0].isEnabled, "만료돼 잠겨 있다")

        await screen.coverAndReturn()
        await screen.settle()

        #expect(screen.fields[0].isEnabled)
    }
}
