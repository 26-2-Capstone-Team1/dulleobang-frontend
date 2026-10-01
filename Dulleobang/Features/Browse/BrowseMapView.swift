import MapKit
import SwiftUI

/// 둘러보기 (데모 2번째 화면): 지도 위 가격 말풍선 + 아래 매물 시트 ("매물 · 총 N건")
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

    /// 중앙대 서울캠퍼스 주변 (흑석동·상도동)
    static let defaultRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.5051, longitude: 126.9571),
        span: MKCoordinateSpan(latitudeDelta: 0.025, longitudeDelta: 0.025))

    var body: some View {
        let pins = allPins
        let visible = pins.filter { isInside(region, $0.coordinate) }
        let unlocated = listings.filter { coordinate(of: $0) == nil }
        ZStack(alignment: .top) {
            mapLayer(pins)
            topBar
            BottomSheet(detent: $sheet) {
                sheetHeader(count: visible.count + unlocated.count)
            } content: {
                sheetList(visible: visible, unlocated: unlocated)
            }
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
            PriceBubble(listing: c.pins[0].listing)
                .onTapGesture { navigate(.listing(c.pins[0].listing.listingId)) }
        } else {
            ClusterBubble(count: c.pins.count)
                .onTapGesture { zoom(into: c) }
        }
    }

    private var topBar: some View {
        HStack {
            if loading { ProgressView().padding(10).background(Color.white, in: Circle()) }
            Spacer()
            FilterButton(active: query.isFiltered) { showFilter = true }
                .shadow(color: Color.black.opacity(0.12), radius: 6, y: 2)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func sheetHeader(count: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("매물").font(.title3.weight(.bold)).foregroundStyle(DB.ink)
            Spacer()
            Text("총 \(count)건").font(.subheadline).foregroundStyle(DB.sub)
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
        return GeoBounds(minLat: r.center.latitude - halfLat, maxLat: r.center.latitude + halfLat,
                         minLng: r.center.longitude - halfLng, maxLng: r.center.longitude + halfLng)
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

/// 지도 가격 말풍선: 동그란 사진 · "보/월" · "1000/54" · 보라 점
struct PriceBubble: View {
    let listing: Listing
    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 6) {
                RemoteImage(uri: listing.coverUri, placeholderIcon: "house")
                    .frame(width: 30, height: 30)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 0) {
                    Text(Fmt.isJeonse(listing) ? "전세" : "보/월")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(DB.sub)
                    Text(Fmt.priceShort(listing))
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(DB.ink)
                }
            }
            .padding(.leading, 4)
            .padding(.trailing, 12)
            .padding(.vertical, 4)
            .background(Color.white, in: Capsule())
            .shadow(color: Color.black.opacity(0.2), radius: 4, y: 2)
            Circle()
                .fill(DB.purple)
                .frame(width: 10, height: 10)
                .overlay(Circle().stroke(Color.white, lineWidth: 2))
        }
    }
}

struct ClusterBubble: View {
    let count: Int
    var body: some View {
        Text("\(count)")
            .font(.subheadline.weight(.bold))
            .foregroundStyle(Color.white)
            .frame(width: 40, height: 40)
            .background(DB.purple.opacity(0.9), in: Circle())
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
