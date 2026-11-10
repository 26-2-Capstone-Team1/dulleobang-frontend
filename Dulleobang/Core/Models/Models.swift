import Foundation

// 시퀀스 다이어그램(둘러방 v2)의 API 페이로드와 대응하는 Codable 모델.
// 좌표계: 미터, Y-up, 오른손(ARKit·three.js 와 동일). yaw 는 +Y 축 기준 반시계(위에서 볼 때), 도(°).
// 백엔드가 아직 정하지 않은 필드는 Optional 로 두어 디코딩이 깨지지 않게 한다.
// ID 는 숫자/문자열 어느 쪽으로 와도 받는다(@FlexibleID). 매물은 StayView 클래스 다이어그램의 필드명도 받는다.

// MARK: - 공통

struct Vec3: Codable, Hashable {
    var x: Double, y: Double, z: Double
    static let zero = Vec3(x: 0, y: 0, z: 0)
}

struct Dimensions: Codable, Hashable {
    var width: Double, height: Double, depth: Double   // x, y, z (yaw = 0 기준)
}

struct Rotation: Codable, Hashable { var yaw: Double }

struct BoundingBox: Codable, Hashable { var min: Vec3; var max: Vec3 }

/// 실패한 AI 작업의 원인 (서버 JobFailure)
struct JobFailure: Codable {
    var code: String?
    var message: String?
    var retryable: Bool?

    private enum CodingKeys: String, CodingKey { case code, message, retryable }

    /// 객체 {code, message, retryable} 가 기본. 문구만 문자열로 주는 서버도 받고, 다른 형태면 비워 둔다 (작업 상태 조회가 깨지지 않게)
    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let text = try? single.decode(String.self) {
            message = text
            return
        }
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        code = try? c.decodeIfPresent(String.self, forKey: .code)
        message = try? c.decodeIfPresent(String.self, forKey: .message)
        retryable = try? c.decodeIfPresent(Bool.self, forKey: .retryable)
    }
}

struct AIJob: Codable {
    @FlexibleID var jobId: String
    var status: String                 // QUEUED | RUNNING | RETRY_WAIT | COMPLETED | FAILED | CANCELED
    var progress: Double?              // 0–100
    var message: String?
    @FlexibleOptionalID var roomStateId: String? = nil     // ROOM_OBJECT_REMOVAL 완료 시
    var error: JobFailure? = nil       // 실패 원인 {code, message, retryable}
    var isDone: Bool { status == "COMPLETED" }
    /// 실패했을 때 보여 줄 문구: 아는 원인 코드는 한국어로, 아니면 서버가 보낸 message
    var failureMessage: String? {
        if let code = error?.code, let text = ServerErrorText.jobFailure[code] { return text }
        return message
    }
    /// 끝났지만 결과가 없는 상태 (취소도 여기에 넣어야 폴링이 멈춘다)
    var isFailed: Bool { status == "FAILED" || status == "CANCELED" }
    var percent: Int? { progress.map { Int($0.rounded()) } }
}

struct Accepted: Codable {             // 202 Accepted
    @FlexibleID var jobId: String
    var status: String?
    @FlexibleOptionalID var roomStateId: String? = nil
}

// MARK: - 매물

/// 보증금 / 월세 (만원). 전세는 monthly = 0
struct Price: Codable, Hashable {
    var deposit: Int
    var monthly: Int
}

extension Price {
    init(from decoder: Decoder) throws {
        let c = try LooseContainer(decoder)
        deposit = c.int("deposit") ?? 0
        monthly = c.int("monthly", "monthlyRent", "rent") ?? 0
    }
}

/// 입주 상태(가구를 뺀 공간)는 매물에 붙지 않는다. 만든 사람만 보는 개인 결과물이라 GET /listings/{id}/room-states 로 내 것을 찾는다.
struct Space3DInfo: Codable, Hashable {
    var status: String?                // NONE | QUEUED | RUNNING | COMPLETED | FAILED
    @FlexibleOptionalID var jobId: String? = nil
}

/// 매물을 올린 사람 요약. 누구나(집주인도) 매물을 올릴 수 있고, 중개사 인증을 받은 사람만 isVerifiedBroker = true
struct AgentSummary: Codable, Hashable {
    @FlexibleOptionalID var userId: String? = nil
    var name: String? = nil
    var officeName: String? = nil
    var phone: String? = nil
    var isVerifiedBroker: Bool? = nil

