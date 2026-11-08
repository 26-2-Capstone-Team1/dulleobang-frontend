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

    /// 지금 설정(AppConfig): 10 Hz 폴링에서 천천히 걸으면 초당 약 5장, 가만히 서 있으면 같은 사진을 쌓지 않는다
    func testRoomRuleSavesAboutFivePerSecondButNotWhileStandingStill() {
        let cfg = AppConfig.shared
        var walk = FrameSampler(minTranslation: cfg.minTranslationM, minRotationDeg: cfg.minRotationDeg, minInterval: cfg.minIntervalSec)
        let jitter = [0, 1, -1]                                      // ARKit 시각은 1/60초 단위라 0.1초 폴링 사이가 4~7 프레임으로 흔들린다
        for i in 0..<100 {                                           // 10초 동안 초당 15 cm 로 옆걸음
            let t = Double(6 * i + (i == 0 ? 0 : jitter[i % 3])) / 60
            _ = walk.shouldKeep(pose(x: Float(t) * 0.15), time: t, tracking: .normal)
        }
        XCTAssertEqual(walk.kept, 50, "폴링 두 번에 한 장 = 초당 5장")

        var still = FrameSampler(minTranslation: cfg.minTranslationM, minRotationDeg: cfg.minRotationDeg, minInterval: cfg.minIntervalSec)
        for i in 0..<50 {                                            // 5초 동안 제자리 (손떨림 ±3 mm · ±0.5°)
            let wobble: Float = i % 2 == 0 ? 0.003 : -0.003
            _ = still.shouldKeep(pose(x: wobble, yawDeg: wobble * 166), time: Double(6 * i) / 60, tracking: .normal)
        }
        XCTAssertEqual(still.kept, 1, "첫 장만 저장")
    }

    func testWouldKeepDoesNotChangeState() {
        var s = FrameSampler(minTranslation: 0.15, minRotationDeg: 10, minInterval: 0.3)
        XCTAssertTrue(s.wouldKeep(pose(), time: 0, tracking: .normal))
        XCTAssertEqual(s.kept, 0, "wouldKeep 은 저장하지 않는다")
        XCTAssertTrue(s.shouldKeep(pose(), time: 0, tracking: .normal))
        XCTAssertFalse(s.wouldKeep(pose(x: 0.05), time: 1, tracking: .normal), "이동·회전 모두 부족")
        XCTAssertTrue(s.wouldKeep(pose(x: 0.2), time: 1, tracking: .normal))
        XCTAssertTrue(s.wouldKeep(pose(x: 0.05), time: 1, tracking: .normal, force: true), "force 는 이동 조건만 건너뜀")
        XCTAssertFalse(s.wouldKeep(pose(x: 0.2), time: 0.1, tracking: .normal, force: true), "간격은 force 여도 지킨다")
        XCTAssertFalse(s.wouldKeep(pose(x: 0.2), time: 1, tracking: .limited))
        XCTAssertEqual(s.kept, 1)
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

    func testSpinningWhileShufflingIsATipNotAWarning() {
        // 옆으로 거의 안 걷고(초당 5 cm) 돌기만(초당 12°) → 1° 에 0.42 cm. 경고는 띄우지 않고 안내 문구에 팁만 (AI 팀: 사진이 많으면 괜찮음)
        var c = CaptureCoach(checksWalking: true)
        run(&c, seconds: 12) { t in (Float(t * 0.05), 0, t * 12) }
        XCTAssertNil(c.alert)
        XCTAssertTrue(c.turnHeavy)

        var sideways = CaptureCoach(checksWalking: true)              // 옆걸음(초당 15 cm)하며 조금씩(초당 3°) 돌면 팁도 없다
        run(&sideways, seconds: 12) { t in (Float(t * 0.15), 0, t * 3) }
        XCTAssertNil(sideways.alert)
        XCTAssertFalse(sideways.turnHeavy)
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

    func testRoomHintTipAndCoveragePrompt() {
        var s = FrameSampler(minTranslation: 0.15, minRotationDeg: 10, minInterval: 0)
        for i in 0..<36 { _ = s.shouldKeep(pose(yawDeg: Double(i * 10)), time: Double(i), tracking: .normal) }
        XCTAssertTrue(s.hint(kind: .room, tracking: .normal, spanM: 2.4, minSpanM: 2, goodFrames: 10, turnHeavy: true).contains("옆으로"),
                      "많이 돌기만 하면 경고 대신 팁")
        let prompt = "뒤쪽 벽에 아직 덜 찍힌 곳이 있어요"
        XCTAssertEqual(s.hint(kind: .room, tracking: .normal, spanM: 2.4, minSpanM: 2, goodFrames: 10,
                              coveragePrompt: prompt, coverageKnown: true), prompt)
        XCTAssertTrue(s.hint(kind: .room, tracking: .normal, spanM: 2.4, minSpanM: 2, goodFrames: 1000,
                             coverageKnown: true).contains("충분히"), "커버리지로 판단하면 '한 바퀴 더' 를 묻지 않는다")
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

    // MARK: 천장 (LiDAR)

    /// 천장(높이 y) 위 원판 모양 점들 (10 cm 간격). 카메라는 1.4 m 높이라 2.4 m 천장은 1 m 위
    private func ceilingPoints(around c: SIMD2<Float>, radius: Float, y: Float = 2.4) -> [SIMD3<Float>] {
        floorPoints(around: c, radius: radius, y: y)
    }

    /// 높이 1.4 m 에서 위로(+) · 아래로(−) pitchDeg 도 든 카메라
    private func tilted(x: Float = 0, z: Float = 0, pitchDeg: Float) -> simd_float4x4 {
        var m = simd_float4x4(simd_quatf(angle: pitchDeg * .pi / 180, axis: SIMD3(1, 0, 0)))
        m.columns.3 = SIMD4(x, 1.4, z, 1)
        return m
    }

    private enum Look { case down, level, up }

    /// 첫 바퀴를 다 돈 상태로 x 방향(dir = ±1)으로 초당 30 cm 걸으며 seconds 초. 0.5초마다 저장한 프레임의 LiDAR 점을 넣고 마지막 시각을 돌려준다.
    /// down = 폰을 아래로 40° (바닥 점 약 150 + 벽 200), up = 위로 40° (천장 점 약 150 + 벽 200 → 43%),
    /// level = 수평 (먼 바닥 · 먼 천장만 조금씩: 각각 약 50점 → 16%)
    @discardableResult
    private func walkLooking(_ c: inout CaptureCoach, from t0: Double = 0, startX: Float = 0, dir: Float = 1,
                             seconds: Double, look: Look) -> Double {
        var t = t0
        for i in 1...Int(seconds * 10) {
            t = t0 + Double(i) * 0.1
            let x = startX + dir * Float(t - t0) * 0.3
            let T = tilted(x: x, pitchDeg: look == .up ? 40 : (look == .down ? -40 : 0))
            c.update(.init(time: t, transform: T, tracking: .normal, exposureS: 1.0 / 120, fx: 1340,
                           depthM: 2, textureScore: 20, directionsCovered: 1))
            if i % 5 == 0 {
                let seen: [SIMD3<Float>]
                switch look {
                case .down: seen = floorPoints(around: SIMD2(x + dir * 0.6, 0), radius: 0.7)
                case .level: seen = floorPoints(around: SIMD2(x, -2.5), radius: 0.4) + ceilingPoints(around: SIMD2(x, -2.5), radius: 0.4)
                case .up: seen = ceilingPoints(around: SIMD2(x + dir * 0.6, 0), radius: 0.7)
                }
                c.addSavedFrame(points: wallPoints() + seen, camera: T)
            }
        }
        return t
    }

    func testCeilingHeightIsTheHighestBigFlatSurface() {
        var c = CaptureCoach(checksWalking: true)
        let wardrobe = (0..<1500).map { i in SIMD3<Float>(Float(i % 40) * 0.02, 2.05, Float(i / 40) * 0.02) }   // 옷장 윗면 (점이 더 많음)
        c.addSavedFrame(points: ceilingPoints(around: SIMD2(0, 0), radius: 1.0) + wardrobe + wallPoints(), camera: pose())
        XCTAssertEqual(c.ceilingY ?? 99, 2.4, accuracy: 0.03, "옷장 윗면보다 높은 천장을 골라야 한다")
    }

    func testLevelPhoneLeavesTheCeilingEmptyAndTiltingUpFillsIt() {
        var c = CaptureCoach(checksWalking: true)
        let t = walkLooking(&c, seconds: 20, look: .level)
        XCTAssertEqual(c.ceilingY ?? 99, 2.4, accuracy: 0.03)
        XCTAssertEqual(c.ceilingPhotos, 0, "수평으로 들면 천장은 LiDAR 점의 25% 가 안 되고 위를 보지도 않는다")
        XCTAssertEqual(c.ceilingCoverage ?? 1, 0, accuracy: 0.05)
        walkLooking(&c, from: t, startX: 6, dir: -1, seconds: 20, look: .up)         // 돌아오면서 폰을 위로 40° 기울임
        XCTAssertEqual(c.ceilingPhotos, 40, "0.5초마다 저장한 40장 모두 천장 사진")
        XCTAssertGreaterThan(c.ceilingCoverage ?? 0, 0.9)
    }

    func testCeilingPhotoNeedsThePhoneTiltedUp() {
        var c = CaptureCoach(checksWalking: true)
        let seen = wallPoints() + ceilingPoints(around: SIMD2(0, 0), radius: 0.7)    // 천장 43%
        c.addSavedFrame(points: seen, camera: tilted(pitchDeg: 5), frameId: 0)
        c.addSavedFrame(points: seen, camera: tilted(pitchDeg: 5), frameId: 1)
        XCTAssertNotNil(c.ceilingY)
        XCTAssertEqual(c.ceilingPhotos, 0, "거의 수평이면 천장이 많이 보여도 천장 사진이 아니다 (바로 위는 안 보임)")
        c.addSavedFrame(points: seen, camera: tilted(pitchDeg: 25), frameId: 2)
        XCTAssertEqual(c.ceilingPhotos, 1)
    }

    func testHintAsksForTheCeilingAfterTheFloorAndBeforeFurniture() {
        var s = FrameSampler(minTranslation: 0.15, minRotationDeg: 10, minInterval: 0)
        for i in 0..<36 { _ = s.shouldKeep(pose(yawDeg: Double(i * 10)), time: Double(i), tracking: .normal) }
        let ask = s.hint(kind: .room, tracking: .normal, spanM: 2.4, minSpanM: 2, goodFrames: 10,
                         floorCoverage: 0.9, ceilingCoverage: 0.2)
        XCTAssertTrue(ask.contains("천장") && ask.contains("20%"), ask)
        let floorFirst = s.hint(kind: .room, tracking: .normal, spanM: 2.4, minSpanM: 2, goodFrames: 10,
                                floorCoverage: 0.3, ceilingCoverage: 0.2)
        XCTAssertTrue(floorFirst.contains("바닥") && !floorFirst.contains("천장"), floorFirst)
        let beforeFurniture = s.hint(kind: .room, tracking: .normal, spanM: 2.4, minSpanM: 2, goodFrames: 10,
                                     floorCoverage: 0.9, ceilingCoverage: 0.2, furnitureMissing: 2)
        XCTAssertTrue(beforeFurniture.contains("천장"), beforeFurniture)
        XCTAssertTrue(s.hint(kind: .room, tracking: .normal, spanM: 2.4, minSpanM: 2, goodFrames: 10,
                             floorCoverage: 0.9, ceilingCoverage: 0.8).contains("충분히"))
        XCTAssertTrue(s.hint(kind: .room, tracking: .normal, spanM: 2.4, minSpanM: 2, goodFrames: 10,
                             floorCoverage: 0.9, ceilingCoverage: nil).contains("충분히"), "포기했거나 LiDAR 가 없으면 천장 단계를 건너뛴다")
    }

    func testCeilingGuideGivesUpWhenCoverageStaysStuck() {
        var c = CaptureCoach(checksWalking: true)
        let t = walkLooking(&c, seconds: 30, look: .down)              // 첫 바퀴 · 바닥 단계를 마치고 7초쯤부터 천장을 안내
        XCTAssertGreaterThan(c.floorCoverage ?? 0, 0.9)
        XCTAssertEqual(c.ceilingCoverage ?? 1, 0, accuracy: 0.05)
        XCTAssertFalse(c.ceilingGaveUp, "안내를 시작한 지 40초가 안 됐다")
        let t2 = walkLooking(&c, from: t, startX: 9, seconds: 30, look: .down)
        XCTAssertTrue(c.ceilingGaveUp, "천장이 40초 동안 하나도 안 늘면 포기한다")
        walkLooking(&c, from: t2, startX: 18, dir: -1, seconds: 20, look: .up)
        XCTAssertTrue(c.ceilingGaveUp, "포기한 뒤에는 다시 안내하지 않는다")
    }

    func testCeilingGuideKeepsAskingWhileCoverageGrows() {
        var c = CaptureCoach(checksWalking: true)
        let t = walkLooking(&c, seconds: 30, look: .down)
        // 걸어온 길을 되짚으며 위를 찍는다: 천장 비율이 계속 늘어서, 안내를 시작한 지 40초가 지나도 포기하지 않는다
        walkLooking(&c, from: t, startX: 9, dir: -1, seconds: 30, look: .up)
        XCTAssertFalse(c.ceilingGaveUp)
        XCTAssertGreaterThan(c.ceilingCoverage ?? 0, 0.9)

        var stuck = CaptureCoach(checksWalking: true)                  // 같은 시간표에서 위를 안 보면 포기한다
        let t2 = walkLooking(&stuck, seconds: 30, look: .down)
        walkLooking(&stuck, from: t2, startX: 9, dir: -1, seconds: 30, look: .down)
        XCTAssertTrue(stuck.ceilingGaveUp)
    }

    func testCeilingGuideWaitsForTheFloorStage() {
        var c = CaptureCoach(checksWalking: true)
        walkLooking(&c, seconds: 60, look: .level)                     // 바닥을 안 찍음 → 바닥 단계가 계속돼 천장 단계는 시작하지 않는다
        XCTAssertLessThan(c.floorCoverage ?? 1, c.config.floorHintBelow)
        XCTAssertFalse(c.ceilingGaveUp)
    }

    func testNoCeilingGuideWithoutLiDAR() {
        var c = CaptureCoach(checksWalking: true)
        for i in 1...600 {                                             // LiDAR 점을 한 번도 안 넣음 = LiDAR 없는 기기
            let t = Double(i) * 0.1
            c.update(.init(time: t, transform: pose(x: Float(t) * 0.3), tracking: .normal, exposureS: 1.0 / 120,
                           depthM: 2, textureScore: 20, directionsCovered: 1))
        }
        XCTAssertNil(c.ceilingCoverage)
        XCTAssertFalse(c.ceilingGaveUp)
    }

    func testFeaturelessIsIgnoredWhileLookingUpAtTheCeiling() {
        var up = CaptureCoach(checksWalking: false)
        let T = tilted(pitchDeg: 40)
        XCTAssertEqual(CaptureCoach.pitchDeg(T), 40, accuracy: 0.1)
        for i in 1...20 { up.update(.init(time: Double(i) * 0.1, transform: T, tracking: .normal, textureScore: 3)) }
        XCTAssertNil(up.alert, "천장을 올려다볼 때는 '무늬 없는 면' 경고를 띄우지 않는다")

        var level = CaptureCoach(checksWalking: false)                 // 같은 흰 화면이라도 수평이면 경고
        for i in 1...20 { level.update(.init(time: Double(i) * 0.1, transform: tilted(pitchDeg: 0), tracking: .normal, textureScore: 3)) }
        XCTAssertEqual(level.alert, .featureless)
    }

    func testCeilingSharesAreRecordedPerSavedFrame() {
        var c = CaptureCoach(checksWalking: true)
        XCTAssertTrue(c.ceilingShares().isEmpty, "천장 높이를 찾기 전에는 비어 있다")
        for id in 0..<3 {
            c.addSavedFrame(points: wallPoints() + ceilingPoints(around: SIMD2(0, 0), radius: 0.7),
                            camera: tilted(pitchDeg: 40), frameId: id)
        }
        let shares = c.ceilingShares()
        XCTAssertEqual(c.ceilingY ?? 99, 2.4, accuracy: 0.03)
        XCTAssertEqual(shares.count, 3)
        XCTAssertEqual(shares[0] ?? 0, 0.43, accuracy: 0.05)
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

    func testSpaceResponseGlass() throws {
        // 서버(glass_tools)가 찾은 유리: glass 배열로 오거나, objects 에 category "glass" 로 섞여 와도 유리로 모은다
        let json = """
        {
          "roomGeometry": { "floorHeight": -1.55, "ceilingHeight": 2.59, "walls": [] },
          "objects": [
            { "objectId": "o1", "category": "bed", "position": {"x": 0, "y": -1.3, "z": 0},
              "rotation": {"yaw": 0}, "dimensions": {"width": 1.1, "height": 0.5, "depth": 2.0} },
            { "objectId": "g9", "category": "glass", "position": {"x": 0.74, "y": -0.31, "z": 0.62},
              "rotation": {"yaw": -179}, "dimensions": {"width": 3.45, "height": 2.49, "depth": 0.01} } ],
          "glass": [ { "objectId": "glass-1", "category": "glass", "glassKind": "window", "node": "glass_0_window",
                       "position": {"x": 0.76, "y": 0.12, "z": -2.04}, "rotation": {"yaw": 1.0},
                       "dimensions": {"width": 2.55, "height": 1.57, "depth": 0.01}, "removable": false } ]
        }
        """
        let s = try JSONDecoder().decode(SpaceResponse.self, from: Data(json.utf8))
        XCTAssertEqual(s.objects.map(\.objectId), ["o1"], "유리는 가구 목록 · 가구 구분에 들어가지 않는다")
        XCTAssertEqual(s.glass.map(\.objectId), ["glass-1", "g9"])
        XCTAssertEqual(s.glass.first?.glassKind, "window")
        XCTAssertNil(s.glass.last?.glassKind)
        XCTAssertEqual(s.glass.first?.dimensions.width ?? 0, 2.55, accuracy: 1e-9)
        XCTAssertEqual(Room(space: s).glass.count, 2)

        // 데모 저장소(MockStore)는 SpaceResponse 를 그대로 인코딩해 둔다 → 유리도 남아야 한다
        let back = try JSONDecoder().decode(SpaceResponse.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.glass.map(\.objectId), ["glass-1", "g9"])
        XCTAssertEqual(back.objects.count, 1)

        // 유리 항목이 잘못 와도 공간은 열린다 (유리만 빠짐)
        let bad = #"{ "objects": [], "glass": [ { "objectId": 1 } ] }"#
        XCTAssertTrue(try JSONDecoder().decode(SpaceResponse.self, from: Data(bad.utf8)).glass.isEmpty)
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

    func testPersonInFrontDoesNotFailButLowersTheScore() {
        let clear = check(chair, eye: SIMD3(0, 1.4, 0), scene: [chair])
        // 사람이 의자 오른쪽 절반쯤을 가림 (RoomPlan 가구가 아니라서 blockerId 는 nil)
        let person = box("person", "person", at: SIMD3(0.30, 0.85, -1.2), size: SIMD3(0.45, 1.7, 0.3))
        let c = check(chair, eye: SIMD3(0, 1.4, 0), scene: [chair, person], furniture: [chair])
        XCTAssertNil(c.problem, "가려져도 가구 전체가 화면 안이면 통과 — 가려진 부분은 SAM 3D 가 메운다")
        XCTAssertGreaterThan(c.visible ?? 0, 0.3)
        XCTAssertLessThan(c.visible ?? 1, 0.85, "가려진 정도는 기록한다")
        XCTAssertNil(c.blockerId, "가구가 아닌 것이 가림")
        XCTAssertLessThan(c.score, clear.score, "덜 가려진 사진이 대표 사진으로 더 좋다")
    }

    func testFurnitureThatIsHiddenAlmostCompletelyIsNotCountedAsSeen() {
        // 사람이 의자를 통째로 가림 (벽 너머와 같다) → 상자는 화면 안이지만 본 것이 아니다
        let person = box("person", "person", at: SIMD3(0, 0.85, -1.2), size: SIMD3(0.45, 1.7, 0.3))
        let c = check(chair, eye: SIMD3(0, 1.4, 0), scene: [chair, person], furniture: [chair])
        XCTAssertEqual(c.problem, .notInView)
        XCTAssertLessThan(c.visible ?? 1, FurnitureShotConfig().minSeen)
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

    func testTuckedChairPassesFromBothSidesAndRecordsTheTableAsTheBlocker() {
        let table = diningSet.table
        let tucked = box("tucked", "chair", at: SIMD3(0, 0.395, -3.16), size: SIMD3(0.56, 0.79, 0.63), yawDeg: 180)
        let overTable = check(tucked, eye: SIMD3(0, 1.5, -0.6), scene: [table, tucked])
        XCTAssertNil(overTable.problem, "식탁 너머로 찍어도 의자 전체가 화면 안이면 통과")
        XCTAssertLessThan(overTable.visible ?? 1, 0.85)
        XCTAssertEqual(overTable.blockerId, "table", "누가 가렸는지는 기록한다")
        let freeSide = check(tucked, eye: SIMD3(0, 1.4, -4.9), scene: [table, tucked])
        XCTAssertNil(freeSide.problem)
        XCTAssertGreaterThan(freeSide.score, overTable.score, "가림 없는 쪽이 대표 사진으로 더 좋다")
        XCTAssertEqual(FurnitureShotMath.tucked(tucked, others: [table, tucked], minShare: 0.15), "table")
        XCTAssertNil(FurnitureShotMath.tucked(table, others: [table, tucked], minShare: 0.15))
    }

    func testSofaBehindCoffeeTablePassesAndTheSideViewScoresHigher() {
        let sofa = box("sofa", "sofa", at: SIMD3(0, 0.425, -3.6), size: SIMD3(2.0, 0.85, 0.9))
        let coffee = box("coffee", "table", at: SIMD3(0, 0.225, -2.7), size: SIMD3(1.0, 0.45, 0.6))
        let front = check(sofa, eye: SIMD3(0, 1.4, -0.6), look: SIMD3(0, 0.4, -3.6), scene: [sofa, coffee])
        XCTAssertNil(front.problem, "커피 테이블이 앞을 가려도 소파 전체가 화면 안이면 통과")
        XCTAssertEqual(front.blockerId, "coffee")
        XCTAssertLessThan(front.visible ?? 1, 0.85)
        let side = check(sofa, eye: SIMD3(3.0, 1.5, -2.6), look: SIMD3(0, 0.4, -3.6), scene: [sofa, coffee])
        XCTAssertNil(side.problem)
        XCTAssertGreaterThan(side.visible ?? 0, front.visible ?? 1)
        XCTAssertGreaterThan(side.score, front.score, "덜 가려진 방향이 대표 사진으로 더 좋다")
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
        XCTAssertEqual(t.chips().map(\.views), [1, 0, 0], "서로 다른 방향 사진 수는 ✓ 인 가구만")
        XCTAssertFalse(t.evaluateLive(live), "이미 ✓ 이고 같은 방향 사진이 있음 → 억지로 저장하지 않음")
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
        XCTAssertEqual(json?["version"] as? Int, 2)
        XCTAssertEqual(file.rule.yawGapDeg, 30)
        XCTAssertNil((json?["objects"] as? [[String: Any]])?.first?["blockedBy"], "가림은 문제가 아니다 — 사진마다 shots[].blockedBy 로만 기록")
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

    /// 12방향을 다 비춘 샘플러
    private func fullCircleSampler() -> FrameSampler {
        var s = FrameSampler(minTranslation: 0.15, minRotationDeg: 10, minInterval: 0)
        for i in 0..<36 {
            var m = simd_float4x4(simd_quatf(angle: Float(i * 10) * .pi / 180, axis: SIMD3(0, 1, 0)))
            m.columns.3 = SIMD4(0, 1.4, 0, 1)
            _ = s.shouldKeep(m, time: Double(i), tracking: .normal)
        }
        return s
    }

    func testHintAsksForFurnitureAfterTheFloor() {
        let s = fullCircleSampler()
        XCTAssertTrue(s.hint(kind: .room, tracking: .normal, spanM: 2.4, minSpanM: 2, goodFrames: 10,
                             furnitureMissing: 2).contains("가구 2개"))
        XCTAssertTrue(s.hint(kind: .room, tracking: .normal, spanM: 2.4, minSpanM: 2, goodFrames: 10,
                             floorCoverage: 0.5, furnitureMissing: 2).contains("바닥"), "바닥 안내가 먼저")
    }

    func testHintMentionsFewViewsOnlyWhenAlreadyReadyToFinish() {
        let s = fullCircleSampler()
        let ready = s.hint(kind: .room, tracking: .normal, spanM: 2.4, minSpanM: 2, goodFrames: 10, furnitureFewViews: 2)
        XCTAssertTrue(ready.contains("종료할 수 있어요"))
        XCTAssertTrue(ready.contains("가구 2개는 다른 방향"), "끝내는 것을 막지 않고 덧붙이기만 한다")
        let missing = s.hint(kind: .room, tracking: .normal, spanM: 2.4, minSpanM: 2, goodFrames: 10,
                             furnitureMissing: 1, furnitureFewViews: 2)
        XCTAssertFalse(missing.contains("다른 방향"), "전체 사진이 없는 가구 안내가 먼저")
        XCTAssertFalse(s.hint(kind: .room, tracking: .normal, spanM: 2.4, minSpanM: 2, goodFrames: 10).contains("다른 방향"))
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
        XCTAssertEqual(tip?.suggestion, .rotateToLandscape, "좌우로만 넘침 → 가로로 들면 좌우가 긴 축(약 67°)")
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

    func testWideShotPlanGroupsSameShapeAndOnlyTakesNotWhole() {
        let rule = FurnitureShotsFile.Rule(minFill: 0.3, maxBlurPx: 6, marginFrac: 0.02, minSeen: 0.05,
                                           twinTolM: 0.06, yawGapDeg: 30)
        let report = FurnitureShotsFile(rule: rule, frameCount: 10, objects: [
            .init(objectId: "c1", category: "chair", label: "의자 1", status: "missing", problem: "notWhole"),
            .init(objectId: "sofa", category: "sofa", label: "소파", status: "missing", problem: "notWhole"),
            .init(objectId: "c2", category: "chair", label: "의자 2", status: "missing", problem: "notWhole"),
            .init(objectId: "tv", category: "television", label: "TV", status: "missing", problem: "tooFar"),
            .init(objectId: "lamp", category: "lamp", label: "조명", status: "missing", problem: "notInView"),
            .init(objectId: "bed", category: "bed", label: "침대", status: "full"),
        ])
        let boxes = [box("c1", "chair", at: SIMD3(0, 0.4, 0), size: SIMD3(0.5, 0.8, 0.5)),
                     box("c2", "chair", at: SIMD3(1, 0.4, 0), size: SIMD3(0.52, 0.8, 0.5)),
                     box("sofa", "sofa", at: SIMD3(3, 0.425, 0), size: SIMD3(2, 0.85, 0.9)),
                     box("tv", "television", at: SIMD3(0, 1, 3), size: SIMD3(1, 0.6, 0.1)),
                     box("bed", "bed", at: SIMD3(-3, 0.3, 0), size: SIMD3(1.5, 0.6, 2))]
        let plan = WideShotTarget.plan(report: report, boxes: boxes, tol: 0.06)
        XCTAssertEqual(plan.map(\.objectId), ["c1", "sofa"], "다 안 들어옴만 · 작음 · 안 보임 · 이미 있음은 뺀다 (가려짐은 문제가 아니다)")
        XCTAssertEqual(plan.first?.alsoFor, ["c2"], "같은 모양 의자는 한 장으로")
    }

    // MARK: 같은 가구를 계속 재촉하지 않는다

    func testTipGivesUpOnAFurnitureItCannotGetButTheReportStillKnowsIt() {
        let wardrobe = box("w", "storage", at: SIMD3(0, 1.1, -1.6), size: SIMD3(1.0, 2.2, 0.6))
        let sofa = box("s", "sofa", at: SIMD3(0, 0.425, 3), size: SIMD3(2, 0.85, 0.9))              // 카메라 뒤
        let cam = portraitCamera(SIMD3(0, 1.3, 0), wardrobe.center)                                   // 세로로 든 폰: 옷장이 위아래로 넘친다
        var config = FurnitureShotConfig()
        config.wideCameraAvailable = true
        var t = FurnitureShotTracker(config: config)
        t.updateBoxes([wardrobe, sofa])
        var v = liveView([wardrobe, sofa], camera: cam, time: 0, frameId: 0)
        func step(_ now: Double) -> FurnitureTip? {
            v.time = now
            t.evaluateLive(v)
            return t.tip(now: now, camera: cam)
        }
        t.addSaved(v)                                                                                 // 저장한 프레임에서도 다 안 들어옴
        XCTAssertEqual(t.activeMissingLabels, ["수납장", "소파"])
        var now = 0.0
        while now < 20 {
            XCTAssertEqual(step(now)?.objectId, "w", "화면에 걸린 옷장을 20초까지 안내 (t=\(now))")
            now += 0.5
        }
        let next = step(20)
        XCTAssertEqual(next?.objectId, "s", "20초 안내해도 안 되면 옷장은 포기하고 다음 가구로")
        XCTAssertEqual(next?.problem, .notInView)
        XCTAssertEqual(t.activeMissingLabels, ["소파"], "화면 아래 힌트 · 끝낼 때 경고에서 옷장은 뺀다")
        XCTAssertEqual(t.missingLabels, ["수납장", "소파"], "하지만 전체 사진이 없는 건 그대로")
        XCTAssertTrue(t.needsWideShot, "0.5× 광각 제안은 남는다")
        for k in 1...10 {
            XCTAssertNotEqual(step(20 + Double(k))?.objectId, "w", "한 번 포기한 가구는 다시 재촉하지 않는다")
        }
        let report = t.report(finalBoxes: nil)
        XCTAssertEqual(report.objects.first { $0.objectId == "w" }?.status, "missing")
        XCTAssertEqual(report.objects.first { $0.objectId == "w" }?.problem, "notWhole")
        XCTAssertEqual(WideShotTarget.plan(report: report, boxes: [wardrobe, sofa], tol: 0.06).map(\.objectId), ["w"],
                       "촬영 뒤 0.5× 광각 대상에는 그대로 남는다")
    }

    func testOffScreenGuidanceAlsoGivesUpButMuchLater() {
        let sofa = box("s", "sofa", at: SIMD3(0, 0.425, 3), size: SIMD3(2, 0.85, 0.9))              // 카메라 뒤
        let cam = camera(SIMD3(0, 1.4, 0), SIMD3(0, 1, -3))
        var t = FurnitureShotTracker()
        t.updateBoxes([sofa])
        var v = liveView([sofa], camera: cam, time: 0)
        for i in 0..<45 {
            v.time = Double(i)
            t.evaluateLive(v)
            XCTAssertEqual(t.tip(now: Double(i), camera: cam)?.turn, .behind, "t=\(i)")
        }
        v.time = 45
        t.evaluateLive(v)
        XCTAssertNil(t.tip(now: 45, camera: cam), "45초 동안 '돌아 보세요' 해도 안 보면 포기")
        XCTAssertEqual(t.activeMissingLabels, [])
        XCTAssertEqual(t.missingLabels, ["소파"])
    }

    // MARK: 가구마다 서로 다른 방향 사진을 되도록 많이

    /// b 중심에서 deg 방향(viewYawDeg 와 같은 각도)으로 r m 떨어진 눈높이 1.4 m 위치
    private func ringEye(_ deg: Float, around b: FurnitureBox, r: Float = 1.8) -> SIMD3<Float> {
        let a = deg * .pi / 180
        return SIMD3(b.center.x + r * sin(a), 1.4, b.center.z + r * cos(a))
    }

    func testACompleteFurnitureKeepsCollectingNewDirectionsUpToTheLimit() {
        var config = FurnitureShotConfig()
        config.shotsPerObject = 3
        var t = FurnitureShotTracker(config: config)
        t.updateBoxes([chair])
        var nextId = 0
        func shoot(_ deg: Float) -> Bool {                                // 라이브 점검 → 저장하라고 하면 저장
            let v = view([chair], eye: ringEye(deg, around: chair), look: chair.center, frameId: nextId, time: Double(nextId))
            let wants = t.evaluateLive(v)
            if wants { t.addSaved(v); nextId += 1 }
            return wants
        }
        XCTAssertTrue(shoot(0), "아직 전체 사진이 없다")
        XCTAssertEqual(t.state(of: "chair"), .done)
        XCTAssertEqual(t.chips().first?.views, 1)
        XCTAssertEqual(t.fewViewsCount, 1, "방향이 1개뿐 (goodViews = 3)")
        XCTAssertFalse(shoot(10), "비슷한 방향(30° 안)은 더 저장하지 않는다")
        XCTAssertTrue(shoot(90), "이미 ✓ 인 가구도 새 방향이면 저장한다")
        XCTAssertFalse(shoot(80))
        XCTAssertTrue(shoot(180))
        XCTAssertEqual(t.chips().first?.views, 3)
        XCTAssertEqual(t.fewViewsCount, 0)
        XCTAssertFalse(shoot(270), "shotsPerObject(3)방향을 채우면 그만")
    }

    func testSharedFurnitureAlsoGetsItsOwnShotsWhenItIsSeenLater() {
        let c1 = chair
        let c2 = box("c2", "chair", at: SIMD3(3, 0.4, -2), size: SIMD3(0.52, 0.8, 0.49), yawDeg: 90)    // 같은 모양
        var t = FurnitureShotTracker()
        t.updateBoxes([c1, c2])
        t.addSaved(view([c1, c2], eye: SIMD3(1.3, 1.4, -0.7), look: c1.center, frameId: 0))
        XCTAssertEqual(t.state(of: "c2"), .shared)
        let live = view([c1, c2], eye: SIMD3(4.3, 1.4, -1.3), look: c2.center, frameId: 1, time: 2)
        XCTAssertTrue(t.evaluateLive(live), "같은 모양으로 대신하던 의자도 따로 찍히면 자기 사진을 모은다")
        t.addSaved(live)
        XCTAssertEqual(t.state(of: "c2"), .done)
        XCTAssertEqual(t.chips().last?.views, 1)
    }

    func testOverflowKeepsANewDirectionEvenIfItsScoreIsLow() throws {
        var config = FurnitureShotConfig()
        config.keepCandidates = 4
        var t = FurnitureShotTracker(config: config)
        t.updateBoxes([chair])
        // 같은 쪽(40~52°)에서 점수 높은 사진이 많이 쌓인 뒤
        for (i, deg) in [Float(40), 43, 46, 49, 52].enumerated() {
            t.addSaved(view([chair], eye: ringEye(deg, around: chair), look: chair.center, frameId: i))
        }
        // 뒤쪽(200°)에서 조금 흔들린 사진 (점수는 낮다)
        t.addSaved(view([chair], eye: ringEye(200, around: chair), look: chair.center, frameId: 5, blur: 5))
        XCTAssertEqual(t.chips().first?.views, 2, "점수가 낮아도 새 방향은 남는다")
        let shots = try XCTUnwrap(t.report(finalBoxes: nil).objects.first?.shots)
        XCTAssertTrue(shots.map(\.frameId).contains(5), "리포트에도 들어간다")
    }

    func testReportRecordsWhoBlockedButStillCountsTheShot() throws {
        let sofa = box("sofa", "sofa", at: SIMD3(0, 0.425, -3.6), size: SIMD3(2.0, 0.85, 0.9))
        let coffee = box("coffee", "table", at: SIMD3(0, 0.225, -2.7), size: SIMD3(1.0, 0.45, 0.6))
        var t = FurnitureShotTracker()
        t.updateBoxes([sofa, coffee])
        t.addSaved(view([sofa, coffee], eye: SIMD3(0, 1.4, -0.6), look: SIMD3(0, 0.4, -3.6), frameId: 0))
        XCTAssertEqual(t.state(of: "sofa"), .done, "커피 테이블이 앞을 가려도 소파 전체가 화면 안이면 ✓")
        let e = try XCTUnwrap(t.report(finalBoxes: nil).objects.first { $0.objectId == "sofa" })
        XCTAssertEqual(e.status, "full")
        XCTAssertNil(e.problem)
        XCTAssertEqual(e.shots.first?.blockedBy, "coffee")
        XCTAssertLessThan(e.shots.first?.visible ?? 1, 0.85)
    }
}

// MARK: - meta.json 의 cameras (카메라 · 왜곡 · 화각 · extrinsic)

final class CameraRigTests: XCTestCase {
    private func pose(_ id: Int, fx: Double, fy: Double) -> PoseRecord {
        PoseRecord(frameId: id, ts: Double(id),
                   T_wc: [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]],
                   K: PoseRecord.Intrinsics(fx: fx, fy: fy, cx: 960, cy: 720),
                   width: 1920, height: 1440, tracking: "normal", depth: true)
    }

    func testFieldOfViewOfPinholeCamera() {
        XCTAssertEqual(CameraRig.fovDeg(size: 2, focal: 1), 90, accuracy: 1e-9, "초점거리 = 폭/2 → 90°")
        XCTAssertEqual(CameraRig.fovDeg(size: 1920, focal: 1445), 67.2, accuracy: 0.1)
        XCTAssertEqual(CameraRig.fovDeg(size: 1440, focal: 1445), 53.0, accuracy: 0.1)
    }

    func testMainCameraBlockUsesMedianIntrinsicsAndDepthScale() {
        let main = CameraRig.Main(colorSize: [1920, 1440], depthSize: [256, 192],
                                  poses: [pose(0, fx: 1440, fy: 1440), pose(1, fx: 1450, fy: 1450), pose(2, fx: 1445, fy: 1445)])
        XCTAssertEqual(main.fxMedian, 1445)
        XCTAssertEqual(main.fovDeg?.horizontalDeg ?? 0, 67.2, accuracy: 0.1)
        XCTAssertEqual(main.fovDeg?.verticalDeg ?? 0, 53.0, accuracy: 0.1)
        XCTAssertEqual(main.depth?.imageSize, [256, 192])
        XCTAssertEqual(main.depth?.colorToDepthScale[0] ?? 0, 256.0 / 1920.0, accuracy: 1e-9)
        XCTAssertEqual(main.depth?.colorToDepthScale[1] ?? 0, 192.0 / 1440.0, accuracy: 1e-9)

        let noDepth = CameraRig.Main(colorSize: [1920, 1440], depthSize: nil, poses: [])
        XCTAssertNil(noDepth.depth, "LiDAR 없는 기기")
        XCTAssertNil(noDepth.fxMedian, "포즈가 없으면 화각도 없음")
        XCTAssertEqual(noDepth.imageSize, [1920, 1440])
    }

    func testDecodeExtrinsicPaddedAndPackedLayouts() {
        // 열 우선 3행 4열. 회전 = z 축 +90° (열: [0,1,0] [-1,0,0] [0,0,1]), 이동 = (-10, 2, 0.5) mm
        let padded: [Float] = [0, 1, 0, 0,   -1, 0, 0, 0,   0, 0, 1, 0,   -10, 2, 0.5, 0]      // 열마다 16바이트 (matrix_float4x3)
        let packed: [Float] = [0, 1, 0,   -1, 0, 0,   0, 0, 1,   -10, 2, 0.5]                    // 12개 float 그대로
        for floats in [padded, packed] {
            let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
            let e = UltraWideCamera.decodeExtrinsic(data)
            XCTAssertEqual(e?.R, [[0, -1, 0], [1, 0, 0], [0, 0, 1]], "R 은 행 우선 \(floats.count)개")
            XCTAssertEqual(e?.t, [-10, 2, 0.5])
        }
        XCTAssertNil(UltraWideCamera.decodeExtrinsic(Data(count: 20)), "너무 짧으면 풀지 않는다")
    }

    func testMetaJsonCarriesSamplingRule() throws {
        var meta = CaptureMeta(captureId: "c", kind: "room", device: "iPhone", os: "17.0", frameCount: 1, roomplan: false,
                               createdAt: "2026-10-25T00:00:00Z")
        let none = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(meta)) as? [String: Any])
        XCTAssertNil(none["sampling"], "규칙을 안 넣으면 키가 없다 (예전 촬영본과 같음)")
        meta.sampling = .init(pollHz: 10, minIntervalS: 0.18, minMoveM: 0.02, minTurnDeg: 2, maxBlurPx: 6, jpegQuality: 0.85)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(meta)) as? [String: Any])
        let s = try XCTUnwrap(obj["sampling"] as? [String: Any])
        XCTAssertEqual(s["minIntervalS"] as? Double, 0.18)
        XCTAssertEqual(s["minMoveM"] as? Double, 0.02)
        XCTAssertEqual(s["maxBlurPx"] as? Double, 6)
    }

    func testMetaJsonCarriesCamerasAndKeepsOldFields() throws {
        let rig = CameraRig(main: CameraRig.Main(colorSize: [1920, 1440], depthSize: [256, 192], poses: [pose(0, fx: 1445, fy: 1445)]))
        let plain = CaptureMeta(captureId: "c", kind: "room", device: "iPhone", os: "17.0", colorSize: [1920, 1440],
                                depthSize: [256, 192], frameCount: 3, roomplan: true,
                                createdAt: "2026-10-08T00:00:00Z", cameras: rig)
        func object(_ m: CaptureMeta) throws -> [String: Any] {
            let data = try JSONEncoder().encode(m)
            let obj = try JSONSerialization.jsonObject(with: data)
            return try XCTUnwrap(obj as? [String: Any])
        }
        let first = try object(plain)
        XCTAssertEqual(first["frameCount"] as? Int, 3, "예전 필드는 그대로")
        let cameras = try XCTUnwrap(first["cameras"] as? [String: Any])
        XCTAssertNotNil(cameras["main"])
        XCTAssertNil(cameras["ultraWide"], "0.5× 를 안 찍었으면 초광각 항목이 없다")

        var full = plain
        full.cameras?.ultraWide = CameraRig.UltraWide(
            deviceType: "AVCaptureDeviceTypeBuiltInUltraWideCamera", name: "Back Ultra Wide Camera", imageSize: [4032, 3024],
            geometricDistortionCorrection: .init(supported: true, enabled: true),
            distortion: CameraRig.Distortion(model: "pinhole", note: "n"),
            fovDeg: .init(horizontalFromK: 100, verticalFromK: 85, horizontalGdcCorrected: 101, horizontalUncorrected: 120),
            extrinsicToMain: CameraRig.Extrinsic(R: [[1, 0, 0], [0, 1, 0], [0, 0, 1]], t_mm: [10, 0, 0]))
        let second = try object(full)
        let ultra = try XCTUnwrap((second["cameras"] as? [String: Any])?["ultraWide"] as? [String: Any])
        XCTAssertEqual((ultra["geometricDistortionCorrection"] as? [String: Any])?["enabled"] as? Bool, true)
        XCTAssertEqual((ultra["extrinsicToMain"] as? [String: Any])?["t_mm"] as? [Double], [10, 0, 0])
        XCTAssertEqual((ultra["fovDeg"] as? [String: Any])?["horizontalUncorrected"] as? Double, 120)
        XCTAssertEqual((ultra["imageSize"] as? [Int]), [4032, 3024])
    }
}

/// capture_log.json · poses.json 진단 항목 · 촬영 전 확인
final class CaptureLogTests: XCTestCase {
    func testTrackingTimelineRecordsInterruptionsWithReasons() {
        var t = TrackingTimeline()
        t.record(ts: 0, state: .limited, reason: .initializing)
        t.record(ts: 0.1, state: .limited, reason: .initializing)
        t.record(ts: 1.0, state: .normal, reason: nil)
        XCTAssertEqual(t.normalFor(at: 3.5) ?? -1, 2.5, accuracy: 1e-9)
        t.record(ts: 5.0, state: .limited, reason: .excessiveMotion)
        XCTAssertNil(t.normalFor(at: 5.0))
        t.record(ts: 5.5, state: .limited, reason: .insufficientFeatures)   // 이유가 바뀌면 새 구간
        t.record(ts: 6.0, state: .normal, reason: nil)
        t.record(ts: 9.0, state: .none, reason: nil)                         // 끝날 때까지 회복 못 함
        XCTAssertEqual(t.events.map(\.reason), ["initializing", "excessiveMotion", "insufficientFeatures", nil])
        XCTAssertEqual(t.events.map(\.startTs), [0, 5.0, 5.5, 9.0])
        XCTAssertEqual(t.events.map(\.endTs), [1.0, 5.5, 6.0, nil])
        XCTAssertEqual(t.events.last?.state, "none")
    }

    func testIsoFromExif() {
        XCTAssertEqual(FrameProbe.iso(["ISOSpeedRatings": [NSNumber(value: 320)]]), 320)
        XCTAssertEqual(FrameProbe.iso(["{Exif}": ["ISOSpeedRatings": [NSNumber(value: 64)]]]), 64)
        XCTAssertNil(FrameProbe.iso(["ExposureTime": 0.01]))
    }

    func testCaptureLogJsonKeys() throws {
        var log = CaptureLog(captureId: "c")
        log.skippedPolls.blurry = 3
        log.tracking = [.init(startTs: 1, endTs: nil, state: "limited", reason: "relocalizing")]
        log.thermal = [.init(ts: 1, state: "serious")]
        log.focus = .init(lockEnabled: true, lockedAtTs: 2, lensPosition: 0.7, relocks: 1, note: nil)
        log.depthSources = ["sceneDepth": 10]
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(log)) as? [String: Any])
        XCTAssertNotNil(obj["stabilization"])
        XCTAssertEqual((obj["skippedPolls"] as? [String: Any])?["blurry"] as? Int, 3)
        let event = try XCTUnwrap((obj["tracking"] as? [[String: Any]])?.first)
        XCTAssertNil(event["endTs"], "회복 못 한 구간은 endTs 가 없다")
        XCTAssertEqual((obj["focus"] as? [String: Any])?["relocks"] as? Int, 1)
        XCTAssertEqual((obj["depthSources"] as? [String: Any])?["sceneDepth"] as? Int, 10)
    }

    func testPreScanChecklistIsShort() {
        let room = PreScanChecklist.items(for: .room)
        XCTAssertEqual(room.count, 3, "찍는 사람에게는 두세 가지만 부탁한다")
        let text = room.map(\.text).joined(separator: " ")
        for word in ["한 바퀴", "좁은 곳", "사람", "불"] { XCTAssertTrue(text.contains(word), word) }
        XCTAssertEqual(PreScanChecklist.items(for: .furniture).count, 3)
    }
}

