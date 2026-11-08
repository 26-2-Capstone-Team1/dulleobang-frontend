import SwiftUI

/// 홈 (데모 1번째 화면): 로고 · 검색 · 빠른 필터 칩 · 최근 본 매물(옆으로 넘기기) · 내 가구 비교 바로가기 · 새로 올라온 매물 (2열 큰 사진 카드).
/// 추천 기능은 두지 않는다 (팀 결정): 최신순 목록에 사용자가 필터만 건다
struct HomeView: View {
    var body: some View { TabStack { HomeContent() } }
}

private struct HomeContent: View {
    @EnvironmentObject private var session: Session
    @Environment(\.navigate) private var navigate
    @State private var searchText = ""
    @State private var latest: [Listing] = []
    @State private var filter = ListingQuery()
    @State private var showFilter = false
    @State private var loading = false
    @State private var loadError: String?
    @AppStorage(AppConfig.useMockDataKey) private var demoMode = AppConfig.useMockDataDefault
    @State private var loadedKey: LoadKey?

    /// 데모 모드 전환 · 필터 변경 때만 다시 불러온다 (당겨서 새로고침은 따로)
    private struct LoadKey: Hashable { var demo: Bool; var filter: ListingQuery }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 2)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    LogoView()
                    if demoMode {
                        NavigationLink(value: AppRoute.settings) { DemoBadge() }
                            .buttonStyle(.plain)
                            .accessibilityLabel("데모 모드 설정")
                    }
                    Spacer()
                    if session.isLoggedIn {             // 집주인도 본인 집을 올릴 수 있다 (중개사 인증은 선택)
                        Button("매물 등록") { navigate(.register) }.buttonStyle(.dbPill(filled: true))
                    }
                }
                .padding(.horizontal, 20)
                SearchField(placeholder: "지역, 매물 유형 검색", text: $searchText) { search() }
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                QuickFilterBar(query: $filter)          // 3D로 보기 · 월세 · 전세 · 방 종류 (아래 목록에 바로 반영)
                    .padding(.top, 12)

                if !session.recent.isEmpty {
                    Text("최근 본 매물").font(.title3.weight(.bold)).foregroundStyle(DB.ink)
                        .padding(.horizontal, 20)
                        .padding(.top, 24)
                        .padding(.bottom, 10)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 10) {
                            ForEach(session.recent) { l in
                                NavigationLink(value: AppRoute.listing(l.listingId)) { ListingMiniCard(listing: l) }
                                    .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                }

                CompareBanner()                         // 둘러방만의 기능: 내 가구가 들어가는 방 찾기
                    .padding(.horizontal, 20)
                    .padding(.top, 22)

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("새로 올라온 매물").font(.title3.weight(.bold)).foregroundStyle(DB.ink)
                        Spacer()
                        FilterButton(active: filter.hasPriceLimit) { showFilter = true }
                    }
                    if loading && latest.isEmpty {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 30)
                    } else if let loadError, latest.isEmpty {
                        VStack(spacing: 10) {
                            EmptyStateView(icon: "wifi.exclamationmark", title: "매물을 불러오지 못했습니다", message: loadError)
                            Button("다시 시도") {
                                Task {
                                    await load()
                                    // 이 분기에서는 loadError 가 if-let 으로 가려져 있으므로 self 로 상태를 본다
                                    if self.loadError == nil { loadedKey = LoadKey(demo: demoMode, filter: filter) }
                                }
                            }
                            .buttonStyle(.dbPill())
                        }
                    } else if latest.isEmpty {
                        VStack(spacing: 10) {
                            EmptyStateView(icon: "house", title: filter.isFiltered ? "조건에 맞는 매물이 없습니다" : "등록된 매물이 없습니다",
                                           message: filter.isFiltered ? "칩을 해제하거나 필터를 바꿔 보세요." : nil)
                            if filter.isFiltered {
                                Button("조건 모두 해제") { filter = ListingQuery() }.buttonStyle(.dbPill())
                            }
                        }
                    } else {
                        grid(latest)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 26)
            }
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.immediately)
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await load() }
        .task(id: LoadKey(demo: demoMode, filter: filter)) {
            let key = LoadKey(demo: demoMode, filter: filter)
            guard latest.isEmpty || loadedKey != key else { return }
            if loadedKey != key { latest = [] }            // 다른 조건의 결과를 새 필터 밑에 남겨 두지 않는다
            await load()
            if loadError == nil { loadedKey = key }
        }
        .sheet(isPresented: $showFilter) {
            FilterSheet(query: $filter).presentationDetents([.large])
        }
    }

    /// 2열 큰 사진 카드 (♡ 는 사진 위)
    private func grid(_ items: [Listing]) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
            ForEach(items) { l in ListingTile(listing: l) }
        }
    }

    private func search() {
        let text = searchText.trimmed
        guard !text.isEmpty else { return }
        navigate(.search(ListingQuery.parse(text)))
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            latest = try await ListingAPI.list(filter)            // 서버 기본 정렬 = 최신순
            loadError = nil
        } catch {
            if !error.isCancellation { loadError = error.userMessage }
        }
    }
}

// MARK: - 검색 결과

struct SearchResultsView: View {
    @State private var query: ListingQuery
    @State private var text: String
    @State private var items: [Listing] = []
    @State private var loading = false
    @State private var loadError: String?
    @State private var showFilter = false

