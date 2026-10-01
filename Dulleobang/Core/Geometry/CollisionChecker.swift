import Foundation

/// 상면(top-down) 회전 사각형. 좌표 (x, z) 는 월드 좌표(미터), yaw 는 +Y 축 기준 반시계(위에서 볼 때) 도(°).
/// 로컬 x 축 = (cos yaw, -sin yaw)  ← 오른손 좌표계에서 +Y 회전 R_y(θ)·(1,0,0) 을 XZ 평면에 투영한 것.
struct Rect2D: Equatable {
    var cx: Double, cz: Double
    var hx: Double, hz: Double      // 반크기 (로컬 x, 로컬 z)
    var yawDeg: Double

    /// 배치된 가구: position 은 바닥 접점(하단 중심), dims 는 실제 크기
    static func furniture(x: Double, z: Double, yaw: Double, dims: Dimensions) -> Rect2D {
        Rect2D(cx: x, cz: z, hx: dims.width / 2, hz: dims.depth / 2, yawDeg: yaw)
    }

    /// 인식된 객체 / 문 / 창문: position 은 OBB 중심
    static func obb(_ p: Vec3, yaw: Double, dims: Dimensions, minDepth: Double = 0) -> Rect2D {
        Rect2D(cx: p.x, cz: p.z, hx: dims.width / 2, hz: max(dims.depth / 2, minDepth), yawDeg: yaw)
    }

    var area: Double { 4 * hx * hz }
}

/// 가구 배치 충돌 판정 (순수 Swift, 테스트 가능).
/// 벽·문(여닫는 공간)·창문(창틀보다 높은 가구만)·남아 있는 기존 가구·다른 배치 가구·방 경계를 2D OBB 로 두고
/// SAT(분리축 정리)로 겹침 깊이(overlap, m)를 계산한다. 파이썬으로 동일 시나리오를 재계산해 검증한 로직.
enum CollisionChecker {
    static let wallThickness = 0.10
    static let doorClearance = 0.45     // 문 앞 확보 공간 (반폭 기준 → 0.9 m)
    static let windowMinDepth = 0.15
    private static let eps = 1e-4       // 0.1 mm — 딱 붙은 경우의 부동소수점 오차 흡수

    /// - Parameters:
    ///   - f: 가구 상면 사각형
    ///   - topY: 가구 상단 높이 (창문 판정용)
    ///   - others: 이미 배치된 다른 가구들 (id, 사각형)
    static func check(_ f: Rect2D, topY: Double, room: Room,
                      others: [(id: String, rect: Rect2D)] = []) -> [CollisionInfo] {
        var result: [CollisionInfo] = []

        // 1) 방 경계
        var ex = 0.0
        for c in corners(f) {
            ex = max(ex, room.bboxMin.x - c.x, c.x - room.bboxMax.x, room.bboxMin.z - c.z, c.z - room.bboxMax.z)
        }
        if ex > 1e-3 { result.append(CollisionInfo(with: "bounds", type: "bounds", overlap: ex)) }

        // 2) 벽: from→to 는 실내면. 두께만큼 방 바깥쪽으로 민 얇은 사각형 → 벽면에 딱 붙는 건 허용, 넘으면 겹침.
        let rcx = (room.bboxMin.x + room.bboxMax.x) / 2, rcz = (room.bboxMin.z + room.bboxMax.z) / 2
        for w in room.walls where w.from.count >= 2 && w.to.count >= 2 {
            let ax = w.from[0], az = w.from[1], bx = w.to[0], bz = w.to[1]
            let len = hypot(bx - ax, bz - az)
            guard len > 1e-6 else { continue }
            let dx = (bx - ax) / len, dz = (bz - az) / len
            let mx = (ax + bx) / 2, mz = (az + bz) / 2
            var nx = -dz, nz = dx
            if nx * (mx - rcx) + nz * (mz - rcz) < 0 { nx = -nx; nz = -nz }        // 바깥쪽
            let seg = Rect2D(cx: mx + nx * wallThickness / 2, cz: mz + nz * wallThickness / 2,
                             hx: len / 2, hz: wallThickness / 2,
                             yawDeg: atan2(-dz, dx) * 180 / .pi)
            let d = overlap(f, seg)
            if d > 0 { result.append(CollisionInfo(with: w.id, type: "wall", overlap: d)) }
        }

        // 3) 문: 여닫는 공간까지 막으면 안 됨
        for o in room.doors {
            let r = Rect2D.obb(o.position, yaw: o.rotation.yaw, dims: o.dimensions, minDepth: doorClearance)
            let d = overlap(f, r)
            if d > 0 { result.append(CollisionInfo(with: o.id, type: "door", overlap: d)) }
        }

        // 4) 창문: 가구 상단이 창틀보다 높을 때만
        for o in room.windows {
            let sill = o.position.y - o.dimensions.height / 2
            guard topY > sill else { continue }
            let r = Rect2D.obb(o.position, yaw: o.rotation.yaw, dims: o.dimensions, minDepth: windowMinDepth)
            let d = overlap(f, r)
            if d > 0 { result.append(CollisionInfo(with: o.id, type: "window", overlap: d)) }
        }

        // 5) 남아 있는 기존 가구: 원래 모습에서는 뺄 수 있는 개인 가구를 제외(이사 때 빠진다고 보고),
        //    입주 상태에서는 내가 빼지 않고 남긴 가구까지 모두 넣는다
        for obj in room.objects where CollisionChecker.blocks(obj, in: room) {
            let d = overlap(f, .obb(obj.position, yaw: obj.rotation.yaw, dims: obj.dimensions))
            if d > 0 { result.append(CollisionInfo(with: obj.objectId, type: "object", overlap: d)) }
        }

        // 6) 내가 배치한 다른 가구
        for o in others {
            let d = overlap(f, o.rect)
            if d > 0 { result.append(CollisionInfo(with: o.id, type: "furniture", overlap: d)) }
        }
        return result
    }

