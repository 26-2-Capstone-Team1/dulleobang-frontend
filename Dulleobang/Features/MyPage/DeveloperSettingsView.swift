import SwiftUI

/// 설정: 서버 주소 · 로그인 정보 · 개발용 중개사 모드 · 촬영 옵션 · 오프라인 촬영(capture.zip) · 저장 공간
/// 로그인 화면(⚙︎)과 마이페이지(⚙︎) 양쪽에서 연다.
struct DeveloperSettingsView: View {
    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss
    @AppStorage("baseURL") private var baseURL = AppConfig.defaultBaseURL
    @AppStorage("useRoomPlan") private var useRoomPlan = true
    @AppStorage("lockFocus") private var lockFocus = true
    @AppStorage("autoTorch") private var autoTorch = true
    @AppStorage(AppConfig.useMockDataKey) private var useMockData = AppConfig.useMockDataDefault
    @State private var offline: CaptureKind?
    @State private var cacheMB = AssetCache.sizeMB
    @State private var captureCount = 0
    @State private var demoSummary = ""
    @State private var confirmReset = false
    @State private var resetting = false

    var body: some View {
        Form {
            Section {
                Toggle("데모 데이터 사용", isOn: $useMockData)
                if useMockData {
                    LabeledContent("데모 데이터", value: demoSummary)
                    Button(role: .destructive) {
                        confirmReset = true
                    } label: {
                        HStack {
                            Text("데모 데이터 초기화")
                            if resetting { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(resetting)
                }
            } header: {
                Text("데모 모드")
            } footer: {
                Text(useMockData
                     ? "서버 없이 앱 안의 예시 매물 · 채팅 · 내 가구 · 3D 공간으로 동작합니다. 등록 · 채팅 · 배치한 내용은 이 기기에만 저장되고, 3D 생성 · 중개사 인증은 몇 초 뒤 자동으로 완료됩니다."
                     : "아래 백엔드 서버에 연결합니다. 데모 모드에서 만든 계정 · 데이터는 서버에 없으니 다시 로그인해 주세요.")
            }

            Section {
                TextField("http://192.168.0.10:8080/api", text: $baseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if baseURL != AppConfig.defaultBaseURL {
                    Button("기본 서버로 (팀 GCP 서버)") { baseURL = AppConfig.defaultBaseURL }
                }
            } header: {
                Text("백엔드 서버")
            } footer: {
                Text(useMockData
                     ? "데모 모드에서는 쓰지 않습니다."
                     : "기본은 팀 GCP 서버예요. 같은 Wi-Fi 의 노트북에서 서버를 돌린다면 노트북 IP 를 넣으세요. localhost 는 휴대폰 자신을 뜻합니다.")
            }
            .disabled(useMockData)

            if session.isLoggedIn {
                Section("로그인") {
                    LabeledContent("사용자 ID (X-User-Id)", value: session.userId ?? "-")
                    LabeledContent("이름", value: session.displayName)
                    Toggle("중개사 모드 (기기에만 저장 · 개발용)", isOn: Binding(
                        get: { session.usesLocalAgent && session.isBroker },
                        set: { on in
                            session.setLocalAgent(on ? AgentProfile(status: "APPROVED", name: session.displayName,
                                                                    licenseNumber: "00000000000", officeName: "테스트 공인중개사사무소",
                                                                    documentName: "테스트_사업자등록증.jpg") : nil)
                        }))
                }
            }

            Section {
                Toggle("RoomPlan 으로 벽·문·창 함께 스캔", isOn: $useRoomPlan)
                    .disabled(!RoomPlanController.isSupported)
                Toggle("촬영 중 초점 고정 (끄면 계속 자동 초점)", isOn: $lockFocus)
                Toggle("어두우면 손전등 자동으로 켜기", isOn: $autoTorch)
                Button { offline = .room } label: { Label("오프라인 방 촬영 → capture.zip", systemImage: "camera.viewfinder") }
                Button { offline = .furniture } label: { Label("오프라인 가구 촬영 → capture.zip", systemImage: "sofa") }
            } header: {
                Text("촬영")
            } footer: {
                Text(RoomPlanController.isSupported
                     ? "LiDAR 기기입니다. 깊이(depth)와 RoomPlan 구조가 함께 저장됩니다.\n오프라인 촬영은 서버 없이 zip 을 만들어 AirDrop 으로 AI 팀원에게 보낼 때 씁니다."
                     : "LiDAR 가 없는 기기입니다. 사진 + 카메라 포즈만 저장됩니다.")
            }

            Section("저장 공간") {
                LabeledContent("3D 캐시", value: String(format: "%.0f MB", cacheMB))
                Button("3D 캐시 비우기", role: .destructive) {
                    AssetCache.clear()
                    cacheMB = AssetCache.sizeMB
                }
                LabeledContent("기기에 남은 촬영본", value: "\(captureCount)개")
                Button("촬영본 모두 삭제", role: .destructive) {
                    try? FileManager.default.removeItem(at: CaptureRecorder.root)
                    captureCount = 0
                }
            }

            Section("정보") {
                LabeledContent("앱 버전", value: AppConfig.shared.appVersion)
                LabeledContent("기기", value: CaptureRecorder.deviceModel)
                LabeledContent("3D 뷰어 라이브러리",
                               value: ViewerAssetHandler.importMap().contains("./vendor") ? "앱 내장" : "CDN (인터넷 필요)")
            }
        }
        .navigationTitle("설정")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            if !session.isLoggedIn {
                ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } }
            }
        }
        .onAppear {
            cacheMB = AssetCache.sizeMB
            captureCount = (try? FileManager.default.contentsOfDirectory(atPath: CaptureRecorder.root.path).count) ?? 0
        }
        .task(id: useMockData) { demoSummary = await MockBackend.shared.summary() }
        .onChange(of: useMockData) { _, _ in
            // 데이터 출처가 바뀌면 최근 본 매물 · 관심 매물 · 중개사 상태를 새로 읽는다
            APIClient.shared.etags.removeAll()
            session.clearRecent()
            Task { await session.refresh() }
        }
        .confirmationDialog("데모 데이터를 처음 상태로 되돌릴까요?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("초기화", role: .destructive) { Task { await resetDemo() } }
            Button("취소", role: .cancel) {}
        } message: {
            Text("데모 모드에서 등록한 매물 · 채팅 · 가구 배치 · 중개사 인증이 모두 지워집니다.")
        }
        .fullScreenCover(item: $offline) { kind in
            CaptureFlowView(target: .localOnly(kind))
        }
    }

    private func resetDemo() async {
        resetting = true
        await MockBackend.shared.reset()
        APIClient.shared.etags.removeAll()
        session.clearRecent()
        await session.refresh()
        demoSummary = await MockBackend.shared.summary()
        resetting = false
        session.toast = "데모 데이터를 처음 상태로 되돌렸습니다"
    }
}

extension CaptureKind: Identifiable { var id: String { rawValue } }
