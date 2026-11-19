import Combine
import CoreLocation
import SwiftUI
#if canImport(GoogleSignIn)
import GoogleSignIn
#endif
#if canImport(KakaoSDKUser)
import KakaoSDKAuth
import KakaoSDKCommon
import KakaoSDKUser
#endif

enum LoginProvider: String, Identifiable {
    case kakao, google
    var id: String { rawValue }
    var title: String { self == .kakao ? "카카오" : "Google" }
}

/// 카카오 · 구글 SDK 로그인 → 서버에 넘길 토큰 (카카오 accessToken, 구글 idToken) → AuthAPI.oauth.
/// 키는 Info.plist (project.yml 의 info): GIDClientID, GIDServerClientID(구글 웹 클라이언트 → ID 토큰의 aud), KakaoNativeAppKey.
/// 데모 모드는 SDK 없이 가입 시트로 대신한다 (LoginView.startSocial). 패키지가 없는 빌드에서는 '앱 키를 설정한 뒤' 안내로 막힌다.
enum SocialLogin {
    struct NotConfigured: LocalizedError {
        let provider: LoginProvider
        var errorDescription: String? {
            "\(provider.title) 로그인은 앱 키를 설정한 뒤 쓸 수 있어요. 지금은 이메일로 로그인해 주세요."
        }
    }

    /// 서버가 http 면 SDK 토큰(구글 ID 토큰 · 카카오 액세스 토큰)이 암호화 없이 오간다.
    /// 백엔드 요청(11.19)대로 HTTPS 전환 뒤에만 보낸다. 같은 Wi-Fi 의 개발 서버(사설 IP · .local · localhost)는 막지 않는다
    struct NeedsHTTPS: LocalizedError {
        let provider: LoginProvider
        var errorDescription: String? {
            "\(provider.title) 로그인은 서버가 HTTPS로 바뀐 뒤 쓸 수 있어요. 지금은 이메일로 로그인해 주세요."
        }
    }

    struct Failed: LocalizedError {
        let errorDescription: String?
    }

