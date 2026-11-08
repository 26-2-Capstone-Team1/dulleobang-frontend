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
                if model.phase == .recording, let map = model.stats.coverageMap {      // 덜 찍힌 곳 미니맵 (오른쪽 위)
                    HStack {
                        Spacer()
                        CoverageMiniMap(map: map, share: model.stats.surfaceCoverage)
                    }
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
            if model.phase == .recording, model.stats.torchAvailable {     // 손전등 (어두우면 앱이 켬 · 눌러서 켜고 끔)
                Button { model.toggleTorch() } label: {
                    Image(systemName: model.stats.torchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                        .font(.headline)
                        .foregroundStyle(model.stats.torchOn ? Color.yellow : Color.primary)
                        .frame(width: 40, height: 40)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel(model.stats.torchOn ? "손전등 끄기" : "손전등 켜기")
            } else {
                Color.clear.frame(width: 40, height: 40)
            }
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

            if model.phase == .ready { PreScanChecklist(kind: model.kind) }   // 촬영 전 확인 (시작 전 화면만)
            if model.phase == .recording, let gap = model.stats.coverageGap {
                CoverageGapBanner(info: gap)                                 // 덜 찍힌 곳: 화살표 + 한 줄 (미니맵의 주황색 동그라미 쪽)
            } else {
                Text(model.phase == .ready ? readyHint : model.stats.hint)
                    .font(.callout).multilineTextAlignment(.center)
                    .padding(12).frame(maxWidth: .infinity)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }

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
                    if let ceiling = model.stats.ceilingCoverage {            // 첫 바퀴를 마친 뒤부터 (LiDAR 기기만)
                        Label("천장 \(Int((ceiling * 100).rounded()))%", systemImage: "square.tophalf.filled")
                            .foregroundStyle(model.stats.ceilingLow ? Color.orange : Color.primary)
                            .accessibilityLabel("걸어온 길 위의 천장을 찍은 곳 \(Int((ceiling * 100).rounded()))퍼센트")
                    }
                    if let surface = model.stats.surfaceCoverage {                // 벽 · 바닥 중 사진 3장 이상에 나온 곳 (RoomPlan)
                        Label("전체 \(Int((surface * 100).rounded()))%", systemImage: "square.grid.3x3")
                            .foregroundStyle(model.stats.surfaceLow ? Color.orange : Color.primary)
                            .accessibilityLabel("벽과 바닥 중 사진 세 장 이상에 나온 곳 \(Int((surface * 100).rounded()))퍼센트")
                    }
                    Circle().fill(trackingColor).frame(width: 10, height: 10)
                }
                .font(.caption.monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.75)                         // 항목이 늘어도 좁은 화면에서 줄바꿈 없이 줄어들게
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
                ? "방을 천천히 한 바퀴 걸으며 찍어 주세요. 나머지는 화면 안내를 따르면 돼요.\n"
                    + "가구는 하나씩 전체가 한 화면에 들어오게도 찍어 주세요 (위 목록이 ✓ 로 바뀌어요)"
                : "방을 천천히 한 바퀴 걸으며 찍어 주세요.\n창문·문·구석이 모두 보이게, 나머지는 화면 안내를 따르면 돼요."
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
                Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(DB.accent)
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

/// 화면 위 가구 목록: RoomPlan 이 찾은 가구마다 전체 사진 여부. 초록 ✓ = 전체 사진 있음 (뒤의 숫자 = 서로 다른 방향 수), 민트 ✓ = 같은 모양 가구의 사진으로 대신, 회색 = 아직
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
                        if chip.state == .done, chip.views > 0 {
                            Text("\(chip.views)방향").font(.caption2.weight(.bold).monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .opacity(chip.state == .pending ? 0.8 : 1)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(chip.label), \(spoken(chip.state))"
                        + (chip.state == .done && chip.views > 0 ? ", \(chip.views)방향에서 찍음" : ""))
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

/// 첫 바퀴 뒤 '아직 전체 사진이 없는 가구' 안내 띠 (초록). 촬영 경고 띠가 떠 있으면 경고가 먼저다
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
        .background(DB.accent.opacity(0.92), in: RoundedRectangle(cornerRadius: 14))
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
        "벽 쪽으로 최대한 물러나 \(Josa.eulReul(step.label)) 화면 가운데에 두고, 전체가 다 들어오게 찍어 주세요"
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
                .background(DB.accent.opacity(0.92), in: RoundedRectangle(cornerRadius: 14))
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

/// 촬영 전 확인 (시작 전 화면에만). 찍는 사람에게는 두세 가지만 부탁하고 나머지(초점 · 저장 · 흔들림 · 덜 찍힌 곳)는 앱 · 서버가 맡는다 (AI 팀과 합의)
struct PreScanChecklist: View {
    struct Item: Identifiable {
        let icon: String
        let text: String
        var id: String { text }
    }

    let kind: CaptureKind

    static func items(for kind: CaptureKind) -> [Item] {
        switch kind {
        case .room:
            return [Item(icon: "figure.walk", text: "방 전체를 천천히 한 바퀴 · 욕실 · 주방 같은 좁은 곳도 한 번씩 들어가기"),
                    Item(icon: "person.fill.xmark", text: "다른 사람은 화면 밖으로"),
                    Item(icon: "lightbulb.fill", text: "(가능하면) 불 켜기")]
        case .furniture:
            return [Item(icon: "figure.walk", text: "가구 주위를 천천히 한 바퀴"),
                    Item(icon: "person.fill.xmark", text: "사람 · 물건이 가구 앞을 가리지 않게"),
                    Item(icon: "lightbulb.fill", text: "(가능하면) 불 켜기")]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("촬영 전 확인").font(.caption.weight(.semibold))
            ForEach(Self.items(for: kind)) { item in
                Label(item.text, systemImage: item.icon).font(.caption)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

/// 덜 찍힌 곳 미니맵 (방 촬영 · RoomPlan): 벽을 초록(사진 3장 이상) · 노랑 · 주황(덜 찍힘)으로, 파란 점 = 내 위치(위쪽이 바라보는 방향),
/// 주황 동그라미 = 지금 안내하는 가장 덜 찍힌 곳. 바라보는 방향이 위로 오게 돌려 '오른쪽 벽' 안내와 화면 방향이 같다 (magicplan 의 초록/주황 벽 참고)
private struct CoverageMiniMap: View {
    let map: CoverageMap
    let share: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("촬영 지도").font(.caption2.weight(.bold))
                Spacer(minLength: 4)
                if let share {
                    Text("\(Int((share * 100).rounded()))%").font(.caption2.weight(.bold).monospacedDigit())
                }
            }
            Canvas { context, size in draw(&context, size: size) }
                .frame(width: 124, height: 124)
        }
        .padding(8)
        .frame(width: 140)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
    }

    private var spokenLabel: String {
        var text = "촬영 지도"
        if let share { text += ", 벽과 바닥 \(Int((share * 100).rounded()))퍼센트 찍힘" }
        if map.gap != nil { text += ", 주황색 동그라미 쪽이 덜 찍힌 곳" }
        return text
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize) {
        let project = map.projector(size: size, padding: 10)
        if map.floor.count >= 3 {
            var floor = Path()
            floor.addLines(map.floor.map(project))
            floor.closeSubpath()
            context.fill(floor, with: .color(.white.opacity(0.12)))
        }
        for point in map.floorGaps {
            let c = project(point)
            context.fill(Path(ellipseIn: CGRect(x: c.x - 1.5, y: c.y - 1.5, width: 3, height: 3)), with: .color(.orange))
        }
        for piece in map.pieces {
            var line = Path()
            line.move(to: project(piece.a))
            line.addLine(to: project(piece.b))
            let color: Color = piece.covered >= 0.8 ? .green : (piece.covered >= 0.4 ? .yellow : .orange)
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 4, lineCap: .round))
        }
        let me = project(map.camera)
        if let gap = map.gap {
            let g = project(gap)
            var path = Path()
            path.move(to: me)
            path.addLine(to: g)
            context.stroke(path, with: .color(.white.opacity(0.8)), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            context.stroke(Path(ellipseIn: CGRect(x: g.x - 8, y: g.y - 8, width: 16, height: 16)), with: .color(.orange), lineWidth: 2.5)
        }
        var cone = Path()                                                   // 바라보는 방향 (지도에서는 늘 위쪽)
        cone.addLines([me, CGPoint(x: me.x - 11, y: me.y - 22), CGPoint(x: me.x + 11, y: me.y - 22)])
        cone.closeSubpath()
        context.fill(cone, with: .color(.blue.opacity(0.35)))
        let dot = Path(ellipseIn: CGRect(x: me.x - 5, y: me.y - 5, width: 10, height: 10))
        context.fill(dot, with: .color(.blue))
        context.stroke(dot, with: .color(.white), lineWidth: 2)
    }
}

/// 덜 찍힌 곳 안내: 가야 할 쪽을 가리키는 화살표 + 한 줄 (미니맵의 주황색 동그라미 쪽, Object Capture 의 화살표 참고)
private struct CoverageGapBanner: View {
    let info: CoverageGapInfo

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: info.near ? "arrow.down.to.line" : "arrow.up")   // 발밑이면 '아래로 기울이기'
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .rotationEffect(.degrees(info.near ? 0 : info.bearingDeg))
                .frame(width: 44, height: 44)
                .background(Color.orange, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(info.title).font(.headline)
                Text(info.detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }
}
