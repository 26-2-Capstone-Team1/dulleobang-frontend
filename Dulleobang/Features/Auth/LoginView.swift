import SwiftUI

/// 로그인 (와이어프레임 첫 화면): 로고 · 집 일러스트 · "공간의 구조부터 분위기까지" · 카카오 / Google / 이메일로 시작하기
/// 카카오 · 구글은 SDK 토큰을 서버가 검증한다(POST /auth/oauth/{provider}). SDK 는 앱 키가 필요해서,
/// 데모 모드에서는 가입 시트(이름 · 이메일 + 약관 동의)로 대신한다. 이메일은 가입 · 로그인(비밀번호 12자 이상).
struct LoginView: View {
    @EnvironmentObject private var session: Session
    @State private var signup: LoginProvider?
    @State private var showEmail = false
    @State private var socialBusy: LoginProvider?
    @State private var error: String?
    @State private var showSettings = false
    @AppStorage(AppConfig.useMockDataKey) private var demoMode = AppConfig.useMockDataDefault

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                LogoView(size: 16)
                Spacer()
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape").font(.body).foregroundStyle(DB.faint).padding(8)
                }
                .accessibilityLabel("서버 설정")
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)

            Spacer()
            HouseIllustration().frame(width: 164, height: 164)
            Text("공간의 구조부터 분위기까지,\n한눈에 확인하세요")
                .font(.title3.weight(.bold))
                .multilineTextAlignment(.center)
                .foregroundStyle(DB.ink)
                .padding(.top, 28)
            Text("3D 로 둘러보고, 내 가구를 실제 크기로 놓아 보세요")
                .font(.subheadline)
                .foregroundStyle(DB.sub)
                .padding(.top, 8)
            Spacer()

            VStack(spacing: 12) {
                Button { startSocial(.kakao) } label: {
                    HStack(spacing: 8) {
                        if socialBusy == .kakao { ProgressView() } else { Image(systemName: "message.fill") }
                        Text("카카오로 시작하기")
                    }
                    .font(.body.weight(.bold))
                    .foregroundStyle(Color.black.opacity(0.85))
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(DB.kakao, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)

                Button { startSocial(.google) } label: {
                    HStack(spacing: 8) {
                        if socialBusy == .google {
                            ProgressView()
                        } else {
                            Text("G").font(.headline.weight(.heavy)).foregroundStyle(Color(rgb: 66, 133, 244))
                        }
                        Text("Google로 시작하기").font(.body.weight(.semibold)).foregroundStyle(DB.ink)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(DB.line))
                }
                .buttonStyle(.plain)

                Button { showEmail = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "envelope.fill")
                        Text("이메일로 시작하기")
                    }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(DB.ink)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(DB.field, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)

                if demoMode {
                    Text("데모 모드 · 카카오 · 구글은 아무 이름과 이메일로, 이메일은 새로 가입해서 예시 매물을 둘러볼 수 있어요")
                        .font(.caption)
                        .foregroundStyle(DB.sub)
                        .multilineTextAlignment(.center)
                        .padding(.top, 2)
                }

                #if DEBUG
                Button("로그인 없이 시작 (개발용)") { session.devLogin() }
                    .font(.footnote)
                    .foregroundStyle(DB.sub)
                    .padding(.top, 4)
                #endif
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
        .background(Color.white.ignoresSafeArea())
        .sheet(item: $signup) { p in
            DemoSignupSheet(provider: p)
        }
        .sheet(isPresented: $showEmail) {
            EmailAuthSheet().presentationDetents([.large])
        }
        .errorAlert($error)
        .overlay(alignment: .top) {                          // "로그인이 만료되었습니다" 같은 안내
            if let t = session.toast {
                ToastView(text: t)
                    .padding(.top, 56)
                    .task(id: t) {
                        try? await Task.sleep(for: .seconds(3))
                        if session.toast == t { session.toast = nil }
                    }
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack { DeveloperSettingsView() }
        }
    }
}

