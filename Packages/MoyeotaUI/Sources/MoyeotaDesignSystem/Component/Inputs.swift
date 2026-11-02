import SwiftUI
import UIKit

// ─── 키보드 옵션 (Compose KeyboardOptions 자리) ────────────────────────────────

public enum KeyboardType: Sendable {
    case text, ascii, number, phone, uri, email, password, numberPassword, decimal

    var uiKeyboardType: UIKeyboardType {
        switch self {
        case .text: .default
        case .ascii: .asciiCapable
        case .number: .numberPad
        case .phone: .phonePad
        case .uri: .URL
        case .email: .emailAddress
        case .password: .asciiCapable
        case .numberPassword: .numberPad
        case .decimal: .decimalPad
        }
    }

    /// 머티리얼 입력기와 같이, 자유 문장이 아닌 칸에는 자동 수정을 걸지 않는다.
    var allowsAutocorrection: Bool {
        self == .text
    }

    /// 숫자 자판에는 확인 키가 없어 키보드를 내릴 방법이 없다. 안드로이드 숫자 자판의 확인 키 자리로 막대를 얹는다.
    var needsAccessoryDoneButton: Bool {
        switch self {
        case .number, .phone, .numberPassword, .decimal: true
        default: false
        }
    }
}

public enum ImeAction: Sendable {
    case unspecified, none, go, search, send, previous, next, done
}

public enum KeyboardCapitalization: Sendable {
    case none, characters, words, sentences
}

public struct KeyboardOptions: Sendable {
    public var capitalization: KeyboardCapitalization
    public var keyboardType: KeyboardType
    public var imeAction: ImeAction

    public init(
        capitalization: KeyboardCapitalization = .none,
        keyboardType: KeyboardType = .text,
        imeAction: ImeAction = .unspecified
    ) {
        self.capitalization = capitalization
        self.keyboardType = keyboardType
        self.imeAction = imeAction
    }

    public static let Default = KeyboardOptions()
}

/// Compose `KeyboardActions` 자리. 넘긴 동작은 기본 동작(다음 칸으로 이동·키보드 내리기)을 **대신한다.**
public struct KeyboardActions {
    public var onDone: (() -> Void)?
    public var onGo: (() -> Void)?
    public var onNext: (() -> Void)?
    public var onPrevious: (() -> Void)?
    public var onSearch: (() -> Void)?
    public var onSend: (() -> Void)?

    public init(
        onDone: (() -> Void)? = nil,
        onGo: (() -> Void)? = nil,
        onNext: (() -> Void)? = nil,
        onPrevious: (() -> Void)? = nil,
        onSearch: (() -> Void)? = nil,
        onSend: (() -> Void)? = nil
    ) {
        self.onDone = onDone
        self.onGo = onGo
        self.onNext = onNext
        self.onPrevious = onPrevious
        self.onSearch = onSearch
        self.onSend = onSend
    }

    public static var Default: KeyboardActions { KeyboardActions() }
}

// ─── 표시 변환 (Compose VisualTransformation 자리) ─────────────────────────────

/// 원시 값과 표시 문자열 사이의 커서 좌표 변환. 오프셋은 UTF-16 단위다.
public struct OffsetMapping: @unchecked Sendable {
    public let originalToTransformed: (Int) -> Int
    public let transformedToOriginal: (Int) -> Int

    public init(
        originalToTransformed: @escaping (Int) -> Int,
        transformedToOriginal: @escaping (Int) -> Int
    ) {
        self.originalToTransformed = originalToTransformed
        self.transformedToOriginal = transformedToOriginal
    }

    public static let Identity = OffsetMapping(originalToTransformed: { $0 }, transformedToOriginal: { $0 })
}

public struct TransformedText {
    public let text: String
    public let offsetMapping: OffsetMapping

    public init(text: String, offsetMapping: OffsetMapping) {
        self.text = text
        self.offsetMapping = offsetMapping
    }
}

/// 값은 원시 그대로 두고 그릴 때만 바꾼다(휴대폰 번호의 하이픈 등).
/// 원본의 `DigitGroupVisualTransformation` 같은 변환은 `VisualTransformation(filter:)` 로 만든다.
public struct VisualTransformation: @unchecked Sendable {
    public let filter: (String) -> TransformedText
    let isPassword: Bool
    let isNone: Bool

