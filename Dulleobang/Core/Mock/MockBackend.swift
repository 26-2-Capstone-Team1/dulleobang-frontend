import CryptoKit
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// APIClient 가 데모 모드에서 서버 대신 부르는 요청 한 건
struct MockRequest {
    var method: String
    var path: String
    var query: [URLQueryItem] = []
    var body: Data? = nil
    var parts: [MultipartPart] = []
    var file: URL? = nil
    var userId: String? = AppConfig.shared.userId
    var headers: [String: String] = [:]           // Idempotency-Key · If-Match · If-None-Match

    /// 헤더 이름은 대소문자를 가리지 않는다
    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// 서버 없이 앱 전체를 둘러볼 수 있게 하는 앱 내장 데모 백엔드.
/// Endpoints.swift 의 경로를 그대로 받아 JSON 을 돌려주므로, 화면 · 디코딩 코드는 실제 서버와 똑같이 동작한다.
///  - 매물 12개(사진 · 좌표 · 3D 공간 · 입주 상태), 채팅 3개(보내면 중개사가 자동 답장), 내 가구 4개
///  - AI 작업(3D 생성 · 가구 제거 · 가구 3D)은 몇 초 뒤 완료된 것으로 처리한다
///  - 중개사 인증은 3초 뒤 자동 승인. 인증되면 매물 104 · 109 가 "내가 올린 매물"이 된다 (중개사 화면 시연용)
actor MockBackend {
    static let shared = MockBackend(storeURL: MockFiles.dbURL)

    private let storeURL: URL?
    private var db: MockDB
    private var dirty = false
    /// 멱등 키로 처리한 POST 응답 (앱을 다시 켜면 비운다). 키 = 사용자|경로|Idempotency-Key
    private var replays: [String: (fingerprint: String, out: Out)] = [:]
    private(set) var loadProblem: String?

    private static let host = URL(string: "https://demo.dulleobang.local/api")!
    private static let isoFormatter = ISO8601DateFormatter()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// storeURL 이 nil 이면 저장하지 않는다 (테스트용)
    init(storeURL: URL?) {
        self.storeURL = storeURL
        var problem: String?
        db = Self.loadOrSeed(storeURL: storeURL, problem: &problem)
        loadProblem = problem
    }

    // MARK: - 공개 API

    func respond(_ r: MockRequest, progress: (@Sendable (Double) -> Void)? = nil) async -> (Data, URLResponse) {
        if let progress {
            for p in [0.15, 0.4, 0.65, 0.85, 1.0] {                 // 업로드 진행률 흉내
                try? await Task.sleep(nanoseconds: 120_000_000)
                progress(p)
            }
        } else {
            try? await Task.sleep(nanoseconds: 150_000_000)          // 네트워크 지연 흉내 (로딩 표시가 잠깐 보이게)
        }
        let out = handleOnce(r)
        if dirty {
            persist()
            dirty = false
        }
        let url = Self.host.appendingPathComponent(r.path)
        var fields = ["Content-Type": "application/json"]
        fields.merge(out.headers) { _, new in new }
        let resp = HTTPURLResponse(url: url, statusCode: out.status, httpVersion: "HTTP/1.1", headerFields: fields)!
        return (out.data, resp)
    }

    /// 처음 상태로 되돌린다 (올린 사진 · 촬영본 파일도 지운다)
    func reset() {
        if storeURL != nil { try? FileManager.default.removeItem(at: MockFiles.root) }
        var problem: String?
        db = Self.loadOrSeed(storeURL: nil, problem: &problem)
        loadProblem = problem
        persist()
    }

    /// 설정 화면 표시용
    func summary() -> String {
        if let loadProblem { return loadProblem }
        return "매물 \(db.listings.count) · 채팅 \(db.chats.count) · 가구 \(db.furniture.count)"
    }

    static func bundledSeed() throws -> MockSeed {
        guard let url = MockFiles.localURL(for: "bundle://Mock/mock_seed.json") else {
            throw MockError("앱에 데모 데이터(Mock/mock_seed.json)가 없습니다. Resources/Mock 폴더가 번들에 포함됐는지 확인해 주세요.")
        }
        return try JSONDecoder().decode(MockSeed.self, from: Data(contentsOf: url))
    }

    // MARK: - 저장

    private static func loadOrSeed(storeURL: URL?, problem: inout String?) -> MockDB {
        let seed: MockSeed
        do {
            seed = try bundledSeed()
        } catch {
            problem = (error as? MockError)?.message ?? "데모 데이터를 읽지 못했습니다: \(error)"
            print("[demo] \(problem ?? "")")
            return .empty()
        }
        if let storeURL, let data = try? Data(contentsOf: storeURL),
           let stored = try? JSONDecoder().decode(MockDB.self, from: data),
           stored.storeVersion == MockDB.currentStoreVersion, stored.seedVersion == seed.seedVersion {
            return stored
        }
        return MockDB.fromSeed(seed)
    }

    private func persist() {
        guard let storeURL else { return }
        do {
            try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(db).write(to: storeURL, options: .atomic)
        } catch {
            print("[demo] 저장 실패: \(error)")
        }
    }

    // MARK: - 라우팅

    private struct Out {
        var status: Int
        var data: Data
        var headers: [String: String] = [:]
    }

    /// 명세 v1 멱등 처리: 같은 키 · 같은 내용의 POST 는 처음 응답을 그대로 돌려주고, 같은 키로 다른 내용을 보내면 409
    private func handleOnce(_ r: MockRequest) -> Out {
        guard r.method == "POST", let key = r.header("Idempotency-Key") else { return handle(r) }
        let slot = "\(r.userId ?? "guest")|\(r.path)|\(key)"
        let fingerprint = Self.fingerprint(r)
        if let saved = replays[slot] {
            return saved.fingerprint == fingerprint ? saved.out
                : fail(409, "같은 요청 키로 다른 내용을 보냈습니다 (IDEMPOTENCY_KEY_REUSED)")
        }
        let out = handle(r)
        if (200..<300).contains(out.status) { replays[slot] = (fingerprint, out) }
        return out
    }

    private static func etag(_ version: Int) -> String { "\"\(version)\"" }

    /// 요청 내용 지문 (본문 · multipart 각 부분 · 업로드 파일 · 쿼리)
    private static func fingerprint(_ r: MockRequest) -> String {
        var h = SHA256()
        h.update(data: r.body ?? Data())
        for part in r.parts {
            switch part {
            case .field(let name, let value): h.update(data: Data("f|\(name)|\(value)".utf8))
            case .file(let name, let filename, _, let data):
                h.update(data: Data("d|\(name)|\(filename)|".utf8))
                h.update(data: data)
            }
        }
        h.update(data: Data("\(r.file?.path ?? "")|\(r.query.description)".utf8))
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func handle(_ r: MockRequest) -> Out {
        tick()
        let uid = r.userId ?? "guest"
        var q: [String: String] = [:]
        for item in r.query { if let v = item.value { q[item.name] = v } }

        if match(r, "POST", "auth/logout") != nil { return okEmpty() }
        if match(r, "POST", "auth/signup") != nil { return signup(r.body) }
        if match(r, "POST", "auth/login") != nil { return emailLogin(r.body) }
        if match(r, "POST", "auth/refresh") != nil { return refreshTokens(r.body) }
        if let c = match(r, "POST", "auth/oauth/:provider") { return oauthLogin(provider: c[0], r.body) }
        if let c = match(r, "GET", "auth/:provider") { return login(provider: c[0], q) }      // 예전 데모 로그인 (호환)

        if match(r, "GET", "users/me/agent-profile") != nil { return getProfile(uid) }
        if match(r, "POST", "users/me/agent-profile") != nil { return applyAgent(uid, r.parts) }
        if match(r, "GET", "users/me/listings") != nil { return ok(myListings(uid)) }
        if match(r, "GET", "users/me/scraps") != nil { return ok(scrapList(uid)) }
        if match(r, "GET", "users/me/furniture") != nil { return ok(myFurniture(uid)) }

        if match(r, "GET", "listings") != nil { return ok(search(q, uid)) }
        if match(r, "POST", "listings") != nil { return createListing(r.body, uid) }
        if let c = match(r, "GET", "listings/:id") { return getListing(c[0], uid) }
        if let c = match(r, "POST", "listings/:id/images") { return uploadImages(c[0], r.parts) }
        if let c = match(r, "POST", "listings/:id/captures") { return uploadSpaceCapture(c[0], r.file) }
        if let c = match(r, "POST", "listings/:id/scrap") { return setScrap(c[0], on: true, uid) }
        if let c = match(r, "DELETE", "listings/:id/scrap") { return setScrap(c[0], on: false, uid) }
        if match(r, "POST", "listings/:id/reports") != nil {
            db.reportCount += 1
            dirty = true
            return okEmpty()
        }
        if let c = match(r, "GET", "listings/:id/space") {
            guard let s = db.spaces[c[0]] else { return fail(404, "아직 3D 공간이 없는 매물입니다") }
            return ok(s)
        }
        if let c = match(r, "GET", "listings/:id/objects") {
            let space = db.spaces[c[0]]
            return ok(space?.objects ?? [], headers: ["ETag": Self.etag(space?.objectsVersion ?? 1)])
        }
        if let c = match(r, "PATCH", "listings/:id/objects") { return patchObjects(c[0], r, uid) }
        if let c = match(r, "POST", "listings/:id/room-states") { return createRoomState(c[0], r.body, uid) }
        if let c = match(r, "GET", "listings/:id/room-states") { return ok(Page(items: myRoomStates(c[0], uid))) }
        if let c = match(r, "GET", "listings/:id/placements") {
            let key = "\(uid)|\(c[0])"
            let headers = db.placementVersions?[key].map { ["ETag": Self.etag($0)] } ?? [:]
            return ok(db.placements[key] ?? [], headers: headers)
        }
        if let c = match(r, "PUT", "listings/:id/placements") { return savePlacements(c[0], r, uid) }

        if let c = match(r, "GET", "room-states/:id") {
            guard let rs = visibleRoomState(c[0], uid) else { return fail(404, "입주 상태를 찾을 수 없습니다") }
            return ok(rs)
        }
        if let c = match(r, "DELETE", "room-states/:id") { return deleteRoomState(c[0], uid) }

        if match(r, "POST", "furniture") != nil { return createFurniture(r.body, uid) }
        if let c = match(r, "GET", "furniture/:id") {
            guard let f = db.furniture.first(where: { $0.furniture.furnitureId == c[0] }) else {
                return fail(404, "가구를 찾을 수 없습니다")
            }
            return ok(f.furniture)
        }
        if let c = match(r, "POST", "furniture/:id/captures") { return uploadFurnitureCapture(c[0], r.file) }

        if match(r, "GET", "chat") != nil { return ok(chatSummaries(uid)) }
        if match(r, "POST", "chat") != nil { return openChat(r.body, uid) }
        if let c = match(r, "GET", "chat/:id") { return chatDetail(c[0], uid) }
        if let c = match(r, "POST", "chat/:id") { return sendMessage(c[0], r.body, uid) }

        if let c = match(r, "GET", "ai-jobs/:id") { return jobStatus(c[0]) }

        return fail(404, "데모 서버에 없는 API 입니다: \(r.method) /\(r.path)")
    }

    /// "listings/:id/space" 같은 패턴과 맞으면 :값들을 돌려준다
    private func match(_ r: MockRequest, _ method: String, _ pattern: String) -> [String]? {
        guard r.method == method else { return nil }
        let p = pattern.split(separator: "/").map(String.init)
        let a = r.path.split(separator: "/").map(String.init)
        guard p.count == a.count else { return nil }
        var captured: [String] = []
        for (x, y) in zip(p, a) {
            if x.hasPrefix(":") {
                captured.append(y.removingPercentEncoding ?? y)
            } else if x != y {
                return nil
            }
        }
        return captured
    }

    private func ok<T: Encodable>(_ value: T, status: Int = 200, headers: [String: String] = [:]) -> Out {
        do {
            return Out(status: status, data: try encoder.encode(value), headers: headers)
        } catch {
            return fail(500, "데모 응답을 만들지 못했습니다: \(error)")
        }
    }

    private func okEmpty() -> Out { Out(status: 200, data: Data("{}".utf8)) }

    private func fail(_ status: Int, _ message: String) -> Out {
        Out(status: status, data: (try? encoder.encode(["message": message])) ?? Data())
    }

    private func decodeBody<T: Decodable>(_ type: T.Type, _ body: Data?) -> T? {
        guard let body else { return nil }
        return try? decoder.decode(T.self, from: body)
    }

    private func nextId() -> String {
        db.seq += 1
        dirty = true
        return String(db.seq)
    }

    /// 데모 파일 저장 → mockfile:// URI. 저장하지 않는 백엔드(테스트)는 파일을 쓰지 않는다
    private func saveFile(_ data: Data, as rel: String) -> String? {
        guard storeURL != nil else { return "mockfile://" + rel }
        return try? MockFiles.save(data, as: rel)
    }

    private static func iso(_ d: Date) -> String { isoFormatter.string(from: d) }

    // MARK: - 시간이 지나면 바뀌는 것들 (AI 작업 완료 · 인증 승인 · 자동 답장)

    private func tick() {
        let now = Date()
        for i in db.jobs.indices where !db.jobs[i].finished {
            guard let started = db.jobs[i].startedAt, now.timeIntervalSince(started) >= db.jobs[i].duration else { continue }
            complete(i)
        }
        for (userId, p) in db.profiles where p.profile.isPending {
            guard let at = p.approveAt, at <= now else { continue }
            var next = p
            next.profile.status = "APPROVED"
            next.profile.verifiedAt = Self.iso(now)
            next.approveAt = nil
            db.profiles[userId] = next
            dirty = true
        }
        for i in db.chats.indices where !db.chats[i].pendingReplies.isEmpty {
            let due = db.chats[i].pendingReplies.filter { $0.at <= now }
            guard !due.isEmpty else { continue }
            db.chats[i].messages.append(contentsOf: due)
            db.chats[i].pendingReplies.removeAll { $0.at <= now }
            db.chats[i].unread += due.count
            dirty = true
        }
    }

    private func complete(_ i: Int) {
        db.jobs[i].finished = true
        dirty = true
        let job = db.jobs[i]
        switch job.kind {
        case "SPACE":
            if let li = listingIndex(job.targetId) {
                db.listings[li].listing.space3DInfo = Space3DInfo(status: "COMPLETED", jobId: job.jobId)
            }
        case "ROOM_STATE":
            // 만드는 동안 지웠으면 되살리지 않는다
            if let rsId = job.roomStateId, db.roomStates[rsId] != nil {
                db.roomStates[rsId]?.status = "READY"
            }
        case "FURNITURE":
            if let fi = db.furniture.firstIndex(where: { $0.furniture.furnitureId == job.targetId }) {
                var f = db.furniture[fi].furniture
                f.status = "COMPLETED"
                f.modelUri = Self.boxModel
                f.dimensions = Self.defaultDimensions(f.category)
                if f.thumbnailUri == nil { f.thumbnailUri = Self.defaultThumbnail(f.category) }
                db.furniture[fi].furniture = f
            }
        default:
            break
        }
    }

    private func newJob(kind: String, target: String, duration: Double,
                        roomStateId: String? = nil, removed: [String]? = nil) -> MockJob {
        let job = MockJob(jobId: "J\(nextId())", kind: kind, targetId: target, roomStateId: roomStateId, removed: removed,
                          duration: duration, startedAt: Date(), finished: false)
        db.jobs.append(job)
        dirty = true
        return job
    }

    private func jobStatus(_ id: String) -> Out {
        guard let i = db.jobs.firstIndex(where: { $0.jobId == id }) else { return fail(404, "작업을 찾을 수 없습니다") }
        let now = Date()
        if db.jobs[i].startedAt == nil {
            db.jobs[i].startedAt = now                 // 화면에서 처음 확인할 때부터 진행한다
            dirty = true
        }
        if !db.jobs[i].finished, let s = db.jobs[i].startedAt, now.timeIntervalSince(s) >= db.jobs[i].duration {
            complete(i)
        }
        let job = db.jobs[i]
        let elapsed = now.timeIntervalSince(job.startedAt ?? now)
        let ratio = min(max(elapsed / max(job.duration, 1), 0), 1)
        let status = job.finished ? "COMPLETED" : (elapsed < 1 ? "QUEUED" : "RUNNING")
        let progress = job.finished ? 100 : min(99, (ratio * 100).rounded())
        return ok(AIJob(jobId: job.jobId, status: status, progress: progress,
                        message: Self.jobMessage(job.kind, ratio: ratio, done: job.finished), roomStateId: job.roomStateId))
    }

    private static func jobMessage(_ kind: String, ratio: Double, done: Bool) -> String {
        if done { return "완료" }
        switch kind {
        case "SPACE":
            if ratio < 0.15 { return "프레임 정리 중" }
            if ratio < 0.4 { return "카메라 위치 보정 중" }
            if ratio < 0.85 { return "3D 공간 학습 중" }
            return "벽 · 문 · 가구 인식 중"
        case "ROOM_STATE":
            return ratio < 0.5 ? "개인 가구 제거 중" : "빈 공간 복원 중"
        default:
            return "가구 3D 모델 만드는 중"
        }
    }

    // MARK: - 로그인 · 중개사 인증

    private func login(provider: String, _ q: [String: String]) -> Out {
        let email = (q["email"] ?? "").trimmed.lowercased()
        let name = q["name"]?.trimmed
        let key = email.isEmpty ? (name ?? "guest") : email
        let userId = Self.stableUserId(key)
        db.users[userId] = MockUser(name: name, email: email.isEmpty ? nil : email, provider: provider)
        dirty = true
        return ok(AuthResponse(userId: userId, name: name, email: email.isEmpty ? nil : email, accessToken: "demo-\(userId)"))
    }

    // MARK: 명세 방식 로그인 (이메일 · 비밀번호, 카카오 · 구글 토큰, 토큰 갱신)

    private struct DemoUser: Encodable {
        var userId: String
        var email: String?
        var displayName: String
        var roles: [String]
    }

    private struct DemoTokenPair: Encodable {
        var accessToken: String
        var refreshToken: String
        var tokenType = "Bearer"
        var expiresIn = 900
        var refreshExpiresIn = 1_209_600
        var user: DemoUser
    }

    private func demoUser(_ userId: String) -> DemoUser {
        let u = db.users[userId]
        let roles = db.profiles[userId]?.profile.isApproved == true ? ["TENANT", "BROKER"] : ["TENANT"]
        return DemoUser(userId: userId, email: u?.email, displayName: u?.name ?? "회원", roles: roles)
    }

    /// 데모 토큰: "demo-access-<userId>-<n>" / "demo-refresh-<userId>-<n>" (데모 백엔드는 X-User-Id 로 사용자를 구분한다)
    private func tokenPair(_ userId: String) -> Out {
        let n = nextId()
        return ok(DemoTokenPair(accessToken: "demo-access-\(userId)-\(n)", refreshToken: "demo-refresh-\(userId)-\(n)",
                                user: demoUser(userId)))
    }

    private static func passwordHash(_ email: String, _ password: String) -> String {
        SHA256.hash(data: Data("dulleobang-demo|\(email)|\(password)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func signup(_ body: Data?) -> Out {
        guard let req = decodeBody(SignupRequest.self, body) else { return fail(400, "가입 정보를 읽지 못했습니다") }
        let email = req.email.trimmed.lowercased()
        guard email.contains("@") else { return fail(422, "이메일 형식이 올바르지 않습니다") }
        guard (12...128).contains(req.password.count) else { return fail(422, "비밀번호는 12자 이상 128자 이하로 입력해 주세요") }
        let name = req.displayName.trimmed
        guard !name.isEmpty else { return fail(422, "이름을 입력해 주세요") }
        let userId = Self.stableUserId("email:" + email)           // 같은 이메일의 카카오 · 구글 계정과 자동으로 합치지 않는다
        if db.users[userId]?.passwordHash != nil { return fail(409, "이미 가입된 이메일입니다 (EMAIL_ALREADY_EXISTS)") }
        db.users[userId] = MockUser(name: name, email: email, provider: "email", passwordHash: Self.passwordHash(email, req.password))
        dirty = true
        return ok(demoUser(userId), status: 201)
    }

    private func emailLogin(_ body: Data?) -> Out {
        guard let req = decodeBody(LoginRequest.self, body) else { return fail(400, "로그인 정보를 읽지 못했습니다") }
        let email = req.email.trimmed.lowercased()
        let userId = Self.stableUserId("email:" + email)
        guard let hash = db.users[userId]?.passwordHash, hash == Self.passwordHash(email, req.password) else {
            return fail(401, "이메일 또는 비밀번호가 맞지 않습니다 (INVALID_CREDENTIALS)")
        }
        return tokenPair(userId)
    }

    /// 실제 서버는 카카오 · 구글에 토큰을 검증한다. 데모는 "demo:이메일:이름" 토큰을 받는다 (예전 데모 로그인과 같은 사용자 ID)
    private func oauthLogin(provider: String, _ body: Data?) -> Out {
        guard ["kakao", "google"].contains(provider) else { return fail(404, "지원하지 않는 로그인입니다") }
        var fields: [String: String] = [:]
        if let body, let obj = try? JSONSerialization.jsonObject(with: body) as? [String: String] { fields = obj }
        guard let token = fields["accessToken"] ?? fields["idToken"], !token.isEmpty else {
            return fail(400, "로그인 토큰이 없습니다")
        }
        let parts = token.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        let email = parts.count > 1 ? parts[1].trimmed.lowercased() : ""
        let name = parts.count > 2 ? parts[2].trimmed : ""
        let userId = Self.stableUserId(email.isEmpty ? "\(provider):\(token)" : email)
        let old = db.users[userId]
        db.users[userId] = MockUser(name: name.isEmpty ? old?.name : name, email: email.isEmpty ? old?.email : email,
                                    provider: provider, passwordHash: old?.passwordHash)
        dirty = true
        return tokenPair(userId)
    }

    private func refreshTokens(_ body: Data?) -> Out {
        let prefix = "demo-refresh-"
        guard let token = decodeBody(RefreshRequest.self, body)?.refreshToken, token.hasPrefix(prefix),
              let userId = token.dropFirst(prefix.count).split(separator: "-").first.map(String.init),
              db.users[userId] != nil else {
            return fail(401, "다시 로그인해 주세요 (INVALID_REFRESH_TOKEN)")
        }
        return tokenPair(userId)
    }

    /// 같은 이메일이면 항상 같은 사용자 ID (FNV-1a)
    static func stableUserId(_ key: String) -> String {
        var h: UInt32 = 2_166_136_261
        for b in key.utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
        return String(10_000 + Int(h % 90_000))
    }

    private func getProfile(_ uid: String) -> Out {
        guard let p = db.profiles[uid] else { return fail(404, "중개사 인증 정보가 없습니다") }
        return ok(p.profile)
    }

    private func applyAgent(_ uid: String, _ parts: [MultipartPart]) -> Out {
        var fields: [String: String] = [:]
        var document: Data?
        var fileName: String?
        for part in parts {
            switch part {
            case .field(let name, let value):
                fields[name] = value.trimmed
            case .file(let name, let filename, _, let data):
                if name == "document" { document = data; fileName = filename }
            }
        }
        guard let name = fields["name"], !name.isEmpty, let license = fields["licenseNumber"], !license.isEmpty,
              let office = fields["officeName"], !office.isEmpty, let document else {
            return fail(400, "이름 · 중개사 번호 · 사무소명 · 사업자 등록증을 모두 입력해 주세요")
        }
        let uri = saveFile(document, as: "agents/\(uid)/document.jpg")
        let now = Date()
        let profile = AgentProfile(status: "PENDING", name: name, licenseNumber: license, officeName: office,
                                   documentName: fields["documentName"] ?? fileName, documentUri: uri,
                                   requestedAt: Self.iso(now), verifiedAt: nil, rejectReason: nil)
        db.profiles[uid] = MockProfile(profile: profile, approveAt: now.addingTimeInterval(3))
        dirty = true
        return ok(profile)
    }

    private func isBroker(_ uid: String) -> Bool {
        if db.profiles[uid]?.profile.isApproved == true { return true }
        return UserDefaults.standard.bool(forKey: "localAgent")        // 설정 › 중개사 모드 (개발용)
    }

    private static func localAgentProfile() -> AgentProfile? {
        guard UserDefaults.standard.bool(forKey: "localAgent"),
              let data = UserDefaults.standard.data(forKey: "agentProfile") else { return nil }
        return try? JSONDecoder().decode(AgentProfile.self, from: data)
    }

    // MARK: - 매물

    private func listingIndex(_ id: String) -> Int? { db.listings.firstIndex { $0.listing.listingId == id } }

    private func sortedListings() -> [MockListing] {
        db.listings.enumerated()
            .sorted { a, b in
                let ra = a.element.rank ?? 0, rb = b.element.rank ?? 0
                return ra != rb ? ra < rb : a.offset < b.offset
            }
            .map { $0.element }
    }

    private func ownerId(_ m: MockListing, _ uid: String) -> String {
        guard m.ownerId == "me" else { return m.ownerId }
        return isBroker(uid) ? uid : (m.fallbackOwnerId ?? db.agents.first?.userId ?? "")
    }

    private func agentSummary(_ ownerId: String, _ uid: String) -> AgentSummary {
        if let a = db.agents.first(where: { $0.userId == ownerId }) {
            return AgentSummary(userId: a.userId, name: a.name, officeName: a.officeName, phone: a.phone, isVerifiedBroker: true)
        }
        // 중개사 인증을 받은 사람이면 사무소 · 연락처와 인증 표시, 아니면 집주인 직접 등록 (연락처는 공개하지 않음)
        let verified = ownerId == uid ? isBroker(uid) : db.profiles[ownerId]?.profile.isApproved == true
        let profile = verified ? (db.profiles[ownerId]?.profile ?? (ownerId == uid ? Self.localAgentProfile() : nil)) : nil
        return AgentSummary(userId: ownerId, name: profile?.name ?? db.users[ownerId]?.name ?? "나",
                            officeName: profile?.officeName, phone: verified ? "010-0000-0000" : nil,
                            isVerifiedBroker: verified)
    }

    /// 응답용 매물: 담당 중개사 · 관심 여부를 채운다
    private func view(_ m: MockListing, _ uid: String) -> Listing {
        var l = m.listing
        l.agent = agentSummary(ownerId(m, uid), uid)
        l.isScrapped = scrapIds(uid).contains(l.listingId)
        return l
    }

    private func search(_ q: [String: String], _ uid: String) -> [Listing] {
        var query = ListingQuery()
        query.text = q["location"]
        query.dealType = q["dealType"]
        query.roomType = q["roomType"]
        query.maxDeposit = q["maxDeposit"].flatMap { Int($0) }
        query.maxMonthly = q["maxPrice"].flatMap { Int($0) }
        var bounds: GeoBounds?
        if let a = q["minLat"].flatMap({ Double($0) }), let b = q["maxLat"].flatMap({ Double($0) }),
           let c = q["minLng"].flatMap({ Double($0) }), let d = q["maxLng"].flatMap({ Double($0) }) {
            bounds = GeoBounds(minLat: a, maxLat: b, minLng: c, maxLng: d)
        }
        return sortedListings().map { view($0, uid) }.filter { l in
            guard query.matches(l) else { return false }
            guard let bounds, let lat = l.latitude, let lng = l.longitude else { return true }
            return bounds.contains(lat: lat, lng: lng)
        }
    }

    private func getListing(_ id: String, _ uid: String) -> Out {
        guard let i = listingIndex(id) else { return fail(404, "매물을 찾을 수 없습니다") }
        return ok(view(db.listings[i], uid))
    }

    private func myListings(_ uid: String) -> [Listing] {
        sortedListings().filter { ownerId($0, uid) == uid }.map { view($0, uid) }
    }

    private func createListing(_ body: Data?, _ uid: String) -> Out {
        guard let req = decodeBody(CreateListingRequest.self, body) else { return fail(400, "매물 정보를 읽지 못했습니다") }
        let id = nextId()
        var lat = req.latitude, lng = req.longitude
        if lat == nil || lng == nil {
            let c = Self.guessCoordinate(req.location, salt: Int(id) ?? 0)     // 지오코딩 실패(오프라인) 대비
            lat = c.lat
            lng = c.lng
        }
        let listing = Listing(listingId: id, location: req.location, price: req.price, dealType: req.dealType,
                              maintenanceFee: req.maintenanceFee, roomType: req.roomType, floor: req.floor,
                              totalFloors: req.totalFloors, area: req.area, supplyArea: req.supplyArea, rooms: req.rooms,
                              bathrooms: req.bathrooms, availableFrom: req.availableFrom, rentalOptions: req.rentalOptions,
                              thumbnailUri: nil, imageUris: [], latitude: lat, longitude: lng, livingEnvironment: nil,
                              agent: nil, isScrapped: nil, space3DInfo: Space3DInfo(status: "NONE"))
        db.listings.insert(MockListing(listing: listing, ownerId: uid, fallbackOwnerId: nil, rank: 0), at: 0)
        dirty = true
        return ok(["listingId": id], status: 201)
    }

    /// 주소에 동 이름이 있으면 그 근처에 찍는다 (같은 자리에 겹치지 않게 조금 흩뜨림)
    private static func guessCoordinate(_ address: String, salt: Int) -> (lat: Double, lng: Double) {
        let centers: [(key: String, lat: Double, lng: Double)] = [
            ("흑석", 37.5078, 126.9625), ("상도", 37.5020, 126.9500), ("노량진", 37.5118, 126.9460),
            ("본동", 37.5108, 126.9545), ("대방", 37.5100, 126.9290), ("사당", 37.4850, 126.9810),
        ]
        let base = centers.first { address.contains($0.key) } ?? (key: "", lat: 37.5051, lng: 126.9571)
        let jx = Double((salt * 37) % 21 - 10) * 0.00015
        let jy = Double((salt * 53) % 21 - 10) * 0.00012
        return (base.lat + jy, base.lng + jx)
    }

    private func uploadImages(_ id: String, _ parts: [MultipartPart]) -> Out {
        guard let i = listingIndex(id) else { return fail(404, "매물을 찾을 수 없습니다") }
        var uris = db.listings[i].listing.imageUris ?? []
        let batch = nextId()
        var n = 0
        for part in parts {
            guard case .file(let name, _, _, let data) = part, name == "images" else { continue }
            n += 1
            if let uri = saveFile(data, as: "listings/\(id)/\(batch)_\(n).jpg") { uris.append(uri) }
        }
        db.listings[i].listing.imageUris = uris
        if db.listings[i].listing.thumbnailUri == nil { db.listings[i].listing.thumbnailUri = uris.first }
        dirty = true
        return okEmpty()
    }

    private func setScrap(_ id: String, on: Bool, _ uid: String) -> Out {
        guard listingIndex(id) != nil else { return fail(404, "매물을 찾을 수 없습니다") }
        var ids = scrapIds(uid)
        ids.removeAll { $0 == id }
        if on { ids.insert(id, at: 0) }
        db.scraps[uid] = ids
        dirty = true
        return okEmpty()
    }

    private func scrapIds(_ uid: String) -> [String] { db.scraps[uid] ?? db.defaultScraps }

    private func scrapList(_ uid: String) -> [Listing] {
        scrapIds(uid).compactMap { id in listingIndex(id).map { view(db.listings[$0], uid) } }
    }

    // MARK: - 3D 공간 · 입주 상태 · 배치

    private func uploadSpaceCapture(_ id: String, _ zip: URL?) -> Out {
        guard let i = listingIndex(id) else { return fail(404, "매물을 찾을 수 없습니다") }
        let capture = Self.readCapture(zip)
        var space = capture.space ?? Self.genericSpace(listingId: id, area: db.listings[i].listing.area)
        // 다시 촬영하면 새 공간 버전. 예전 버전으로 만든 입주 상태는 앱이 건너뛴다 (명세: isStale)
        space.spaceVersion = (db.spaces[id]?.spaceVersion ?? 0) + 1
        space.objectsVersion = 1
        db.spaces[id] = space
        if (db.listings[i].listing.imageUris ?? []).isEmpty, let frame = capture.frame,
           let uri = saveFile(frame, as: "listings/\(id)/capture_\(nextId()).jpg") {
            db.listings[i].listing.imageUris = [uri]          // 사진 없이 등록했으면 촬영 프레임을 대표 사진으로
            db.listings[i].listing.thumbnailUri = uri
        }
        let job = newJob(kind: "SPACE", target: id, duration: 20)
        db.listings[i].listing.space3DInfo = Space3DInfo(status: "RUNNING", jobId: job.jobId)
        return ok(Accepted(jobId: job.jobId, status: "QUEUED"), status: 202)
    }

    /// 가구 구분: 매물을 올린 중개사만 (명세 v1). 하나라도 잘못되면 아무것도 바꾸지 않는다
    private func patchObjects(_ id: String, _ r: MockRequest, _ uid: String) -> Out {
        guard let li = listingIndex(id) else { return fail(404, "매물을 찾을 수 없습니다") }
        guard var space = db.spaces[id] else { return fail(404, "아직 3D 공간이 없는 매물입니다") }
        guard ownerId(db.listings[li], uid) == uid else { return fail(403, "매물을 올린 사람만 가구를 구분할 수 있습니다") }
        // 명세 v1: 직전에 본 구분 버전을 If-Match 로 보내야 한다 (없으면 428, 그 사이 바뀌었으면 412)
        guard let tag = r.header("If-Match") else { return fail(428, "If-Match 헤더가 필요합니다 (가구 구분 버전)") }
        guard tag == Self.etag(space.objectsVersion ?? 1) else {
            return fail(412, "그 사이 가구 구분이 바뀌었습니다. 다시 불러와 주세요")
        }
        guard let patch = decodeBody(ObjectOwnershipPatch.self, r.body) else { return fail(400, "요청 형식이 올바르지 않습니다") }
        let allowed: Set<String> = ["PERSONAL", "RENTAL_OPTION", "UNKNOWN"]
        var changed = false
        for item in patch.objects {
            guard let k = space.objects.firstIndex(where: { $0.objectId == item.objectId }) else {
                return fail(422, "이 공간에 없는 가구입니다: \(item.objectId)")
            }
            let type = item.ownershipType ?? "UNKNOWN"
            guard allowed.contains(type) else { return fail(422, "가구 구분 값이 올바르지 않습니다: \(type)") }
            let stored: String? = type == "UNKNOWN" ? nil : type          // 데모 데이터는 미분류를 null 로 둔다
            if space.objects[k].ownershipType != stored {
                space.objects[k].ownershipType = stored
                changed = true
            }
        }
        if changed {
            space.objectsVersion = (space.objectsVersion ?? 1) + 1
            db.spaces[id] = space
            dirty = true
        }
        return ok(["objectsVersion": space.objectsVersion ?? 1], headers: ["ETag": Self.etag(space.objectsVersion ?? 1)])
    }

    /// 가구 빼 보기: 요청한 사람만 보는 입주 상태를 만든다 (명세 v1).
    /// 뺄 가구는 1개 이상, 모두 중개사가 개인 가구로 구분한 것이어야 하고, 보낸 버전이 지금 공간과 같아야 한다
    private func createRoomState(_ id: String, _ body: Data?, _ uid: String) -> Out {
        guard listingIndex(id) != nil else { return fail(404, "매물을 찾을 수 없습니다") }
        guard let space = db.spaces[id] else { return fail(409, "아직 3D 공간이 없는 매물입니다") }
        guard let req = decodeBody(RoomStateRequest.self, body) else { return fail(400, "요청 형식이 올바르지 않습니다") }
        if let v = req.sourceSpaceVersion, v != (space.spaceVersion ?? 1) {
            return fail(409, "공간이 다시 촬영됐습니다. 새로 불러온 뒤 다시 골라 주세요")
        }
        if let v = req.sourceObjectsVersion, v != (space.objectsVersion ?? 1) {
            return fail(409, "중개사가 가구 구분을 바꿨습니다. 새로 불러온 뒤 다시 골라 주세요")
        }
        let ids = req.removedObjectIds
        guard !ids.isEmpty else { return fail(422, "뺄 가구를 하나 이상 골라 주세요") }
        guard Set(ids).count == ids.count else { return fail(422, "같은 가구가 두 번 들어 있습니다") }
        for oid in ids {
            guard let o = space.objects.first(where: { $0.objectId == oid }) else {
                return fail(422, "이 공간에 없는 가구입니다: \(oid)")
            }
            guard o.canRemove else {
                return fail(422, "개인 가구로 구분된 가구만 뺄 수 있습니다 (\(Fmt.objectLabel(o.category)))")
            }
        }
        let rsId = "RS\(nextId())"
        let job = newJob(kind: "ROOM_STATE", target: id, duration: 6, roomStateId: rsId, removed: ids)
        db.roomStates[rsId] = RoomState(roomStateId: rsId, listingId: id, createdBy: uid, status: "PROCESSING",
                                        jobId: job.jobId, sourceSpaceVersion: space.spaceVersion ?? 1,
                                        sourceObjectsVersion: space.objectsVersion ?? 1, createdAt: Self.iso(Date()),
                                        removedObjectIds: ids)
        dirty = true
        return ok(Accepted(jobId: job.jobId, status: "QUEUED", roomStateId: rsId), status: 202)
    }

    /// 입주 상태를 만든 사람. 시드의 "me" 는 로그인한 사용자 (데모에서 처음부터 가지고 있는 입주 상태)
    private func roomStateOwner(_ rs: RoomState, _ uid: String) -> String? {
        rs.createdBy == "me" ? uid : rs.createdBy
    }

    private func visibleRoomState(_ id: String, _ uid: String) -> RoomState? {
        guard var rs = db.roomStates[id], roomStateOwner(rs, uid) == uid else { return nil }
        rs.createdBy = uid
        return rs
    }

    /// 이 매물에서 내가 만든 입주 상태, 최근 것이 앞
    private func myRoomStates(_ listingId: String, _ uid: String) -> [RoomState] {
        db.roomStates.values
            .filter { $0.listingId == listingId && roomStateOwner($0, uid) == uid }
            .sorted { a, b in
                let ta = a.createdAt ?? "", tb = b.createdAt ?? ""
                return ta != tb ? ta > tb : Self.seqNumber(a.roomStateId) > Self.seqNumber(b.roomStateId)
            }
            .map { rs in
                var mine = rs
                mine.createdBy = uid
                return mine
            }
    }

    private func deleteRoomState(_ id: String, _ uid: String) -> Out {
        guard let rs = db.roomStates[id], roomStateOwner(rs, uid) == uid else { return fail(404, "입주 상태를 찾을 수 없습니다") }
        db.roomStates[id] = nil
        dirty = true
        return Out(status: 204, data: Data())
    }

    private static func seqNumber(_ id: String?) -> Int { Int(String((id ?? "").filter(\.isNumber))) ?? 0 }

    /// 목록 응답 (명세의 {items, page} 형식)
    private struct Page<T: Encodable>: Encodable {
        var items: [T]
        var page = PageInfo()
        struct PageInfo: Encodable { var hasNext = false }
    }

    /// 명세 v1: 첫 저장은 If-None-Match: *, 그다음부터는 If-Match (둘 다 없으면 428, 안 맞으면 412)
    private func savePlacements(_ id: String, _ r: MockRequest, _ uid: String) -> Out {
        let key = "\(uid)|\(id)"
        let current = db.placementVersions?[key]
        switch (r.header("If-Match"), r.header("If-None-Match")) {
        case (.some, .some):
            return fail(400, "If-Match 와 If-None-Match 를 함께 보낼 수 없습니다")
        case (nil, .some(let none)):
            guard none == "*" else { return fail(400, "If-None-Match 는 * 만 쓸 수 있습니다") }
            if current != nil { return fail(412, "이미 저장한 배치가 있습니다 (RESOURCE_ALREADY_EXISTS)") }
        case (.some(let tag), nil):
            guard let current, tag == Self.etag(current) else {
                return fail(412, "다른 곳에서 먼저 저장한 배치가 있습니다. 다시 불러온 뒤 저장해 주세요")
            }
        case (nil, nil):
            return fail(428, "If-Match 또는 If-None-Match 헤더가 필요합니다")
        }
        guard let req = decodeBody(PlacementsRequest.self, r.body) else { return fail(400, "요청 형식이 올바르지 않습니다") }
        let version = (current ?? 0) + 1
        db.placements[key] = req.placements
        var versions = db.placementVersions ?? [:]
        versions[key] = version
        db.placementVersions = versions
        dirty = true
        return ok(PlacementsResponse(placementSetId: "P\(nextId())", savedAt: Self.iso(Date()), placements: req.placements),
                  headers: ["ETag": Self.etag(version)])
    }

    /// 촬영 폴더(capture.zip 옆의 capture/)에서 RoomPlan 구조와 대표 프레임을 읽는다.
    /// 업로드 직후 촬영 폴더가 지워지므로 요청을 처리하는 동안 바로 읽는다.
    private static func readCapture(_ zip: URL?) -> (space: SpaceResponse?, frame: Data?) {
        guard let zip else { return (nil, nil) }
        let dir = zip.deletingLastPathComponent().appendingPathComponent("capture", isDirectory: true)
        var space: SpaceResponse?
        if let data = try? Data(contentsOf: dir.appendingPathComponent("roomplan_structure.json")),
           let s = try? JSONDecoder().decode(CapturedStructure.self, from: data),
           let g = s.roomGeometry, !g.walls.isEmpty {
            space = SpaceResponse(threeDgsUri: nil, pointsUri: nil, roomGeometry: g, roomDimensions: s.roomDimensions,
                                  objects: s.objects ?? [], collisionGeometryUri: nil)
        }
        let framesDir = dir.appendingPathComponent("frames", isDirectory: true)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: framesDir.path)) ?? [])
            .filter { $0.lowercased().hasSuffix(".jpg") }
            .sorted()
        var frame: Data?
        if !names.isEmpty, let raw = try? Data(contentsOf: framesDir.appendingPathComponent(names[names.count / 2])) {
            frame = uprightJPEG(raw) ?? raw
        }
        return (space, frame)
    }

    private struct CapturedStructure: Decodable {
        var roomGeometry: RoomGeometry?
        var roomDimensions: RoomDimensions?
        var objects: [SceneObject]?
    }

    /// 촬영 프레임은 센서 원래 방향(가로)으로 저장돼 있어 세로로 든 휴대폰 기준으로 돌려서 줄인다
    private static func uprightJPEG(_ data: Data, maxPixel: CGFloat = 1280) -> Data? {
        #if canImport(UIKit)
        guard let cg = UIImage(data: data)?.cgImage else { return nil }
        let size = CGSize(width: CGFloat(cg.height), height: CGFloat(cg.width))
        let scale = min(1, maxPixel / max(size.width, size.height, 1))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            UIImage(cgImage: cg, scale: 1, orientation: .right).draw(in: CGRect(origin: .zero, size: target))
        }
        return image.jpegData(compressionQuality: 0.82)
        #else
        return nil
        #endif
    }

