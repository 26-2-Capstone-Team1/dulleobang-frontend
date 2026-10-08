import Foundation
import simd

enum CaptureKind: String, Codable { case room, furniture }

enum TrackingState: String, Codable { case normal, limited, none }

/// ARKit 이 추적이 불안정하다고 알려 준 이유 (ARCamera.TrackingState.Reason 을 ARKit 없이 쓰기 위한 사본)
enum TrackingReason: Equatable { case initializing, excessiveMotion, insufficientFeatures, relocalizing, other }

struct CaptureStats: Equatable {
    var kept = 0
    var spanM: Float = 0              // 카메라가 실제로 움직인 범위 (바닥 기준 가로·세로 상자의 대각선)
    var coverage: Double = 0          // 0…1, 12방향 중 촬영된 비율
    var tracking: TrackingState = .none
    var hasDepth = false
    var alert: CaptureAlert?          // 지금 화면에 띄울 경고 (없으면 nil)
    var floorCoverage: Double?        // 걸어온 길 중 바닥 사진을 찍은 곳의 비율 (LiDAR 없으면 nil)
    var furniture: [FurnitureChip] = []  // 가구별 전체 사진 상태 (방 촬영 · RoomPlan 이 찾은 가구, FurnitureShotTracker)
    var furnitureTip: FurnitureTip?   // 첫 바퀴 뒤, 아직 전체 사진이 없는 가구 하나를 안내 (없으면 nil)
    var hint = "시작 버튼을 눌러 촬영을 시작하세요"
}

/// 어떤 AR 프레임을 저장할지 결정하고(이동·회전·간격 기준), 촬영 가이드용 커버리지를 집계한다.
/// 흔들림 · 제자리 촬영 같은 실시간 경고는 아래 CaptureCoach 가 맡는다. ARKit 에 의존하지 않아 테스트 가능.
struct FrameSampler {
    static let yawBinCount = 12

    let minTranslation: Float
    let minRotationRad: Float
    let minInterval: Double

    private(set) var kept = 0
    private(set) var distance: Float = 0          // 저장한 프레임 사이 이동 거리의 합 (손떨림도 쌓이므로 가이드에는 쓰지 않음)
    private var last: simd_float4x4?
    private var lastTime = -Double.infinity
    private var yawBins = [Bool](repeating: false, count: FrameSampler.yawBinCount)

    init(minTranslation: Float, minRotationDeg: Float, minInterval: Double) {
        self.minTranslation = minTranslation
        self.minRotationRad = minRotationDeg * .pi / 180
        self.minInterval = minInterval
    }

    var coverage: Double { Double(yawBins.filter { $0 }.count) / Double(Self.yawBinCount) }

    /// 저장해야 하면 true 를 반환하고 내부 상태(누적 거리, 커버리지)를 갱신한다.
    /// force = 이동 · 회전 기준을 건너뛰고 저장 (아직 전체 사진이 없는 가구가 지금 화면에서 통과할 때). 간격 · 추적 상태는 그대로 본다
    mutating func shouldKeep(_ T: simd_float4x4, time: Double, tracking: TrackingState, force: Bool = false) -> Bool {
        guard tracking == .normal, time - lastTime >= minInterval else { return false }
        if let last {
            let dT = simd_distance(T.columns.3.xyz, last.columns.3.xyz)
            let dR = Self.rotationAngle(last, T)
            guard force || dT >= minTranslation || dR >= minRotationRad else { return false }
            distance += dT
        }
        last = T
        lastTime = time
        kept += 1
        yawBins[Self.yawBin(T)] = true
        return true
    }

    /// 카메라 forward(-Z 열)를 XZ 평면에 투영한 방향의 12등분 인덱스
    static func yawBin(_ T: simd_float4x4) -> Int {
        let f = -T.columns.2.xyz
        let yaw = atan2(f.x, -f.z)                                   // -π…π
        let bin = Int(((yaw + .pi) / (2 * .pi)) * Float(yawBinCount))
        return min(max(bin, 0), yawBinCount - 1)
    }

    /// 두 포즈 사이 회전각 (라디안, 0…π)
    static func rotationAngle(_ a: simd_float4x4, _ b: simd_float4x4) -> Float {
        let qa = simd_quatf(simd_float3x3(a.columns.0.xyz, a.columns.1.xyz, a.columns.2.xyz))
        let qb = simd_quatf(simd_float3x3(b.columns.0.xyz, b.columns.1.xyz, b.columns.2.xyz))
        var ang = (qa.inverse * qb).angle
        if ang > .pi { ang = 2 * .pi - ang }
        return ang
    }