    public init(filter: @escaping (String) -> TransformedText) {
        self.filter = filter
        self.isPassword = false
        self.isNone = false
    }

    private init(isPassword: Bool) {
        self.filter = { TransformedText(text: $0, offsetMapping: .Identity) }
        self.isPassword = isPassword
        self.isNone = !isPassword
    }

    public static let None = VisualTransformation(isPassword: false)
    static let password = VisualTransformation(isPassword: true)
}

/// 비밀번호 가림. iOS 의 보안 입력(`isSecureTextEntry`)으로 그린다.
public func PasswordVisualTransformation() -> VisualTransformation {
    .password
}

// ─── 포커스 (Compose FocusRequester 자리) ─────────────────────────────────────

@MainActor
public final class FocusRequester {
    fileprivate weak var view: UIView?

    public init() {}

    public func requestFocus() {
        view?.becomeFirstResponder()
    }

    public func freeFocus() {
        view?.resignFirstResponder()
    }
}

// ─── BasicTextField ────────────────────────────────────────────────────────

/// Compose `BasicTextField` 자리. **값의 주인은 호출부다** — 입력을 `onValueChange` 로 넘기고, 호출부가 걸러 낸
/// (예: 숫자만 남긴) 값으로 표시를 되돌린다. SwiftUI `TextField` 는 호출부가 입력을 거부해 상태가 그대로면
/// 표시를 되돌리지 않고, 표시 변환과 커서 좌표 변환도 없어 `UITextField`·`UITextView` 를 직접 감쌌다.
public struct BasicTextField: View {
    fileprivate let value: String
    fileprivate let onValueChange: (String) -> Void
    fileprivate let textStyle: MoyeotaType
    fileprivate let keyboardOptions: KeyboardOptions
    fileprivate let keyboardActions: KeyboardActions
    fileprivate let visualTransformation: VisualTransformation
    fileprivate let singleLine: Bool
    fileprivate let enabled: Bool
    fileprivate let focusRequester: FocusRequester?
    fileprivate let onFocusChanged: ((Bool) -> Void)?
    fileprivate var fillsHeight = false

    public init(
        value: String,
        onValueChange: @escaping (String) -> Void,
        textStyle: MoyeotaType = MoyeotaType(),
        keyboardOptions: KeyboardOptions = .Default,
        keyboardActions: KeyboardActions = .Default,
        visualTransformation: VisualTransformation = .None,
        singleLine: Bool = false,
        enabled: Bool = true,
        focusRequester: FocusRequester? = nil,
        onFocusChanged: ((Bool) -> Void)? = nil
    ) {
        self.value = value
        self.onValueChange = onValueChange
        self.textStyle = textStyle
        self.keyboardOptions = keyboardOptions
        self.keyboardActions = keyboardActions
        self.visualTransformation = visualTransformation
        self.singleLine = singleLine
        self.enabled = enabled
        self.focusRequester = focusRequester
        self.onFocusChanged = onFocusChanged
    }

    public var body: some View {
        if singleLine {
            // `UIControl` 인 플랫폼 뷰의 `isEnabled` 는 SwiftUI 가 환경 값(`.disabled`)으로 덮어쓴다. 첫 배치에서는
            // `updateUIView` 가 넣은 값 위에 환경의 true 가 덮여, 처음부터 잠긴 칸이 다음 갱신까지 열려 있었다.
            // 그래서 호출부 값을 환경으로 내려 둘이 같은 값을 말하게 한다(바깥의 `.disabled` 도 함께 따른다).
            SingleLineInput(config: self)
                .disabled(!enabled)
        } else {
            MultiLineInput(config: self)
        }
    }

    /// 입력 칸이 부모(52dp 상자) 높이를 다 차지해 어디를 눌러도 포커스를 받게 한다.
    fileprivate func fillingHeight() -> BasicTextField {
        var copy = self
        copy.fillsHeight = true
        return copy
    }

    fileprivate var textColor: UIColor {
        (textStyle.color ?? LocalContentColorDefault).toUIColor()
    }

    fileprivate var capitalization: UITextAutocapitalizationType {
        switch keyboardOptions.capitalization {
        case .none: .none
        case .characters: .allCharacters
        case .words: .words
        case .sentences: .sentences
        }
    }

