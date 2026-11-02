import Foundation
import MoyeotaDesignSystem
import MoyeotaDomain
import PresentationCore
import SwiftUI

private let ChipBlueBg = Color(argb: 0xFFF1F5FD)
private let GraySlate = Color(argb: 0xFF4B5563)
private let GrayDeep = Color(argb: 0xFF54637D)
private let GrayMute = Color(argb: 0xFF8A93A0)
private let GrayAsh = Color(argb: 0xFF9AA1AC)
private let CardShadow = Color(argb: 0x1A1B2A4A)

/// 16 지도·요약 칩·요금 문구에 쓰이는 경로 미리보기 값 (POST /matching/routes 응답).
///
/// 방을 만들기 **전**이라 서버가 확정한 값이 아니다 — 좌표만으로 뽑은 추정치이며,
/// 실패해도 방 생성은 막지 않는다(서버가 생성 시 어차피 다시 계산한다).
/// 셋 다 nil 이고 `loading` 이 false 면 「값 없음」 — 칩·요금 문구를 감춘다.
public struct RoutePreviewUi: Equatable, Sendable {
    public var loading: Bool
    public var estimatedMinutes: Int?
    public var estimatedFare: Int? // 미터기 추정 총액(1인 요금 아님)
    public var encodedPath: String? // Google Encoded Polyline — 25 배차 화면과 같은 형식

    public init(
        loading: Bool = false,
        estimatedMinutes: Int? = nil,
        estimatedFare: Int? = nil,
        encodedPath: String? = nil
    ) {
        self.loading = loading
        self.estimatedMinutes = estimatedMinutes
        self.estimatedFare = estimatedFare
        self.encodedPath = encodedPath
    }
}

/// 16 에서 고른 매칭 조건. 지금은 **정원 하나뿐**이다.
///
/// 「출발지 반경」·「도착지 반경」 칩은 지웠다(2026-10-14). 서버가 방 생성 요청에서 반경을 빼고
/// 고정값(500m)을 쓰기로 했다(Backend `a668aee`) — 보내도 버려진다. 그전에도 어떤 조회·판정도
/// 그 값을 읽지 않아(합류에 거리 검사가 없고 목록은 지도 뷰포트만 본다) 사용자는 **아무 영향 없는
/// 값**을 「매칭 조건」이라는 이름으로 고르고 있었다. 「준비 중」 자리표시를 두지 않고 요소째 내렸다.
///
/// 「동성만」 토글도 없다 — 성별은 매칭에 쓰이지 않는다(백엔드 `matching` 패키지에 성별 필드 0건).
/// 고를 수는 있는데 아무 일도 일어나지 않는 조건은 두지 않는다.
public struct MatchConditions: Equatable, Sendable {
    public var capacity: Int

    public init(capacity: Int) {
        self.capacity = capacity
    }
}

/// 원본 `"%,d".format` 자리. 기기 로케일의 묶음 기호를 쓴다.
func groupedAmount(_ amount: Int, locale: Locale = .current) -> String {
    amount.formatted(.number.locale(locale).grouping(.automatic))
}

/// 요약 칩 문구 — 거리는 서버 응답에 없어 시간·총요금으로 대체한다(와이어프레임의 2값 구조 유지).
/// nil 이면 실패 — 칩 자체를 감춘다. 틀린 값보다 없는 편이 낫다.
func routeSummaryLabel(routePreview: RoutePreviewUi, locale: Locale = .current) -> String? {
    if routePreview.loading { return "예상 경로 계산 중" }
    if let minutes = routePreview.estimatedMinutes, let fare = routePreview.estimatedFare {
        return "예상 \(minutes)분 · 총 \(groupedAmount(fare, locale: locale))원"
    }
    return nil
}

/// 시트 푸터의 요금 안내. 1인 요금 = 미터기 추정 총액 ÷ 인원, 10원 단위 반올림(`farePerPersonWon` — 19·22·25 가 쓰는
/// 서버 값 계산식과 **같은 규칙**이다). 추정이 아직 없거나 실패했어도 CTA 는 살려 둔다.
func fareFooterText(routePreview: RoutePreviewUi, peopleCount: Int, locale: Locale = .current) -> String {
    if routePreview.loading { return "예상 요금 계산 중이에요" }
    // 뒤에 붙던 설명 문구(「인원이 확정되면…」)는 뺐다 — 한 줄 안내는 금액만으로 충분하다
    if let total = routePreview.estimatedFare {
        let perPerson = groupedAmount(farePerPersonWon(totalFare: total, people: peopleCount), locale: locale)
        return "예상 요금 1인 \(perPerson)원"
    }
    return "예상 요금 —"
}

/// 이름이 이미 실주소면 호출부가 주소 칸을 비워 보낸다 — 구분자만 남지 않게 합친다
func destinationBadgeLabel(destinationName: String, destinationAddress: String) -> String {
    [destinationName, destinationAddress]
        .filter { !$0.isBlank }
        .joined(separator: " · ")
}

