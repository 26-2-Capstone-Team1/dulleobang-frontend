import Foundation

/// SpaceResponse / RoomState 를 뷰어·충돌 판정이 쓰기 편한 형태로 정리한 값.
struct Room {
    var floorY: Double
    var ceilingY: Double
    var bboxMin: Vec3
    var bboxMax: Vec3
    var walls: [Wall]
    var doors: [Opening]
    var windows: [Opening]
    var objects: [SceneObject]
    /// 입주 상태(내가 가구를 뺀 공간)인가. 이때 남아 있는 가구는 개인 가구라도 그대로 남는 것이므로 충돌에 넣는다
    var isMoveIn = false

    var width: Double { bboxMax.x - bboxMin.x }
    var depth: Double { bboxMax.z - bboxMin.z }
    var center: Vec3 { Vec3(x: (bboxMin.x + bboxMax.x) / 2, y: floorY, z: (bboxMin.z + bboxMax.z) / 2) }

    init(space: SpaceResponse) {
        self.init(geometry: space.roomGeometry, dimensions: space.roomDimensions, objects: space.objects)
    }

    /// 입주 상태: 제거된 객체를 뺀 목록으로 교체
    func applying(_ state: RoomState) -> Room {
        var r = self
        r.isMoveIn = true
        if let remaining = state.remainingObjects, !remaining.isEmpty {
            r.objects = remaining
        } else {
            r.objects = objects.filter { !state.removedObjectIds.contains($0.objectId) }
        }
        return r
    }

    init(geometry: RoomGeometry?, dimensions: RoomDimensions?, objects: [SceneObject]) {
        let g = geometry
        floorY = g?.floorHeight ?? 0
        ceilingY = floorY + (g?.ceilingHeight ?? dimensions?.height ?? 2.4)
        walls = (g?.walls ?? []).filter { $0.from.count >= 2 && $0.to.count >= 2 }
        doors = g?.doors ?? []
        windows = g?.windows ?? []
        self.objects = objects

        if let bb = g?.boundingBox {
            bboxMin = bb.min; bboxMax = bb.max
        } else if !walls.isEmpty {
            // 벽 폴리라인에서 bbox 유도
            let xs = walls.flatMap { [$0.from[0], $0.to[0]] }, zs = walls.flatMap { [$0.from[1], $0.to[1]] }
            bboxMin = Vec3(x: xs.min()!, y: floorY, z: zs.min()!)
            bboxMax = Vec3(x: xs.max()!, y: ceilingY, z: zs.max()!)
        } else if let d = dimensions {
            bboxMin = Vec3(x: -d.width / 2, y: floorY, z: -d.depth / 2)
            bboxMax = Vec3(x: d.width / 2, y: ceilingY, z: d.depth / 2)
        } else {
            bboxMin = Vec3(x: -2, y: floorY, z: -2); bboxMax = Vec3(x: 2, y: ceilingY, z: 2)
        }
    }
}