    /// RoomPlan 구조가 없는 촬영본(LiDAR 없는 기기): 전용면적으로 직사각형 방을 만든다
    static func genericSpace(listingId id: String, area: Double?) -> SpaceResponse {
        let floorArea = max(10, min(40, (area ?? 20) - 3.3))          // 욕실을 뺀 방 면적
        let w = ((floorArea / 1.35).squareRoot() * 10).rounded() / 10
        let d = ((floorArea / w) * 10).rounded() / 10
        let l = -w / 2, r = w / 2, b = -d / 2, f = d / 2, h = 2.4
        let walls = [
            Wall(id: "\(id)-wall-back", from: [l, b], to: [r, b], height: h),
            Wall(id: "\(id)-wall-right", from: [r, b], to: [r, f], height: h),
            Wall(id: "\(id)-wall-front", from: [r, f], to: [l, f], height: h),
            Wall(id: "\(id)-wall-left", from: [l, f], to: [l, b], height: h),
        ]
        let door = Opening(id: "\(id)-door", type: "door", position: Vec3(x: r - 0.55, y: 1.05, z: f),
                           rotation: Rotation(yaw: 0), dimensions: Dimensions(width: 0.9, height: 2.1, depth: 0.1))
        let window = Opening(id: "\(id)-window", type: "window", position: Vec3(x: 0, y: 1.5, z: b),
                             rotation: Rotation(yaw: 0), dimensions: Dimensions(width: 1.4, height: 1.1, depth: 0.1))
        let geometry = RoomGeometry(floorHeight: 0, ceilingHeight: h, walls: walls, doors: [door], windows: [window],
                                    boundingBox: BoundingBox(min: Vec3(x: l, y: 0, z: b), max: Vec3(x: r, y: h, z: f)))
        return SpaceResponse(threeDgsUri: nil, pointsUri: nil, roomGeometry: geometry,
                             roomDimensions: RoomDimensions(width: w, depth: d, height: h, area: w * d),
                             objects: [], collisionGeometryUri: nil)
    }