    /// 화면 아래 안내 문구. spanM = 카메라가 실제로 움직인 범위, floorCoverage = 걸어온 길 중 바닥을 찍은 곳의 비율 (CaptureCoach),
    /// furnitureMissing = 아직 전체 사진이 없는 가구 수 (FurnitureShotTracker, 같은 모양 가구로 대신할 수 있는 것은 뺌)
    func hint(kind: CaptureKind, tracking: TrackingState, spanM: Float, minSpanM: Float, goodFrames: Int,
              floorCoverage: Double? = nil, floorTarget: Double = 0.85, furnitureMissing: Int = 0) -> String {
        switch tracking {
        case .none: return "카메라를 천천히 움직여 주변을 비춰 주세요"
        case .limited: return "위치를 잡는 중이에요. 천천히 움직여 주세요"
        case .normal: break
        }
        let covered = Int((coverage * Double(Self.yawBinCount)).rounded())
        switch kind {
        case .furniture:
            if covered < Self.yawBinCount { return "가구 주위를 한 바퀴 돌아 주세요 (\(covered)/\(Self.yawBinCount) 방향)" }
            return "충분합니다. 위에서 내려다보는 각도를 추가하면 더 좋아요"
        case .room:
            if spanM < minSpanM {
                return "벽을 따라 걸으면서 찍어 주세요 (이동 범위 \(String(format: "%.1f", spanM))/\(String(format: "%.0f", minSpanM)) m)"
            }
            if covered < Self.yawBinCount { return "아직 비추지 않은 방향이 있어요 (\(covered)/\(Self.yawBinCount))" }
            if let floor = floorCoverage, floor < floorTarget {
                return "이제 폰을 아래로 30~45° 기울여 걸어온 길의 바닥을 찍어 주세요 (바닥 \(Int((floor * 100).rounded()))%)"
            }
            if furnitureMissing > 0 {
                return "가구 \(furnitureMissing)개는 아직 전체 사진이 없어요. 위 목록의 회색 가구를 하나씩 전체가 한 화면에 들어오게 찍어 주세요"
            }
            if kept < goodFrames { return "좋아요. 높이를 바꿔 한 바퀴 더 돌면 더 선명해져요 (\(kept)/\(goodFrames)장)" }
            return "충분히 촬영했습니다. 종료할 수 있어요"
        }
    }
}

// MARK: - 촬영 중 경고

/// 촬영 중 화면에 띄우는 경고. allCases 순서 = 우선순위 (앞일수록 먼저 보여 준다)
enum CaptureAlert: String, CaseIterable, Equatable {
    case trackingLost        // 위치 추적이 끊김
    case tooDark             // tooFast 와 같은 조건인데 셔터가 길다(어둡다) → "불을 켜거나" 를 덧붙인다
    case tooFast             // 너무 빨리 돌리거나 움직여서 흔들림
    case featureless         // 무늬 없는 면(흰 벽 · 화이트보드)만 화면에 가득
    case tooClose            // 벽 · 물체에 너무 가까움
    case standingStill       // 제자리에서 돌리기만 함 (방 촬영)
    case floorMissing        // 첫 바퀴를 돌았는데 바닥 사진(LiDAR 로 확인)이 걸어온 길 대부분에서 없음 (방 촬영)

    var title: String {
        switch self {
        case .trackingLost: return "위치를 놓쳤어요"
        case .tooDark: return "어두워서 사진이 흔들려요"
        case .tooFast: return "너무 빨라요 · 사진이 흔들려요"
        case .featureless: return "무늬 없는 면만 보여요"
        case .tooClose: return "너무 가까워요"
        case .standingStill: return "제자리에서만 찍고 있어요"
        case .floorMissing: return "바닥이 거의 안 찍혔어요"
        }
    }

    var detail: String {
        switch self {
        case .trackingLost: return "방금 찍은 곳을 천천히 다시 비춰 주세요"
        case .tooDark: return "불을 켜거나 더 천천히 움직여 주세요"
        case .tooFast: return "천천히 움직여 주세요. 많이 흔들린 사진은 저장하지 않아요"
        case .featureless: return "가구 · 문 · 모서리가 함께 보이게 조금 물러나 비춰 주세요"
        case .tooClose: return "한 걸음 물러나 넓게 비춰 주세요"
        case .standingStill: return "벽을 따라 걸으면서 찍어야 3D가 선명하게 나와요"
        case .floorMissing: return "폰을 아래로 30~45° 기울여 걸어온 길의 바닥이 화면 절반쯤 보이게 찍어 주세요"
        }
    }