    /// 이 가구가 자리를 차지하는가 (충돌 판정 · 매물 비교의 빈 면적 공통 규칙)
    static func blocks(_ obj: SceneObject, in room: Room) -> Bool {
        room.isMoveIn || !obj.canRemove
    }

    /// SAT: 두 OBB 의 최소 겹침 깊이. 겹치지 않으면 0.
    static func overlap(_ a: Rect2D, _ b: Rect2D) -> Double {
        let axes = [axis(a.yawDeg), axis(a.yawDeg + 90), axis(b.yawDeg), axis(b.yawDeg + 90)]
        let dx = b.cx - a.cx, dz = b.cz - a.cz
        var minO = Double.greatestFiniteMagnitude
        for ax in axes {
            let o = project(a, ax) + project(b, ax) - abs(dx * ax.x + dz * ax.z)
            if o <= eps { return 0 }
            minO = min(minO, o)
        }
        return minO
    }

    static func corners(_ r: Rect2D) -> [(x: Double, z: Double)] {
        let ux = axis(r.yawDeg), uz = axis(r.yawDeg + 90)
        return [(1.0, 1.0), (1, -1), (-1, 1), (-1, -1)].map { sx, sz in
            (r.cx + sx * ux.x * r.hx + sz * uz.x * r.hz, r.cz + sx * ux.z * r.hx + sz * uz.z * r.hz)
        }
    }

    private static func axis(_ deg: Double) -> (x: Double, z: Double) {
        let r = deg * .pi / 180
        return (cos(r), -sin(r))
    }

    private static func project(_ r: Rect2D, _ ax: (x: Double, z: Double)) -> Double {
        let ux = axis(r.yawDeg), uz = axis(r.yawDeg + 90)
        return r.hx * abs(ux.x * ax.x + ux.z * ax.z) + r.hz * abs(uz.x * ax.x + uz.z * ax.z)
    }

    /// 방 안에서 충돌 없이 놓을 수 있는 첫 위치를 격자(기본 10 cm, yaw 0°/90°)로 찾는다.
    /// 매물 비교(여러 방에 같은 가구 구성 적용)와 "가구 추가" 시 초기 위치에 쓴다.
    static func autoFit(_ dims: Dimensions, room: Room,
                        others: [(id: String, rect: Rect2D)] = [], step: Double = 0.10) -> (x: Double, z: Double, yaw: Double)? {
        for yaw in [0.0, 90.0] {
            let hx = yaw == 0 ? dims.width / 2 : dims.depth / 2
            let hz = yaw == 0 ? dims.depth / 2 : dims.width / 2
            var x = room.bboxMin.x + hx + wallThickness
            while x <= room.bboxMax.x - hx - wallThickness {
                var z = room.bboxMin.z + hz + wallThickness
                while z <= room.bboxMax.z - hz - wallThickness {
                    let r = Rect2D.furniture(x: x, z: z, yaw: yaw, dims: dims)
                    if check(r, topY: room.floorY + dims.height, room: room, others: others).isEmpty {
                        return (x, z, yaw)
                    }
                    z += step
                }
                x += step
            }
        }
        return nil
    }

    /// 사용자에게 보여줄 한 줄 설명
    static func describe(_ collisions: [CollisionInfo], names: [String: String] = [:]) -> String {
        guard !collisions.isEmpty else { return "배치 가능" }
        var parts: [String] = []
        for c in collisions {
            let s: String
            switch c.type {
            case "wall": s = "벽과 \(Int((c.overlap * 100).rounded()))cm 겹침"
            case "door": s = "문 앞을 막음"
            case "window": s = "창문을 가림"
            case "object": s = "\(Fmt.withAnd(names[c.with] ?? "기존 가구")) 겹침"
            case "furniture": s = "\(Fmt.withAnd(names[c.with] ?? "다른 가구")) 겹침"
            case "bounds": s = "방 밖으로 나감"
            default: s = c.type
            }
            if !parts.contains(s) { parts.append(s) }
        }
        return parts.joined(separator: " · ")
    }
}