    var isVerified: Bool { isVerifiedBroker == true }
}

extension AgentSummary {
    /// 명세 v1.1 의 owner {userId, displayName, isVerifiedBroker, officeName, phone} 도 받는다
    init(from decoder: Decoder) throws {
        let c = try LooseContainer(decoder)
        _userId = FlexibleOptionalID(wrappedValue: c.id("userId", "id"))
        name = c.string("name", "displayName", "nickname")
        officeName = c.string("officeName", "office")
        phone = c.string("phone", "phoneNumber")
        isVerifiedBroker = c.value(Bool.self, "isVerifiedBroker", "verifiedBroker", "isVerified", "verified")
    }
}

struct Listing: Codable, Identifiable, Hashable {
    var id: String { listingId }
    @FlexibleID var listingId: String
    var location: String
    var price: Price
    var dealType: String? = nil            // MONTHLY | JEONSE
    var maintenanceFee: Int? = nil         // 관리비 (만원). nil = 협의
    var roomType: String? = nil            // ONE_ROOM | TWO_ROOM | THREE_ROOM | OFFICETEL
    var floor: Int? = nil
    var totalFloors: Int? = nil
    var area: Double? = nil                // 전용면적 ㎡
    var supplyArea: Double? = nil          // 공급면적 ㎡
    var rooms: Int? = nil
    var bathrooms: Int? = nil
    var availableFrom: String? = nil       // "IMMEDIATE" 또는 yyyy-MM-dd
    var rentalOptions: [String]? = nil
    var thumbnailUri: String? = nil
    var imageUris: [String]? = nil
    var latitude: Double? = nil
    var longitude: Double? = nil
    var livingEnvironment: String? = nil   // 생활 환경 (편의시설·교통 등 자유 텍스트)
    var agent: AgentSummary? = nil
    var isScrapped: Bool? = nil
    var space3DInfo: Space3DInfo? = nil

    var isSpaceReady: Bool { space3DInfo?.status == "COMPLETED" }
    var coverUri: String? { thumbnailUri ?? imageUris?.first }
    var photoUris: [String] {
        if let imgs = imageUris, !imgs.isEmpty { return imgs }
        return thumbnailUri.map { [$0] } ?? []
    }
    var hasCoordinate: Bool { latitude != nil && longitude != nil }
}

extension Listing {
    /// v2 API(location, price{deposit,monthly}) 와 StayView 다이어그램(address, deposit, monthlyRent, availableDate …) 둘 다 받는다.
    init(from decoder: Decoder) throws {
        let c = try LooseContainer(decoder)
        guard let id = c.id("listingId", "spaceId", "id") else {
            throw DecodingError.keyNotFound(AnyCodingKey(stringValue: "listingId")!,
                                            .init(codingPath: decoder.codingPath, debugDescription: "매물 ID(listingId) 가 없습니다"))
        }
        _listingId = FlexibleID(wrappedValue: id)
        location = c.string("location", "address", "roadAddress") ?? ""
        price = c.value(Price.self, "price")
            ?? Price(deposit: c.int("deposit") ?? 0, monthly: c.int("monthly", "monthlyRent", "rent") ?? 0)
        dealType = c.string("dealType", "tradeType", "contractType")
        maintenanceFee = c.int("maintenanceFee", "managementFee")
        roomType = c.string("roomType")
        floor = c.int("floor")
        totalFloors = c.int("totalFloors", "buildingFloors", "totalFloor")
        area = c.double("area", "exclusiveArea")
        supplyArea = c.double("supplyArea")
        rooms = c.int("rooms", "roomCount")
        bathrooms = c.int("bathrooms", "bathroomCount")
        availableFrom = c.string("availableFrom", "availableDate", "moveInDate")
        rentalOptions = c.value([String].self, "rentalOptions", "options")
        thumbnailUri = c.string("thumbnailUri", "thumbnailUrl", "thumbnail")
        imageUris = c.value([String].self, "imageUris", "imageUrls", "images", "photos")
            ?? c.value([ImageRef].self, "images", "spaceImages", "photos")
                .map { $0.sorted { ($0.order ?? 0) < ($1.order ?? 0) }.map(\.uri) }
        latitude = c.double("latitude", "lat")
        longitude = c.double("longitude", "lng", "lon")
        livingEnvironment = c.string("livingEnvironment", "livingEnvironmentInfo")
        if let a = c.value(AgentSummary.self, "agent", "broker", "owner") {
            agent = a
        } else if let agentId = c.id("agentId", "brokerId", "ownerId") {
            agent = AgentSummary(userId: agentId, name: c.string("agentName"), officeName: c.string("officeName"),
                                 phone: c.string("agentPhone"))
        }
        isScrapped = c.value(Bool.self, "isScrapped", "scrapped", "isFavorite", "favorite")
        if let s = c.value(Space3DInfo.self, "space3DInfo", "space3dInfo") {
            space3DInfo = s
        } else if let status = c.string("modelStatus", "spaceStatus") {
            space3DInfo = Space3DInfo(status: status)
        }
    }
}

