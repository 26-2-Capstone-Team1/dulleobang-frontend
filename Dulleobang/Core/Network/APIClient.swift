import Foundation

struct APIError: LocalizedError {
    let status: Int
    let body: String
    var errorDescription: String? { "HTTP \(status): \(body.prefix(200))" }

    /// 오류 응답 본문 (JSON 객체일 때)
    private var json: [String: Any]? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] else { return nil }
        return obj
    }

    /// 대문자 · 숫자 · 밑줄로만 된 값은 사람이 읽을 문구가 아니라 오류 코드다: "RESOURCE_NOT_FOUND"
    static func looksLikeCode(_ s: String) -> Bool {
        let scalars = s.unicodeScalars
        guard scalars.count >= 3, let first = scalars.first, first.value >= 65, first.value <= 90 else { return false }
        for u in scalars {
            let v = u.value
            let upper = v >= 65 && v <= 90          // A–Z
            let digit = v >= 48 && v <= 57          // 0–9
            if !(upper || digit || v == 95) { return false }        // _
        }
        return true
    }

    /// 서버가 보낸 오류 코드. 둘러방 서버(problem+json)는 "code" 와 "detail" 에 같은 코드를 넣는다: "RESOURCE_NOT_FOUND"
    var serverCode: String? {
        guard let obj = json else { return nil }
        for k in ["code", "detail", "error", "message", "reason"] {
            if let s = obj[k] as? String, APIError.looksLikeCode(s) { return s }
        }
        return nil
    }

    /// 서버가 보낸 사람이 읽을 문구 ({"message": "..."} / {"error": "..."} / {"detail": "..."}) 가 있으면 꺼낸다.
    /// 오류 코드처럼 생긴 값은 문구가 아니므로 건너뛴다 (serverCode 로 읽는다)
    var serverMessage: String? {
        guard let obj = json else { return nil }
        for k in ["message", "error", "detail", "reason"] {
            if let s = obj[k] as? String, !s.isEmpty, !APIError.looksLikeCode(s) { return s }
        }
        return nil
    }

    /// 화면에 보여 줄 한국어 문구. 아는 코드는 표에서 찾고, 모르는 코드는 상태 번호로 고른 문구 뒤에 코드를 붙인다
    var displayMessage: String {
        if let code = serverCode {
            if let text = ServerErrorText.forUser[code] { return text }
            if let text = ServerErrorText.toReport[code] { return "\(text) (\(code))" }
            return "\(ServerErrorText.byStatus(status)) (\(code) · \(status))"
        }
        if let m = serverMessage { return "\(m) (\(status))" }
        return "\(ServerErrorText.byStatus(status)) (\(status))"
    }

    /// 아직 서버에 없는 API 로 보이는 응답 (앱이 로컬 동작으로 대신할 때 쓴다).
    /// 둘러방 서버의 404 RESOURCE_NOT_FOUND 는 대상(매물 등)이 없다는 뜻이라 여기에 넣지 않는다
    var isMissingEndpoint: Bool {
        if status == 404 { return serverCode != "RESOURCE_NOT_FOUND" }
        return [405, 501].contains(status)
    }
}

/// 서버 오류 코드 → 화면에 보여 줄 한국어 문구 (코드 목록: 백엔드 spring-boot-v2 의 ApiException · GlobalExceptionHandler)
enum ServerErrorText {
    private static let appFault = "앱이 보낸 요청을 서버가 받지 못했습니다. 다시 시도해 보고, 계속되면 이 문구를 개발팀에 알려 주세요."
    private static let captureFault = "촬영 파일을 서버가 읽지 못했습니다. 다시 촬영해 보고, 계속되면 이 문구를 개발팀에 알려 주세요."
    private static let serverBusy = "서버가 잠시 응답하지 못하고 있습니다. 잠시 후 다시 시도해 주세요."
    private static let changedElsewhere = "그 사이 다른 곳에서 내용이 바뀌었습니다. 새로 불러온 뒤 다시 시도해 주세요."

