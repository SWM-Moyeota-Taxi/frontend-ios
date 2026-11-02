import Foundation
import MoyeotaDomain
import SwiftUI
import UIKit
import Testing
@testable import AppNavigation

struct FakeFailure: Error {}

final class FakeAuthRepository: AuthRepository, @unchecked Sendable {
    let flow: MutableStateFlow<AuthState>
    var authState: StateFlow<AuthState> { flow }

    init(_ initial: AuthState) {
        flow = MutableStateFlow(initial)
    }

    func sendPhoneVerificationCode(phoneNumber: String) async throws { throw FakeFailure() }
    func verifyPhoneCode(phoneNumber: String, code: String) async throws -> String { throw FakeFailure() }
    func register(newUser: NewUser) async throws -> String { throw FakeFailure() }
    func isNicknameTaken(nickname: String) async throws -> Bool { false }
    func isPhoneRegistered(phoneNumber: String) async throws -> Bool { false }
    func updateProfile(nickname: String?, imageKey: String?) async throws {}
    func getProfileImages() async throws -> [ProfileImage] { [] }
    func resetProfileImage() async throws {}
    func login(loginId: String, password: String) async throws -> String { throw FakeFailure() }
    func logout() async throws { flow.value = .unauthenticated }
    func deleteAccount(password: String) async throws { throw FakeFailure() }
    func getMyProfile() async throws -> UserProfileInfo { UserProfileInfo(uuid: "u", name: "테스터") }
}

final class FakeAppConfigRepository: AppConfigRepository, @unchecked Sendable {
    var config: AppConfig
    init(_ config: AppConfig = .Default) { self.config = config }
    func getConfig() async throws -> AppConfig { config }
}

final class FakeRideRepository: RideRepository, DispatchRepository, @unchecked Sendable {
    var ride: Ride?
    var parties: [Ride] = []
    private let lock = NSLock()
    private var requested: [Int64] = []
    var detailRequests: [Int64] { lock.withLock { requested } }
    private var withinCount = 0
    /// 17 목록 조회 횟수 — 화면이 한 번 시작했는지 세는 데 쓴다.
    var withinRequests: Int { lock.withLock { withinCount } }

    func getNearbyParties() -> [Ride] { [] }
    func getParties() async throws -> [Ride] { parties }
    func getPartiesWithin(swLat: Double, swLng: Double, neLat: Double, neLng: Double) async throws -> [Ride] {
        lock.withLock { withinCount += 1 }
        return parties
    }
    func getPartyDetail(partyId: Int64) async throws -> Ride {
        lock.withLock { requested.append(partyId) }
        guard let ride else { throw FakeFailure() }
        return ride
    }
    func getPartyDetailWithVersion(partyId: Int64) async throws -> PartyDetail {
        PartyDetail(ride: try await getPartyDetail(partyId: partyId), version: 1)
    }
    func findRealtimeCandidates(
        departureLat: Double, departureLng: Double, destinationLat: Double, destinationLng: Double
    ) async throws -> [MatchCandidate] { [] }
    func createParty(request: NewParty) async throws -> Ride { throw FakeFailure() }
    func joinParty(partyId: Int64) async throws -> PartyStatus { throw FakeFailure() }
    func leaveParty(partyId: Int64) async throws {}
    func finishParty(partyId: Int64) async throws {}
    func getAssignedDriver(partyId: Int64) async throws -> AssignedDriver { throw FakeFailure() }
    func reportEmergency(partyId: Int64?) async throws -> Int64 { throw FakeFailure() }
    func confirmEmergencyCall(called: Bool) async throws {}
    func previewRoute(
        departureLat: Double, departureLng: Double, destinationLat: Double, destinationLng: Double
    ) async throws -> RouteEstimate { throw FakeFailure() }
    func getDriverLocation(partyId: Int64) async throws -> DriverLocation { throw FakeFailure() }
}

final class FakePlaceRepository: PlaceRepository, @unchecked Sendable {
    func searchPlaces(query: String) async throws -> [Place] { [] }
    func reverseGeocode(latitude: Double, longitude: Double) async throws -> ReverseAddress? { nil }
    func addFavoritePlace(place: Place) async throws {}
    func getFavoritePlaces() async throws -> [FavoritePlace] { [] }
    func deleteFavoritePlace(id: Int64) async throws {}
    func deleteFavoritePlaces(ids: [Int64]) async throws {}
    func deleteAllFavoritePlaces() async throws {}
}

