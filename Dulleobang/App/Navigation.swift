import SwiftUI

/// 탭 안에서 push 되는 화면들. 각 탭의 NavigationStack 이 같은 목적지 표를 쓴다 (RouteView).
enum AppRoute: Hashable {
    case listing(String)                // 매물 상세
    case search(ListingQuery)           // 검색 결과
    case chat(String)                   // 채팅방
    case favorites                      // 관심 매물
    case furniture                      // 내 가구
    case compare([String])              // 가구로 매물 비교 (미리 고른 매물 ID)
    case agentVerify                    // 중개인 인증 신청
    case agentInfo                      // 중개사 인증 정보
    case myListings                     // 내가 올린 매물
    case register                       // 매물 등록하기
    case settings                       // 설정 (서버 주소 · 오프라인 촬영 등)
    case notifications                  // 알림
}

struct RouteView: View {
    let route: AppRoute

    var body: some View {
        destination
            .toolbarRole(.editor)            // 다음 화면의 뒤로 버튼을 "<" 만 보이게
    }

    @ViewBuilder private var destination: some View {
        switch route {
        case .listing(let id): ListingDetailView(listingId: id)
        case .search(let q): SearchResultsView(initialQuery: q)
        case .chat(let id): ChatRoomView(chatId: id)
        case .favorites: FavoritesView()
        case .furniture: FurnitureListView()
        case .compare(let ids): CompareView(preselectedListingIds: ids)
        case .agentVerify: AgentVerifyView()
        case .agentInfo: AgentInfoView()
        case .myListings: MyListingsView()
        case .register: ListingRegisterView()
        case .settings: DeveloperSettingsView()
        case .notifications: NotificationsView()
        }
    }
}

/// 하위 화면에서 탭의 경로를 바꾸는 동작 (`@Environment(\.navigate)`)
struct NavigateAction {
    enum Op { case push(AppRoute), replaceTop(AppRoute), pop, popToRoot }
    let perform: (Op) -> Void

    func callAsFunction(_ route: AppRoute) { perform(.push(route)) }
    func replaceTop(_ route: AppRoute) { perform(.replaceTop(route)) }
    func pop() { perform(.pop) }
    func popToRoot() { perform(.popToRoot) }
}

private struct NavigateKey: EnvironmentKey {
    static let defaultValue = NavigateAction(perform: { _ in })
}

extension EnvironmentValues {
    var navigate: NavigateAction {
        get { self[NavigateKey.self] }
        set { self[NavigateKey.self] = newValue }
    }
}

/// 탭 하나의 NavigationStack. 루트 화면과 공용 목적지 표를 묶는다.
struct TabStack<Root: View>: View {
    @State private var path = NavigationPath()
    private let root: Root

    init(@ViewBuilder root: () -> Root) { self.root = root() }

    var body: some View {
        NavigationStack(path: $path) {
            root
                .toolbarRole(.editor)
                .navigationDestination(for: AppRoute.self) { RouteView(route: $0) }
        }
        .environment(\.navigate, NavigateAction { op in
            switch op {
            case .push(let r):
                path.append(r)
            case .replaceTop(let r):
                if !path.isEmpty { path.removeLast() }
                path.append(r)
            case .pop:
                if !path.isEmpty { path.removeLast() }
            case .popToRoot:
                path = NavigationPath()
            }
        })
    }
}

// MARK: - 루트 · 탭

enum MainTab: Hashable { case home, browse, chat, my }

struct RootView: View {
    @EnvironmentObject private var session: Session

    var body: some View {
        Group {
            if session.isLoggedIn { MainTabView() } else { LoginView() }
        }
        .animation(.easeInOut(duration: 0.25), value: session.isLoggedIn)
    }
}

struct MainTabView: View {
    @EnvironmentObject private var session: Session
    @State private var tab: MainTab = .home

    var body: some View {
        TabView(selection: $tab) {
            HomeView()
                .tabItem { Label("홈", systemImage: "house.fill") }
                .tag(MainTab.home)
            BrowseMapView()
                .tabItem { Label("둘러보기", systemImage: "mappin.and.ellipse") }
                .tag(MainTab.browse)
            ChatListView()
                .tabItem { Label("채팅", systemImage: "message.fill") }
                .tag(MainTab.chat)
            MyPageView()
                .tabItem { Label("마이페이지", systemImage: "person.fill") }
                .tag(MainTab.my)
        }
        .overlay(alignment: .top) {
            if let t = session.toast {
                ToastView(text: t)
                    .task(id: t) {
                        try? await Task.sleep(for: .seconds(2))
                        if session.toast == t { session.toast = nil }
                    }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: session.toast)
    }
}