extension LoginView {
    /// 데모 모드는 가입 시트, 실제 서버면 SDK 로 토큰을 받아 서버에 보낸다
    private func startSocial(_ provider: LoginProvider) {
        if demoMode {
            signup = provider
            return
        }
        guard socialBusy == nil else { return }
        socialBusy = provider
        Task {
            defer { socialBusy = nil }
            do {
                let token = try await SocialLogin.token(for: provider)
                try await session.loginSocial(provider, token: token)
            } catch {
                if !error.isCancellation { self.error = error.userMessage }
            }
        }
    }
}

/// 이메일 가입 · 로그인. 비밀번호는 명세 v1 대로 12~128자 (앞뒤 공백도 비밀번호의 일부)
struct EmailAuthSheet: View {
    enum Mode: String, CaseIterable { case login = "로그인", signup = "회원가입" }

    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .login
    @AppStorage("lastLoginEmail") private var email = ""
    @AppStorage("lastLoginName") private var name = ""
    @State private var password = ""
    @State private var passwordAgain = ""
    @State private var terms = false
    @State private var privacy = false
    @State private var busy = false
    @State private var error: String?

    static let passwordRange = 12...128

    private var emailOK: Bool { let e = email.trimmed; return e.contains("@") && e.contains(".") }
    private var passwordOK: Bool { Self.passwordRange.contains(password.count) }
    private var canSubmit: Bool {
        guard emailOK, !busy else { return false }
        switch mode {
        case .login: return !password.isEmpty
        case .signup: return passwordOK && password == passwordAgain && !name.trimmed.isEmpty && terms && privacy
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Picker("방식", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    FieldBlock(title: "이메일") {
                        DBTextField(placeholder: "example@cau.ac.kr", text: $email, keyboard: .emailAddress)
                    }
                    FieldBlock(title: "비밀번호", subtitle: mode == .signup ? "12자 이상" : nil) {
                        DBSecureField(placeholder: "비밀번호", text: $password, isNew: mode == .signup)
                    }
                    if mode == .signup {
                        if !password.isEmpty && !passwordOK {
                            Text("비밀번호는 12자 이상 128자 이하로 입력해 주세요").font(.caption).foregroundStyle(DB.danger)
                        }
                        FieldBlock(title: "비밀번호 확인") {
                            DBSecureField(placeholder: "한 번 더 입력", text: $passwordAgain, isNew: true)
                        }
                        if !passwordAgain.isEmpty && password != passwordAgain {
                            Text("비밀번호가 서로 다릅니다").font(.caption).foregroundStyle(DB.danger)
                        }
                        FieldBlock(title: "이름") { DBTextField(placeholder: "화면에 보일 이름", text: $name) }
                        VStack(alignment: .leading, spacing: 12) {
                            CheckRow(label: "서비스 이용약관 (필수)", checked: terms) { terms.toggle() }
                            CheckRow(label: "개인정보 수집·이용 동의 (필수)", checked: privacy) { privacy.toggle() }
                        }
                    }
                }
                .padding(24)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) {
                Button {
                    Task { await submit() }
                } label: {
                    if busy { ProgressView().tint(Color.white) } else { Text(mode == .login ? "로그인" : "가입하고 시작하기") }
                }
                .buttonStyle(.dbPrimary)
                .disabled(!canSubmit)
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
                .background(Color.white)
            }
            .navigationTitle("이메일로 시작하기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } }
            }
            .errorAlert($error)
        }
    }

    private func submit() async {
        busy = true
        defer { busy = false }
        do {
            switch mode {
            case .login: try await session.loginEmail(email: email.trimmed, password: password)
            case .signup: try await session.signupEmail(email: email.trimmed, password: password, name: name.trimmed)
            }
            dismiss()
        } catch let e as APIError where e.status == 401 {
            self.error = "이메일 또는 비밀번호가 맞지 않습니다."
        } catch let e as APIError where e.status == 409 {
            self.error = "이미 가입된 이메일입니다. 로그인해 주세요."
            mode = .login
        } catch {
            self.error = error.validationAwareMessage(hint: mode == .signup
                ? "이메일 형식을 확인해 주세요. 비밀번호는 12~128자, 이름은 40자까지 쓸 수 있습니다."
                : "이메일 형식과 비밀번호를 확인해 주세요.")
        }
    }
}

