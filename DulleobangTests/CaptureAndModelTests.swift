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