/// 이미지가 객체 배열로 올 때 ({imageUrl, imageOrder})
private struct ImageRef: Decodable {
    let uri: String
    let order: Int?
    init(from decoder: Decoder) throws {
        let c = try LooseContainer(decoder)
        guard let u = c.string("uri", "url", "imageUrl", "imageUri") else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "이미지 URL 없음"))
        }
        uri = u
        order = c.int("imageOrder", "order")
    }
}

struct CreateListingRequest: Codable {
    var location: String
    var dealType: String
    var price: Price
    var maintenanceFee: Int?
    var roomType: String
    var floor: Int?
    var totalFloors: Int?
    var area: Double
    var supplyArea: Double?
    var rooms: Int?
    var bathrooms: Int?
    var availableFrom: String
    var rentalOptions: [String]
    var latitude: Double?
    var longitude: Double?
}

struct CreateListingResponse: Codable { @FlexibleID var listingId: String }

extension CreateListingResponse {
    init(from decoder: Decoder) throws {
        let c = try LooseContainer(decoder)
        guard let id = c.id("listingId", "spaceId", "id") else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "응답에 listingId 가 없습니다"))
        }
        _listingId = FlexibleID(wrappedValue: id)
    }
}

// MARK: - 3D 공간 (GET /listings/{id}/space)

struct Wall: Codable, Identifiable {
    @FlexibleID var id: String
    var from: [Double]                 // [x, z] 실내면 기준
    var to: [Double]
    var height: Double?
}

struct Opening: Codable, Identifiable {
    @FlexibleID var id: String
    var type: String                   // door | window
    var position: Vec3                 // 중심
    var rotation: Rotation
    var dimensions: Dimensions         // width(가로) height(세로) depth(두께)
}

struct RoomGeometry: Codable {
    var floorHeight: Double?
    var ceilingHeight: Double?
    var walls: [Wall]
    var doors: [Opening]?
    var windows: [Opening]?
    var boundingBox: BoundingBox?
}

struct RoomDimensions: Codable { var width: Double; var depth: Double; var height: Double; var area: Double? }

struct SceneObject: Codable, Identifiable {
    var id: String { objectId }
    @FlexibleID var objectId: String
    var category: String
    var position: Vec3
    var rotation: Rotation
    var dimensions: Dimensions
    var ownershipType: String?         // PERSONAL | RENTAL_OPTION | UNKNOWN (nil 도 미분류)
    var removable: Bool? = nil         // false = 구조물 · 고정 설비. 없으면 종류로 판단

    var isPersonal: Bool { ownershipType == "PERSONAL" }
    var isRentalOption: Bool { ownershipType == "RENTAL_OPTION" }
    var isUnclassified: Bool { ownershipType == nil || ownershipType == "UNKNOWN" }
    var isFixture: Bool { !(removable ?? !Self.fixtureCategories.contains(category)) }
    /// 입주 상태에서 뺄 수 있는 가구: 중개사가 개인 가구로 구분했고 고정 설비가 아닌 것 (명세 v1: PERSONAL + removable)
    var canRemove: Bool { isPersonal && !isFixture }

    /// RoomPlan 종류 중 빼는 게 말이 안 되는 고정 설비
    static let fixtureCategories: Set<String> = ["sink", "toilet", "bathtub", "fireplace", "stairs", "stove", "oven", "dishwasher"]
    /// 서버가 objects 에 유리를 섞어 보낼 때의 종류. 가구가 아니므로 SpaceResponse.glass 로 옮긴다
    static let glassCategory = "glass"
}