    var icon: String {
        switch self {
        case .trackingLost: return "location.slash.fill"
        case .tooDark: return "lightbulb.fill"
        case .tooFast: return "tortoise.fill"
        case .featureless: return "square.dashed"
        case .tooClose: return "hand.raised.fill"
        case .standingStill: return "figure.walk"
        case .floorMissing: return "arrow.down.to.line"
        }
    }

    /// 빨강 = 지금 찍히는 사진이 망가지는 중, 주황 = 결과가 나빠지는 촬영 습관
    var isSevere: Bool { self == .trackingLost || self == .tooDark || self == .tooFast }

    /// 조건이 이만큼(초) 이어져야 띄운다 — 잠깐 스치는 동작으로 깜빡이지 않게
    var onDelay: Double {
        switch self {
        case .trackingLost: return 0.5
        case .tooDark, .tooFast: return 0.4
        case .featureless, .tooClose, .standingStill: return 1.0
        case .floorMissing: return 6.0                     // 안내 문구를 보고 폰을 기울일 시간을 준다
        }
    }

    /// 조건이 사라지고 이만큼(초) 지나야 내린다
    var offDelay: Double { self == .standingStill || self == .floorMissing ? 2.0 : 1.0 }
}

/// 촬영 중 실시간 점검. CaptureRecorder 가 폴링(10 Hz)마다 update 를 부른다. ARKit 에 의존하지 않는 순수 로직이라 테스트 가능.
///  - 흔들림: 직전 폴링과의 움직임으로 구한 화면 가운데 점의 이동 속도 × 셔터 시간 = 사진에서 번지는 픽셀 수(예상)
///    (회전과 옆 이동이 서로 상쇄되는 경우 — 가구 주위를 돌며 가구를 계속 바라볼 때 — 도 반영)
///  - 제자리: 15초가 지나도 이동 범위가 1 m 미만이고 걷지 않거나, 최근 8초 동안 35 cm 도 안 움직이고 60° 이상 돌아섬
///  - 무늬 없음 / 너무 가까움: 화면 밝기 변화 점수, LiDAR 가운데 깊이
///  - 바닥: 저장한 프레임의 LiDAR 점으로 바닥 높이(가장 낮은 수평면)를 찾고, 바닥이 화면의 25% 이상인 '바닥 사진'이
///    걸어온 길(카메라가 지나간 자리) 곳곳에서 찍혔는지 센다. 첫 바퀴가 끝났는데 60% 미만이고 폰이 수평이면 '바닥이 거의 안 찍혔어요'
///    (실제 촬영본 capture 3: 바닥 사진 152장 중 2장 → 걸어온 길의 18% → 3DGS 바닥에 구멍. 이 경고가 93초에 떴을 것)
struct CaptureCoach {
    struct Config {
        var warnBlurPx = 5.0             // 예상 흔들림(px, 컬러 1920 폭 기준)이 이 이상이면 '너무 빨라요' (1/60초면 초당 약 13°)
        var skipBlurPx = 10.0            // 이 이상 흔들린 프레임은 저장하지 않는다 (CaptureRecorder 가 사용)
        var darkExposureS = 1.0 / 75     // 흔들릴 때 셔터(평활)가 이보다 길면 '어두워서 흔들려요'. ARKit 은 60 fps 라 최대 1/60초
        var tooCloseM = 0.45             // 화면 가운데 깊이가 이보다 가까우면 '너무 가까워요'
        var featurelessScore = 6.0       // 밝기 변화 점수가 이보다 낮으면 '무늬 없는 면' (화이트보드 3.4 · 보통 장면 10 이상)
        var stillAfterS = 15.0           // 촬영 시작 후 이만큼 지났는데
        var stillSpanM = 1.0             // 이동 범위가 이보다 좁고 요즘 걷지 않으면 '제자리'
        var stillWindowS = 8.0           // 또는 최근 이 시간 동안
        var stillMoveM = 0.35            // 이만큼도 움직이지 않고
        var stillTurnDeg = 60.0          // 바라보는 방향(수평)이 이 이상 바뀌었으면 '제자리'
        var recentWalkM = 0.5            // 최근 창에서 이만큼 움직였으면 지금 걷는 중으로 본다
        var fallbackExposureS = 1.0 / 60 // 셔터 시간을 모를 때
        var fallbackDepthM = 2.0         // 깊이를 모를 때 (LiDAR 없는 기기)
        // 바닥 (LiDAR)
        var floorCellM: Float = 0.2      // 걸어온 길 칸 크기
        var floorBinM: Float = 0.02      // 바닥 높이 찾기용 높이 칸
        var floorTolM: Float = 0.05      // 바닥 높이 ± 이만큼 = 바닥 점
        var floorLookShare = 0.25        // LiDAR 점 중 바닥이 이 비율 이상이면 '바닥 사진' (수평으로 들면 보통 5% 안팎)
        var floorClusterMin = 150        // 가장 낮은 수평면으로 인정할 최소 점 수
        var floorMinBelowCamM: Float = 0.5   // 바닥은 카메라보다 0.5 ~ 2.2 m 아래
        var floorMaxBelowCamM: Float = 2.2
        var floorResetM: Float = 0.08    // 바닥 높이 추정이 이만큼 바뀌면 다시 센다
        var floorLevelWindowM: Float = 0.25  // 바로 위 25 cm 안에 3배 넘게 큰 수평면이 있으면 그쪽이 방 바닥 (현관 · 욕실 · 베란다는 아래 단으로)
        var walkRadiusM: Float = 0.25    // 카메라가 지나간 자리 ± 이만큼 = 걸어온 길
        var floorPassRadiusM: Float = 0.5    // 바닥 사진을 찍은 자리 ± 이만큼은 바닥을 찍은 것으로 본다
        var floorMinWalkedCells = 10     // 걸어온 칸이 이보다 적으면 아직 판단하지 않음
        var floorAlertBelow = 0.6        // 걸어온 길 중 바닥 사진을 찍은 곳이 이보다 적으면 경고 · 끝낼 때 확인
        var floorHintBelow = 0.85        // 이보다 적으면 안내 문구에 '바닥 찍기' 단계
        var floorAfterS = 60.0           // 첫 바퀴를 못 끝내도 이 시간이 지나면 바닥 경고를 본다
        var loopSpanM: Float = 2.0       // 첫 바퀴 완료 = 12방향 + 이동 범위 이만큼 (AppConfig.roomMinSpanM 과 같게)
        var lookingDownDeg: Float = -20  // 이보다 아래를 보고 있으면 바닥을 찍는 중으로 본다
    }