/// 16 · 도착지 확인 · 매칭 조건 (모달) [신규]
///
/// 이동(디스크립션):
/// - 닫기·배경 탭 → 15 (onDismiss) — 공통 규칙: 모달은 배경 탭·닫기로만 종료
/// - 「같이 탈 사람 찾기」 → 방 생성(POST /matching/rooms) 성공 시 21 매칭 대기 (onFindCompanions)
///   선택한 매칭 조건(인원)을 그대로 넘긴다.
///
/// 선택 규칙(디스크립션):
/// - 인원(나 포함) 1~3명 → 예상 1인 요금 재계산 (`RoutePreviewUi.estimatedFare` ÷ 인원, `farePerPersonWon`)
///   기본값 3명. **고를 수 있는 조건은 이것뿐이다** — 반경 칩과 「매칭 방식」 행은 지웠다
///   (`MatchConditions` 설명: 서버가 반경을 고정값으로 정하고, 승차지점 개념 자체가 없다)
/// - **1명을 고르면** 칩 행 아래에 「혼자 출발한다」 안내가 붙는다(`soloCapacityNotice`) —
///   정원 1 은 만든 즉시 꽉 찬 방이라 아무도 합류할 수 없다. 선택지와 전송 값은 그대로다
///
/// 레이아웃(디스크립션):
/// - 지도가 헤더 아래를 전부 채우고, 그 위에 **드래그로 접었다 펴는 시트**가 얹힌다
/// - 펼침 = 매칭 조건까지 전부 보임(지도 160pt 노출) / 접힘 = 도착지·요금·CTA 만 보이고 지도가 넓어짐
/// - CTA 는 시트 하단에 고정이라 두 상태 모두에서 보인다
public struct DestinationConfirmModal: View {
    private let destinationName: String
    private let destinationAddress: String
    private let originStopName: String
    private let departureTimeLabel: String
    private let arrivalTimeLabel: String
    private let destinationPosition: LatLng?
    private let originPosition: LatLng?
    private let routePreview: RoutePreviewUi
    private let creating: Bool
    private let errorMessage: String?
    private let onDismiss: () -> Void
    private let onAdjustPositions: (LatLng?, LatLng?) -> Void
    private let onFindCompanions: (MatchConditions) -> Void
    private let nearbyCandidates: [MatchCandidate]
    private let onCandidateClick: (MatchCandidate) -> Void
    private let nearbyLoadFailed: Bool
    private let onRetryNearby: () -> Void

    // 기본값: 3인 (디스크립션 유효값 규칙)
    @State private var peopleCount = 3
    // 핀 조정 화면(모달 내 확장 상태). nil 이면 닫혀 있다.
    @State private var adjustTarget: PinTarget?

    // 원본 `remember(key)` 자리 — 시트를 끄는 동안 지도 슬롯이 프레임마다 다시 평가되므로,
    // 폴리라인 해석과 카메라 계산을 그때마다 돌리지 않는다.
    @State private var routeMemo = Remembered<String?, [LatLng]>()
    @State private var fitMemo = Remembered<FitKey, (first: LatLng, second: Double)?>()

    /// - Parameters:
    ///   - destinationName: 이름 자리에는 검색 장소명 대신 **역지오코딩 실주소**가 들어올 수 있다(핀 조정·GPS 출발지).
    ///     「부산광역시 금정구 부산대학로63번길 2 부산대학교」처럼 길어지므로 표기는 전부 1줄 말줄임이다 —
    ///     시/도 접두 제거 같은 가공은 하지 않는다(서버가 조합해 준 값을 그대로 보여준다).
    ///   - destinationPosition: 지도 좌표 — 도착지가 있으면 실지도, 없으면 자리표시자 (15 를 거치지 않은 진입)
    ///   - creating: 방 생성 요청 중 — 중복 제출 차단
    ///   - onAdjustPositions: 핀 조정 확정 — (출발지, 도착지) 좌표. 조정하지 않은 쪽은 들어온 값 그대로 돌아온다
    ///   - nearbyCandidates: 「걸어서 가까운 방」 추천. **빈 목록이 기본값이자 기본 상태**다 — 서버가 출발지·도착지
    ///     각각 300m 안(AND)에서만 고르기 때문에 초기에는 거의 항상 비어 있다. 비면 섹션을 그리지 않는다.
    ///     서버가 도보 시간 순으로 정렬해 준 순서 그대로 받는다 — **여기서 다시 정렬하지 않는다.**
    ///   - onCandidateClick: 추천 카드를 누르면 그 방의 합류 확인(19)으로 간다 — 합류 흐름은 이미 있는 걸 그대로 쓴다.
    ///   - nearbyLoadFailed: 추천 **조회가 실패**했다 — 「주변에 방이 없다」와 구별해야 하는 상태다.
    ///     둘을 합치면 다음 행동이 정반대인 두 상황이 같게 보인다: 후보 0건이면 방을 만드는 게 맞지만,
    ///     조회 실패(OSRM 장애·배포 중 503)면 **300m 안에 방이 있어도** 섹션이 사라져 사용자가 모르고
    ///     새 방을 만든다. 합승 매칭이 조용히 꺼지는 자리라 작은 재시도 줄을 둔다 — 차단형 배너가
    ///     아닌 이유는 추천이 부가 기능이라는 기존 판단을 유지하기 때문이다.
    public init(
        destinationName: String,
        destinationAddress: String,
        originStopName: String,
        departureTimeLabel: String = "지금",
        arrivalTimeLabel: String = "도착 계산 중",
        destinationPosition: LatLng? = nil,
        originPosition: LatLng? = nil,
        routePreview: RoutePreviewUi = RoutePreviewUi(),
        creating: Bool = false,
        errorMessage: String? = nil,
        onDismiss: @escaping () -> Void = {},
        onAdjustPositions: @escaping (LatLng?, LatLng?) -> Void = { _, _ in },
        onFindCompanions: @escaping (MatchConditions) -> Void = { _ in },
        nearbyCandidates: [MatchCandidate] = [],
        onCandidateClick: @escaping (MatchCandidate) -> Void = { _ in },
        nearbyLoadFailed: Bool = false,
        onRetryNearby: @escaping () -> Void = {}
    ) {
        self.destinationName = destinationName
        self.destinationAddress = destinationAddress
        self.originStopName = originStopName
        self.departureTimeLabel = departureTimeLabel
        self.arrivalTimeLabel = arrivalTimeLabel
        self.destinationPosition = destinationPosition
        self.originPosition = originPosition
        self.routePreview = routePreview
        self.creating = creating
        self.errorMessage = errorMessage
        self.onDismiss = onDismiss
        self.onAdjustPositions = onAdjustPositions
        self.onFindCompanions = onFindCompanions
        self.nearbyCandidates = nearbyCandidates
        self.onCandidateClick = onCandidateClick
        self.nearbyLoadFailed = nearbyLoadFailed
        self.onRetryNearby = onRetryNearby
    }

