import AVFoundation
import SwiftUI
import UIKit
import simd

// MARK: - 촬영을 마친 뒤 0.5× 광각(울트라 와이드) 가구 사진
//
// 방이 좁아 물러설 수 없으면 1× 카메라로는 가구 전체가 한 화면에 안 들어온다. ARKit(LiDAR · RoomPlan)은 스캔 중 1× 카메라 영상만
// 앱에 주고(world tracking 이 울트라 와이드를 내부에서 쓰지만 API 로 열어 주지 않음 — Apple 개발자 포럼 엔지니어 답변),
// 스캔 중에 다른 카메라를 따로 열면 ARSession 이 끊겨 포즈가 망가질 수 있다.
// 그래서 스캔을 끝내 ARSession 을 멈춘 뒤, 전체 사진이 없는 가구(다 안 들어옴)만 0.5× 로 한 장씩 찍는다 (WideShotTarget).
// 이 사진에는 ARKit 포즈 · LiDAR 깊이가 없다 → 서버가 frames/ 와 특징점 매칭으로 위치를 찾거나(COLMAP image_registrator · hloc),
// 단일 사진 3D(SAM 3D) 입력 · 가구 마스크(SAM 3 글자 프롬프트 "sofa" 등)로 쓴다.

/// 0.5× 광각 카메라 (AVFoundation). 사진은 센서 원래 방향(가로) 그대로 저장해 frames/ 와 같은 규약 · K 가 그대로 맞게 한다.
/// start · stop · capture 는 어느 스레드에서 불러도 된다 (세션 작업은 전용 큐에서).
final class UltraWideCamera: NSObject, @unchecked Sendable {      // 상태는 전용 큐 · lock 으로만 다룬다
    struct Photo {
        let jpeg: Data
        let width: Int
        let height: Int
        let K: simd_float3x3?                // 사진 해상도 기준 내부 파라미터 (AVFoundation 영상 프레임의 값을 사진 크기로 늘림, 없으면 nil)
    }

    enum Failure: LocalizedError {
        case noCamera, cannotConfigure, busy, noData
        var errorDescription: String? {
            switch self {
            case .noCamera: return "이 기기에는 0.5× 광각 카메라가 없어요"
            case .cannotConfigure: return "광각 카메라를 열 수 없어요"
            case .busy: return "사진을 찍는 중이에요"
            case .noData: return "사진 데이터를 받지 못했어요"
            }
        }
    }

