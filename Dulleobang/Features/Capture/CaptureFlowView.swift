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

            VStack(spacing: 12) {
                topBar
                Spacer()
                if model.phase == .ready || model.phase == .recording { controls }
            }
            .padding()
            .alert(model.stopWarning?.title ?? "",
                   isPresented: Binding(get: { model.stopWarning != nil }, set: { if !$0 { model.stopWarning = nil } })) {
                Button("더 찍기", role: .cancel) {}
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
    }

    private var readyHint: String {
        switch model.kind {
        case .room:
            return model.useRoomPlan
                ? "방 입구에서 시작해 벽을 따라 걸으면서 천천히 한 바퀴 돈 뒤,\n폰을 아래로 기울여 바닥이 보이게 한 바퀴 더 도세요. 다른 사람은 잠시 방 밖으로!"
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
        case .ready, .recording:
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
