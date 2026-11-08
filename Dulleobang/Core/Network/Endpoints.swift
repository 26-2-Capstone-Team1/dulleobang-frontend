import Foundation

// 엔드포인트를 한곳에 모은다. 백엔드와 경로/응답 형태가 다르면 여기만 고친다.
// 백엔드에 아직 없는 API(404/405/501)는 호출하는 쪽에서 로컬 동작으로 대신한다 (isMissingEndpoint).

/// 지도 화면에 보이는 영역
struct GeoBounds: Hashable {
    var minLat: Double, maxLat: Double, minLng: Double, maxLng: Double
    func contains(lat: Double, lng: Double) -> Bool {
        lat >= minLat && lat <= maxLat && lng >= minLng && lng <= maxLng
    }
    /// 다른 범위를 통째로 품는가
    func contains(_ other: GeoBounds) -> Bool {
        other.minLat >= minLat && other.maxLat <= maxLat && other.minLng >= minLng && other.maxLng <= maxLng
    }
}

/// 매물 검색 조건. 서버에 쿼리로 보내고, 서버가 무시해도 결과를 한 번 더 걸러서(matches) 화면이 조건과 맞게 한다.
struct ListingQuery: Hashable {
    var text: String? = nil                // 검색창 입력 (지역명)
    var dealType: String? = nil            // MONTHLY | JEONSE
    var roomType: String? = nil            // ONE_ROOM | TWO_ROOM | THREE_ROOM | OFFICETEL
    var maxDeposit: Int? = nil             // 만원
    var maxMonthly: Int? = nil             // 만원
    var spaceOnly = false                  // 3D 공간이 준비된 매물만 (서버에 보내지 않고 받은 목록에서 거른다)
    var bounds: GeoBounds? = nil

    var isFiltered: Bool { dealType != nil || roomType != nil || maxDeposit != nil || maxMonthly != nil || spaceOnly }
    /// 필터 시트에서만 거는 가격 조건이 있는가 (필터 버튼 강조용 · 빠른 칩은 따로 보인다)
    var hasPriceLimit: Bool { maxDeposit != nil || maxMonthly != nil }

    var items: [URLQueryItem] {
        var q: [URLQueryItem] = []
        if let t = text?.trimmed, !t.isEmpty { q.append(.init(name: "location", value: t)) }
        if let dealType { q.append(.init(name: "dealType", value: dealType)) }
        if let roomType { q.append(.init(name: "roomType", value: roomType)) }
        if let maxDeposit { q.append(.init(name: "maxDeposit", value: String(maxDeposit))) }
        if let maxMonthly { q.append(.init(name: "maxPrice", value: String(maxMonthly))) }
        if let b = bounds {
            q.append(contentsOf: [
                .init(name: "minLat", value: String(format: "%.6f", b.minLat)), .init(name: "maxLat", value: String(format: "%.6f", b.maxLat)),
                .init(name: "minLng", value: String(format: "%.6f", b.minLng)), .init(name: "maxLng", value: String(format: "%.6f", b.maxLng)),
            ])
        }
        return q
    }

    /// 검색어에서 "원룸", "전세" 같은 단어를 조건으로 옮기고 나머지를 지역명으로 쓴다
    static func parse(_ input: String) -> ListingQuery {
        var q = ListingQuery()
        var words: [String] = []
        for w in input.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init) {
            if let rt = Fmt.roomTypes.first(where: { $0.label == w || ($0.key == "THREE_ROOM" && w == "쓰리룸") }) {
                q.roomType = rt.key
            } else if w == "월세" { q.dealType = "MONTHLY" }
            else if w == "전세" { q.dealType = "JEONSE" }
            else { words.append(w) }
        }
        q.text = words.isEmpty ? nil : words.joined(separator: " ")
        return q
    }

    func matches(_ l: Listing) -> Bool {
        if let t = text?.trimmed, !t.isEmpty {
            let hay = l.location.replacingOccurrences(of: " ", with: "")
            let tokens = t.split(separator: " ").map(String.init)
            if !tokens.allSatisfy({ hay.contains($0) }) { return false }
        }
        if spaceOnly && !l.isSpaceReady { return false }
        if let dealType, Fmt.dealKey(l) != dealType { return false }
        if let roomType, l.roomType != roomType, Fmt.roomType(l.roomType) != Fmt.roomType(roomType) { return false }
        if let maxDeposit, l.price.deposit > maxDeposit { return false }
        if let maxMonthly, !Fmt.isJeonse(l), l.price.monthly > maxMonthly { return false }
        return true
    }
}

/// 로그인: 이메일 · 비밀번호, 카카오 · 구글(SDK 토큰을 서버가 검증), 토큰 갱신
enum AuthAPI {
    /// 가입만 하고 토큰은 주지 않는다 (명세) → 이어서 login
    static func signup(email: String, password: String, displayName: String) async throws {
        let _: Empty = try await APIClient.shared.post("auth/signup",
                                                       SignupRequest(email: email, password: password, displayName: displayName))
    }

    static func login(email: String, password: String) async throws -> AuthResponse {
        try await APIClient.shared.post("auth/login", LoginRequest(email: email, password: password))
    }