    init(initialQuery: ListingQuery) {
        _query = State(initialValue: initialQuery)
        let words = [initialQuery.text,
                     initialQuery.dealType.map { $0 == "JEONSE" ? "전세" : "월세" },
                     initialQuery.roomType.map { Fmt.roomType($0) }]
        _text = State(initialValue: words.compactMap { $0 }.joined(separator: " "))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                SearchField(placeholder: "지역, 매물 유형 검색", text: $text) { resubmit() }
                FilterButton(active: query.isFiltered) { showFilter = true }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Text(loading && items.isEmpty ? "검색 중…" : "검색 결과 \(items.count)건")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(DB.sub)
                        .padding(.vertical, 8)
                    if let loadError, items.isEmpty {
                        EmptyStateView(icon: "wifi.exclamationmark", title: "검색하지 못했습니다", message: loadError)
                    } else if !loading && items.isEmpty {
                        EmptyStateView(icon: "magnifyingglass", title: "조건에 맞는 매물이 없습니다",
                                       message: "지역명을 줄이거나 필터를 초기화해 보세요.")
                    }
                    ForEach(items) { l in
                        ListingRow(listing: l).padding(.vertical, 10)
                        Divider()
                    }
                }
                .padding(.horizontal, 20)
            }
            .scrollDismissesKeyboard(.immediately)
        }
        .navigationTitle("매물 검색")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .task(id: query) { await load() }
        .sheet(isPresented: $showFilter) {
            FilterSheet(query: $query).presentationDetents([.large])
        }
    }

    private func resubmit() {
        var q = ListingQuery.parse(text)
        if q.dealType == nil { q.dealType = query.dealType }
        if q.roomType == nil { q.roomType = query.roomType }
        q.maxDeposit = query.maxDeposit
        q.maxMonthly = query.maxMonthly
        q.spaceOnly = query.spaceOnly
        query = q
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            items = try await ListingAPI.list(query)
            loadError = nil
        } catch {
            if !error.isCancellation { loadError = error.userMessage }
        }
    }
}

/// 필터 버튼 (조건이 걸려 있으면 초록)
struct FilterButton: View {
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "slider.horizontal.3")
                Text("필터")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(active ? Color.white : DB.ink)
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(active ? DB.accent : Color.white, in: Capsule())
            .overlay(Capsule().stroke(active ? Color.clear : DB.line))
        }
        .buttonStyle(.plain)
    }
}

/// 필터: 3D 공간 · 거래 유형 · 방 종류 · 보증금 · 월세
struct FilterSheet: View {
    @Binding var query: ListingQuery
    @State private var draft = ListingQuery()
    @Environment(\.dismiss) private var dismiss

    static let depositSteps: [Int?] = [nil, 500, 1000, 3000, 5000, 10000, 20000]
    static let monthlySteps: [Int?] = [nil, 30, 40, 50, 60, 80, 100]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    FieldBlock(title: "3D 공간") {
                        FlowStack {
                            Chip(label: "전체", selected: !draft.spaceOnly) { draft.spaceOnly = false }
                            Chip(label: "3D로 볼 수 있는 방만", selected: draft.spaceOnly) { draft.spaceOnly = true }
                        }
                    }
                    FieldBlock(title: "거래 유형") {
                        FlowStack {
                            Chip(label: "전체", selected: draft.dealType == nil) { draft.dealType = nil }
                            Chip(label: "월세", selected: draft.dealType == "MONTHLY") { draft.dealType = "MONTHLY" }
                            Chip(label: "전세", selected: draft.dealType == "JEONSE") {
                                draft.dealType = "JEONSE"
                                draft.maxMonthly = nil
                            }
                        }
                    }
                    FieldBlock(title: "방 종류") {
                        FlowStack {
                            Chip(label: "전체", selected: draft.roomType == nil) { draft.roomType = nil }
                            ForEach(Fmt.roomTypes.indices, id: \.self) { i in
                                Chip(label: Fmt.roomTypes[i].label, selected: draft.roomType == Fmt.roomTypes[i].key) {
                                    draft.roomType = Fmt.roomTypes[i].key
                                }
                            }
                        }
                    }
                    FieldBlock(title: "보증금") {
                        FlowStack {
                            ForEach(Self.depositSteps.indices, id: \.self) { i in
                                let v = Self.depositSteps[i]
                                Chip(label: v.map { "\(Fmt.won($0)) 이하" } ?? "전체", selected: draft.maxDeposit == v) {
                                    draft.maxDeposit = v
                                }
                            }
                        }
                    }
                    if draft.dealType != "JEONSE" {
                        FieldBlock(title: "월세") {
                            FlowStack {
                                ForEach(Self.monthlySteps.indices, id: \.self) { i in
                                    let v = Self.monthlySteps[i]
                                    Chip(label: v.map { "\($0)만 이하" } ?? "전체", selected: draft.maxMonthly == v) {
                                        draft.maxMonthly = v
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(24)
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 10) {
                    Button("초기화") {
                        draft.dealType = nil
                        draft.roomType = nil
                        draft.maxDeposit = nil
                        draft.maxMonthly = nil
                        draft.spaceOnly = false
                    }
                    .buttonStyle(.dbSecondary)
                    .frame(width: 110)
                    Button("적용하기") {
                        query = draft
                        dismiss()
                    }
                    .buttonStyle(.dbPrimary)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
                .background(Color.white)
            }
            .navigationTitle("필터")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } }
            }
            .onAppear { draft = query }
        }
    }
}