    fileprivate var returnKeyType: UIReturnKeyType {
        switch keyboardOptions.imeAction {
        case .go: .go
        case .search: .search
        case .send: .send
        case .next: .next
        // 안드로이드 한 줄 입력의 기본 확인 키는 「완료」다.
        case .unspecified, .none, .previous, .done: .done
        }
    }

    /// 확인 키를 눌렀을 때. `UITextField` 에서만 불린다(여러 줄은 줄바꿈이다).
    fileprivate func performImeAction(from view: UIView) {
        switch keyboardOptions.imeAction {
        case .next:
            if let action = keyboardActions.onNext { action() } else { moveFocus(from: view, forward: true) }
        case .previous:
            if let action = keyboardActions.onPrevious { action() } else { moveFocus(from: view, forward: false) }
        case .go: keyboardActions.onGo?()
        case .search: keyboardActions.onSearch?()
        case .send: keyboardActions.onSend?()
        case .done, .unspecified, .none:
            if let action = keyboardActions.onDone {
                action()
            } else if let field = view as? KeyboardHidingTextField {
                field.hideKeyboardKeepingFocus()
            } else {
                view.resignFirstResponder()
            }
        }
    }
}

@MainActor
private func moveFocus(from view: UIView, forward: Bool) {
    guard let window = view.window else {
        view.resignFirstResponder()
        return
    }
    func inputs(in root: UIView) -> [UIView] {
        var found: [UIView] = []
        for child in root.subviews where !child.isHidden {
            if let field = child as? UITextField, field.isEnabled {
                found.append(field)
            } else if let area = child as? UITextView, area.isEditable {
                found.append(area)
            } else {
                found += inputs(in: child)
            }
        }
        return found
    }
    let ordered = inputs(in: window).sorted { lhs, rhs in
        let a = lhs.convert(lhs.bounds, to: window)
        let b = rhs.convert(rhs.bounds, to: window)
        return a.minY == b.minY ? a.minX < b.minX : a.minY < b.minY
    }
    guard let index = ordered.firstIndex(of: view) else { return }
    let next = index + (forward ? 1 : -1)
    if ordered.indices.contains(next) {
        ordered[next].becomeFirstResponder()
    } else {
        view.resignFirstResponder()
    }
}

/// 칸이 포커스를 잃었다고 다음 차례에 알린다. 칸이 잠기면(`.disabled`) UIKit 이 SwiftUI 갱신 한가운데에서 포커스를 놓아,
/// 그 자리에서 호출부 `@State` 를 쓰면 값이 버려진다. 그러면 04a 처럼 제출 뒤에도 테두리가 Primary500 으로 남는다.
/// 원본 칸도 `enabled = false` 로 포커스를 잃고, 잠금을 풀어도 되찾지 않는다. 그 사이 다시 포커스를 받았으면 알리지 않는다.
@MainActor
private func reportFocusLost(from view: UIView, to onFocusChanged: ((Bool) -> Void)?) {
    Task { @MainActor [weak view] in
        guard let view, !view.isFirstResponder else { return }
        onFocusChanged?(false)
    }
}

