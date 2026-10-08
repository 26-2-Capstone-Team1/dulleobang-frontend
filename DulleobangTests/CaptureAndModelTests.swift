import XCTest
import simd
@testable import Dulleobang

final class FrameSamplerTests: XCTestCase {
    private func pose(x: Float = 0, z: Float = 0, yawDeg: Float = 0) -> simd_float4x4 {
        var m = simd_float4x4(simd_quatf(angle: yawDeg * .pi / 180, axis: SIMD3(0, 1, 0)))
        m.columns.3 = SIMD4(x, 1.4, z, 1)
        return m
    }

    func testKeepsFirstNormalFrameOnly() {
        var s = FrameSampler(minTranslation: 0.15, minRotationDeg: 10, minInterval: 0.3)
        XCTAssertFalse(s.shouldKeep(pose(), time: 0, tracking: .limited))
        XCTAssertTrue(s.shouldKeep(pose(), time: 0, tracking: .normal))
        XCTAssertFalse(s.shouldKeep(pose(x: 0.5), time: 0.1, tracking: .normal), "간격 0.3초 미만")
        XCTAssertFalse(s.shouldKeep(pose(x: 0.05), time: 1, tracking: .normal), "이동·회전 모두 부족")
        XCTAssertTrue(s.shouldKeep(pose(x: 0.2), time: 1, tracking: .normal), "15cm 이상 이동")
        XCTAssertTrue(s.shouldKeep(pose(x: 0.2, yawDeg: 15), time: 2, tracking: .normal), "10° 이상 회전")
        XCTAssertEqual(s.kept, 3)
        XCTAssertEqual(s.distance, 0.2, accuracy: 1e-5)
    }

    func testCoverageFillsAllBinsAfterFullTurn() {
        var s = FrameSampler(minTranslation: 0.15, minRotationDeg: 10, minInterval: 0)
        for i in 0..<36 { _ = s.shouldKeep(pose(yawDeg: Float(i * 10)), time: Double(i), tracking: .normal) }
        XCTAssertEqual(s.coverage, 1, accuracy: 1e-9)
    }

    func testRotationAngle() {
        XCTAssertEqual(FrameSampler.rotationAngle(pose(yawDeg: 0), pose(yawDeg: 30)), 30 * .pi / 180, accuracy: 1e-4)
        XCTAssertEqual(FrameSampler.rotationAngle(pose(yawDeg: 170), pose(yawDeg: -170)), 20 * .pi / 180, accuracy: 1e-4)
    }

    func testRowMajorMatchesTranslationColumn() {
        let rm = pose(x: 1, z: -2).rowMajor
        XCTAssertEqual(rm[0][3], 1, accuracy: 1e-6)
        XCTAssertEqual(rm[1][3], 1.4, accuracy: 1e-6)
        XCTAssertEqual(rm[2][3], -2, accuracy: 1e-6)
        XCTAssertEqual(rm[3], [0, 0, 0, 1])
    }
}

/// 촬영 중 경고 (CaptureCoach). 10 Hz 폴링을 흉내 내 샘플을 넣는다
final class CaptureCoachTests: XCTestCase {
    /// 높이 1.4 m 에서 yaw(도)만큼 돌아선 카메라
    private func pose(x: Float = 0, z: Float = 0, yawDeg: Double = 0) -> simd_float4x4 {
        var m = simd_float4x4(simd_quatf(angle: Float(yawDeg * .pi / 180), axis: SIMD3(0, 1, 0)))
        m.columns.3 = SIMD4(x, 1.4, z, 1)
        return m
    }

    /// t0 다음부터 0.1초 간격으로 seconds 초 동안 넣고 마지막 시각을 돌려준다. at(t) = (x, z, yaw°)
    @discardableResult
    private func run(_ coach: inout CaptureCoach, from t0: Double = 0, seconds: Double,
                     exposure: Double? = 1.0 / 120, depth: Double? = 1.5, texture: Double? = 20,
                     tracking: TrackingState = .normal, reason: TrackingReason? = nil,
                     at: (Double) -> (Float, Float, Double)) -> Double {
        var t = t0
        for i in 1...max(Int((seconds * 10).rounded()), 1) {
            t = t0 + Double(i) * 0.1
            let (x, z, yaw) = at(t)
            coach.update(.init(time: t, transform: pose(x: x, z: z, yawDeg: yaw), tracking: tracking, reason: reason,
                               exposureS: exposure, fx: 1340, depthM: depth, textureScore: texture))
        }
        return t
    }

    func testTurningInPlaceWarnsStandingStill() {
        var c = CaptureCoach(checksWalking: true)
        run(&c, seconds: 10) { t in (0, 0, t * 10) }                   // 제자리에서 초당 10° (1/120초 → 흔들림 약 2 px)
        XCTAssertEqual(c.alert, .standingStill)
        XCTAssertLessThan(c.blurPx, c.config.warnBlurPx)
        XCTAssertEqual(c.spanM, 0, accuracy: 1e-6)
    }

    func testWalkingClearsStandingStill() {
        var c = CaptureCoach(checksWalking: true)
        let stopAt = run(&c, seconds: 10) { t in (0, 0, t * 10) }
        XCTAssertEqual(c.alert, .standingStill)
        let yaw = stopAt * 10
        run(&c, from: stopAt, seconds: 8) { t in (Float((t - stopAt) * 0.3), 0, yaw) }   // 초당 30 cm 로 걷기
        XCTAssertNil(c.alert)
        XCTAssertGreaterThan(c.spanM, 2)
    }

    func testFurnitureCaptureNeverSaysStandingStill() {
        var c = CaptureCoach(checksWalking: false)
        run(&c, seconds: 20) { t in (0, 0, t * 10) }
        XCTAssertNil(c.alert)
    }

