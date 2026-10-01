import Foundation

struct CompareResult: Identifiable {
    let listing: Listing
    var roomStateId: String?
    var fits: Bool
    var freeArea: Double           // 바닥 면적 - (남은 기존 가구 + 내 가구) 점유 면적, ㎡
    var blocked: [String]          // 들어가지 않는 가구 이름
    var placements: [Placement]    // 자동 배치 결과 (뷰어에 그대로 넘긴다)
    var errorMessage: String?
    var id: String { listing.listingId }
}

/// 같은 가구 구성을 여러 후보 매물에 자동 배치해 비교한다 (제안서 3.2-5 "가구 배치 및 매물 비교").
/// 내가 만든 입주 상태(개인 가구를 뺀 공간)가 있으면 그 상태를 기준으로, 큰 가구부터 CollisionChecker.autoFit 으로 자리를 찾는다.
enum CompareEngine {
    static func run(listings: [Listing], furniture: [Furniture]) async -> [CompareResult] {
        let ordered = furniture.filter { $0.dimensions != nil }
            .sorted { ($0.dimensions!.width * $0.dimensions!.depth) > ($1.dimensions!.width * $1.dimensions!.depth) }

        var results: [CompareResult] = []
        for l in listings {
            var rsId: String?
            do {
                let space = try await ListingAPI.space(l.listingId)
                var room = Room(space: space)
                if let rs = await RoomStateAPI.latestReady(listingId: l.listingId, spaceVersion: space.spaceVersion) {
                    rsId = rs.roomStateId
                    room = room.applying(rs)
                }
                results.append(evaluate(listing: l, roomStateId: rsId, room: room, furniture: ordered))
            } catch {
                results.append(CompareResult(listing: l, roomStateId: rsId, fits: false, freeArea: 0, blocked: [],
                                             placements: [], errorMessage: error.userMessage))
            }
        }
        return results.sorted {
            if $0.fits != $1.fits { return $0.fits }
            return $0.freeArea > $1.freeArea
        }
    }

    /// 순수 함수 (테스트 가능)
    static func evaluate(listing: Listing, roomStateId: String?, room: Room, furniture: [Furniture]) -> CompareResult {
        var others: [(id: String, rect: Rect2D)] = []
        var placements: [Placement] = []
        var blocked: [String] = []
        for f in furniture {
            guard let d = f.dimensions else { continue }
            if let fit = CollisionChecker.autoFit(d, room: room, others: others) {
                let rect = Rect2D.furniture(x: fit.x, z: fit.z, yaw: fit.yaw, dims: d)
                others.append((f.furnitureId, rect))
                placements.append(Placement(furnitureId: f.furnitureId, position: Vec3(x: fit.x, y: room.floorY, z: fit.z),
                                            rotation: Rotation(yaw: fit.yaw), isPlaceable: true, collisions: []))
            } else {
                blocked.append(f.label)
            }
        }
        let floor = room.width * room.depth
        let occupiedByObjects = room.objects.filter { CollisionChecker.blocks($0, in: room) }
            .reduce(0.0) { $0 + $1.dimensions.width * $1.dimensions.depth }
        let occupiedByMine = others.reduce(0.0) { $0 + $1.rect.area }
        return CompareResult(listing: listing, roomStateId: roomStateId, fits: blocked.isEmpty,
                             freeArea: max(0, floor - occupiedByObjects - occupiedByMine),
                             blocked: blocked, placements: placements, errorMessage: nil)
    }
}