    /// 카카오는 accessToken, 구글은 idToken 을 서버에 넘긴다
    static func oauth(_ provider: LoginProvider, token: String) async throws -> AuthResponse {
        let body = provider == .kakao ? ["accessToken": token] : ["idToken": token]
        return try await APIClient.shared.post("auth/oauth/\(provider.rawValue)", body)
    }

    static func refresh(_ refreshToken: String) async throws -> AuthResponse {
        try await APIClient.shared.post("auth/refresh", RefreshRequest(refreshToken: refreshToken))
    }

    static func logout(refreshToken: String?) async throws {
        if let refreshToken {
            let _: Empty = try await APIClient.shared.post("auth/logout", RefreshRequest(refreshToken: refreshToken))
        } else {
            let _: Empty = try await APIClient.shared.post("auth/logout")
        }
    }
}

enum UserAPI {
    /// 중개사 인증 상태. 신청한 적 없으면 nil (404)
    static func agentProfile() async throws -> AgentProfile? {
        do {
            let p: AgentProfile = try await APIClient.shared.get("users/me/agent-profile")
            return p.status == nil && p.name == nil ? nil : p
        } catch let e as APIError where e.status == 404 {
            return nil
        }
    }

    /// 중개사 인증 신청 (multipart: name, licenseNumber, officeName, document)
    static func applyAgent(name: String, licenseNumber: String, officeName: String,
                           document: Data, documentName: String) async throws -> AgentProfile {
        try await APIClient.shared.uploadMultipart("users/me/agent-profile", parts: [
            .field(name: "name", value: name),
            .field(name: "licenseNumber", value: licenseNumber),
            .field(name: "officeName", value: officeName),
            .field(name: "documentName", value: documentName),
            .file(name: "document", filename: documentName, mimeType: "image/jpeg", data: document),
        ])
    }

    static func myListings() async throws -> [Listing] { try await APIClient.shared.getList("users/me/listings") }
    static func scraps() async throws -> [Listing] { try await APIClient.shared.getList("users/me/scraps") }
}

enum ListingAPI {
    static func list(_ query: ListingQuery = ListingQuery()) async throws -> [Listing] {
        let all: [Listing] = try await APIClient.shared.getList("listings", query: query.items)
        return all.filter { query.matches($0) }
    }

    static func get(_ id: String) async throws -> Listing { try await APIClient.shared.get("listings/\(id)") }

    static func create(_ req: CreateListingRequest) async throws -> CreateListingResponse {
        try await APIClient.shared.post("listings", req)
    }

    /// 상세 사진 (multipart "images", 선택한 순서대로)
    static func uploadImages(_ id: String, images: [(filename: String, data: Data)],
                             progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let parts = images.map { MultipartPart.file(name: "images", filename: $0.filename, mimeType: "image/jpeg", data: $0.data) }
        let _: Empty = try await APIClient.shared.uploadMultipart("listings/\(id)/images", parts: parts, progress: progress)
    }

    /// capture.zip 을 body 로 스트리밍 (multipart 아님)
    static func uploadCapture(_ id: String, zip: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws -> Accepted {
        try await APIClient.shared.upload("listings/\(id)/captures", file: zip, progress: progress)
    }

    static func setScrap(_ id: String, on: Bool) async throws {
        if on {
            let _: Empty = try await APIClient.shared.post("listings/\(id)/scrap")
        } else {
            let _: Empty = try await APIClient.shared.delete("listings/\(id)/scrap")
        }
    }

    static func report(_ id: String, reason: String, detail: String?) async throws {
        let _: Empty = try await APIClient.shared.post("listings/\(id)/reports", ReportRequest(reason: reason, detail: detail))
    }

    static func space(_ id: String) async throws -> SpaceResponse { try await APIClient.shared.get("listings/\(id)/space") }

    static func objects(_ id: String) async throws -> [SceneObject] { try await APIClient.shared.getList("listings/\(id)/objects") }

    /// 가구 구분 (매물을 올린 사람만). 미분류는 "UNKNOWN" 으로 보낸다.
    /// objectsVersion: 화면을 열 때 본 구분 버전 → If-Match. 그 사이 바뀌었으면 서버가 412
    static func patchObjects(_ id: String, _ items: [ObjectOwnershipPatch.Item], objectsVersion: Int? = nil) async throws {
        let _: Empty = try await APIClient.shared.patch("listings/\(id)/objects", ObjectOwnershipPatch(objects: items),
                                                        ifMatch: objectsVersion.map { "\"\($0)\"" })
    }

    /// 가구 빼 보기: 개인 가구 중 고른 것을 뺀 "나만 보는" 입주 상태를 만든다 (202 → 작업 폴링)
    static func createRoomState(_ id: String, removed: [String],
                                spaceVersion: Int? = nil, objectsVersion: Int? = nil) async throws -> Accepted {
        try await APIClient.shared.post("listings/\(id)/room-states",
                                        RoomStateRequest(sourceSpaceVersion: spaceVersion, sourceObjectsVersion: objectsVersion,
                                                         removedObjectIds: removed))
    }

    /// 이 매물에서 내가 만든 입주 상태 (다른 사람 것은 서버가 주지 않는다)
    static func myRoomStates(_ id: String) async throws -> [RoomState] {
        try await APIClient.shared.getList("listings/\(id)/room-states")
    }

    /// overwrite: 다른 기기에서 먼저 저장해 412 가 났을 때 사용자가 "덮어쓰기"를 고른 경우 (지금 버전을 받아 If-Match 로 저장)
    static func savePlacements(_ id: String, _ placements: [Placement], overwrite: Bool = false) async throws -> PlacementsResponse {
        let path = "listings/\(id)/placements"
        if overwrite { await APIClient.shared.refreshETag(path) }
        return try await APIClient.shared.put(path, PlacementsRequest(placements: placements))
    }

    static func placements(_ id: String) async throws -> [Placement] { try await APIClient.shared.getList("listings/\(id)/placements") }
}

enum RoomStateAPI {
    /// 만든 사람만 받을 수 있다 (다른 사람 것은 404)
    static func get(_ roomStateId: String) async throws -> RoomState { try await APIClient.shared.get("room-states/\(roomStateId)") }

