import SwiftUI

// StayView 데모 화면의 디자인 토큰과 공용 컴포넌트.
// 흰 배경 · 보라 포인트 · 연회색 입력칸/카드 · 굵은 한글 제목.

extension Color {
    init(rgb r: Double, _ g: Double, _ b: Double) { self.init(red: r / 255, green: g / 255, blue: b / 255) }
}

enum DB {
    static let purple = Color(rgb: 108, 77, 246)
    static let purpleSoft = Color(rgb: 243, 240, 255)
    static let purpleLine = Color(rgb: 221, 214, 255)
    static let ink = Color(rgb: 28, 28, 30)
    static let sub = Color(rgb: 134, 134, 140)
    static let faint = Color(rgb: 178, 178, 184)
    static let field = Color(rgb: 242, 242, 244)
    static let group = Color(rgb: 247, 247, 249)
    static let line = Color(rgb: 232, 232, 236)
    static let danger = Color(rgb: 232, 72, 85)
    static let kakao = Color(rgb: 254, 229, 0)
    static let logo = Color(rgb: 196, 196, 202)
}

// MARK: - 로고 · 검색

/// 2×2 타일 + 앱 이름 (StayView 로고 형태)
struct LogoView: View {
    var size: CGFloat = 22
    var color: Color = DB.logo

    var body: some View {
        HStack(spacing: size * 0.35) {
            VStack(spacing: size * 0.12) {
                HStack(spacing: size * 0.12) { tile; tile }
                HStack(spacing: size * 0.12) { tile; tile }
            }
            Text(AppConfig.shared.brandName)
                .font(.system(size: size, weight: .heavy))
                .foregroundStyle(color)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AppConfig.shared.brandName)
    }

    private var tile: some View {
        RoundedRectangle(cornerRadius: size * 0.1).fill(color).frame(width: size * 0.44, height: size * 0.44)
    }
}

struct SearchField: View {
    let placeholder: String
    @Binding var text: String
    var cornerRadius: CGFloat = 22
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(DB.faint)
            TextField(placeholder, text: $text)
                .submitLabel(.search)
                .onSubmit(onSubmit)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(DB.faint) }
                    .buttonStyle(.plain)
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(DB.field, in: RoundedRectangle(cornerRadius: cornerRadius))
    }
}

// MARK: - 버튼

/// 보라색 큰 버튼 ("채팅하기", "매물 등록하기", "인증 완료하기")
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.bold))
            .foregroundStyle(Color.white)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(DB.purple.opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.35),
                        in: RoundedRectangle(cornerRadius: 14))
    }
}

/// 연보라 보조 버튼 ("입주 예상 공간", "내 가구 놓아보기")
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.bold))
            .foregroundStyle(DB.purple.opacity(isEnabled ? 1 : 0.4))
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(DB.purpleSoft.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// 작은 알약 버튼. filled = 보라("매물 등록"), dark = 3D 뷰어 헤더("초기화", "평면뷰"), 기본 = 회색("전체 선택")
struct PillButtonStyle: ButtonStyle {
    var filled = false
    var dark = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.bold))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(filled || dark ? Color.white : DB.ink)
            .background(background, in: Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
    private var background: Color { filled ? DB.purple : (dark ? Color.white.opacity(0.16) : DB.field) }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var dbPrimary: PrimaryButtonStyle { PrimaryButtonStyle() }
}
extension ButtonStyle where Self == SecondaryButtonStyle {
    static var dbSecondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}
extension ButtonStyle where Self == PillButtonStyle {
    static func dbPill(filled: Bool = false, dark: Bool = false) -> PillButtonStyle { PillButtonStyle(filled: filled, dark: dark) }
}

// MARK: - 입력 폼

/// 굵은 제목 + (설명) + 내용. 등록/인증 폼의 한 칸
struct FieldBlock<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title3.weight(.bold)).foregroundStyle(DB.ink)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(DB.sub) }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 회색 둥근 입력칸 ("입력하기")
struct DBTextField: View {
    let placeholder: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default

    var body: some View {
        TextField(placeholder, text: $text)
            .keyboardType(keyboard)
            .textInputAutocapitalization(Self.capitalization(for: keyboard))
            .autocorrectionDisabled(keyboard != .default)
            .font(.body)
            .padding(.horizontal, 16)
            .frame(height: 50)
            .background(DB.field, in: RoundedRectangle(cornerRadius: 12))
    }

