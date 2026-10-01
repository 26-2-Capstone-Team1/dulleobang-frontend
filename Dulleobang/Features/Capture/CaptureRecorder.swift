import ARKit
import UIKit
import Foundation

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
    var hasDepth: Bool { depthSize != nil }                           // LiDAR 깊이가 한 장이라도 저장됐는지
    private let osVersion = "iOS \(UIDevice.current.systemVersion)"     // init(메인 스레드)에서 읽어 둔다

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
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / AppConfig.shared.sampleHz, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    /// 샘플링만 멈춘다 (RoomPlan 후처리 중에도 호출 가능)
    func stopSampling() {
        isRecording = false
        timer?.invalidate()
        timer = nil
    }

    /// 쓰기 완료를 기다린 뒤 poses.json / meta.json / 추가 파일(RoomPlan 결과 등)을 쓰고 폴더 URL 을 돌려준다.
    /// 호출 전에 메인 스레드에서 stopSampling() 을 불러 둘 것 (Timer 는 설치한 스레드에서만 해제 가능).
    func finalize(extraFiles: [String: Data] = [:], roomplan: Bool = false) async throws -> URL {
        await withCheckedContinuation { cont in group.notify(queue: .main) { cont.resume() } }
        // 바닥 높이는 촬영 중에 정해지므로, 마지막 추정으로 프레임마다 바닥 비율을 다시 적는다
        let shares = coach.floorShares()
        if !shares.isEmpty {
            for i in poses.indices { poses[i].floorShare = shares[poses[i].frameId].map { ($0 * 1000).rounded() / 1000 } }
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
                               floorPhotos: coach.hasDepth ? coach.floorPhotos : nil)
        try enc.encode(meta).write(to: dir.appendingPathComponent("meta.json"))
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
        for (name, data) in extraFiles { try data.write(to: dir.appendingPathComponent(name)) }
        return dir
    }

    func discard() {
        stopSampling()
        try? FileManager.default.removeItem(at: dir.deletingLastPathComponent())
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
        defer { publish(tracking: tracking, hasDepth: depthData != nil) }

        // 쓰기가 밀리면 이번 프레임은 건너뛴다 (카메라 버퍼 풀 고갈 방지)
        guard inFlight < 3 else { return }
        // 많이 흔들린 프레임은 저장하지 않는다 → 화면에는 '너무 빨라요' 경고가 뜬다
        guard coach.frameBlurPx < coach.config.skipBlurPx else { return }
        guard sampler.shouldKeep(cam.transform, time: frame.timestamp, tracking: tracking) else { return }

        let id = poses.count
        let w = Int(cam.imageResolution.width), h = Int(cam.imageResolution.height)
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
                                floorShare: floorShare.map { ($0 * 1000).rounded() / 1000 }))
        colorSize = colorSize ?? [w, h]

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

    private func publish(tracking: TrackingState, hasDepth: Bool) {
        let cfg = AppConfig.shared
        let floor = kind == .room ? coach.floorCoverage : nil
        let s = CaptureStats(kept: sampler.kept, spanM: spanM, coverage: sampler.coverage,
                             tracking: tracking, hasDepth: hasDepth, alert: coach.alert, floorCoverage: floor,
                             hint: sampler.hint(kind: kind, tracking: tracking, spanM: spanM,
                                                minSpanM: cfg.roomMinSpanM, goodFrames: cfg.roomGoodFrames,
                                                floorCoverage: floor, floorTarget: coach.config.floorHintBelow))
        onStats?(s)
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
