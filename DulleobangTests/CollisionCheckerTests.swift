import XCTest
@testable import Dulleobang

/// 파이썬으로 먼저 검증한 시나리오를 그대로 옮긴 테스트. 3.0 × 4.0 m 방, 층고 2.4 m,
/// 문은 z = -2 벽, 창문(창틀 0.9 m)은 z = +2 벽.
final class CollisionCheckerTests: XCTestCase {
    private func room(objects: [SceneObject] = []) -> Room {
        let g = RoomGeometry(
            floorHeight: 0, ceilingHeight: 2.4,
            walls: [
                Wall(id: "w1", from: [-1.5, -2], to: [1.5, -2], height: 2.4),
                Wall(id: "w2", from: [1.5, -2], to: [1.5, 2], height: 2.4),
                Wall(id: "w3", from: [1.5, 2], to: [-1.5, 2], height: 2.4),
                Wall(id: "w4", from: [-1.5, 2], to: [-1.5, -2], height: 2.4),
            ],
            doors: [Opening(id: "d1", type: "door", position: Vec3(x: 0, y: 1.05, z: -2), rotation: Rotation(yaw: 0),
                            dimensions: Dimensions(width: 0.9, height: 2.1, depth: 0.1))],
            windows: [Opening(id: "win1", type: "window", position: Vec3(x: 0, y: 1.5, z: 2), rotation: Rotation(yaw: 0),
                              dimensions: Dimensions(width: 1.2, height: 1.2, depth: 0.1))],
            boundingBox: BoundingBox(min: Vec3(x: -1.5, y: 0, z: -2), max: Vec3(x: 1.5, y: 2.4, z: 2)))
        return Room(geometry: g, dimensions: nil, objects: objects)
    }

    private let bed = Dimensions(width: 1.5, height: 0.5, depth: 2.0)
    private func bedRect(_ x: Double, _ z: Double, yaw: Double = 0) -> Rect2D { .furniture(x: x, z: z, yaw: yaw, dims: bed) }

    func testOverlapSeparatedIsZero() {
        let a = Rect2D(cx: 0, cz: 0, hx: 0.5, hz: 0.5, yawDeg: 0)
        let b = Rect2D(cx: 2, cz: 0, hx: 0.5, hz: 0.5, yawDeg: 0)
        XCTAssertEqual(CollisionChecker.overlap(a, b), 0)
    }

    func testOverlapDepthAxisAligned() {
        let a = Rect2D(cx: 0, cz: 0, hx: 0.5, hz: 0.5, yawDeg: 0)
        let b = Rect2D(cx: 0.8, cz: 0, hx: 0.5, hz: 0.5, yawDeg: 0)
        XCTAssertEqual(CollisionChecker.overlap(a, b), 0.2, accuracy: 1e-6)
    }

    func testOverlapRotated45() {
        let a = Rect2D(cx: 0, cz: 0, hx: 0.5, hz: 0.5, yawDeg: 0)
        XCTAssertGreaterThan(CollisionChecker.overlap(a, Rect2D(cx: 1.1, cz: 0, hx: 0.5, hz: 0.5, yawDeg: 45)), 0)
        XCTAssertEqual(CollisionChecker.overlap(a, Rect2D(cx: 1.3, cz: 0, hx: 0.5, hz: 0.5, yawDeg: 45)), 0)
    }

    func testBedInCenterFits() {
        XCTAssertTrue(CollisionChecker.check(bedRect(0, 0), topY: 0.5, room: room()).isEmpty)
    }

    func testBedPastWallReportsOverlap() {
        let c = CollisionChecker.check(bedRect(1.5 - 0.75 + 0.03, 0), topY: 0.5, room: room())
        let w2 = c.first { $0.with == "w2" }
        XCTAssertEqual(w2?.type, "wall")
        XCTAssertEqual(w2?.overlap ?? 0, 0.03, accuracy: 1e-3)
    }

    func testBedTouchingWallIsAllowed() {
        let c = CollisionChecker.check(bedRect(1.5 - 0.75, 0), topY: 0.5, room: room())
        XCTAssertFalse(c.contains { $0.type == "wall" })
    }

    func testBedInFrontOfDoorIsBlocked() {
        let c = CollisionChecker.check(bedRect(0, -2 + 1.0 + 0.15), topY: 0.5, room: room())
        XCTAssertTrue(c.contains { $0.type == "door" })
    }

    func testWindowDependsOnHeight() {
        let low = Rect2D(cx: 0, cz: 2 - 0.3 - 0.06, hx: 0.5, hz: 0.3, yawDeg: 0)
        XCTAssertFalse(CollisionChecker.check(low, topY: 0.5, room: room()).contains { $0.type == "window" })
        XCTAssertTrue(CollisionChecker.check(low, topY: 1.8, room: room()).contains { $0.type == "window" })
    }

