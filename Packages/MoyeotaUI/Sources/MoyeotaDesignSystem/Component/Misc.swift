import SwiftUI
import UIKit

// 온보딩 페이지 인디케이터 — 활성은 20x8 pill, 비활성은 8x8 dot
public struct PageDots: View {
    private let count: Int
    private let activeIndex: Int

    public init(count: Int, activeIndex: Int) {
        self.count = count
        self.activeIndex = activeIndex
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ForEach(0..<count, id: \.self) { i in
                if i == activeIndex {
                    Capsule(style: .circular)
                        .fill(MoyeotaColor.Primary500)
                        .frame(width: 20, height: 8)
                } else {
                    Circle()
                        .fill(MoyeotaColor.TextAsh)
                        .frame(width: 8, height: 8)
                }
            }
        }
    }
}

public enum NoticeKind: Sendable {
    case info, error, success, waiting

    var colors: (background: Color, foreground: Color) {
        switch self {
        case .info: (MoyeotaColor.Primary50, MoyeotaColor.Primary600)
        case .error: (MoyeotaColor.Danger50, MoyeotaColor.Danger600)
        case .success: (MoyeotaColor.Success50, MoyeotaColor.Success600)
        case .waiting: (MoyeotaColor.Waiting50, MoyeotaColor.Waiting600)
        }
    }
}

// 공통 규칙: 화면 단위 오류는 CTA 위 NoticeBanner Kind=error
public struct NoticeBanner: View {
    private let kind: NoticeKind
    private let text: String

    public init(kind: NoticeKind, text: String) {
        self.kind = kind
        self.text = text
    }

    public var body: some View {
        let colors = kind.colors
        Text(text)
            .moyeotaText(MoyeotaType.BodySm.hangulTrimmed, color: colors.foreground)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(colors.background, in: RoundedRectangle(cornerRadius: 12, style: .circular))
    }
}

// 상태 배지 (모집 중 · 매칭 완료 · 대기 등)
public struct StatusBadge: View {
    private let kind: NoticeKind
    private let text: String

    public init(kind: NoticeKind, text: String) {
        self.kind = kind
        self.text = text
    }

    public var body: some View {
        let colors = kind.colors
        // 지정 줄 높이는 16.2 지만 원본 한글 한 줄은 대체 폰트 높이 17.2dp 로 그려진다(22 「모집 중」 UI 트리에서 잼).
        Text(text)
            .moyeotaText(
                MoyeotaType.CaptionMd.copy(fontWeight: .semibold, lineHeight: .sp(17.25)),
                color: colors.foreground
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(colors.background, in: Capsule(style: .circular))
    }
}

/// 아바타. `imageUrl` 이 있으면 서버 프로필 사진을 그리고, **그릴 수 없을 때는 `label`**(없으면 회색 원)
/// 으로 되돌아간다.
///
/// ### 네 경우에 무엇이 보이는가
///
/// | 경우 | 보이는 것 |
/// |---|---|
/// | `imageUrl` 이 nil/빈 값 | `label` 또는 빈 회색 원 — **요청을 만들지 않는다** |
/// | 로딩 중 | 같음 |
/// | 성공 | 사진 |
/// | 실패(403·타임아웃·디코드 실패) | 같음 |
///
/// 이 앱에서 사진 없음은 **정상 경우**(유저 요약이 없는 멤버·조회 실패)라, 요청을 만들고 실패 경로를
/// 타는 것보다 분기로 거르는 쪽이 의도를 정확히 말한다.
///
/// 대체 표시를 **아래에 깔고 성공했을 때만 가린다.** 페이드를 두지 않는다 — 대체 표시를 지운 뒤
/// 사진이 떠오르는 동안 빈 원만 남아 깜빡이기 때문이다(`MoyeotaImageLoader` 도 페이드를 쓰지 않는다).
///
/// ### 표시 상태의 키가 `imageUrl` 인 이유
/// 채팅 목록이 최근 메시지 순으로 재정렬되거나 매칭 대기의 멤버가 한 명 나가 목록이 밀리면, 같은 위치의
/// 뷰가 **다른 방·다른 사람**을 받을 수 있다. 키가 없으면 **새 사람의 대체 표시가 가려진 채 앞 사람 사진이
/// 남는다.** `MoyeotaAsyncImage` 가 URL 이 다른 결과를 버리는 건 같은 이유다.
public struct AvatarCircle: View {
    private let size: CGFloat
    private let label: String?
    private let imageUrl: String?

    public init(size: CGFloat = 40, label: String? = nil, imageUrl: String? = nil) {
        self.size = size
        self.label = label
        self.imageUrl = imageUrl
    }

    public var body: some View {
        MoyeotaAsyncImage(url: imageUrl) { image in
            ZStack {
                if let label, image == nil {
                    Text(label)
                        .moyeotaText(.CaptionMd, color: MoyeotaColor.TextMute)
                }
                if let image {
                    // 지름에서 2 를 빼는 이유: 꽉 찬 원형 이미지는 부모의 1dp 헤어라인을 덮는다.
                    // 비정사각 이미지가 원 안에서 레터박스가 되지 않게 채워서 자른다.
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size - 2, height: size - 2)
                        .clipShape(Circle())
                        // 이름을 바로 옆에서 읽어 주는 자리들이라 사진은 장식이다 — 중복 낭독을 막는다.
                        .accessibilityHidden(true)
                }
            }
            .frame(width: size, height: size)
            .background(MoyeotaColor.SurfaceSoft, in: Circle())
            .overlay(Circle().strokeBorder(MoyeotaColor.Hairline, lineWidth: 1))
        }
    }
}