    func testFastTurnWarnsAndDarkRoomSaysTooDark() {
        var fast = CaptureCoach(checksWalking: false)
        run(&fast, seconds: 1, exposure: 1.0 / 120) { t in (0, 0, t * 60) }  // 초당 60° · 셔터 1/120초 → 약 12 px
        XCTAssertEqual(fast.alert, .tooFast)
        XCTAssertGreaterThan(fast.frameBlurPx, fast.config.skipBlurPx, "이만큼 흔들린 프레임은 저장하지 않는다")

        var dark = CaptureCoach(checksWalking: false)
        run(&dark, seconds: 1, exposure: 1.0 / 60) { t in (0, 0, t * 20) }   // 셔터가 최대(1/60초)인 어두운 방: 초당 20° → 약 8 px
        XCTAssertEqual(dark.alert, .tooDark)
    }

    func testOrbitingFurnitureWhileLookingAtItIsNotShaky() {
        // 가구(원점) 주위를 반지름 1.5 m 로 30초에 한 바퀴 돌며 계속 가구를 바라봄 → 회전과 옆 이동이 상쇄돼 가운데는 거의 안 번진다
        var c = CaptureCoach(checksWalking: false)
        run(&c, seconds: 5, exposure: 1.0 / 60) { t in
            let phi = t * 12
            let rad = phi * .pi / 180
            return (Float(1.5 * sin(rad)), Float(1.5 * cos(rad)), phi)
        }
        XCTAssertLessThan(c.frameBlurPx, 1)
        XCTAssertNil(c.alert)
    }

    func testBriefFlickDoesNotAlert() {
        var c = CaptureCoach(checksWalking: false)
        run(&c, seconds: 1) { _ in (0, 0, 0) }
        run(&c, from: 1, seconds: 0.1, exposure: 1.0 / 60) { _ in (0, 0, 6) }  // 0.1초 동안만 6° 휙
        run(&c, from: 1.1, seconds: 1.5) { _ in (0, 0, 6) }
        XCTAssertNil(c.alert)
    }

    func testBlankWallAndTooClose() {
        var blank = CaptureCoach(checksWalking: false)
        run(&blank, seconds: 1.5, texture: 3.4) { _ in (0, 0, 0) }         // 화이트보드만 가득 (실제 촬영본 23번 = 3.4)
        XCTAssertEqual(blank.alert, .featureless)

        var close = CaptureCoach(checksWalking: false)
        run(&close, seconds: 1.5, depth: 0.3) { _ in (0, 0, 0) }
        XCTAssertEqual(close.alert, .tooClose)
    }

    func testTrackingLostComesFirst() {
        var c = CaptureCoach(checksWalking: true)
        run(&c, seconds: 1, texture: 3) { _ in (0, 0, 0) }
        run(&c, from: 1, seconds: 1, texture: 3, tracking: .limited, reason: .relocalizing) { _ in (0, 0, 0) }
        XCTAssertEqual(c.alert, .trackingLost, "무늬 없음보다 추적 끊김이 먼저")
    }

    func testRoomHintAsksToWalkUntilSpanIsReached() {
        var s = FrameSampler(minTranslation: 0.15, minRotationDeg: 10, minInterval: 0)
        for i in 0..<36 { _ = s.shouldKeep(pose(yawDeg: Double(i * 10)), time: Double(i), tracking: .normal) }
        XCTAssertTrue(s.hint(kind: .room, tracking: .normal, spanM: 0.6, minSpanM: 2, goodFrames: 10).contains("걸으면서"))
        XCTAssertTrue(s.hint(kind: .room, tracking: .normal, spanM: 2.4, minSpanM: 2, goodFrames: 100).contains("한 바퀴 더"))
        XCTAssertTrue(s.hint(kind: .room, tracking: .normal, spanM: 2.4, minSpanM: 2, goodFrames: 10).contains("충분히"))
    }

    // MARK: 바닥 (LiDAR)

    /// 바닥(높이 y) 위 원판 모양 점들 (10 cm 간격)
    private func floorPoints(around c: SIMD2<Float>, radius: Float, y: Float = 0) -> [SIMD3<Float>] {
        var pts: [SIMD3<Float>] = []
        for i in stride(from: -radius, through: radius, by: 0.1) {
            for j in stride(from: -radius, through: radius, by: 0.1) where i * i + j * j <= radius * radius {
                pts.append(SIMD3(c.x + i, y, c.y + j))
            }
        }
        return pts
    }

    /// x = 8 에 있는 벽 (높이 0.3 ~ 2.2 m)
    private func wallPoints() -> [SIMD3<Float>] {
        (0..<200).map { i in SIMD3(8, 0.3 + Float(i % 20) * 0.1, Float(i / 20) * 0.3 - 1.5) }
    }

    /// x 방향으로 초당 30 cm 걸으며(정면 = -z) 첫 바퀴를 다 돈 상태로 seconds 초. 0.5초마다 저장한 프레임의 LiDAR 점을 넣는다.
    /// floorAhead = 폰을 아래로 기울여 바닥이 화면에 많이 나옴 (바닥 점 약 150 + 벽 200 → 43%), 아니면 먼 바닥만 조금 (49 + 200 → 20%)
    private func walk(_ c: inout CaptureCoach, seconds: Double, floorAhead: Bool) {
        for i in 1...Int(seconds * 10) {
            let t = Double(i) * 0.1, x = Float(t) * 0.3
            let T = pose(x: x, z: 0)
            c.update(.init(time: t, transform: T, tracking: .normal, exposureS: 1.0 / 120, fx: 1340,
                           depthM: 2, textureScore: 20, directionsCovered: 1))
            if i % 5 == 0 {
                // 수평으로 들면 2 m 넘게 떨어진 바닥만 보이고, 아래로 기울이면 걸어갈 길 바로 앞 바닥이 보인다
                let floor = floorAhead ? floorPoints(around: SIMD2(x + 0.6, 0), radius: 0.7)
                                       : floorPoints(around: SIMD2(x, -2.5), radius: 0.4)
                c.addSavedFrame(points: wallPoints() + floor, camera: T)
            }
        }
    }

