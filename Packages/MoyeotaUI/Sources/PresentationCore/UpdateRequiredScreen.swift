import MoyeotaDesignSystem
import SwiftUI

/// 서버가 「이 버전은 더 못 쓴다」고 답했을 때의 화면(`UpdateRequirement.blocked`).
///
/// ### 왜 오버레이가 아니라 화면 전체를 대신하나
/// 이 화면은 **내비게이션 스택 자체를 세우지 않는 자리**에 선다(`MainNavHost` 의 이른 분기).
/// 오버레이 + 뒤로가기 차단으로 막으면 그리는 순서와 핸들러 등록 순서에 기대게 되는데,
/// 스택이 아예 없으면 **뒤로가기로 갈 수 있는 앱 화면이 존재하지 않는다.** 앱을 껐다 다시 켜면
/// 설정을 또 받아 같은 판정이 난다.
///
/// ### 「나중에」가 없는 이유
/// 막는 이유는 서버 계약이 이미 바뀌어 이 버전이 **정상 동작하지 않기** 때문이다. 넘어갈 길을
/// 주면 고장난 화면을 보여 주게 되고, 그건 잠긴 화면보다 나쁘다. 안내만 할 상황이면 서버가
/// `minVersionCode` 가 아니라 `recommendedVersionCode` 를 쓴다.
public struct UpdateRequiredScreen: View {
    public init() {}

    public var body: some View {
        ZStack {
            MoyeotaColor.SurfaceSoft
            VStack(spacing: 12) {
                // 원본은 style 없는 Text 라 테마의 bodyLarge(자간 0.5sp, 줄 상자는 24 또는 한글 대체 글꼴 높이)를 물려받는다.
                Text("업데이트가 필요해요")
                    .moyeotaText(inheritedBodyLargeType(22, .bold), color: MoyeotaColor.InkPrimary)
                Text("지금 버전으로는 합승을 이어갈 수 없어요\n스토어에서 최신 버전을 받아 주세요")
                    .moyeotaText(inheritedBodyLargeType(15, .regular), color: MoyeotaColor.TextBody)
                    .multilineTextAlignment(.center)
                PrimaryCtaButton(text: "업데이트하러 가기", onClick: { openPlayStoreListing() })
                    .padding(.top, 12)
            }
            .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