    struct Sample {
        var time: Double                     // ARFrame.timestamp (초)
        var transform: simd_float4x4         // 카메라 → 월드 (ARKit: x 오른쪽, y 위, -z 정면)
        var tracking: TrackingState
        var reason: TrackingReason? = nil    // tracking == .limited 일 때 ARKit 이 알려 준 이유
        var exposureS: Double? = nil         // ARCamera.exposureDuration (초)
        var fx: Double = 1340                // 컬러 해상도 기준 초점거리 (px)
        var depthM: Double? = nil            // 화면 가운데 깊이 중앙값 (미터, LiDAR 없으면 nil)
        var textureScore: Double? = nil      // 화면 밝기 변화 점수 (FrameProbe.textureScore)
        var directionsCovered: Double = 0    // 12방향 중 찍은 비율 (FrameSampler.coverage) → 첫 바퀴 완료 판단
    }

    /// 바닥 칸 (월드 x · z 를 floorCellM 로 나눈 정수 좌표)
    struct Cell: Hashable { var x: Int32; var z: Int32 }

    let config: Config
    let checksWalking: Bool                  // 방 촬영만 '제자리' 를 본다

    private(set) var blurPx = 0.0            // 예상 흔들림 (px), 지수 평활 → 경고용
    private(set) var frameBlurPx = 0.0       // 이번 폴링의 예상 흔들림 (px) → 저장 여부 · poses.json 용
    private(set) var spanM = 0.0             // 추적이 정상일 때 카메라가 지나간 범위 (바닥 기준 상자의 대각선, m)
    private(set) var alert: CaptureAlert?
    /// 마지막으로 받은 샘플 시각 (같은 프레임을 두 번 넣지 않도록 CaptureRecorder 가 본다)
    private(set) var lastSampleTime: Double?

