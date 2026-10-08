import AVFoundation
import SwiftUI
import UIKit
import simd

// MARK: - 촬영을 마친 뒤 0.5× 광각(울트라 와이드) 가구 사진
//
// 방이 좁아 물러설 수 없으면 1× 카메라로는 가구 전체가 한 화면에 안 들어온다. ARKit(LiDAR · RoomPlan)은 스캔 중 1× 카메라 영상만
// 앱에 주고(world tracking 이 울트라 와이드를 내부에서 쓰지만 API 로 열어 주지 않음 — Apple 개발자 포럼 엔지니어 답변),
// 스캔 중에 다른 카메라를 따로 열면 ARSession 이 끊겨 포즈가 망가질 수 있다.
// 그래서 스캔을 끝내 ARSession 을 멈춘 뒤, 전체 사진이 없는 가구(다 안 들어옴 · 가려짐)만 0.5× 로 한 장씩 찍는다 (WideShotTarget).
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

    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()       // 내부 파라미터(intrinsic matrix)를 받으려고만 쓴다
    private let queue = DispatchQueue(label: "capture.ultrawide", qos: .userInitiated)
    private let lock = NSLock()
    private var configured = false                             // queue 에서만
    private var latest: (K: simd_float3x3, width: Int, height: Int)?   // lock
    private var pending: CheckedContinuation<Photo, Error>?    // lock

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
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard session.canAddInput(input), session.canAddOutput(photoOutput) else { throw Failure.cannotConfigure }
        session.addInput(input)
        session.addOutput(photoOutput)
        if session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }   // 4:3 전체 화각 (기본으로 왜곡 보정된 사진)
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
        cont.resume(returning: Photo(jpeg: data, width: w, height: h, K: intrinsics(width: w, height: h)))
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
        var reason: String                   // 1× 로 전체 사진을 못 찍은 이유 (notWhole · blocked)
        var width: Int
        var height: Int
        var K: Intrinsics?                   // AVFoundation 이 준 근사값 (왜곡 보정된 사진 기준) — 서버에서 다시 맞추세요
        var takenAt: String
    }

    var version = 1
    var camera = "builtInUltraWideCamera (0.5x) · AVFoundation · ARKit/RoomPlan 스캔을 마친 뒤"
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