    // MARK: - 가구

    /// 뷰어가 상자 모양 가구를 그리라는 뜻의 modelUri (GLB 없이)
    static let boxModel = "box"

    static func defaultDimensions(_ category: String?) -> Dimensions {
        switch category {
        case "bed": return Dimensions(width: 1.1, height: 0.9, depth: 2.05)
        case "desk": return Dimensions(width: 1.2, height: 0.74, depth: 0.6)
        case "sofa": return Dimensions(width: 1.6, height: 0.85, depth: 0.85)
        case "closet": return Dimensions(width: 0.9, height: 1.9, depth: 0.55)
        case "storage": return Dimensions(width: 0.8, height: 1.0, depth: 0.4)
        case "chair": return Dimensions(width: 0.5, height: 0.9, depth: 0.5)
        default: return Dimensions(width: 0.8, height: 0.8, depth: 0.8)
        }
    }

    static func defaultThumbnail(_ category: String?) -> String? {
        guard let c = category, ["bed", "desk", "closet", "sofa"].contains(c) else { return nil }
        return "bundle://Mock/F_\(c).jpg"
    }

    private func myFurniture(_ uid: String) -> [Furniture] {
        let mine = db.furniture.filter { $0.ownerId == uid }.reversed().map(\.furniture)
        let shared = db.furniture.filter { $0.ownerId == nil }.map(\.furniture)
        return mine + shared
    }