    /// 이메일·URL 입력은 첫 글자 대문자 자동 변환을 끈다
    static func capitalization(for keyboard: UIKeyboardType) -> TextInputAutocapitalization {
        switch keyboard {
        case .emailAddress, .URL: return .never
        default: return .sentences
        }
    }
}

/// 검정 선택 표시의 분할 버튼 ("공간 촬영 | 이미지 선택", "m² | 평")
struct SegmentedPills<T: Hashable>: View {
    let options: [(value: T, label: String)]
    @Binding var selection: T
    var height: CGFloat = 40

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options.indices, id: \.self) { i in
                let on = selection == options[i].value
                Button { selection = options[i].value } label: {
                    Text(options[i].label)
                        .font(.subheadline.weight(.bold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: height)
                        .foregroundStyle(on ? Color.white : DB.sub)
                        .background(on ? DB.ink : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(DB.field, in: RoundedRectangle(cornerRadius: 13))
    }
}

/// 선택 칩 (필터 · 방 종류). 선택 = 검정
struct Chip: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .frame(height: 36)
                .foregroundStyle(selected ? Color.white : DB.ink)
                .background(selected ? DB.ink : DB.field, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// 체크박스 행 (옵션 선택 · 약관 동의)
struct CheckRow: View {
    let label: String
    let checked: Bool
    var bold = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(checked ? DB.purple : DB.faint)
                Text(label)
                    .font(bold ? Font.body.weight(.bold) : Font.subheadline)
                    .foregroundStyle(DB.ink)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 카드 · 행

/// 마이페이지의 연회색 둥근 묶음
struct GroupCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(DB.group, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct RowDivider: View {
    var body: some View { Rectangle().fill(Color.white).frame(height: 1).padding(.horizontal, 16) }
}

/// "관심 매물 >" 같은 이동 행
struct NavRowLabel: View {
    let title: String
    var value: String? = nil
    var valueColor: Color = DB.ink
    var titleColor: Color = DB.ink
    var showsChevron = true

    var body: some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(titleColor)
            Spacer(minLength: 8)
            if let value { Text(value).font(.subheadline.weight(.bold)).foregroundStyle(valueColor) }
            if showsChevron {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(DB.faint)
            }
        }
        .font(.body.weight(.medium))
        .padding(.horizontal, 20)
        .frame(height: 58)
        .contentShape(Rectangle())
    }
}

/// "월세        500/31" 두 칸 정보 행
struct InfoRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(label).font(.subheadline.weight(.semibold)).foregroundStyle(DB.ink)
                .frame(width: 112, alignment: .leading)
            Text(value).font(.subheadline.weight(.semibold)).foregroundStyle(DB.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// 옵션 표시용 연보라 태그
struct OptionTag: View {
    let label: String
    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(DB.purple)
            .background(DB.purpleSoft, in: Capsule())
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: String
    var message: String? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 34)).foregroundStyle(DB.faint)
            Text(title).font(.headline).foregroundStyle(DB.ink)
            if let message {
                Text(message).font(.subheadline).foregroundStyle(DB.sub).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

// MARK: - 이미지 · 매물

/// 서버 이미지 (상대 경로도 AssetURL 로 해석). 주어진 프레임을 채우고 잘라낸다.
/// 데모 데이터 사진(bundle:// · mockfile://)은 기기 파일이라 LocalImage 로 바로 읽는다.
struct RemoteImage: View {
    let uri: String?
    var placeholderIcon = "photo"

    var body: some View {
        let url = AssetURL.resolve(uri)
        Color.clear
            .overlay {
                if let url, url.isFileURL {
                    LocalImage(url: url, placeholderIcon: placeholderIcon)
                } else {
                    AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        default:
                            ImagePlaceholder(icon: placeholderIcon)
                        }
                    }
                }
            }
            .clipped()
    }
}

struct ImagePlaceholder: View {
    let icon: String
    var body: some View {
        ZStack {
            DB.field
            Image(systemName: icon).font(.title3).foregroundStyle(DB.faint)
        }
    }
}

/// 기기 안의 사진 파일 (앱 번들 · 데모 데이터). 한 번 읽은 사진은 메모리에 캐시한다.
struct LocalImage: View {
    let url: URL
    var placeholderIcon = "photo"
    @State private var image: UIImage?
    @State private var loadedURL: URL?

    init(url: URL, placeholderIcon: String = "photo") {
        self.url = url
        self.placeholderIcon = placeholderIcon
        let cached = LocalImageCache.shared.cached(url)
        _image = State(initialValue: cached)
        _loadedURL = State(initialValue: cached == nil ? nil : url)
    }

    var body: some View {
        ZStack {
            if let image, loadedURL == url {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ImagePlaceholder(icon: placeholderIcon)
            }
        }
        .task(id: url) {
            guard loadedURL != url else { return }
            let img = await LocalImageCache.shared.load(url)
            image = img
            loadedURL = url
        }
    }
}

final class LocalImageCache {
    static let shared = LocalImageCache()
    private let cache = NSCache<NSURL, UIImage>()

    init() { cache.countLimit = 120 }

    func cached(_ url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }

    func load(_ url: URL) async -> UIImage? {
        if let img = cached(url) { return img }
        let img = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let data = try? Data(contentsOf: url), let img = UIImage(data: data) else { return nil }
            return img.preparingForDisplay() ?? img             // 디코딩을 백그라운드에서 끝내 둔다
        }.value
        if let img { cache.setObject(img, forKey: url as NSURL) }
        return img
    }
}

/// 데모 모드 표시 (홈 로고 옆. 누르면 설정)
struct DemoBadge: View {
    var body: some View {
        Text("데모")
            .font(.caption2.weight(.bold))
            .foregroundStyle(DB.purple)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(DB.purpleSoft, in: Capsule())
            .overlay(Capsule().stroke(DB.purpleLine))
    }
}

/// 3D 공간이 준비된 매물 표시
struct ThreeDBadge: View {
    var body: some View {
        Text("3D")
            .font(.system(size: 10, weight: .heavy))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(DB.purple, in: Capsule())
    }
}

/// 중개사 인증을 받은 사람이 올린 매물 표시 (집주인이 직접 올린 매물에는 붙지 않는다)
struct VerifiedBrokerBadge: View {
    var compact = false
    var body: some View {
        if compact {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.white, DB.purple)
                .padding(3)
                .background(Color.white, in: Circle())
                .accessibilityLabel("인증 중개사")
        } else {
            Label("인증 중개사", systemImage: "checkmark.seal.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(DB.purple)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(DB.purpleSoft, in: Capsule())
        }
    }
}

/// 관심 매물 하트. framed = 상세 화면 하단의 네모 버튼
struct HeartButton: View {
    let listingId: String
    var size: CGFloat = 22
    var framed = false
    @EnvironmentObject private var session: Session

    var body: some View {
        let on = session.isFavorite(listingId)
        Button {
            Task { await session.toggleFavorite(listingId) }
        } label: {
            Image(systemName: on ? "heart.fill" : "heart")
                .font(.system(size: size))
                .foregroundStyle(DB.danger)
                .frame(width: framed ? 54 : 36, height: framed ? 54 : 36)
                .background {
                    if framed {
                        RoundedRectangle(cornerRadius: 14).fill(Color.white)
                        RoundedRectangle(cornerRadius: 14).stroke(DB.line)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(on ? "관심 매물 해제" : "관심 매물 추가")
    }
}

/// 홈 3열 격자 카드: 사진 · "월세 1000/57" · "원룸" · "4층, 관리비 6만"
struct ListingCard: View {
    let listing: Listing
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            RemoteImage(uri: listing.coverUri, placeholderIcon: "house")
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topLeading) {
                    if listing.isSpaceReady { ThreeDBadge().padding(5) }
                }
                .overlay(alignment: .topTrailing) {
                    if listing.agent?.isVerified == true { VerifiedBrokerBadge(compact: true).padding(4) }
                }
                .padding(.bottom, 5)
            Text(Fmt.price(listing)).font(.footnote.weight(.bold)).foregroundStyle(DB.ink).lineLimit(1)
            Text(Fmt.roomType(listing.roomType).ifEmpty(" ")).font(.caption).foregroundStyle(DB.ink).lineLimit(1)
            Text(Fmt.cardDetail(listing)).font(.caption2).foregroundStyle(DB.sub).lineLimit(1)
        }
        .contentShape(Rectangle())
    }
}

/// 목록 행 (지도 시트 · 관심 매물 · 검색 결과): 사진 · "500/31" · "원룸" · "3층, 관리비 5만" · ♡
struct ListingRow: View {
    let listing: Listing
    var body: some View {
        HStack(spacing: 12) {
            NavigationLink(value: AppRoute.listing(listing.listingId)) {
                HStack(spacing: 14) {
                    RemoteImage(uri: listing.coverUri, placeholderIcon: "house")
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(alignment: .topLeading) {
                            if listing.isSpaceReady { ThreeDBadge().padding(4) }
                        }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Fmt.priceShort(listing)).font(.headline.weight(.bold)).foregroundStyle(DB.ink)
                        HStack(spacing: 6) {
                            Text([Fmt.dealLabel(listing), Fmt.roomType(listing.roomType)].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption.weight(.medium)).foregroundStyle(DB.ink)
                            if listing.agent?.isVerified == true { VerifiedBrokerBadge() }
                        }
                        Text(Fmt.cardDetail(listing)).font(.caption).foregroundStyle(DB.sub).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            HeartButton(listingId: listing.listingId)
        }
    }
}

/// 3D 처리 상태 배지
struct StatusBadge: View {
    let status: String?
    var body: some View {
        let style: (text: String, color: Color) = {
            switch status ?? "NONE" {
            case "COMPLETED": return ("3D 준비됨", Color.green)
            case "QUEUED", "RUNNING": return ("3D 생성 중", Color.orange)
            case "FAILED": return ("3D 실패", Color.red)
            default: return ("사진만", Color.gray)
            }
        }()
        Text(style.text).font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(style.color.opacity(0.15), in: Capsule())
            .foregroundStyle(style.color)
    }
}

// MARK: - 줄바꿈 배치

/// 칩·태그를 폭에 맞춰 줄바꿈하며 배치
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            widest = max(widest, x + size.width)
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: proposal.width ?? widest, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// FlowLayout 을 뷰처럼 쓰기 위한 래퍼: `FlowStack { Chip(...); Chip(...) }`
struct FlowStack<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        let layout = FlowLayout(spacing: spacing, lineSpacing: spacing)
        layout { content }
    }
}