    private var startTime: Double?
    private var last: (time: Double, transform: simd_float4x4)?
    private var box: (minX: Float, maxX: Float, minZ: Float, maxZ: Float)?
    private var exposureEMA = 0.0            // 셔터 시간(초), 평활 → tooFast 를 tooDark 로 보여 줄지
    private var window: [(time: Double, xz: SIMD2<Float>, heading: Double)] = []   // 최근 stillWindowS 초 (추적 정상일 때만)
    private var onSince: [CaptureAlert: Double] = [:]
    private var offSince: [CaptureAlert: Double] = [:]
    private var active: Set<CaptureAlert> = []
    // 바닥 (LiDAR)
    private(set) var floorY: Float?          // 추정한 방 바닥 높이 (ARKit 월드 y, m)
    private(set) var lowerFloors: [Float] = []   // 방 바닥보다 6~25 cm 낮은 바닥 (현관 · 욕실 · 베란다)
    private var countedFloors: [Float] = []  // 바닥 사진을 마지막으로 다시 셀 때 쓴 바닥 높이들
    private(set) var hasDepth = false        // LiDAR 점이 한 번이라도 들어왔는지
    private var heightBins: [Int: Int] = [:] // 저장한 프레임의 LiDAR 점 높이 히스토그램
    private var heightTotal = 0
    private var camYSum = 0.0, camYCount = 0
    private var savedFrames: [(id: Int, cam: SIMD3<Float>, heights: [Float], samples: Int)] = []   // 바닥 높이가 바뀌면 다시 세려고 보관
    private var floorPassed: Set<Cell> = []  // 바닥 사진을 찍은 자리 주변 칸
    private(set) var floorPhotos = 0         // 바닥 사진(바닥이 화면의 25% 이상) 수
    private var walked: Set<Cell> = []

    init(config: Config = Config(), checksWalking: Bool) {
        self.config = config
        self.checksWalking = checksWalking
    }

    @discardableResult
    mutating func update(_ s: Sample) -> CaptureAlert? {
        if startTime == nil { startTime = s.time }
        lastSampleTime = s.time
        if let e = s.exposureS, e > 0 { exposureEMA = exposureEMA == 0 ? e : 0.8 * exposureEMA + 0.2 * e }
        updateMotion(s)
        if s.tracking == .normal { updatePlace(s) }
        debounce(conditions(s), at: s.time)
        let shown = active
        var top = CaptureAlert.allCases.first { shown.contains($0) }
        // 흔들림 경고는 하나의 조건으로 켜고 끄고, 보여 줄 때만 셔터 길이로 문구를 고른다 (깜빡임 방지)
        if top == .tooFast, exposureEMA >= config.darkExposureS { top = .tooDark }
        alert = top
        return alert
    }

    // MARK: 흔들림

    private mutating func updateMotion(_ s: Sample) {
        // 추적이 불안정할 때의 포즈는 튈 수 있어 속도를 재지 않고, 다시 정상이 되면 새로 시작한다
        guard s.tracking == .normal else {
            last = nil
            frameBlurPx = 0
            blurPx *= 0.5
            return
        }
        defer { last = (time: s.time, transform: s.transform) }
        guard let prev = last else { return }
        let dt = s.time - prev.time
        guard dt > 0.001, dt < 0.5 else {                  // 같은 프레임이거나 한참 끊겼으면 속도를 재지 않는다
            frameBlurPx = 0
            return
        }
        let r0 = Self.rotation(prev.transform), r1 = Self.rotation(s.transform)
        // 카메라 좌표계(x 오른쪽, y 위, -z 정면)에서 본 각속도 · 이동 속도
        let w = Self.rotationVector(r0.transpose * r1) / Float(dt)
        let v = r1.transpose * (s.transform.columns.3.xyz - prev.transform.columns.3.xyz) / Float(dt)
        // 화면 가운데(거리 depth)에 있는 점이 화면에서 움직이는 속도 (rad/s). z 축 회전(화면 중심)은 가운데를 움직이지 않고,
        // 왼쪽으로 돌면서 오른쪽으로 옮기면(가구를 바라보며 주위를 돌 때) 서로 상쇄된다
        let depth = max(s.depthM ?? config.fallbackDepthM, 0.3)
        let fu = Double(w.y) - Double(v.x) / depth
        let fv = Double(w.x) + Double(v.y) / depth
        let exposure = s.exposureS.flatMap { $0 > 0 ? $0 : nil } ?? config.fallbackExposureS
        frameBlurPx = (fu * fu + fv * fv).squareRoot() * exposure * s.fx
        blurPx = 0.5 * blurPx + 0.5 * frameBlurPx
    }

    // MARK: 이동 범위

