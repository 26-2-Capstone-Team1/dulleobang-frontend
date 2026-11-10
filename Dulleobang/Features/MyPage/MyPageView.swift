import PhotosUI
import SwiftUI

/// 마이페이지 (데모 4번째 화면 · 중개사 인증 후 화면):
/// 프로필(이름 · 역할) · 알림 · 설정 / 바로가기 3칸(관심 매물 · 내 가구 · 올린 매물) · 내 가구로 맞는 방 찾기 / [중개사 메뉴] / 문의하기 · 중개사 신청하기 · 앱 버전 · 로그아웃
struct MyPageView: View {
    var body: some View { TabStack { MyPageContent() } }
}

private struct MyPageContent: View {
    @EnvironmentObject private var session: Session
    @Environment(\.navigate) private var navigate
    @State private var myCount: Int?
    @State private var furnitureCount: Int?
    @State private var confirmLogout = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                shortcutTiles
                CompareBanner(title: "내 가구로 맞는 방 찾기", subtitle: "관심 매물에 내 침대 · 책상을 자동으로 놓아 비교해요")

                if let agent = session.agent {
                    if agent.isApproved {
                        brokerCard(agent)
                    } else if agent.isPending {
                        statusCard(title: "중개사 인증 심사 중", message: "제출한 서류를 확인하고 있습니다. 승인되면 올린 매물에 ‘인증 중개사’ 표시가 붙어요.",
                                   color: DB.accent)
                    } else if agent.isRejected {
                        statusCard(title: "중개사 인증이 반려되었습니다",
                                   message: agent.rejectReason ?? "정보를 확인한 뒤 다시 신청해 주세요.", color: DB.danger)
                    }
                }

                if !session.isBroker {
                    // 중개사가 아니어도 본인 집을 매물로 올릴 수 있다
                    GroupCard {
                        Button { navigate(.register) } label: { NavRowLabel(title: "내 집 매물 올리기") }
                    }
                    .buttonStyle(.plain)
                }

                GroupCard {
                    if let url = mailURL {
                        Link(destination: url) { NavRowLabel(title: "문의하기") }
                        RowDivider()
                    }
                    if !session.isBroker {
                        NavigationLink(value: session.agent == nil || session.agent?.isRejected == true ? AppRoute.agentVerify : AppRoute.agentInfo) {
                            NavRowLabel(title: "중개사 인증 신청", value: "인증 표시", valueColor: DB.sub)
                        }
                        RowDivider()
                    }
                    NavRowLabel(title: "앱 버전", value: AppConfig.shared.appVersion, showsChevron: false)
                    RowDivider()
                    Button { confirmLogout = true } label: {
                        NavRowLabel(title: "로그아웃", titleColor: DB.danger)
                    }
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await reload() }
        .task { await reload() }
        .confirmationDialog("로그아웃할까요?", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("로그아웃", role: .destructive) { Task { await session.logout() } }
            Button("취소", role: .cancel) {}
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Text(String(session.displayName.prefix(1)))
                .font(.title3.weight(.heavy))
                .foregroundStyle(DB.accent)
                .frame(width: 52, height: 52)
                .background(DB.accentSoft, in: Circle())
                .overlay(Circle().stroke(DB.accentLine))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(session.displayName).font(.title2.weight(.bold)).foregroundStyle(DB.ink)
                roleChip
            }
            Spacer()
            NavigationLink(value: AppRoute.notifications) {
                Image(systemName: "bell").font(.title3)
            }
            .accessibilityLabel("알림")
            NavigationLink(value: AppRoute.settings) {
                Image(systemName: "gearshape").font(.title3)
            }
            .accessibilityLabel("설정")
        }
        .foregroundStyle(DB.ink)
        .buttonStyle(.plain)
        .padding(.top, 28)
        .padding(.bottom, 6)
    }

    /// 이름 아래: 인증 중개사 / 심사 중 / 일반 회원
    @ViewBuilder private var roleChip: some View {
        if session.isBroker {
            VerifiedBrokerBadge()
        } else {
            Text(session.agent?.isPending == true ? "중개사 인증 심사 중" : "일반 회원")
                .font(.caption.weight(.semibold))
                .foregroundStyle(DB.sub)
        }
    }

    /// 바로가기 3칸: 관심 매물 · 내 가구 · 올린 매물 (누르면 그 목록)
    private var shortcutTiles: some View {
        HStack(spacing: 10) {
            tile(icon: "heart.fill", color: DB.danger, title: "관심 매물", value: session.favoriteIds.count, route: .favorites)
            tile(icon: "sofa", color: DB.accent, title: "내 가구", value: furnitureCount, route: .furniture)
            tile(icon: "house.fill", color: DB.ink, title: "올린 매물", value: myCount, route: .myListings)
        }
    }

    private func tile(icon: String, color: Color, title: String, value: Int?, route: AppRoute) -> some View {
        NavigationLink(value: route) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 18, weight: .semibold)).foregroundStyle(color)
                Text(value.map { "\($0)" } ?? "–").font(.title3.weight(.heavy)).foregroundStyle(DB.ink)
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(DB.sub)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(DB.group, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    /// 초록 "중개사 메뉴" 카드
    private func brokerCard(_ a: AgentProfile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("중개사 메뉴").font(.headline.weight(.bold)).foregroundStyle(DB.accent)
                Spacer()
                Button("매물 등록") { navigate(.register) }.buttonStyle(.dbPill(filled: true))
            }
            Text("\(a.officeName ?? "중개사무소") 정보로 인증되어 있습니다.").font(.caption).foregroundStyle(DB.sub)
            VStack(spacing: 0) {
                NavigationLink(value: AppRoute.agentInfo) { NavRowLabel(title: "중개사 인증 정보 보기") }
                Divider().padding(.horizontal, 16)
                NavigationLink(value: AppRoute.myListings) {
                    NavRowLabel(title: "내가 올린 매물 보기", value: myCount.map { "\($0)개" }, valueColor: DB.accent)
                }
            }
            .buttonStyle(.plain)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(16)
        .background(DB.accentSoft, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(DB.accentLine))
    }

    private func statusCard(title: String, message: String, color: Color) -> some View {
        NavigationLink(value: AppRoute.agentInfo) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title).font(.subheadline.weight(.bold)).foregroundStyle(color)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(DB.faint)
                }
                Text(message).font(.caption).foregroundStyle(DB.sub).multilineTextAlignment(.leading)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DB.accentSoft, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    private var mailURL: URL? {
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = AppConfig.shared.supportEmail
        c.queryItems = [URLQueryItem(name: "subject", value: "\(AppConfig.shared.brandName) 문의")]
        return c.url
    }

    private func reload() async {
        await session.refreshAgent()
        myCount = (try? await MyListingsView.fetch(userId: session.userId))?.count
        furnitureCount = (try? await FurnitureAPI.mine())?.count
    }
}