/// 서버(AI)가 LiDAR 로 찾은 투명 유리 하나 (tools/capture/glass_tools.py 가 만드는 glass.json 의 objects 와 같은 모양).
/// LiDAR 레이저는 맑은 유리를 통과해서 스캔에는 유리가 비어 있다 → 뷰어가 이 자리에 반투명 유리 상자를 그린다
struct GlassPane: Codable, Identifiable {
    var id: String { objectId }
    @FlexibleID var objectId: String
    var glassKind: String? = nil       // window | door | wall(RoomPlan 은 벽이라고 한 유리벽) | gap(RoomPlan 이 벽을 못 찾은 자리)
    var position: Vec3                 // 중심
    var rotation: Rotation             // yaw: +Y 축 반시계(위에서 볼 때), 도. 폭(width)이 벽을 따라간다
    var dimensions: Dimensions         // width(가로) height(세로) depth(두께, 보통 0.01)
}

struct SpaceResponse: Codable {
    var threeDgsUri: String?           // scene_current.ply (3DGS)
    var pointsUri: String?             // points.ply (7–8주차 MVP 용, 선택)
    var roomGeometry: RoomGeometry?
    var roomDimensions: RoomDimensions?
    var objects: [SceneObject]
    var collisionGeometryUri: String?  // glb
    var spaceVersion: Int? = nil       // 다시 촬영할 때마다 +1
    var objectsVersion: Int? = nil     // 중개사가 가구 구분을 바꿀 때마다 +1 (입주 상태 요청에 그대로 보낸다)
    /// 서버가 LiDAR 로 찾은 투명 유리 (선택). 뷰어가 반투명 유리로 그리고, 가구 목록 · 가구 구분 · 충돌 판정에는 넣지 않는다
    var glass: [GlassPane] = []

    enum CodingKeys: String, CodingKey {
        case threeDgsUri = "3dgsUri", pointsUri, roomGeometry, roomDimensions, objects, collisionGeometryUri
        case spaceVersion, objectsVersion, glass
    }
}

extension SpaceResponse {
    /// objects 가 빠져 있어도(가구 인식 전) 디코딩되게 한다
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        threeDgsUri = try c.decodeIfPresent(String.self, forKey: .threeDgsUri)
        pointsUri = try c.decodeIfPresent(String.self, forKey: .pointsUri)
        roomGeometry = try c.decodeIfPresent(RoomGeometry.self, forKey: .roomGeometry)
        roomDimensions = try c.decodeIfPresent(RoomDimensions.self, forKey: .roomDimensions)
        let all = try c.decodeIfPresent([SceneObject].self, forKey: .objects) ?? []
        objects = all.filter { $0.category != SceneObject.glassCategory }
        collisionGeometryUri = try c.decodeIfPresent(String.self, forKey: .collisionGeometryUri)
        spaceVersion = try? c.decodeIfPresent(Int.self, forKey: .spaceVersion)
        objectsVersion = try? c.decodeIfPresent(Int.self, forKey: .objectsVersion)
        // 유리는 보여 주기용이라 잘못 와도 공간 전체를 못 여는 일은 없게 한다. objects 에 category "glass" 로 섞여 와도 유리로 옮긴다
        let separate = (try? c.decodeIfPresent([GlassPane].self, forKey: .glass)) ?? []
        glass = separate + all.filter { $0.category == SceneObject.glassCategory }.map {
            GlassPane(objectId: $0.objectId, glassKind: nil, position: $0.position, rotation: $0.rotation, dimensions: $0.dimensions)
        }
    }
}

// MARK: - 입주 상태 (room-states)
// 명세 v1 방식: 가구 구분(개인 가구 / 임대 옵션)은 매물을 올린 중개사가 하고,
// 가구를 뺀 입주 상태는 보는 사람이 각자 만든다. 입주 상태는 만든 사람만 볼 수 있다.

struct ObjectOwnershipPatch: Codable {
    struct Item: Codable { var objectId: String; var ownershipType: String? }   // PERSONAL | RENTAL_OPTION | UNKNOWN
    var objects: [Item]
}

/// POST /listings/{id}/room-states. 버전은 GET space 에서 받은 값 (중간에 구분이 바뀌면 서버가 409)
struct RoomStateRequest: Codable {
    var sourceSpaceVersion: Int? = nil
    var sourceObjectsVersion: Int? = nil
    var removedObjectIds: [String]
}