    /// 쓰는 사람이 직접 해결할 수 있는 오류: 문구만 보여 준다
    static let forUser: [String: String] = [
        // 로그인 · 가입
        "INVALID_CREDENTIALS": "이메일 또는 비밀번호가 맞지 않습니다.",
        "EMAIL_ALREADY_EXISTS": "이미 가입된 이메일입니다. 로그인해 주세요.",
        "INVALID_REFRESH_TOKEN": "로그인이 만료되었습니다. 다시 로그인해 주세요.",
        "TOKEN_REUSED": "보안을 위해 로그아웃되었습니다. 다시 로그인해 주세요.",
        "UNAUTHORIZED": "로그인을 확인하지 못했습니다. 다시 시도해 보고, 계속되면 다시 로그인해 주세요.",
        "INVALID_OAUTH_TOKEN": "소셜 로그인을 확인하지 못했습니다. 다시 로그인해 주세요.",
        "OAUTH_NOT_CONFIGURED": "이 서버에서는 소셜 로그인을 쓸 수 없습니다. 이메일로 로그인해 주세요.",
        "OAUTH_PROVIDER_UNAVAILABLE": "소셜 로그인 서비스에 연결하지 못했습니다. 잠시 후 다시 시도해 주세요.",
        "RATE_LIMIT_EXCEEDED": "요청이 너무 많습니다. 1분쯤 뒤에 다시 시도해 주세요.",
        // 권한 · 없는 대상
        "FORBIDDEN": "이 작업을 할 권한이 없습니다.",
        "RESOURCE_NOT_FOUND": "찾을 수 없습니다. 삭제되었거나 비공개로 바뀌었을 수 있습니다.",
        "VALIDATION_FAILED": "입력한 내용 중 서버가 받지 못하는 값이 있습니다. 글자 수와 숫자 범위를 확인해 주세요.",
        // 매물
        "INVALID_AREA": "공급면적은 전용면적보다 작을 수 없습니다.",
        "INVALID_FLOOR": "해당층은 건물 전체 층수보다 높을 수 없습니다.",
        "INVALID_PRICE": "월세 매물은 월세를 1만원 이상으로, 전세 매물은 월세를 0으로 입력해 주세요.",
        "INVALID_LOCATION": "주소를 입력해 주세요.",
        "LOCATION_COORDINATES_REQUIRED": "주소의 위치를 찾지 못했습니다. 도로명 주소나 지번 주소로 다시 입력해 주세요.",
        "INVALID_STATE": "종료된 매물이라 이 작업을 할 수 없습니다.",
        "SELF_REPORT_FORBIDDEN": "내가 올린 매물은 신고할 수 없습니다.",
        // 채팅
        "SELF_CHAT_FORBIDDEN": "내가 올린 매물에는 채팅을 열 수 없습니다.",
        "CHAT_LISTING_UNAVAILABLE": "매물이 내려가서 이 채팅에는 더 이상 메시지를 보낼 수 없습니다.",
        "EMPTY_MESSAGE": "메시지 내용을 입력해 주세요.",
        // 중개사 인증 · 사진
        "VERIFICATION_PENDING": "이미 중개사 인증을 신청해 심사 중입니다. 결과를 기다려 주세요.",
        "INVALID_IMAGE": "사진을 읽을 수 없습니다. 다른 사진을 골라 주세요.",
        "INVALID_IMAGE_DIMENSIONS": "사진 크기가 맞지 않습니다. 가로 640 · 세로 480픽셀 이상인 사진을 골라 주세요.",
        "CONTENT_TYPE_MISMATCH": "사진 형식을 확인하지 못했습니다. 다른 사진을 골라 주세요.",
        "BODY_TOO_LARGE": "보내는 파일이 너무 큽니다. 사진은 한 장에 20MB까지 올릴 수 있습니다.",
        "UPLOAD_LIMIT_EXCEEDED": "올릴 수 없는 크기의 파일이 있습니다. 사진은 한 장에 20MB까지 올릴 수 있습니다.",
        // 촬영 · 3D 생성
        "CAPTURE_ZIP_TOO_LARGE": "촬영 파일이 너무 큽니다. 더 짧게 다시 촬영해 주세요.",
        "ACTIVE_JOB_EXISTS": "이미 3D 생성이 진행 중입니다. 끝난 뒤에 다시 시도해 주세요.",
        "ACTIVE_JOB_LIMIT": "3D 생성은 한 번에 3개까지 진행할 수 있습니다. 진행 중인 작업이 끝난 뒤에 다시 시도해 주세요.",
        // 3D 공간 · 가구 구분 · 배치
        "SPACE_NOT_READY": "이 매물은 아직 3D 공간이 준비되지 않았습니다.",
        "ROOM_STATE_NOT_READY": "입주 예상 공간이 아직 준비되지 않았습니다.",
        "STALE_SPACE_VERSION": "그 사이 공간이나 가구 구분이 바뀌었습니다. 새로 불러온 뒤 다시 시도해 주세요.",
        "VERSION_MISMATCH": changedElsewhere,
        "PRECONDITION_FAILED": changedElsewhere,
        "OBJECT_NOT_REMOVABLE": "뺄 수 없는 가구가 들어 있습니다. 개인 가구만 뺄 수 있습니다.",
        "UNKNOWN_OBJECT": "목록에 없는 가구가 들어 있습니다. 새로 불러온 뒤 다시 골라 주세요.",
        "RESOURCE_IN_USE": "다른 곳에서 쓰고 있어 지울 수 없습니다.",
        "FURNITURE_NOT_READY": "3D 모델이 아직 준비되지 않은 가구가 있습니다.",
        "STALE_MODEL_VERSION": "가구의 3D 모델이 새로 만들어졌습니다. 가구를 다시 불러온 뒤 저장해 주세요.",
        "PLACEMENT_NOT_FOUND": "저장한 배치가 없습니다.",
    ]

