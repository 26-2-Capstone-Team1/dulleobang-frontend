import MapKit
import SwiftUI

/// 매물 상세 (데모 "임차인의 매물 보기" 2번째 화면):
/// 사진(+ 3D로 보기 · 평면도) · 표시(3D · 실측 · 인증) · 가격 · 핵심 4칸 · 3D 공간(평면도 · 실측 · 둘러보기 / 입주 예상 / 내 가구) · 상세 정보 · 옵션 아이콘 · 생활 환경 · 위치 · ♡ + 채팅하기
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
                PhotoCarousel(uris: l.photoUris, show3D: l.isSpaceReady,
                              onOpen3D: { open3D(l) }, onOpenPlan: { openPlan(l) })

                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 6) {
                        badges(l)
                        Text(Fmt.price(l)).font(.title.weight(.bold)).foregroundStyle(DB.ink)
                        if !l.location.isEmpty {
                            Text(l.location).font(.subheadline).foregroundStyle(DB.sub)
                        }
                        FactGrid(listing: l).padding(.top, 8)
                    }

                    section("3D 공간") { spaceCard(l) }

                    section("상세 정보") {
                        InfoRow(label: Fmt.dealLabel(l), value: Fmt.priceShort(l))
                        InfoRow(label: "관리비", value: Fmt.fee(l))
                        InfoRow(label: "방종류", value: Fmt.roomType(l.roomType).ifEmpty("-"))
                        InfoRow(label: "해당층/건물층", value: Fmt.floors(l))
                        InfoRow(label: "전용/공급면적", value: Fmt.areas(l))
                        InfoRow(label: "방 수/욕실 수", value: Fmt.roomsBaths(l))
                        InfoRow(label: "입주 가능일", value: Fmt.available(l.availableFrom))
                    }

                    if let opts = l.rentalOptions, !opts.isEmpty {
                        section("옵션") { OptionIconGrid(keys: opts) }
                    }

                    if let env = l.livingEnvironment?.trimmed, !env.isEmpty {
                        section("생활 환경") {
                            Text(env).font(.subheadline).foregroundStyle(DB.ink).fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if let lat = l.latitude, let lng = l.longitude {
                        section("위치") {
                            LocationPreview(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng),
                                            caption: Fmt.shortLocation(l.location))
                        }
                    }

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

    /// 가격 위 표시: 3D · LiDAR 실측 · 인증 중개사
    @ViewBuilder private func badges(_ l: Listing) -> some View {
        let measured = l.isSpaceReady && (space?.roomDimensions != nil || space?.roomGeometry?.walls.isEmpty == false)
        if l.isSpaceReady || l.agent?.isVerified == true {
            HStack(spacing: 6) {
                if l.isSpaceReady { ThreeDBadge() }
                if measured {
                    Label("LiDAR 실측", systemImage: "ruler")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(DB.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(DB.accentSoft, in: Capsule())
                }
                if l.agent?.isVerified == true { VerifiedBrokerBadge() }
            }
        }
    }

    private func open3D(_ l: Listing) {
        viewer = ViewerRoute(listing: l, knownRoomStateId: myRoomState?.roomStateId)
    }

    /// 평면도: 같은 3D 뷰어를 위에서 내려다보는 '평면' 보기로 연다
    private func openPlan(_ l: Listing) {
        var r = ViewerRoute(listing: l, knownRoomStateId: myRoomState?.roomStateId)
        r.startInPlan = true
        viewer = r
    }

    // MARK: - 3D 공간 카드 (둘러방 기능)

    private func spaceCard(_ l: Listing) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            switch l.space3DInfo?.status ?? "NONE" {
            case "COMPLETED":
                HStack(spacing: 12) {
                    MiniFloorPlan(room: space.map { Room(space: $0) })
                        .frame(width: 104, height: 78)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(DB.line))
                        .contentShape(Rectangle())
                        .onTapGesture { openPlan(l) }
                        .accessibilityAddTraits(.isButton)
                    if let s = space {
                        spaceSummary(s)
                    } else {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                }
                Button {
                    open3D(l)
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
        return VStack(alignment: .leading, spacing: 2) {
            Text("LiDAR 실측").font(.caption.weight(.bold)).foregroundStyle(DB.accent)
            Text(String(format: "%.2f × %.2f m", w, dp)).font(.title3.weight(.heavy)).foregroundStyle(DB.ink)
                .lineLimit(1).minimumScaleFactor(0.8)
            Text("층고 \(Fmt.m(h)) · \(Fmt.area(d?.area ?? w * dp))").font(.caption).foregroundStyle(DB.sub)
                .lineLimit(1).minimumScaleFactor(0.8)
            Text("문 \(room.doors.count) · 창 \(room.windows.count) · 가구 \(s.objects.count)개").font(.caption).foregroundStyle(DB.sub)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

/// 사진 넘기기 + 아래 [사진 i/n · 3D로 보기 · 평면도] 칩 (3D 가 준비된 매물만 3D · 평면도). 사진은 옆으로 밀어 넘긴다
struct PhotoCarousel: View {
    let uris: [String]
    var show3D = false
    var onOpen3D: () -> Void = {}
    var onOpenPlan: () -> Void = {}
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

            // 위 · 아래 그라데이션: 투명 내비게이션 바의 버튼과 아래 칩이 사진 위에서도 보이게
            LinearGradient(colors: [Color.black.opacity(0.35), Color.clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 120)
                .frame(maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)
            LinearGradient(colors: [Color.clear, Color.black.opacity(0.3)], startPoint: .top, endPoint: .bottom)
                .frame(height: 90)
                .allowsHitTesting(false)

            HStack(spacing: 7) {
                if !uris.isEmpty {
                    chip(icon: "photo", text: "사진 \(index + 1)/\(uris.count)", fill: Color.black.opacity(0.6), fg: Color.white)
                        .accessibilityLabel("사진 \(uris.count)장 중 \(index + 1)번째")
                }
                if show3D {
                    Button(action: onOpen3D) {
                        chip(icon: "cube.fill", text: "3D로 보기", fill: DB.accent, fg: Color.white)
                            .shadow(color: DB.accent.opacity(0.45), radius: 6, y: 2)
                    }
                    .buttonStyle(.plain)
                    Button(action: onOpenPlan) {
                        chip(icon: "square.split.bottomrightquarter", text: "평면도", fill: Color.white.opacity(0.92), fg: DB.ink)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .frame(height: 320)
        .frame(maxWidth: .infinity)
        .clipped()
    }

    private func chip(icon: String, text: String, fill: Color, fg: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 12, weight: .bold))
            Text(text).font(.footnote.weight(.bold))
        }
        .foregroundStyle(fg)
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(fill, in: Capsule())
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
                                        .foregroundStyle(reason == r ? DB.accent : DB.faint)
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

// MARK: - 상세 조각 (앱 화면 개선)

/// 가격 아래 핵심 4칸: 전용 · 층 · 관리비 · 입주
private struct FactGrid: View {
    let listing: Listing

    var body: some View {
        HStack(spacing: 0) {
            cell("arrow.up.left.and.arrow.down.right", "전용", listing.area.map { Fmt.areaShort($0) } ?? "-")
            divider
            cell("building.2", "층", Fmt.floors(listing))
            divider
            cell("wonsign.circle", "관리비", Fmt.feeShort(listing))
            divider
            cell("calendar", "입주", Fmt.available(listing.availableFrom))
        }
        .padding(.vertical, 10)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(DB.line))
    }

    private var divider: some View { Rectangle().fill(DB.line).frame(width: 1, height: 34) }

    private func cell(_ icon: String, _ label: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(DB.accent)
            Text(label).font(.caption2).foregroundStyle(DB.sub)
            Text(value).font(.caption.weight(.bold)).foregroundStyle(DB.ink).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 2)
        .accessibilityElement(children: .combine)
    }
}

/// 옵션: 아이콘 + 이름 (5칸 격자)
private struct OptionIconGrid: View {
    let keys: [String]
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: 5)

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
            ForEach(keys, id: \.self) { k in
                VStack(spacing: 5) {
                    Image(systemName: Fmt.optionIcon(k))
                        .font(.system(size: 19))
                        .foregroundStyle(DB.ink.opacity(0.8))
                        .frame(width: 46, height: 46)
                        .background(DB.group, in: RoundedRectangle(cornerRadius: 14))
                    Text(Fmt.optionLabel(k)).font(.caption).foregroundStyle(DB.ink).lineLimit(1).minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// 3D 카드의 작은 평면도: 벽(검정) · 문(주황) · 창(하늘) · 가구(회색). 실측 좌표 그대로 위에서 본 모습 (x 오른쪽 · z 아래)
struct MiniFloorPlan: View {
    let room: Room?

    var body: some View {
        Canvas { ctx, size in
            guard let room else { return }
            let minX = room.bboxMin.x, minZ = room.bboxMin.z
            let w = max(room.bboxMax.x - minX, 0.5), d = max(room.bboxMax.z - minZ, 0.5)
            let pad: CGFloat = 8
            let scale = min((size.width - 2 * pad) / CGFloat(w), (size.height - 2 * pad) / CGFloat(d))
            let ox = (size.width - CGFloat(w) * scale) / 2, oy = (size.height - CGFloat(d) * scale) / 2
            func pt(_ x: Double, _ z: Double) -> CGPoint {
                CGPoint(x: ox + CGFloat(x - minX) * scale, y: oy + CGFloat(z - minZ) * scale)
            }
            // 가구: yaw 는 위에서 볼 때 반시계 (도) → 로컬 x 축 = (cos, -sin) 이라 화면에서는 -yaw 만큼 돌린다
            for o in room.objects {
                let c = pt(o.position.x, o.position.z)
                let bw = CGFloat(o.dimensions.width) * scale, bd = CGFloat(o.dimensions.depth) * scale
                let box = Path(roundedRect: CGRect(x: -bw / 2, y: -bd / 2, width: bw, height: bd), cornerRadius: 1.5)
                let t = CGAffineTransform(rotationAngle: -CGFloat(o.rotation.yaw * .pi / 180))
                    .concatenating(CGAffineTransform(translationX: c.x, y: c.y))
                ctx.fill(box.applying(t), with: .color(DB.faint.opacity(0.6)))
            }
            // 벽 (벽 정보가 없으면 방 상자)
            var walls = Path()
            if room.walls.isEmpty {
                walls.addRect(CGRect(origin: pt(minX, minZ), size: CGSize(width: CGFloat(w) * scale, height: CGFloat(d) * scale)))
            }
            for wall in room.walls {
                walls.move(to: pt(wall.from[0], wall.from[1]))
                walls.addLine(to: pt(wall.to[0], wall.to[1]))
            }
            ctx.stroke(walls, with: .color(DB.ink), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            // 문 · 창: 벽 위의 짧은 굵은 선
            for (openings, color) in [(room.doors, Color.orange), (room.windows, Color(rgb: 90, 170, 230))] {
                for o in openings {
                    let c = pt(o.position.x, o.position.z)
                    let a = CGFloat(o.rotation.yaw * .pi / 180)
                    let half = CGFloat(o.dimensions.width) * scale / 2
                    var p = Path()
                    p.move(to: CGPoint(x: c.x - cos(a) * half, y: c.y + sin(a) * half))
                    p.addLine(to: CGPoint(x: c.x + cos(a) * half, y: c.y - sin(a) * half))
                    ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("평면도 미리보기")
    }
}

/// 대략적인 위치: 반경 150 m 원 (정확한 번지는 보이지 않게) · 움직이지 않는 작은 지도
private struct LocationPreview: View {
    let coordinate: CLLocationCoordinate2D
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Map(initialPosition: .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 900, longitudinalMeters: 900)),
                interactionModes: []) {
                MapCircle(center: coordinate, radius: 150)
                    .foregroundStyle(DB.accent.opacity(0.18))
                    .stroke(DB.accent, lineWidth: 1.5)
            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .allowsHitTesting(false)
            Text(caption.isEmpty ? "정확한 위치는 중개사에게 확인하세요" : "\(caption) 부근 · 정확한 위치는 중개사에게 확인하세요")
                .font(.caption).foregroundStyle(DB.sub)
        }
    }
}