    static func delete(_ roomStateId: String) async throws {
        let _: Empty = try await APIClient.shared.delete("room-states/\(roomStateId)")
    }

    /// 이 매물에서 내가 만든 입주 상태 중 가장 최근 완성본. 공간을 다시 촬영했으면 예전 공간으로 만든 것은 건너뛴다.
    /// 없거나 목록을 못 받으면 nil (입주 예상 버튼 대신 "가구 빼 보기"를 보여 준다)
    static func latestReady(listingId: String, spaceVersion: Int?) async -> RoomState? {
        guard let list = try? await ListingAPI.myRoomStates(listingId) else { return nil }
        return pickLatestReady(list, spaceVersion: spaceVersion)
    }

    /// 완성본 중 가장 최근 것. 지금 공간 버전과 다른 버전으로 만든 것(다시 촬영 전)은 건너뛴다
    static func pickLatestReady(_ list: [RoomState], spaceVersion: Int?) -> RoomState? {
        newestFirst(list).first { rs in
            guard rs.isReady, rs.roomStateId != nil else { return false }
            guard let made = rs.sourceSpaceVersion, let current = spaceVersion else { return true }
            return made == current
        }
    }

    /// 서버 순서를 믿지 않고 createdAt 최신순으로 (같거나 없으면 받은 순서 유지)
    static func newestFirst(_ list: [RoomState]) -> [RoomState] {
        // 타입을 나눠 적는다 (한 줄 체인은 컴파일러가 타입 추론을 제때 못 끝낸다)
        var keyed: [(index: Int, date: Date, state: RoomState)] = []
        for (index, state) in list.enumerated() {
            let date: Date = Fmt.parseDate(state.createdAt) ?? Date.distantPast
            keyed.append((index: index, date: date, state: state))
        }
        keyed.sort { (a, b) -> Bool in
            if a.date != b.date { return a.date > b.date }
            return a.index < b.index
        }
        return keyed.map { $0.state }
    }
}

enum FurnitureAPI {
    static func mine() async throws -> [Furniture] { try await APIClient.shared.getList("users/me/furniture") }
    static func get(_ id: String) async throws -> Furniture { try await APIClient.shared.get("furniture/\(id)") }
    static func create(name: String, category: String) async throws -> CreateFurnitureResponse {
        try await APIClient.shared.post("furniture", CreateFurnitureRequest(name: name, category: category))
    }
    static func uploadCapture(_ id: String, zip: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws -> Accepted {
        try await APIClient.shared.upload("furniture/\(id)/captures", file: zip, progress: progress)
    }
}

enum ChatAPI {
    static func rooms() async throws -> [ChatRoomSummary] { try await APIClient.shared.getList("chat") }
    static func room(_ chatId: String) async throws -> ChatRoomDetail { try await APIClient.shared.get("chat/\(chatId)") }
    static func send(_ chatId: String, message: String) async throws {
        let _: Empty = try await APIClient.shared.post("chat/\(chatId)", SendMessageRequest(message: message))
    }
    /// 매물 상세의 "채팅하기": 이미 방이 있으면 서버가 기존 chatId 를 돌려준다
    static func open(listingId: String) async throws -> String {
        let r: OpenChatResponse = try await APIClient.shared.post("chat", OpenChatRequest(listingId: listingId))
        return r.chatId
    }
}

enum JobAPI {
    static func get(_ jobId: String) async throws -> AIJob { try await APIClient.shared.get("ai-jobs/\(jobId)") }

    /// COMPLETED / FAILED 까지 폴링. 백엔드가 push 를 붙이면 이 함수만 교체하면 된다.
    static func wait(_ jobId: String, every seconds: Double = 3,
                     onUpdate: (@MainActor (AIJob) -> Void)? = nil) async throws -> AIJob {
        while !Task.isCancelled {
            let job = try await get(jobId)
            if let onUpdate { await onUpdate(job) }
            if job.isDone || job.isFailed { return job }
            try await Task.sleep(for: .seconds(seconds))
        }
        throw CancellationError()
    }
}