/// 벽 · 바닥 커버리지 ("이쪽이 아직 덜 찍혔어요")
final class SurfaceCoverageTests: XCTestCase {
    /// 높이 1.25 m 에서 -z 를 바라보는 카메라 (회전 없음)
    private func camera(x: Float = 0, z: Float = 0) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(x, 1.25, z, 1)
        return m
    }

    /// 화면 전체 LiDAR 깊이가 depth 인 프레임 (0 = 측정 없음)
    private func view(_ T: simd_float4x4, depth: Float) -> ShotView {
        ShotView(frameId: nil, time: 0, transform: T, fx: 1445, fy: 1445, cx: 960, cy: 720, width: 1920, height: 1440,
                 depth: DepthGrid(cols: 64, rows: 48, meters: Array(repeating: depth, count: 64 * 48)))
    }

    /// 가운데가 (x, 1.25, z), 가로축이 axis 인 벽
    private func wall(_ id: String, x: Float, z: Float, axis: SIMD3<Float>, width: Float, height: Float = 2.5) -> CoverageWall {
        let up = SIMD3<Float>(0, 1, 0)
        let n = simd_cross(axis, up)
        let m = simd_float4x4(columns: (SIMD4<Float>(axis.x, axis.y, axis.z, 0), SIMD4<Float>(up.x, up.y, up.z, 0),
                                        SIMD4<Float>(n.x, n.y, n.z, 0), SIMD4<Float>(x, 1.25, z, 1)))
        return CoverageWall(id: id, transform: m, width: width, height: height)
    }

    func testWallSeenThreeTimesIsCovered() {
        var t = CoverageTracker()
        t.updateWalls([wall("n", x: 0, z: -2, axis: SIMD3<Float>(1, 0, 0), width: 2, height: 1.2)])
        XCTAssertEqual(t.summary.walls, 0)
        t.addSaved(view(camera(), depth: 2))
        t.addSaved(view(camera(), depth: 2))
        XCTAssertEqual(t.summary.walls, 0, "두 장으로는 부족")
        t.addSaved(view(camera(), depth: 2))
        XCTAssertEqual(t.summary.walls ?? 0, 1, accuracy: 1e-9)
        XCTAssertNil(t.biggestGap())
        XCTAssertNil(t.summary.floor, "벽 하나로는 바닥 다각형을 못 만든다")
    }

    func testWallAlwaysHiddenIsLeftOut() {
        var t = CoverageTracker()
        t.updateWalls([wall("n", x: 0, z: -2, axis: SIMD3<Float>(1, 0, 0), width: 2, height: 1.2)])
        for _ in 0..<3 { t.addSaved(view(camera(), depth: 1)) }        // 1 m 앞에 옷장 → 벽은 매번 가려짐
        XCTAssertNil(t.summary.walls, "찍을 수 없는 곳만 남으면 비율을 내지 않는다")
        XCTAssertEqual(t.summary.blocked, t.summary.samples)
        XCTAssertNil(t.biggestGap())
    }

    func testGapPointsToTheWallBehindYou() throws {
        var cfg = CoverageConfig()
        cfg.floorInsetM = 100                                           // 바닥 점은 빼고 벽만 본다 (벽 두 개로 만든 바닥이 더 넓게 비어 있어서)
        var t = CoverageTracker(config: cfg)
        t.updateWalls([wall("n", x: 0, z: -2, axis: SIMD3<Float>(1, 0, 0), width: 2, height: 1.2),
                       wall("s", x: 0, z: 2, axis: SIMD3<Float>(1, 0, 0), width: 2, height: 1.2)])
        for _ in 0..<3 { t.addSaved(view(camera(), depth: 2)) }        // 앞(북쪽) 벽만 찍음
        XCTAssertEqual(t.summary.walls ?? 0, 0.5, accuracy: 1e-9)
        let gap = try XCTUnwrap(t.biggestGap())
        XCTAssertEqual(gap.kind, .wall)
        XCTAssertEqual(gap.center.z, 2, accuracy: 1e-4)
        let text = CoverageTracker.prompt(gap, camera: camera(), share: 0.5)
        XCTAssertTrue(text.hasPrefix("뒤쪽 벽"), text)
        XCTAssertTrue(text.contains("50%"), text)
    }

    func testDirectionFollowsWhereYouLook() {
        let cam = camera()                                              // -z 를 바라봄
        XCTAssertEqual(CoverageTracker.direction(from: cam, to: SIMD3<Float>(0, 1, -2)), "앞쪽")
        XCTAssertEqual(CoverageTracker.direction(from: cam, to: SIMD3<Float>(2, 1, 0)), "오른쪽")
        XCTAssertEqual(CoverageTracker.direction(from: cam, to: SIMD3<Float>(-2, 1, 0)), "왼쪽")
        XCTAssertEqual(CoverageTracker.direction(from: cam, to: SIMD3<Float>(0, 1, 2)), "뒤쪽")
    }

    func testFloorPolygonFromFourWalls() {
        var t = CoverageTracker()
        t.updateWalls([wall("n", x: 0, z: -1.5, axis: SIMD3<Float>(1, 0, 0), width: 4),
                       wall("s", x: 0, z: 1.5, axis: SIMD3<Float>(1, 0, 0), width: 4),
                       wall("w", x: -2, z: 0, axis: SIMD3<Float>(0, 0, 1), width: 3),
                       wall("e", x: 2, z: 0, axis: SIMD3<Float>(0, 0, 1), width: 3)])
        XCTAssertEqual(t.floorPolygon?.count, 4)
        XCTAssertFalse(t.floorSamples.isEmpty)
        XCTAssertTrue(t.floorSamples.allSatisfy { abs($0.p.y - 0.01) < 1e-4 }, "바닥 높이 = 벽 아래 끝")
        XCTAssertEqual(t.summary.floor, 0)
    }

    func testWallUpdatesKeepOrRecountFromSavedPhotos() {
        var t = CoverageTracker()
        t.updateWalls([wall("n", x: 0, z: -2, axis: SIMD3<Float>(1, 0, 0), width: 2, height: 1.2)])
        for _ in 0..<3 { t.addSaved(view(camera(), depth: 0)) }        // 깊이 없음 → 화면에 들어오면 본 것
        t.updateWalls([wall("n", x: 0.05, z: -2, axis: SIMD3<Float>(1, 0, 0), width: 2, height: 1.2)])   // 5 cm → 그대로
        XCTAssertEqual(t.summary.walls ?? 0, 1, accuracy: 1e-9)
        t.updateWalls([wall("n", x: 0, z: -2.5, axis: SIMD3<Float>(1, 0, 0), width: 2, height: 1.2)])    // 50 cm → 점을 다시 찍고 다시 셈
        XCTAssertEqual(t.summary.walls ?? 0, 1, accuracy: 1e-9, "저장한 사진 3장으로 다시 세어도 다 나온다")
    }
}