    /// 앱이나 서버 쪽 문제: 문구 뒤에 코드를 붙여 보여 준다 (그대로 개발팀에 전할 수 있게)
    static let toReport: [String: String] = [
        // 서버
        "INTERNAL_ERROR": "서버에 문제가 생겼습니다. 잠시 후 다시 시도해 주세요.",
        "DATABASE_UNAVAILABLE": serverBusy,
        "STORAGE_UNAVAILABLE": serverBusy,
        "IDEMPOTENCY_KEY_REUSED": "같은 요청이 다른 내용으로 다시 전송되었습니다. 다시 시도해 주세요.",
        "INVALID_QUERY_PARAMETER": "검색 조건을 서버가 받지 못했습니다. 검색어를 줄이거나 지도를 확대해 보세요.",
        // 요청 형식 (앱 쪽 문제)
        "MALFORMED_JSON": appFault,
        "BODY_REQUIRED": appFault,
        "UNSUPPORTED_MEDIA_TYPE": appFault,
        "NOT_ACCEPTABLE": appFault,
        "METHOD_NOT_ALLOWED": appFault,
        "IDEMPOTENCY_KEY_REQUIRED": appFault,
        "INVALID_PARAMETER": appFault,
        "UNKNOWN_QUERY_PARAMETER": appFault,
        "DUPLICATE_QUERY_PARAMETER": appFault,
        "AMBIGUOUS_QUERY_PARAMETER": appFault,
        "INCOMPLETE_MAP_BOUNDS": appFault,
        "INVALID_PRICE_FILTER": appFault,
        "INVALID_RANGE": appFault,
        "INVALID_CURSOR": appFault,
        "INVALID_MULTIPART": appFault,
        "DUPLICATE_FIELD": appFault,
        "INVALID_UPLOAD_ROLE": appFault,
        "INVALID_PRECONDITION": appFault,
        "PRECONDITION_REQUIRED": appFault,
        "DUPLICATE_ID": appFault,
        "INVALID_ROTATION": appFault,
        "INVALID_COLLISION_REPORT": appFault,
        // 촬영 파일(capture.zip) 검사
        "INVALID_CAPTURE_ZIP": captureFault,
        "MISSING_CAPTURE_FILE": captureFault,
        "DUPLICATE_ZIP_ENTRY": captureFault,
        "UNSAFE_CAPTURE_ZIP": captureFault,
        "UNSUPPORTED_ZIP_COMPRESSION": captureFault,
        "INVALID_CAPTURE_FILES": captureFault,
        "INVALID_CAPTURE_FILE_NAME": captureFault,
        "INVALID_CAPTURE_JSON": captureFault,
        "INVALID_CAPTURE_METADATA": captureFault,
        "INVALID_CAPTURE_ORIGIN": captureFault,
        "INVALID_CAMERA_POSE": captureFault,
        "INVALID_TRACKING_STATE": captureFault,
        "INVALID_FRAME_ORDER": captureFault,
        "INVALID_DEPTH_REFERENCE": captureFault,
        "INVALID_DEPTH_ENCODING": captureFault,
        "INVALID_CONFIDENCE_REFERENCE": captureFault,
        "INVALID_CONFIDENCE_VALUES": captureFault,
        "INVALID_ROOMPLAN_JSON": captureFault,
        "MANIFEST_IMAGE_MISMATCH": captureFault,
        "UNREFERENCED_DEPTH_FILE": captureFault,
        "INVALID_UPLOAD_SESSION": captureFault,
    ]