/// Coil `AsyncImage` 자리. 불러온 `UIImage`(아직 없거나 실패했으면 nil)를 받아 그린다.
///
/// `url` 이 nil·빈 값이면 요청을 만들지 않는다. 메모리 캐시에 있으면 첫 프레임부터 사진이 나온다.
public struct MoyeotaAsyncImage<Content: View>: View {
    private let url: String?
    private let content: (UIImage?) -> Content

    @State private var loaded: (url: String, image: UIImage)?

    public init(url: String?, @ViewBuilder content: @escaping (UIImage?) -> Content) {
        self.url = url?.allSatisfy(\.isWhitespace) == true ? nil : url
        self.content = content
    }

    public var body: some View {
        content(currentImage)
            .task(id: url) {
                guard let url, currentImage == nil else { return }
                // 실패·취소는 대체 표시로 남는다.
                guard let image = try? await MoyeotaImageLoader.load(url) else { return }
                loaded = (url, image)
            }
    }

    private var currentImage: UIImage? {
        guard let url else { return nil }
        if let loaded, loaded.url == url { return loaded.image }
        return MoyeotaImageLoader.cachedImage(url)
    }
}

/// 이미지 로더. 원본의 `MoyeotaApplication.newImageLoader` 자리다.
///
/// 네트워크 구성은 이 모듈이 알지 못한다 — 앱 시작 때 `configure(session:)` 에 `Apis.imageClient` 를 넘긴다
/// (디스크 캐시 32MB 는 그 세션의 `URLCache` 가 맡는다). 메모리 캐시 크기는 원본과 같이 앱 메모리의 15% 다.
@MainActor
public enum MoyeotaImageLoader {
    private static var session: URLSession = .shared

    private static let memoryCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = Int(Double(ProcessInfo.processInfo.physicalMemory) * 0.15)
        return cache
    }()

    public static func configure(session: URLSession) {
        self.session = session
    }

    public static func cachedImage(_ url: String) -> UIImage? {
        memoryCache.object(forKey: url as NSString)
    }

    public static func load(_ url: String) async throws -> UIImage {
        if let cached = cachedImage(url) { return cached }
        guard let parsed = URL(string: url) else { throw URLError(.badURL) }
        let (data, response) = try await session.data(from: parsed)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        let decoded = await Task.detached { UIImage(data: data)?.preparingForDisplay() ?? UIImage(data: data) }.value
        guard let decoded else { throw URLError(.cannotDecodeContentData) }
        memoryCache.setObject(decoded, forKey: url as NSString, cost: data.count * 4)
        return decoded
    }
}

// 선택 칩 (매칭 조건 등)
public struct MoyeotaChip: View {
    private let text: String
    private let selected: Bool
    private let onClick: () -> Void

    public init(text: String, selected: Bool, onClick: @escaping () -> Void) {
        self.text = text
        self.selected = selected
        self.onClick = onClick
    }

    public var body: some View {
        let bg = selected ? MoyeotaColor.Primary50 : MoyeotaColor.SurfaceCanvas
        let fg = selected ? MoyeotaColor.Primary600 : MoyeotaColor.TextMute
        let border = selected ? MoyeotaColor.Primary500 : MoyeotaColor.Hairline
        Button(action: onClick) {
            Text(text)
                .moyeotaText(.ButtonMd, color: fg)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(bg, in: Capsule(style: .circular))
                .overlay(Capsule(style: .circular).strokeBorder(border, lineWidth: 1))
                .contentShape(Capsule(style: .circular))
        }
        .buttonStyle(PressFeedbackStyle())
    }
}

// 바텀시트 핸들
public struct SheetHandle: View {
    public init() {}

    public var body: some View {
        Capsule(style: .circular)
            .fill(MoyeotaColor.TextAsh)
            .frame(width: 36, height: 4)
    }
}

// 지도 자리표시 — SDK 없이 와이어프레임처럼 격자 배경
public struct MapPlaceholder: View {
    public init() {}

    public var body: some View {
        ZStack {
            MoyeotaColor.SurfaceSoft
            Rectangle()
                .fill(Color(argb: 0xFFE2E6ED))
                .frame(height: 2)
                .padding(.horizontal, 24)
            Text("지도 영역")
                .moyeotaText(.CaptionMd, color: MoyeotaColor.TextAsh)
        }
    }
}

public extension View {
    /// Compose `Modifier.shadow(elevation, shape, spotColor = …)` 자리. 뷰 뒤에 모양을 깔아 그림자를 드리운다.
    ///
    /// 안드로이드 그림자는 앰비언트(사방, 기본 검정)와 스폿(아래로 치우침, `spotColor`) 두 겹이고, 시스템이
    /// 각 색 알파에 0.039·0.19 를 곱한다. 같은 두 겹을 같은 알파로 그리되 번짐·거리는 고도에서 환산한 근사다.
    func moyeotaShadow<S: Shape>(
        elevation: CGFloat,
        shape: S,
        ambientColor: Color = .black,
        spotColor: Color = .black
    ) -> some View {
        background {
            ZStack {
                shape
                    .fill(Color.white)
                    .shadow(color: ambientColor.opacity(0.039), radius: elevation * 0.5)
                shape
                    .fill(Color.white)
                    .shadow(color: spotColor.opacity(0.19), radius: elevation * 0.5, y: elevation * 0.5)
            }
        }
    }
}
