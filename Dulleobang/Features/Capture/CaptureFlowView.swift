import AVFoundation
import SwiftUI

/// 전체 화면 촬영 UI. 방(중개사) / 가구(임차인) / 오프라인(zip 만들기) / 매물 등록용(촬영본만 돌려줌) 공용.
struct CaptureFlowView: View {
    @StateObject private var model: CaptureFlowModel
    private let onFinish: () -> Void
    private let onCaptured: ((CapturedSpace) -> Void)?
    @Environment(\.dismiss) private var dismiss

    init(target: CaptureFlowModel.Target, onFinish: @escaping () -> Void = {},
         onCaptured: ((CapturedSpace) -> Void)? = nil) {
        _model = StateObject(wrappedValue: CaptureFlowModel(target: target))
        self.onFinish = onFinish
        self.onCaptured = onCaptured
    }

    var body: some View {
        ZStack {
            camera.ignoresSafeArea()

            if case .wideShot(let step) = model.phase {               // 촬영을 마친 뒤 0.5× 광각 사진 (RoomPlan 화면 위에 덮음)
                WideShotScreen(step: step, session: model.wideCamera.session, busy: model.wideBusy,
                               onShoot: { model.shootWide() }, onSkip: { model.skipWide() },
                               onSkipAll: { model.skipAllWide() })
            }

            VStack(spacing: 12) {
                topBar
                if model.phase == .recording, !model.stats.furniture.isEmpty {
                    FurnitureChecklist(chips: model.stats.furniture)
                }
                Spacer()
                if model.phase == .ready || model.phase == .recording { controls }
            }
            .padding()
            .alert(model.stopWarning?.title ?? "",
                   isPresented: Binding(get: { model.stopWarning != nil }, set: { if !$0 { model.stopWarning = nil } })) {
                Button("더 찍기", role: .cancel) {}
                if model.stopWarning?.offersWide == true {
                    Button("끝내고 0.5× 광각으로 찍기") { model.stop(force: true, wide: true) }
                }
                Button("그대로 끝내기") { model.stop(force: true) }
            } message: {
                Text(model.stopWarning?.message ?? "")
            }

            if let card = statusCard { card }
        }
        .onAppear { model.appear() }
        .onDisappear { model.disappear() }
        .statusBarHidden()
        .alert(model.notice ?? "", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("확인", role: .cancel) {}
        }
    }

    @ViewBuilder private var camera: some View {
        if model.useRoomPlan {
            RoomPlanCaptureView(session: model.session, controller: model.roomPlan)
        } else {
            ARCameraView(session: model.session)
        }
    }

    private var title: String {
        if case .wideShot = model.phase { return "0.5× 광각 사진" }
        switch model.target {
        case .listing: return model.useRoomPlan ? "방 촬영 · RoomPlan" : "방 촬영"
        case .furniture: return "가구 촬영"
        case .localOnly(let k): return k == .room ? "오프라인 방 촬영" : "오프라인 가구 촬영"
        case .deferred(let k): return k == .room ? (model.useRoomPlan ? "공간 촬영 · RoomPlan" : "공간 촬영") : "가구 촬영"
        }
    }

