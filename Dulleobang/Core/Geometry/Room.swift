import Foundation
import simd

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
    /// 서버가 찾은 투명 유리 (SpaceResponse.glass). 뷰어가 그리기만 하고 충돌 판정에는 쓰지 않는다
    var glass: [GlassPane] = []
    /// 입주 상태(내가 가구를 뺀 공간)인가. 이때 남아 있는 가구는 개인 가구라도 그대로 남는 것이므로 충돌에 넣는다
    var isMoveIn = false
    /// 서버가 방 구조(벽 또는 범위 상자)를 줬는가. false 면 범위가 임시값이라, 뷰어가 방 메시 크기로 잡아 알려 준다
    var hasGeometry = false

    var width: Double { bboxMax.x - bboxMin.x }
    var depth: Double { bboxMax.z - bboxMin.z }
    /// 벽으로 잰 방 크기 (가로 × 세로 · 면적). 화면에 '실측'으로 보여 줄 때는 width · depth(축에 맞춘 범위) 대신 이것을 쓴다. 벽이 없으면 nil
    var footprint: (width: Double, depth: Double, area: Double)? { Room.footprint(of: walls) }
    var center: Vec3 { Vec3(x: (bboxMin.x + bboxMax.x) / 2, y: floorY, z: (bboxMin.z + bboxMax.z) / 2) }

    init(space: SpaceResponse) {
        self.init(geometry: space.roomGeometry, dimensions: space.roomDimensions, objects: space.objects)
        glass = space.glass
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

    /// 벽으로 잰 방 크기. ARKit 좌표축은 방과 상관없이(촬영을 시작할 때 폰 방향으로) 정해져서, 방이 비스듬하면
    /// 축에 맞춘 범위가 실제보다 커진다 (실서버 시험 매물: 범위 3.94 × 4.08 m · 16.1㎡ ↔ 벽 2.73 × 3.09 m · 8.4㎡, 11.19).
    /// 벽이 주로 향하는 방향으로 돌려서 가로 · 세로를 재고, 벽이 닫힌 고리면 넓이는 그 다각형으로 (ㄱ자 방도 맞게)
    static func footprint(of walls: [Wall]) -> (width: Double, depth: Double, area: Double)? {
        let segs: [(SIMD2<Double>, SIMD2<Double>)] = walls.compactMap { w in
            guard w.from.count >= 2, w.to.count >= 2 else { return nil }
            let a = SIMD2<Double>(w.from[0], w.from[1]), b = SIMD2<Double>(w.to[0], w.to[1])
            return simd_distance(a, b) > 0.05 ? (a, b) : nil
        }
        guard !segs.isEmpty else { return nil }
        // 90° 마다 같은 방향으로 보고(4θ), 길이로 가중해 평균한 벽 방향
        var sx = 0.0, sy = 0.0
        for (a, b) in segs {
            let d: SIMD2<Double> = b - a
            let len = simd_length(d), t = atan2(d.y, d.x)
            sx += len * cos(4 * t)
            sy += len * sin(4 * t)
        }
        let phi = atan2(sy, sx) / 4
        let c = cos(phi), s = sin(phi)
        var xs: [Double] = [], ys: [Double] = []           // 그 방향으로 돌린 벽 끝점
        for (a, b) in segs {
            for p in [a, b] {
                xs.append(p.x * c + p.y * s)
                ys.append(-p.x * s + p.y * c)
            }
        }
        guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max(),
              x1 - x0 > 0.1, y1 - y0 > 0.1 else { return nil }
        let w = x1 - x0, d = y1 - y0
        return (w, d, loopArea(segs) ?? w * d)
    }

    /// 벽이 끝과 끝으로 이어진 닫힌 고리면 그 다각형 넓이, 아니면 nil
    static func loopArea(_ segs: [(SIMD2<Double>, SIMD2<Double>)], tolerance: Double = 0.15) -> Double? {
        guard segs.count >= 3 else { return nil }
        var rest = Array(segs.dropFirst())
        var poly = [segs[0].0, segs[0].1]
        while !rest.isEmpty {
            let end = poly[poly.count - 1]
            guard let i = rest.firstIndex(where: { simd_distance($0.0, end) < tolerance || simd_distance($0.1, end) < tolerance }) else {
                return nil
            }
            let seg = rest.remove(at: i)
            poly.append(simd_distance(seg.0, end) < tolerance ? seg.1 : seg.0)
        }
        guard simd_distance(poly[0], poly[poly.count - 1]) < tolerance else { return nil }
        poly.removeLast()
        var twice = 0.0
        for i in poly.indices {
            let p = poly[i], q = poly[(i + 1) % poly.count]
            twice += p.x * q.y - q.x * p.y
        }
        return abs(twice) / 2
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
        hasGeometry = g?.boundingBox != nil || !walls.isEmpty
    }
}