    /// 실패한 AI 작업의 원인 코드 (GET /ai-jobs/{jobId} 의 error.code) → 문구
    static let jobFailure: [String: String] = [
        "INSUFFICIENT_FRAMES": "촬영한 사진이 부족합니다. 더 천천히, 빠진 곳 없이 다시 촬영해 주세요.",
        "TRACKING_UNSTABLE": "촬영 중 위치 추적이 불안정했습니다. 더 천천히 움직이며 다시 촬영해 주세요.",
        "SCALE_UNRELIABLE": "공간의 크기를 정확히 재지 못했습니다. 다시 촬영해 주세요.",
        "RECONSTRUCTION_FAILED": "3D 공간을 만들지 못했습니다. 다시 촬영해 주세요.",
        "SEGMENTATION_FAILED": "가구를 구분하지 못했습니다. 다시 촬영해 주세요.",
        "REMOVAL_FAILED": "가구를 뺀 공간을 만들지 못했습니다. 다시 시도해 주세요.",
        "INVALID_ARTIFACT": "만들어진 3D 결과에 문제가 있어 쓸 수 없습니다. 다시 시도해 주세요.",
        "WORKER_TIMEOUT": "AI 처리가 너무 오래 걸려 중단되었습니다. 잠시 후 다시 시도해 주세요.",
        "DEPENDENCY_UNAVAILABLE": "AI 서버가 잠시 응답하지 않습니다. 잠시 후 다시 시도해 주세요.",
        "INTERNAL_ERROR": "AI 처리 중 서버에 문제가 생겼습니다. 잠시 후 다시 시도해 주세요.",
    ]

    /// 표에 없는 코드 · 코드가 없는 응답은 상태 번호로 고른다
    static func byStatus(_ status: Int) -> String {
        switch status {
        case 400, 415, 422: return "요청을 처리하지 못했습니다. 입력한 내용을 확인해 주세요."
        case 401: return "로그인이 필요합니다. 다시 로그인해 주세요."
        case 403: return "이 작업을 할 권한이 없습니다."
        case 404: return "요청한 정보를 찾을 수 없습니다."
        case 405, 501: return "아직 지원하지 않는 기능입니다."
        case 409, 412, 428: return changedElsewhere
        case 413: return "보내는 파일이 너무 큽니다."
        case 429: return "요청이 너무 많습니다. 잠시 후 다시 시도해 주세요."
        default:
            return status >= 500 ? "서버에 문제가 생겼습니다. 잠시 후 다시 시도해 주세요." : "요청을 처리하지 못했습니다."
        }
    }
}

struct Empty: Decodable {}

/// 요청 안전장치 (명세 v1: Idempotency-Key · ETag/If-Match)
enum RequestSafety {
    /// 생성 · 제출 요청(POST)에는 요청마다 새 키를 붙인다. 네트워크가 끊겨 다시 보낼 때는 같은 키를 써서 서버가 한 번만 처리하게 한다
    static func needsIdempotencyKey(_ method: String) -> Bool { method == "POST" }
    /// 처음 저장이면 만들고 있으면 바꾸는 자원 (첫 저장은 If-None-Match: *)
    static func isCreateOrReplace(_ path: String) -> Bool { path.hasPrefix("listings/") && path.hasSuffix("/placements") }
    /// 잠깐 끊긴 네트워크로 보고 다시 보내 볼 오류
    static func isTransient(_ e: URLError) -> Bool {
        [.timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet].contains(e.code)
    }
}

extension Notification.Name {
    /// refresh 토큰까지 만료 · 폐기됨 → 다시 로그인해야 한다 (Session 이 받아서 로그아웃)
    static let sessionExpired = Notification.Name("DulleobangSessionExpired")
}