    private mutating func updatePlace(_ s: Sample) {
        let p = s.transform.columns.3
        if var b = box {
            b.minX = min(b.minX, p.x); b.maxX = max(b.maxX, p.x)
            b.minZ = min(b.minZ, p.z); b.maxZ = max(b.maxZ, p.z)
            box = b
        } else {
            box = (minX: p.x, maxX: p.x, minZ: p.z, maxZ: p.z)
        }
        if let b = box { spanM = Double(hypot(b.maxX - b.minX, b.maxZ - b.minZ)) }
        markWalked(SIMD2(p.x, p.z))
        let f = -s.transform.columns.2
        window.append((time: s.time, xz: SIMD2(p.x, p.z), heading: Double(atan2(f.x, -f.z)) * 180 / .pi))
        let now = s.time, keep = config.stillWindowS          // 클로저 안에서 self 를 읽지 않게 (배타적 접근)
        window.removeAll { now - $0.time > keep }
    }

    private func isStandingStill(at t: Double) -> Bool {
        guard let first = window.first, let newest = window.last,
              newest.time - first.time >= config.stillWindowS * 0.9 - Self.eps else { return false }
        let moved = Double(window.map { simd_distance($0.xz, first.xz) }.max() ?? 0)
        // 창의 처음 대비 바라보는 방향이 가장 많이 바뀐 각도 (-180…180 으로 감아서). 위아래로 흔든 것 · 손떨림은 쌓이지 않는다
        let turned = window.map { abs(($0.heading - first.heading).remainder(dividingBy: 360)) }.max() ?? 0
        if moved < config.stillMoveM && turned >= config.stillTurnDeg { return true }
        if let start = startTime, t - start >= config.stillAfterS - Self.eps, spanM < config.stillSpanM,
           moved < config.recentWalkM {
            return true
        }
        return false
    }

    /// 0.1초씩 더한 시각의 부동소수점 오차 때문에 경계에서 한 번 늦게 켜지지 않게
    private static let eps = 1e-6

    // MARK: 경고 판정

    private func conditions(_ s: Sample) -> Set<CaptureAlert> {
        var c: Set<CaptureAlert> = []
        if s.tracking == .none || (s.tracking == .limited && s.reason == .relocalizing) { c.insert(.trackingLost) }
        if blurPx >= config.warnBlurPx || (s.tracking == .limited && s.reason == .excessiveMotion) {
            c.insert(.tooFast)                               // 어두우면 update() 에서 tooDark 로 보여 준다
        }
        let lookingDown = Self.pitchDeg(s.transform) < config.lookingDownDeg
        // 바닥을 찍으라고 해 놓고 '무늬 없음' 을 띄우지 않도록, 아래를 볼 때는 밝기 점수로 판단하지 않는다
        if (s.tracking == .limited && s.reason == .insufficientFeatures)
            || (!lookingDown && (s.textureScore.map { $0 < config.featurelessScore } ?? false)) {
            c.insert(.featureless)
        }
        if let d = s.depthM, d < config.tooCloseM { c.insert(.tooClose) }
        if checksWalking, s.tracking == .normal, isStandingStill(at: s.time) { c.insert(.standingStill) }
        if checksWalking, s.tracking == .normal, !lookingDown, let floor = floorCoverage, floor < config.floorAlertBelow {
            let loopDone = s.directionsCovered >= 0.999 && spanM >= Double(config.loopSpanM)
            let late = startTime.map { s.time - $0 >= config.floorAfterS - Self.eps } ?? false
            if loopDone || late { c.insert(.floorMissing) }
        }
        return c
    }

    // MARK: 바닥 (LiDAR)

    /// 걸어온 길(카메라가 지나간 자리 ± walkRadiusM) 중 바닥 사진을 찍은 곳(± floorPassRadiusM)의 비율.
    /// LiDAR 점이 없거나 아직 걸은 곳이 적으면 nil, 바닥 높이를 아직 못 찾았으면 0
    var floorCoverage: Double? {
        guard hasDepth, walked.count >= config.floorMinWalkedCells else { return nil }
        guard floorY != nil else { return 0 }
        let passed = floorPassed
        let covered = walked.reduce(0) { $0 + (passed.contains($1) ? 1 : 0) }
        return Double(covered) / Double(walked.count)
    }