/// 원본 `ImeAction.Done` 의 기본 동작 자리: **키보드만 내리고 포커스는 둔다.** 칸의 Primary500 테두리와 커서가 남고,
/// 다시 누르면 키보드가 올라온다(foundation 1.12.0 `KeyboardActionRunner` 바이트코드, 37 원본 렌더).
///
/// `UITextField` 에 그 동작이 따로 없어 빈 `inputView` 로 키보드 자리를 비운다. 숫자 자판의 「완료」 막대도 함께 뺀다.
private final class KeyboardHidingTextField: UITextField, UIGestureRecognizerDelegate {
    private(set) var keyboardHidden = false
    private var hiddenAccessory: UIView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        // 칸의 커서 옮기기·선택 제스처는 그대로 두고 탭만 함께 본다.
        let tap = UITapGestureRecognizer(target: self, action: #selector(tappedWhileFocused))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        addGestureRecognizer(tap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 원본 커서는 글자 끝에서 **시작해** 오른쪽으로 2 를 그린다. `UITextField` 커서는 글자가 있으면 1 왼쪽에서 시작해
    /// 앞 글자에 붙는다(10 「a」 잉크 끝에서 커서까지 원본 1.1dp, iOS 0pt). 첫 자리는 양쪽 다 칸 왼쪽 끝이다.
    override func caretRect(for position: UITextPosition) -> CGRect {
        let rect = super.caretRect(for: position)
        return offset(from: beginningOfDocument, to: position) > 0 ? rect.offsetBy(dx: 1, dy: 0) : rect
    }

    func hideKeyboardKeepingFocus() {
        guard isFirstResponder, !keyboardHidden else { return }
        keyboardHidden = true
        hiddenAccessory = inputAccessoryView
        inputAccessoryView = nil
        inputView = UIView(frame: .zero)
        reloadInputViews()
    }

    func restoreInputViews(reload: Bool) {
        guard keyboardHidden else { return }
        keyboardHidden = false
        inputView = nil
        inputAccessoryView = hiddenAccessory
        hiddenAccessory = nil
        if reload { reloadInputViews() }
    }

    @objc private func tappedWhileFocused() {
        restoreInputViews(reload: true)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    /// 07 인증 코드처럼 칸 밖의 탭 영역이 포커스를 부르는 호출도 키보드를 되살린다.
    override func becomeFirstResponder() -> Bool {
        restoreInputViews(reload: true)
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { restoreInputViews(reload: false) }
        return resigned
    }
}

@MainActor
private func doneToolbar(target: AnyObject, action: Selector) -> UIToolbar {
    let toolbar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
    toolbar.items = [
        UIBarButtonItem(systemItem: .flexibleSpace),
        UIBarButtonItem(barButtonSystemItem: .done, target: target, action: action),
    ]
    toolbar.sizeToFit()
    return toolbar
}

/// 입력 직후 호출부의 값과 표시를 맞추기까지의 시간차.
///
/// 호출부 상태는 `onValueChange` 에서 바로 바뀌어도 `updateUIView` 는 다음 갱신에야 불린다. 그 사이의 값은 낡았으므로,
/// 빠르게 치는 동안 낡은 값을 기준으로 삼거나 표시를 되돌리면 글자가 사라지고 순서가 뒤집힌다(시뮬레이터에서 재현했다).
/// 그래서 입력 중에는 코디네이터가 직접 가진 `raw` 를 기준으로 삼고, 입력이 멎은 뒤에 호출부 값으로 맞춘다.
/// 호출부가 입력을 받지 않아 상태가 그대로면 `updateUIView` 자체가 불리지 않으므로 이 맞춤이 표시를 되돌린다.
private let InputReconcileDelay = Duration.milliseconds(50)

private struct SingleLineInput: UIViewRepresentable {
    let config: BasicTextField

    func makeCoordinator() -> Coordinator {
        Coordinator(config: config)
    }

    func makeUIView(context: Context) -> KeyboardHidingTextField {
        let field = KeyboardHidingTextField(frame: .zero)
        field.delegate = context.coordinator
        field.borderStyle = .none
        field.backgroundColor = .clear
        field.adjustsFontForContentSizeCategory = false
        // 원본 BasicTextField 의 커서 기본색은 검정이다.
        field.tintColor = LocalContentColorDefault.toUIColor()
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged(_:)), for: .editingChanged)
        field.isEnabled = context.environment.isEnabled
        return field
    }

    func updateUIView(_ uiView: KeyboardHidingTextField, context: Context) {
        context.coordinator.config = config
        uiView.isEnabled = context.environment.isEnabled
        context.coordinator.sync(uiView)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: KeyboardHidingTextField, context: Context) -> CGSize? {
        let natural = max(ceil(config.textStyle.uiFont.lineHeight), config.textStyle.lineHeightPoints ?? 0)
        let height = config.fillsHeight ? (proposal.height ?? natural) : natural
        return CGSize(width: proposal.width ?? uiView.intrinsicContentSize.width, height: height)
    }

    @MainActor
    final class Coordinator: NSObject, UITextFieldDelegate {
        var config: BasicTextField
        private var appliedStyle: MoyeotaType?
        private weak var field: UITextField?
        /// 표시의 기준이 되는 원시 값. 입력 중에는 호출부보다 앞서 있다.
        private var raw: String
        private var editInFlight = false
        private var editGeneration = 0

        init(config: BasicTextField) {
            self.config = config
            self.raw = config.value
        }