    static var isAvailable: Bool {
        AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) != nil
    }

    /// 마지막 사진을 찍은 순간의 카메라 상태 (왜곡 보정 · 화각 · extrinsic) → meta.json 의 cameras.ultraWide. 한 장도 못 찍었으면 nil
    var cameraInfo: CameraRig.UltraWide? {
        lock.lock()
        defer { lock.unlock() }
        return lastInfo
    }

    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()       // 내부 파라미터(intrinsic matrix)를 받으려고만 쓴다
    private let queue = DispatchQueue(label: "capture.ultrawide", qos: .userInitiated)
    private let lock = NSLock()
    private var configured = false                             // queue 에서만
    private var latest: (K: simd_float3x3, width: Int, height: Int)?   // lock
    private var pending: CheckedContinuation<Photo, Error>?    // lock
    private var activeDevice: AVCaptureDevice?                  // lock — 렌즈 · 왜곡 보정 상태를 읽을 때만 쓴다
    private var lastInfo: CameraRig.UltraWide?                  // lock — 마지막 사진을 찍은 순간의 카메라 상태

    /// 세션을 구성하고 시작한다 (startRunning 은 오래 걸릴 수 있어 전용 큐에서)
    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                try self.configureIfNeeded()
                if !self.session.isRunning { self.session.startRunning() }
            } catch {
                print("[ultrawide] start failed: \(error)")
            }
        }
    }

    func stop() {
        lock.lock()
        let cont = pending
        pending = nil
        lock.unlock()
        cont?.resume(throwing: CancellationError())             // 찍는 중이던 사진은 취소
        queue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    func capture() async throws -> Photo {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Photo, Error>) in
            queue.async { [self] in
                guard configured, session.isRunning else { cont.resume(throwing: Failure.cannotConfigure); return }
                lock.lock()
                if pending != nil {
                    lock.unlock()
                    cont.resume(throwing: Failure.busy)
                    return
                }
                pending = cont
                lock.unlock()
                let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                settings.photoQualityPrioritization = .balanced
                photoOutput.capturePhoto(with: settings, delegate: self)
            }
        }
    }

    private func configureIfNeeded() throws {
        guard !configured else { return }
        guard let device = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) else {
            throw Failure.noCamera
        }
        let input = try AVCaptureDeviceInput(device: device)
        lock.lock()
        activeDevice = device
        lock.unlock()
        // 왜곡 보정(GDC): 초광각 가장자리의 어안 왜곡을 Apple 이 펴 준다 (대신 화각이 조금 줄고, 보정한 사진을 원래 크기로 키운다).
        // 지원하는 기기는 기본값이 켜짐이지만 분명히 켜 둔다. 끄면 원본 왜곡 사진이 나오는데, 그때의 보정표(lensDistortionLookupTable)는
        // 가상 장치(트리플 카메라)의 구성 사진 모드에서만 받을 수 있다 (isCameraCalibrationDataDeliverySupported 문서)
        if device.isGeometricDistortionCorrectionSupported {
            do {
                try device.lockForConfiguration()
                device.isGeometricDistortionCorrectionEnabled = true
                device.unlockForConfiguration()
            } catch {
                print("[ultrawide] 왜곡 보정 설정 실패: \(error)")
            }
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard session.canAddInput(input), session.canAddOutput(photoOutput) else { throw Failure.cannotConfigure }
        session.addInput(input)
        session.addOutput(photoOutput)
        if session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }   // 4:3 사진 (GDC 가 켜지면 화각이 조금 줄어든다)
        photoOutput.maxPhotoQualityPrioritization = .quality
        if session.canAddOutput(videoOutput) {
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: queue)
            session.addOutput(videoOutput)
            if let c = videoOutput.connection(with: .video), c.isCameraIntrinsicMatrixDeliverySupported {
                c.isCameraIntrinsicMatrixDeliveryEnabled = true
            }
        }
        configured = true
    }

    /// 영상 프레임의 내부 파라미터를 사진 크기로 늘린다 (같은 4:3 화각이라 비율만 곱하면 된다)
    private func intrinsics(width w: Int, height h: Int) -> simd_float3x3? {
        lock.lock()
        defer { lock.unlock() }
        guard let l = latest, l.width > 0, l.height > 0 else { return nil }
        let sx = Float(w) / Float(l.width), sy = Float(h) / Float(l.height)
        var K = l.K
        K.columns.0.x *= sx
        K.columns.2.x *= sx
        K.columns.1.y *= sy
        K.columns.2.y *= sy
        return K
    }

    /// 사진을 찍은 순간의 렌즈 · 왜곡 보정 · 화각 · 메인 카메라와의 extrinsic (meta.json 의 cameras.ultraWide)
    private func makeInfo(width w: Int, height h: Int, K: simd_float3x3?) -> CameraRig.UltraWide? {
        lock.lock()
        let dev = activeDevice
        lock.unlock()
        guard let dev else { return nil }
        let format = dev.activeFormat
        let supported = dev.isGeometricDistortionCorrectionSupported
        let enabled = supported && dev.isGeometricDistortionCorrectionEnabled
        let distortion: CameraRig.Distortion
        if enabled {
            distortion = CameraRig.Distortion(
                model: "pinhole",
                note: "Apple 의 왜곡 보정(GDC)이 켜진 사진이라 핀홀로 간주한다 (보정 뒤에 남은 왜곡은 재지 않았다). "
                    + "보정표(lensDistortionLookupTable)는 이 방식으로는 받을 수 없다 — Apple 문서상 GDC 를 끄고 가상 장치(트리플 카메라)의 구성 사진 모드로 찍어야 제공된다")
        } else if supported {
            distortion = CameraRig.Distortion(
                model: "uncorrected",
                note: "왜곡 보정(GDC)이 꺼진 원본 사진인데, 이 촬영 방식에서는 보정표를 받을 수 없다")
        } else {
            distortion = CameraRig.Distortion(
                model: "unknown",
                note: "이 기기는 왜곡 보정(GDC)을 지원하지 않는다 — 사진의 왜곡이 보정됐는지 알 수 없다")
        }
        let corrected = Double(format.geometricDistortionCorrectedVideoFieldOfView)
        let raw = Double(format.videoFieldOfView)
        let fov = CameraRig.UltraWide.FieldOfViewReport(
            horizontalFromK: K.map { CameraRig.round(CameraRig.fovDeg(size: Double(w), focal: Double($0.columns.0.x)), digits: 1) },
            verticalFromK: K.map { CameraRig.round(CameraRig.fovDeg(size: Double(h), focal: Double($0.columns.1.y)), digits: 1) },
            horizontalGdcCorrected: corrected > 0 ? CameraRig.round(corrected, digits: 1) : nil,
            horizontalUncorrected: raw > 0 ? CameraRig.round(raw, digits: 1) : nil)
        var extrinsic: CameraRig.Extrinsic?
        if let main = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           let data = AVCaptureDevice.extrinsicMatrix(from: dev, to: main),
           let m = Self.decodeExtrinsic(data) {
            extrinsic = CameraRig.Extrinsic(R: m.R.map { $0.map { CameraRig.round($0, digits: 6) } },
                                            t_mm: m.t.map { CameraRig.round($0, digits: 3) })
        }
        return CameraRig.UltraWide(deviceType: dev.deviceType.rawValue, name: dev.localizedName, imageSize: [w, h],
                                   geometricDistortionCorrection: .init(supported: supported, enabled: enabled),
                                   distortion: distortion, fovDeg: fov, extrinsicToMain: extrinsic)
    }

    /// AVCaptureDevice.extrinsicMatrix(from:to:) 의 Data (matrix_float4x3: 열 우선, 3행 4열)를 회전 R(3×3, 행 우선)과 이동 t(mm)로 푼다.
    /// 열이 16바이트로 패딩된 것(64바이트)과 붙어 있는 것(48바이트) 둘 다 받는다
    static func decodeExtrinsic(_ data: Data) -> (R: [[Double]], t: [Double])? {
        let n = data.count / MemoryLayout<Float>.size
        guard n >= 12 else { return nil }
        let f: [Float] = data.withUnsafeBytes { raw in
            (0..<n).map { raw.loadUnaligned(fromByteOffset: $0 * MemoryLayout<Float>.size, as: Float.self) }
        }
        let colStride = n >= 16 ? 4 : 3                            // 한 열이 float 몇 개를 차지하나 (패딩 포함)
        func at(_ row: Int, _ col: Int) -> Double { Double(f[col * colStride + row]) }
        let R = (0..<3).map { r in (0..<3).map { c in at(r, c) } }
        let t = (0..<3).map { r in at(r, 3) }
        return (R, t)
    }
}

