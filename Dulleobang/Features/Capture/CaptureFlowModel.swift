import ARKit
import Combine
import Foundation
import UIKit

/// 촬영을 마치고 아직 업로드하지 않은 결과 (매물 등록 화면에서 매물을 만든 뒤 올린다)
struct CapturedSpace: Equatable {
    let captureDir: URL            // …/captures/<id>/capture
    let zipURL: URL                // …/captures/<id>/capture.zip
    let frameCount: Int
    let hasDepth: Bool
    let hasRoomPlan: Bool
    let sizeMB: Double
}

/// 촬영 → (RoomPlan 후처리) → 파일 정리 → zip → 업로드 → AI 작업 대기 흐름.
@MainActor
final class CaptureFlowModel: ObservableObject {
    enum Target: Equatable {
        case listing(String)            // 중개사: 매물 방 촬영 → POST /listings/{id}/captures
        case furniture(String)          // 임차인: 보유 가구 촬영 → POST /furniture/{id}/captures
        case localOnly(CaptureKind)     // 백엔드 없이 zip 만 만들기 (AirDrop 으로 AI 팀원에게 전달)
        case deferred(CaptureKind)      // zip 까지만 만들고 돌려준다 (매물 등록 화면이 매물 생성 후 업로드)
    }

    enum Phase: Equatable {
        case ready
        case recording
        case finishing(String)
        case uploading(Double)
        case processing(String)         // 업로드 완료, AI 처리 중 (닫아도 서버에서 계속됨)
        case captured(CapturedSpace)    // .deferred: 촬영본 준비됨
        case done
        case share(URL)
        case failed(String)
    }

    @Published var phase: Phase = .ready
    @Published var stats = CaptureStats()
    @Published var notice: String?
    /// 정지를 눌렀는데 제자리에서만 찍었거나 바닥이 덜 찍혔을 때 확인 (더 찍기 / 그대로 끝내기)
    struct StopWarning: Equatable { let title: String; let message: String }
    @Published var stopWarning: StopWarning?

    let target: Target
    let session = ARSession()
    let roomPlan = RoomPlanController()
    let useRoomPlan: Bool

    private var recorder: CaptureRecorder?
    private var work: Task<Void, Never>?
    private var zipDir: URL?
    private let haptics = UINotificationFeedbackGenerator()
    private var lastBuzz: [CaptureAlert: Date] = [:]

    var kind: CaptureKind {
        switch target {
        case .listing: return .room
        case .furniture: return .furniture
        case .localOnly(let k), .deferred(let k): return k
        }
    }

    private var minFrames: Int { kind == .room ? 30 : 15 }

    init(target: Target) {
        self.target = target
        let k: CaptureKind
        switch target {
        case .listing: k = .room
        case .furniture: k = .furniture
        case .localOnly(let kk), .deferred(let kk): k = kk
        }
        useRoomPlan = k == .room && RoomPlanController.isSupported && AppConfig.shared.useRoomPlan
    }

    func appear() {
        // RoomPlan 은 시작 버튼을 누를 때 자기 설정으로 세션을 실행한다. 일반 모드는 미리보기를 위해 바로 실행.
        if !useRoomPlan { ARCameraView.run(session) }
    }

    func disappear() {
        work?.cancel()
        if phase == .recording { recorder?.discard() }
        recorder?.stopSampling()
        session.pause()
    }

    func start() {
        do {
            let r = try CaptureRecorder(session: session, kind: kind)
            r.onStats = { [weak self] s in self?.apply(s) }
            recorder = r
            lastBuzz = [:]
            haptics.prepare()
            if useRoomPlan { roomPlan.start() }
            r.start()
            phase = .recording
        } catch {
            phase = .failed("촬영 폴더를 만들 수 없습니다: \(error.localizedDescription)")
        }
    }

    /// force = 제자리 경고를 보고도 "그대로 끝내기" 를 고름
    func stop(force: Bool = false) {
        guard let recorder, phase == .recording else { return }
        guard recorder.frameCount >= minFrames else {
            notice = "프레임이 너무 적습니다 (\(recorder.frameCount)/\(minFrames)). 조금 더 촬영해 주세요"
            return
        }
        if !force, kind == .room {
            if recorder.spanM < recorder.stillSpanM {
                stopWarning = StopWarning(
                    title: "제자리에서만 찍었어요",
                    message: "카메라가 \(String(format: "%.1f", recorder.spanM)) m 범위 안에서만 움직였어요.\n"
                        + "제자리에서 찍으면 3D가 흐릿하게 나와요. 벽을 따라 걸으면서 조금 더 찍을까요?")
                return
            }
            if let floor = recorder.floorCoverage, floor < recorder.floorAlertBelow {
                stopWarning = StopWarning(
                    title: "바닥이 덜 찍혔어요",
                    message: "걸어온 길 중 바닥을 찍은 곳이 \(Int((floor * 100).rounded()))%뿐이에요. 바닥이 비면 3D 바닥에 구멍이 생겨요.\n"
                        + "폰을 아래로 30~45° 기울여 바닥이 화면 절반쯤 보이게 한 바퀴 더 찍을까요?")
                return
            }
        }
        stopWarning = nil
        work = Task { await finish(recorder) }
    }