    private func createFurniture(_ body: Data?, _ uid: String) -> Out {
        guard let req = decodeBody(CreateFurnitureRequest.self, body) else { return fail(400, "가구 정보를 읽지 못했습니다") }
        let id = nextId()
        let f = Furniture(furnitureId: id, name: req.name, category: req.category, status: "PENDING", modelUri: nil,
                          dimensions: nil, boundingBox: nil, collisionMeshUri: nil, thumbnailUri: nil)
        db.furniture.append(MockFurniture(furniture: f, ownerId: uid))
        dirty = true
        return ok(["furnitureId": id], status: 201)
    }

    private func uploadFurnitureCapture(_ id: String, _ zip: URL?) -> Out {
        guard let fi = db.furniture.firstIndex(where: { $0.furniture.furnitureId == id }) else {
            return fail(404, "가구를 찾을 수 없습니다")
        }
        if let frame = Self.readCapture(zip).frame, let uri = saveFile(frame, as: "furniture/\(id)/thumb.jpg") {
            db.furniture[fi].furniture.thumbnailUri = uri
        }
        db.furniture[fi].furniture.status = "RUNNING"
        let job = newJob(kind: "FURNITURE", target: id, duration: 12)
        return ok(Accepted(jobId: job.jobId, status: "QUEUED"), status: 202)
    }