    func testLevelPhoneAfterLoopWarnsFloorMissing() {
        var c = CaptureCoach(checksWalking: true)
        walk(&c, seconds: 20, floorAhead: false)
        XCTAssertEqual(c.floorY ?? 99, 0, accuracy: 0.03)
        XCTAssertEqual(c.floorPhotos, 0, "수평으로 들면 바닥은 LiDAR 점의 25% 가 안 된다")
        XCTAssertEqual(c.floorCoverage ?? 1, 0, accuracy: 0.05)
        XCTAssertEqual(c.alert, .floorMissing)
    }

    func testTiltingDownToTheWalkedFloorClearsFloorAlert() {
        var c = CaptureCoach(checksWalking: true)
        walk(&c, seconds: 20, floorAhead: true)
        XCTAssertEqual(c.floorPhotos, 40, "0.5초마다 저장한 40장 모두 바닥 사진")
        XCTAssertGreaterThan(c.floorCoverage ?? 0, 0.9)
        XCTAssertNil(c.alert)
    }

    func testNoFloorAlertWithoutLiDARorBeforeLoop() {
        var noDepth = CaptureCoach(checksWalking: true)
        for i in 1...200 {                                             // LiDAR 점을 한 번도 안 넣음 = LiDAR 없는 기기
            let t = Double(i) * 0.1
            noDepth.update(.init(time: t, transform: pose(x: Float(t) * 0.3), tracking: .normal, exposureS: 1.0 / 120,
                                 depthM: 2, textureScore: 20, directionsCovered: 1))
        }
        XCTAssertNil(noDepth.floorCoverage)
        XCTAssertNil(noDepth.alert)

        var early = CaptureCoach(checksWalking: true)                  // 첫 바퀴 전(방향 절반)이고 60초 전
        for i in 1...200 {
            let t = Double(i) * 0.1, T = pose(x: Float(t) * 0.3)
            early.update(.init(time: t, transform: T, tracking: .normal, exposureS: 1.0 / 120, depthM: 2,
                               textureScore: 20, directionsCovered: 0.5))
            if i % 5 == 0 { early.addSavedFrame(points: wallPoints() + floorPoints(around: SIMD2(0, -2.5), radius: 0.4), camera: T) }
        }
        XCTAssertNil(early.alert)
    }

    func testFloorHeightIsTheLowestBigFlatSurface() {
        var c = CaptureCoach(checksWalking: true)
        let table = (0..<1500).map { i in SIMD3<Float>(Float(i % 40) * 0.02, 0.75, Float(i / 40) * 0.02) }   // 탁자 윗면 (점이 더 많음)
        c.addSavedFrame(points: floorPoints(around: SIMD2(0, 0), radius: 1.0) + table + wallPoints(), camera: pose())
        XCTAssertEqual(c.floorY ?? 99, 0, accuracy: 0.03, "탁자보다 낮은 바닥을 골라야 한다")
    }

    func testHintAsksForFloorPassAfterTheLoop() {
        var s = FrameSampler(minTranslation: 0.15, minRotationDeg: 10, minInterval: 0)
        for i in 0..<36 { _ = s.shouldKeep(pose(yawDeg: Double(i * 10)), time: Double(i), tracking: .normal) }
        let low = s.hint(kind: .room, tracking: .normal, spanM: 2.4, minSpanM: 2, goodFrames: 10, floorCoverage: 0.3)
        XCTAssertTrue(low.contains("바닥") && low.contains("30%"), low)
        XCTAssertTrue(s.hint(kind: .room, tracking: .normal, spanM: 2.4, minSpanM: 2, goodFrames: 10, floorCoverage: 0.9).contains("충분히"))
    }

    func testLowerEntrywayDoesNotBecomeTheRoomFloor() {
        var c = CaptureCoach(checksWalking: true)
        for _ in 0..<10 { c.addSavedFrame(points: floorPoints(around: SIMD2(0, 0), radius: 1.0) + wallPoints(), camera: pose()) }
        // 방 바닥보다 15 cm 낮은 현관 (점은 훨씬 적음) — 방 바닥은 그대로, 현관은 아래 단으로 잡혀 '바닥 사진'으로 센다
        let entry = floorPoints(around: SIMD2(2, 0), radius: 0.8, y: -0.15)          // 약 200점 (방 바닥은 3000점 넘음)
        let share = c.addSavedFrame(points: entry + wallPoints(), camera: pose(x: 2))
        XCTAssertEqual(c.floorY ?? 99, 0, accuracy: 0.03)
        XCTAssertEqual(c.lowerFloors.first ?? 99, -0.15, accuracy: 0.03)
        XCTAssertGreaterThan(share ?? 0, 0.25)
        XCTAssertEqual(c.floorPhotos, 11)
    }

    func testDistantWallsCountInTheFloorShare() {
        // 넓은 방: 먼 벽(5 m 넘음)은 LiDAR 점이 없지만 분모(전체 768점)에는 들어가야 수평 프레임이 '바닥 사진'이 안 된다
        var c = CaptureCoach(checksWalking: true)
        let floor = floorPoints(around: SIMD2(0, -2.5), radius: 0.6)            // 바닥 점 약 110개 (나머지는 5 m 넘어 빠짐)
        c.addSavedFrame(points: floor, samples: 768, camera: pose())
        let share = c.addSavedFrame(points: floor, samples: 768, camera: pose())  // 두 장째에 바닥 높이를 찾는다
        XCTAssertNotNil(c.floorY)
        XCTAssertLessThan(share ?? 1, 0.25)
        XCTAssertEqual(c.floorPhotos, 0)
    }