extension UltraWideCamera: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        lock.lock()
        let cont = pending
        pending = nil
        lock.unlock()
        guard let cont else { return }
        if let error { cont.resume(throwing: error); return }
        guard let data = photo.fileDataRepresentation() else { cont.resume(throwing: Failure.noData); return }
        let dims = photo.resolvedSettings.photoDimensions
        let w = Int(dims.width), h = Int(dims.height)
        let K = intrinsics(width: w, height: h)
        if let info = makeInfo(width: w, height: h, K: K) {
            lock.lock()
            lastInfo = info
            lock.unlock()
        }
        cont.resume(returning: Photo(jpeg: data, width: w, height: h, K: K))
    }
}

extension UltraWideCamera: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let raw = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
                                        attachmentModeOut: nil) as? Data,
              raw.count >= MemoryLayout<simd_float3x3>.size,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        var K = simd_float3x3()
        _ = withUnsafeMutableBytes(of: &K) { raw.copyBytes(to: $0) }
        let w = CVPixelBufferGetWidth(pixels), h = CVPixelBufferGetHeight(pixels)
        lock.lock()
        latest = (K, w, h)
        lock.unlock()
    }
}

/// 0.5× 광각 미리보기. 찍히는 범위가 잘리지 않게 aspect-fit, 세로 화면
struct UltraWidePreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        override func layoutSubviews() {
            super.layoutSubviews()
            if let c = previewLayer.connection, c.isVideoRotationAngleSupported(90), c.videoRotationAngle != 90 {
                c.videoRotationAngle = 90                       // 뒤 카메라 세로 화면
            }
        }
    }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.backgroundColor = .black
        v.previewLayer.videoGravity = .resizeAspect
        v.previewLayer.session = session
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

/// wide_shots.json — 촬영을 마친 뒤 0.5× 광각으로 찍은 가구 사진 (wide/NNN.jpg)
struct WideShotsFile: Codable {
    struct Intrinsics: Codable { var fx, fy, cx, cy: Double }