    /// 녹화 중 통계 반영. 새 경고가 뜨면 진동(같은 경고는 4초에 한 번) + VoiceOver 안내
    private func apply(_ s: CaptureStats) {
        if phase == .recording, let alert = s.alert, alert != stats.alert {
            let now = Date()
            if now.timeIntervalSince(lastBuzz[alert] ?? .distantPast) > 4 {
                haptics.notificationOccurred(alert.isSevere ? .error : .warning)
                haptics.prepare()
                UIAccessibility.post(notification: .announcement, argument: alert.title)
                lastBuzz[alert] = now
            }
        }
        stats = s
    }

    func retry() {
        recorder?.discard()
        recorder = nil
        stats = CaptureStats()
        stopWarning = nil
        phase = .ready
        if !useRoomPlan { ARCameraView.run(session) }
    }

    private func finish(_ recorder: CaptureRecorder) async {
        do {
            recorder.stopSampling()
            var extras: [String: Data] = [:]
            if useRoomPlan {
                phase = .finishing("방 구조 분석 중 (RoomPlan)…")
                roomPlan.stop()
                if let room = await roomPlan.waitForResult() {
                    extras = RoomPlanExport.files(from: room)
                } else if let msg = roomPlan.errorMessage {
                    notice = "RoomPlan 결과 없이 진행합니다: \(msg)"
                }
            }
            session.pause()

            phase = .finishing("파일 정리 중…")
            let dir = try await recorder.finalize(extraFiles: extras, roomplan: !extras.isEmpty)
            let zip = try await CapturePackager.zip(dir)
            zipDir = dir

            let progress: @Sendable (Double) -> Void = { [weak self] p in
                Task { @MainActor in self?.phase = .uploading(p) }
            }
            switch target {
            case .localOnly:
                phase = .share(zip)
                return
            case .deferred:
                phase = .captured(CapturedSpace(captureDir: dir, zipURL: zip, frameCount: recorder.frameCount,
                                                hasDepth: recorder.hasDepth, hasRoomPlan: !extras.isEmpty,
                                                sizeMB: CapturePackager.sizeMB(zip)))
                return
            case .listing(let id):
                phase = .uploading(0)
                let acc = try await ListingAPI.uploadCapture(id, zip: zip, progress: progress)
                CapturePackager.cleanup(dir); zipDir = nil
                try await waitJob(acc.jobId)
            case .furniture(let id):
                phase = .uploading(0)
                let acc = try await FurnitureAPI.uploadCapture(id, zip: zip, progress: progress)
                CapturePackager.cleanup(dir); zipDir = nil
                try await waitJob(acc.jobId)
            }
        } catch is CancellationError {
            // 화면을 닫음 — 업로드가 끝났다면 서버 작업은 계속된다
        } catch {
            phase = .failed("업로드 실패: \(error.localizedDescription)\n촬영 파일은 기기에 남아 있어 다시 시도할 수 있습니다.")
        }
    }

    private func waitJob(_ jobId: String) async throws {
        phase = .processing("업로드 완료 · AI 처리 대기 중")
        let job = try await JobAPI.wait(jobId) { [weak self] j in
            let pct = j.percent.map { " \($0)%" } ?? ""
            self?.phase = .processing("AI 처리 중 (\(j.status))\(pct)")
        }
        phase = job.isDone ? .done : .failed(job.message ?? "AI 처리에 실패했습니다")
    }

    /// 업로드 실패 후 같은 zip 으로 재시도
    func retryUpload() {
        guard let dir = zipDir else { return }
        let zip = dir.deletingLastPathComponent().appendingPathComponent("capture.zip")
        work = Task {
            do {
                let progress: @Sendable (Double) -> Void = { [weak self] p in Task { @MainActor in self?.phase = .uploading(p) } }
                phase = .uploading(0)
                let acc: Accepted
                switch target {
                case .listing(let id): acc = try await ListingAPI.uploadCapture(id, zip: zip, progress: progress)
                case .furniture(let id): acc = try await FurnitureAPI.uploadCapture(id, zip: zip, progress: progress)
                case .localOnly: phase = .share(zip); return
                case .deferred: return          // 업로드는 매물 등록 화면이 한다
                }
                CapturePackager.cleanup(dir); zipDir = nil
                try await waitJob(acc.jobId)
            } catch is CancellationError {
            } catch {
                phase = .failed("업로드 실패: \(error.localizedDescription)")
            }
        }
    }

    var canRetryUpload: Bool {
        if case .deferred = target { return false }
        return zipDir != nil
    }

    /// .deferred 결과를 쓰지 않고 닫을 때 파일 정리
    func discardCaptured() {
        if case .captured(let c) = phase { CapturePackager.cleanup(c.captureDir) }
        zipDir = nil
        recorder = nil
        phase = .ready
    }
}