    func testFeaturelessIsIgnoredWhileLookingDownAtTheFloor() {
        var down = CaptureCoach(checksWalking: false)
        var T = simd_float4x4(simd_quatf(angle: -40 * .pi / 180, axis: SIMD3(1, 0, 0)))   // 40° 숙임
        T.columns.3 = SIMD4(0, 1.4, 0, 1)
        XCTAssertEqual(CaptureCoach.pitchDeg(T), -40, accuracy: 0.1)
        for i in 1...20 { down.update(.init(time: Double(i) * 0.1, transform: T, tracking: .normal, textureScore: 3)) }
        XCTAssertNil(down.alert, "바닥을 내려다볼 때는 '무늬 없는 면' 경고를 띄우지 않는다")
    }

    func testFloorAlertAfterSixtySecondsEvenWithoutTheLoop() {
        var c = CaptureCoach(checksWalking: true)
        for i in 1...700 {
            let t = Double(i) * 0.1, T = pose(x: Float(t) * 0.3)
            c.update(.init(time: t, transform: T, tracking: .normal, exposureS: 1.0 / 120, depthM: 2,
                           textureScore: 20, directionsCovered: 0.5))
            if i % 5 == 0 { c.addSavedFrame(points: wallPoints() + floorPoints(around: SIMD2(Float(t) * 0.3, -2.5), radius: 0.4), camera: T) }
            if i == 600 { XCTAssertNil(c.alert, "60초 전에는 첫 바퀴를 안 끝냈으면 띄우지 않는다") }
        }
        XCTAssertEqual(c.alert, .floorMissing)
    }

    func testRotationVector() {
        let v = CaptureCoach.rotationVector(CaptureCoach.rotation(pose(yawDeg: 10)))
        XCTAssertEqual(v.y, Float(10 * Double.pi / 180), accuracy: 1e-4)
        XCTAssertEqual(v.x, 0, accuracy: 1e-5)
        XCTAssertEqual(CaptureCoach.rotationVector(matrix_identity_float3x3), .zero)
    }
}

final class ModelDecodingTests: XCTestCase {
    func testSpaceResponseDecodes() throws {
        let json = """
        {
          "3dgsUri": "https://storage.example.com/spaces/12/scene_current.ply?sig=abc",
          "roomDimensions": { "width": 3.4, "depth": 2.8, "height": 2.35, "area": 9.52 },
          "roomGeometry": {
            "floorHeight": 0, "ceilingHeight": 2.35,
            "walls": [ { "id": "w1", "from": [-1.7, -1.4], "to": [1.7, -1.4], "height": 2.35 } ],
            "doors": [ { "id": "d1", "type": "door", "position": {"x": 0, "y": 1.05, "z": -1.4},
                         "rotation": {"yaw": 0}, "dimensions": {"width": 0.9, "height": 2.1, "depth": 0.1} } ],
            "windows": []
          },
          "objects": [ { "objectId": "o3", "category": "bed", "position": {"x": 1.2, "y": 0.25, "z": 0.3},
                         "rotation": {"yaw": 90}, "dimensions": {"width": 2.0, "height": 0.5, "depth": 1.5},
                         "ownershipType": null } ],
          "collisionGeometryUri": "https://storage.example.com/spaces/12/collision.glb"
        }
        """
        let s = try JSONDecoder().decode(SpaceResponse.self, from: Data(json.utf8))
        XCTAssertEqual(s.threeDgsUri?.hasSuffix("sig=abc"), true)
        XCTAssertEqual(s.objects.first?.ownershipType, nil)
        let room = Room(space: s)
        XCTAssertEqual(room.width, 3.4, accuracy: 1e-9)      // boundingBox 가 없으면 벽에서 유도
        XCTAssertEqual(room.doors.count, 1)
    }

    func testPlacementEncodesSpecShape() throws {
        let p = Placement(furnitureId: "f1", position: Vec3(x: 1, y: 0, z: -0.5), rotation: Rotation(yaw: 90),
                          isPlaceable: true, collisions: [])
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(PlacementsRequest(placements: [p]))) as? [String: Any]
        let first = (obj?["placements"] as? [[String: Any]])?.first
        XCTAssertEqual(first?["furnitureId"] as? String, "f1")
        XCTAssertEqual((first?["rotation"] as? [String: Any])?["yaw"] as? Double, 90)
    }

    func testAssetURLResolvesRelativePaths() {
        UserDefaults.standard.set("http://192.168.0.10:8080/api", forKey: "baseURL")
        defer { UserDefaults.standard.removeObject(forKey: "baseURL") }
        XCTAssertEqual(AssetURL.resolve("/files/a.ply")?.absoluteString, "http://192.168.0.10:8080/files/a.ply")
        XCTAssertEqual(AssetURL.resolve("https://cdn.x/a.ply")?.absoluteString, "https://cdn.x/a.ply")
        XCTAssertNil(AssetURL.resolve(nil))
    }
}

/// 가구 전체 사진 점검 (FurnitureShotMath · FurnitureShotTracker).
/// 상자들 + 바닥(y = 0)을 카메라에서 광선으로 비춰 LiDAR 깊이 격자(64 × 48, 5 m 넘으면 0)를 흉내 낸다. 크기는 실제 촬영본 capture 4 기준
final class FurnitureShotTests: XCTestCase {
    private let W = 1920, H = 1440
    private let fx: Float = 1450, fy: Float = 1450, cx: Float = 960, cy: Float = 720

    private func box(_ id: String, _ category: String, at c: SIMD3<Float>, size: SIMD3<Float>,
                     yawDeg: Float = 0) -> FurnitureBox {
        var m = simd_float4x4(simd_quatf(angle: yawDeg * .pi / 180, axis: SIMD3(0, 1, 0)))
        m.columns.3 = SIMD4<Float>(c.x, c.y, c.z, 1)
        return FurnitureBox(id: id, category: category, transform: m, dimensions: size)
    }