    private static func info(_ key: String) -> String? {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// 앱을 켤 때 한 번 (카카오 SDK 초기화)
    static func configure() {
        #if canImport(KakaoSDKUser)
        if let key = info("KakaoNativeAppKey") { KakaoSDK.initSDK(appKey: key) }
        #endif
    }

    /// 카카오톡 · 구글 로그인을 마치고 앱으로 돌아온 URL (DulleobangApp 의 onOpenURL)
    @MainActor
    static func handle(_ url: URL) {
        #if canImport(KakaoSDKUser)
        if info("KakaoNativeAppKey") != nil, AuthApi.isKakaoTalkLoginUrl(url) {
            _ = AuthController.handleOpenUrl(url: url)
            return
        }
        #endif
        #if canImport(GoogleSignIn)
        _ = GIDSignIn.sharedInstance.handle(url)
        #endif
    }

    @MainActor
    static func token(for provider: LoginProvider) async throws -> String {
        guard isSecure(AppConfig.shared.baseURL) else { throw NeedsHTTPS(provider: provider) }
        switch provider {
        case .google: return try await googleIdToken()
        case .kakao: return try await kakaoAccessToken()
        }
    }

    /// https 이거나, 같은 Wi-Fi 의 개발 서버
    static func isSecure(_ url: URL) -> Bool {
        if url.scheme?.lowercased() == "https" { return true }
        guard let host = url.host?.lowercased() else { return false }
        if host == "localhost" || host == "127.0.0.1" || host.hasSuffix(".local") { return true }
        let p = host.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4 else { return false }
        return p[0] == 10 || (p[0] == 192 && p[1] == 168) || (p[0] == 172 && (16...31).contains(p[1]))
    }

    /// 로그아웃할 때 SDK 쪽 로그인도 끊는다 (다음에 다른 계정을 고를 수 있게)
    @MainActor
    static func signOut() {
        #if canImport(GoogleSignIn)
        GIDSignIn.sharedInstance.signOut()
        #endif
        #if canImport(KakaoSDKUser)
        if info("KakaoNativeAppKey") != nil, AuthApi.hasToken() {
            UserApi.shared.logout { _ in }
        }
        #endif
    }

    // MARK: 구글: GIDSignIn → ID 토큰 (aud = GIDServerClientID)

    @MainActor
    private static func googleIdToken() async throws -> String {
        #if canImport(GoogleSignIn)
        guard let clientID = info("GIDClientID") else { throw NotConfigured(provider: .google) }
        guard let presenter = topViewController() else {
            throw Failed(errorDescription: "구글 로그인 화면을 열지 못했어요. 다시 시도해 주세요.")
        }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID, serverClientID: info("GIDServerClientID"))
        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
            guard let token = result.user.idToken?.tokenString else {
                throw Failed(errorDescription: "구글에서 로그인 토큰을 받지 못했어요. 다시 시도해 주세요.")
            }
            return token
        } catch let e as GIDSignInError where e.code == .canceled {
            throw CancellationError()                    // 사용자가 닫음 → 오류 안내 없이 그대로
        }
        #else
        throw NotConfigured(provider: .google)
        #endif
    }

    // MARK: 카카오: 카카오톡이 있으면 카카오톡, 없으면 카카오계정 웹 로그인 → 액세스 토큰

    @MainActor
    private static func kakaoAccessToken() async throws -> String {
        #if canImport(KakaoSDKUser)
        guard info("KakaoNativeAppKey") != nil else { throw NotConfigured(provider: .kakao) }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let done: (OAuthToken?, Error?) -> Void = { token, error in
                if let token {
                    cont.resume(returning: token.accessToken)
                } else if let e = error as? SdkError, case .ClientFailed(reason: .Cancelled, errorMessage: _) = e {
                    cont.resume(throwing: CancellationError())   // 사용자가 닫음
                } else {
                    cont.resume(throwing: error ?? Failed(errorDescription: "카카오 로그인에 실패했어요. 다시 시도해 주세요."))
                }
            }
            // 카카오톡이 깔려 있는지 (Info.plist LSApplicationQueriesSchemes 의 kakaokompassauth).
            // SDK 의 UserApi.isKakaoTalkLoginAvailable() 은 2.30 에서 deprecated 라 같은 확인을 직접 한다
            let talkInstalled = URL(string: "kakaokompassauth://authorize").map { UIApplication.shared.canOpenURL($0) } ?? false
            if talkInstalled {
                UserApi.shared.loginWithKakaoTalk(completion: done)
            } else {
                UserApi.shared.loginWithKakaoAccount(prompts: nil, loginHint: nil, nonce: nil, completion: done)
            }
        }
        #else
        throw NotConfigured(provider: .kakao)
        #endif
    }

    /// 지금 맨 위에 떠 있는 화면 (로그인 화면이 시트여도 그 위에서 띄우게)
    @MainActor
    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

/// 로그인 사용자 · 중개사 인증 · 관심 매물 · 최근 본 매물. 앱 전체에서 하나만 쓴다 (environmentObject).
/// 서버에 아직 없는 API(관심 매물 등)는 기기에 저장해서 화면 흐름이 끊기지 않게 한다.
@MainActor
final class Session: ObservableObject {
    static let shared = Session()

    @Published private(set) var userId: String? = nil
    @Published private(set) var name: String? = nil
    @Published private(set) var provider: String? = nil
    @Published private(set) var agent: AgentProfile? = nil
    @Published private(set) var favoriteIds: Set<String> = []
    @Published private(set) var recent: [Listing] = []
    @Published var toast: String? = nil

    private enum Key {
        static let userId = "userId", name = "userName", provider = "authProvider", token = "accessToken"
        static let agent = "agentProfile", favorites = "favoriteIds", recent = "recentListings", localAgent = "localAgent"
    }