    /// 저장한 프레임의 LiDAR 점(월드 좌표, FrameProbe.worldPoints)을 넣는다. samples = 격자에서 뽑은 전체 점 수
    /// (먼 벽 · 낮은 신뢰도로 빠진 점도 분모에 넣어야 넓은 방에서 수평으로 든 프레임이 '바닥 사진'이 되지 않는다).
    /// 돌려주는 값 = 이 프레임에서 바닥 점의 비율 (바닥 높이를 아직 모르면 nil). 최종값은 floorShares() 로 다시 구한다
    @discardableResult
    /// confident = 점마다 LiDAR 신뢰도 medium 이상인지 (nil = 모두). 바닥 높이 찾기에는 믿을 만한 점만 쓴다
    mutating func addSavedFrame(points: [SIMD3<Float>], confident: [Bool]? = nil, samples: Int? = nil,
                                camera: simd_float4x4, frameId: Int = -1) -> Double? {
        guard !points.isEmpty else { return nil }
        hasDepth = true
        let cam = camera.columns.3.xyz
        camYSum += Double(cam.y); camYCount += 1
        let bin = config.floorBinM
        for (i, p) in points.enumerated() where confident.map({ i < $0.count ? $0[i] : true }) ?? true {
            heightBins[Int((p.y / bin).rounded(.down)), default: 0] += 1
            heightTotal += 1
        }
        savedFrames.append((id: frameId, cam: cam, heights: points.map(\.y), samples: max(samples ?? points.count, points.count)))
        if let levels = estimateFloorLevels() {                  // 못 찾으면 이전 추정을 그대로 둔다
            floorY = levels.main
            lowerFloors = levels.lower
        }
        guard let f = floorY else { return nil }
        let floors = [f] + lowerFloors
        let moved = countedFloors.isEmpty || countedFloors.count != floors.count
            || zip(countedFloors, floors).contains { abs($0 - $1) > config.floorResetM }
        if moved {                                               // 처음 찾았거나 크게 바뀜 → 보관한 프레임으로 다시 센다
            countedFloors = floors
            floorPassed = []
            floorPhotos = 0
            let frames = savedFrames.dropLast()
            for frame in frames { markFloorPhoto(frame.heights, samples: frame.samples, cam: frame.cam) }
        }
        let last = savedFrames[savedFrames.count - 1]
        return markFloorPhoto(last.heights, samples: last.samples, cam: last.cam)
    }

    /// 지금 바닥 추정으로 저장한 프레임마다 바닥 점 비율 (frameId → 비율). 촬영을 끝낼 때 poses.json 의 floorShare 로 쓴다
    func floorShares() -> [Int: Double] {
        guard floorY != nil else { return [:] }
        var out: [Int: Double] = [:]
        for frame in savedFrames where frame.id >= 0 { out[frame.id] = floorShare(frame.heights, samples: frame.samples) }
        return out
    }

    private func floorShare(_ heights: [Float], samples: Int) -> Double {
        guard let f = floorY else { return 0 }
        let tol = config.floorTolM, floors = [f] + lowerFloors
        let n = heights.reduce(0) { acc, y in acc + (floors.contains { abs(y - $0) < tol } ? 1 : 0) }
        return Double(n) / Double(max(samples, 1))
    }

    /// 이 프레임의 바닥 점 비율을 구하고, 바닥 사진이면 찍은 자리 주변을 '바닥을 찍은 곳' 으로 표시한다
    @discardableResult
    private mutating func markFloorPhoto(_ heights: [Float], samples: Int, cam: SIMD3<Float>) -> Double {
        let share = floorShare(heights, samples: samples)
        if share >= config.floorLookShare, let f = floorY, cam.y - f > 0.3 {
            floorPhotos += 1
            for c in Self.cells(around: SIMD2(cam.x, cam.z), radius: config.floorPassRadiusM, cell: config.floorCellM) {
                floorPassed.insert(c)
            }
        }
        return share
    }