/// 손전등 자동 켜기
final class TorchTests: XCTestCase {
    func testDarknessNeedsTwoSecondsOfHighISOAtTheSlowestShutter() {
        var m = DarknessMeter()
        XCTAssertFalse(m.update(time: 0, ambientLumens: nil, exposureS: 1.0 / 60, iso: 1250))
        XCTAssertFalse(m.update(time: 1.9, ambientLumens: nil, exposureS: 1.0 / 60, iso: 1250))
        XCTAssertTrue(m.update(time: 2.0, ambientLumens: nil, exposureS: 1.0 / 60, iso: 1250))
        XCTAssertFalse(m.update(time: 2.1, ambientLumens: nil, exposureS: 1.0 / 120, iso: 1250), "셔터에 여유가 있으면 어둡지 않다")
        XCTAssertFalse(m.update(time: 4.5, ambientLumens: nil, exposureS: 1.0 / 60, iso: 400), "ISO 가 낮으면 어둡지 않다")
    }

    func testDarknessUsesTheLightEstimateWithoutISO() {
        var dark = DarknessMeter()
        XCTAssertFalse(dark.update(time: 0, ambientLumens: 150, exposureS: nil, iso: nil))
        XCTAssertTrue(dark.update(time: 2, ambientLumens: 150, exposureS: nil, iso: nil))
        var bright = DarknessMeter()
        XCTAssertFalse(bright.update(time: 0, ambientLumens: 800, exposureS: nil, iso: nil))
        XCTAssertFalse(bright.update(time: 5, ambientLumens: 800, exposureS: nil, iso: nil))
    }

