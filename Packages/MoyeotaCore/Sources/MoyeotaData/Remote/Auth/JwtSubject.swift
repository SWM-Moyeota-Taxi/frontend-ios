import Foundation
import MoyeotaDomain

/// 액세스 토큰 페이로드에서 우리가 읽는 유일한 클레임.
/// 나머지(tokenType/iat/exp/jti)는 서버만 쓰므로 디코더가 흘려보낸다.
private struct JwtPayload: Decodable {
    let sub: String

    private enum CodingKeys: String, CodingKey {
        case sub
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sub = try c.decodeOrDefault(.sub, default: "")
    }
}

/// JWT 의 `sub` 클레임을 꺼낸다. 백엔드에서 `sub` = 사용자 publicId UUID 다
/// (`JwtProvider.build`: `.subject(publicId.toString())`, 실측으로 가입 응답 `uuid` 와 일치 확인).
///
/// **왜 토큰을 파싱하는가.** 인증 개편으로 로그인 응답이 `{accessToken, refreshToken}` 만 주게 되면서
/// 서버가 사용자 UUID 를 알려주는 다른 경로가 없어졌다. 가입 응답의 `uuid` 는 "방금 가입한" 흐름에서만
/// 얻을 수 있고, 앱을 재설치 없이 다시 켰을 때·기존 계정으로 로그인했을 때는 존재하지 않는다.
/// 반면 `sub` 는 로그인·재발급 어느 쪽 토큰에도 항상 들어 있어 **모든 진입 경로에서 같은 값**을 준다.
///
/// **서명은 검증하지 않는다.** 이 값은 화면 표시·자기 식별에만 쓰이고 권한 판정에는 절대 쓰이지 않는다
/// — 권한은 서버가 서명을 검증한 뒤 정한다. 앱이 서명 키를 가질 수도 없으므로 검증할 방법 자체가 없다.
/// 토큰을 위조해 얻는 것은 "내 화면에 남의 UUID 가 보인다"뿐이라 공격 가치가 없다.
///
/// - Returns: `sub` 값, 또는 토큰 형식이 JWT 가 아니거나 `sub` 가 비어 있으면 null
func jwtSubject(token: String) -> String? {
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3 else { return nil }

    guard let payload = decodeBase64(parts[1]) else { return nil }

    guard let sub = (try? MoyeotaJSON.decoder.decode(JwtPayload.self, from: payload))?.sub,
          !sub.isBlank
    else { return nil }
    return sub
}

/// okio `decodeBase64` 와 같은 규칙. 표준/URL-safe 알파벳을 모두 받고 패딩이 없어도 동작한다.
///
/// `Data(base64Encoded:)` 는 표준 알파벳만 받고 패딩을 요구한다. 서버 페이로드는 base64**url** 이고
/// 패딩도 없어서 `-`·`_` 가 섞이는 순간 깨진다.
private func decodeBase64(_ text: Substring) -> Data? {
    let whitespace: Set<UInt8> = [0x0A, 0x0D, 0x20, 0x09]
    var input = Array(text.utf8)
    while let last = input.last, last == 0x3D || whitespace.contains(last) {
        input.removeLast()
    }

    var output = Data()
    var word: UInt32 = 0
    var count = 0
    for c in input {
        let bits: UInt32
        switch c {
        case 0x41...0x5A: bits = UInt32(c - 0x41)
        case 0x61...0x7A: bits = UInt32(c - 0x61) + 26
        case 0x30...0x39: bits = UInt32(c - 0x30) + 52
        case 0x2B, 0x2D: bits = 62
        case 0x2F, 0x5F: bits = 63
        default:
            if whitespace.contains(c) { continue }
            return nil
        }
        word = (word << 6) | bits
        count += 1
        if count % 4 == 0 {
            output.append(UInt8(truncatingIfNeeded: word >> 16))
            output.append(UInt8(truncatingIfNeeded: word >> 8))
            output.append(UInt8(truncatingIfNeeded: word))
        }
    }
    switch count % 4 {
    case 1:
        // 문자 하나(6비트)로는 한 바이트를 만들 수 없다.
        return nil
    case 2:
        output.append(UInt8(truncatingIfNeeded: (word << 12) >> 16))
    case 3:
        let shifted = word << 6
        output.append(UInt8(truncatingIfNeeded: shifted >> 16))
        output.append(UInt8(truncatingIfNeeded: shifted >> 8))
    default:
        break
    }
    return output
}