/// access 토큰 갱신을 한 번만 돌린다. 여러 요청이 동시에 401 을 받아도 refresh 는 1회 (명세: 병렬 갱신 금지, 매번 새 refresh 토큰)
actor TokenRefresher {
    private var inflight: Task<Bool, Never>?

    func refresh() async -> Bool {
        if let inflight { return await inflight.value }
        let task = Task { () -> Bool in
            guard let token = AppConfig.shared.refreshToken else { return false }
            do {
                let r = try await AuthAPI.refresh(token)
                // 그 사이 로그아웃 · 다른 계정 로그인이면 받은 토큰을 버린다
                guard let access = r.accessToken, AppConfig.shared.refreshToken == token else { return false }
                KeychainStore.set(KeychainStore.accessToken, access)
                if let next = r.refreshToken { KeychainStore.set(KeychainStore.refreshToken, next) }
                return true
            } catch let e as APIError where e.status == 401 {
                // 그 사이 다른 계정으로 로그인했으면 새 세션을 끊지 않는다
                if AppConfig.shared.refreshToken == token {
                    await MainActor.run { NotificationCenter.default.post(name: .sessionExpired, object: nil) }
                }
                return false
            } catch {
                return false                // 네트워크 문제면 다음 요청 때 다시 시도
            }
        }
        inflight = task
        let ok = await task.value
        inflight = nil
        return ok
    }
}

/// 서버가 준 ETag 를 경로별로 기억했다가 수정 · 삭제 때 If-Match 로 돌려보낸다
final class ETagStore: @unchecked Sendable {
    private var map: [String: String] = [:]
    private let lock = NSLock()
    func get(_ path: String) -> String? { lock.lock(); defer { lock.unlock() }; return map[path] }
    func set(_ path: String, _ tag: String?) { lock.lock(); defer { lock.unlock() }; map[path] = tag }
    /// 로그인 사용자 · 데이터 출처(데모 ↔ 서버)가 바뀌면 전부 버린다
    func removeAll() { lock.lock(); defer { lock.unlock() }; map.removeAll() }
}

/// REST 클라이언트. JSON 은 JSONDecoder/Encoder, 큰 파일은 파일 기반 upload/download 로 메모리를 쓰지 않는다.
/// 응답이 {"status":…, "message":…, "data": …} 처럼 감싸져 와도 data 를 꺼내서 디코딩한다.
final class APIClient {
    static let shared = APIClient()

    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    let etags = ETagStore()
    private let refresher = TokenRefresher()
    /// 네트워크가 잠깐 끊겼을 때 다시 보내기 전 기다리는 시간 (초). 같은 헤더(같은 Idempotency-Key)로 보낸다
    private let retryDelays: [Double] = [1, 2]

    private func request(_ method: String, _ path: String, query: [URLQueryItem] = []) -> URLRequest {
        var comps = URLComponents(url: AppConfig.shared.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        // 로그인 · 가입 · 갱신에는 예전(만료된) 토큰을 붙이지 않는다 (서버 인증 필터가 401 로 막을 수 있음)
        if !path.hasPrefix("auth/") || path == "auth/logout" { Self.authorize(&req) }
        return req
    }

    /// 데모 인증: X-User-Id (+ 로그인 응답에 토큰이 있으면 Bearer)
    static func authorize(_ req: inout URLRequest) {
        if let uid = AppConfig.shared.userId { req.setValue(uid, forHTTPHeaderField: "X-User-Id") }
        if let token = AppConfig.shared.accessToken { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    }

    /// Idempotency-Key (POST) · If-Match / If-None-Match (PATCH · PUT · DELETE)
    private func applySafetyHeaders(_ req: inout URLRequest, method: String, path: String, ifMatch: String?) {
        if RequestSafety.needsIdempotencyKey(method), req.value(forHTTPHeaderField: "Idempotency-Key") == nil {
            req.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "Idempotency-Key")
        }
        guard ["PATCH", "PUT", "DELETE"].contains(method) else { return }
        if let tag = ifMatch ?? etags.get(path) {
            req.setValue(tag, forHTTPHeaderField: "If-Match")
        } else if method == "PUT", RequestSafety.isCreateOrReplace(path) {
            req.setValue("*", forHTTPHeaderField: "If-None-Match")
        }
    }

    private func check(_ data: Data, _ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
    }

    /// 응답의 ETag 를 기억한다. ETag 가 없는 응답이면 예전 값을 지운다 (낡은 버전으로 덮어쓰지 않게)
    private func remember(_ response: URLResponse, path: String) {
        guard let http = response as? HTTPURLResponse else { return }
        etags.set(path, http.value(forHTTPHeaderField: "ETag"))
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        try Self.decodeResponse(data, decoder: decoder)
    }

    /// 봉투({status, message, data}) 를 벗겨서 디코딩. 봉투가 아니면 그대로 디코딩한다. (테스트에서도 사용)
    static func decodeResponse<T: Decodable>(_ data: Data, as type: T.Type = T.self,
                                             decoder: JSONDecoder = JSONDecoder()) throws -> T {
        if T.self == Empty.self { return Empty() as! T }
        if let inner = unwrapEnvelope(data), let v = try? decoder.decode(T.self, from: inner) { return v }
        return try decoder.decode(T.self, from: data)
    }

    static func unwrapEnvelope(_ data: Data) -> Data? {
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any],
              let inner = obj["data"], !(inner is NSNull) else { return nil }
        let markers: Set<String> = ["status", "success", "isSuccess", "message", "code", "result", "timestamp"]
        guard !markers.isDisjoint(with: obj.keys) else { return nil }
        return try? JSONSerialization.data(withJSONObject: inner, options: [.fragmentsAllowed])
    }