    private struct FitKey: Equatable {
        let routePath: [LatLng]
        let origin: LatLng?
        let destination: LatLng?
        let widthDp: Float
        let heightDp: Float
    }

    public var body: some View {
        ZStack {
            // Scrim 배경 — 탭 시 닫기
            MoyeotaColor.Scrim
                .onTapGesture(perform: onDismiss)

            // 모달 카드 (풀스크린 라우트 겸용) — 내부 탭은 소비
            VStack(spacing: 0) {
                header

                // 지도(헤더 아래 전부) 위에 드래그 시트를 얹는다 — 시트 메커니즘은 21 과 공유한다
                MapSheetScaffold(
                    // 접힘 = 핸들 + 도착지 배지 + 요금 문구 + CTA (기본값과 같은 구성)
                    collapsedSheetHeight: 176,
                    background: { sheet in
                        mapBackground(sheet: sheet)
                    },
                    sheetTop: { sheetTop },
                    sheetDetail: { sheetDetail },
                    sheetFooter: { sheetFooter }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 핀 조정 — 같은 화면의 최상단 레이어로 덮는다(신규 목적지 아님)
            if let adjustTarget {
                PinAdjustOverlay(
                    originName: originStopName,
                    destinationName: destinationName,
                    originPosition: originPosition,
                    destinationPosition: destinationPosition,
                    initialTarget: adjustTarget,
                    onCancel: { self.adjustTarget = nil },
                    onConfirm: { adjustedOrigin, adjustedDestination in
                        self.adjustTarget = nil
                        onAdjustPositions(adjustedOrigin, adjustedDestination)
                    }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 원본 `adjustTarget` 은 `remember` 다. 위에 다른 화면이 쌓였다 돌아오면 핀 조정이 닫혀 있고 `peopleCount`(저장값)만 남는다.
        .onDisappear { adjustTarget = nil }
    }

    // 상단 헤더
    private var header: some View {
        VStack(spacing: 0) {
            // 16 은 안전 영역 안에 놓인다. 첫 레이아웃부터 0 이어야 아래 지도의 첫 카메라가 어긋나지 않는다.
            StatusBarSpacer(startsCollapsed: true)
            HStack(alignment: .center, spacing: 0) {
                Button(action: onDismiss) {
                    // 머티리얼 `IconButton` 의 레이아웃 크기는 최소 터치 영역인 48dp 다.
                    BackArrowIcon()
                        .frame(width: 48, height: 48)
                        .contentShape(Circle())
                }
                .buttonStyle(PressFeedbackStyle())
                Text("도착지 확인")
                    .moyeotaText(inlineType(18, .bold), color: MoyeotaColor.InkPrimary)
                Spacer(minLength: 0)
                ShieldIcon()
            }
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .padding(.leading, 12)
            .padding(.trailing, 16)
        }
        .frame(maxWidth: .infinity)
        .background(MoyeotaColor.SurfaceCanvas.onTapGesture {})
    }

    private func mapBackground(sheet: MapSheetState) -> some View {
        // 폴리라인 디코딩은 25 배차 화면과 같은 decodePolyline 을 쓴다
        let routePath = routeMemo.value(key: routePreview.encodedPath) {
            routePreview.encodedPath.map { decodePolyline(encoded: $0) } ?? []
        }
        let widthDp = Float(sheet.containerWidth)
        // fit 기준은 **시트에 가리지 않고 실제로 보이는 지도 높이**다.
        // 앵커가 바뀔 때만 값이 변하므로 드래그·정착 중 카메라가 매 프레임 튀지 않는다.
        let visibleMapHeightDp = Float(sheet.visibleMapHeight)
        let fitted = fitMemo.value(
            key: FitKey(
                routePath: routePath,
                origin: originPosition,
                destination: destinationPosition,
                widthDp: widthDp,
                heightDp: visibleMapHeightDp
            )
        ) {
            fitMapCamera(
                points: routePath + [originPosition, destinationPosition].compactMap { $0 },
                widthDp: widthDp,
                heightDp: visibleMapHeightDp
            )
        }
        // 「위치 조정」 버튼은 **실측** 시트 높이를 써서 시트 바로 위에 붙인다 —
        // 앵커 추정치를 쓰면 에러 배너가 떠 시트가 커졌을 때 버튼이 가린다.
        let sheetHeight = sheet.sheetHeight
        let canAdjust = destinationPosition != nil || originPosition != nil
        let label = routeSummaryLabel(routePreview: routePreview)
        let chipShape = RoundedRectangle(cornerRadius: 15, style: .circular)

        return ZStack(alignment: .topLeading) {
            if let destinationPosition {
                RouteMapView(
                    routePath: routePath, // previewRoute 의 encodedPath — 2점 미만이면 그려지지 않는다
                    originPosition: originPosition,
                    destinationPosition: destinationPosition,
                    center: fitted?.first ?? destinationPosition,
                    // 경로가 없을 땐 도착지 주변 블록이 식별될 정도로 당겨 본다
                    zoom: fitted?.second ?? 15.0,
                    // 가려지는 영역을 지도에 알려 카메라 중심이 보이는 영역 기준으로 잡히게 한다
                    contentPadding: EdgeInsets(top: 0, leading: 0, bottom: sheet.settledSheetHeight, trailing: 0)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MapPlaceholder()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // 지도를 덮는 투명 탭 레이어는 두지 않는다 — 그 레이어가 터치를 전부 먹어
            // SDK 줌 컨트롤(+/-)·핀치·팬이 통째로 죽어 있었다. 핀 조정 진입은
            // 아래 「위치 조정」 버튼 하나로 충분하다.

            // 경로 미리보기 실패 시엔 칩을 통째로 감춘다 — 틀린 값보다 없는 편이 낫다
            if let label {
                Text(label)
                    .moyeotaText(inlineType(13, .bold), color: MoyeotaColor.InkPrimary)
                    .padding(.horizontal, 16)
                    .frame(height: 30)
                    .background(MoyeotaColor.SurfaceCanvas, in: chipShape)
                    .moyeotaShadow(elevation: 3, shape: chipShape, spotColor: CardShadow)
                    .padding(16)
                    .allowsHitTesting(false)
            }

            // 지도 조정 진입점. 오른쪽 아래는 SDK 줌 컨트롤(+/-) 자리라 왼쪽에 둔다.
            if canAdjust {
                Button {
                    adjustTarget = .destination
                } label: {
                    Text("위치 조정")
                        .moyeotaText(inlineType(12, .bold), color: MoyeotaColor.Primary500)
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .background(MoyeotaColor.SurfaceCanvas, in: chipShape)
                        .contentShape(chipShape)
                }
                .buttonStyle(PressFeedbackStyle())
                .moyeotaShadow(elevation: 3, shape: chipShape, spotColor: CardShadow)
                .padding(.leading, 12)
                .padding(.bottom, sheetHeight + 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
    }

    // 도착지 배지 — 접힌 상태에서도 보이는 최소 정보
    private var sheetTop: some View {
        HStack(alignment: .center, spacing: 0) {
            StatusBadge(kind: .success, text: "도착지")
            Spacer().frame(width: 10)
            Text(destinationBadgeLabel(destinationName: destinationName, destinationAddress: destinationAddress))
                .moyeotaText(inlineType(13, .medium), color: GrayMute)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
    }

    // 상세 영역은 시트가 접히면 높이 0 이 된다 — 좌우 여백은 여기서 준다
    private var sheetDetail: some View {
        VStack(alignment: .leading, spacing: 0) {
            routeCard

            Spacer().frame(height: 20)

            Text("매칭 조건")
                .moyeotaText(inlineType(13, .medium), color: GrayMute)
            Spacer().frame(height: 10)

            conditionsCard

            // 「걸어서 가까운 방」 — 후보가 있을 때만 그린다. 없는 게 기본 상태라
            // (서버가 출발지·도착지 **각각** 300m 안에서만 고른다) 「없음」을 강조하면
            // 방을 만들러 온 사람에게 실패처럼 읽힌다.
            if !nearbyCandidates.isEmpty {
                Spacer().frame(height: 16)
                NearbyCandidateSection(
                    candidates: nearbyCandidates,
                    onCandidateClick: onCandidateClick
                )
            } else if nearbyLoadFailed {
                // 후보 0건과 달리 **못 물어봤다**는 뜻이라 사실을 말하고 길을 준다.
                Spacer().frame(height: 16)
                HStack(alignment: .center, spacing: 0) {
                    Text("가까운 방을 불러오지 못했어요")
                        .moyeotaText(inlineType(12, .medium), color: GrayAsh)
                    Spacer().frame(width: 8)
                    Button(action: onRetryNearby) {
                        Text("다시 시도")
                            .moyeotaText(inlineType(12, .bold), color: MoyeotaColor.Primary600)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressFeedbackStyle())
                }
            }

            Spacer().frame(height: 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
    }

    // 경로 카드
    private var routeCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            routeRow(
                dotColor: MoyeotaColor.Primary500,
                name: originStopName,
                timeLabel: departureTimeLabel,
                // 무엇을 조정하는지 애매하지 않도록 출발지·도착지 각각에 진입점을 둔다
                adjustTarget: originPosition != nil ? .origin : nil
            )
            ZStack {
                DashedVerticalLine()
            }
            .frame(width: 11, height: 30)
            // 출발지 → 도착지 연결선만 그린다. 도보 거리·시간은 서버가 주지 않아 표기하지 않는다.
            routeRow(
                dotColor: MoyeotaColor.MarkerDestination,
                name: destinationName,
                timeLabel: arrivalTimeLabel,
                adjustTarget: destinationPosition != nil ? .destination : nil
            )
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ChipBlueBg, in: RoundedRectangle(cornerRadius: 16, style: .circular))
    }

    private func routeRow(dotColor: Color, name: String, timeLabel: String, adjustTarget: PinTarget?) -> some View {
        HStack(alignment: .center, spacing: 0) {
            Circle()
                .fill(dotColor)
                .frame(width: 11, height: 11)
            Spacer().frame(width: 13)
            Text(name)
                .moyeotaText(inlineType(15, .bold), color: MoyeotaColor.InkPrimary)
                // 실주소가 들어오면 시각·「조정」과 같은 줄에 못 담긴다 — 줄바꿈 대신 말줄임
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            // 이름이 남는 폭을 전부 쓰므로 시각과 붙지 않게 최소 간격을 둔다
            Spacer().frame(width: 8)
            Text(timeLabel)
                .moyeotaText(inlineType(15, .bold), color: MoyeotaColor.InkPrimary)
                .fixedSize(horizontal: true, vertical: false)
            if let adjustTarget {
                AdjustLink(onClick: { self.adjustTarget = adjustTarget })
            }
        }
    }

    // 매칭 조건 카드
    private var conditionsCard: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .circular)
        return VStack(alignment: .leading, spacing: 0) {
            // 라벨에 「나 포함」을 박았다 — 서버 정원(`Capacity`)은 **방장을 포함한 총
            // 인원**이라(`Party.open` 이 생성자를 멤버로 넣고 `members.size == capacity`
            // 면 꽉 찬 것으로 본다) 「3인」만 쓰면 「나 외 3명」으로 읽힌다. 「나 포함 N명」을
            // 칩마다 쓰지 않고 라벨로 올린 건 레이아웃 때문이다 — 칩 3개가 좁은 폰(360dp)에서
            // 카드 밖으로 밀려 잘린 전례가 있다(`ConditionRow` 주석).
            ConditionRow(label: "인원(나 포함)") {
                ForEach([1, 2, 3], id: \.self) { count in
                    ConditionChip(
                        text: "\(count)명",
                        selected: peopleCount == count,
                        onClick: { peopleCount = count }
                    )
                }
            }
            // 「1명」을 고른 사람에게만 **고르는 자리에서** 결과를 말해 준다
            // (`soloCapacityNotice`). 1 은 지우지 않았다 — 혼자 타기를 상품으로
            // 인정한 결정이다. 다만 그 선택의 결과(정원 1 = 만든 즉시 꽉 찬 방 =
            // 아무도 합류 못 함)는 서버 규약을 아는 사람만 읽어 낼 수 있어서,
            // 안내가 없으면 「1명」은 그냥 「나 외 1명」처럼 보인다.
            //
            // 자리를 늘 비워 두지 **않고** 1명일 때만 줄을 넣은 근거:
            // 이 카드는 `MapSheetScaffold` 의 sheetDetail 안에 있고 그 영역은
            // **앵커가 정한 고정 높이 + 세로 스크롤**이다(콘텐츠가 높이를 정하지
            // 않는다). 그래서 이 줄이 생겨도 시트 높이·지도 노출·CTA 위치는 **한
            // 픽셀도 움직이지 않고**, 아래의 「걸어서 가까운 방」 섹션만 그만큼
            // 밀린다 — 손가락이 닿아 있는 칩 행은 안내보다 **위**라 제자리다.
            // 상시 빈 자리를 두면 2·3명(기본값 3)에서 늘 비어 있는 ~30pt 가
            // 좁은 폰의 스크롤 영역에서 추천 카드 한 줄만큼을 먹는다.
            //
            // 색·크기는 이 파일의 보조 문구 관습(13pt Medium + `GrayMute`)이다.
            // 빨강·경고 아이콘을 쓰지 않는다 — 정상 선택이고, 오류로 읽히면
            // 사용자는 고를 수 있는 값을 「막힌 값」으로 본다.
            // 줄바꿈을 막지 않는다 — 잘린 안내보다 두 줄이 낫고, 스크롤 영역 안이라 잘릴 일도 없다.
            if let notice = soloCapacityNotice(capacity: peopleCount) {
                Text(notice)
                    .moyeotaText(inlineType(13, .medium), color: GrayMute)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 11)
            }
            // 「출발지 반경」·「도착지 반경」 행은 지웠다(2026-10-14) — 서버가 방 생성
            // 요청에서 반경을 빼고 고정값(500m)을 쓴다(Backend `a668aee`). 고른 값이
            // 전송조차 되지 않고, 전송됐을 때도 매칭이 읽지 않던 값이다(`MatchConditions`).
            //
            // 「매칭 방식 · 주요 승차지점」 행은 지웠다(2026-10-13) — 그런 매칭 방식이
            // 없다. 서버에 승차지점 개념이 없고(방은 사용자가 찍은 좌표 그대로 만들어진다)
            // 칩도 항상 선택된 채 무동작이었다. 고를 것도, 가리킬 기능도 없는 줄이었다.
            //
            // 남은 행이 「인원」 하나라 구분선도 없다 — 카드는 그대로 둔다. 실제 매칭
            // 조건이 하나뿐이라는 사실을 그대로 보여 주는 모양이다.
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MoyeotaColor.SurfaceCanvas, in: shape)
        .moyeotaShadow(elevation: 4, shape: shape, spotColor: CardShadow)
    }

    // 요금 안내 + CTA — 접힘·펼침 모두에서 보이도록 시트 하단에 고정한다.
    // 추정 실패 시에도 CTA 는 막지 않는다 — 방 생성 요청을 받으면 서버가 요금을 다시 계산한다.
    private var sheetFooter: some View {
        VStack(spacing: 0) {
            Text(fareFooterText(routePreview: routePreview, peopleCount: peopleCount))
                .moyeotaText(inlineType(12, .medium), color: GrayAsh)
                // 접힘 높이가 문구 길이에 따라 흔들리지 않게 한 줄로 고정한다
                .lineLimit(1)
                .padding(.horizontal, 16)
            if let errorMessage {
                Spacer().frame(height: 10)
                NoticeBanner(kind: .error, text: errorMessage)
                    .padding(.horizontal, 16)
            }
            Spacer().frame(height: 12)
            PrimaryCtaButton(
                text: "같이 탈 사람 찾기",
                onClick: { onFindCompanions(MatchConditions(capacity: peopleCount)) },
                loading: creating
            )
            .padding(.horizontal, 16)
            Spacer().frame(height: 20)
            NavigationBarSpacer()
        }
        .frame(maxWidth: .infinity)
    }
}

/// `remember(key) { … }` 의 자리 — 키가 같으면 다시 계산하지 않는다.
@MainActor
final class Remembered<Key: Equatable, Value> {
    private var entry: (key: Key, value: Value)?

    func value(key: Key, compute: () -> Value) -> Value {
        if let entry, entry.key == key { return entry.value }
        let value = compute()
        entry = (key, value)
        return value
    }
}

// 경로 카드 행에 붙는 좌표 조정 진입점
private struct AdjustLink: View {
    let onClick: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .circular)
        Button(action: onClick) {
            Text("조정")
                .moyeotaText(inlineType(12, .bold), color: MoyeotaColor.Primary500)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(shape)
        }
        .buttonStyle(PressFeedbackStyle())
        .fixedSize(horizontal: true, vertical: false)
        .padding(.leading, 8)
    }
}

/// 「걸어서 가까운 방」 추천 목록. **후보가 있을 때만** 불린다(빈 목록은 호출부가 거른다).
///
/// 기존 17 탐색 카드보다 **정보가 적다** — 서버 응답에 인원·요금이 없어서다. 그래서 숫자를
/// 지어내 채우지 않고, 가진 것(출발·도착·도보 시간·정원)만 보여 준다. 인원 현황은 탭해서 들어간
/// 합류 확인(19)이 방 상세를 읽어 채운다.
private struct NearbyCandidateSection: View {
    let candidates: [MatchCandidate]
    let onCandidateClick: (MatchCandidate) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("걸어서 가까운 방")
                .moyeotaText(inlineType(14, .bold), color: MoyeotaColor.InkPrimary)
            Spacer().frame(height: 4)
            // 「N분 소요」라고 쓰면 목적지까지 N분으로 읽힌다 — 걷는 시간이라는 걸 못 박는다.
            Text("타러 가고, 내려서 걷는 시간을 더한 값이에요")
                .moyeotaText(inlineType(12, .regular), color: GrayAsh)
            Spacer().frame(height: 10)
            ForEach(Array(candidates.enumerated()), id: \.offset) { _, candidate in
                NearbyCandidateCard(candidate: candidate, onClick: { onCandidateClick(candidate) })
                Spacer().frame(height: 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct NearbyCandidateCard: View {
    let candidate: MatchCandidate
    let onClick: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .circular)
        let headcount = headcountLabel(joined: candidate.ride.members.count, capacity: candidate.ride.capacity)
        Button(action: onClick) {
            HStack(alignment: .center, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(candidate.ride.origin) → \(candidate.ride.destination)" as String)
                        .moyeotaText(inlineType(14, .bold), color: MoyeotaColor.InkPrimary)
                        .lineLimit(1)
                    Spacer().frame(height: 4)
                    if !headcount.isEmpty {
                        Text(headcount)
                            .moyeotaText(inlineType(12, .regular), color: GrayAsh)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer().frame(width: 12)
                Text(walkMinutesLabel(walkSeconds: candidate.walkSeconds))
                    .moyeotaText(inlineType(13, .bold), color: MoyeotaColor.Primary500)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(MoyeotaColor.SurfaceCanvas, in: shape)
            .contentShape(shape)
        }
        .buttonStyle(PressFeedbackStyle())
        .moyeotaShadow(elevation: 4, shape: shape, spotColor: CardShadow)
    }
}

/// 예상 총 요금 ÷ 인원 = 1인 요금(원), **10원 단위 반올림**.
///
/// **이 규칙은 data 쪽 `farePerPerson` 과 한 글자도 다르면 안 된다.** 16 모달은 방을 만들기 **전**의
/// 추정치(`POST /matching/routes`)를 인원으로 나누고, 19 합류·22 상세·25 배차는 서버가 방에 박아 둔
/// 요금을 정원으로 나눈 값(`Ride.farePerPerson`)을 쓴다 — 나누는 수가 같은 값(정원)이므로 **반올림
/// 규칙만 어긋나도 같은 방이 화면마다 다른 금액**을 보여 준다(실제로 7,900원·3인 방이 16 에서
/// 2,630원, 25 에서 2,633원이었다). 모듈 경계(presentation ↔ data) 때문에 함수를 공유할 수 없어
/// 규칙을 양쪽에 적고, 「두 값이 같다」는 `FarePerPersonRuleTest`(여기)와 `PartyMappersTest`(data)가
/// **같은 표**로 못 박는다.
///
/// 10원 단위인 근거는 택시 요금 표기 관례다 — 1원 단위 금액은 실제로 낼 수 없다.
/// `people` 이 0 이하면 0 을 돌려준다(data 쪽의 `capacity <= 0` 가드와 같은 자리). 화면에서는 칩이
/// 1~3 뿐이라 닿지 않는 길이지만, 두 규칙을 같은 모양으로 유지해 비교 테스트가 성립하게 둔다.
func farePerPersonWon(totalFare: Int, people: Int) -> Int {
    if people <= 0 { return 0 }
    return roundToInt((Double(totalFare) / Double(people)) / 10.0) &* 10
}

/// Kotlin `Double.roundToInt()` — 정확히 .5 는 양의 무한대 쪽으로 올린다. Swift `rounded()` 는 음수에서 0 의
/// 반대쪽으로 가서 어긋난다.
private func roundToInt(_ value: Double) -> Int {
    let floor = value.rounded(.down)
    return Int(value - floor >= 0.5 ? floor + 1 : floor)
}

/// 「인원(나 포함)」에서 **1명**을 고른 상태의 안내 문구. 1 이 아니면 nil — 줄을 그리지 않는다.
///
/// 왜 필요한가: 서버 `Capacity` 는 **방장을 포함한 총 인원**이고 `Party.open` 이 생성자를 멤버로
/// 넣는다(`MatchConditions`). 그래서 1 로 방을 만들면 `members.size == capacity` 가 **만든 즉시**
/// 참이 되어 아무도 합류할 수 없고, 사용자는 「같이 탈 사람 찾기」를 눌렀는데 혼자 출발한다.
/// 선택지에서 1 을 지우지 않기로 한 결정(혼자 타기를 상품으로 인정)이 성립하려면, 그 결과를
/// **고르는 자리에서** 말해 주는 것이 조건이다.
///
/// 문구 규칙:
/// - 「1/1 로 꽉 찬 방」·「정원」 같은 내부 용어를 쓰지 않는다. 사용자가 겪는 일은 두 가지뿐이다 —
///   **동승자를 받지 않고, 혼자 출발한다.** 둘 다 적는다(하나만 적으면 나머지를 추측하게 된다).
/// - 「같이 탈 사람」은 이 화면 CTA 와 **같은 말**이다. 「동승자」·「합승 인원」으로 바꾸지 말 것 —
///   CTA 가 「같이 탈 사람 찾기」인데 안내가 다른 단어를 쓰면 같은 대상인지 한 번 더 생각해야 한다.
/// - 요금과 모순되지 않는다: 1명이면 `farePerPersonWon` 이 총액을 1 로 나눠 **1인 요금 = 총 요금**이
///   되고(「예상 N분 · 총 7,900원」 칩과 「예상 요금 1인 7,900원」이 같은 수가 된다) 그건 혼자
///   출발하는 방의 **사실**이다. 그래서 요금 문구는 손대지 않았다 — 여기서 「요금을 전부 부담한다」를
///   한 번 더 말하면 같은 사실을 두 자리에서 말하게 되고, 한 줄 안내가 두 줄로 늘어난다.
func soloCapacityNotice(capacity: Int) -> String? {
    capacity == 1 ? "같이 탈 사람을 받지 않고 혼자 출발해요" : nil
}

/// 도보 시간(초) → 표시 문구. **「걸어서」를 반드시 붙인다** — 서버가 주는 값은 탑승지까지 걷는
/// 시간과 내려서 걷는 시간의 **합**이고 차 타는 시간은 안 들어 있다. 「7분」만 쓰면 목적지까지
/// 7분으로 읽힌다.
///
/// 1분 미만도 「걸어서 1분」으로 올린다 — 「0분」은 걸을 필요가 없다는 뜻으로 읽히는데 그런 경우가
/// 아니고(좌표가 다르니 거리는 있다), 반올림해 0 이 되는 값일 뿐이다.
func walkMinutesLabel(walkSeconds: Int) -> String {
    let minutes = max((walkSeconds + 59) / 60, 1)
    return "걸어서 \(minutes)분"
}

private struct ConditionRow<Chips: View>: View {
    let label: String
    @ViewBuilder let chips: () -> Chips

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            Text(label)
                .moyeotaText(inlineType(14, .bold), color: MoyeotaColor.InkPrimary)
                .fixedSize(horizontal: true, vertical: false)
            Spacer().frame(width: 12)
            // 칩 행이 **남는 폭 안에서** 오른쪽 정렬된다. 예전엔 라벨 뒤 Spacer(weight) + 고정폭 칩이라
            // 작은 폰(360dp)에서 칩 3개가 카드 밖으로 밀려 「500m」이 잘리고 선택 칩의 파란 배경이 카드
            // 모서리를 넘어 보였다(실기 QA). 칩 자체도 좁아졌다(ConditionChip 패딩 20 → 14dp).
            HStack(alignment: .center, spacing: 6) {
                chips()
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 11)
    }
}

// 와이어프레임 스타일 칩 — 선택 시 Primary 솔리드, 미선택 시 흰색 + 그림자
// (핀 조정 화면의 출발지/도착지 토글도 같은 칩을 쓴다 — 모듈 내부라 internal)
struct ConditionChip: View {
    let text: String
    let selected: Bool
    let onClick: () -> Void
    /// 넓은 패딩 — 핀 조정 화면(16a)의 출발지/도착지 토글이 쓴다
    var wide = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .circular)
        let bg = selected ? MoyeotaColor.Primary500 : MoyeotaColor.SurfaceCanvas
        let fg = selected ? MoyeotaColor.TextOnDark : GraySlate
        Button(action: onClick) {
            Text(text)
                .moyeotaText(inlineType(13, .bold), color: fg)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, wide ? 28 : 14)
                .frame(height: 32)
                .background(bg, in: shape)
                .contentShape(shape)
        }
        .buttonStyle(PressFeedbackStyle())
        .background {
            if !selected {
                Color.clear.moyeotaShadow(elevation: 3, shape: shape, spotColor: CardShadow)
            }
        }
    }
}

private struct DashedVerticalLine: View {
    var color = Color(argb: 0xFFB9C6DE)

    var body: some View {
        Canvas { context, size in
            var line = Path()
            line.move(to: CGPoint(x: size.width / 2, y: 0))
            line.addLine(to: CGPoint(x: size.width / 2, y: size.height))
            context.stroke(
                line,
                with: .color(color),
                style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [4, 4])
            )
        }
        .frame(width: 3, height: 30)
    }
}

private struct ShieldIcon: View {
    var color = GrayDeep

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let strokeWidth: CGFloat = 1.6
            var path = Path()
            path.move(to: CGPoint(x: w * 0.5, y: h * 0.08))
            path.addLine(to: CGPoint(x: w * 0.85, y: h * 0.22))
            path.addQuadCurve(to: CGPoint(x: w * 0.5, y: h * 0.92), control: CGPoint(x: w * 0.85, y: h * 0.62))
            path.addQuadCurve(to: CGPoint(x: w * 0.15, y: h * 0.22), control: CGPoint(x: w * 0.15, y: h * 0.62))
            path.closeSubpath()
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: strokeWidth, lineJoin: .round))

            var check = Path()
            check.move(to: CGPoint(x: w * 0.35, y: h * 0.48))
            check.addLine(to: CGPoint(x: w * 0.46, y: h * 0.6))
            var check2 = Path()
            check2.move(to: CGPoint(x: w * 0.46, y: h * 0.6))
            check2.addLine(to: CGPoint(x: w * 0.66, y: h * 0.36))
            let lineStyle = StrokeStyle(lineWidth: strokeWidth, lineCap: .round)
            context.stroke(check, with: .color(color), style: lineStyle)
            context.stroke(check2, with: .color(color), style: lineStyle)
        }
        .frame(width: 22, height: 22)
    }
}
