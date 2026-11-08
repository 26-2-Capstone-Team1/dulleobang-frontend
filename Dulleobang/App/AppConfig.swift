import Foundation
import Security

/// 앱 전역 설정. 서버 주소 등은 설정(개발자) 화면에서 UserDefaults 로 바꾼다.
final class AppConfig {
    static let shared = AppConfig()

    /// 기본 백엔드 = 팀 GCP 서버(dulleobang-backend VM, 서울 · 포트 8080). 설정 화면에서 다른 주소를 넣으면 그쪽이 우선.
    /// 아직 HTTP 만 있어서 Info.plist 에 ATS 예외(NSAllowsArbitraryLoads)가 켜져 있다.
    /// HTTPS 도메인이 생기면 여기만 https://api.<도메인>/api 로 바꾸고 ATS 예외를 지운다.
    static let defaultBaseURL = "http://34.47.87.3:8080/api"

    var baseURL: URL {
        let s = UserDefaults.standard.string(forKey: "baseURL")?.trimmingCharacters(in: .whitespaces) ?? ""
        return URL(string: s).flatMap { $0.scheme == nil ? nil : $0 } ?? URL(string: Self.defaultBaseURL)!
    }
    /// 로그인한 사용자 (X-User-Id 헤더). 로그아웃 상태면 nil
    var userId: String? { UserDefaults.standard.string(forKey: "userId").flatMap { $0.isEmpty ? nil : $0 } }
    /// 로그인 토큰 (키체인). access 는 Authorization: Bearer 로 보내고, 만료(401)되면 refresh 로 새로 받는다
    var accessToken: String? {
        KeychainStore.get(KeychainStore.accessToken)
            ?? UserDefaults.standard.string(forKey: "accessToken").flatMap { $0.isEmpty ? nil : $0 }   // 예전 버전 호환
    }
    var refreshToken: String? { KeychainStore.get(KeychainStore.refreshToken) }

    /// 데모 모드: 서버 대신 앱 안의 예시 데이터(MockBackend)로 동작한다. 설정 › 데모 모드에서 끄면 위 서버에 연결.
    static let useMockDataKey = "useMockData"
    static let useMockDataDefault = true
    var useMockData: Bool { UserDefaults.standard.object(forKey: Self.useMockDataKey) as? Bool ?? Self.useMockDataDefault }

    // 촬영 (방) — 3DGS 는 사진이 많을수록 좋아서(AI 팀 실험: 사진을 절반으로 줄이면 −0.8 dB) 초당 약 5장씩 저장한다
    let minTranslationM: Float = 0.02       // 직전 저장 프레임 대비 최소 이동 (가구 촬영은 절반). 가만히 서 있을 때 같은 사진이 쌓이지 않게만 막는다
    let minRotationDeg: Float = 2           // 최소 회전
    let minIntervalSec: Double = 0.18       // 최소 저장 간격 ≈ 초당 5장 (10 Hz 폴링 두 번에 한 번. ARKit 시각은 1/60초 단위라 두 번 사이가 0.183초일 수 있다)
    let jpegQuality: CGFloat = 0.85         // 장 수가 늘어난 만큼 용량을 줄인다 (AI 팀 권장 0.85~0.9)
    let roomMinSpanM: Float = 2.0           // 가이드: 방 안에서 카메라가 움직인 범위(바닥 기준 상자의 대각선) 권장값
    let roomGoodFrames = 500                // 가이드: 이만큼 찍으면 '충분히 촬영했습니다' (초당 5장이면 약 100초)
    // 촬영 중 경고(흔들림 · 제자리 · 어두움 · 무늬 없음 · 너무 가까움)의 기준값은 CaptureCoach.Config 에 있다
    let sampleHz: Double = 10               // currentFrame 폴링 주기
    var lockFocus: Bool { UserDefaults.standard.object(forKey: "lockFocus") as? Bool ?? true }   // 촬영 중 초점 고정 (설정(개발자)에서 끌 수 있음)
    let focusLockAfterS: Double = 2.0       // 첫 프레임에서 이만큼 뒤(자동 초점이 방에 맞춰진 뒤) 초점을 잠근다
    var autoTorch: Bool { UserDefaults.standard.object(forKey: "autoTorch") as? Bool ?? true }   // 어두우면 손전등 자동으로 켜기 (설정(개발자)에서 끌 수 있음)
    var useRoomPlan: Bool { UserDefaults.standard.object(forKey: "useRoomPlan") as? Bool ?? true }

    // 뷰어 / 배치
    let eyeHeightM: Double = 1.5
    let snapPositionM: Double = 0.05
    let snapYawDeg: Double = 5
    let maxPoints = 2_000_000

    // 매물 사진
    let maxListingPhotos = 30
    let photoMaxPixel: CGFloat = 2048

    /// 3D 뷰어 라이브러리 출처. vendor/ 에 로컬 복사본이 있으면 index.html 이 그것을 우선 사용한다.
    let viewerCDN = "https://cdn.jsdelivr.net/npm"

    /// 앱 이름(로고 글자). StayView 로 바꾸려면 여기만 고치면 된다.
    let brandName = "둘러방"
    /// 마이페이지 › 문의하기 메일 주소 (팀 메일로 교체)
    let supportEmail = "support@example.com"

    var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0") + " alpha"
    }
}

/// 로그인 토큰 보관 (UserDefaults 대신 키체인, 이 기기에서만)
enum KeychainStore {
    static let accessToken = "accessToken"
    static let refreshToken = "refreshToken"
    private static let service = "com.dulleobang.auth"

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: key, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// nil 이면 지운다
    static func set(_ key: String, _ value: String?) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}