    /// 데모 모드(설정 › 데모 데이터 사용)면 앱 안의 MockBackend 가, 아니면 서버가 응답한다
    private func transport(_ req: URLRequest, path: String, query: [URLQueryItem]) async throws -> (Data, URLResponse) {
        if AppConfig.shared.useMockData {
            return await MockBackend.shared.respond(MockRequest(method: req.httpMethod ?? "GET", path: path, query: query,
                                                                body: req.httpBody, headers: req.allHTTPHeaderFields ?? [:]))
        }
        return try await withRetry { try await URLSession.shared.data(for: req) }
    }

    /// 401(access 토큰 만료)이면 토큰을 한 번 갱신하고 새 토큰으로 다시 보낸다. 로그인 · 갱신 요청 자신은 제외
    private func perform(_ req: URLRequest, path: String, query: [URLQueryItem]) async throws -> (Data, URLResponse) {
        let first = try await transport(req, path: path, query: query)
        guard await refreshedAfterUnauthorized(first.1, path: path) else { return first }
        var retry = req
        Self.authorize(&retry)
        return try await transport(retry, path: path, query: query)
    }

    /// 401 이면 토큰을 한 번 갱신한다 (성공하면 true → 호출한 쪽이 새 토큰으로 다시 보낸다).
    /// refresh 토큰이 없는데 401 이면(예전 버전 로그인) 다시 로그인하도록 알린다
    private func refreshedAfterUnauthorized(_ response: URLResponse, path: String) async -> Bool {
        guard (response as? HTTPURLResponse)?.statusCode == 401, !path.hasPrefix("auth/") else { return false }
        guard AppConfig.shared.refreshToken != nil else {
            if AppConfig.shared.accessToken != nil {
                await MainActor.run { NotificationCenter.default.post(name: .sessionExpired, object: nil) }
            }
            return false
        }
        return await refresher.refresh()
    }