    // MARK: - 채팅

    private func visibleChats(_ uid: String) -> [Int] {
        db.chats.indices.filter { db.chats[$0].userId == nil || db.chats[$0].userId == uid }
    }

    private func chatListing(_ l: Listing) -> ChatListing {
        ChatListing(listingId: l.listingId, price: l.price, dealType: l.dealType, location: l.location,
                    roomType: l.roomType, floor: l.floor, thumbnailUri: l.coverUri)
    }

    /// 채팅 상대 = 매물 담당 중개사
    private func counterpart(_ listingId: String, _ uid: String) -> AgentSummary? {
        guard let i = listingIndex(listingId) else { return nil }
        return agentSummary(ownerId(db.listings[i], uid), uid)
    }

    private func chatSummaries(_ uid: String) -> [ChatRoomSummary] {
        visibleChats(uid)
            .map { db.chats[$0] }
            .sorted { ($0.messages.last?.at ?? .distantPast) > ($1.messages.last?.at ?? .distantPast) }
            .map { c -> ChatRoomSummary in
                let l = listingIndex(c.listingId).map { view(db.listings[$0], uid) }
                return ChatRoomSummary(chatId: c.chatId, listing: l.map { chatListing($0) },
                                       counterpartName: counterpart(c.listingId, uid)?.name,
                                       lastMessage: c.messages.last?.text,
                                       lastMessageAt: c.messages.last.map { Self.iso($0.at) },
                                       unreadCount: c.unread)
            }
    }