        func sync(_ field: KeyboardHidingTextField) {
            self.field = field
            config.focusRequester?.view = field

            if appliedStyle != config.textStyle {
                appliedStyle = config.textStyle
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: config.textStyle.uiFont,
                    .foregroundColor: config.textColor,
                ]
                if config.textStyle.letterSpacing != 0 {
                    attributes[.kern] = config.textStyle.letterSpacing
                }
                field.defaultTextAttributes = attributes
            }

            let options = config.keyboardOptions
            let keyboardType = options.keyboardType.uiKeyboardType
            if field.keyboardType != keyboardType { field.keyboardType = keyboardType }
            if field.returnKeyType != config.returnKeyType { field.returnKeyType = config.returnKeyType }
            if field.autocapitalizationType != config.capitalization { field.autocapitalizationType = config.capitalization }
            let autocorrection: UITextAutocorrectionType = options.keyboardType.allowsAutocorrection ? .default : .no
            if field.autocorrectionType != autocorrection {
                field.autocorrectionType = autocorrection
                field.spellCheckingType = options.keyboardType.allowsAutocorrection ? .default : .no
            }
            if field.keyboardHidden {
                // 키보드를 내린 동안에는 막대를 얹지 않는다. 다시 올릴 때 칸이 되돌린다.
            } else if options.keyboardType.needsAccessoryDoneButton {
                if field.inputAccessoryView == nil {
                    field.inputAccessoryView = doneToolbar(target: self, action: #selector(accessoryDone))
                }
            } else if field.inputAccessoryView != nil {
                field.inputAccessoryView = nil
            }

            let secure = config.visualTransformation.isPassword
            if field.isSecureTextEntry != secure {
                field.isSecureTextEntry = secure
            }

            if !editInFlight {
                raw = config.value
                render(field)
            }
        }

        private func render(_ field: UITextField) {
            let display = config.visualTransformation.filter(raw).text
            let current = field.text ?? ""
            guard current != display else { return }
            // 값이 바깥에서 바뀌면 커서를 끝에서 같은 거리에 둔다. 호출부가 글자를 걸러 내도 쓰던 자리에 머문다.
            let fromEnd = field.selectedTextRange.map { field.offset(from: $0.end, to: field.endOfDocument) } ?? 0
            field.text = display
            if field.isFirstResponder {
                setCaret(field, offset: max(display.utf16.count - fromEnd, 0))
            }
        }

        private func setCaret(_ field: UITextField, offset: Int) {
            guard let position = field.position(from: field.beginningOfDocument, offset: offset) else { return }
            field.selectedTextRange = field.textRange(from: position, to: position)
        }

        func textField(
            _ textField: UITextField,
            shouldChangeCharactersIn range: NSRange,
            replacementString string: String
        ) -> Bool {
            let transformation = config.visualTransformation
            // 변환이 없으면 시스템이 고치게 둔다. 한글 조합(markedText)은 여기서 false 를 돌려주면 깨진다.
            if transformation.isNone { return true }

            // 변환이 있으면 표시 좌표의 편집을 원시 좌표로 옮겨 호출부에 넘긴다(Compose 와 같은 방식).
            // 보안 입력도 이 길로 온다. 시스템에 맡기면 다시 포커스를 받은 뒤 첫 글자에 내용을 통째로 지운다.
            let mapping = transformation.filter(raw).offsetMapping
            let rawUnits = Array(raw.utf16)
            var start = min(max(mapping.transformedToOriginal(range.location), 0), rawUnits.count)
            let end = min(max(mapping.transformedToOriginal(range.location + range.length), start), rawUnits.count)
            // 표시에만 있는 구분자를 지우려 하면 원시 범위가 빈다. Compose 는 원시 값의 커서 앞 글자를 지우므로 그렇게 한다.
            // (그러지 않으면 `010-|1` 에서 백스페이스가 아무 일도 하지 않는다.)
            if string.isEmpty, range.length > 0, start == end, start > 0 {
                start -= 1
            }
            let replaced = String(decoding: rawUnits[..<start] + Array(string.utf16) + rawUnits[end...], as: UTF16.self)
            let caret = start + string.utf16.count
            raw = replaced
            let transformed = transformation.filter(replaced)
            textField.text = transformed.text
            setCaret(textField, offset: min(max(transformed.offsetMapping.originalToTransformed(caret), 0), transformed.text.utf16.count))
            config.onValueChange(replaced)
            scheduleReconcile(textField)
            return false
        }