    /// 잠깐 끊긴 네트워크면 같은 요청을 조금 기다렸다 다시 보낸다
    private func withRetry<T>(_ operation: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await operation()
            } catch let e as URLError where RequestSafety.isTransient(e) && attempt < retryDelays.count {
                try await Task.sleep(for: .seconds(retryDelays[attempt]))
                attempt += 1
            }
        }
    }

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let (data, resp) = try await perform(request("GET", path, query: query), path: path, query: query)
        try check(data, resp)
        remember(resp, path: path)
        return try decode(data)
    }

    /// 목록 응답: [T] / {"data":[T]} / {"content":[T]} / {"listings":[T]} … 모두 [T] 로
    func getList<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> [T] {
        let list: FlexibleList<T> = try await get(path, query: query)
        return list.items
    }

    /// ifMatch: 화면이 알고 있는 버전(예: 가구 구분의 objectsVersion). 없으면 기억해 둔 ETag 를 쓴다
    func send<T: Decodable, B: Encodable>(_ method: String, _ path: String, body: B?, query: [URLQueryItem] = [],
                                          ifMatch: String? = nil) async throws -> T {
        var req = request(method, path, query: query)
        if let body {
            req.httpBody = try encoder.encode(body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        applySafetyHeaders(&req, method: method, path: path, ifMatch: ifMatch)
        var (data, resp) = try await perform(req, path: path, query: query)
        // 428 = 버전을 몰라서 못 보냄. 내 것만 있는 자원(배치)일 때만 지금 버전을 받아 한 번 다시 보낸다.
        // 412 는 다른 곳에서 먼저 바뀐 것이므로 덮어쓰지 않고 화면에 알린다 (배치는 사용자가 "덮어쓰기"를 고르면 다시 저장)
        if (resp as? HTTPURLResponse)?.statusCode == 428, RequestSafety.isCreateOrReplace(path),
           let tag = await refreshETag(path) {
            req.setValue(nil, forHTTPHeaderField: "If-None-Match")
            req.setValue(tag, forHTTPHeaderField: "If-Match")
            (data, resp) = try await perform(req, path: path, query: query)
        }
        if (resp as? HTTPURLResponse)?.statusCode == 412 { etags.set(path, nil) }       // 낡은 버전은 버린다
        try check(data, resp)
        remember(resp, path: path)
        return try decode(data)
    }

    /// 같은 경로를 GET 해서 지금 ETag 만 받아 온다 (덮어쓰기를 고른 경우 등)
    @discardableResult
    func refreshETag(_ path: String) async -> String? {
        guard let result = try? await perform(request("GET", path), path: path, query: []),
              let http = result.1 as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let tag = http.value(forHTTPHeaderField: "ETag") else { return nil }
        etags.set(path, tag)
        return tag
    }

    func post<T: Decodable, B: Encodable>(_ path: String, _ body: B) async throws -> T { try await send("POST", path, body: body) }
    func post<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        try await send("POST", path, body: Optional<Empty0>.none, query: query)
    }
    func put<T: Decodable, B: Encodable>(_ path: String, _ body: B) async throws -> T { try await send("PUT", path, body: body) }
    func patch<T: Decodable, B: Encodable>(_ path: String, _ body: B, ifMatch: String? = nil) async throws -> T {
        try await send("PATCH", path, body: body, ifMatch: ifMatch)
    }
    func delete<T: Decodable>(_ path: String) async throws -> T { try await send("DELETE", path, body: Optional<Empty0>.none) }

    /// 파일을 스트리밍 업로드 (capture.zip 수백 MB 대응). Content-Type: application/zip
    func upload<T: Decodable>(_ path: String, file: URL, contentType: String = "application/zip",
                              progress: (@Sendable (Double) -> Void)? = nil) async throws -> T {
        var req = request("POST", path)
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 600
        applySafetyHeaders(&req, method: "POST", path: path, ifMatch: nil)
        if AppConfig.shared.useMockData {
            let (data, resp) = await MockBackend.shared.respond(
                MockRequest(method: "POST", path: path, file: file, headers: req.allHTTPHeaderFields ?? [:]), progress: progress)
            try check(data, resp)
            return try decode(data)
        }
        let delegate = TransferProgressDelegate(onProgress: progress)
        let request = req
        var (data, resp) = try await withRetry { try await URLSession.shared.upload(for: request, fromFile: file, delegate: delegate) }
        if await refreshedAfterUnauthorized(resp, path: path) {          // 오래 촬영하는 동안 토큰이 만료된 경우
            var again = request
            Self.authorize(&again)
            let retry = again
            (data, resp) = try await withRetry { try await URLSession.shared.upload(for: retry, fromFile: file, delegate: delegate) }
        }
        try check(data, resp)
        return try decode(data)
    }

    /// multipart/form-data (매물 사진 · 사업자 등록증). 사진 수십 장 정도라 메모리에서 조립한다.
    func uploadMultipart<T: Decodable>(_ path: String, method: String = "POST", parts: [MultipartPart],
                                       progress: (@Sendable (Double) -> Void)? = nil) async throws -> T {
        var req = request(method, path)
        applySafetyHeaders(&req, method: method, path: path, ifMatch: nil)
        if AppConfig.shared.useMockData {
            let (data, resp) = await MockBackend.shared.respond(
                MockRequest(method: method, path: path, parts: parts, headers: req.allHTTPHeaderFields ?? [:]), progress: progress)
            try check(data, resp)
            return try decode(data)
        }
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        for part in parts {
            body.appendString("--\(boundary)\r\n")
            switch part {
            case .field(let name, let value):
                body.appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
                body.appendString("\(value)\r\n")
            case .file(let name, let filename, let mimeType, let data):
                body.appendString("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
                body.appendString("Content-Type: \(mimeType)\r\n\r\n")
                body.append(data)
                body.appendString("\r\n")
            }
        }
        body.appendString("--\(boundary)--\r\n")

        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 300
        let delegate = TransferProgressDelegate(onProgress: progress)
        let payload = body, request = req
        var (data, resp) = try await withRetry { try await URLSession.shared.upload(for: request, from: payload, delegate: delegate) }
        if await refreshedAfterUnauthorized(resp, path: path) {
            var again = request
            Self.authorize(&again)
            let retry = again
            (data, resp) = try await withRetry { try await URLSession.shared.upload(for: retry, from: payload, delegate: delegate) }
        }
        try check(data, resp)
        return try decode(data)
    }

    /// 절대 URL 다운로드 → 지정 경로로 이동
    func download(_ url: URL, to dest: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if url.isFileURL {                       // 앱 번들 · 데모 데이터 파일
            try FileManager.default.copyItem(at: url, to: dest)
            progress?(1)
            return
        }
        var req = URLRequest(url: url)
        // 우리 서버의 파일만 인증 헤더를 붙인다. S3 같은 서명 URL 에 Authorization 이 붙으면 저장소가 요청을 거절한다
        if url.host == AppConfig.shared.baseURL.host { Self.authorize(&req) }
        req.timeoutInterval = 600
        let delegate = TransferProgressDelegate(onProgress: progress)
        let request = req
        var (tmp, resp) = try await withRetry { try await URLSession.shared.download(for: request, delegate: delegate) }
        if url.host == AppConfig.shared.baseURL.host, await refreshedAfterUnauthorized(resp, path: "files") {
            var again = request
            Self.authorize(&again)
            let retry = again
            (tmp, resp) = try await withRetry { try await URLSession.shared.download(for: retry, delegate: delegate) }
        }
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw APIError(status: http.statusCode, body: url.absoluteString)
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
    }
}

enum MultipartPart {
    case field(name: String, value: String)
    case file(name: String, filename: String, mimeType: String, data: Data)
}

private extension Data {
    mutating func appendString(_ s: String) { append(Data(s.utf8)) }
}

/// `post(path)` 의 body 없는 호출용 더미 타입
struct Empty0: Encodable {}

/// 업로드/다운로드 진행률. iOS 16+ didCreateTask 로 task.progress 를 KVO 관찰한다
/// (URLSessionDownloadDelegate 를 구현하면 async download 의 임시 파일 처리와 충돌할 수 있어 피한다).
final class TransferProgressDelegate: NSObject, URLSessionTaskDelegate {
    let onProgress: (@Sendable (Double) -> Void)?
    private var observation: NSKeyValueObservation?
    init(onProgress: (@Sendable (Double) -> Void)?) { self.onProgress = onProgress }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        guard let onProgress else { return }
        observation = task.progress.observe(\.fractionCompleted, options: [.new]) { p, _ in
            onProgress(p.fractionCompleted)
        }
    }
}

/// 서버가 돌려준 URI(절대 URL 또는 "/files/..." 같은 상대 경로)를 다운로드 가능한 URL 로 바꾼다.
/// s3:// 같은 내부 URI 는 앱이 받을 수 없으므로 백엔드가 http(s) (pre-signed) URL 로 내려줘야 한다.
enum AssetURL {
    static func resolve(_ uri: String?) -> URL? {
        guard let uri, !uri.isEmpty else { return nil }
        if MockFiles.isLocal(uri) { return MockFiles.localURL(for: uri) }      // 데모 데이터 (bundle:// · mockfile://)
        if let u = URL(string: uri), let scheme = u.scheme, scheme.hasPrefix("http") { return u }
        let base = AppConfig.shared.baseURL
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        comps.path = uri.hasPrefix("/") ? uri : "/" + uri
        comps.query = nil
        return comps.url
    }
}
