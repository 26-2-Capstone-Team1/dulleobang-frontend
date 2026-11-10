import MapKit
import SwiftUI

/// 둘러보기 (데모 2번째 화면): 위쪽 빠른 필터 칩 · 지도 위 가격 말풍선(3D 매물은 초록) · 핀을 누르면 미리보기 카드 · 아래 매물 시트 ("이 지역 매물 N건")
/// 좌표는 서버의 latitude/longitude 를 쓰고, 없으면 주소를 기기에서 지오코딩한다.
struct BrowseMapView: View {
    var body: some View { TabStack { BrowseMapContent() } }
}

enum SheetDetent: Hashable { case collapsed, half, full }

/// 지도에 찍을 매물 하나
struct ListingPin {
    let listing: Listing
    let coordinate: CLLocationCoordinate2D
}

/// 가까운 매물 묶음 (확대하면 풀린다)
struct MapCluster: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let pins: [ListingPin]
}

private struct BrowseMapContent: View {
    @Environment(\.navigate) private var navigate
    @State private var camera: MapCameraPosition = .region(BrowseMapContent.defaultRegion)
    @State private var region: MKCoordinateRegion = BrowseMapContent.defaultRegion
    /// 지도에 보이는 범위(조금 넓게)를 서버 검색 조건으로 보낸다 (팀 결정: 지도 범위 검색)
    @State private var query = ListingQuery(bounds: BrowseMapContent.bounds(for: BrowseMapContent.defaultRegion))
    @State private var listings: [Listing] = []
    @State private var geocoded: [String: CLLocationCoordinate2D] = [:]
    @State private var sheet: SheetDetent = .half
    @State private var loading = false
    @State private var loadError: String?
    @State private var showFilter = false
    @State private var selectedId: String?          // 누른 핀 (미리보기 카드)