    private var topBar: some View {
        HStack {
            Button { close() } label: {
                Image(systemName: "xmark").font(.headline).padding(10).background(.ultraThinMaterial, in: Circle())
            }
            Spacer()
            Text(title).font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 6).background(.ultraThinMaterial, in: Capsule())
            Spacer()
            Color.clear.frame(width: 40, height: 40)
        }
    }

    private var controls: some View {
        VStack(spacing: 14) {
            if model.phase == .recording, let alert = model.stats.alert {
                CaptureAlertBanner(alert: alert)
                    .id(alert)                                            // 종류가 바뀌면 다시 나타나는 애니메이션
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if model.phase == .recording, let tip = model.stats.furnitureTip {
                FurnitureTipBanner(tip: tip)                              // 경고가 없을 때만: 아직 전체 사진이 없는 가구
                    .id(tip.objectId)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            Text(model.phase == .ready ? readyHint : model.stats.hint)
                .font(.callout).multilineTextAlignment(.center)
                .padding(12).frame(maxWidth: .infinity)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

            if model.phase == .recording {
                HStack(spacing: 16) {
                    Label("\(model.stats.kept)장", systemImage: "photo.stack")
                    Label(String(format: "%.1f m", model.stats.spanM), systemImage: "figure.walk")
                        .accessibilityLabel("이동 범위 \(String(format: "%.1f", model.stats.spanM)) 미터")
                    if let floor = model.stats.floorCoverage {
                        Label("바닥 \(Int((floor * 100).rounded()))%", systemImage: "square.bottomhalf.filled")
                            .foregroundStyle(floor < CaptureCoach.Config().floorAlertBelow ? Color.orange : Color.primary)
                            .accessibilityLabel("걸어온 길 중 바닥을 찍은 곳 \(Int((floor * 100).rounded()))퍼센트")
                    } else {
                        Label(model.stats.hasDepth ? "깊이 ✓" : "깊이 없음", systemImage: "sensor.tag.radiowaves.forward")
                    }
                    Circle().fill(trackingColor).frame(width: 10, height: 10)
                }
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
            }

            ZStack {
                Circle().stroke(.white.opacity(0.25), lineWidth: 6)
                Circle().trim(from: 0, to: model.stats.coverage)
                    .stroke(.green, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Button {
                    model.phase == .ready ? model.start() : model.stop()
                } label: {
                    Group {
                        if model.phase == .ready { Circle().fill(.red) }
                        else { RoundedRectangle(cornerRadius: 6).fill(.red).padding(14) }
                    }
                    .frame(width: 62, height: 62)
                }
                .accessibilityLabel(model.phase == .ready ? "촬영 시작" : "촬영 종료")
            }
            .frame(width: 84, height: 84)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.stats.alert)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.stats.furnitureTip)
    }

    private var readyHint: String {
        switch model.kind {
        case .room:
            return model.useRoomPlan
                ? "방 입구에서 시작해 벽을 따라 걸으면서 천천히 한 바퀴 돈 뒤,\n폰을 아래로 기울여 바닥이 보이게 한 바퀴 더 도세요. 다른 사람은 잠시 방 밖으로!\n"
                    + "가구는 하나씩 전체가 한 화면에 들어오게도 찍어 주세요 (위 목록이 ✓ 로 바뀌어요)"
                : "방 입구에서 시작해 벽을 따라 걸으면서 천천히 한 바퀴 도세요.\n창문·문·구석이 모두 보이게 찍고, 제자리에서 돌리기만 하지는 마세요."
        case .furniture:
            return "가구 전체가 화면에 들어오게 1~2 m 떨어져서\n가구 주위를 천천히 한 바퀴 도세요."
        }
    }

    private var trackingColor: Color {
        switch model.stats.tracking {
        case .normal: return .green
        case .limited: return .yellow
        case .none: return .red
        }
    }

    private var statusCard: AnyView? {
        let content: AnyView
        switch model.phase {
        case .ready, .recording, .wideShot:
            return nil
        case .finishing(let msg):
            content = AnyView(VStack(spacing: 12) { ProgressView(); Text(msg) })
        case .uploading(let p):
            content = AnyView(VStack(spacing: 12) {
                Text("업로드 중")
                ProgressView(value: p).frame(width: 220)
                Text("\(Int(p * 100))%").font(.caption.monospacedDigit())
            })
        case .processing(let msg):
            content = AnyView(VStack(spacing: 12) {
                ProgressView()
                Text(msg).multilineTextAlignment(.center)
                Text("3D 생성에는 몇 분 이상 걸릴 수 있습니다.\n닫아도 서버에서 계속 처리됩니다.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("닫기") { close() }.buttonStyle(.bordered)
            })
        case .done:
            content = AnyView(VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(.green)
                Text(model.kind == .room ? "3D 공간이 준비되었습니다" : "3D 가구가 준비되었습니다")
                Button("완료") { close() }.buttonStyle(.borderedProminent)
            })
        case .captured(let c):
            content = AnyView(VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(DB.purple)
                Text("촬영을 마쳤습니다").font(.headline)
                Text("\(c.frameCount)장 · \(String(format: "%.0f", c.sizeMB)) MB\n깊이 \(c.hasDepth ? "✓" : "없음") · 방 구조 \(c.hasRoomPlan ? "✓" : "없음")")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("이 촬영본 사용") {
                    onCaptured?(c)
                    dismiss()
                }
                .buttonStyle(.dbPrimary)
                Button("다시 촬영") { model.retry() }.buttonStyle(.bordered)
            })
        case .share(let url):
            content = AnyView(VStack(spacing: 12) {
                Image(systemName: "doc.zipper").font(.largeTitle)
                Text("capture.zip 생성 완료 · \(String(format: "%.0f", CapturePackager.sizeMB(url))) MB")
                Text("AirDrop 으로 노트북에 보내 AI 팀원에게 전달하세요.\n파일 앱 › 나의 iPhone › 둘러방 › captures 에도 남아 있습니다.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                ShareLink(item: url) { Label("공유 / AirDrop", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.borderedProminent)
                Button("닫기") { close() }
            })
        case .failed(let msg):
            content = AnyView(VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.orange)
                Text(msg).multilineTextAlignment(.center)
                HStack {
                    if model.canRetryUpload { Button("업로드 재시도") { model.retryUpload() }.buttonStyle(.borderedProminent) }
                    Button("다시 촬영") { model.retry() }.buttonStyle(.bordered)
                    Button("닫기") { close() }
                }
            })
        }
        return AnyView(
            ZStack {
                Color.black.opacity(0.55).ignoresSafeArea()
                content.padding(24).frame(maxWidth: 340)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        )
    }

    private func close() {
        let finished: Bool
        switch model.phase {
        case .done, .processing: finished = true
        case .captured: model.discardCaptured(); finished = false     // 사용하지 않고 닫으면 촬영본 삭제
        default: finished = false
        }
        dismiss()
        if finished { onFinish() }
    }
}