    func testPersonalObjectsIgnoredRentalOptionsBlock() {
        let objs = [
            SceneObject(objectId: "o1", category: "desk", position: Vec3(x: 0, y: 0.4, z: 0), rotation: Rotation(yaw: 0),
                        dimensions: Dimensions(width: 1, height: 0.8, depth: 0.6), ownershipType: "PERSONAL"),
            SceneObject(objectId: "o2", category: "refrigerator", position: Vec3(x: 0, y: 0.9, z: 0), rotation: Rotation(yaw: 0),
                        dimensions: Dimensions(width: 0.6, height: 1.8, depth: 0.6), ownershipType: "RENTAL_OPTION"),
        ]
        let c = CollisionChecker.check(Rect2D(cx: 0, cz: 0, hx: 0.5, hz: 0.5, yawDeg: 0), topY: 0.5, room: room(objects: objs))
        XCTAssertFalse(c.contains { $0.with == "o1" })
        XCTAssertTrue(c.contains { $0.with == "o2" && $0.type == "object" })
    }

    /// 입주 상태에서는 내가 빼지 않고 남긴 개인 가구도 자리를 차지한다
    func testKeptPersonalObjectBlocksInMoveInState() {
        let objs = [
            SceneObject(objectId: "desk", category: "desk", position: Vec3(x: 0, y: 0.4, z: 0), rotation: Rotation(yaw: 0),
                        dimensions: Dimensions(width: 1, height: 0.8, depth: 0.6), ownershipType: "PERSONAL"),
            SceneObject(objectId: "bed", category: "bed", position: Vec3(x: 0, y: 0.4, z: 0), rotation: Rotation(yaw: 0),
                        dimensions: Dimensions(width: 1, height: 0.8, depth: 2), ownershipType: "PERSONAL"),
        ]
        let moveIn = room(objects: objs).applying(RoomState(roomStateId: "rs", removedObjectIds: ["bed"]))
        XCTAssertTrue(moveIn.isMoveIn)
        let c = CollisionChecker.check(Rect2D(cx: 0, cz: 0, hx: 0.5, hz: 0.5, yawDeg: 0), topY: 0.5, room: moveIn)
        XCTAssertTrue(c.contains { $0.with == "desk" })          // 남긴 책상은 부딪힌다
        XCTAssertFalse(c.contains { $0.with == "bed" })          // 뺀 침대는 없다
    }

    func testOtherPlacedFurnitureCollides() {
        let other = (id: "f2", rect: Rect2D(cx: 0.3, cz: 0, hx: 0.5, hz: 0.5, yawDeg: 0))
        let c = CollisionChecker.check(Rect2D(cx: 0, cz: 0, hx: 0.5, hz: 0.5, yawDeg: 0), topY: 0.5, room: room(), others: [other])
        XCTAssertTrue(c.contains { $0.with == "f2" && $0.type == "furniture" })
    }

    func testRotatedWallDetected() {
        let g = RoomGeometry(floorHeight: 0, ceilingHeight: 2.4, walls: [Wall(id: "wd", from: [-2, -2], to: [2, 2], height: 2.4)],
                             doors: [], windows: [],
                             boundingBox: BoundingBox(min: Vec3(x: -3, y: 0, z: -3), max: Vec3(x: 3, y: 2.4, z: 3)))
        let r = Room(geometry: g, dimensions: nil, objects: [])
        let c = CollisionChecker.check(Rect2D(cx: 0, cz: 0, hx: 0.5, hz: 0.5, yawDeg: 45), topY: 0.5, room: r)
        XCTAssertTrue(c.contains { $0.type == "wall" })
    }

    func testAutoFit() {
        XCTAssertNotNil(CollisionChecker.autoFit(bed, room: room()))
        XCTAssertNil(CollisionChecker.autoFit(Dimensions(width: 3.2, height: 1, depth: 4.1), room: room()))
    }

    func testCompareEvaluatePlacesLargestFirst() {
        let wardrobe = Furniture(furnitureId: "a", name: "옷장", category: "closet", status: "COMPLETED", modelUri: "x.glb",
                                 dimensions: Dimensions(width: 1.2, height: 2.0, depth: 0.6))
        let big = Furniture(furnitureId: "b", name: "침대", category: "bed", status: "COMPLETED", modelUri: "y.glb", dimensions: bed)
        let listing = Listing(listingId: "L1", location: "흑석동", price: Price(deposit: 500, monthly: 50))
        let r = CompareEngine.evaluate(listing: listing, roomStateId: nil, room: room(), furniture: [big, wardrobe])
        XCTAssertTrue(r.fits)
        XCTAssertEqual(r.placements.count, 2)
        XCTAssertLessThan(r.freeArea, 12)
    }
}