    struct Shot: Codable {
        var file: String                     // wide/000.jpg — 센서 원래 방향(가로), 회전하지 않음
        var objectId: String                 // furniture_shots.json · roomplan_structure.json 의 objectId
        var alsoFor: [String]                // 같은 모양이라 이 사진을 함께 쓰는 가구
        var category: String
        var label: String
        var reason: String                   // 1× 로 전체 사진을 못 찍은 이유 (notWhole)
        var width: Int
        var height: Int
        var K: Intrinsics?                   // 영상 프레임의 intrinsic matrix 를 사진 크기로 환산한 근사값 — meta.json cameras.ultraWide.fovDeg 와 맞는지 보고 서버에서 다시 맞추세요
        var takenAt: String
    }

    var version = 1
    var camera = "builtInUltraWideCamera (0.5x) · AVFoundation · ARKit/RoomPlan 스캔을 마친 뒤 — 왜곡 보정 · 화각 · extrinsic 은 meta.json 의 cameras.ultraWide"
    var note = "ARKit 포즈 · LiDAR 깊이가 없는 사진. frames/ 와 특징점 매칭으로 위치를 찾거나(COLMAP image_registrator · hloc), "
        + "단일 사진 3D(SAM 3D) 입력 · SAM 3 가구 마스크(글자 프롬프트 = category)로 쓰세요. 가구는 대개 화면 가운데에 있다"
    var shots: [Shot]

    /// 사진 한 장을 wide/NNN.jpg 로 저장하고 기록을 돌려준다
    static func save(_ photo: UltraWideCamera.Photo, index: Int, target: WideShotTarget, in dir: URL) throws -> Shot {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("wide", isDirectory: true),
                                                withIntermediateDirectories: true)
        let name = String(format: "wide/%03d.jpg", index)
        try photo.jpeg.write(to: dir.appendingPathComponent(name))
        let K = photo.K.map { m in
            Intrinsics(fx: Double(m.columns.0.x), fy: Double(m.columns.1.y), cx: Double(m.columns.2.x), cy: Double(m.columns.2.y))
        }
        return Shot(file: name, objectId: target.objectId, alsoFor: target.alsoFor, category: target.category,
                    label: target.label, reason: target.problem, width: photo.width, height: photo.height, K: K,
                    takenAt: ISO8601DateFormatter().string(from: Date()))
    }

    static func write(_ shots: [Shot], to dir: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(WideShotsFile(shots: shots)).write(to: dir.appendingPathComponent("wide_shots.json"))
    }
}

// MARK: - meta.json 의 cameras

/// meta.json 의 "cameras" — 사진을 어느 카메라로 어떻게 찍었는지 (서버가 사진을 맞추고 왜곡을 펼 때 쓴다).
/// main = 스캔 중 ARKit 1× 프레임(frames/ · depth/), ultraWide = 스캔을 마친 뒤 찍은 0.5× 사진(wide/ — 찍은 경우에만)
struct CameraRig: Codable {
    /// 사진을 어떤 카메라 모델로 봐야 하는지. 왜곡 계수 · 보정표는 이 앱이 주지 않는다 (없는 이유는 note)
    struct Distortion: Codable {
        var model: String                        // pinhole = 왜곡 없는 핀홀로 간주 · uncorrected = 보정 안 됨 · unknown = 알 수 없음
        var coefficients: [Double]? = nil
        var lookupTable: [Double]? = nil         // Apple lensDistortionLookupTable
        var note: String
    }

    struct FieldOfView: Codable {
        var horizontalDeg: Double
        var verticalDeg: Double
    }

    struct DepthInfo: Codable {
        var source = "LiDAR (ARKit sceneDepth)"
        var imageSize: [Int]
        var colorToDepthScale: [Double]          // 깊이 크기 ÷ 컬러 크기
        var note = "깊이는 컬러와 같은 4:3 화각 전체를 덮는다. 깊이 K = 컬러 K × colorToDepthScale (depth.json 과 같은 규약)"
    }

    /// 스캔 중 ARKit 1× 프레임
    struct Main: Codable {
        var camera = "메인 광각(1×) — ARKit capturedImage (frames/)"
        var api = "ARKit"
        var imageSize: [Int]? = nil
        var intrinsics = "poses.json 의 K — 프레임마다 (fx, fy, cx, cy), imageSize 기준"
        var fxMedian: Double? = nil
        var fovDeg: FieldOfView? = nil           // fxMedian · imageSize 로 계산
        var distortion = Distortion(model: "pinhole",
                                    note: "ARKit 은 왜곡 계수를 주지 않는다. K 만 있는 핀홀로 취급했고, 남은 왜곡은 따로 재지 않았다")
        var depth: DepthInfo? = nil
        var pose = "poses.json 의 T_wc (카메라→월드, ARKit 월드)"
    }

