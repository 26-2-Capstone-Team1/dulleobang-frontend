import SwiftUI

@main
struct DulleobangApp: App {
    @StateObject private var session = Session.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .preferredColorScheme(.light)          // 데모 디자인은 라이트 모드 기준
                .tint(DB.accent)
                .task { await session.refresh() }
        }
    }
}
