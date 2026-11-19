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
        case wideShot(WideStep)         // 촬영을 마친 뒤 0.5× 광각으로 가구 사진 (ARSession 은 멈춘 상태)
    }

    @Published var phase: Phase = .ready
    @Published var stats = CaptureStats()
    @Published var notice: String?
    /// 정지를 눌렀는데 제자리에서만 찍었거나 바닥 · 천장이 덜 찍혔을 때 확인 (더 찍기 / 그대로 끝내기)
    struct StopWarning: Equatable {
        let title: String
        let message: String
        var offersWide = false          // "끝내고 0.5× 광각으로 찍기" 버튼을 함께 보여 줌
    }
    @Published var stopWarning: StopWarning?
    /// 0.5× 광각 사진 단계의 한 장 (화면 표시용)
    struct WideStep: Equatable {
        let index: Int
        let total: Int
        let label: String               // "소파"
        let alsoCount: Int              // 같은 모양이라 이 사진을 함께 쓰는 가구 수
        let problem: String             // notWhole
    }
    @Published private(set) var wideBusy = false

    let target: Target
    let session = ARSession()
    let roomPlan = RoomPlanController()
    let wideCamera = UltraWideCamera()
    let useRoomPlan: Bool

    private var recorder: CaptureRecorder?
    private var work: Task<Void, Never>?
    private var zipDir: URL?
    private let haptics = UINotificationFeedbackGenerator()
    private var lastBuzz: [CaptureAlert: Date] = [:]
    private var wideTargets: [WideShotTarget] = []
    private var wideShots: [WideShotsFile.Shot] = []
    private var wideIndex = 0
    private var wideDir: URL?
    private var wideContinuation: CheckedContinuation<Void, Never>?
    private var wideOffered = false                          // 끝낼 때 0.5× 광각 촬영을 이미 제안했는지 (한 번만)
    private var warnedMissing: Set<String> = []              // 끝낼 때 "전체 사진이 없는 가구" 로 이미 물어본 가구 (같은 가구를 또 묻지 않는다)
    private var warnedCeiling = false                        // 끝낼 때 "천장이 덜 찍혔어요" 를 이미 물어봤는지 (한 번만)
    private var warnedCoverage = false                       // 끝낼 때 "덜 찍힌 곳이 있어요" 를 이미 물어봤는지 (한 번만)

    var kind: CaptureKind {
        switch target {
        case .listing: return .room
        case .furniture: return .furniture
        case .localOnly(let k), .deferred(let k): return k
        }
    }

    private var minFrames: Int { kind == .room ? 80 : 30 }      // 초당 약 5장 저장 기준 (방 약 16초 · 가구 약 6초)

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
        endWideShots()
        wideCamera.stop()
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
            wideOffered = false
            warnedMissing = []
            warnedCeiling = false
            warnedCoverage = false
            haptics.prepare()
            if useRoomPlan {
                // 스캔 중 RoomPlan 가구 상자 → 가구 전체 사진 점검
                roomPlan.onFurniture = { [weak self] boxes in self?.recorder?.updateFurniture(boxes) }
                roomPlan.onWalls = { [weak self] walls in self?.recorder?.updateSurfaces(walls) }   // 벽 · 바닥 커버리지
                roomPlan.start()
            }
            r.start()
            phase = .recording
        } catch {
            phase = .failed("촬영 폴더를 만들 수 없습니다: \(error.localizedDescription)")
        }
    }

    /// force = 제자리 경고를 보고도 "그대로 끝내기" 를 고름
    /// wide = 끝낸 뒤 0.5× 광각 사진 단계로 (가구 경고에서 "끝내고 0.5× 광각으로 찍기")
    /// 화면 오른쪽 위 손전등 버튼
    func toggleTorch() { recorder?.toggleTorch() }

    func stop(force: Bool = false, wide: Bool = false) {
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
            // 천장은 선택 사항이라 한 번만 묻는다. 안내를 오래 했는데도 안 늘어 포기했으면 묻지 않는다
            if !warnedCeiling, !recorder.ceilingGaveUp, let ceiling = recorder.ceilingCoverage,
               ceiling < recorder.ceilingAlertBelow {
                warnedCeiling = true
                stopWarning = StopWarning(
                    title: "천장이 덜 찍혔어요",
                    message: "걸어온 길 위의 천장을 찍은 곳이 \(Int((ceiling * 100).rounded()))%뿐이에요. 천장이 비면 3D 천장에 구멍이 생길 수 있어요.\n"
                        + "폰을 위로 30~45° 기울여 천장이 화면에 크게 보이게 한 바퀴 더 찍을까요? (벽 모서리나 조명이 같이 보이면 위치를 덜 놓쳐요)")
                return
            }
            // 벽 · 바닥 중 사진 3장 미만에 나온 곳이 많으면 한 번만 묻는다 (덜 찍힌 곳은 화면 아래 안내가 가리킨다)
            if !warnedCoverage, let share = recorder.surfaceCoverage, share < recorder.surfaceCoverageTarget {
                warnedCoverage = true
                stopWarning = StopWarning(
                    title: "덜 찍힌 곳이 있어요",
                    message: "벽 · 바닥 중 사진 3장 이상에 나온 곳이 \(Int((share * 100).rounded()))%예요. 덜 찍힌 곳은 3D 가 흐리거나 비어요.\n"
                        + "화면 아래 안내를 따라 조금 더 찍을까요?")
                return
            }
            // 아직 전체 사진이 없고 안내도 포기하지 않은 가구가 있으면 한 번 묻는다. 안내를 오래 했는데도 안 되던 가구와
            // 이미 물어본 가구는 다시 묻지 않는다 (같은 가구를 계속 재촉하지 않는다)
            let missing = recorder.furnitureMissing
            let wideOK = recorder.furnitureNeedsWide
            if !missing.isEmpty, !Set(missing).isSubset(of: warnedMissing) {
                warnedMissing.formUnion(missing)
                if wideOK { wideOffered = true }
                let names = missing.prefix(4).joined(separator: ", ") + (missing.count > 4 ? " 외 \(missing.count - 4)개" : "")
                stopWarning = StopWarning(
                    title: "전체 사진이 없는 가구가 있어요",
                    message: "아직 전체가 한 화면에 나온 사진이 없는 가구: \(names)\n"
                        + "가구를 따로 3D 로 만들려면 가구마다 전체가 한 화면에 나온 사진이 필요해요 (다른 가구에 가려지는 건 괜찮아요). "
                        + "화면 아래 안내를 따라 조금 더 찍을까요?"
                        + (wideOK ? "\n방이 좁아 물러설 수 없었다면, 끝낸 뒤 0.5× 광각으로 한 장씩 찍을 수 있어요." : ""),
                    offersWide: wideOK)
                return
            }
            // 방이 좁아 한 화면에 다 안 들어온 가구만 남았으면 0.5× 광각 촬영을 한 번만 제안한다
            if wideOK, !wideOffered {
                wideOffered = true
                stopWarning = StopWarning(
                    title: "방이 좁아 다 못 찍은 가구가 있어요",
                    message: "물러설 곳이 없어 한 화면에 다 안 들어온 가구가 있어요. 끝낸 뒤 0.5× 광각으로 가구마다 한 장씩 찍을 수 있어요 (건너뛰어도 돼요).",
                    offersWide: true)
                return
            }
        }
        stopWarning = nil
        work = Task { await finish(recorder, wide: wide) }
    }

    /// 녹화 중 통계 반영. 새 경고가 뜨면 진동(같은 경고는 4초에 한 번) + VoiceOver 안내,
    /// 가구 전체 사진이 새로 찍히면 '성공' 진동 + "소파 전체 사진 ✓", 가구 안내 대상이 바뀌면 VoiceOver 로 읽는다
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
        if phase == .recording {
            let before = Dictionary(stats.furniture.map { ($0.id, $0.state) }, uniquingKeysWith: { a, _ in a })
            if let fresh = s.furniture.first(where: { $0.state == .done && before[$0.id] != nil && before[$0.id] != .done }) {
                haptics.notificationOccurred(.success)
                haptics.prepare()
                UIAccessibility.post(notification: .announcement, argument: "\(fresh.label) 전체 사진 ✓")
            } else if s.alert == nil, let tip = s.furnitureTip, tip.objectId != stats.furnitureTip?.objectId {
                UIAccessibility.post(notification: .announcement, argument: tip.title)
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

    private func finish(_ recorder: CaptureRecorder, wide: Bool = false) async {
        do {
            recorder.stopSampling()
            var extras: [String: Data] = [:]
            var furniture: [FurnitureBox]?
            if useRoomPlan {
                phase = .finishing("방 구조 분석 중 (RoomPlan)…")
                roomPlan.onFurniture = nil                      // 가구 점검은 아래 최종 상자로 다시 한다
                roomPlan.onWalls = nil
                roomPlan.stop()
                if let room = await roomPlan.waitForResult() {
                    extras = RoomPlanExport.files(from: room)
                    furniture = RoomPlanExport.furniture(from: room)
                } else if let msg = roomPlan.errorMessage {
                    notice = "RoomPlan 결과 없이 진행합니다: \(msg)"
                }
            }
            session.pause()

            phase = .finishing("파일 정리 중…")
            let dir = try await recorder.finalize(extraFiles: extras, roomplan: !extras.isEmpty, furniture: furniture)
            // 0.5× 광각 사진 (가구 경고에서 고른 경우): ARSession 을 멈춘 지금 광각 카메라를 연다
            if wide {
                let targets = recorder.wideShotTargets()
                if !targets.isEmpty {
                    let shots = await runWideShots(targets, in: dir)
                    try Task.checkCancellation()
                    if !shots.isEmpty {
                        try WideShotsFile.write(shots, to: dir)
                        if let info = wideCamera.cameraInfo { try recorder.addUltraWide(info) }     // meta.json 의 cameras.ultraWide
                    }
                    phase = .finishing("파일 정리 중…")
                }
            }
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
            phase = .failed("업로드 실패: \(error.userMessage)\n촬영 파일은 기기에 남아 있어 다시 시도할 수 있습니다.")
        }
    }

    private func waitJob(_ jobId: String) async throws {
        phase = .processing("업로드 완료 · AI 처리 대기 중")
        let job = try await JobAPI.wait(jobId) { [weak self] j in
            let pct = j.percent.map { " \($0)%" } ?? ""
            self?.phase = .processing("AI 처리 중 (\(j.status))\(pct)")
        }
        phase = job.isDone ? .done : .failed(job.failureMessage ?? "AI 처리에 실패했습니다")
    }

    // MARK: 0.5× 광각 사진 (촬영을 마친 뒤)

    /// 가구마다 한 장씩 (건너뛸 수 있음). 화면은 phase = .wideShot 으로 그리고, 마지막 장을 찍거나 건너뛰면 돌아온다
    private func runWideShots(_ targets: [WideShotTarget], in dir: URL) async -> [WideShotsFile.Shot] {
        wideTargets = targets
        wideShots = []
        wideDir = dir
        wideCamera.start()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            wideContinuation = cont
            showWideStep(0)
        }
        wideCamera.stop()
        return wideShots
    }

    private func showWideStep(_ i: Int) {
        guard i < wideTargets.count else { endWideShots(); return }
        wideIndex = i
        let t = wideTargets[i]
        phase = .wideShot(WideStep(index: i, total: wideTargets.count, label: t.label,
                                   alsoCount: t.alsoFor.count, problem: t.problem))
    }

    /// 셔터
    func shootWide() {
        guard case .wideShot = phase, !wideBusy, let dir = wideDir, wideIndex < wideTargets.count else { return }
        let target = wideTargets[wideIndex], index = wideIndex
        wideBusy = true
        Task {
            defer { wideBusy = false }
            do {
                let photo = try await wideCamera.capture()
                guard case .wideShot = phase, wideIndex == index else { return }
                wideShots.append(try WideShotsFile.save(photo, index: wideShots.count, target: target, in: dir))
                haptics.notificationOccurred(.success)
                haptics.prepare()
                showWideStep(index + 1)
            } catch is CancellationError {
            } catch {
                notice = "광각 사진을 찍지 못했어요: \(error.localizedDescription)"
            }
        }
    }

    func skipWide() {
        guard case .wideShot = phase, !wideBusy else { return }
        showWideStep(wideIndex + 1)
    }

    func skipAllWide() {
        guard case .wideShot = phase, !wideBusy else { return }
        endWideShots()
    }

    private func endWideShots() {
        let cont = wideContinuation
        wideContinuation = nil
        cont?.resume()
    }

    /// 업로드 실패 후 같은 zip 으로 재시도
    func retryUpload() {
        guard let dir = zipDir else { return }
        let zip = dir.deletingLastPathComponent().appendingPathComponent("capture.zip")
        work = Task {
            do {
                let progress: @Sendable (Double) -> Void = { [weak self = self] p in Task { @MainActor in self?.phase = .uploading(p) } }
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
                phase = .failed("업로드 실패: \(error.userMessage)")
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
