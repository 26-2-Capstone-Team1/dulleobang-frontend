import ARKit
import AVFoundation
import UIKit
import Foundation
import simd

/// poses.json 한 줄. 좌표계: ARKit 월드(미터, Y-up, 오른손), 카메라: x right / y up / -z forward (OpenGL = nerfstudio 규약).
struct PoseRecord: Codable {
    struct Intrinsics: Codable { var fx, fy, cx, cy: Double }
    var frameId: Int
    var ts: Double
    var T_wc: [[Double]]          // camera→world, row-major 4×4 (= ARCamera.transform 그대로)
    var K: Intrinsics             // 저장된 JPG(센서 원래 방향) 해상도 기준. JSON 키는 "K"
    var width: Int
    var height: Int
    var tracking: String
    var depth: Bool
    var exposureS: Double? = nil  // 셔터 시간(초, ARCamera.exposureDuration). 길수록 흔들리기 쉽다
    var blurPx: Double? = nil     // 저장 순간의 예상 흔들림(px, 이 JPG 해상도 기준) = 카메라 속도 × 셔터 × 초점거리
    var floorShare: Double? = nil // 이 프레임 LiDAR 격자(768점) 중 바닥인 비율. 촬영을 끝낼 때 최종 바닥 높이로 다시 계산
    var ceilingShare: Double? = nil // 이 프레임 LiDAR 격자(768점) 중 천장인 비율 (천장 높이를 찾은 경우만, 촬영을 끝낼 때 계산)
    var iso: Double? = nil        // ISO (ARFrame.exifData). 높을수록 어두운 곳이라 노이즈가 많다
    var focusLocked: Bool? = nil  // 이 프레임을 찍을 때 초점이 고정돼 있었는지 (기기가 알려 주지 않으면 nil)
    var lensPosition: Double? = nil   // 렌즈 위치 (0 가까움 … 1 멀리, AVCaptureDevice.lensPosition). 초점이 고정됐으면 프레임마다 같다
    var depthSource: String? = nil    // 깊이 출처: sceneDepth · smoothedSceneDepth (ARKit 이 여러 프레임을 평활한 깊이)
    var trackingNormalForS: Double? = nil // 이 프레임까지 추적이 normal 로 이어진 시간 (초). 막 회복한 직후 프레임은 포즈가 튈 수 있다
    var torch: Bool? = nil        // 손전등을 켠 채 찍은 프레임 (빛이 카메라와 함께 움직여 밝기 · 그림자가 프레임마다 다르다)
}

/// depth.json: 깊이 파일 설명 + 프레임별 요약 (전체 깊이 값은 depth/*.png 원본에 있다)
struct DepthSummaryFile: Codable {
    var captureId: String
    var files = [
        "depth": "depth/NNNNNN.png — uint16 PNG, 밀리미터, 0 = 측정 없음 (AI 가 쓰는 원본). 파이썬: np.array(Image.open(p)) / 1000 → 미터",
        "depthPreview": "depth_vis/NNNNNN.jpg — Turbo 히트맵, 파랑 0.2 m → 빨강 5 m, 검정 = 없음 (보기용)",
        "confidence": "confidence/NNNNNN.png — uint8, 0 낮음 · 1 중간 · 2 높음 (원본)",
        "confidencePreview": "confidence_vis/NNNNNN.png — 빨강 낮음 · 노랑 중간 · 초록 높음 (보기용)",
    ]
    var depthSize: [Int]
    var colorSize: [Int]
    var colorToDepthScale: [Double]
    var note = "프레임마다 poses.json 의 K(컬러 해상도 기준)에 colorToDepthScale 을 곱하면 깊이 해상도의 intrinsics. "
        + "깊이는 광선 거리가 아니라 카메라 z 축 거리(미터). 모든 이미지는 센서 원래 방향(가로)."
    var previewRangeM: [Double]
    var frameCount: Int
    var frames: [DepthFrameSummary]
}

struct CaptureMeta: Codable {
    var captureId: String
    var kind: String
    var device: String
    var os: String
    var arSdk = "ARKit"
    var coordinate = "arkit_world; meters; y-up; right-handed; camera x-right y-up -z-forward (OpenGL)"
    var imageOrientation = "sensor_native_landscape (not rotated; K matches the JPG)"
    var colorSize: [Int]?
    var depthSize: [Int]?
    var depthUnit = "uint16 PNG, millimeters, 0 = invalid"
    var confidence = "uint8 PNG: 0 low, 1 medium, 2 high"
    var frameCount: Int
    var roomplan: Bool
    var createdAt: String
    var floorHeightM: Double? = nil         // LiDAR 로 찾은 바닥 높이 (ARKit 월드 y, m)
    var walkedFloorCoverage: Double? = nil  // 걸어온 길 중 바닥 사진(바닥이 LiDAR 점의 25% 이상)을 찍은 곳의 비율 (0~1)
    var floorPhotos: Int? = nil              // 바닥 사진 수
    var ceilingHeightM: Double? = nil        // LiDAR 로 찾은 천장 높이 (ARKit 월드 y, m)
    var walkedCeilingCoverage: Double? = nil // 걸어온 길 위의 천장을 찍은 곳의 비율 (천장 사진 = 천장이 LiDAR 점의 25% 이상이고 폰을 위로 20° 넘게 듦, 0~1)
    var ceilingPhotos: Int? = nil            // 천장 사진 수
    var cameras: CameraRig? = nil            // 어느 카메라로 찍었는지 · 왜곡 · 화각 · 깊이와의 관계 (0.5× 사진을 찍었으면 ultraWide 포함)
    var sampling: Sampling? = nil            // 프레임을 고른 규칙 (2026-10-25 이전 촬영본에는 없음: 15 cm / 10° / 0.3초 / 10 px)
    var surfaceCoverage: CoverageSummary? = nil  // 벽 · 바닥이 사진 3장 이상에 나온 비율 (LiDAR + RoomPlan, 2026-10-27 이후)

    /// 프레임 저장 규칙. 폴링마다 모두 만족하면 저장한다 (가구 전체 사진이 새로 통과한 프레임은 이동 · 회전 조건만 건너뜀)
    struct Sampling: Codable, Equatable {
        var pollHz: Double               // ARSession.currentFrame 폴링 주기
        var minIntervalS: Double         // 저장 간격 하한 (초당 최대 장 수 ≈ 1 / 이 값)
        var minMoveM: Double             // 직전 저장 프레임에서 이만큼 움직였거나
        var minTurnDeg: Double           // 이만큼 돌았을 때 (가만히 서 있으면 저장하지 않음)
        var maxBlurPx: Double            // 예상 흔들림(poses.json 의 blurPx 와 같은 단위)이 이 이상이면 저장하지 않음
        var jpegQuality: Double
    }
}

