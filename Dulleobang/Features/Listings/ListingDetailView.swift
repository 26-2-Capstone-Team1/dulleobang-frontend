import SwiftUI

/// 매물 상세 (데모 "임차인의 매물 보기" 2번째 화면):
/// 사진 넘기기 · 가격 정보 · 상세 정보 · 옵션 · 생활 환경 · 3D 공간(둘러보기 / 입주 예상 / 내 가구 놓아보기) · ♡ + 채팅하기
struct ListingDetailView: View {
    let listingId: String
    @EnvironmentObject private var session: Session
    @Environment(\.navigate) private var navigate
    @State private var listing: Listing?
    @State private var space: SpaceResponse?
    @State private var myRoomState: RoomState?          // 내가 만든 입주 상태 (다른 사람 것은 볼 수 없다)
    @State private var job: AIJob?
    @State private var loadError: String?
    @State private var actionError: String?
    @State private var viewer: ViewerRoute?
    @State private var showCapture = false
    @State private var showReport = false
    @State private var openingChat = false
    @State private var reloadToken = 0
    @State private var isVisible = false

    /// 이 매물을 올린 중개사 본인인가
    private var isOwner: Bool {
        guard let me = session.userId, let owner = listing?.agent?.userId else { return false }
        return me == owner
    }