    private init() {
        let d = UserDefaults.standard
        userId = d.string(forKey: Key.userId).flatMap { $0.isEmpty ? nil : $0 }
        name = d.string(forKey: Key.name)
        provider = d.string(forKey: Key.provider)
        if let data = d.data(forKey: Key.agent) { agent = try? JSONDecoder().decode(AgentProfile.self, from: data) }
        favoriteIds = Set(d.stringArray(forKey: Key.favorites) ?? [])
        if let data = d.data(forKey: Key.recent) { recent = (try? JSONDecoder().decode([Listing].self, from: data)) ?? [] }
        // 키체인은 앱을 지웠다 깔아도 남는다: 로그인 기록이 없으면 예전 토큰을 지운다
        if userId == nil {
            KeychainStore.set(KeychainStore.accessToken, nil)
            KeychainStore.set(KeychainStore.refreshToken, nil)
        }
        // refresh 토큰까지 만료되면 로그아웃하고 알린다
        NotificationCenter.default.addObserver(forName: .sessionExpired, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isLoggedIn else { return }
                await self.logout()
                self.toast = "로그인이 만료되었습니다. 다시 로그인해 주세요"
            }
        }
    }

    var isLoggedIn: Bool { userId != nil }
    var isBroker: Bool { agent?.isApproved == true }
    var displayName: String {
        if let n = name?.trimmed, !n.isEmpty { return n }
        switch provider {
        case "kakao": return "카카오 회원"
        case "google": return "Google 회원"
        case "email": return "이메일 회원"
        default: return "\(AppConfig.shared.brandName) 회원"
        }
    }

    // MARK: - 로그인

    /// 이메일 · 비밀번호 로그인
    func loginEmail(email: String, password: String) async throws {
        let r = try await AuthAPI.login(email: email, password: password)
        signIn(r, provider: "email", fallbackName: nil)
        await refresh()
    }

    /// 이메일 가입 → 바로 로그인 (명세: 가입 응답에는 토큰이 없다)
    func signupEmail(email: String, password: String, name: String) async throws {
        try await AuthAPI.signup(email: email, password: password, displayName: name)
        try await loginEmail(email: email, password: password)
    }

    /// 카카오 · 구글: SDK 가 준 토큰을 서버가 검증하고 우리 토큰을 준다
    func loginSocial(_ provider: LoginProvider, token: String, fallbackName: String? = nil) async throws {
        let r = try await AuthAPI.oauth(provider, token: token)
        signIn(r, provider: provider.rawValue, fallbackName: fallbackName)
        await refresh()
    }

    /// 데모 모드: SDK 대신 이름 · 이메일로 만든 가짜 토큰 (데모 백엔드만 받는다)
    func loginDemoSocial(_ provider: LoginProvider, name: String, email: String) async throws {
        try await loginSocial(provider, token: "demo:\(email):\(name)", fallbackName: name)
    }

    private func signIn(_ r: AuthResponse, provider: String, fallbackName: String?) {
        signIn(userId: r.userId, name: r.name ?? fallbackName, provider: provider, token: r.accessToken, refreshToken: r.refreshToken)
    }

    /// 서버 없이 화면만 둘러보기 (개발·시연용). X-User-Id = 1
    func devLogin(name: String = "개발자") {
        signIn(userId: "1", name: name, provider: "dev", token: nil)
        Task { await refresh() }
    }

    private func signIn(userId: String, name: String?, provider: String, token: String?, refreshToken: String? = nil) {
        let d = UserDefaults.standard
        d.set(userId, forKey: Key.userId)
        d.set(name, forKey: Key.name)
        d.set(provider, forKey: Key.provider)
        d.removeObject(forKey: Key.token)                           // 예전 버전이 UserDefaults 에 두던 토큰
        KeychainStore.set(KeychainStore.accessToken, token)
        KeychainStore.set(KeychainStore.refreshToken, refreshToken)
        APIClient.shared.etags.removeAll()                           // 다른 사람의 버전 정보를 쓰지 않게
        toast = nil
        self.userId = userId
        self.name = name
        self.provider = provider
    }

    func logout() async {
        SocialLogin.signOut()                                       // 구글 · 카카오 SDK 로그인도 끊는다
        // 기기 정보부터 지우고, 서버에 알리는 건 기다리지 않는다 (네트워크가 느려도 바로 로그아웃).
        // 명세의 로그아웃은 본문의 refreshToken 으로 세션을 찾으므로 Authorization 이 없어도 된다
        let refreshToken = AppConfig.shared.refreshToken
        KeychainStore.set(KeychainStore.accessToken, nil)
        KeychainStore.set(KeychainStore.refreshToken, nil)
        APIClient.shared.etags.removeAll()
        Task.detached { try? await AuthAPI.logout(refreshToken: refreshToken) }
        let d = UserDefaults.standard
        for k in [Key.userId, Key.name, Key.provider, Key.token, Key.agent, Key.favorites, Key.recent, Key.localAgent] {
            d.removeObject(forKey: k)
        }
        userId = nil
        name = nil
        provider = nil
        agent = nil
        favoriteIds = []
        recent = []
    }

    func refresh() async {
        guard isLoggedIn else { return }
        await refreshAgent()
        await refreshFavorites()
    }

    // MARK: - 중개사 인증

    /// 서버에 인증 API 가 아직 없을 때 기기에만 저장한 중개사 정보 (개발용)
    var usesLocalAgent: Bool { UserDefaults.standard.bool(forKey: Key.localAgent) }

    func refreshAgent() async {
        guard isLoggedIn, !usesLocalAgent else { return }
        do { setAgent(try await UserAPI.agentProfile()) } catch { /* 네트워크 오류면 저장된 값 유지 */ }
    }

    func setAgent(_ profile: AgentProfile?) {
        agent = profile
        if let profile, let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: Key.agent)
        } else {
            UserDefaults.standard.removeObject(forKey: Key.agent)
        }
    }

    /// 기기에만 저장하는 중개사 정보. nil 이면 해제하고 서버 값을 다시 읽는다.
    func setLocalAgent(_ profile: AgentProfile?) {
        UserDefaults.standard.set(profile != nil, forKey: Key.localAgent)
        setAgent(profile)
        if profile == nil { Task { await refreshAgent() } }
    }

    // MARK: - 관심 매물

    func isFavorite(_ id: String) -> Bool { favoriteIds.contains(id) }

    func refreshFavorites() async {
        guard isLoggedIn else { return }
        if let list = try? await UserAPI.scraps() { setFavorites(Set(list.map(\.listingId))) }
    }

    /// 바로 화면에 반영하고 서버에 저장. 서버에 API 가 없으면(404 등) 기기에만 저장한다.
    func toggleFavorite(_ id: String) async {
        let on = !favoriteIds.contains(id)
        var next = favoriteIds
        if on { next.insert(id) } else { next.remove(id) }
        setFavorites(next)
        do {
            try await ListingAPI.setScrap(id, on: on)
        } catch let e as APIError where e.isMissingEndpoint {
            // 기기에만 저장
        } catch {
            var back = favoriteIds
            if on { back.remove(id) } else { back.insert(id) }
            setFavorites(back)
            toast = "관심 매물을 저장하지 못했습니다"
        }
    }

    private func setFavorites(_ ids: Set<String>) {
        favoriteIds = ids
        UserDefaults.standard.set(Array(ids), forKey: Key.favorites)
    }

    // MARK: - 최근 본 매물

    func clearRecent() {
        recent = []
        UserDefaults.standard.removeObject(forKey: Key.recent)
    }

    func recordView(_ listing: Listing) {
        var list = recent.filter { $0.listingId != listing.listingId }
        list.insert(listing, at: 0)
        recent = Array(list.prefix(12))
        if let data = try? JSONEncoder().encode(recent) { UserDefaults.standard.set(data, forKey: Key.recent) }
    }
}

