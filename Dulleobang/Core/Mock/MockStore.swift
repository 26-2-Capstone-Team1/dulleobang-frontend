import Foundation

// 데모 모드(설정 › 데모 데이터 사용)에서 MockBackend 가 쓰는 데이터 형식.
// 처음 실행하면 번들의 Resources/Mock/mock_seed.json 으로 채우고, 이후 바뀐 내용(등록한 매물 · 채팅 · 배치 등)은
// Application Support/DemoData/db.json 에 저장한다. 설정 › 데모 데이터 초기화로 처음 상태로 되돌린다.

/// 저장 파일 전체
struct MockDB: Codable {
    var storeVersion: Int
    var seedVersion: Int
    var seq: Int                                  // 새 ID 발급용 (매물 · 채팅 · 작업 · 가구 공용)
    var agents: [MockAgent]
    var listings: [MockListing]
    var spaces: [String: SpaceResponse]           // listingId → 3D 공간 (spaceVersion · objectsVersion 포함)
    var roomStates: [String: RoomState]           // roomStateId → 입주 상태. createdBy 만 볼 수 있다 ("me" = 로그인한 사용자)
    var furniture: [MockFurniture]
    var placements: [String: [Placement]]         // "userId|listingId" → 저장한 배치
    var placementVersions: [String: Int]? = nil  // 같은 키 → 배치 세트 버전 (ETag). 예전 저장본에는 없음
    var scraps: [String: [String]]                // userId → 관심 매물 (최근 것이 앞)
    var defaultScraps: [String]                   // 처음 로그인한 사용자의 관심 매물
    var chats: [MockChat]
    var jobs: [MockJob]
    var profiles: [String: MockProfile]           // userId → 중개사 인증
    var users: [String: MockUser]
    var reportCount: Int
}

/// 데모 중개사
struct MockAgent: Codable {
    var userId: String
    var name: String
    var officeName: String
    var phone: String
}

struct MockListing: Codable {
    var listing: Listing                          // agent · isScrapped 는 응답할 때 채운다
    /// 등록한 중개사 userId. "me" = 로그인한 사용자가 중개사로 인증돼 있으면 그 사람의 매물 (중개사 화면 시연용)
    var ownerId: String
    var fallbackOwnerId: String?                  // ownerId 가 "me" 인데 사용자가 중개사가 아닐 때 보여 줄 중개사
    var rank: Int?                                // 추천 순서 (작을수록 먼저). 새로 등록한 매물은 0
}

struct MockFurniture: Codable {
    var furniture: Furniture
    var ownerId: String?                          // nil = 데모 기본 가구 (모든 사용자에게 보인다)
}

struct MockChat: Codable {
    var chatId: String
    var listingId: String
    var userId: String?                           // nil = 데모 기본 채팅 (모든 사용자에게 보인다)
    var unread: Int
    var messages: [MockMessage]
    var pendingReplies: [MockMessage]             // 중개사 자동 답장. at 이 지나면 messages 로 옮긴다
}

struct MockMessage: Codable {
    var id: String
    var fromMe: Bool
    var text: String
    var at: Date
}

/// AI 작업 흉내: 시작 후 duration 초가 지나면 완료되고 결과를 반영한다
struct MockJob: Codable {
    var jobId: String
    var kind: String                              // SPACE | ROOM_STATE | FURNITURE
    var targetId: String                          // listingId 또는 furnitureId
    var roomStateId: String?
    var removed: [String]?
    var duration: Double
    var startedAt: Date?                          // nil = 처음 조회할 때 시작 (데모 매물 105 의 "3D 생성 중")
    var finished: Bool
}

struct MockProfile: Codable {
    var profile: AgentProfile
    var approveAt: Date?                          // 심사 중 → 이 시각에 자동 승인
}

struct MockUser: Codable {
    var name: String?
    var email: String?
    var provider: String?
    var passwordHash: String? = nil              // 이메일 가입 계정만 (SHA-256, 데모용)
}

/// 번들의 mock_seed.json 형식 (tools: mockgen/make_seed.py 로 생성)
struct MockSeed: Decodable {
    var seedVersion: Int
    var agents: [MockAgent]
    var listings: [MockListing]
    var spaces: [String: SpaceResponse]
    var roomStates: [String: RoomState]
    var furniture: [Furniture]
    var chats: [Chat]
    var jobs: [Job]
    var defaultScraps: [String]