        @objc func editingChanged(_ field: UITextField) {
            let text = field.text ?? ""
            if text != raw {
                raw = text
                config.onValueChange(text)
            }
            scheduleReconcile(field)
        }

        private func scheduleReconcile(_ field: UITextField) {
            editInFlight = true
            editGeneration += 1
            let generation = editGeneration
            Task { @MainActor [weak self, weak field] in
                try? await Task.sleep(for: InputReconcileDelay)
                guard let self, let field, generation == self.editGeneration else { return }
                self.editInFlight = false
                // 조합 중인 글자는 건드리지 않는다. 조합이 끝나면 다시 editingChanged 가 온다.
                if field.markedTextRange == nil {
                    self.raw = self.config.value
                    self.render(field)
                }
            }
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            config.onFocusChanged?(true)
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            // 칸이 잠겨 UIKit 이 포커스를 놓는 길까지 여기서 받는다. 다음 포커스에 키보드가 떠야 한다.
            (textField as? KeyboardHidingTextField)?.restoreInputViews(reload: false)
            reportFocusLost(from: textField, to: config.onFocusChanged)
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            config.performImeAction(from: textField)
            return false
        }

        @objc private func accessoryDone() {
            guard let field else { return }
            config.performImeAction(from: field)
        }
    }
}

private struct MultiLineInput: UIViewRepresentable {
    let config: BasicTextField

    func makeCoordinator() -> Coordinator {
        Coordinator(config: config)
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = false
        view.tintColor = LocalContentColorDefault.toUIColor()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.config = config
        context.coordinator.sync(uiView)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? uiView.bounds.width
        guard width > 0, width.isFinite else { return nil }
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let minimum = config.textStyle.lineHeightPoints ?? ceil(config.textStyle.uiFont.lineHeight)
        let natural = max(fitted.height, minimum)
        // 부모가 높이를 정해 주면(52dp 입력 상자) 그 안에서 스크롤되고, 아니면 내용만큼 자란다.
        let height = proposal.height.map { min($0, natural) } ?? natural
        return CGSize(width: width, height: height)
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var config: BasicTextField
        private var appliedStyle: MoyeotaType?
        /// 표시의 기준이 되는 값. 입력 중에는 호출부보다 앞서 있다(`InputReconcileDelay` 참고).
        private var raw: String
        private var editInFlight = false
        private var editGeneration = 0

        init(config: BasicTextField) {
            self.config = config
            self.raw = config.value
        }

        private var attributes: [NSAttributedString.Key: Any] {
            let style = config.textStyle
            var result: [NSAttributedString.Key: Any] = [
                .font: style.uiFont,
                .foregroundColor: config.textColor,
            ]
            if style.letterSpacing != 0 {
                result[.kern] = style.letterSpacing
            }
            if let target = style.lineHeightPoints {
                let paragraph = NSMutableParagraphStyle()
                paragraph.minimumLineHeight = target
                paragraph.maximumLineHeight = target
                result[.paragraphStyle] = paragraph
            }
            return result
        }

        func sync(_ view: UITextView) {
            config.focusRequester?.view = view
            view.isEditable = config.enabled
            view.isSelectable = config.enabled
            view.keyboardType = config.keyboardOptions.keyboardType.uiKeyboardType
            view.autocapitalizationType = config.capitalization
            if appliedStyle != config.textStyle {
                appliedStyle = config.textStyle
                view.typingAttributes = attributes
                view.attributedText = NSAttributedString(string: view.text ?? "", attributes: attributes)
            }
            if !editInFlight {
                raw = config.value
                render(view)
            }
        }

        private func render(_ view: UITextView) {
            let value = raw
            guard view.text != value else { return }
            let fromEnd = (view.text as NSString).length - view.selectedRange.location - view.selectedRange.length
            view.attributedText = NSAttributedString(string: value, attributes: attributes)
            let length = (value as NSString).length
            view.selectedRange = NSRange(location: max(length - max(fromEnd, 0), 0), length: 0)
            view.typingAttributes = attributes
            view.invalidateIntrinsicContentSize()
        }

        func textViewDidChange(_ textView: UITextView) {
            let text = textView.text ?? ""
            if text != raw {
                raw = text
                config.onValueChange(text)
            }
            editInFlight = true
            editGeneration += 1
            let generation = editGeneration
            Task { @MainActor [weak self, weak textView] in
                try? await Task.sleep(for: InputReconcileDelay)
                guard let self, let textView, generation == self.editGeneration else { return }
                self.editInFlight = false
                if textView.markedTextRange == nil {
                    self.raw = self.config.value
                    self.render(textView)
                }
            }
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            config.onFocusChanged?(true)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            reportFocusLost(from: textView, to: config.onFocusChanged)
        }
    }
}