/// 주소 → 좌표 (서버가 위경도를 안 줄 때 지도에 표시하기 위해). 결과는 기기에 캐시한다.
@MainActor
final class Geocoder {
    static let shared = Geocoder()
    private let geocoder = CLGeocoder()
    private var cache: [String: CLLocationCoordinate2D] = [:]
    private var failed: Set<String> = []
    private let storeKey = "geocodeCache"

    private init() {
        let stored = UserDefaults.standard.dictionary(forKey: storeKey) as? [String: [Double]] ?? [:]
        for (k, v) in stored where v.count == 2 { cache[k] = CLLocationCoordinate2D(latitude: v[0], longitude: v[1]) }
    }

    /// "서울 동작구 상도동 123-4, 302호" 처럼 호수가 붙어 있어도 쉼표 앞부분으로 찾는다
    func coordinate(for address: String) async -> CLLocationCoordinate2D? {
        let key = String(address.split(separator: ",").first ?? Substring(address)).trimmed
        guard !key.isEmpty else { return nil }
        if let c = cache[key] { return c }
        if failed.contains(key) { return nil }
        do {
            let marks = try await geocoder.geocodeAddressString(key)
            if let c = marks.first?.location?.coordinate {
                cache[key] = c
                var stored = UserDefaults.standard.dictionary(forKey: storeKey) as? [String: [Double]] ?? [:]
                stored[key] = [c.latitude, c.longitude]
                UserDefaults.standard.set(stored, forKey: storeKey)
                return c
            }
            failed.insert(key)
        } catch let e as CLError where e.code == .geocodeFoundNoResult || e.code == .geocodeFoundPartialResult {
            failed.insert(key)            // 주소가 정말 없는 경우만 기억한다
        } catch {
            // 네트워크 · 요청 제한 · 취소: 다음에 다시 시도
        }
        return nil
    }
}