    var body: some View {
        Group {
            if let l = listing {
                content(l)
            } else if let loadError {
                VStack(spacing: 12) {
                    EmptyStateView(icon: "exclamationmark.triangle", title: "매물을 불러오지 못했습니다", message: loadError)
                    Button("다시 시도") { reloadToken += 1 }.buttonStyle(.dbPill())
                }
                .frame(maxHeight: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("신고하기", systemImage: "exclamationmark.bubble") { showReport = true }
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
        }
        .task(id: reloadToken) { await load() }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .fullScreenCover(item: $viewer, onDismiss: { Task { await reloadSpaceCard() } }) { r in
            SpaceViewerView(route: r, isBroker: isOwner)
        }
        .fullScreenCover(isPresented: $showCapture, onDismiss: { reloadToken += 1 }) {
            CaptureFlowView(target: .listing(listingId))
        }
        .sheet(isPresented: $showReport) {
            ReportSheet(listingId: listingId).presentationDetents([.large])
        }
        .errorAlert($actionError)
    }

    // MARK: - 본문

    private func content(_ l: Listing) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PhotoCarousel(uris: l.photoUris)

                VStack(alignment: .leading, spacing: 30) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(Fmt.price(l)).font(.title.weight(.bold)).foregroundStyle(DB.ink)
                        if !l.location.isEmpty {
                            Text(l.location).font(.subheadline).foregroundStyle(DB.sub)
                        }
                    }

                    section("가격 정보") {
                        InfoRow(label: Fmt.dealLabel(l), value: Fmt.priceShort(l))
                        InfoRow(label: "관리비", value: Fmt.fee(l))
                    }

                    section("상세 정보") {
                        InfoRow(label: "방종류", value: Fmt.roomType(l.roomType).ifEmpty("-"))
                        InfoRow(label: "해당층/건물층", value: Fmt.floors(l))
                        InfoRow(label: "전용/공급면적", value: Fmt.areas(l))
                        InfoRow(label: "방 수/욕실 수", value: Fmt.roomsBaths(l))
                        InfoRow(label: "입주 가능일", value: Fmt.available(l.availableFrom))
                    }

                    if let opts = l.rentalOptions, !opts.isEmpty {
                        section("옵션") {
                            FlowStack {
                                ForEach(opts, id: \.self) { OptionTag(label: Fmt.optionLabel($0)) }
                            }
                        }
                    }

                    if let env = l.livingEnvironment?.trimmed, !env.isEmpty {
                        section("생활 환경") {
                            Text(env).font(.subheadline).foregroundStyle(DB.ink).fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    section("3D 공간") { spaceCard(l) }

                    if let a = l.agent, a.name != nil || a.officeName != nil {
                        section(a.isVerified ? "중개사" : "등록한 사람") { agentRow(a) }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 22)
                .padding(.bottom, 24)
            }
        }
        .ignoresSafeArea(edges: .top)
        .refreshable { await load(followJob: false) }
        .safeAreaInset(edge: .bottom) { bottomBar(l) }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title3.weight(.bold)).foregroundStyle(DB.ink)
            content()
        }
    }

    // MARK: - 3D 공간 카드 (둘러방 기능)

    private func spaceCard(_ l: Listing) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            switch l.space3DInfo?.status ?? "NONE" {
            case "COMPLETED":
                if let s = space {
                    spaceSummary(s)
                }
                Button {
                    viewer = ViewerRoute(listing: l, knownRoomStateId: myRoomState?.roomStateId)
                } label: {
                    Label("3D 공간 둘러보기", systemImage: "cube.transparent")
                }
                .buttonStyle(.dbPrimary)
                HStack(spacing: 10) {
                    // 입주 예상 공간은 각자 만든다: 만든 게 있으면 열고, 없으면 "가구 빼 보기"로 만든다
                    if let rs = myRoomState?.roomStateId {
                        Button {
                            viewer = ViewerRoute(listing: l, roomStateId: rs)
                        } label: {
                            Label("입주 예상 공간", systemImage: "sparkles")
                        }
                        .buttonStyle(.dbSecondary)
                    } else if space?.objects.contains(where: \.canRemove) == true {
                        Button {
                            viewer = ViewerRoute(listing: l, openRemoval: true)
                        } label: {
                            Label("가구 빼 보기", systemImage: "sparkles")
                        }
                        .buttonStyle(.dbSecondary)
                    }
                    Button {
                        viewer = ViewerRoute(listing: l, roomStateId: myRoomState?.roomStateId, openFurnitureTray: true)
                    } label: {
                        Label("내 가구 놓아보기", systemImage: "sofa")
                    }
                    .buttonStyle(.dbSecondary)
                }
            case "QUEUED", "RUNNING":
                HStack(spacing: 10) {
                    ProgressView()
                    Text(progressText).font(.subheadline).foregroundStyle(DB.ink)
                }
                Text("촬영본으로 3D 공간을 만드는 중입니다. 완료되면 이 화면에서 바로 둘러볼 수 있어요.")
                    .font(.caption).foregroundStyle(DB.sub)
            case "FAILED":
                Label("3D 생성에 실패했습니다", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(DB.danger)
                Text(isOwner ? "공간을 다시 촬영해 주세요." : "중개사에게 재촬영을 요청해 주세요.")
                    .font(.caption).foregroundStyle(DB.sub)
            default:
                Text("아직 3D 공간이 없는 매물입니다. 사진으로만 제공됩니다.")
                    .font(.subheadline).foregroundStyle(DB.sub)
            }
            if isOwner {
                Button {
                    showCapture = true
                } label: {
                    Label(l.isSpaceReady ? "공간 다시 촬영" : "공간 촬영하기", systemImage: "camera.viewfinder")
                }
                .buttonStyle(.dbSecondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DB.group, in: RoundedRectangle(cornerRadius: 16))
    }

    private func spaceSummary(_ s: SpaceResponse) -> some View {
        let room = Room(space: s)
        let d = s.roomDimensions
        let w = d?.width ?? room.width, dp = d?.depth ?? room.depth
        let h = d?.height ?? (room.ceilingY - room.floorY)
        return VStack(alignment: .leading, spacing: 10) {
            InfoRow(label: "가로 × 세로", value: String(format: "%.2f × %.2f m", w, dp))
            InfoRow(label: "층고", value: Fmt.m(h))
            InfoRow(label: "실측 면적", value: Fmt.area(d?.area ?? w * dp))
            InfoRow(label: "문 / 창문", value: "\(room.doors.count) / \(room.windows.count)")
            InfoRow(label: "인식된 가구", value: "\(s.objects.count)개")
        }
    }

    private var progressText: String {
        guard let j = job else { return "3D 생성 대기 중" }
        let pct = j.percent.map { " \($0)%" } ?? ""
        return "3D 생성 중 · \(j.status)\(pct)"
    }

    private func agentRow(_ a: AgentSummary) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.fill").font(.system(size: 40)).foregroundStyle(DB.faint)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(a.officeName ?? a.name ?? "중개사").font(.subheadline.weight(.bold)).foregroundStyle(DB.ink)
                    if a.isVerified { VerifiedBrokerBadge() }
                }
                let line = [a.officeName == nil ? nil : a.name, a.phone].compactMap { $0 }.joined(separator: " · ")
                if !line.isEmpty { Text(line).font(.caption).foregroundStyle(DB.sub) }
                if !a.isVerified {
                    Text("집주인 직접 등록 매물").font(.caption).foregroundStyle(DB.sub)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - 하단 바

    private func bottomBar(_ l: Listing) -> some View {
        HStack(spacing: 12) {
            HeartButton(listingId: l.listingId, framed: true)
            if isOwner {
                Button(l.isSpaceReady ? "공간 다시 촬영" : "공간 촬영하기") { showCapture = true }
                    .buttonStyle(.dbPrimary)
            } else {
                Button {
                    Task { await openChat(l) }
                } label: {
                    if openingChat { ProgressView().tint(Color.white) } else { Text("채팅하기") }
                }
                .buttonStyle(.dbPrimary)
                .disabled(openingChat)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(Color.white.shadow(.drop(color: Color.black.opacity(0.06), radius: 8, y: -2)))
    }

    // MARK: - 동작

    private func openChat(_ l: Listing) async {
        openingChat = true
        defer { openingChat = false }
        do {
            let chatId = try await ChatAPI.open(listingId: l.listingId)
            if isVisible { navigate(.chat(chatId)) }      // 그 사이 화면을 떠났으면 밀어 넣지 않는다
        } catch {
            actionError = error.userMessage
        }
    }

    /// followJob: 3D 생성 중이면 끝날 때까지 진행률을 보여 준 뒤 한 번만 다시 불러온다
    private func load(followJob: Bool = true) async {
        do {
            let l = try await ListingAPI.get(listingId)
            listing = l
            loadError = nil
            session.recordView(l)
            if l.isSpaceReady {
                await reloadSpaceCard()
            } else if followJob, let jobId = l.space3DInfo?.jobId,
                      ["QUEUED", "RUNNING"].contains(l.space3DInfo?.status ?? "") {
                _ = try await JobAPI.wait(jobId, every: 5) { j in job = j }
                await load(followJob: false)
            }
        } catch {
            if error.isCancellation { return }
            if listing == nil { loadError = error.userMessage } else { actionError = error.userMessage }
        }
    }

    /// 3D 카드: 공간 정보와 내 입주 상태를 함께 받아 한 번에 바꾼다 (버튼이 깜빡이지 않게).
    /// 입주 상태는 만든 사람만 보므로 3D 화면에서 새로 만들거나 중개사가 가구 구분을 바꾸고 돌아왔을 때도 다시 받는다
    private func reloadSpaceCard() async {
        guard listing?.isSpaceReady == true else { return }
        let s = try? await ListingAPI.space(listingId)
        let rs = await RoomStateAPI.latestReady(listingId: listingId, spaceVersion: s?.spaceVersion)
        if let s { space = s }
        myRoomState = rs
    }
}

// MARK: - 사진 넘기기

/// 위: 사진 페이지 · 오른쪽 아래 "1 / 8" · 아래 썸네일 줄 (데모와 같은 배치)
struct PhotoCarousel: View {
    let uris: [String]
    @State private var index = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            if uris.isEmpty {
                ZStack {
                    DB.field
                    VStack(spacing: 8) {
                        Image(systemName: "photo").font(.largeTitle)
                        Text("등록된 사진이 없습니다").font(.caption)
                    }
                    .foregroundStyle(DB.faint)
                }
            } else {
                TabView(selection: $index) {
                    ForEach(uris.indices, id: \.self) { i in
                        RemoteImage(uri: uris[i]).tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }

            // 상단 그라데이션: 투명 내비게이션 바의 버튼이 사진 위에서도 보이게
            LinearGradient(colors: [Color.black.opacity(0.35), Color.clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 120)
                .frame(maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)

            if !uris.isEmpty {
                VStack(alignment: .trailing, spacing: 8) {
                    Text("\(index + 1) / \(uris.count)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.black.opacity(0.45), in: Capsule())
                        .padding(.trailing, 14)
                    if uris.count > 1 { thumbnails }
                }
                .padding(.bottom, 12)
            }
        }
        .frame(height: 340)
        .frame(maxWidth: .infinity)
        .clipped()
    }

    private var thumbnails: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(uris.indices, id: \.self) { i in
                        Button {
                            withAnimation { index = i }
                        } label: {
                            RemoteImage(uri: uris[i])
                                .frame(width: 54, height: 42)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white, lineWidth: i == index ? 2 : 0))
                                .opacity(i == index ? 1 : 0.7)
                        }
                        .buttonStyle(.plain)
                        .id(i)
                    }
                }
                .padding(.horizontal, 14)
            }
            .onChange(of: index) { _, i in
                withAnimation { proxy.scrollTo(i, anchor: .center) }
            }
        }
    }
}

