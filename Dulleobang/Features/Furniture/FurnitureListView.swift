import SwiftUI

/// 내 가구 (마이페이지 › 내 가구): GET /users/me/furniture + 새 가구 등록·촬영
struct FurnitureListView: View {
    @State private var items: [Furniture] = []
    @State private var loading = false
    @State private var error: String?
    @State private var showRegister = false

    var body: some View {
        List {
            if !loading && items.isEmpty {
                ContentUnavailableView("등록된 가구가 없습니다",
                                       systemImage: "sofa",
                                       description: Text("지금 쓰는 침대·책상·옷장을 촬영해 두면\n어느 매물에든 실제 크기로 놓아 볼 수 있어요."))
                    .listRowSeparator(.hidden)
            }
            ForEach(items) { f in FurnitureRow(furniture: f) }
        }
        .listStyle(.plain)
        .navigationTitle("내 가구")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showRegister = true } label: { Label("가구 등록", systemImage: "plus") }
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .overlay { if loading && items.isEmpty { ProgressView() } }
        .refreshable { await load() }
        .task { await load() }
        .sheet(isPresented: $showRegister, onDismiss: { Task { await load() } }) {
            FurnitureRegisterView()
        }
        .errorAlert($error)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do { items = try await FurnitureAPI.mine() } catch { if !error.isCancellation { self.error = error.userMessage } }
    }
}

struct FurnitureRow: View {
    let furniture: Furniture
    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(uri: furniture.thumbnailUri, placeholderIcon: FurnitureRegisterView.icon(furniture.category))
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(furniture.label).font(.headline)
                if let d = furniture.dimensions {
                    Text("가로 \(Int(d.width * 100)) · 깊이 \(Int(d.depth * 100)) · 높이 \(Int(d.height * 100)) cm")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !furniture.isReady {
                switch furniture.status {
                case "FAILED":
                    Label("실패", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
                case "DRAFT":           // 등록만 하고 아직 촬영을 올리지 않음
                    Label("촬영 전", systemImage: "camera").font(.caption).foregroundStyle(.secondary)
                default:
                    Label("3D 생성 중", systemImage: "hourglass").font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }
}

/// 가구 이름·종류 입력(POST /furniture) → 다각도 촬영
struct FurnitureRegisterView: View {
    @State private var name = ""
    @State private var category = "bed"
    @State private var saving = false
    @State private var error: String?
    @State private var captureId: CaptureID?
    @Environment(\.dismiss) private var dismiss

    struct CaptureID: Identifiable { let id: String }
    static let categories: [(key: String, label: String, icon: String)] = [
        ("bed", "침대", "bed.double"), ("desk", "책상", "table.furniture"), ("sofa", "소파", "sofa"),
        ("closet", "옷장", "cabinet"), ("storage", "수납장", "archivebox"), ("chair", "의자", "chair"), ("other", "기타", "shippingbox"),
    ]
    static func icon(_ key: String?) -> String { categories.first { $0.key == key }?.icon ?? "shippingbox" }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("예: 자취방 침대 (슈퍼싱글)", text: $name)
                } header: { Text("이름") } footer: {
                    if name.trimmingCharacters(in: .whitespaces).count > 80 {
                        Text("가구 이름은 80자까지 입력할 수 있습니다").foregroundStyle(.red)
                    }
                }
                Section("종류") {
                    Picker("종류", selection: $category) {
                        ForEach(Self.categories.indices, id: \.self) { i in
                            Label(Self.categories[i].label, systemImage: Self.categories[i].icon).tag(Self.categories[i].key)
                        }
                    }
                    .pickerStyle(.navigationLink)
                }
                Section {
                    Button { Task { await submit() } } label: {
                        HStack { Spacer(); if saving { ProgressView() } else { Text("등록하고 가구 촬영하기") }; Spacer() }
                    }
                    .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty
                              || name.trimmingCharacters(in: .whitespaces).count > 80)
                } footer: {
                    Text("가구 전체가 보이게 1~2 m 떨어져서 한 바퀴 돌며 촬영합니다. 실제 크기는 휴대폰의 이동 거리로 자동 계산됩니다.")
                }
            }
            .navigationTitle("가구 등록")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } } }
            .fullScreenCover(item: $captureId, onDismiss: { dismiss() }) { c in
                CaptureFlowView(target: .furniture(c.id))
            }
            .errorAlert($error)
        }
    }

    private func submit() async {
        saving = true
        defer { saving = false }
        do {
            let res = try await FurnitureAPI.create(name: name.trimmingCharacters(in: .whitespaces), category: category)
            captureId = CaptureID(id: res.furnitureId)
        } catch {
            self.error = error.validationAwareMessage(hint: "가구 이름은 80자까지 입력할 수 있습니다.")
        }
    }
}