    func testTorchEventsAreLogged() throws {
        var log = CaptureLog(captureId: "c")
        log.torch.autoEnabled = true
        log.torch.events = [.init(ts: 3, on: true, by: "auto", trigger: "ISO 1250"), .init(ts: 9, on: false, by: "user")]
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(log)) as? [String: Any])
        let torch = try XCTUnwrap(obj["torch"] as? [String: Any])
        XCTAssertEqual(torch["autoEnabled"] as? Bool, true)
        XCTAssertEqual((torch["events"] as? [[String: Any]])?.map { $0["by"] as? String }, ["auto", "user"])
    }
}

/// 덜 찍힌 곳 미니맵 · 화살표
final class CoverageMapTests: XCTestCase {
    private func wall(_ id: String, x: Float, z: Float, width: Float, height: Float) -> CoverageWall {
        let m = simd_float4x4(columns: (SIMD4<Float>(1, 0, 0, 0), SIMD4<Float>(0, 1, 0, 0), SIMD4<Float>(0, 0, 1, 0),
                                        SIMD4<Float>(x, 1.25, z, 1)))
        return CoverageWall(id: id, transform: m, width: width, height: height)
    }

    func testMapPiecesTurnGreenWhenSeenThreeTimes() {
        var t = CoverageTracker()
        t.updateWalls([wall("n", x: 0, z: -2, width: 2, height: 1.2)])
        var cam = matrix_identity_float4x4
        cam.columns.3 = SIMD4<Float>(0, 1.25, 0, 1)
        let grid = DepthGrid(cols: 64, rows: 48, meters: Array(repeating: 2, count: 64 * 48))
        let before = t.map(camera: SIMD2<Float>(0, 0), forward: SIMD2<Float>(0, -1), gap: nil)
        XCTAssertEqual(before.pieces.count, 6, "가로 6칸")
        XCTAssertTrue(before.pieces.allSatisfy { $0.covered == 0 })
        for _ in 0..<3 {
            t.addSaved(ShotView(frameId: nil, time: 0, transform: cam, fx: 1445, fy: 1445, cx: 960, cy: 720,
                                width: 1920, height: 1440, depth: grid))
        }
        let after = t.map(camera: SIMD2<Float>(0, 0), forward: SIMD2<Float>(0, -1), gap: nil)
        XCTAssertTrue(after.pieces.allSatisfy { $0.covered == 1 })
        XCTAssertEqual(after.roomCenter.y, -2, accuracy: 1e-4)
        XCTAssertGreaterThanOrEqual(after.radius, 2, "카메라도 지도 안에 들어온다")
    }

