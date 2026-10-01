import Foundation
import Security

/// 앱 전역 설정. 서버 주소 등은 설정(개발자) 화면에서 UserDefaults 로 바꾼다.
final class AppConfig {
    static let shared = AppConfig()

    var baseURL: URL {
        let s = UserDefaults.standard.string(forKey: "baseURL")?.trimmingCharacters(in: .whitespaces) ?? ""
        return URL(string: s).flatMap { $0.scheme == nil ? nil : $0 } ?? URL(string: "http://localhost:8080/api")!
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

    // 촬영 (방)
    let minTranslationM: Float = 0.15       // 이전 저장 프레임 대비 최소 이동
    let minRotationDeg: Float = 10          // 최소 회전
    let minIntervalSec: Double = 0.3        // 최소 저장 간격
    let jpegQuality: CGFloat = 0.9
    let roomMinSpanM: Float = 2.0           // 가이드: 방 안에서 카메라가 움직인 범위(바닥 기준 상자의 대각선) 권장값
    let roomGoodFrames = 150                // 가이드: 이만큼 찍으면 '충분히 촬영했습니다'
    // 촬영 중 경고(흔들림 · 제자리 · 어두움 · 무늬 없음 · 너무 가까움)의 기준값은 CaptureCoach.Config 에 있다
    let sampleHz: Double = 10               // currentFrame 폴링 주기
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
