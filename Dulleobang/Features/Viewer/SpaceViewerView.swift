import SwiftUI

/// 3D 뷰어를 여는 정보 (매물 상세 · 비교 결과에서 전체 화면으로 띄운다)
struct ViewerRoute: Identifiable {
    let id = UUID()
    var listingId: String
    var title: String                     // "월세 500/31"
    var subtitle: String                  // "동작구 상도동"
    var roomStateId: String? = nil        // 내 입주 상태로 열기
    var knownRoomStateId: String? = nil   // 이미 알고 있는 내 입주 상태 (현재 모습으로 열되 "입주 예상 보기"를 바로 보여 준다)
    var openFurnitureTray = false
    var openRemoval = false               // 열자마자 "가구 빼 보기"
    var initialPlacements: [Placement]? = nil
    var startInPlan = false               // 평면(위에서 내려다보기)으로 열기 (상세의 '평면도')
}

extension ViewerRoute {
    init(listing l: Listing, roomStateId: String? = nil, knownRoomStateId: String? = nil, openFurnitureTray: Bool = false,
         openRemoval: Bool = false, initialPlacements: [Placement]? = nil) {
        self.init(listingId: l.listingId, title: Fmt.price(l), subtitle: Fmt.shortLocation(l.location),
                  roomStateId: roomStateId, knownRoomStateId: knownRoomStateId, openFurnitureTray: openFurnitureTray,
                  openRemoval: openRemoval, initialPlacements: initialPlacements)
    }
}

/// 매물 3D 탐색 (데모 "임차인의 매물 보기" 3번째 화면: 검정 헤더 · 시점 초기화) + 아래 [둘러보기 | 평면] · [지금 모습 | 입주 예상 AI] · 이름 붙은 도구 칸
/// + 둘러방 기능: 치수 오버레이 · 가구 빼 보기(나만 보는 입주 상태) · 입주 예상 전환 · 내 가구 배치/충돌 확인/저장
/// + (매물을 올린 중개사) 가구 구분
struct SpaceViewerView: View {
    @StateObject private var model: SpaceViewerModel
    private let route: ViewerRoute
    private let isBroker: Bool
    @State private var myRoomStateId: String?
    @State private var showFurniturePicker: Bool
    @State private var showOwnership = false
    @State private var showRemoval = false
    @AppStorage("viewerGestureHintShown") private var gestureHintShown = false   // 처음 한 번만 확대 · 축소 방법 안내
    @Environment(\.dismiss) private var dismiss

    init(route: ViewerRoute, isBroker: Bool = false) {
        _model = StateObject(wrappedValue: SpaceViewerModel(
            listingId: route.listingId,
            state: route.roomStateId.map { SpaceViewerModel.RoomStateKind.movein($0) } ?? .current,
            initialPlacements: route.initialPlacements))
        _showFurniturePicker = State(initialValue: route.openFurnitureTray)
        _myRoomStateId = State(initialValue: route.roomStateId ?? route.knownRoomStateId)
        self.route = route
        self.isBroker = isBroker
    }