// MARK: - 중개인 인증

/// 중개인 인증 (데모 "중개인의 매물 등록하기 (1)" 2번째 화면)
struct AgentVerifyView: View {
    @EnvironmentObject private var session: Session
    @Environment(\.navigate) private var navigate
    @State private var name = ""
    @State private var license = ""
    @State private var office = ""
    @State private var docItem: PhotosPickerItem?
    @State private var docImage: UIImage?
    @State private var docData: Data?
    @State private var busy = false
    @State private var error: String?

    private var canSubmit: Bool {
        !name.trimmed.isEmpty && !license.trimmed.isEmpty && !office.trimmed.isEmpty && docData != nil && !busy
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("중개인 인증").font(.title2.weight(.bold)).foregroundStyle(DB.ink)
                    Text("인증을 완료하면\n매물 등록 기능을 사용할 수 있습니다.").font(.subheadline).foregroundStyle(DB.sub)
                }
                FieldBlock(title: "이름") { DBTextField(placeholder: "입력하기", text: $name) }
                FieldBlock(title: "중개사 번호") { DBTextField(placeholder: "입력하기", text: $license, keyboard: .numberPad) }
                FieldBlock(title: "사무소명") { DBTextField(placeholder: "입력하기", text: $office) }
                FieldBlock(title: "사업자 등록증") {
                    PhotosPicker(selection: $docItem, matching: .images) { uploadBox }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            Button {
                Task { await submit() }
            } label: {
                if busy { ProgressView().tint(Color.white) } else { Text("인증 완료하기") }
            }
            .buttonStyle(.dbPrimary)
            .disabled(!canSubmit)
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            .background(Color.white)
        }
        .toolbar(.hidden, for: .tabBar)
        .navigationBarBackButtonHidden(busy)
        .onAppear {
            if name.isEmpty { name = session.name ?? "" }
        }
        .onChange(of: docItem) { _, item in
            Task { await loadDocument(item) }
        }
        .errorAlert($error)
    }

    private var uploadBox: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(DB.field)
            if let img = docImage {
                Image(uiImage: img).resizable().scaledToFit().padding(10)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo").font(.title2)
                    Text("업로드하기").font(.subheadline)
                }
                .foregroundStyle(DB.sub)
            }
        }
        .frame(height: docImage == nil ? 110 : 200)
        .contentShape(Rectangle())
    }

    private func loadDocument(_ item: PhotosPickerItem?) async {
        guard let item, let raw = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: raw) else { return }
        let scaled = img.downscaled(maxPixel: 2000)
        docImage = scaled
        docData = scaled.jpegData(compressionQuality: 0.85)
    }

    private func submit() async {
        guard let doc = docData else { return }
        busy = true
        defer { busy = false }
        let docName = "\(name.trimmed)_\(office.trimmed)_사업자등록증.jpg"
        do {
            var p = try await UserAPI.applyAgent(name: name.trimmed, licenseNumber: license.trimmed,
                                                 officeName: office.trimmed, document: doc, documentName: docName)
            if p.status == nil { p.status = "PENDING" }
            if p.name == nil { p.name = name.trimmed }
            if p.licenseNumber == nil { p.licenseNumber = license.trimmed }
            if p.officeName == nil { p.officeName = office.trimmed }
            if p.documentName == nil { p.documentName = docName }
            session.setAgent(p)
            navigate.replaceTop(.agentInfo)
        } catch let e as APIError where e.isMissingEndpoint {
            #if DEBUG
            // 서버에 인증 API 가 아직 없으면 (개발 빌드) 기기에만 승인 상태로 저장해 등록 흐름을 이어서 볼 수 있게 한다
            session.setLocalAgent(AgentProfile(status: "APPROVED", name: name.trimmed, licenseNumber: license.trimmed,
                                               officeName: office.trimmed, documentName: docName))
            session.toast = "서버에 인증 API 가 없어 기기에만 저장했습니다 (개발용)"
            navigate.replaceTop(.agentInfo)
            #else
            self.error = e.userMessage
            #endif
        } catch {
            self.error = error.validationAwareMessage(hint: "이름과 등록번호는 80자, 사무소 이름은 150자까지 입력할 수 있습니다.")
        }
    }
}