// MARK: - 알림

struct ToastView: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.78), in: Capsule())
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}

extension View {
    /// `@State var error: String?` 를 알림으로 보여준다
    func errorAlert(_ error: Binding<String?>) -> some View {
        alert("문제가 발생했습니다", isPresented: Binding(get: { error.wrappedValue != nil },
                                                  set: { if !$0 { error.wrappedValue = nil } })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(error.wrappedValue ?? "")
        }
    }
}

extension Error {
    var isCancellation: Bool {
        if self is CancellationError { return true }
        if let u = self as? URLError, u.code == .cancelled { return true }
        return false
    }

    var userMessage: String {
        if let api = self as? APIError {
            if let m = api.serverMessage { return "\(m) (\(api.status))" }
            switch api.status {
            case 401, 403: return "권한이 없습니다. 다시 로그인해 주세요. (\(api.status))"
            case 404: return "요청한 정보를 찾을 수 없습니다. (404)"
            default: return "서버 오류 (\(api.status)): \(api.body.prefix(120))"
            }
        }
        if let url = self as? URLError {
            switch url.code {
            case .cannotConnectToHost, .cannotFindHost, .timedOut, .notConnectedToInternet, .networkConnectionLost:
                return "서버에 연결할 수 없습니다. 설정의 서버 주소(\(AppConfig.shared.baseURL.absoluteString))를 확인해 주세요."
            default: return url.localizedDescription
            }
        }
        if let d = self as? DecodingError { return "서버 응답 형식이 예상과 다릅니다: " + Self.describe(d) }
        return localizedDescription
    }

    private static func describe(_ e: DecodingError) -> String {
        func path(_ ctx: DecodingError.Context) -> String {
            ctx.codingPath.map { k in k.intValue.map { "[\($0)]" } ?? k.stringValue }.joined(separator: ".")
        }
        switch e {
        case .keyNotFound(let key, let ctx):
            return "‘\(key.stringValue)’ 필드가 없습니다 (\(path(ctx)))"
        case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx):
            return "‘\(path(ctx))’ 값의 형식이 다릅니다 · \(ctx.debugDescription)"
        case .dataCorrupted(let ctx):
            return ctx.debugDescription
        @unknown default:
            return "\(e)"
        }
    }
}