/// 비밀번호 입력 칸 (DBTextField 와 같은 모양)
struct DBSecureField: View {
    let placeholder: String
    @Binding var text: String
    var isNew = false

    var body: some View {
        SecureField(placeholder, text: $text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textContentType(isNew ? .newPassword : .password)
            .font(.body)
            .padding(.horizontal, 16)
            .frame(height: 50)
            .background(DB.field, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// 초록 집 + 3D 큐브 배지
struct HouseIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                Circle().fill(DB.accentSoft)
                Image(systemName: "house.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: s * 0.5, height: s * 0.5)
                    .foregroundStyle(DB.accent)
                Image(systemName: "cube.transparent")
                    .font(.system(size: s * 0.16, weight: .semibold))
                    .foregroundStyle(DB.accent)
                    .padding(s * 0.06)
                    .background(Color.white, in: Circle())
                    .shadow(color: Color.black.opacity(0.12), radius: 6, y: 3)
                    .offset(x: s * 0.3, y: s * 0.28)
            }
            .frame(width: s, height: s)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// 회원가입 (정보구조도의 "개인정보 동의" 3개 필수 항목)
struct DemoSignupSheet: View {
    let provider: LoginProvider
    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss
    @AppStorage("lastLoginName") private var name = ""
    @AppStorage("lastLoginEmail") private var email = ""
    @State private var terms = false
    @State private var privacy = false
    @State private var thirdParty = false
    @State private var busy = false
    @State private var error: String?

    private var allAgreed: Bool { terms && privacy && thirdParty }
    private var canSubmit: Bool { allAgreed && !name.trimmed.isEmpty && email.contains("@") && !busy }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(provider.title)로 시작하기").font(.title2.weight(.bold)).foregroundStyle(DB.ink)
                        Text("데모 버전에서는 \(provider.title) 계정 대신 이름과 이메일로 가입합니다.")
                            .font(.subheadline).foregroundStyle(DB.sub)
                    }
                    FieldBlock(title: "이름") { DBTextField(placeholder: "입력하기", text: $name) }
                    FieldBlock(title: "이메일") {
                        DBTextField(placeholder: "example@cau.ac.kr", text: $email, keyboard: .emailAddress)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        Text("개인정보 동의").font(.title3.weight(.bold)).foregroundStyle(DB.ink)
                        CheckRow(label: "전체 동의", checked: allAgreed, bold: true) {
                            let v = !allAgreed
                            terms = v
                            privacy = v
                            thirdParty = v
                        }
                        Divider()
                        CheckRow(label: "서비스 이용약관 (필수)", checked: terms) { terms.toggle() }
                        CheckRow(label: "개인정보 수집·이용 동의 (필수)", checked: privacy) { privacy.toggle() }
                        CheckRow(label: "제3자 정보제공 동의 (필수)", checked: thirdParty) { thirdParty.toggle() }
                    }
                }
                .padding(24)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) {
                Button {
                    Task { await submit() }
                } label: {
                    if busy { ProgressView().tint(Color.white) } else { Text("동의하고 시작하기") }
                }
                .buttonStyle(.dbPrimary)
                .disabled(!canSubmit)
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
                .background(Color.white)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } }
            }
            .errorAlert($error)
        }
    }

    private func submit() async {
        busy = true
        defer { busy = false }
        do {
            try await session.loginDemoSocial(provider, name: name.trimmed, email: email.trimmed)
            dismiss()
        } catch {
            self.error = error.userMessage
        }
    }
}
