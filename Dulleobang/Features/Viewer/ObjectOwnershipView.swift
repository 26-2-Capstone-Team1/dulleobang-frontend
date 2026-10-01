import SwiftUI

// 입주 상태 (명세 v1 방식)
//  - 가구 구분: 매물을 올린 중개사가 인식된 가구마다 "개인 가구(이사 때 빠짐) / 임대 옵션(남음)" 을 정한다 → ObjectOwnershipView
//  - 가구 빼 보기: 매물을 보는 사람(임차인 · 중개사)이 개인 가구 중 뺄 것을 골라 "나만 보는" 입주 상태를 만든다 → RoomStateCreateView
//  입주 상태는 매물에 붙지 않고 만든 사람만 볼 수 있다. 다른 사람이 만든 입주 상태는 보이지 않는다.

/// 중개사(매물 등록자): 가구 구분만 한다.  PATCH /listings/{id}/objects {objects:[{objectId, ownershipType}]}
struct ObjectOwnershipView: View {
    let listingId: String
    let objectsVersion: Int?                            // 연 시점의 구분 버전 (If-Match)
    let onPreview: (String, String?) -> Void            // 3D 뷰어 색 미리보기
    let onSaved: () -> Void
    let onStale: (String) -> Void                       // 그 사이 다른 곳에서 구분이 바뀜(412) → 닫고 새로 불러온다

    @State private var objects: [SceneObject]
    @State private var saving = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(listingId: String, objects: [SceneObject], objectsVersion: Int?,
         onPreview: @escaping (String, String?) -> Void, onSaved: @escaping () -> Void,
         onStale: @escaping (String) -> Void) {
        self.listingId = listingId
        self.objectsVersion = objectsVersion
        self.onPreview = onPreview
        self.onSaved = onSaved
        self.onStale = onStale
        // 서버가 미분류를 "UNKNOWN" 으로 주든 null 로 주든 화면에서는 nil(미분류)로 다룬다
        _objects = State(initialValue: objects.map { o in
            var o = o
            if o.isUnclassified { o.ownershipType = nil }
            return o
        })
    }

    private var unclassified: Int { objects.filter(\.isUnclassified).count }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach($objects) { $obj in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(Fmt.objectLabel(obj.category)).font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(Fmt.dims(obj.dimensions)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            Picker("구분", selection: $obj.ownershipType) {
                                Text("미분류").tag(String?.none)
                                Text("개인 가구 (빠짐)").tag(String?.some("PERSONAL"))
                                Text("임대 옵션 (남음)").tag(String?.some("RENTAL_OPTION"))
                            }
                            .pickerStyle(.segmented)
                            .disabled(saving)
                            .onChange(of: obj.ownershipType) { _, new in onPreview(obj.objectId, new) }
                            if obj.isFixture && obj.isPersonal {
                                Text("고정 설비라서 개인 가구로 정해도 뺄 수 없습니다")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("인식된 가구 \(objects.count)개")
                } footer: {
                    Text("개인 가구로 정한 가구는 매물을 보는 사람이 ‘가구 빼 보기’에서 빼 볼 수 있습니다. 임대 옵션과 미분류 가구는 입주할 때도 그대로 남는 것으로 보여요.")
                }

                Section {
                    Button {
                        Task { await save() }
                    } label: {
                        HStack {
                            Spacer()
                            if saving { ProgressView() } else { Text("구분 저장") }
                            Spacer()
                        }
                    }
                    .disabled(saving)
                    if unclassified > 0 {
                        Text("미분류 \(unclassified)개는 아무도 뺄 수 없습니다").font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("가구 구분")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } } }
            .errorAlert($error)
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            try await ListingAPI.patchObjects(listingId, objects.map {
                .init(objectId: $0.objectId, ownershipType: $0.ownershipType ?? "UNKNOWN")
            }, objectsVersion: objectsVersion)
            onSaved()
            dismiss()
        } catch let e as APIError where e.status == 412 {
            // 다른 기기에서 먼저 구분을 바꿈: 덮어쓰지 않고 닫은 뒤 새로 불러온다
            onStale("그 사이 다른 곳에서 가구 구분이 바뀌었습니다. 다시 열어 확인해 주세요")
            dismiss()
        } catch {
            if error.isCancellation { return }
            self.error = error.userMessage
        }
    }
}

/// 가구 빼 보기: 개인 가구 중 뺄 것을 골라 나만 보는 입주 상태를 만든다.
///   POST /listings/{id}/room-states {sourceSpaceVersion, sourceObjectsVersion, removedObjectIds} → GET /ai-jobs/{jobId} 폴링
struct RoomStateCreateView: View {
    let listingId: String
    let objects: [SceneObject]
    let spaceVersion: Int?
    let objectsVersion: Int?
    let onPreview: ([String]?) -> Void                  // 고른 가구를 3D 에서 미리 숨긴다 (nil = 원래대로)
    let onCreated: (String) -> Void                     // 서버가 받은 직후의 roomStateId (아직 만드는 중)
    let onReady: (String) -> Void                       // 완성된 roomStateId
    let onStale: (String) -> Void                       // 그 사이 구분 · 공간이 바뀜(409) → 뷰어가 다시 불러온다