    /// eye 에서 target 을 보는 카메라 (ARKit 카메라 축: x 오른쪽, y 위, -z 정면)
    private func camera(_ eye: SIMD3<Float>, _ target: SIMD3<Float>) -> simd_float4x4 {
        let z = -simd_normalize(target - eye)
        let x = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), z)), y = simd_cross(z, x)
        return simd_float4x4(columns: (SIMD4(x.x, x.y, x.z, 0), SIMD4(y.x, y.y, y.z, 0),
                                       SIMD4(z.x, z.y, z.z, 0), SIMD4(eye.x, eye.y, eye.z, 1)))
    }

    private func hit(_ b: FurnitureBox, _ o: SIMD3<Float>, _ d: SIMD3<Float>) -> Float? {
        let ol = b.local(o), a = b.axes, h = b.half
        let dl = SIMD3(simd_dot(d, a.x), simd_dot(d, a.y), simd_dot(d, a.z))
        var tmin = -Float.infinity, tmax = Float.infinity
        for i in 0..<3 {
            if abs(dl[i]) < 1e-9 {
                if abs(ol[i]) > h[i] { return nil }
                continue
            }
            let t1 = (-h[i] - ol[i]) / dl[i], t2 = (h[i] - ol[i]) / dl[i]
            tmin = max(tmin, min(t1, t2))
            tmax = min(tmax, max(t1, t2))
        }
        guard tmax >= max(tmin, 0) else { return nil }
        return tmin > 0 ? tmin : tmax
    }

    private func render(_ solids: [FurnitureBox], from T: simd_float4x4) -> DepthGrid {
        let cols = 64, rows = 48
        var meters = [Float](repeating: 0, count: cols * rows)
        let R = simd_float3x3(T.columns.0.xyz, T.columns.1.xyz, T.columns.2.xyz), o = T.columns.3.xyz
        for r in 0..<rows {
            for c in 0..<cols {
                let u = (Float(c) + 0.5) / Float(cols) * Float(W), v = (Float(r) + 0.5) / Float(rows) * Float(H)
                let d = R * SIMD3((u - cx) / fx, -(v - cy) / fy, -1)       // 카메라 z 거리 1 만큼 가는 광선
                var best = Float.infinity
                if d.y < -1e-6 { best = -o.y / d.y }                       // 바닥 y = 0
                for b in solids { if let t = hit(b, o, d) { best = min(best, t) } }
                if best.isFinite, best > 0.2, best < 5 { meters[r * cols + c] = best }
            }
        }
        return DepthGrid(cols: cols, rows: rows, meters: meters)
    }

    private func view(_ solids: [FurnitureBox], eye: SIMD3<Float>, look: SIMD3<Float>, frameId: Int? = nil,
                      time: Double = 0, blur: Double = 0) -> ShotView {
        let T = camera(eye, look)
        return ShotView(frameId: frameId, time: time, transform: T, fx: fx, fy: fy, cx: cx, cy: cy,
                        width: W, height: H, depth: render(solids, from: T), blurPx: blur)
    }

    private func check(_ b: FurnitureBox, eye: SIMD3<Float>, look: SIMD3<Float>? = nil, scene: [FurnitureBox],
                       furniture: [FurnitureBox]? = nil, blur: Double = 0) -> ShotCheck {
        FurnitureShotMath.check(b, in: view(scene, eye: eye, look: look ?? b.center, blur: blur), others: furniture ?? scene)
    }

    private var chair: FurnitureBox { box("chair", "chair", at: SIMD3(0, 0.4, -2), size: SIMD3(0.5, 0.8, 0.5)) }

    /// capture 4 식탁(2.27 × 0.73 × 0.99) + 의자 6개(0.56 × 0.79 × 0.63, 식탁 밑으로 25 cm 넣음)
    private var diningSet: (table: FurnitureBox, chairs: [FurnitureBox]) {
        let table = box("table", "table", at: SIMD3(0, 0.365, -2.6), size: SIMD3(2.27, 0.73, 0.99))
        var chairs: [FurnitureBox] = []
        for (i, x) in [Float(-0.7), 0, 0.7].enumerated() {
            chairs.append(box("near\(i)", "chair", at: SIMD3(x, 0.395, -2.04), size: SIMD3(0.56, 0.79, 0.63)))
            chairs.append(box("far\(i)", "chair", at: SIMD3(x, 0.395, -3.16), size: SIMD3(0.56, 0.79, 0.63), yawDeg: 180))
        }
        return (table, chairs)
    }

    func testWholeChairPassesAndThreeQuarterViewScoresHigher() {
        let front = check(chair, eye: SIMD3(0, 1.4, 0), scene: [chair])
        let quarter = check(chair, eye: SIMD3(1.3, 1.4, -0.7), scene: [chair])
        XCTAssertNil(front.problem)
        XCTAssertNil(quarter.problem)
        XCTAssertEqual(quarter.visible ?? 0, 1, accuracy: 1e-9)
        XCTAssertGreaterThan(quarter.score, front.score, "두 옆면 + 윗면이 보이는 3/4 각도가 더 좋은 대표 사진")
        XCTAssertEqual(quarter.bbox.map { $0.z > $0.x && $0.w > $0.y }, true)
    }

    func testTooCloseTooFarAndBehind() {
        XCTAssertEqual(check(chair, eye: SIMD3(0.6, 1.0, -2.0), scene: [chair]).problem, .notWhole, "옆에서 바짝 붙음")
        let far = box("far", "chair", at: SIMD3(0, 0.4, -6), size: SIMD3(0.5, 0.8, 0.5))
        let farCheck = check(far, eye: SIMD3(0, 1.4, 0), scene: [far])
        XCTAssertEqual(farCheck.problem, .tooFar)
        XCTAssertNil(farCheck.visible, "5 m 넘으면 LiDAR 깊이가 없다")
        XCTAssertEqual(check(chair, eye: SIMD3(0, 1.4, 0), look: SIMD3(0, 1, 2), scene: [chair]).problem, .notInView)
    }

    func testPersonInFrontBlocks() {
        let person = box("person", "person", at: SIMD3(0, 0.85, -1.2), size: SIMD3(0.45, 1.7, 0.3))
        let c = check(chair, eye: SIMD3(0, 1.4, 0), scene: [chair, person], furniture: [chair])
        XCTAssertEqual(c.problem, .blocked)
        XCTAssertNil(c.blockerId, "가구가 아닌 것이 가림")
    }

    func testDiningTableWithTuckedChairsAndCupsPasses() {
        let (table, chairs) = diningSet
        let cups = [box("cup1", "cup", at: SIMD3(0.3, 0.78, -2.5), size: SIMD3(0.08, 0.1, 0.08)),
                    box("cup2", "cup", at: SIMD3(-0.5, 0.8, -2.8), size: SIMD3(0.1, 0.14, 0.1)),
                    box("vase", "cup", at: SIMD3(0, 0.88, -2.6), size: SIMD3(0.15, 0.3, 0.15))]
        let c = check(table, eye: SIMD3(2.6, 1.5, -0.4), look: SIMD3(0, 0.4, -2.6),
                      scene: [table] + chairs + cups, furniture: [table] + chairs)
        XCTAssertNil(c.problem, "식탁에 넣은 의자 · 위에 놓인 컵은 가린 것으로 치지 않는다")
        XCTAssertGreaterThan(c.visible ?? 0, 0.9)
    }

    func testTuckedChairIsBlockedFromTheTableSideButPassesFromItsFreeSide() {
        let table = diningSet.table
        let tucked = box("tucked", "chair", at: SIMD3(0, 0.395, -3.16), size: SIMD3(0.56, 0.79, 0.63), yawDeg: 180)
        let overTable = check(tucked, eye: SIMD3(0, 1.5, -0.6), scene: [table, tucked])
        XCTAssertEqual(overTable.problem, .blocked)
        XCTAssertEqual(overTable.blockerId, "table")
        XCTAssertNil(check(tucked, eye: SIMD3(0, 1.4, -4.9), scene: [table, tucked]).problem)
        XCTAssertEqual(FurnitureShotMath.tucked(tucked, others: [table, tucked], minShare: 0.15), "table")
        XCTAssertNil(FurnitureShotMath.tucked(table, others: [table, tucked], minShare: 0.15))
    }

    func testSofaBehindCoffeeTableNeedsAnAngle() {
        let sofa = box("sofa", "sofa", at: SIMD3(0, 0.425, -3.6), size: SIMD3(2.0, 0.85, 0.9))
        let coffee = box("coffee", "table", at: SIMD3(0, 0.225, -2.7), size: SIMD3(1.0, 0.45, 0.6))
        let front = check(sofa, eye: SIMD3(0, 1.4, -0.6), look: SIMD3(0, 0.4, -3.6), scene: [sofa, coffee])
        XCTAssertEqual(front.problem, .blocked)
        XCTAssertEqual(front.blockerId, "coffee")
        XCTAssertNil(check(sofa, eye: SIMD3(3.0, 1.5, -2.6), look: SIMD3(0, 0.4, -3.6), scene: [sofa, coffee]).problem)
    }

    func testTVOnCabinetDoesNotBlockTheCabinet() {
        let cabinet = box("cab", "storage", at: SIMD3(0, 0.25, -3), size: SIMD3(1.6, 0.5, 0.45))
        let tv = box("tv", "television", at: SIMD3(0, 0.77, -3), size: SIMD3(0.92, 0.54, 0.1))
        XCTAssertNil(check(cabinet, eye: SIMD3(0.3, 1.4, -0.9), look: SIMD3(0, 0.3, -3), scene: [cabinet, tv]).problem)
    }

    func testBlurryFrameAndUnknownDepth() {
        XCTAssertEqual(check(chair, eye: SIMD3(1.3, 1.4, -0.7), scene: [chair], blur: 8).problem, .blurry)
        var v = view([chair], eye: SIMD3(1.3, 1.4, -0.7), look: chair.center)
        v.depth = DepthGrid(cols: 64, rows: 48, meters: [Float](repeating: 0, count: 64 * 48))
        let c = FurnitureShotMath.check(chair, in: v, others: [chair])
        XCTAssertNil(c.problem, "깊이를 못 재면 가려짐은 모름 → 화면 안 · 크기로만 판단")
        XCTAssertNil(c.visible)
    }

    func testTrackerNeedsASavedFrameAndSharesWithSameShapeFurniture() {
        let c1 = chair
        let c2 = box("c2", "chair", at: SIMD3(3, 0.4, -2), size: SIMD3(0.52, 0.8, 0.49), yawDeg: 90)   // 같은 모양 (±6 cm)
        let sofa = box("s", "sofa", at: SIMD3(0, 0.425, 3), size: SIMD3(2, 0.85, 0.9))                 // 카메라 뒤
        var t = FurnitureShotTracker()
        t.updateBoxes([c1, c2, sofa])
        XCTAssertEqual(t.state(of: "chair"), .pending)
        let live = view([c1, c2, sofa], eye: SIMD3(1.3, 1.4, -0.7), look: c1.center, time: 1)
        XCTAssertTrue(t.evaluateLive(live), "아직 전체 사진이 없는 의자가 지금 통과 → 이 프레임을 꼭 저장")
        XCTAssertEqual(t.state(of: "chair"), .pending, "라이브로 통과만 해서는 ✓ 아님")
        var saved = live
        saved.frameId = 0
        t.addSaved(saved)
        XCTAssertEqual(t.state(of: "chair"), .done)
        XCTAssertEqual(t.state(of: "c2"), .shared)
        XCTAssertEqual(t.state(of: "s"), .pending)
        XCTAssertEqual(t.missingLabels, ["소파"])
        XCTAssertEqual(t.chips().map(\.label), ["의자 1", "의자 2", "소파"])
        XCTAssertFalse(t.evaluateLive(live), "이미 ✓ 인 가구만 통과 → 억지로 저장하지 않음")
    }

    func testBoxCorrectedByRoomPlanIsRecheckedWithSavedFrames() {
        var t = FurnitureShotTracker()
        t.updateBoxes([chair])
        t.addSaved(view([chair], eye: SIMD3(1.3, 1.4, -0.7), look: chair.center, frameId: 0))
        XCTAssertEqual(t.state(of: "chair"), .done)
        let moved = box("chair", "chair", at: SIMD3(0, 0.4, 2), size: SIMD3(0.5, 0.8, 0.5))   // RoomPlan 이 자리를 고침 → 그 사진엔 없음
        t.updateBoxes([moved])
        XCTAssertEqual(t.state(of: "chair"), .pending)
        let late = box("late", "chair", at: SIMD3(0, 0.4, -2), size: SIMD3(0.5, 0.8, 0.5))     // 나중에 발견된 가구 → 저장한 프레임으로 바로 ✓
        t.updateBoxes([moved, late])
        XCTAssertEqual(t.state(of: "late"), .done)
        XCTAssertEqual(t.state(of: "chair"), .shared)
    }

    func testTipPointsTowardMissingFurniture() {
        var t = FurnitureShotTracker()
        t.updateBoxes([box("s", "sofa", at: SIMD3(3, 0.425, 0), size: SIMD3(2, 0.85, 0.9), yawDeg: 90)])
        let tip = t.tip(now: 0, camera: camera(SIMD3(0, 1.4, 0), SIMD3(0, 1, -3)))       // 정면(-z)을 봄 → 소파는 오른쪽
        XCTAssertEqual(tip?.problem, .notInView)
        XCTAssertEqual(tip?.turn, .right)
        XCTAssertEqual(tip?.title, "소파 전체 사진이 아직 없어요")
        XCTAssertEqual(t.tip(now: 1, camera: camera(SIMD3(0, 1.4, 0), SIMD3(-3, 1, 0)))?.turn, .behind)
        XCTAssertEqual(t.tip(now: 2, camera: camera(SIMD3(0, 1.4, 0), SIMD3(0, 1, 3)))?.turn, .left)
    }

    func testReportUsesFinalBoxesAndPicksShotsFromDifferentDirections() throws {
        var t = FurnitureShotTracker()
        t.updateBoxes([chair])
        let eyes: [SIMD3<Float>] = [SIMD3(1.3, 1.4, -0.7), SIMD3(-1.3, 1.4, -0.7), SIMD3(1.35, 1.4, -0.75), SIMD3(0, 1.4, -4)]
        for (i, e) in eyes.enumerated() { t.addSaved(view([chair], eye: e, look: chair.center, frameId: i)) }
        // RoomPlan 최종 결과는 id 가 바뀌고 상자도 조금 움직일 수 있다
        let final = box("final-id", "chair", at: SIMD3(0.01, 0.4, -2.01), size: SIMD3(0.5, 0.8, 0.5))
        let file = t.report(finalBoxes: [final])
        XCTAssertEqual(file.frameCount, 4)
        XCTAssertEqual(file.objects.count, 1)
        let e = try XCTUnwrap(file.objects.first)
        XCTAssertEqual(e.objectId, "final-id")
        XCTAssertEqual(e.status, "full")
        XCTAssertEqual(e.shots.count, 3)
        XCTAssertFalse(Set(e.shots.map(\.frameId)).isSuperset(of: [0, 2]), "거의 같은 방향(0번 · 2번)은 하나만")
        XCTAssertEqual(e.shots.first?.bbox?.count, 4)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(file)) as? [String: Any]
        XCTAssertEqual((json?["objects"] as? [[String: Any]])?.first?["status"] as? String, "full")
    }

    func testForceKeepSkipsTheMotionRuleButNotTheInterval() {
        var p = matrix_identity_float4x4
        p.columns.3 = SIMD4(0, 1.4, 0, 1)
        var s = FrameSampler(minTranslation: 0.15, minRotationDeg: 10, minInterval: 0.3)
        XCTAssertTrue(s.shouldKeep(p, time: 0, tracking: .normal))
        XCTAssertFalse(s.shouldKeep(p, time: 1, tracking: .normal), "움직이지 않음")
        XCTAssertTrue(s.shouldKeep(p, time: 1, tracking: .normal, force: true), "가구 전체 사진 → 저장")
        XCTAssertFalse(s.shouldKeep(p, time: 1.1, tracking: .normal, force: true), "간격 0.3초는 지킨다")
        XCTAssertFalse(s.shouldKeep(p, time: 2, tracking: .limited, force: true), "추적이 불안정하면 저장하지 않는다")
    }

    func testHintAsksForFurnitureAfterTheFloor() {
        var s = FrameSampler(minTranslation: 0.15, minRotationDeg: 10, minInterval: 0)
        for i in 0..<36 {
            var m = simd_float4x4(simd_quatf(angle: Float(i * 10) * .pi / 180, axis: SIMD3(0, 1, 0)))
            m.columns.3 = SIMD4(0, 1.4, 0, 1)
            _ = s.shouldKeep(m, time: Double(i), tracking: .normal)
        }
        XCTAssertTrue(s.hint(kind: .room, tracking: .normal, spanM: 2.4, minSpanM: 2, goodFrames: 10,
                             furnitureMissing: 2).contains("가구 2개"))
        XCTAssertTrue(s.hint(kind: .room, tracking: .normal, spanM: 2.4, minSpanM: 2, goodFrames: 10,
                             floorCoverage: 0.5, furnitureMissing: 2).contains("바닥"), "바닥 안내가 먼저")
    }

    func testJosa() {
        XCTAssertEqual(Josa.iGa("소파"), "소파가")
        XCTAssertEqual(Josa.iGa("테이블"), "테이블이")
        XCTAssertEqual(Josa.iGa("의자 1"), "의자 1이")
        XCTAssertEqual(Josa.iGa("의자 2"), "의자 2가")
        XCTAssertEqual(Josa.iGa("TV"), "TV가")
        XCTAssertEqual(Josa.eulReul("소파"), "소파를")
        XCTAssertEqual(Josa.eulReul("테이블"), "테이블을")
    }

    // MARK: 방이 좁을 때 (폰 돌리기 · 촬영 뒤 0.5× 광각)

    /// 세로로 든 폰: 센서 긴 축(x)이 아래, 짧은 축(y)이 화면 오른쪽
    private func portraitCamera(_ eye: SIMD3<Float>, _ target: SIMD3<Float>) -> simd_float4x4 {
        let f = simd_normalize(target - eye), z = -f
        let y = simd_normalize(simd_cross(f, SIMD3<Float>(0, 1, 0))), x = simd_cross(y, z)
        return simd_float4x4(columns: (SIMD4(x.x, x.y, x.z, 0), SIMD4(y.x, y.y, y.z, 0),
                                       SIMD4(z.x, z.y, z.z, 0), SIMD4(eye.x, eye.y, eye.z, 1)))
    }

    private func liveView(_ solids: [FurnitureBox], camera T: simd_float4x4, time: Double, frameId: Int? = nil) -> ShotView {
        ShotView(frameId: frameId, time: time, transform: T, fx: fx, fy: fy, cx: cx, cy: cy, width: W, height: H,
                 depth: render(solids, from: T), blurPx: 0)
    }

    func testWideSofaInPortraitSuggestsTurningThePhone() {
        let sofa = box("sofa", "sofa", at: SIMD3(0, 0.425, -2.6), size: SIMD3(2.4, 0.85, 0.9))
        let eye = SIMD3<Float>(0, 1.2, 0)
        var t = FurnitureShotTracker()
        t.updateBoxes([sofa])
        let portrait = portraitCamera(eye, sofa.center)
        t.evaluateLive(liveView([sofa], camera: portrait, time: 0))
        let tip = t.tip(now: 0, camera: portrait)
        XCTAssertEqual(tip?.problem, .notWhole)
        XCTAssertEqual(tip?.suggestion, .rotateToLandscape, "좌우로만 넘침 → 가로로 들면 좌우가 긴 축(약 65°)")
        XCTAssertTrue(t.evaluateLive(liveView([sofa], camera: camera(eye, sofa.center), time: 1)),
                      "같은 자리에서 가로로 들면 통과 → 이 프레임을 저장")
    }

    func testTallWardrobeSuggestsWideShotAfterWaiting() {
        let wardrobe = box("w", "storage", at: SIMD3(0, 1.1, -1.6), size: SIMD3(1.0, 2.2, 0.6))
        let cam = portraitCamera(SIMD3(0, 1.3, 0), wardrobe.center)
        var config = FurnitureShotConfig()
        config.wideCameraAvailable = true
        var t = FurnitureShotTracker(config: config)
        t.updateBoxes([wardrobe])
        XCTAssertFalse(t.needsWideShot)
        t.evaluateLive(liveView([wardrobe], camera: cam, time: 0))
        let first = t.tip(now: 0, camera: cam)
        XCTAssertEqual(first?.problem, .notWhole)
        XCTAssertNil(first?.suggestion, "위아래로 넘치는데 이미 세로로 들고 있음 → 돌려도 안 된다")
        t.evaluateLive(liveView([wardrobe], camera: cam, time: 9))
        XCTAssertEqual(t.tip(now: 9, camera: cam)?.suggestion, .wideAfterScan, "8초 넘게 못 찍으면 촬영 뒤 0.5× 광각 안내")
        t.addSaved(liveView([wardrobe], camera: cam, time: 10, frameId: 0))
        XCTAssertTrue(t.needsWideShot, "저장한 프레임에서도 다 안 들어옴 → 끝낼 때 광각 사진 제안")
    }

    func testWideShotPlanGroupsSameShapeAndPutsNotWholeFirst() {
        let rule = FurnitureShotsFile.Rule(minVisible: 0.85, minFaceVisible: 0.6, minFill: 0.3, maxBlurPx: 6,
                                           marginFrac: 0.02, twinTolM: 0.06)
        let report = FurnitureShotsFile(rule: rule, frameCount: 10, objects: [
            .init(objectId: "c1", category: "chair", label: "의자 1", status: "missing", problem: "blocked"),
            .init(objectId: "sofa", category: "sofa", label: "소파", status: "missing", problem: "notWhole"),
            .init(objectId: "c2", category: "chair", label: "의자 2", status: "missing", problem: "blocked"),
            .init(objectId: "tv", category: "television", label: "TV", status: "missing", problem: "tooFar"),
            .init(objectId: "bed", category: "bed", label: "침대", status: "full"),
        ])
        let boxes = [box("c1", "chair", at: SIMD3(0, 0.4, 0), size: SIMD3(0.5, 0.8, 0.5)),
                     box("c2", "chair", at: SIMD3(1, 0.4, 0), size: SIMD3(0.52, 0.8, 0.5)),
                     box("sofa", "sofa", at: SIMD3(3, 0.425, 0), size: SIMD3(2, 0.85, 0.9)),
                     box("tv", "television", at: SIMD3(0, 1, 3), size: SIMD3(1, 0.6, 0.1)),
                     box("bed", "bed", at: SIMD3(-3, 0.3, 0), size: SIMD3(1.5, 0.6, 2))]
        let plan = WideShotTarget.plan(report: report, boxes: boxes, tol: 0.06)
        XCTAssertEqual(plan.map(\.objectId), ["sofa", "c1"], "다 안 들어옴 먼저 · 작음(tooFar) · 이미 있음은 빼고")
        XCTAssertEqual(plan.last?.alsoFor, ["c2"], "같은 모양 의자는 한 장으로")
    }
}