// ─── MoyeotaTextField ──────────────────────────────────────────────────────

// 텍스트 입력 — 토큰 text-input (h52, radius 12, 포커스 시 primary 테두리)
// 공통 규칙: 필드 단위 오류는 필드 하단 danger 문구
public struct MoyeotaTextField<Trailing: View>: View {
    private let value: String
    private let onValueChange: (String) -> Void
    private let label: String?
    private let placeholder: String
    private let errorText: String?
    private let helperText: String?
    private let keyboardOptions: KeyboardOptions
    private let visualTransformation: VisualTransformation
    private let singleLine: Bool
    private let enabled: Bool
    private let trailing: Trailing

    @State private var focused = false

    public init(
        value: String,
        onValueChange: @escaping (String) -> Void,
        label: String? = nil,
        placeholder: String = "",
        errorText: String? = nil,
        helperText: String? = nil,
        keyboardOptions: KeyboardOptions = .Default,
        visualTransformation: VisualTransformation = .None,
        singleLine: Bool = true,
        enabled: Bool = true,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.value = value
        self.onValueChange = onValueChange
        self.label = label
        self.placeholder = placeholder
        self.errorText = errorText
        self.helperText = helperText
        self.keyboardOptions = keyboardOptions
        self.visualTransformation = visualTransformation
        self.singleLine = singleLine
        self.enabled = enabled
        self.trailing = trailing()
    }

    public var body: some View {
        let borderColor = errorText != nil
            ? MoyeotaColor.Danger500
            : (focused ? MoyeotaColor.Primary500 : MoyeotaColor.Hairline)
        VStack(alignment: .leading, spacing: 0) {
            if let label {
                Text(label)
                    .moyeotaText(MoyeotaType.BodySm.hangulTrimmed, color: MoyeotaColor.TextBody)
                Spacer().frame(height: 8)
            }
            ZStack(alignment: .leading) {
                BasicTextField(
                    value: value,
                    onValueChange: onValueChange,
                    textStyle: MoyeotaType.BodyMd.copy(color: MoyeotaColor.InkPrimary),
                    keyboardOptions: keyboardOptions,
                    visualTransformation: visualTransformation,
                    singleLine: singleLine,
                    enabled: enabled,
                    onFocusChanged: { focused = $0 }
                )
                .fillingHeight()
                if value.isEmpty {
                    Text(placeholder)
                        .moyeotaText(.BodyMd, color: MoyeotaColor.TextAsh)
                        .allowsHitTesting(false)
                }
                // 원본처럼 입력 칸 위에 겹쳐 놓는다(입력 칸 폭을 줄이지 않는다).
                trailing
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .overlay(RoundedRectangle(cornerRadius: 12, style: .circular).strokeBorder(borderColor, lineWidth: 1))
            if let errorText {
                Text(errorText)
                    .moyeotaText(MoyeotaType.CaptionMd.hangulTrimmed, color: MoyeotaColor.Danger500)
                    .padding(.top, 6)
            } else if let helperText {
                Text(helperText)
                    .moyeotaText(MoyeotaType.CaptionMd.hangulTrimmed, color: MoyeotaColor.TextMute)
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

public extension MoyeotaTextField where Trailing == EmptyView {
    init(
        value: String,
        onValueChange: @escaping (String) -> Void,
        label: String? = nil,
        placeholder: String = "",
        errorText: String? = nil,
        helperText: String? = nil,
        keyboardOptions: KeyboardOptions = .Default,
        visualTransformation: VisualTransformation = .None,
        singleLine: Bool = true,
        enabled: Bool = true
    ) {
        self.init(
            value: value,
            onValueChange: onValueChange,
            label: label,
            placeholder: placeholder,
            errorText: errorText,
            helperText: helperText,
            keyboardOptions: keyboardOptions,
            visualTransformation: visualTransformation,
            singleLine: singleLine,
            enabled: enabled
        ) {
            EmptyView()
        }
    }
}