final class FakeChatRepository: ChatRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var observed: [Int64] = []
    private var fetched: [Int64] = []
    /// 실시간 구독을 연 방을 연 순서대로 — 소켓이 끊겼다 다시 붙으면 같은 방이 두 번 나온다.
    var observedRooms: [Int64] { lock.withLock { observed } }
    var messageRequests: [Int64] { lock.withLock { fetched } }

    func getMyChatRooms() async throws -> [MyChatRoom] { [] }
    func getChatRoom(chatRoomId: Int64) async throws -> ChatRoom {
        ChatRoom(id: chatRoomId, partyId: 0, departure: "부산대", destination: "서면", createdAt: "", status: .active)
    }
    func joinChatRoom(chatRoomId: Int64) async throws {}
    func leaveChatRoom(chatRoomId: Int64) async throws {}
    func getChatRoomMembers(chatRoomId: Int64) async throws -> [ChatMember] { [] }
    func setNotificationMuted(chatRoomId: Int64, muted: Bool) async throws {}
    func markAsRead(chatRoomId: Int64, readMessageId: Int64) async throws {}
    func getMessages(chatRoomId: Int64, cursor: Int64?, size: Int) async throws -> ChatMessagePage {
        lock.withLock { fetched.append(chatRoomId) }
        return ChatMessagePage(messages: [], nextCursor: nil, hasNext: false)
    }
    func observeRoom(chatRoomId: Int64) -> AsyncStream<ChatRealtimeEvent> {
        lock.withLock { observed.append(chatRoomId) }
        return AsyncStream { _ in }
    }
    func getMessagesAfter(chatRoomId: Int64, cursor: Int64, size: Int) async throws -> ChatMessagePage {
        ChatMessagePage(messages: [], nextCursor: nil, hasNext: false)
    }
    func sendMessage(chatRoomId: Int64, content: String) async throws -> ChatMessage { throw FakeFailure() }
    func deleteMessage(chatRoomId: Int64, messageId: Int64) async throws {}
    func searchMessages(chatRoomId: Int64, keyword: String, cursor: Int64?, size: Int) async throws -> ChatMessagePage {
        ChatMessagePage(messages: [], nextCursor: nil, hasNext: false)
    }
    func reportMessage(
        chatRoomId: Int64, chatMessageId: Int64, reason: ChatReportReason, description: String?
    ) async throws {}
}

final class FakeActivePartyRepository: ActivePartyRepository, @unchecked Sendable {
    var ride: Ride?
    func remember(partyId: String) async throws {}
    func clear() async throws { ride = nil }
    func resolve() async throws -> Ride? { ride }
}

final class FakeRideRecordRepository: RideRecordRepository, @unchecked Sendable {
    func getMyRecords(cursor: Int64?, size: Int) async throws -> RideRecordPage {
        RideRecordPage(records: [], nextCursor: nil, hasNext: false)
    }
}

func fakeRide(id: String = "7", status: RideStatus = .recruiting, driverId: Int64? = nil) -> Ride {
    Ride(
        id: id, origin: "부산대", destination: "서면", departureLabel: "지금 출발",
        capacity: 2, members: [], farePerPerson: 0, totalFare: 0,
        status: status, driverId: driverId
    )
}

/// 씬이 없는 창에는 안전 영역이 없다. 실기 값(iPhone 17: 위 62, 아래 34)을 흉내 낸다.
/// 창의 값을 덮으면 `WindowInsetSpacer` 와 하위 컨트롤러·SwiftUI 의 안전 영역이 모두 이 값을 받는다.
final class InsetWindow: UIWindow {
    static let insets = UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0)
    override var safeAreaInsets: UIEdgeInsets { Self.insets }
}

@MainActor
@Observable
final class PendingBox {
    var roomId: Int64?
    var handled = 0
}

struct GraphHarness: View {
    let auth: FakeAuthRepository
    let config: FakeAppConfigRepository
    let rides: FakeRideRepository
    let active: FakeActivePartyRepository
    let chat: FakeChatRepository
    let installedVersionCode: Int64
    let probe: MainNavGraphProbe
    @Bindable var pending: PendingBox

    var body: some View {
        MainNavGraph(
            authRepository: auth,
            appConfigRepository: config,
            rideRepository: rides,
            placeRepository: FakePlaceRepository(),
            chatRepository: chat,
            dispatchRepository: rides,
            activePartyRepository: active,
            rideRecordRepository: FakeRideRecordRepository(),
            pendingChatRoomId: pending.roomId,
            onPendingChatRoomHandled: {
                pending.roomId = nil
                pending.handled += 1
            },
            installedVersionCode: installedVersionCode,
            debuggable: true,
            probe: probe
        )
        // 씬이 없는 창의 scenePhase 는 background 라 `lifecycleEffect` 가 시작하지 않는다. 실기의 전면 상태로 맞춘다.
        .environment(\.scenePhase, .active)
    }
}