    @State private var selected: Set<String>
    @State private var phase: Phase = .editing
    @State private var error: String?
    @State private var submitTask: Task<Void, Never>?
    @State private var finished = false
    @Environment(\.dismiss) private var dismiss

    enum Phase: Equatable { case editing, sending, processing(String) }

    init(listingId: String, objects: [SceneObject], spaceVersion: Int?, objectsVersion: Int?,
         onPreview: @escaping ([String]?) -> Void, onCreated: @escaping (String) -> Void,
         onReady: @escaping (String) -> Void, onStale: @escaping (String) -> Void) {
        self.listingId = listingId
        self.objects = objects
        self.spaceVersion = spaceVersion
        self.objectsVersion = objectsVersion
        self.onPreview = onPreview
        self.onCreated = onCreated
        self.onReady = onReady
        self.onStale = onStale
        _selected = State(initialValue: Set(objects.filter(\.canRemove).map(\.objectId)))    // 처음엔 개인 가구 전부
    }

    private var removable: [SceneObject] { objects.filter(\.canRemove) }
    private var staying: [SceneObject] { objects.filter { !$0.canRemove } }
    private var chosenIds: [String] { removable.map(\.objectId).filter { selected.contains($0) } }

    var body: some View {
        NavigationStack {
            List {
                if removable.isEmpty {
                    Section {
                        Text("중개사가 개인 가구로 정한 가구가 없어서 뺄 수 있는 가구가 없습니다. 지금 보이는 모습이 입주할 때의 모습이에요.")
                            .font(.subheadline)
                    }
                } else {
                    Section {
                        ForEach(removable) { o in
                            Button {
                                if selected.contains(o.objectId) { selected.remove(o.objectId) } else { selected.insert(o.objectId) }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: selected.contains(o.objectId) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selected.contains(o.objectId) ? DB.purple : Color.secondary)
                                        .font(.title3)
                                    Text(Fmt.objectLabel(o.category)).font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Text(Fmt.dims(o.dimensions)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(phase != .editing)
                        }
                    } header: {
                        Text("뺄 가구 (전 세입자의 개인 가구)")
                    } footer: {
                        Text("고른 가구를 AI 가 지우고 그 자리를 빈 공간으로 채웁니다. 만든 입주 예상 공간은 나만 볼 수 있어요.")
                    }
                }

                if !staying.isEmpty {
                    Section {
                        ForEach(staying) { o in
                            HStack {
                                Text(Fmt.objectLabel(o.category)).font(.subheadline)
                                Spacer()
                                Text(Self.reason(o)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text("그대로 남는 가구")
                    }
                }

                if !removable.isEmpty {
                    Section {
                        Button {
                            submitTask = Task { await submit() }
                        } label: {
                            HStack {
                                Spacer()
                                switch phase {
                                case .editing: Text("\(chosenIds.count)개 빼고 입주 예상 공간 만들기")
                                case .sending: ProgressView()
                                case .processing(let msg): HStack { ProgressView(); Text(msg) }
                                }
                                Spacer()
                            }
                        }
                        .disabled(phase != .editing || chosenIds.isEmpty)
                        if chosenIds.isEmpty {
                            Text("뺄 가구를 하나 이상 골라 주세요").font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
            }
            .navigationTitle("가구 빼 보기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } } }
            .errorAlert($error)
            .onAppear { onPreview(chosenIds) }
            .onChange(of: selected) { _, _ in onPreview(chosenIds) }
        }
        .interactiveDismissDisabled(phase != .editing)     // 만드는 중에는 쓸어내려 닫지 않게 (닫기 버튼은 됨)
        .onDisappear {
            submitTask?.cancel()           // 닫으면 폴링만 멈춘다 (서버 작업은 계속되고, 다음에 열 때 목록에서 찾는다)
            if !finished { onPreview(nil) }
        }
    }

    private static func reason(_ o: SceneObject) -> String {
        if o.isPersonal { return "고정 설비" }
        if o.isRentalOption { return "임대 옵션" }
        return "미분류"
    }

    private func submit() async {
        phase = .sending
        do {
            let acc = try await ListingAPI.createRoomState(listingId, removed: chosenIds,
                                                           spaceVersion: spaceVersion, objectsVersion: objectsVersion)
            if let rsId = acc.roomStateId { onCreated(rsId) }
            phase = .processing("가구 빼는 중")
            let job = try await JobAPI.wait(acc.jobId) { j in
                phase = .processing("AI 처리 중\(j.percent.map { " \($0)%" } ?? "")")
            }
            guard job.isDone else { throw ViewerError(job.message ?? "입주 예상 공간을 만들지 못했습니다") }
            guard let rsId = acc.roomStateId ?? job.roomStateId else {
                throw ViewerError("완료됐지만 roomStateId 를 받지 못했습니다 (백엔드 응답 확인)")
            }
            try Task.checkCancellation()
            finished = true
            onReady(rsId)
            dismiss()
        } catch let e as APIError where e.status == 409 {
            // 중개사가 그 사이 구분을 바꿨거나 공간을 다시 촬영함: 목록이 낡았으니 닫고 새로 불러온다
            onStale(e.serverMessage ?? "가구 구분이 바뀌었습니다. 새로 불러온 뒤 다시 골라 주세요")
            dismiss()
        } catch {
            if error.isCancellation { return }
            self.error = error.userMessage
            phase = .editing
        }
    }
}