struct RoomState: Codable {
    @FlexibleOptionalID var roomStateId: String? = nil
    @FlexibleOptionalID var listingId: String? = nil
    @FlexibleOptionalID var createdBy: String? = nil
    var status: String? = nil                // PROCESSING | READY | FAILED | CANCELED (없으면 완성본으로 본다)
    @FlexibleOptionalID var jobId: String? = nil
    var sourceSpaceVersion: Int? = nil
    var sourceObjectsVersion: Int? = nil
    var createdAt: String? = nil
    var sceneUri: String?
    var pointsUri: String?
    var collisionGeometryUri: String?
    @FlexibleIDs var removedObjectIds: [String] = []
    var remainingObjects: [SceneObject]?     // 없으면 removedObjectIds 로 걸러서 쓴다

    var isReady: Bool { status == nil || status == "READY" }
    var isProcessing: Bool { status == "PROCESSING" }
}

// MARK: - 가구

struct Furniture: Codable, Identifiable, Hashable {
    var id: String { furnitureId }
    @FlexibleID var furnitureId: String
    var name: String?
    var category: String?
    var status: String?
    var modelUri: String?              // glb
    var dimensions: Dimensions?
    var boundingBox: BoundingBox?
    var collisionMeshUri: String?
    var thumbnailUri: String?
    var isReady: Bool { modelUri != nil && dimensions != nil && (status == nil || status == "COMPLETED") }
    var label: String { name ?? category ?? furnitureId }
}

struct CreateFurnitureRequest: Codable { var name: String; var category: String }
struct CreateFurnitureResponse: Codable { @FlexibleID var furnitureId: String }

// MARK: - 배치

struct CollisionInfo: Codable, Hashable {
    var with: String                   // wallId | objectId | doorId | windowId | "bounds"
    var type: String                   // wall | object | door | window | bounds | furniture
    var overlap: Double                // m
}

struct Placement: Codable, Identifiable, Hashable {
    var id: String { furnitureId }
    @FlexibleID var furnitureId: String
    var position: Vec3
    var rotation: Rotation
    var isPlaceable: Bool?
    var collisions: [CollisionInfo]?
}

struct PlacementsRequest: Codable { var placements: [Placement] }
struct PlacementsResponse: Codable {
    @FlexibleOptionalID var placementSetId: String? = nil
    var savedAt: String?
    var placements: [Placement]?
}

// MARK: - 로그인 · 중개사

/// 로그인 응답. 명세의 TokenPair {accessToken, refreshToken, expiresIn, user{userId, email, displayName, roles}} 와
/// 예전 데모 형태 {userId, name, email, accessToken} 를 모두 받는다
struct AuthResponse: Codable {
    @FlexibleID var userId: String
    var name: String?
    var email: String?
    var accessToken: String?
    var refreshToken: String? = nil
    var roles: [String]? = nil
}

extension AuthResponse {
    init(from decoder: Decoder) throws {
        let c = try LooseContainer(decoder)
        accessToken = c.string("accessToken", "token", "jwt")
        refreshToken = c.string("refreshToken")
        if let u = c.value(AuthUser.self, "user") {
            _userId = FlexibleID(wrappedValue: u.userId)
            name = u.name
            email = u.email
            roles = u.roles
            return
        }
        guard let id = c.id("userId", "id", "memberId") else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "로그인 응답에 userId 가 없습니다"))
        }
        _userId = FlexibleID(wrappedValue: id)
        name = c.string("name", "nickname", "displayName")
        email = c.string("email")
        roles = c.value([String].self, "roles")
    }
}

/// TokenPair.user / 가입 응답(User)
struct AuthUser: Decodable {
    let userId: String
    let name: String?
    let email: String?
    let roles: [String]?

    init(from decoder: Decoder) throws {
        let c = try LooseContainer(decoder)
        guard let id = c.id("userId", "id") else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "사용자 ID 가 없습니다"))
        }
        userId = id
        name = c.string("displayName", "name", "nickname")
        email = c.string("email")
        roles = c.value([String].self, "roles")
    }
}

struct SignupRequest: Codable { var email: String; var password: String; var displayName: String }
struct LoginRequest: Codable { var email: String; var password: String }
struct RefreshRequest: Codable { var refreshToken: String }

/// GET/POST /users/me/agent-profile
struct AgentProfile: Codable, Equatable {
    var status: String?                // PENDING | APPROVED | REJECTED
    var name: String?
    var licenseNumber: String?
    var officeName: String?
    var documentName: String?
    var documentUri: String?
    var requestedAt: String?
    var verifiedAt: String?
    var rejectReason: String?

    var isApproved: Bool { ["APPROVED", "VERIFIED"].contains(status ?? "") }
    var isPending: Bool { ["PENDING", "REQUESTED"].contains(status ?? "") }
    var isRejected: Bool { status == "REJECTED" }
}