/// capture_log.json: 촬영 중에 생긴 일. 결과가 이상할 때 원인(추적 끊김 · 흔들림 · 발열 · 초점)을 나중에 찾으려고 남긴다 (AI 팀 요청)
struct CaptureLog: Codable, Equatable {
    var captureId: String
    var stabilization = "none: frames are ARKit capturedImage, which ARKit never stabilizes (no per-frame crop or shift)"
    var startTs: Double?                     // 첫 폴링의 ARKit 시각 (poses.json 의 ts 와 같은 시계, 초)
    var endTs: Double?                       // 마지막 폴링
    var polls = 0                            // currentFrame 을 읽은 횟수 (AppConfig.sampleHz)
    var skippedPolls = Skipped()             // 저장할 차례였는데 건너뛴 폴링 수 (10 Hz 라 프레임 수의 약 2배)
    var tracking: [TrackingEvent] = []       // 추적이 normal 이 아니었던 구간 (처음 위치를 잡는 initializing 포함)
    var thermal: [ThermalEvent] = []         // 기기 발열 상태 (처음 값 + 바뀐 시각)
    var focus = Focus()
    var depthSources: [String: Int] = [:]    // 저장한 프레임의 깊이 출처별 장 수 (sceneDepth · smoothedSceneDepth)
    var torch = TorchLog()                   // 손전등 (어두우면 앱이 켬 · 화면 버튼으로 켜고 끔)

    struct TorchLog: Codable, Equatable {
        var autoEnabled = false              // 설정(개발자) › 어두우면 손전등 자동으로 켜기 (손전등이 없는 기기면 false)
        var events: [TorchEvent] = []        // 켜고 끈 기록
        var note: String?                    // 켜지 못한 이유 (손전등 없음 · 기기가 뜨거움)
    }
    struct TorchEvent: Codable, Equatable {
        var ts: Double                       // ARKit 시각 (poses.json 의 ts 와 같은 시계)
        var on: Bool
        var by: String                       // auto(어두워서) · user(화면 버튼) · relight(iOS 가 꺼서 다시 켬) · end(촬영 끝)
        var trigger: String?                 // auto 일 때 근거 (ISO · 셔터 또는 조명 추정)
    }
    struct Skipped: Codable, Equatable {
        var blurry = 0                       // 예상 흔들림이 meta.json sampling.maxBlurPx 이상
        var busy = 0                         // 앞 프레임을 아직 쓰는 중 (쓰기 대기 3장)
    }
    struct TrackingEvent: Codable, Equatable {
        var startTs: Double
        var endTs: Double?                   // nil = 끝날 때까지 회복하지 못함
        var state: String                    // limited · none
        var reason: String?                  // initializing · excessiveMotion · insufficientFeatures · relocalizing · other
    }
    struct ThermalEvent: Codable, Equatable {
        var ts: Double
        var state: String                    // nominal · fair · serious · critical (ProcessInfo.thermalState)
    }
    struct Focus: Codable, Equatable {
        var lockEnabled = false              // 설정(개발자) › 촬영 중 초점 고정
        var lockedAtTs: Double?              // 잠근 ARKit 시각 (nil = 잠그지 못했거나 꺼 둠)
        var lensPosition: Double?            // 잠근 렌즈 위치 (0 가까움 … 1 멀리)
        var relocks = 0                      // ARKit · RoomPlan 이 풀어 버려 다시 잠근 횟수
        var note: String?                    // 잠그지 못한 이유
    }
}

/// 추적이 normal 이 아니었던 구간을 모은다 (capture_log.json 의 tracking). ARKit 에 의존하지 않아 테스트 가능
struct TrackingTimeline: Equatable {
    private(set) var events: [CaptureLog.TrackingEvent] = []
    private(set) var normalSince: Double?        // 지금 normal 이면 그렇게 된 시각

    mutating func record(ts: Double, state: TrackingState, reason: TrackingReason?) {
        if state == .normal {
            if normalSince == nil { normalSince = ts }
            if let i = events.indices.last, events[i].endTs == nil { events[i].endTs = ts }
            return
        }
        normalSince = nil
        let why = reason?.rawValue
        if let i = events.indices.last, events[i].endTs == nil {
            if events[i].state == state.rawValue && events[i].reason == why { return }    // 같은 상태가 이어짐
            events[i].endTs = ts                                                         // 상태 · 이유가 바뀜 → 새 구간
        }
        events.append(.init(startTs: ts, endTs: nil, state: state.rawValue, reason: why))
    }

    /// ts 시각까지 normal 이 이어진 시간 (지금 normal 이 아니면 nil)
    func normalFor(at ts: Double) -> Double? { normalSince.map { max(0, ts - $0) } }
}

