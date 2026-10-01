import SwiftUI

/// 가구로 매물 비교 (마이페이지 · 관심 매물에서 진입):
/// 가져갈 내 가구 + 비교할 매물(관심 매물 우선) → 자동 배치 → 들어가는 매물 · 여유 공간 순 → 누르면 그 배치 그대로 3D 로 확인
struct CompareView: View {
    let preselectedListingIds: [String]
    @EnvironmentObject private var session: Session
    @State private var furniture: [Furniture] = []
    @State private var listings: [Listing] = []
    @State private var pickedFurniture: Set<String> = []
    @State private var pickedListings: Set<String> = []
    @State private var results: [CompareResult] = []
    @State private var fromFavorites = false
    @State private var running = false
    @State private var loading = false
    @State private var error: String?
    @State private var viewer: ViewerRoute?

    init(preselectedListingIds: [String] = []) {
        self.preselectedListingIds = preselectedListingIds
    }

    var body: some View {
        List {
            Section {
                if furniture.isEmpty && !loading {
                    Text("3D 가 준비된 내 가구가 없습니다. 마이페이지 › 내 가구에서 먼저 촬영해 주세요.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(furniture) { f in
                    toggleRow(title: f.label, subtitle: f.dimensions.map { Fmt.dims($0) } ?? "",
                              on: pickedFurniture.contains(f.furnitureId)) { toggle(&pickedFurniture, f.furnitureId) }
                }
            } header: { Text("1. 가져갈 가구") }

            Section {
                if listings.isEmpty && !loading {
                    Text("3D 공간이 준비된 매물이 없습니다.").font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(listings) { l in
                    toggleRow(title: Fmt.price(l), subtitle: l.location,
                              on: pickedListings.contains(l.listingId)) { toggle(&pickedListings, l.listingId) }
                }
            } header: {
                Text(fromFavorites ? "2. 비교할 매물 (관심 매물 중 3D 준비됨)" : "2. 비교할 매물 (3D 준비됨)")
            }

            Section {
                Button {
                    Task { await run() }
                } label: {
                    if running { ProgressView().tint(Color.white) } else { Text("자동 배치해서 비교하기") }
                }
                .buttonStyle(.dbPrimary)
                .disabled(running || pickedFurniture.isEmpty || pickedListings.isEmpty)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)
            }

            if !results.isEmpty {
                Section {
                    ForEach(results) { r in
                        Button {
                            viewer = ViewerRoute(listing: r.listing, roomStateId: r.roomStateId, initialPlacements: r.placements)
                        } label: {
                            ResultRow(result: r)
                        }
                        .buttonStyle(.plain)
                        .disabled(r.errorMessage != nil)
                    }
                } header: {
                    Text("결과 (들어가는 매물 · 여유 공간 순)")
                } footer: {
                    Text("누르면 자동 배치된 그대로 3D 공간에서 확인하고 옮겨 볼 수 있어요.")
                }
            }
        }
        .navigationTitle("가구로 매물 비교")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .overlay { if loading { ProgressView() } }
        .task { await load() }
        .refreshable { await load() }
        .fullScreenCover(item: $viewer) { r in SpaceViewerView(route: r) }
        .errorAlert($error)
    }

    private func toggleRow(title: String, subtitle: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(on ? DB.purple : DB.faint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(DB.ink)
                    if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(DB.sub) }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ set: inout Set<String>, _ id: String) {
        if set.contains(id) { _ = set.remove(id) } else { _ = set.insert(id) }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            furniture = try await FurnitureAPI.mine().filter(\.isReady)
            // 비교 후보: 관심 매물 중 3D 준비된 것 → 없으면 전체 매물 중 3D 준비된 것
            var candidates: [Listing] = []
            if !session.favoriteIds.isEmpty {
                if let scraps = try? await UserAPI.scraps() {
                    candidates = scraps.filter(\.isSpaceReady)
                } else {
                    for id in session.favoriteIds.sorted() {
                        if let l = try? await ListingAPI.get(id), l.isSpaceReady { candidates.append(l) }
                    }
                }
            }
            fromFavorites = !candidates.isEmpty
            if candidates.isEmpty { candidates = try await ListingAPI.list().filter(\.isSpaceReady) }
            listings = candidates
            if pickedFurniture.isEmpty { pickedFurniture = Set(furniture.map(\.furnitureId)) }
            if pickedListings.isEmpty {
                let pre = Set(preselectedListingIds).intersection(candidates.map(\.listingId))
                pickedListings = pre.isEmpty ? Set(candidates.prefix(3).map(\.listingId)) : pre
            }
        } catch {
            if !error.isCancellation { self.error = error.userMessage }
        }
    }

    private func run() async {
        running = true
        defer { running = false }
        results = await CompareEngine.run(listings: listings.filter { pickedListings.contains($0.listingId) },
                                          furniture: furniture.filter { pickedFurniture.contains($0.furnitureId) })
    }
}

private struct ResultRow: View {
    let result: CompareResult
    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(uri: result.listing.coverUri, placeholderIcon: "house")
                .frame(width: 60, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: result.fits ? "checkmark.seal.fill" : "xmark.seal.fill")
                        .foregroundStyle(result.fits ? Color.green : DB.danger)
                    Text(result.fits ? "모두 들어감" : "안 들어감").font(.subheadline.weight(.bold))
                    Spacer(minLength: 0)
                    Text(Fmt.price(result.listing)).font(.caption.weight(.semibold))
                }
                Text(result.listing.location).font(.caption).foregroundStyle(DB.sub).lineLimit(1)
                if let e = result.errorMessage {
                    Text(e).font(.caption).foregroundStyle(DB.danger)
                } else if result.fits {
                    Text(String(format: "배치 후 여유 바닥 %.1f㎡", result.freeArea)).font(.caption).foregroundStyle(DB.ink)
                } else {
                    Text("안 들어가는 가구: " + result.blocked.joined(separator: ", ")).font(.caption).foregroundStyle(DB.danger)
                }
            }
        }
        .contentShape(Rectangle())
    }
}