    struct Chat: Decodable {
        var chatId: String
        var listingId: String
        var unread: Int
        var messages: [Message]
    }

    struct Message: Decodable {
        var fromMe: Bool
        var text: String
        var minutesAgo: Double                    // 처음 실행한 시각 기준 몇 분 전
    }

    struct Job: Decodable {
        var jobId: String
        var kind: String
        var targetId: String
        var duration: Double
    }
}

extension MockDB {
    static let currentStoreVersion = 2           // 2: 입주 상태가 사용자별(createdBy · status)로 바뀜

    static func fromSeed(_ s: MockSeed, now: Date = Date()) -> MockDB {
        let chats = s.chats.map { c -> MockChat in
            let messages = c.messages.enumerated().map { pair -> MockMessage in
                MockMessage(id: "\(c.chatId)-\(pair.offset + 1)", fromMe: pair.element.fromMe, text: pair.element.text,
                            at: now.addingTimeInterval(-pair.element.minutesAgo * 60))
            }
            return MockChat(chatId: c.chatId, listingId: c.listingId, userId: nil, unread: c.unread,
                            messages: messages, pendingReplies: [])
        }
        let jobs = s.jobs.map { j in
            MockJob(jobId: j.jobId, kind: j.kind, targetId: j.targetId, roomStateId: nil, removed: nil,
                    duration: j.duration, startedAt: nil, finished: false)
        }
        return MockDB(storeVersion: currentStoreVersion, seedVersion: s.seedVersion, seq: 1000, agents: s.agents,
                      listings: s.listings, spaces: s.spaces, roomStates: s.roomStates,
                      furniture: s.furniture.map { MockFurniture(furniture: $0, ownerId: nil) },
                      placements: [:], scraps: [:], defaultScraps: s.defaultScraps, chats: chats, jobs: jobs,
                      profiles: [:], users: [:], reportCount: 0)
    }

    /// 시드를 못 읽었을 때 (Resources/Mock 폴더가 번들에 없을 때) 빈 데이터로라도 동작하게
    static func empty() -> MockDB {
        MockDB(storeVersion: currentStoreVersion, seedVersion: 0, seq: 1000, agents: [], listings: [], spaces: [:],
               roomStates: [:], furniture: [], placements: [:], scraps: [:], defaultScraps: [], chats: [], jobs: [],
               profiles: [:], users: [:], reportCount: 0)
    }
}

// MARK: - 파일

/// 데모 데이터의 사진 · 파일 위치.
///  - bundle://Mock/L01_1.jpg      → 앱 번들의 Mock 폴더 (시드 사진)
///  - mockfile://listings/1001/…   → Application Support/DemoData/files (데모 모드에서 올린 사진 · 촬영본)
enum MockFiles {
    static let root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("DemoData", isDirectory: true)
    static var dbURL: URL { root.appendingPathComponent("db.json") }
    static var filesDir: URL { root.appendingPathComponent("files", isDirectory: true) }

    static func isLocal(_ uri: String) -> Bool { uri.hasPrefix("bundle://") || uri.hasPrefix("mockfile://") }

    static func localURL(for uri: String) -> URL? {
        if uri.hasPrefix("bundle://") {
            let rel = String(uri.dropFirst("bundle://".count))
            guard !rel.isEmpty, !rel.contains(".."), let base = Bundle.main.resourceURL else { return nil }
            let inFolder = base.appendingPathComponent(rel)
            if FileManager.default.fileExists(atPath: inFolder.path) { return inFolder }
            // 폴더 참조가 아니라 그룹으로 추가돼 번들 루트에 풀린 경우
            let flat = base.appendingPathComponent((rel as NSString).lastPathComponent)
            return FileManager.default.fileExists(atPath: flat.path) ? flat : nil
        }
        if uri.hasPrefix("mockfile://") {
            let rel = String(uri.dropFirst("mockfile://".count))
            guard !rel.isEmpty, !rel.contains("..") else { return nil }
            return filesDir.appendingPathComponent(rel)
        }
        return nil
    }

    /// files/ 아래에 저장하고 mockfile:// URI 를 돌려준다
    static func save(_ data: Data, as rel: String) throws -> String {
        let url = filesDir.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return "mockfile://" + rel
    }
}

struct MockError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}
