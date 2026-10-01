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
}

extension ViewerRoute {
    init(listing l: Listing, roomStateId: String? = nil, knownRoomStateId: String? = nil, openFurnitureTray: Bool = false,
         openRemoval: Bool = false, initialPlacements: [Placement]? = nil) {
        self.init(listingId: l.listingId, title: Fmt.price(l), subtitle: Fmt.shortLocation(l.location),
                  roomStateId: roomStateId, knownRoomStateId: knownRoomStateId, openFurnitureTray: openFurnitureTray,
                  openRemoval: openRemoval, initialPlacements: initialPlacements)
    }
}

/// 매물 3D 탐색 (데모 "임차인의 매물 보기" 3번째 화면: 검정 헤더 · 초기화 · 평면뷰)
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
                    HStack {
                        if model.overlay && !model.dimensionsText.isEmpty {
                            Text(model.dimensionsText)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(Color.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.black.opacity(0.55), in: Capsule())
                        }
                        Spacer()
                    }
                    Spacer()
                    if let item = model.selected { selectedCard(item) }
                }
                .padding(12)
                if let msg = model.loading { loadingCard(msg) }
            }
            bottomBar
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .task {
            await model.load()
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
            Button("초기화") { model.resetView() }
                .buttonStyle(.dbPill(dark: true))
            Button(model.mode == .walk ? "평면뷰" : "1인칭") {
                model.mode = model.mode == .walk ? .overview : .walk
            }
            .buttonStyle(.dbPill(dark: true))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.black)
    }

    private var bottomBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if myRoomStateId != nil || model.isMovein {
                    Button(model.isMovein ? "현재 상태 보기" : "입주 예상 보기") {
                        Task {
                            if model.isMovein { await model.showCurrent() }
                            else if let id = myRoomStateId { await model.showRoomState(id) }
                        }
                    }
                    .buttonStyle(.dbPill(dark: true))
                    .disabled(model.loading != nil)          // 불러오는 중에 또 누르지 않게
                }
                if canRemoveAny {
                    Button { showRemoval = true } label: {
                        Label("가구 빼 보기", systemImage: "sparkles")
                    }
                    .buttonStyle(.dbPill(dark: true))
                    .disabled(model.loading != nil)
                }
                Button { model.overlay.toggle() } label: {
                    Label("치수", systemImage: model.overlay ? "ruler.fill" : "ruler")
                }
                .buttonStyle(.dbPill(dark: true))

                if !model.placed.isEmpty {
                    let bad = model.placed.filter { !$0.ok }.count
                    Text(bad == 0 ? "모두 배치 가능" : "\(bad)개 충돌")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(bad == 0 ? Color.green : Color.red)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.1), in: Capsule())
                    Button { Task { await model.save() } } label: {
                        Label("저장", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.dbPill(dark: true))
                }

                Button { showFurniturePicker = true } label: {
                    Label("가구 추가", systemImage: "plus")
                }
                .buttonStyle(.dbPill(filled: true))

                if isBroker && !model.objects.isEmpty {
                    Button("가구 구분") { showOwnership = true }
                        .buttonStyle(.dbPill(dark: true))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(Color.black)
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
                Text(Fmt.dims(item.dims)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
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