    func testBearingAndWords() {
        let me = SIMD2<Float>(0, 0), north = SIMD2<Float>(0, -1)       // -z 를 바라봄
        XCTAssertEqual(CoverageTracker.bearingDeg(from: me, forward: north, to: SIMD2<Float>(1, 0)), 90, accuracy: 1e-4)
        XCTAssertEqual(CoverageTracker.bearingDeg(from: me, forward: north, to: SIMD2<Float>(-1, 0)), -90, accuracy: 1e-4)
        XCTAssertEqual(CoverageTracker.bearingDeg(from: me, forward: north, to: SIMD2<Float>(0, -2)), 0, accuracy: 1e-4)
        XCTAssertEqual(abs(CoverageTracker.bearingDeg(from: me, forward: north, to: SIMD2<Float>(0, 2))), 180, accuracy: 1e-4)
        XCTAssertEqual(CoverageTracker.word(forBearing: 30), "앞쪽")
        XCTAssertEqual(CoverageTracker.word(forBearing: 100), "오른쪽")
        XCTAssertEqual(CoverageTracker.word(forBearing: -100), "왼쪽")
        XCTAssertEqual(CoverageTracker.word(forBearing: 170), "뒤쪽")
        let info = CoverageGapInfo(kind: .wall, bearingDeg: 100, share: 0.74)
        XCTAssertEqual(info.title, "오른쪽 벽이 덜 찍혔어요")
        XCTAssertTrue(info.detail.contains("74%"))
        let underfoot = CoverageGapInfo(kind: .floor, bearingDeg: 0, share: 0.5, near: true)
        XCTAssertEqual(underfoot.title, "발밑 바닥이 덜 찍혔어요")
        XCTAssertTrue(underfoot.detail.hasPrefix("폰을 아래로 기울여"))
    }

    func testMapTurnsSoYouAlwaysFaceUp() {
        let map = CoverageMap(forward: SIMD2<Float>(1, 0), roomCenter: SIMD2<Float>(0, 0), radius: 2)   // +x 를 바라봄
        let project = map.projector(size: CGSize(width: 100, height: 100), padding: 0)
        let ahead = project(SIMD2<Float>(1, 0)), right = project(SIMD2<Float>(0, 1))
        XCTAssertEqual(ahead.x, 50, accuracy: 1e-6)
        XCTAssertLessThan(ahead.y, 50, "바라보는 쪽이 위")
        XCTAssertGreaterThan(right.x, 50, "+x 를 볼 때 +z 는 오른쪽")
        XCTAssertEqual(right.y, 50, accuracy: 1e-6)
    }
}