// MARK: - 채팅

/// 채팅방에 붙는 매물 요약
struct ChatListing: Codable, Hashable {
    @FlexibleOptionalID var listingId: String? = nil
    var price: Price? = nil
    var dealType: String? = nil
    var location: String? = nil
    var roomType: String? = nil
    var floor: Int? = nil
    var thumbnailUri: String? = nil
}

struct ChatRoomSummary: Codable, Identifiable {
    var id: String { chatId }
    @FlexibleID var chatId: String
    var listing: ChatListing?
    var counterpartName: String?
    var lastMessage: String?
    var lastMessageAt: String?
    var unreadCount: Int?
}

struct ChatMessage: Codable, Identifiable, Equatable {
    var id: String { messageId }
    @FlexibleID var messageId: String
    @FlexibleOptionalID var senderId: String? = nil
    var senderName: String? = nil
    var message: String
    var sentAt: String? = nil
}

extension ChatMessage {
    /// 클래스 다이어그램(ChatMessage.content, createdAt) 필드명도 받는다
    init(from decoder: Decoder) throws {
        let c = try LooseContainer(decoder)
        _messageId = FlexibleID(wrappedValue: c.id("messageId", "id") ?? UUID().uuidString)
        _senderId = FlexibleOptionalID(wrappedValue: c.id("senderId", "userId", "writerId"))
        senderName = c.string("senderName", "sender", "writerName")
        message = c.string("message", "content", "text") ?? ""
        sentAt = c.string("sentAt", "createdAt", "timestamp")
    }
}

struct ChatRoomDetail: Codable {
    @FlexibleID var chatId: String
    var listing: ChatListing?
    var counterpartName: String?
    var officeName: String?
    var messages: [ChatMessage]?
}

struct OpenChatRequest: Codable { var listingId: String }
struct OpenChatResponse: Codable { @FlexibleID var chatId: String }

extension OpenChatResponse {
    init(from decoder: Decoder) throws {
        let c = try LooseContainer(decoder)
        guard let id = c.id("chatId", "chatRoomId", "roomId", "id") else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "응답에 chatId 가 없습니다"))
        }
        _chatId = FlexibleID(wrappedValue: id)
    }
}

struct SendMessageRequest: Codable { var message: String }
struct ReportRequest: Codable { var reason: String; var detail: String? }

// MARK: - 너그러운 디코딩 도우미

/// 여러 후보 키 중 처음 성공하는 값을 읽는다. 숫자가 문자열로 와도("3") 받는다.
struct LooseContainer {
    let c: KeyedDecodingContainer<AnyCodingKey>
    init(_ decoder: Decoder) throws { c = try decoder.container(keyedBy: AnyCodingKey.self) }

    private func keys(_ names: [String]) -> [AnyCodingKey] {
        names.compactMap { AnyCodingKey(stringValue: $0) }.filter { c.contains($0) }
    }

    func value<T: Decodable>(_ type: T.Type, _ names: String...) -> T? {
        for k in keys(names) {
            if let v = try? c.decode(T.self, forKey: k) { return v }
        }
        return nil
    }

    func string(_ names: String...) -> String? {
        for k in keys(names) {
            if let s = try? c.decode(String.self, forKey: k) { return s }
            if let i = try? c.decode(Int64.self, forKey: k) { return String(i) }
            if let d = try? c.decode(Double.self, forKey: k) { return String(d) }
        }
        return nil
    }

    func id(_ names: String...) -> String? {
        for k in keys(names) {
            if let v = try? c.decode(FlexibleOptionalID.self, forKey: k), let s = v.wrappedValue { return s }
        }
        return nil
    }

    func int(_ names: String...) -> Int? {
        for k in keys(names) {
            if let i = try? c.decode(Int.self, forKey: k) { return i }
            if let d = try? c.decode(Double.self, forKey: k), let i = Int(exactly: d.rounded()) { return i }
            if let s = try? c.decode(String.self, forKey: k),
               let d = Double(s.trimmingCharacters(in: .whitespaces)), let i = Int(exactly: d.rounded()) { return i }
        }
        return nil
    }

    func double(_ names: String...) -> Double? {
        for k in keys(names) {
            if let d = try? c.decode(Double.self, forKey: k) { return d }
            if let s = try? c.decode(String.self, forKey: k), let d = Double(s.trimmingCharacters(in: .whitespaces)) { return d }
        }
        return nil
    }
}