extension ProcessInfo.ThermalState {
    /// capture_log.json 에 쓰는 이름
    var logName: String {
        switch self {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

/// 촬영 중 초점 고정 (AI 팀 권장). 자동 초점이 움직이면 초점거리가 6% 까지 흔들리고(10월 8일 1331~1415 px) 사진마다 선명한 곳이 달라져
/// 3DGS · 메시가 나빠진다. ARKit 1× 카메라(AVCaptureDevice)를 직접 잠근다 — RoomPlan 이 세션 설정을 정해도 쓸 수 있는 방법.
/// RoomPlan · ARKit 이 다시 풀 수도 있어서 CaptureRecorder 가 폴링마다 확인한다
enum FocusLock {
    private static var device: AVCaptureDevice? { ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera }

    /// 지금 초점 상태 (기기를 얻지 못하면 nil)
    static var state: (locked: Bool, lensPosition: Float, adjusting: Bool)? {
        guard let d = device else { return nil }
        return (d.focusMode == .locked, d.lensPosition, d.isAdjustingFocus)
    }

    /// 지금 렌즈 위치에서 초점을 잠근다. 실패하면 이유를 돌려준다
    static func lock() -> String? {
        guard let d = device else { return "configurableCaptureDeviceForPrimaryCamera 없음" }
        guard d.isFocusModeSupported(.locked) else { return "초점 고정을 지원하지 않는 카메라" }
        do {
            try d.lockForConfiguration()
            d.focusMode = .locked
            d.unlockForConfiguration()
            return nil
        } catch {
            return "lockForConfiguration 실패: \(error.localizedDescription)"
        }
    }

    /// 자동 초점으로 되돌린다
    static func unlock() {
        guard let d = device, d.focusMode == .locked, d.isFocusModeSupported(.continuousAutoFocus) else { return }
        do {
            try d.lockForConfiguration()
            d.focusMode = .continuousAutoFocus
            d.unlockForConfiguration()
        } catch {}
    }
}

/// 어두운지 (손전등 자동 켜기). 셔터가 이미 최대(1/60초)인데 ISO 가 높으면 어두운 것 — 사진이 흔들리고 거칠어지기 시작하는 때.
/// ISO 를 모르면 ARKit 조명 추정(ambientIntensity, 1000 lm ≈ 보통 밝기)을 본다. darkForS 초 이어져야 켤 때가 된 것
struct DarknessMeter {
    var darkISO = 1000.0             // 셔터 1/61초 이상에서 ISO 가 이 이상이면 어두움
    var darkLumens = 250.0           // ISO 를 모를 때 조명 추정이 이보다 낮으면 어두움
    var darkForS = 2.0               // 이만큼 이어져야 켠다 (어두운 구석을 잠깐 스친 것은 무시)
    private(set) var darkSince: Double?

    init() {}

    /// 이번 폴링이 어두운지 넣고, 손전등을 켤 때가 됐으면 true
    mutating func update(time: Double, ambientLumens: Double?, exposureS: Double?, iso: Double?) -> Bool {
        let dark: Bool
        if let iso, let e = exposureS { dark = e >= 1.0 / 61 && iso >= darkISO }
        else if let lm = ambientLumens { dark = lm < darkLumens }
        else { dark = false }
        if dark { darkSince = darkSince ?? time } else { darkSince = nil }
        guard let since = darkSince else { return false }
        return time - since >= darkForS - 1e-6
    }
}

/// 손전등 (ARKit 1× 카메라의 LED · AVCaptureDevice). ARKit 세션이 도는 중에도 켤 수 있지만, 세션을 막 시작했을 때 켜면
/// iOS 가 바로 꺼 버려서(Apple 개발자 포럼) 촬영 시작 2초 뒤부터 켠다. 기기가 뜨거우면 iOS 가 밝기를 낮추거나 막는다
enum Torch {
    private static var device: AVCaptureDevice? { ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera }

    static var isAvailable: Bool { device?.hasTorch ?? false }
    static var isOn: Bool { device?.torchMode == .on }

    /// 지금 켤 수 있는 가장 밝게 켠다. 실패하면 이유
    static func turnOn() -> String? {
        guard let d = device, d.hasTorch, d.isTorchModeSupported(.on) else { return "손전등이 없는 기기" }
        guard d.isTorchAvailable else { return "기기가 뜨거워 지금은 손전등을 켤 수 없음" }
        do {
            try d.lockForConfiguration()
            defer { d.unlockForConfiguration() }
            try d.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
            return nil
        } catch {
            return "손전등을 켜지 못함: \(error.localizedDescription)"
        }
    }

    static func turnOff() {
        guard let d = device, d.hasTorch, d.torchMode != .off else { return }
        do {
            try d.lockForConfiguration()
            d.torchMode = .off
            d.unlockForConfiguration()
        } catch {}
    }
}

extension TrackingState {
    init(_ s: ARCamera.TrackingState) {
        switch s {
        case .normal: self = .normal
        case .limited: self = .limited
        case .notAvailable: self = .none
        }
    }
}

extension TrackingReason {
    /// limited 일 때만 값이 있다
    init?(_ s: ARCamera.TrackingState) {
        guard case .limited(let r) = s else { return nil }
        if r == .initializing { self = .initializing }
        else if r == .excessiveMotion { self = .excessiveMotion }
        else if r == .insufficientFeatures { self = .insufficientFeatures }
        else if r == .relocalizing { self = .relocalizing }
        else { self = .other }
    }
}

/// ARSession.currentFrame 을 주기적으로 폴링해서 frames/ depth/ confidence/ poses.json meta.json 을 기록한다.
/// 델리게이트 대신 폴링을 쓰는 이유: RoomPlan 이 같은 ARSession 을 쓸 때 session.delegate 를 건드리지 않기 위해서.
/// 모든 공개 메서드는 메인 스레드에서 호출한다.
final class CaptureRecorder {
    let captureId: String
    let kind: CaptureKind
    let dir: URL                                    // …/captures/<id>/capture  (zip 최상위 폴더명 = capture)
    var onStats: ((CaptureStats) -> Void)?

    private let session: ARSession
    private var sampler: FrameSampler
    private var coach: CaptureCoach                                    // 촬영 중 경고 (흔들림 · 제자리 · 어두움 …)
    private var poses: [PoseRecord] = []
    private var timer: Timer?
    private var inFlight = 0
    private var colorSize: [Int]?
    private var depthSize: [Int]?
    private let writer = FrameWriter()
    private let queue = DispatchQueue(label: "capture.writer", qos: .userInitiated)
    private let group = DispatchGroup()
    private var writeErrors = 0
    private var depthSummaries: [DepthFrameSummary] = []             // depth.json 용 (메인 스레드에서만 추가)
    private var shots = FurnitureShotTracker()                        // 가구 전체 사진 점검 (방 촬영 · RoomPlan 이 찾은 가구)
    private var firstFrameTime: Double?                               // 가구 안내를 1분 뒤부터 띄우려고
    private var lastFurnitureReport: FurnitureShotsFile?              // finalize 에서 쓴 furniture_shots.json (광각 사진 대상 고르기)
    private var lastFurnitureBoxes: [FurnitureBox] = []
    private var lastMeta: CaptureMeta?                                // finalize 에서 쓴 meta.json (0.5× 사진을 찍은 뒤 cameras 에 더해 다시 쓴다)
    private var captureLog = CaptureLog(captureId: "")                // capture_log.json (finalize 에서 captureId 를 채운다)
    private var timeline = TrackingTimeline()                         // 추적이 normal 이 아니었던 구간 · 정상으로 이어진 시간
    private var lastThermal: ProcessInfo.ThermalState?                // 마지막으로 기록한 발열 상태
    private var focusCheckedAt = -Double.infinity                     // 초점을 마지막으로 확인한 시각 (잠근 뒤에는 2초에 한 번)
    private var focusGaveUp = false                                   // 초점을 잠글 수 없는 기기 → 다시 시도하지 않는다
    private var coverage = CoverageTracker()                          // 벽 · 바닥이 사진 몇 장에 나왔는지 (방 촬영 · RoomPlan)
    private var darkness = DarknessMeter()                            // 어두운지 (손전등 자동 켜기)
    private let torchAvailable = Torch.isAvailable
    private var torchWanted = false                                   // 지금 손전등을 켜 두려는지 (앱이 켰거나 사람이 켬)
    private var torchUserOff = false                                  // 사람이 버튼으로 껐으면 이 촬영에서는 다시 자동으로 켜지 않는다
    private var torchCheckedAt = -Double.infinity                     // iOS 가 껐는지 마지막으로 확인한 시각 (2초에 한 번)
    private var torchAutoAt: Double?                                  // 어두워서 켠 시각 (안내 문구를 잠깐 보여 주려고)
    private var mapForward = SIMD2<Float>(0, -1)                      // 미니맵 위쪽 = 바라보는 방향 (바로 아래 · 위를 볼 때는 직전 방향 유지)

    private(set) var isRecording = false
    var frameCount: Int { poses.count }
    /// 카메라가 실제로 움직인 범위 (m, 바닥 기준 상자의 대각선)
    var spanM: Float { Float(coach.spanM) }
    /// 이보다 좁게 움직였으면 '제자리에서만 찍었다' 고 본다
    var stillSpanM: Float { Float(coach.config.stillSpanM) }
    /// 걸어온 길 중 바닥 사진을 찍은 곳의 비율 (LiDAR 없으면 nil)
    var floorCoverage: Double? { coach.floorCoverage }
    /// 바닥이 이보다 적게 찍혔으면 끝낼 때 한 번 더 묻는다
    var floorAlertBelow: Double { coach.config.floorAlertBelow }
    /// 걸어온 길 위의 천장을 찍은 곳의 비율 (LiDAR 없으면 nil)
    var ceilingCoverage: Double? { coach.ceilingCoverage }
    /// 벽 · 바닥 중 사진 3장 이상에 나온 곳의 비율 (RoomPlan 벽을 모르면 nil)
    var surfaceCoverage: Double? { kind == .room && coverage.hasSurfaces ? coverage.summary.overall : nil }
    /// 이보다 적게 찍혔으면 끝낼 때 한 번 묻는다
    var surfaceCoverageTarget: Double { coverage.config.targetShare }
    /// 천장이 이보다 적게 찍혔으면 끝낼 때 한 번 묻는다 (선택 사항이라 한 번만)
    var ceilingAlertBelow: Double { coach.config.ceilingAlertBelow }
    /// 천장을 안내했는데도 비율이 안 늘어 포기했는지 (포기했으면 끝낼 때도 묻지 않는다)
    var ceilingGaveUp: Bool { coach.ceilingGaveUp }
    var hasDepth: Bool { depthSize != nil }                           // LiDAR 깊이가 한 장이라도 저장됐는지
    /// 아직 전체 사진이 없고 안내도 포기하지 않은 가구 이름 (같은 모양 가구로 대신할 수 있는 것은 뺀다). 화면 아래 힌트 · 끝낼 때 "더 찍을까요?" 경고에 쓴다.
    /// 안내를 오래 했는데도 안 되던 가구는 뺀다 — 같은 가구를 계속 재촉하지 않는다
    var furnitureMissing: [String] { kind == .room ? shots.activeMissingLabels : [] }
    /// 전체 사진은 있지만 서로 다른 방향 사진이 적은 가구 수 (끝낼 수 있을 때 힌트에 덧붙이기만 한다)
    var furnitureFewViews: Int { kind == .room ? shots.fewViewsCount : 0 }
    /// 끝낼 때 0.5× 광각 사진을 제안할지: 광각 카메라가 있고, '다 안 들어옴' 때문에 전체 사진이 없는 가구가 있음 (안내를 포기한 가구 포함).
    /// 다른 가구에 가려진 것은 문제로 치지 않는다
    var furnitureNeedsWide: Bool { kind == .room && shots.config.wideCameraAvailable && shots.needsWideShot }

    /// finalize 뒤: 0.5× 광각으로 찍을 가구 (RoomPlan 최종 상자 기준, 같은 모양은 한 장으로)
    func wideShotTargets() -> [WideShotTarget] {
        guard let report = lastFurnitureReport else { return [] }
        return WideShotTarget.plan(report: report, boxes: lastFurnitureBoxes, tol: shots.config.twinTolM)
    }
    private let osVersion = "iOS \(UIDevice.current.systemVersion)"     // init(메인 스레드)에서 읽어 둔다

    /// meta.json 의 sampling: 이 촬영에서 프레임을 고른 규칙 (AppConfig · CaptureCoach.Config 값 그대로)
    private var samplingRule: CaptureMeta.Sampling {
        let cfg = AppConfig.shared
        return CaptureMeta.Sampling(pollHz: cfg.sampleHz,
                                    minIntervalS: sampler.minInterval,
                                    minMoveM: (Double(sampler.minTranslation) * 1000).rounded() / 1000,
                                    minTurnDeg: (Double(sampler.minRotationRad) * 180 / .pi * 100).rounded() / 100,
                                    maxBlurPx: coach.config.skipBlurPx,
                                    jpegQuality: (Double(cfg.jpegQuality) * 100).rounded() / 100)
    }

    init(session: ARSession, kind: CaptureKind) throws {
        let cfg = AppConfig.shared
        self.session = session
        self.kind = kind
        captureId = UUID().uuidString.lowercased()
        sampler = FrameSampler(minTranslation: kind == .room ? cfg.minTranslationM : cfg.minTranslationM * 0.5,
                               minRotationDeg: cfg.minRotationDeg, minInterval: cfg.minIntervalSec)
        var coachConfig = CaptureCoach.Config()
        coachConfig.loopSpanM = cfg.roomMinSpanM
        coach = CaptureCoach(config: coachConfig, checksWalking: kind == .room)
        var shotConfig = FurnitureShotConfig()
        shotConfig.wideCameraAvailable = kind == .room && UltraWideCamera.isAvailable
        shots = FurnitureShotTracker(config: shotConfig)
        dir = Self.root.appendingPathComponent(captureId, isDirectory: true)
                       .appendingPathComponent("capture", isDirectory: true)
        for sub in ["frames", "depth", "confidence", "depth_vis", "confidence_vis"] {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
    }

    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("captures", isDirectory: true)
    }

    func start() {
        guard !isRecording else { return }
        isRecording = true
        captureLog.focus.lockEnabled = AppConfig.shared.lockFocus
        if captureLog.focus.lockEnabled { FocusLock.unlock() }          // 지난 촬영에서 남은 고정은 풀고, 방에 초점이 맞은 뒤 다시 잠근다
        captureLog.torch.autoEnabled = AppConfig.shared.autoTorch && torchAvailable
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / AppConfig.shared.sampleHz, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    /// 샘플링만 멈춘다 (RoomPlan 후처리 중에도 호출 가능)
    func stopSampling() {
        isRecording = false
        timer?.invalidate()
        timer = nil
        if captureLog.focus.lockedAtTs != nil { FocusLock.unlock() }    // 다음 촬영 · 다른 화면은 다시 자동 초점
        if torchWanted || (torchAvailable && Torch.isOn) {                // 촬영이 끝나면 손전등도 끈다
            Torch.turnOff()
            if torchWanted { captureLog.torch.events.append(.init(ts: captureLog.endTs ?? 0, on: false, by: "end")) }
            torchWanted = false
        }
    }

    /// 쓰기 완료를 기다린 뒤 poses.json / meta.json / 추가 파일(RoomPlan 결과 등)을 쓰고 폴더 URL 을 돌려준다.
    /// 호출 전에 메인 스레드에서 stopSampling() 을 불러 둘 것 (Timer 는 설치한 스레드에서만 해제 가능).
    /// furniture = RoomPlan 최종 가구 상자 (nil 이면 촬영 중 마지막 상자) → furniture_shots.json
    func finalize(extraFiles: [String: Data] = [:], roomplan: Bool = false,
                  furniture: [FurnitureBox]? = nil) async throws -> URL {
        await withCheckedContinuation { cont in group.notify(queue: .main) { cont.resume() } }
        // 바닥 높이는 촬영 중에 정해지므로, 마지막 추정으로 프레임마다 바닥 비율을 다시 적는다
        let shares = coach.floorShares()
        if !shares.isEmpty {
            for i in poses.indices { poses[i].floorShare = shares[poses[i].frameId].map { ($0 * 1000).rounded() / 1000 } }
        }
        let ceilingShares = coach.ceilingShares()                    // 천장도 같은 방식: 마지막 추정으로 프레임마다 다시 적는다
        if !ceilingShares.isEmpty {
            for i in poses.indices { poses[i].ceilingShare = ceilingShares[poses[i].frameId].map { ($0 * 1000).rounded() / 1000 } }
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(poses).write(to: dir.appendingPathComponent("poses.json"))
        let meta = CaptureMeta(captureId: captureId, kind: kind.rawValue, device: Self.deviceModel,
                               os: osVersion, colorSize: colorSize, depthSize: depthSize,
                               frameCount: poses.count, roomplan: roomplan,
                               createdAt: ISO8601DateFormatter().string(from: Date()),
                               floorHeightM: coach.floorY.map { (Double($0) * 1000).rounded() / 1000 },
                               walkedFloorCoverage: coach.floorCoverage.map { ($0 * 1000).rounded() / 1000 },
                               floorPhotos: coach.hasDepth ? coach.floorPhotos : nil,
                               ceilingHeightM: coach.ceilingY.map { (Double($0) * 1000).rounded() / 1000 },
                               walkedCeilingCoverage: coach.ceilingCoverage.map { ($0 * 1000).rounded() / 1000 },
                               ceilingPhotos: coach.hasDepth ? coach.ceilingPhotos : nil,
                               cameras: CameraRig(main: CameraRig.Main(colorSize: colorSize, depthSize: depthSize, poses: poses)),
                               sampling: samplingRule,
                               surfaceCoverage: kind == .room && coverage.hasSurfaces ? coverage.summary.rounded() : nil)
        try enc.encode(meta).write(to: dir.appendingPathComponent("meta.json"))
        lastMeta = meta
        captureLog.captureId = captureId
        captureLog.tracking = timeline.events
        try enc.encode(captureLog).write(to: dir.appendingPathComponent("capture_log.json"))
        if !depthSummaries.isEmpty, let depthSize, let colorSize {
            let file = DepthSummaryFile(
                captureId: captureId,
                depthSize: depthSize,
                colorSize: colorSize,
                colorToDepthScale: [Double(depthSize[0]) / Double(colorSize[0]), Double(depthSize[1]) / Double(colorSize[1])],
                previewRangeM: [Double(FrameWriter.previewNear), Double(FrameWriter.previewFar)],
                frameCount: depthSummaries.count,
                frames: depthSummaries.sorted { $0.frameId < $1.frameId })
            try enc.encode(file).write(to: dir.appendingPathComponent("depth.json"))
        }
        // 가구별 전체 사진: RoomPlan 최종 상자로 저장한 프레임을 모두 다시 점검한다 (샘플링 · RoomPlan 갱신은 이미 멈춤)
        if kind == .room, shots.hasFurniture || !(furniture ?? []).isEmpty {
            let report = shots.report(finalBoxes: furniture)
            lastFurnitureReport = report
            lastFurnitureBoxes = furniture ?? shots.boxes
            try enc.encode(report).write(to: dir.appendingPathComponent("furniture_shots.json"))
        }
        for (name, data) in extraFiles { try data.write(to: dir.appendingPathComponent(name)) }
        return dir
    }

    /// 스캔을 마친 뒤 0.5× 사진을 찍었다면 meta.json 의 cameras 에 초광각 항목을 더해 다시 쓴다
    func addUltraWide(_ info: CameraRig.UltraWide) throws {
        guard var meta = lastMeta else { return }
        meta.cameras?.ultraWide = info
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(meta).write(to: dir.appendingPathComponent("meta.json"))
        lastMeta = meta
    }

    func discard() {
        stopSampling()
        try? FileManager.default.removeItem(at: dir.deletingLastPathComponent())
    }

    /// RoomPlan 이 가구 상자를 고칠 때마다 (메인 스레드). 촬영을 멈춘 뒤에 온 갱신은 무시한다
    /// RoomPlan 이 벽을 고칠 때마다 (메인 스레드). 촬영을 멈춘 뒤에 온 갱신은 무시한다
    func updateSurfaces(_ walls: [CoverageWall]) {
        guard isRecording, kind == .room else { return }
        coverage.updateWalls(walls)
    }

    func updateFurniture(_ boxes: [FurnitureBox]) {
        guard isRecording, kind == .room else { return }
        shots.updateBoxes(boxes)
    }

    // MARK: - 샘플링

    private func tick() {
        guard isRecording, let frame = session.currentFrame else { return }
        let cam = frame.camera
        let tracking = TrackingState(cam.trackingState)
        let depthData = frame.sceneDepth ?? frame.smoothedSceneDepth     // RoomPlan 설정에서는 smoothed 만 올 수 있음
        let K = cam.intrinsics                                        // column-major: [fx 0 0][0 fy 0][cx cy 1]
        let exposure: Double? = cam.exposureDuration > 0 ? cam.exposureDuration : nil
        if frame.timestamp > (coach.lastSampleTime ?? -.infinity) {   // 같은 프레임을 두 번 재지 않는다 (앱이 잠깐 멈췄을 때)
            coach.update(.init(time: frame.timestamp, transform: cam.transform, tracking: tracking,
                               reason: TrackingReason(cam.trackingState), exposureS: exposure, fx: Double(K.columns.0.x),
                               depthM: depthData.flatMap { FrameProbe.centerDepth($0.depthMap) },
                               textureScore: FrameProbe.textureScore(frame.capturedImage),
                               directionsCovered: sampler.coverage))
        }
        if firstFrameTime == nil { firstFrameTime = frame.timestamp }
        // capture_log.json: 폴링 · 추적이 끊긴 구간 · 발열 · 초점 고정 (저장 여부와 상관없이 매 폴링)
        captureLog.polls += 1
        if captureLog.startTs == nil { captureLog.startTs = frame.timestamp }
        captureLog.endTs = frame.timestamp
        timeline.record(ts: frame.timestamp, state: tracking, reason: TrackingReason(cam.trackingState))
        let thermal = ProcessInfo.processInfo.thermalState
        if thermal != lastThermal {
            lastThermal = thermal
            captureLog.thermal.append(.init(ts: frame.timestamp, state: thermal.logName))
        }
        updateFocusLock(time: frame.timestamp, tracking: tracking)
        updateTorch(frame, time: frame.timestamp, exposure: exposure)
        defer { publish(tracking: tracking, hasDepth: depthData != nil, time: frame.timestamp, camera: cam.transform) }

        // 가구 전체 사진 (방 촬영 · RoomPlan 이 찾은 가구가 있을 때): 매 폴링 점검하고, 아직 전체 사진이 없는 가구가 통과하거나
        // 이미 ✓ 인 가구라도 지금까지 없던 새 방향이면 이동 · 회전이 적어도 이 프레임을 저장한다 (가구마다 방향당 한 번)
        let w = Int(cam.imageResolution.width), h = Int(cam.imageResolution.height)
        let makeView = { (grid: DepthGrid) -> ShotView in
            ShotView(frameId: nil, time: frame.timestamp, transform: cam.transform,
                     fx: K.columns.0.x, fy: K.columns.1.y, cx: K.columns.2.x, cy: K.columns.2.y,
                     width: w, height: h, depth: grid, blurPx: self.coach.frameBlurPx)
        }
        var shotView: ShotView?
        if kind == .room, tracking == .normal, shots.hasFurniture, let depthData,
           let grid = FrameProbe.depthGrid(depth: depthData.depthMap, confidence: depthData.confidenceMap) {
            shotView = makeView(grid)
        }
        var wantsShot = false
        if let v = shotView { wantsShot = shots.evaluateLive(v) }

        // 쓰기 대기 · 흔들림으로 건너뛰는 폴링은 저장할 차례였을 때만 센다 (capture_log.json)
        let due = sampler.wouldKeep(cam.transform, time: frame.timestamp, tracking: tracking, force: wantsShot)
        // 쓰기가 밀리면 이번 프레임은 건너뛴다 (카메라 버퍼 풀 고갈 방지)
        guard inFlight < 3 else { if due { captureLog.skippedPolls.busy += 1 }; return }
        // 많이 흔들린 프레임은 저장하지 않는다 → 화면에는 '너무 빨라요' 경고가 뜬다
        guard coach.frameBlurPx < coach.config.skipBlurPx else { if due { captureLog.skippedPolls.blurry += 1 }; return }
        guard sampler.shouldKeep(cam.transform, time: frame.timestamp, tracking: tracking, force: wantsShot) else { return }

        let id = poses.count
        let focus = FocusLock.state                                   // 초점 고정 여부 · 렌즈 위치 (poses.json)
        let depthSource: String? = frame.sceneDepth != nil ? "sceneDepth" : (frame.smoothedSceneDepth != nil ? "smoothedSceneDepth" : nil)
        if let depthSource { captureLog.depthSources[depthSource, default: 0] += 1 }
        // 저장한 프레임의 LiDAR 점으로 바닥이 화면에 얼마나 나왔는지 센다 (바닥 경고 · 안내 문구 · meta.json)
        var floorShare: Double?
        if kind == .room, let depthData {
            let probe = FrameProbe.worldPoints(depth: depthData.depthMap, confidence: depthData.confidenceMap,
                                               intrinsics: K, colorWidth: w, transform: cam.transform)
            floorShare = coach.addSavedFrame(points: probe.points, confident: probe.confident, samples: probe.samples,
                                             camera: cam.transform, frameId: id)
        }
        poses.append(PoseRecord(frameId: id, ts: frame.timestamp, T_wc: cam.transform.rowMajor,
                                K: .init(fx: Double(K.columns.0.x), fy: Double(K.columns.1.y),
                                         cx: Double(K.columns.2.x), cy: Double(K.columns.2.y)),
                                width: w, height: h, tracking: tracking.rawValue, depth: depthData != nil,
                                exposureS: exposure.map { ($0 * 1_000_000).rounded() / 1_000_000 },
                                blurPx: (coach.frameBlurPx * 10).rounded() / 10,
                                floorShare: floorShare.map { ($0 * 1000).rounded() / 1000 },
                                iso: FrameProbe.iso(frame.exifData),
                                focusLocked: focus?.locked,
                                lensPosition: focus.map { (Double($0.lensPosition) * 1000).rounded() / 1000 },
                                depthSource: depthSource,
                                trackingNormalForS: timeline.normalFor(at: frame.timestamp).map { ($0 * 10).rounded() / 10 },
                                torch: torchAvailable ? Torch.isOn : nil))
        colorSize = colorSize ?? [w, h]
        // 저장한 프레임은 가구 점검용으로 보관한다 (가구가 나중에 발견되거나 RoomPlan 상자가 바뀌면 다시 점검)
        if kind == .room, let depthData,
           var view = shotView ?? FrameProbe.depthGrid(depth: depthData.depthMap, confidence: depthData.confidenceMap).map(makeView) {
            view.frameId = id
            shots.addSaved(view)
            coverage.addSaved(view)                                   // 벽 · 바닥이 이 사진에 나왔는지 센다
        }

        // ARFrame 자체는 잡아두지 않고 필요한 버퍼만 넘긴다
        let image = frame.capturedImage
        let depth = depthData?.depthMap
        let conf = depthData?.confidenceMap
        if let depth, depthSize == nil { depthSize = [CVPixelBufferGetWidth(depth), CVPixelBufferGetHeight(depth)] }

        let name = String(format: "%06d", id)
        let dir = self.dir, writer = self.writer, quality = AppConfig.shared.jpegQuality
        inFlight += 1
        group.enter()
        queue.async { [weak self] in
            var failed = false
            var summary: DepthFrameSummary?
            do {
                try writer.writeJPEG(image, to: dir.appendingPathComponent("frames/\(name).jpg"), quality: quality)
                if let depth {
                    let s = try writer.writeDepth(depth, raw: dir.appendingPathComponent("depth/\(name).png"),
                                                  preview: dir.appendingPathComponent("depth_vis/\(name).jpg"))
                    summary = DepthFrameSummary(frameId: id, depth: "depth/\(name).png", preview: "depth_vis/\(name).jpg",
                                                valid: s.valid, minM: s.minM, medianM: s.medianM, maxM: s.maxM)
                }
                if let conf {
                    let share = try writer.writeConfidence(conf, raw: dir.appendingPathComponent("confidence/\(name).png"),
                                                           preview: dir.appendingPathComponent("confidence_vis/\(name).png"))
                    summary?.confidence = share
                    summary?.confidencePreview = "confidence_vis/\(name).png"
                }
            } catch {
                failed = true
                print("[capture] write \(name) failed: \(error)")
            }
            let done = summary
            DispatchQueue.main.async {
                self?.inFlight -= 1
                if failed { self?.writeErrors += 1 }
                if let done { self?.depthSummaries.append(done) }
                self?.group.leave()
            }
        }
    }

    /// 초점 고정: 첫 프레임에서 focusLockAfterS 초 뒤(자동 초점이 방에 맞춰진 뒤), 추적이 정상이고 초점을 맞추는 중이 아니면 지금 렌즈 위치로 잠근다.
    /// 그 뒤 RoomPlan · ARKit 이 풀어 버리면 2초에 한 번까지 다시 잠근다 (capture_log.json 의 focus.relocks)
    private func updateFocusLock(time: Double, tracking: TrackingState) {
        let after = AppConfig.shared.focusLockAfterS
        guard captureLog.focus.lockEnabled, !focusGaveUp, tracking == .normal, let start = firstFrameTime,
              time - start >= after,
              time - focusCheckedAt >= (captureLog.focus.lockedAtTs == nil ? 0.2 : 2.0) else { return }
        focusCheckedAt = time
        guard let state = FocusLock.state else {
            focusGaveUp = true
            captureLog.focus.note = "configurableCaptureDeviceForPrimaryCamera 없음"
            return
        }
        if state.locked { return }
        // 아직 한 번도 안 잠갔고 초점을 맞추는 중이면 조금(최대 3초) 기다린다
        if state.adjusting, captureLog.focus.lockedAtTs == nil, time - start < after + 3 { return }
        if let reason = FocusLock.lock() {
            focusGaveUp = true
            captureLog.focus.note = reason
            return
        }
        if captureLog.focus.lockedAtTs == nil {
            captureLog.focus.lockedAtTs = time
            captureLog.focus.lensPosition = FocusLock.state.map { (Double($0.lensPosition) * 1000).rounded() / 1000 }
        } else {
            captureLog.focus.relocks += 1
        }
    }

    /// 손전등: 촬영을 시작하고 2초 뒤부터 어두움(셔터 최대인데 ISO 1000 이상, ISO 를 모르면 조명 추정 250 lm 미만)이 2초 이어지면 켜고
    /// 끝날 때까지 켜 둔다 (켜면 밝아 보여 다시 잴 수 없음). 사람이 버튼으로 끄면 이 촬영에서는 다시 켜지 않는다.
    /// iOS 가 꺼 버리면(세션을 다시 설정할 때 등) 2초에 한 번까지 다시 켠다
    private func updateTorch(_ frame: ARFrame, time: Double, exposure: Double?) {
        guard torchAvailable, let start = firstFrameTime, time - start >= AppConfig.shared.focusLockAfterS else { return }
        if torchWanted {
            guard time - torchCheckedAt >= 2 else { return }
            torchCheckedAt = time
            guard !Torch.isOn else { return }
            if let reason = Torch.turnOn() {
                if captureLog.torch.note == nil { captureLog.torch.note = reason }
            } else {
                captureLog.torch.events.append(.init(ts: time, on: true, by: "relight"))
            }
            return
        }
        guard captureLog.torch.autoEnabled, !torchUserOff, captureLog.torch.note == nil else { return }
        let iso = FrameProbe.iso(frame.exifData)
        let lumens = frame.lightEstimate.map { Double($0.ambientIntensity) }
        guard darkness.update(time: time, ambientLumens: lumens, exposureS: exposure, iso: iso) else { return }
        if let reason = Torch.turnOn() {
            captureLog.torch.note = reason
            return
        }
        torchWanted = true
        torchCheckedAt = time
        torchAutoAt = time
        let trigger = iso.map { "ISO \(Int($0.rounded())) · 셔터 \(String(format: "%.4f", exposure ?? 0))초" }
            ?? lumens.map { "조명 추정 \(Int($0.rounded())) lm" }
        captureLog.torch.events.append(.init(ts: time, on: true, by: "auto", trigger: trigger))
    }

    /// 화면 오른쪽 위 손전등 버튼 (메인 스레드)
    func toggleTorch() {
        guard isRecording, torchAvailable else { return }
        let now = session.currentFrame?.timestamp ?? captureLog.endTs ?? 0
        if torchWanted || Torch.isOn {
            Torch.turnOff()
            torchWanted = false
            torchUserOff = true
            torchAutoAt = nil
            captureLog.torch.events.append(.init(ts: now, on: false, by: "user"))
        } else if let reason = Torch.turnOn() {
            captureLog.torch.note = reason
        } else {
            torchWanted = true
            torchCheckedAt = now
            captureLog.torch.events.append(.init(ts: now, on: true, by: "user"))
        }
    }

    private func publish(tracking: TrackingState, hasDepth: Bool, time: Double, camera: simd_float4x4) {
        let cfg = AppConfig.shared
        let floor = kind == .room ? coach.floorCoverage : nil
        // 첫 바퀴(12방향 + 이동 범위)를 마쳤는지: 천장 단계 · 가구 안내는 그 뒤부터 (그 전에는 걷기 · 바닥 · 위 목록만 보여 준다)
        let loopDone = sampler.coverage >= 0.999 && coach.spanM >= Double(coach.config.loopSpanM)
        // 천장 진행률은 첫 바퀴를 마친 뒤부터 보여 준다. 안내(문구 · 주황)는 안내를 포기하지 않았을 때만
        let ceiling: Double? = (kind == .room && loopDone) ? coach.ceilingCoverage : nil
        let ceilingAsked: Double? = coach.ceilingGaveUp ? nil : ceiling
        // 가구 안내는 첫 바퀴를 마쳤거나 1분이 지난 뒤부터 (그 전에는 위 목록만 보여 준다)
        var tip: FurnitureTip?
        if kind == .room, tracking == .normal, shots.hasFurniture {
            let late = firstFrameTime.map { time - $0 >= shots.config.guideAfterS } ?? false
            if loopDone || late { tip = shots.tip(now: time, camera: camera) }
        }
        // 벽 · 바닥 커버리지: 첫 바퀴 뒤(또는 1분 뒤)부터 가장 넓게 덜 찍힌 곳을 안내한다 (방 촬영 · RoomPlan 벽을 안 뒤)
        let coverageKnown = kind == .room && coverage.hasSurfaces
        let coverageLate = loopDone || (firstFrameTime.map { time - $0 >= coverage.config.guideAfterS } ?? false)
        var surface: Double?
        var coveragePrompt: String?
        var gapInfo: CoverageGapInfo?
        var coverageMap: CoverageMap?
        if coverageKnown {
            let summary = coverage.summary
            surface = summary.overall
            let fwd = -camera.columns.2.xyz
            let flat = SIMD2<Float>(fwd.x, fwd.z)
            if simd_length(flat) > 0.2 { mapForward = simd_normalize(flat) }
            let me = SIMD2<Float>(camera.columns.3.x, camera.columns.3.z)
            var gapPoint: SIMD2<Float>?
            if coverageLate, tracking == .normal, let share = summary.overall, share < coverage.config.targetShare,
               let gap = coverage.biggestGap() {
                coveragePrompt = CoverageTracker.prompt(gap, camera: camera, share: share)
                let point = SIMD2<Float>(gap.center.x, gap.center.z)
                gapPoint = point
                let near = gap.kind == .floor && simd_distance(point, me) < 0.5     // 발밑 바닥: 방향 대신 '발밑'
                gapInfo = CoverageGapInfo(kind: gap.kind,
                                          bearingDeg: near ? 0 : CoverageTracker.bearingDeg(from: me, forward: mapForward, to: point),
                                          share: share, near: near)
            }
            coverageMap = coverage.map(camera: me, forward: mapForward, gap: gapPoint)
        }
        let s = CaptureStats(kept: sampler.kept, spanM: spanM, coverage: sampler.coverage,
                             tracking: tracking, hasDepth: hasDepth, alert: coach.alert, floorCoverage: floor,
                             ceilingCoverage: ceiling, ceilingLow: (ceilingAsked ?? 1) < coach.config.ceilingAlertBelow,
                             furniture: kind == .room ? shots.chips() : [], furnitureTip: tip,
                             hint: sampler.hint(kind: kind, tracking: tracking, spanM: spanM,
                                                minSpanM: cfg.roomMinSpanM, goodFrames: cfg.roomGoodFrames,
                                                floorCoverage: floor, floorTarget: coach.config.floorHintBelow,
                                                ceilingCoverage: ceilingAsked, ceilingTarget: coach.config.ceilingHintBelow,
                                                furnitureMissing: furnitureMissing.count,
                                                furnitureFewViews: furnitureFewViews,
                                                coveragePrompt: coveragePrompt, coverageKnown: coverageKnown,
                                                turnHeavy: coach.turnHeavy))
        var stats = s
        stats.surfaceCoverage = surface
        stats.surfaceLow = coverageLate && (surface ?? 1) < coverage.config.targetShare
        stats.torchAvailable = torchAvailable
        stats.torchOn = torchAvailable && Torch.isOn
        if let at = torchAutoAt, time - at < 4 { stats.hint = "어두워서 손전등을 켰어요. 오른쪽 위 버튼으로 끌 수 있어요" }
        stats.coverageMap = coverageMap
        if let info = gapInfo, stats.hint == coveragePrompt { stats.coverageGap = info }   // 안내 문구가 '덜 찍힌 곳' 일 때만 화살표 배너
        onStats?(stats)
    }

    static var deviceModel: String {
        var sys = utsname()
        uname(&sys)
        return withUnsafePointer(to: &sys.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }
}

/// 폴링(메인 스레드, 10 Hz)마다 쓰는 가벼운 측정. 전체 픽셀이 아니라 격자 몇십~몇천 점만 읽는다.
enum FrameProbe {
    /// ARFrame.exifData 에서 ISO (키 ISOSpeedRatings, 값은 숫자 배열). EXIF 하위 사전({Exif})에 들어 있어도 찾는다
    static func iso(_ exif: [String: Any]) -> Double? {
        let key = "ISOSpeedRatings"
        let dict = exif[key] != nil ? exif : (exif["{Exif}"] as? [String: Any] ?? [:])
        if let list = dict[key] as? [NSNumber], let first = list.first { return first.doubleValue }
        if let list = dict[key] as? [Double], let first = list.first { return first }
        if let value = dict[key] as? NSNumber { return value.doubleValue }
        return nil
    }

    /// 깊이 지도(Float32, 미터) 가운데 60% 영역의 중앙값. 유효한 값이 적으면 nil
    static func centerDepth(_ buf: CVPixelBuffer) -> Double? {
        guard CVPixelBufferGetPixelFormatType(buf) == kCVPixelFormatType_DepthFloat32 else { return nil }
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buf) else { return nil }
        let w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf), row = CVPixelBufferGetBytesPerRow(buf)
        guard w >= 12, h >= 9 else { return nil }
        var values: [Float] = []
        values.reserveCapacity(108)
        for gy in 0..<9 {
            let y = h / 5 + (h * 3 / 5) * gy / 8                     // 20% … 80%
            let line = base.advanced(by: y * row).assumingMemoryBound(to: Float32.self)
            for gx in 0..<12 {
                let v = line[w / 5 + (w * 3 / 5) * gx / 11]
                if v.isFinite, v > 0.05 { values.append(v) }
            }
        }
        guard values.count >= 12 else { return nil }
        values.sort()
        return Double(values[values.count / 2])
    }

    /// 깊이 지도를 cols × rows 격자로 뽑아 월드 좌표로 바꾼다 (0.2 ~ 5 m). confident = 신뢰도 medium 이상 (바닥 높이 찾기에만 씀,
    /// 반들반들하거나 어두운 바닥은 신뢰도가 낮게 나오므로 바닥 비율에는 다 센다).
    /// intrinsics 는 컬러 해상도 기준(ARCamera.intrinsics) → 깊이 해상도로 줄여 쓴다. 카메라: x 오른쪽, y 위, -z 정면.
    /// samples = 격자 전체 점 수 (5 m 넘는 먼 벽 등 빠진 점 포함) — 바닥 비율의 분모
    static func worldPoints(depth: CVPixelBuffer, confidence: CVPixelBuffer?, intrinsics K: simd_float3x3,
                            colorWidth: Int, transform: simd_float4x4, cols: Int = 32, rows: Int = 24)
        -> (points: [SIMD3<Float>], confident: [Bool], samples: Int) {
        guard CVPixelBufferGetPixelFormatType(depth) == kCVPixelFormatType_DepthFloat32, colorWidth > 0 else { return ([], [], 0) }
        CVPixelBufferLockBaseAddress(depth, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depth, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(depth) else { return ([], [], 0) }
        let w = CVPixelBufferGetWidth(depth), h = CVPixelBufferGetHeight(depth), row = CVPixelBufferGetBytesPerRow(depth)
        guard w > 1, h > 1 else { return ([], [], 0) }

        var confBase: UnsafeMutableRawPointer?
        var confRow = 0
        var confLocked = false
        if let confidence, CVPixelBufferGetPixelFormatType(confidence) == kCVPixelFormatType_OneComponent8,
           CVPixelBufferGetWidth(confidence) == w, CVPixelBufferGetHeight(confidence) == h {
            CVPixelBufferLockBaseAddress(confidence, .readOnly)
            confLocked = true
            confBase = CVPixelBufferGetBaseAddress(confidence)
            confRow = CVPixelBufferGetBytesPerRow(confidence)
        }
        defer { if confLocked, let confidence { CVPixelBufferUnlockBaseAddress(confidence, .readOnly) } }

        let s = Float(w) / Float(colorWidth)
        let fx = K.columns.0.x * s, fy = K.columns.1.y * s, cx = K.columns.2.x * s, cy = K.columns.2.y * s
        var out: [SIMD3<Float>] = []
        var confident: [Bool] = []
        out.reserveCapacity(cols * rows)
        confident.reserveCapacity(cols * rows)
        for r in 0..<rows {
            let v = (h - 1) * r / max(rows - 1, 1)
            let line = base.advanced(by: v * row).assumingMemoryBound(to: Float32.self)
            for c in 0..<cols {
                let u = (w - 1) * c / max(cols - 1, 1)
                let d = line[u]
                guard d.isFinite, d > 0.2, d < 5 else { continue }
                let p = transform * SIMD4<Float>((Float(u) - cx) / fx * d, -(Float(v) - cy) / fy * d, -d, 1)
                out.append(SIMD3(p.x, p.y, p.z))
                confident.append(confBase.map { $0.load(fromByteOffset: v * confRow + u, as: UInt8.self) >= 1 } ?? true)
            }
        }
        return (out, confident, cols * rows)
    }

    /// 깊이 지도를 cols × rows 격자(칸 가운데 값)로 뽑는다 — 가구 전체 사진 점검용 (FurnitureShotMath).
    /// 신뢰도 low · 측정 없음 · 0.2 m 미만 · 5 m 초과는 0. 64 × 48 = 3072점만 읽는다
    static func depthGrid(depth: CVPixelBuffer, confidence: CVPixelBuffer?, cols: Int = 64, rows: Int = 48) -> DepthGrid? {
        guard CVPixelBufferGetPixelFormatType(depth) == kCVPixelFormatType_DepthFloat32 else { return nil }
        CVPixelBufferLockBaseAddress(depth, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depth, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(depth) else { return nil }
        let w = CVPixelBufferGetWidth(depth), h = CVPixelBufferGetHeight(depth), row = CVPixelBufferGetBytesPerRow(depth)
        guard w >= cols, h >= rows else { return nil }

        var confBase: UnsafeMutableRawPointer?
        var confRow = 0
        var confLocked = false
        if let confidence, CVPixelBufferGetPixelFormatType(confidence) == kCVPixelFormatType_OneComponent8,
           CVPixelBufferGetWidth(confidence) == w, CVPixelBufferGetHeight(confidence) == h {
            CVPixelBufferLockBaseAddress(confidence, .readOnly)
            confLocked = true
            confBase = CVPixelBufferGetBaseAddress(confidence)
            confRow = CVPixelBufferGetBytesPerRow(confidence)
        }
        defer { if confLocked, let confidence { CVPixelBufferUnlockBaseAddress(confidence, .readOnly) } }

        var meters = [Float](repeating: 0, count: cols * rows)
        for r in 0..<rows {
            let v = min(h - 1, (2 * r + 1) * h / (2 * rows))
            let line = base.advanced(by: v * row).assumingMemoryBound(to: Float32.self)
            for c in 0..<cols {
                let u = min(w - 1, (2 * c + 1) * w / (2 * cols))
                let d = line[u]
                guard d.isFinite, d > 0.2, d < 5 else { continue }
                if let confBase, confBase.load(fromByteOffset: v * confRow + u, as: UInt8.self) < 1 { continue }
                meters[r * cols + c] = d
            }
        }
        return DepthGrid(cols: cols, rows: rows, meters: meters)
    }

    /// 화면이 얼마나 "무늬가 있는지" (0~255). 밝기(Y) 평면의 64×48 격자 점마다 오른쪽 · 아래로 폭의 1/80 만큼 떨어진 점과의
    /// 밝기 차를 평균한다. 실제 촬영본 기준: 화이트보드만 가득 3.4 · 흔들린 보통 장면 13.9 · 노트북 가까이 30.2
    static func textureScore(_ buf: CVPixelBuffer) -> Double? {
        let format = CVPixelBufferGetPixelFormatType(buf)
        let videoRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        guard videoRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
              CVPixelBufferGetPlaneCount(buf) >= 1 else { return nil }
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buf, 0) else { return nil }
        let w = CVPixelBufferGetWidthOfPlane(buf, 0), h = CVPixelBufferGetHeightOfPlane(buf, 0)
        let row = CVPixelBufferGetBytesPerRowOfPlane(buf, 0)
        let d = max(w / 80, 2)                                        // 1920 → 24 px
        let gw = 64, gh = 48
        guard w > d + gw, h > d + gh else { return nil }
        let px = base.assumingMemoryBound(to: UInt8.self)
        var sum = 0
        for gy in 0..<gh {
            let y = (h - d - 1) * gy / (gh - 1)
            for gx in 0..<gw {
                let i = y * row + (w - d - 1) * gx / (gw - 1)
                let c = Int(px[i])
                sum += abs(Int(px[i + d]) - c) + abs(Int(px[i + d * row]) - c)
            }
        }
        let score = Double(sum) / Double(gw * gh)
        return videoRange ? score * 255 / 219 : score                 // 16~235 범위면 0~255 로 맞춘다
    }
}