    /// 초광각 → 메인 카메라의 공장 보정 위치 관계
    struct Extrinsic: Codable {
        var from = "ultraWide"
        var to = "main"
        var R: [[Double]]                        // 3×3, 행 우선
        var t_mm: [Double]                       // 밀리미터
        var formula = "X_main = R · X_ultraWide + t   (AVCaptureDevice.extrinsicMatrix(from:to:), 공장 보정)"
        var note = "두 렌즈 사이의 고정된 위치 관계다. 0.5× 사진은 ARKit 프레임과 같은 순간에 찍지 않아 이 값만으로는 사진의 월드 포즈를 구할 수 없다. "
            + "카메라 축 방향 규약은 Apple 문서에 없다 — 쓰기 전에 확인할 것"
    }

    /// 스캔을 마친 뒤 찍은 0.5× 사진
    struct UltraWide: Codable {
        struct GDC: Codable {
            var supported: Bool
            var enabled: Bool
        }

        struct FieldOfViewReport: Codable {
            var horizontalFromK: Double?         // wide_shots.json 의 K · 사진 크기로 계산 (사진 가로 방향)
            var verticalFromK: Double?
            var horizontalGdcCorrected: Double?  // AVCaptureDevice.Format.geometricDistortionCorrectedVideoFieldOfView (GDC 뒤)
            var horizontalUncorrected: Double?   // AVCaptureDevice.Format.videoFieldOfView (GDC 전)
        }

        var camera = "초광각(0.5×) — builtInUltraWideCamera"
        var api = "AVFoundation (AVCaptureSession + AVCapturePhotoOutput) — ARSession 을 멈춘 뒤 한 장씩"
        var deviceType: String
        var name: String
        var photos = "wide_shots.json — 사진마다 파일 · K(fx, fy, cx, cy; 사진 해상도 기준) · 크기"
        var imageSize: [Int]
        var geometricDistortionCorrection: GDC
        var distortion: Distortion
        var fovDeg: FieldOfViewReport
        var extrinsicToMain: Extrinsic? = nil
        var depth = "없음 — ARSession 이 멈춘 뒤라 LiDAR 깊이를 받지 않는다"
        var pose = "없음 — ARKit 포즈가 없다. frames/ 와 특징점 매칭으로 위치를 찾는다"
    }

    var main: Main
    var ultraWide: UltraWide? = nil              // 0.5× 사진을 찍은 때만

    /// 핀홀 카메라의 화각(도): size(px) 방향, 초점거리 focal(px)
    static func fovDeg(size: Double, focal: Double) -> Double {
        2 * atan(size / (2 * focal)) * 180 / .pi
    }

    static func round(_ x: Double, digits: Int) -> Double {
        let p = pow(10.0, Double(digits))
        return (x * p).rounded() / p
    }
}

extension CameraRig.Main {
    /// poses.json 의 K 중앙값과 컬러 · 깊이 크기로 채운다
    init(colorSize: [Int]?, depthSize: [Int]?, poses: [PoseRecord]) {
        self.init()
        imageSize = colorSize
        guard let c = colorSize, c.count == 2, c[0] > 0, c[1] > 0 else { return }
        let fx = poses.map { $0.K.fx }.sorted()
        let fy = poses.map { $0.K.fy }.sorted()
        if !fx.isEmpty, fx.count == fy.count {
            let mx = fx[fx.count / 2], my = fy[fy.count / 2]
            fxMedian = CameraRig.round(mx, digits: 1)
            fovDeg = CameraRig.FieldOfView(horizontalDeg: CameraRig.round(CameraRig.fovDeg(size: Double(c[0]), focal: mx), digits: 1),
                                           verticalDeg: CameraRig.round(CameraRig.fovDeg(size: Double(c[1]), focal: my), digits: 1))
        }
        if let d = depthSize, d.count == 2 {
            depth = CameraRig.DepthInfo(imageSize: d, colorToDepthScale: [Double(d[0]) / Double(c[0]), Double(d[1]) / Double(c[1])])
        }
    }
}