/// 촬영 중 경고 띠. 빨강 = 지금 찍히는 사진이 망가지는 중(흔들림 · 추적 끊김), 주황 = 결과가 나빠지는 촬영 습관
private struct CaptureAlertBanner: View {
    let alert: CaptureAlert

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: alert.icon)
                .font(.title2.weight(.semibold))
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(alert.title).font(.headline)
                Text(alert.detail).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(14)
        .frame(maxWidth: .infinity)
        .background((alert.isSevere ? Color.red : Color.orange).opacity(0.92), in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        .accessibilityElement(children: .combine)
    }
}

/// 화면 위 가구 목록: RoomPlan 이 찾은 가구마다 전체 사진 여부. 초록 ✓ = 전체 사진 있음, 민트 ✓ = 같은 모양 가구의 사진으로 대신, 회색 = 아직
private struct FurnitureChecklist: View {
    let chips: [FurnitureChip]

    var body: some View {
        let done = chips.filter { $0.state != .pending }.count
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Text("가구 \(done)/\(chips.count)")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(done == chips.count ? Color.green.opacity(0.85) : Color.black.opacity(0.45), in: Capsule())
                    .accessibilityLabel("가구 \(chips.count)개 중 \(done)개 전체 사진 있음")
                ForEach(chips) { chip in
                    HStack(spacing: 4) {
                        Image(systemName: chip.symbol)
                        Text(chip.label)
                        Image(systemName: icon(chip.state)).foregroundStyle(color(chip.state))
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .opacity(chip.state == .pending ? 0.8 : 1)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(chip.label), \(spoken(chip.state))")
                }
            }
            .padding(.horizontal, 2)
        }
        .animation(.easeInOut(duration: 0.25), value: chips)
    }

    private func icon(_ s: FurnitureShotState) -> String {
        switch s {
        case .done: return "checkmark.circle.fill"
        case .shared: return "checkmark.circle"
        case .pending: return "circle.dashed"
        }
    }

    private func color(_ s: FurnitureShotState) -> Color {
        switch s {
        case .done: return .green
        case .shared: return .mint
        case .pending: return .secondary
        }
    }

    private func spoken(_ s: FurnitureShotState) -> String {
        switch s {
        case .done: return "전체 사진 있음"
        case .shared: return "같은 모양 가구의 사진으로 대신"
        case .pending: return "아직 전체 사진 없음"
        }
    }
}

/// 첫 바퀴 뒤 '아직 전체 사진이 없는 가구' 안내 띠 (보라). 촬영 경고 띠가 떠 있으면 경고가 먼저다
private struct FurnitureTipBanner: View {
    let tip: FurnitureTip

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: tip.icon)
                .font(.title2.weight(.semibold))
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(tip.title).font(.headline)
                Text(tip.detail).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(DB.purple.opacity(0.92), in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        .accessibilityElement(children: .combine)
    }
}

/// 촬영을 마친 뒤 0.5× 광각 사진 화면: 가구 하나씩 전체가 들어오게 찍는다 (ARSession 은 멈춘 상태라 포즈 · 깊이는 없음)
private struct WideShotScreen: View {
    let step: CaptureFlowModel.WideStep
    let session: AVCaptureSession
    let busy: Bool
    let onShoot: () -> Void
    let onSkip: () -> Void
    let onSkipAll: () -> Void

    private var guide: String {
        step.problem == ShotCheck.Problem.blocked.rawValue
            ? "가리는 것이 없는 쪽으로 가까이 가서, \(step.label) 전체가 화면 안에 들어오게 찍어 주세요"
            : "벽 쪽으로 최대한 물러나 \(Josa.eulReul(step.label)) 화면 가운데에 두고, 전체가 다 들어오게 찍어 주세요"
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            UltraWidePreview(session: session).ignoresSafeArea()
            VStack(spacing: 14) {
                VStack(spacing: 4) {
                    Text("0.5× 광각 \(step.index + 1)/\(step.total)").font(.caption.weight(.bold).monospacedDigit())
                    Text(step.alsoCount > 0 ? "\(step.label) (같은 모양 \(step.alsoCount)개도 이 사진으로)" : step.label)
                        .font(.headline)
                    Text(guide).font(.subheadline).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(.white)
                .padding(14)
                .frame(maxWidth: .infinity)
                .background(DB.purple.opacity(0.92), in: RoundedRectangle(cornerRadius: 14))
                .padding(.top, 56)                                        // 위쪽 닫기 버튼 · 제목 아래
                Spacer()
                HStack {
                    Button("모두 건너뛰기", action: onSkipAll)
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 96)
                    Spacer()
                    Button(action: onShoot) {
                        ZStack {
                            Circle().stroke(.white, lineWidth: 5).frame(width: 78, height: 78)
                            Circle().fill(busy ? Color.gray : Color.white).frame(width: 64, height: 64)
                        }
                    }
                    .disabled(busy)
                    .accessibilityLabel("광각 사진 찍기")
                    Spacer()
                    Button("건너뛰기", action: onSkip)
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 96)
                }
                .foregroundStyle(.white)
                .padding(.bottom, 24)
            }
            .padding(.horizontal)
        }
    }
}