    private func chatDetail(_ chatId: String, _ uid: String) -> Out {
        guard let i = visibleChats(uid).first(where: { db.chats[$0].chatId == chatId }) else {
            return fail(404, "채팅방을 찾을 수 없습니다")
        }
        if db.chats[i].unread != 0 {
            db.chats[i].unread = 0
            dirty = true
        }
        let c = db.chats[i]
        let agent = counterpart(c.listingId, uid)
        let myName = db.users[uid]?.name ?? "나"
        let messages = c.messages.map { m in
            ChatMessage(messageId: m.id, senderId: m.fromMe ? uid : agent?.userId, senderName: m.fromMe ? myName : agent?.name,
                        message: m.text, sentAt: Self.iso(m.at))
        }
        let l = listingIndex(c.listingId).map { view(db.listings[$0], uid) }
        return ok(ChatRoomDetail(chatId: c.chatId, listing: l.map { chatListing($0) }, counterpartName: agent?.name,
                                 officeName: agent?.officeName, messages: messages))
    }

    private func openChat(_ body: Data?, _ uid: String) -> Out {
        guard let req = decodeBody(OpenChatRequest.self, body) else { return fail(400, "요청 형식이 올바르지 않습니다") }
        guard let li = listingIndex(req.listingId) else { return fail(404, "매물을 찾을 수 없습니다") }
        if let i = visibleChats(uid).first(where: { db.chats[$0].listingId == req.listingId }) {
            return ok(["chatId": db.chats[i].chatId])
        }
        let l = db.listings[li].listing
        let agent = counterpart(req.listingId, uid)
        let who = [agent?.officeName, agent?.name].compactMap { $0 }.joined(separator: " ")
        let place = [Fmt.shortLocation(l.location), Fmt.roomType(l.roomType)].filter { !$0.isEmpty }.joined(separator: " ")
        let greeting = "안녕하세요, \(who.isEmpty ? "담당 중개사" : who)입니다. \(place) 매물 문의 주셔서 감사합니다. 궁금한 점 편하게 물어보세요."
        let chatId = "C\(nextId())"
        let hello = MockMessage(id: "\(chatId)-1", fromMe: false, text: greeting, at: Date())
        db.chats.append(MockChat(chatId: chatId, listingId: req.listingId, userId: uid, unread: 0,
                                 messages: [hello], pendingReplies: []))
        dirty = true
        return ok(["chatId": chatId], status: 201)
    }