    /// 중앙대 서울캠퍼스 주변 (흑석동·상도동)
    static let defaultRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.5051, longitude: 126.9571),
        span: MKCoordinateSpan(latitudeDelta: 0.025, longitudeDelta: 0.025))

    var body: some View {
        let pins = allPins
        let visible = pins.filter { isInside(region, $0.coordinate) }
        let unlocated = listings.filter { coordinate(of: $0) == nil }
        let selected = visible.first { $0.listing.listingId == selectedId }
        ZStack(alignment: .top) {
            mapLayer(pins)
            topBar
            BottomSheet(detent: $sheet) {
                sheetHeader(count: visible.count + unlocated.count)
            } content: {
                sheetList(visible: visible, unlocated: unlocated)
            }
            if let selected, sheet == .collapsed {
                // 핀을 누르면 접힌 목록 바로 위에 미리보기 카드 (누르면 상세, ✕ 로 닫기)
                MapPreviewCard(listing: selected.listing,
                               onOpen: { navigate(.listing(selected.listing.listingId)) },
                               onClose: { withAnimation { selectedId = nil } })
                    .padding(.horizontal, 12)
                    .padding(.bottom, BottomSheet<EmptyView, EmptyView>.height(.collapsed, in: 0) + 10)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: selectedId)
        .onChange(of: sheet) { _, d in
            if d != .collapsed { selectedId = nil }        // 목록을 올리면 카드는 닫는다
        }
        .toolbar(.hidden, for: .navigationBar)
        .task(id: query) { await load() }
        .sheet(isPresented: $showFilter) {
            FilterSheet(query: $query).presentationDetents([.large])
        }
    }

    private func mapLayer(_ pins: [ListingPin]) -> some View {
        let clusters = Self.cluster(pins, region: region)
        return Map(position: $camera) {
            ForEach(clusters) { c in
                Annotation("", coordinate: c.coordinate, anchor: .bottom) {
                    annotationView(c)
                }
                .annotationTitles(.hidden)          // MapContent 수식어 (Map 이 아니라 Annotation 에 붙인다)
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .mapControls { MapCompass() }
        .onMapCameraChange(frequency: .onEnd) { context in
            region = context.region
            // 조금 움직인 정도로는 다시 부르지 않는다 (지금 보이는 화면이 이전 검색 범위 안이면 그대로)
            if let current = query.bounds, current.contains(Self.bounds(for: context.region, padding: 0)) { return }
            query.bounds = Self.bounds(for: context.region)
        }
        .ignoresSafeArea(edges: .top)
    }

    @ViewBuilder private func annotationView(_ c: MapCluster) -> some View {
        if c.pins.count == 1 {
            let l = c.pins[0].listing
            PriceBubble(listing: l, selected: l.listingId == selectedId)
                .onTapGesture {
                    if selectedId == l.listingId {
                        navigate(.listing(l.listingId))          // 한 번 더 누르면 상세
                    } else {
                        selectedId = l.listingId                 // 처음 누르면 미리보기 카드
                        sheet = .collapsed
                    }
                }
        } else {
            ClusterBubble(count: c.pins.count)
                .onTapGesture {
                    selectedId = nil
                    zoom(into: c)
                }
        }
    }

    /// 빠른 필터 칩(홈과 같음) + 필터 버튼. 불러오는 중이면 아래에 작은 표시
    private var topBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                QuickFilterBar(query: $query, floating: true)
                FilterButton(active: query.hasPriceLimit) { showFilter = true }
                    .shadow(color: Color.black.opacity(0.12), radius: 6, y: 2)
                    .padding(.leading, 4)
                    .padding(.trailing, 16)
            }
            if loading {
                ProgressView().padding(10).background(Color.white, in: Circle()).padding(.leading, 16)
            }
        }
        .padding(.top, 2)
    }

    private func sheetHeader(count: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("이 지역 매물 \(count)건").font(.headline.weight(.bold)).foregroundStyle(DB.ink)
            Spacer()
            if sheet == .collapsed {
                Button { sheet = .half } label: {
                    HStack(spacing: 3) {
                        Text("목록 보기")
                        Image(systemName: "chevron.up")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DB.sub)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 6)
    }

    private func sheetList(visible: [ListingPin], unlocated: [Listing]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let loadError, listings.isEmpty {
                    VStack(spacing: 8) {
                        EmptyStateView(icon: "wifi.exclamationmark", title: "매물을 불러오지 못했습니다", message: loadError)
                        Button("다시 시도") { Task { await load() } }.buttonStyle(.dbPill())
                    }
                } else if !loading && visible.isEmpty && unlocated.isEmpty {
                    EmptyStateView(icon: "map", title: "이 지역에 매물이 없습니다", message: "지도를 옮기거나 필터를 바꿔 보세요.")
                }
                ForEach(visible, id: \.listing.listingId) { p in
                    ListingRow(listing: p.listing).padding(.vertical, 8)
                }
                if !unlocated.isEmpty {
                    Text("위치 확인 중인 매물 \(unlocated.count)건")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(DB.sub)
                        .padding(.top, 12)
                    ForEach(unlocated) { l in
                        ListingRow(listing: l).padding(.vertical, 8)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
    }

    // MARK: - 좌표

    private var allPins: [ListingPin] {
        listings.compactMap { l in coordinate(of: l).map { ListingPin(listing: l, coordinate: $0) } }
    }

    private func coordinate(of l: Listing) -> CLLocationCoordinate2D? {
        if let lat = l.latitude, let lng = l.longitude { return CLLocationCoordinate2D(latitude: lat, longitude: lng) }
        return geocoded[l.listingId]
    }

    private func isInside(_ r: MKCoordinateRegion, _ c: CLLocationCoordinate2D) -> Bool {
        abs(c.latitude - r.center.latitude) <= r.span.latitudeDelta / 2
            && abs(c.longitude - r.center.longitude) <= r.span.longitudeDelta / 2
    }

    /// 보이는 영역보다 사방 25% 넓게 잡아, 조금 움직여도 가장자리 핀이 비지 않게 한다
    static func bounds(for r: MKCoordinateRegion, padding: Double = 0.25) -> GeoBounds {
        let halfLat = r.span.latitudeDelta / 2 * (1 + padding)
        let halfLng = r.span.longitudeDelta / 2 * (1 + padding)
        // 서버는 위도 -90~90, 경도 -180~180 밖의 값을 받지 않는다 (지도를 아주 멀리 축소했을 때)
        return GeoBounds(minLat: max(-90, r.center.latitude - halfLat), maxLat: min(90, r.center.latitude + halfLat),
                         minLng: max(-180, r.center.longitude - halfLng), maxLng: min(180, r.center.longitude + halfLng))
    }

    /// 화면을 7×7 격자로 나눠 같은 칸의 매물을 하나로 묶는다
    static func cluster(_ pins: [ListingPin], region: MKCoordinateRegion) -> [MapCluster] {
        let cellLat = max(region.span.latitudeDelta / 7, 0.0002)
        let cellLng = max(region.span.longitudeDelta / 7, 0.0002)
        var groups: [String: [ListingPin]] = [:]
        var order: [String] = []
        for p in pins {
            let key = "\(Int((p.coordinate.latitude / cellLat).rounded(.down)))_\(Int((p.coordinate.longitude / cellLng).rounded(.down)))"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(p)
        }
        return order.compactMap { key in
            guard let g = groups[key], !g.isEmpty else { return nil }
            let lat = g.reduce(0) { $0 + $1.coordinate.latitude } / Double(g.count)
            let lng = g.reduce(0) { $0 + $1.coordinate.longitude } / Double(g.count)
            let id = g.count == 1 ? g[0].listing.listingId : key
            return MapCluster(id: id, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng), pins: g)
        }
    }

    private func zoom(into c: MapCluster) {
        let span = MKCoordinateSpan(latitudeDelta: max(region.span.latitudeDelta / 3, 0.002),
                                    longitudeDelta: max(region.span.longitudeDelta / 3, 0.002))
        withAnimation { camera = .region(MKCoordinateRegion(center: c.coordinate, span: span)) }
    }

    // MARK: - 불러오기

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            listings = try await ListingAPI.list(query)
            loadError = nil
        } catch {
            if !error.isCancellation { loadError = error.userMessage }
            return
        }
        // 좌표 없는 매물은 주소로 찾는다 (결과는 기기에 캐시)
        for l in listings where !l.hasCoordinate && geocoded[l.listingId] == nil && !l.location.isEmpty {
            if Task.isCancelled { return }
            if let c = await Geocoder.shared.coordinate(for: l.location) { geocoded[l.listingId] = c }
        }
    }
}