// MARK: - 신고

struct ReportSheet: View {
    let listingId: String
    @Environment(\.dismiss) private var dismiss
    @State private var reason = ReportSheet.reasons[0]
    @State private var detail = ""
    @State private var busy = false
    @State private var error: String?
    @State private var done = false

    static let reasons = ["허위 매물이에요", "실제 공간과 사진·3D 가 달라요", "가격 정보가 달라요", "이미 거래된 매물이에요", "기타"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("매물 신고").font(.title2.weight(.bold)).foregroundStyle(DB.ink)
                        Text("신고 내용은 관리자가 확인한 뒤 조치합니다.").font(.subheadline).foregroundStyle(DB.sub)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Self.reasons, id: \.self) { r in
                            Button {
                                reason = r
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: reason == r ? "largecircle.fill.circle" : "circle")
                                        .font(.title3)
                                        .foregroundStyle(reason == r ? DB.purple : DB.faint)
                                    Text(r).font(.subheadline).foregroundStyle(DB.ink)
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    FieldBlock(title: "자세한 내용 (선택)") {
                        TextEditor(text: $detail)
                            .frame(minHeight: 120)
                            .scrollContentBackground(.hidden)
                            .padding(10)
                            .background(DB.field, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding(24)
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    Task { await submit() }
                } label: {
                    if busy { ProgressView().tint(Color.white) } else { Text("신고하기") }
                }
                .buttonStyle(.dbPrimary)
                .disabled(busy)
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
                .background(Color.white)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } }
            }
            .alert("신고가 접수되었습니다", isPresented: $done) {
                Button("확인") { dismiss() }
            }
            .errorAlert($error)
        }
    }

    private func submit() async {
        busy = true
        defer { busy = false }
        do {
            try await ListingAPI.report(listingId, reason: reason, detail: detail.trimmed.isEmpty ? nil : detail.trimmed)
            done = true
        } catch {
            self.error = error.userMessage
        }
    }
}