    private func sendMessage(_ chatId: String, _ body: Data?, _ uid: String) -> Out {
        guard let i = visibleChats(uid).first(where: { db.chats[$0].chatId == chatId }) else {
            return fail(404, "채팅방을 찾을 수 없습니다")
        }
        guard let text = decodeBody(SendMessageRequest.self, body)?.message.trimmed, !text.isEmpty else {
            return fail(400, "메시지가 비어 있습니다")
        }
        let now = Date()
        let listing = listingIndex(db.chats[i].listingId).map { db.listings[$0].listing }
        db.chats[i].messages.append(MockMessage(id: "m\(nextId())", fromMe: true, text: text, at: now))
        db.chats[i].pendingReplies.append(MockMessage(id: "m\(nextId())", fromMe: false,
                                                      text: Self.autoReply(to: text, listing: listing),
                                                      at: now.addingTimeInterval(2.5)))
        dirty = true
        return okEmpty()
    }

    /// 데모용 중개사 자동 답장 (메시지의 낱말로 고른다)
    static func autoReply(to text: String, listing: Listing?) -> String {
        let t = text.replacingOccurrences(of: " ", with: "")
        func has(_ words: [String]) -> Bool { words.contains { t.contains($0) } }
        let options = listing?.rentalOptions ?? []
        if has(["방문", "보러", "구경", "볼수", "가봐", "가도"]) {
            return "네, 평일 저녁이나 토요일 오후 모두 괜찮아요. 편한 시간을 알려 주시면 맞춰 둘게요."
        }
        if has(["관리비", "인터넷", "공과금", "수도"]) {
            if let fee = listing?.maintenanceFee {
                return fee == 0 ? "관리비는 따로 없고, 전기·가스만 사용한 만큼 나와요."
                    : "관리비는 월 \(fee)만 원이고 인터넷·수도가 포함이에요. 전기·가스는 사용한 만큼 따로 나옵니다."
            }
            return "관리비는 집주인분께 확인해서 바로 알려 드릴게요."
        }
        if has(["주차", "차량", "자동차"]) {
            return options.contains("parking") ? "주차 가능한 매물이에요. 1대 기준으로 무료입니다."
                : "아쉽지만 전용 주차 공간은 없어요. 근처 공영주차장을 이용하셔야 해요."
        }
        if has(["반려", "강아지", "고양이", "펫"]) {
            return options.contains("pet") ? "소형 반려동물은 가능해요. 계약서에 특약으로 넣어 드립니다."
                : "반려동물은 집주인분께 한 번 여쭤보고 알려 드릴게요."
        }
        if has(["대출", "전세자금", "보증보험", "보증금반환"]) {
            return "전세자금대출과 보증보험 가입이 가능한 매물이에요. 필요한 서류는 계약 전에 정리해서 보내 드릴게요."
        }
        if has(["입주", "이사", "날짜", "언제부터"]) {
            let when = Fmt.available(listing?.availableFrom)
            return when == "즉시" ? "바로 입주 가능해요. 이사 날짜는 편하신 대로 맞춰 드릴게요."
                : "\(when)부터 입주 가능해요. 날짜는 조금 조율할 수 있습니다."
        }
        if has(["3D", "가구", "배치", "치수", "크기"]) {
            return "앱의 ‘내 가구 놓아보기’로 가구가 들어가는지 먼저 확인해 보세요. 실제 치수로 측정한 공간이에요."
        }
        if has(["깎", "네고", "조정", "할인", "비싸"]) {
            return "보증금은 조금 조정할 수 있어요. 방문하실 때 같이 이야기 나눠요."
        }
        if has(["감사", "고마", "알겠", "좋아요", "네"]) {
            return "네, 궁금한 점 있으시면 언제든 편하게 연락 주세요!"
        }
        return "네, 확인해 보고 바로 답변드릴게요."
    }
}