/// 중개사 인증 정보 (데모 "중개인의 매물 등록하기 (1)" 3번째 화면)
struct AgentInfoView: View {
    @EnvironmentObject private var session: Session
    @Environment(\.navigate) private var navigate

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("중개사 인증 정보").font(.title2.weight(.bold)).foregroundStyle(DB.ink)
                    Text(subtitle).font(.subheadline).foregroundStyle(DB.sub)
                }
                if let a = session.agent {
                    VStack(alignment: .leading, spacing: 10) {
                        badge(a)
                        infoRow("이름", a.name)
                        infoRow("중개사 번호", a.licenseNumber)
                        infoRow("사무소명", a.officeName)
                        infoRow("제출 서류", a.documentName)
                        if a.isRejected, let r = a.rejectReason { infoRow("반려 사유", r) }
                        if a.isRejected {
                            Button("다시 신청하기") { navigate.replaceTop(.agentVerify) }
                                .buttonStyle(.dbPrimary)
                                .padding(.top, 4)
                        } else {
                            Button("마이페이지로 돌아가기") { navigate.popToRoot() }
                                .buttonStyle(.dbPrimary)
                                .padding(.top, 4)
                        }
                    }
                    .padding(16)
                    .background(DB.accentSoft, in: RoundedRectangle(cornerRadius: 16))
                } else {
                    EmptyStateView(icon: "person.text.rectangle", title: "인증 정보가 없습니다", message: "마이페이지 › 중개사 신청하기에서 인증을 신청해 주세요.")
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .toolbar(.hidden, for: .tabBar)
        .task {
            await session.refreshAgent()
            // 심사 중이면 이 화면을 보는 동안 결과를 주기적으로 확인한다
            while !Task.isCancelled, session.agent?.isPending == true {
                do { try await Task.sleep(for: .seconds(3)) } catch { break }
                await session.refreshAgent()
            }
        }
    }

    private var subtitle: String {
        guard let a = session.agent else { return "" }
        if a.isApproved { return "인증된 정보로\n매물을 등록하고 관리할 수 있습니다." }
        if a.isRejected { return "인증이 반려되었습니다.\n사유를 확인하고 다시 신청해 주세요." }
        return "제출한 정보를 확인하고 있습니다.\n승인되면 매물 등록 기능이 열립니다."
    }

    private func badge(_ a: AgentProfile) -> some View {
        let text = a.isApproved ? "인증 완료" : (a.isRejected ? "반려됨" : "심사 중")
        return Text(text)
            .font(.caption.weight(.bold))
            .foregroundStyle(a.isRejected ? DB.danger : DB.accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.white, in: Capsule())
    }

    private func infoRow(_ label: String, _ value: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(DB.sub).frame(width: 64, alignment: .leading)
            Spacer(minLength: 0)
            Text(value ?? "-").font(.subheadline.weight(.bold)).foregroundStyle(DB.ink).multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - 관심 매물 · 내가 올린 매물 · 알림

struct FavoritesView: View {
    @EnvironmentObject private var session: Session
    @State private var items: [Listing] = []
    @State private var loading = true
    @State private var loadError: String?

    /// ♡ 를 풀면 바로 목록에서 빠지게 한다
    private var shown: [Listing] { items.filter { session.isFavorite($0.listingId) } }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Text("관심 매물").font(.title2.weight(.bold)).foregroundStyle(DB.ink).padding(.bottom, 8)
                if loading && items.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                } else if shown.isEmpty {
                    EmptyStateView(icon: "heart", title: "관심 매물이 없습니다",
                                   message: loadError ?? "매물의 ♡ 를 눌러 저장해 두면 여기에서 모아 볼 수 있어요.")
                }
                ForEach(shown) { l in
                    ListingRow(listing: l).padding(.vertical, 10)
                    Divider()
                }
                let comparable = shown.filter { $0.isSpaceReady }
                if !comparable.isEmpty {
                    NavigationLink(value: AppRoute.compare(comparable.map(\.listingId))) {
                        Label("내 가구로 비교하기 (\(comparable.count)곳)", systemImage: "sofa")
                    }
                    .buttonStyle(.dbPrimary)
                    .padding(.top, 20)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .toolbar(.hidden, for: .tabBar)
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            items = try await UserAPI.scraps()
            loadError = nil
        } catch {
            if error.isCancellation { return }
            // 서버에 관심 매물 API 가 없으면 기기에 저장된 ID 로 하나씩 불러온다
            var out: [Listing] = []
            for id in session.favoriteIds.sorted() {
                if let l = try? await ListingAPI.get(id) { out.append(l) }
            }
            items = out
            if out.isEmpty && !session.favoriteIds.isEmpty { loadError = error.userMessage }
        }
    }
}