/// 지도 가격 말풍선: 동그란 사진 · "3D"/"보/월"/"전세" · "1000/54". 3D 매물은 초록, 누른 핀은 검정으로 조금 크게
struct PriceBubble: View {
    let listing: Listing
    var selected = false

    private var fill: Color { selected ? DB.ink : (listing.isSpaceReady ? DB.accent : Color.white) }
    private var textColor: Color { selected || listing.isSpaceReady ? Color.white : DB.ink }

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 6) {
                RemoteImage(uri: listing.coverUri, placeholderIcon: "house")
                    .frame(width: 30, height: 30)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1.5))
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 2) {
                        if listing.isSpaceReady { Image(systemName: "cube.fill").font(.system(size: 7, weight: .bold)) }
                        Text(listing.isSpaceReady ? "3D" : (Fmt.isJeonse(listing) ? "전세" : "보/월"))
                    }
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(textColor.opacity(0.8))
                    Text(Fmt.priceShort(listing))
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(textColor)
                }
            }
            .padding(.leading, 4)
            .padding(.trailing, 12)
            .padding(.vertical, 4)
            .background(fill, in: Capsule())
            .shadow(color: Color.black.opacity(selected ? 0.35 : 0.2), radius: selected ? 6 : 4, y: 2)
            Circle()
                .fill(selected ? DB.ink : DB.accent)
                .frame(width: 10, height: 10)
                .overlay(Circle().stroke(Color.white, lineWidth: 2))
        }
        .scaleEffect(selected ? 1.12 : 1, anchor: .bottom)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: selected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Fmt.price(listing) + (listing.isSpaceReady ? ", 3D 공간 있음" : ""))
        .accessibilityAddTraits(.isButton)
    }
}

