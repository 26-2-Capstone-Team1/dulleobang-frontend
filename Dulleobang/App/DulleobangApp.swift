import SwiftUI

@main
struct DulleobangApp: App {
    @StateObject private var session = Session.shared

    init() {
        SocialLogin.configure()                            // 카카오 SDK 초기화 (앱 키는 Info.plist)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .preferredColorScheme(.light)          // 데모 디자인은 라이트 모드 기준
                .tint(DB.accent)
                .task { await session.refresh() }
                .onOpenURL { url in SocialLogin.handle(url) }   // 카카오톡 · 구글 로그인 뒤 돌아오는 주소
        }
    }
}