    /// 뺄 수 있는 가구(중개사가 개인 가구로 정한 것)가 있는가
    private var canRemoveAny: Bool { model.objects.contains(where: \.canRemove) }

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                ViewerWebView(controller: model.viewer)
                VStack(spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        if model.overlay && !model.dimensionsText.isEmpty {
                            Text(model.dimensionsText)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(Color.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.black.opacity(0.55), in: Capsule())
                        }
                        Spacer(minLength: 0)
                        if model.isMovein { aiBadge }           // 가구를 뺀 모습은 AI 가 만든 예상이라고 밝힌다
                    }
                    Spacer()
                    if let item = model.selected { selectedCard(item) }
                    if !model.placed.isEmpty {
                        HStack {
                            placementPill
                            Spacer()
                        }
                    }
                    modeSwitch
                }
                .padding(12)
                if let msg = model.loading { loadingCard(msg) }
            }
            bottomPanel
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .task {
            if route.startInPlan { model.mode = .overview }     // 상세의 '평면도' 로 열었으면 위에서 내려다보기부터
            await model.load()
            if !gestureHintShown && model.mode == .walk {
                gestureHintShown = true
                model.toast = "두 손가락으로 오므리면 넓게 보여요"
            }
            if myRoomStateId == nil {           // 전에 만들어 둔 내 입주 상태가 있으면 "입주 예상 보기"로 바로 갈 수 있게
                myRoomStateId = await RoomStateAPI.latestReady(listingId: model.listingId,
                                                               spaceVersion: model.spaceVersion)?.roomStateId
            }
            if route.openRemoval && canRemoveAny && !showFurniturePicker { showRemoval = true }
        }
        .onChange(of: model.unavailableRoomStateId) { _, dead in
            // 열 수 없는 입주 상태(실패 · 삭제됨)면 버튼 대상을 다시 찾는다
            guard let dead, dead == myRoomStateId else { return }
            myRoomStateId = nil
            Task {
                myRoomStateId = await RoomStateAPI.latestReady(listingId: model.listingId,
                                                               spaceVersion: model.spaceVersion)?.roomStateId
            }
        }
        .sheet(isPresented: $showFurniturePicker) {
            FurniturePickerSheet(placedIds: Set(model.placed.map(\.id))) { f in
                Task { await model.addFurniture(f) }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showOwnership, onDismiss: { model.restoreOwnershipColors() }) {
            ObjectOwnershipView(listingId: model.listingId, objects: model.objects, objectsVersion: model.objectsVersion,
                                onPreview: { id, type in model.previewOwnership(id, type) },
                                onSaved: {
                                    model.toast = "가구 구분을 저장했습니다"
                                    Task { await model.refreshSpaceInfo() }
                                },
                                onStale: { message in
                                    model.toast = message
                                    Task { await model.refreshSpaceInfo() }
                                })
        }
        .sheet(isPresented: $showRemoval) {
            RoomStateCreateView(listingId: model.listingId, objects: model.objects,
                                spaceVersion: model.spaceVersion, objectsVersion: model.objectsVersion,
                                onPreview: { ids in model.previewRemoval(ids) },
                                onCreated: { rsId in myRoomStateId = rsId },      // 닫아도 "입주 예상 보기"로 이어서 볼 수 있게
                                onReady: { rsId in
                                    myRoomStateId = rsId
                                    Task { await model.showRoomState(rsId) }
                                },
                                onStale: { message in
                                    model.toast = message
                                    Task { await model.refreshSpaceInfo() }
                                })
            .presentationDetents([.medium, .large])
        }
        .errorAlert($model.error)
        .confirmationDialog("이미 저장된 배치가 있어요", isPresented: $model.confirmOverwrite, titleVisibility: .visible) {
            Button("지금 배치로 덮어쓰기", role: .destructive) { Task { await model.save(overwrite: true) } }
            Button("취소", role: .cancel) {}
        } message: {
            Text("다른 기기나 예전에 저장한 배치입니다. 덮어쓰면 그 배치는 사라집니다.")
        }
        .overlay(alignment: .top) {
            if let t = model.toast {
                ToastView(text: t)
                    .padding(.top, 60)
                    .task(id: t) {
                        try? await Task.sleep(for: .seconds(2))
                        if model.toast == t { model.toast = nil }
                    }
            }
        }
    }

    // MARK: - 헤더 · 하단 바

    private var header: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: 38, height: 38)
                    .background(Color.white.opacity(0.14), in: Circle())
            }
            .accessibilityLabel("닫기")
            VStack(alignment: .leading, spacing: 2) {
                if !route.subtitle.isEmpty {
                    Text(route.subtitle).font(.caption2).foregroundStyle(Color.white.opacity(0.7))
                }
                Text(route.title + (model.isMovein ? " · 입주 예상" : ""))
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button { model.resetView() } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: 38, height: 38)
                    .background(Color.white.opacity(0.14), in: Circle())
            }
            .accessibilityLabel("시점 초기화")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.black)
    }

    /// 아래 판: [지금 모습 | 입주 예상 AI] (입주 예상이 있을 때) + 이름 붙은 도구 칸 (중개사는 '가구 구분' 한 칸 더)
    private var bottomPanel: some View {
        VStack(spacing: 12) {
            if myRoomStateId != nil || model.isMovein { stateSwitch }
            HStack(spacing: 0) {
                tool("치수", icon: "ruler", on: model.overlay) { model.overlay.toggle() }
                tool("가구 빼기", icon: "sparkles", enabled: canRemoveAny && model.loading == nil) { showRemoval = true }
                tool("내 가구", icon: "sofa") { showFurniturePicker = true }
                tool("저장", icon: "square.and.arrow.down", enabled: !model.placed.isEmpty) { Task { await model.save() } }
                if isBroker && !model.objects.isEmpty {
                    tool("가구 구분", icon: "tag") { showOwnership = true }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .background(Color(white: 0.07))
    }

    /// 지금 모습 ↔ 입주 예상 (내가 가구를 빼서 만든 모습 · AI 생성)
    private var stateSwitch: some View {
        HStack(spacing: 0) {
            stateButton("지금 모습", on: !model.isMovein) { Task { await model.showCurrent() } }
            stateButton("입주 예상", ai: true, on: model.isMovein) {
                Task { if let id = myRoomStateId { await model.showRoomState(id) } }
            }
        }
        .padding(3)
        .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .disabled(model.loading != nil)                 // 불러오는 중에 또 누르지 않게
    }

    private func stateButton(_ title: String, ai: Bool = false, on: Bool, action: @escaping () -> Void) -> some View {
        Button { if !on { action() } } label: {
            HStack(spacing: 4) {
                Text(title)
                if ai {
                    HStack(spacing: 1) {
                        Image(systemName: "sparkles")
                        Text("AI")
                    }
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(DB.accent, in: Capsule())
                }
            }
            .font(.subheadline.weight(.bold))
            .foregroundStyle(on ? DB.ink : Color.white.opacity(0.75))
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background(on ? Color.white : Color.clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// 이름이 붙은 도구 칸 (처음 보는 사람도 알 수 있게). on = 켜져 있음(초록)
    private func tool(_ title: String, icon: String, on: Bool = false, enabled: Bool = true,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 46, height: 46)
                    .background(on ? DB.accent : Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                Text(title).font(.caption2.weight(.semibold)).lineLimit(1)
            }
            .foregroundStyle(Color.white)
            .frame(maxWidth: .infinity)
            .opacity(enabled ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// 3D 화면 아래 가운데: [둘러보기 | 평면] (1인칭 ↔ 위에서 내려다보기)
    private var modeSwitch: some View {
        HStack(spacing: 0) {
            modeButton("둘러보기", .walk)
            modeButton("평면", .overview)
        }
        .padding(3)
        .background(Color.black.opacity(0.6), in: Capsule())
    }

    private func modeButton(_ title: String, _ m: ViewMode) -> some View {
        let on = model.mode == m
        return Button { model.mode = m } label: {
            Text(title)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(on ? DB.ink : Color.white.opacity(0.8))
                .padding(.horizontal, 18)
                .padding(.vertical, 7)
                .background(on ? Color.white : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// 입주 예상(가구를 뺀 모습)일 때: AI 가 만든 모습임을 밝힌다
    private var aiBadge: some View {
        Label("AI로 만든 예상 모습", systemImage: "sparkles")
            .font(.caption.weight(.bold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(DB.accent.opacity(0.9), in: Capsule())
    }

    /// 배치한 내 가구 결과 한 줄
    private var placementPill: some View {
        let bad = model.placed.filter { !$0.ok }.count
        return Label(bad == 0 ? "내 가구 \(model.placed.count)개 · 모두 들어가요" : "\(bad)개가 벽이나 가구에 부딪혀요",
                     systemImage: bad == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .font(.caption.weight(.bold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background((bad == 0 ? Color.green : Color.red).opacity(0.85), in: Capsule())
    }


    // MARK: - 카드

    private func selectedCard(_ item: PlacedItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(item.ok ? Color.green : Color.red)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.furniture.label).font(.subheadline.weight(.semibold))
                Text(model.describe(item)).font(.caption).foregroundStyle(item.ok ? Color.green : Color.red)
                Text(Fmt.dims(item.dims) + " · 끌어서 옮기기").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.rotateSelected(by: -15) } label: { Image(systemName: "rotate.left") }
                .accessibilityLabel("왼쪽으로 15° 회전")
            Button { model.rotateSelected(by: 15) } label: { Image(systemName: "rotate.right") }
                .accessibilityLabel("오른쪽으로 15° 회전")
            Button(role: .destructive) { model.removeSelected() } label: { Image(systemName: "trash") }
                .accessibilityLabel("빼기")
        }
        .buttonStyle(.bordered)
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func loadingCard(_ msg: String) -> some View {
        VStack(spacing: 10) {
            if let p = model.progress { ProgressView(value: p).frame(width: 200) } else { ProgressView() }
            Text(msg).font(.callout)
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

/// 내 가구 목록에서 하나 골라 배치
struct FurniturePickerSheet: View {
    let placedIds: Set<String>
    let onPick: (Furniture) -> Void
    @State private var items: [Furniture] = []
    @State private var error: String?
    @State private var loading = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if !loading && items.isEmpty {
                    Text("등록된 가구가 없습니다. 마이페이지 › 내 가구에서 먼저 가구를 촬영해 주세요.")
                        .foregroundStyle(.secondary)
                }
                ForEach(items) { f in
                    Button {
                        onPick(f)
                        dismiss()
                    } label: {
                        HStack {
                            FurnitureRow(furniture: f)
                            if placedIds.contains(f.furnitureId) {
                                Text("배치됨").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(!f.isReady || placedIds.contains(f.furnitureId))
                }
            }
            .navigationTitle("내 가구 불러오기")
            .navigationBarTitleDisplayMode(.inline)
            .overlay { if loading { ProgressView() } }
            .task {
                do { items = try await FurnitureAPI.mine() } catch { self.error = error.userMessage }
                loading = false
            }
            .errorAlert($error)
        }
    }
}

// MARK: - 3D 파일 하나 열어 보기 (설정 › 3D 뷰어 시험)

struct MeshPreviewItem: Identifiable {
    let id = UUID()
    let name: String            // 파일 이름 (화면 위에 보여 준다)
    let viewerURL: String       // AssetCache.importLocal 이 돌려준 dulleobang://app/assets/… 주소
}

/// 방 구조(roomGeometry) 없이 3D 파일 하나만 연다. AI 팀이 만든 room.glb 가 폰에서 열리는지, 어떻게 보이는지
/// 서버 없이 확인하는 용도. 바닥 · 천장 · 걸을 수 있는 범위는 뷰어가 메시 크기에서 잡아 알려 준다(bounds)
struct MeshPreviewView: View {
    let item: MeshPreviewItem
    @StateObject private var viewer = ViewerController()
    @State private var mode: ViewMode = .walk
    @State private var loading: String? = "3D 뷰어 준비 중"
    @State private var progress: Double?
    @State private var sizeText = ""
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .frame(width: 38, height: 38)
                        .background(Color.white.opacity(0.14), in: Circle())
                }
                .accessibilityLabel("닫기")
                VStack(alignment: .leading, spacing: 2) {
                    Text("3D 파일 열어 보기").font(.caption2).foregroundStyle(Color.white.opacity(0.7))
                    Text(item.name).font(.headline.weight(.bold)).foregroundStyle(Color.white).lineLimit(1)
                }
                Spacer(minLength: 4)
                Button { viewer.call("resetView") } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .frame(width: 38, height: 38)
                        .background(Color.white.opacity(0.14), in: Circle())
                }
                .accessibilityLabel("시점 초기화")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.black)
            ZStack {
                ViewerWebView(controller: viewer)
                VStack(spacing: 8) {
                    HStack {
                        if !sizeText.isEmpty {
                            Text(sizeText)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(Color.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.black.opacity(0.55), in: Capsule())
                        }
                        Spacer(minLength: 0)
                    }
                    Spacer()
                    Picker("보기", selection: $mode) {
                        Text("둘러보기").tag(ViewMode.walk)
                        Text("평면").tag(ViewMode.overview)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                }
                .padding(12)
                if let loading {
                    VStack(spacing: 10) {
                        if let p = progress { ProgressView(value: p).frame(width: 200) } else { ProgressView() }
                        Text(loading).font(.callout)
                    }
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onChange(of: mode) { _, m in viewer.call("setMode", m.rawValue) }
        .task { await open() }
        .errorAlert($error)
    }

    private func open() async {
        viewer.onEvent = { ev in
            switch ev {
            case .loaded:
                loading = nil
                progress = nil
            case .progress(let value):
                progress = value
            case .error(let message):
                error = message
                loading = nil
            case .meshFailed(let message):
                error = "파일을 열지 못했습니다" + (message.isEmpty ? "" : ": \(message)")
                loading = nil
            case .crashed:
                error = "파일이 너무 커서 3D 뷰어가 멈췄습니다 (이 기기의 메모리가 모자람). 삼각형 수 · 텍스처 크기를 줄인 파일로 다시 해 보세요."
                loading = nil
            case .bounds(let lo, let hi):
                sizeText = String(format: "%.2f × %.2f m · 높이 %.2f m", hi.x - lo.x, hi.z - lo.z, hi.y - lo.y)
            default:
                break
            }
        }
        guard await viewer.waitUntilReady() else {
            error = "3D 뷰어를 시작하지 못했습니다 (인터넷 연결 확인)"
            loading = nil
            return
        }
        loading = "3D 파일 여는 중"
        // .glb · .gltf · .obj 는 메시. PLY 는 3dgsUri 자리로 넘기면 뷰어가 머리말을 보고 메시 · 3DGS · 점 중에 고른다
        let isMesh = SceneAsset.isMesh(item.viewerURL)
        let empty = Room(geometry: nil, dimensions: nil, objects: [])          // 방 구조 없음 → 뷰어가 메시 크기에서 범위를 잡는다
        viewer.call("loadScene", ScenePayload(meshUrl: isMesh ? item.viewerURL : nil, objectModels: [:],
                                              splatUrl: isMesh ? nil : item.viewerURL, pointsUrl: nil,
                                              room: RoomPayload(empty), objects: [], removed: [], sceneRemoved: [], glass: []))
        viewer.call("setMode", mode.rawValue)
        viewer.call("setOverlay", false)
    }
}