    /// 방 바닥 = 가장 낮은 '점이 많이 모인' 높이. 탁자 · 침대 윗면은 바닥보다 위라 걸러지고,
    /// 바로 위 25 cm 안에 3배 넘게 큰 수평면이 있으면(방 바닥보다 낮은 현관 · 욕실 · 베란다) 그 위쪽을 방 바닥으로 보고 아래 단으로 둔다.
    /// (바닥에 깐 요 · 토퍼처럼 26 cm 아래로 낮고 바닥보다 3배 넘게 많이 보인 면이면 그 면이 main 이 되지만, 바닥도 아래 단으로 세므로 비율은 맞다)
    private func estimateFloorLevels() -> (main: Float, lower: [Float])? {
        guard camYCount > 0 else { return nil }
        let camY = Float(camYSum / Double(camYCount)), bin = config.floorBinM
        let need = max(config.floorClusterMin, heightTotal / 250)
        let bins = heightBins
        let count = { (b: Int) -> Int in bins[b] ?? 0 }
        let window = { (b: Int) -> Int in count(b - 1) + count(b) + count(b + 1) }
        let reach = max(Int((config.floorLevelWindowM / bin).rounded()), 1)
        let center = { (b: Int) -> Float in
            let peak = (b - 1...b + 2).max { count($0) < count($1) } ?? b
            let sum = (peak - 1...peak + 1).reduce(Float(0)) { $0 + Float(count($1)) * (Float($1) + 0.5) * bin }
            return sum / Float(max(window(peak), 1))
        }
        var lowerCandidates: [Float] = []
        for b in bins.keys.sorted() {
            let y = (Float(b) + 0.5) * bin
            if y < camY - config.floorMaxBelowCamM { continue }      // 너무 낮음 = 잡음
            if y > camY - config.floorMinBelowCamM { break }         // 바닥이라기엔 너무 높음
            guard window(b) >= need else { continue }
            if (b + 1...b + reach).contains(where: { window($0) > 3 * window(b) }) {
                lowerCandidates.append(center(b))                    // 더 큰 바닥이 바로 위에 있음 → 아래 단
                continue
            }
            let main = center(b)
            var lower: [Float] = []
            for y in lowerCandidates where main - y >= 0.06 && main - y <= config.floorLevelWindowM {
                if !lower.contains(where: { abs($0 - y) < 0.04 }) { lower.append(y) }
            }
            return (main, lower)
        }
        return nil
    }

    /// 카메라가 지나간 자리 ± walkRadiusM 의 칸 = 걸어온 길
    private mutating func markWalked(_ xz: SIMD2<Float>) {
        for c in Self.cells(around: xz, radius: config.walkRadiusM, cell: config.floorCellM) { walked.insert(c) }
    }

    /// 점 xz 에서 radius 안에 중심이 있는 칸들
    static func cells(around xz: SIMD2<Float>, radius r: Float, cell: Float) -> [Cell] {
        let ix = Int32((xz.x / cell).rounded(.down)), iz = Int32((xz.y / cell).rounded(.down))
        let reach = Int32((r / cell).rounded(.up))
        var out: [Cell] = []
        for dx in -reach...reach {
            for dz in -reach...reach {
                let c = Cell(x: ix + dx, z: iz + dz)
                let center = SIMD2((Float(c.x) + 0.5) * cell, (Float(c.z) + 0.5) * cell)
                if simd_distance(center, xz) <= r { out.append(c) }
            }
        }
        return out
    }

    /// 카메라가 수평선보다 얼마나 아래를 보는지 (도, 음수 = 아래)
    static func pitchDeg(_ T: simd_float4x4) -> Float {
        asin(min(max(-T.columns.2.y, -1), 1)) * 180 / .pi
    }

    private mutating func debounce(_ now: Set<CaptureAlert>, at t: Double) {
        for a in CaptureAlert.allCases {
            if now.contains(a) {
                offSince[a] = nil
                let since = onSince[a] ?? t
                onSince[a] = since
                if t - since >= a.onDelay - Self.eps { active.insert(a) }
            } else {
                onSince[a] = nil
                guard active.contains(a) else { continue }
                let since = offSince[a] ?? t
                offSince[a] = since
                if t - since >= a.offDelay - Self.eps {
                    active.remove(a)
                    offSince[a] = nil
                }
            }
        }
    }

    // MARK: 수학

    static func rotation(_ T: simd_float4x4) -> simd_float3x3 {
        simd_float3x3(T.columns.0.xyz, T.columns.1.xyz, T.columns.2.xyz)
    }

    /// 회전 행렬 → 회전 벡터 (축 × 각도, 라디안). 가장 짧은 쪽 회전
    static func rotationVector(_ r: simd_float3x3) -> SIMD3<Float> {
        var q = simd_quatf(r)
        if q.real < 0 { q = simd_quatf(real: -q.real, imag: -q.imag) }
        let n = simd_length(q.imag)
        guard n > 1e-7 else { return .zero }
        return q.imag / n * (2 * atan2(n, q.real))
    }
}

extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}

extension simd_float4x4 {
    /// JSON 용 row-major 4×4 (simd 는 column-major: self[col][row])
    var rowMajor: [[Double]] {
        (0..<4).map { r in (0..<4).map { c in Double(self[c][r]) } }
    }
}