/// 내가 올린 매물 (중개사)
struct MyListingsView: View {
    @EnvironmentObject private var session: Session
    @State private var items: [Listing] = []
    @State private var loading = true
    @State private var loadError: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("내가 올린 매물").font(.title2.weight(.bold)).foregroundStyle(DB.ink)
                    Spacer()
                    NavigationLink(value: AppRoute.register) { Text("매물 등록") }
                        .buttonStyle(.dbPill(filled: true))
                }
                .padding(.bottom, 8)
                if loading && items.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                } else if items.isEmpty {
                    EmptyStateView(icon: "house", title: "올린 매물이 없습니다", message: loadError ?? "‘매물 등록’으로 첫 매물을 올려 보세요.")
                }
                ForEach(items) { l in
                    VStack(alignment: .leading, spacing: 4) {
                        ListingRow(listing: l)
                        StatusBadge(status: l.space3DInfo?.status).padding(.leading, 86)
                    }
                    .padding(.vertical, 10)
                    Divider()
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .toolbar(.hidden, for: .tabBar)
        .refreshable { await load() }
        .task { await load() }
    }

    /// users/me/listings 가 없으면 전체 목록에서 내 매물만 거른다
    static func fetch(userId: String?) async throws -> [Listing] {
        do {
            return try await UserAPI.myListings()
        } catch let e as APIError where e.isMissingEndpoint {
            guard let userId else { return [] }
            return try await ListingAPI.list().filter { $0.agent?.userId == userId }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            items = try await Self.fetch(userId: session.userId)
            loadError = nil
        } catch {
            if !error.isCancellation { loadError = error.userMessage }
        }
    }
}

struct NotificationsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading) {
                Text("알림").font(.title2.weight(.bold)).foregroundStyle(DB.ink)
                EmptyStateView(icon: "bell", title: "새 알림이 없습니다",
                               message: "채팅 · 3D 공간 생성 완료 · 중개사 인증 결과를 여기에서 알려 드릴 예정입니다.")
            }
            .padding(.horizontal, 20)
        }
        .toolbar(.hidden, for: .tabBar)
    }
}