/// 지도에서 핀을 누르면 뜨는 매물 카드: 사진 · 가격 · 방 정보 · 자세히 보기 (카드를 누르면 상세, ✕ 로 닫기, ♡ 저장)
struct MapPreviewCard: View {
    let listing: Listing
    let onOpen: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(uri: listing.coverUri, placeholderIcon: "house")
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .topLeading) {
                    if listing.isSpaceReady { ThreeDBadge().padding(5) }
                }
            VStack(alignment: .leading, spacing: 3) {
                if listing.agent?.isVerified == true { VerifiedBrokerBadge() }
                Text(Fmt.price(listing)).font(.title3.weight(.heavy)).foregroundStyle(DB.ink).lineLimit(1)
                Text(Fmt.cardFacts(listing).ifEmpty(" ")).font(.footnote).foregroundStyle(DB.ink).lineLimit(1)
                Text(Fmt.cardSub(listing)).font(.caption).foregroundStyle(DB.sub).lineLimit(1)
                HStack(spacing: 2) {
                    Text("자세히 보기")
                    Image(systemName: "chevron.right")
                }
                .font(.caption.weight(.bold))
                .foregroundStyle(DB.accent)
                .padding(.top, 2)
            }
            .padding(.trailing, 30)                 // 오른쪽 ✕ · ♡ 자리
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: Color.black.opacity(0.18), radius: 12, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .onTapGesture(perform: onOpen)
        .overlay(alignment: .topTrailing) {
            VStack(spacing: 0) {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(DB.sub)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("카드 닫기")
                Spacer(minLength: 0)
                HeartButton(listingId: listing.listingId, size: 20)
            }
            .padding(4)
        }
        .accessibilityAction(named: "자세히 보기", onOpen)
    }
}


struct ClusterBubble: View {
    let count: Int
    var body: some View {
        Text("\(count)")
            .font(.subheadline.weight(.bold))
            .foregroundStyle(Color.white)
            .frame(width: 40, height: 40)
            .background(DB.accent.opacity(0.9), in: Circle())
            .overlay(Circle().stroke(Color.white, lineWidth: 2))
            .shadow(color: Color.black.opacity(0.2), radius: 4, y: 2)
    }
}

/// 손잡이를 끌어 올리고 내리는 하단 시트 (접힘 · 절반 · 전체)
struct BottomSheet<Header: View, Content: View>: View {
    @Binding var detent: SheetDetent
    let header: Header
    let content: Content
    @GestureState private var dragOffset: CGFloat = 0

    init(detent: Binding<SheetDetent>, @ViewBuilder header: () -> Header, @ViewBuilder content: () -> Content) {
        _detent = detent
        self.header = header()
        self.content = content()
    }

    var body: some View {
        GeometryReader { geo in
            let full = geo.size.height
            let target = Self.height(detent, in: full)
            let h = min(max(target - dragOffset, 90), full)
            VStack(spacing: 0) {
                VStack(spacing: 10) {
                    Capsule().fill(DB.line).frame(width: 40, height: 5).padding(.top, 8)
                    header
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 4, coordinateSpace: .global)
                        .updating($dragOffset) { value, state, _ in state = value.translation.height }
                        .onEnded { value in
                            let projected = target - value.predictedEndTranslation.height
                            let all: [SheetDetent] = [.collapsed, .half, .full]
                            if let best = all.min(by: { abs(Self.height($0, in: full) - projected) < abs(Self.height($1, in: full) - projected) }) {
                                detent = best
                            }
                        }
                )
                content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(height: h, alignment: .top)
            .background(Color.white)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20))
            .shadow(color: Color.black.opacity(0.12), radius: 10, y: -2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .animation(.spring(response: 0.32, dampingFraction: 0.86), value: detent)
        }
    }

    static func height(_ d: SheetDetent, in full: CGFloat) -> CGFloat {
        switch d {
        case .collapsed: return 110
        case .half: return full * 0.45
        case .full: return full * 0.92
        }
    }
}