/// 창에 올린 실제 `MainNavGraph`.
@MainActor
final class HostedGraph {
    let auth: FakeAuthRepository
    let config: FakeAppConfigRepository
    let rides = FakeRideRepository()
    let active = FakeActivePartyRepository()
    let chat = FakeChatRepository()
    let probe = MainNavGraphProbe()
    let pending = PendingBox()
    let window: InsetWindow
    let host: UIViewController

    init(
        auth initial: AuthState = .authenticated(userUuid: "u"),
        config appConfig: AppConfig = .Default,
        activeRide: Ride? = nil,
        installedVersionCode: Int64 = 100,
        height: CGFloat = 874
    ) {
        auth = FakeAuthRepository(initial)
        config = FakeAppConfigRepository(appConfig)
        active.ride = activeRide
        rides.ride = activeRide
        window = InsetWindow(frame: CGRect(x: 0, y: 0, width: 402, height: height))
        host = UIHostingController(
            rootView: GraphHarness(
                auth: auth, config: config, rides: rides, active: active, chat: chat,
                installedVersionCode: installedVersionCode, probe: probe, pending: pending
            )
        )
        window.rootViewController = host
        window.isHidden = false
    }

    func close() async {
        window.rootViewController = nil
        window.isHidden = true
        await settle()
    }

    var nav: MoyeotaNavController {
        get throws { try #require(probe.navController) }
    }

    var routes: [Route] { probe.navController?.backStack.map(\.route) ?? [] }

    var navigationController: UINavigationController? {
        Self.find(in: host)
    }

    private static func find(in controller: UIViewController) -> UINavigationController? {
        if let found = controller as? UINavigationController { return found }
        for child in controller.children {
            if let found = find(in: child) { return found }
        }
        return nil
    }

    var scrollViews: [UIScrollView] { allViews(of: UIScrollView.self, in: topView) }

    /// 지금 맨 위 화면의 뷰. 스택이 있으면 맨 위 컨트롤러, 없으면 창 전체다.
    var topView: UIView {
        navigationController?.topViewController?.view ?? host.view
    }

    func allViews<View: UIView>(of type: View.Type, in root: UIView) -> [View] {
        var found: [View] = []
        if let view = root as? View, !view.isHidden { found.append(view) }
        for child in root.subviews { found += allViews(of: type, in: child) }
        return found
    }

    /// 상태바·내비게이션바 여백(`WindowInsetSpacer`)이 잰 자리를 창 좌표로.
    func insetSpacerFrames(in root: UIView) -> [CGRect] {
        probeViews(in: root).map { $0.convert($0.bounds, to: window) }
    }

    private func probeViews(in root: UIView) -> [UIView] {
        var found: [UIView] = []
        if String(describing: type(of: root)).contains("WindowInsetProbeView") { found.append(root) }
        for child in root.subviews { found += probeViews(in: child) }
        return found
    }

    func settle(_ rounds: Int = 12) async {
        for _ in 0..<rounds {
            window.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    func waitUntil(
        _ what: String,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: () -> Bool
    ) async {
        for _ in 0..<240 {
            window.layoutIfNeeded()
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("기다려도 되지 않았다: \(what) (스택 \(routes))", sourceLocation: sourceLocation)
    }

    /// 스택 화면 수가 맞고 전환이 끝날 때까지.
    func waitForViewControllers(
        _ count: Int,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        await waitUntil("화면 \(count)장", sourceLocation: sourceLocation) {
            navigationController?.viewControllers.count == count
                && navigationController?.transitionCoordinator == nil
        }
    }

    /// 창에 붙은 가장자리 소비 제스처. pop 이 시작되지 않는 스와이프를 받는다.
    var edgeConsumer: UIGestureRecognizer? {
        window.gestureRecognizers?.first { $0 is UIScreenEdgePanGestureRecognizer }
    }

    /// 가장자리 스와이프가 시작될 때 시스템이 부르는 판정을 그대로 부른다(손가락은 흉내 낼 수 없다). 두 제스처가 같은 터치를 보므로 둘 다 부른다.
    /// 시스템 pop 이 시작되는지를 돌려준다.
    @discardableResult
    func edgeSwipeShouldBegin() throws -> Bool {
        let navigationController = try #require(navigationController)
        let gesture = try #require(navigationController.interactivePopGestureRecognizer)
        let delegate = try #require(gesture.delegate)
        let pops = delegate.gestureRecognizerShouldBegin?(gesture) ?? true
        let consumer = try #require(edgeConsumer)
        let consumed = delegate.gestureRecognizerShouldBegin?(consumer) ?? true
        #expect(pops != consumed, "pop 이 아니면 소비 제스처가 터치를 받아야 아래 화면이 눌리지 않는다")
        return pops
    }
}
