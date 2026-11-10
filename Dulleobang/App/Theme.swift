import SwiftUI

// 디자인 토큰과 공용 컴포넌트 (처음엔 StayView 데모 화면을 따랐고, 색은 둘러방 아이콘 · 지도에 맞춰 바꿈).
// 흰 배경 · 세이지 그린 포인트 · 따뜻한 베이지 회색 입력칸/선 · 굵은 한글 제목.

extension Color {
    init(rgb r: Double, _ g: Double, _ b: Double) { self.init(red: r / 255, green: g / 255, blue: b / 255) }
}

enum DB {
    static let accent = Color(rgb: 87, 128, 73)          // #578049 세이지 그린 — 버튼 · 선택 · 3D 표시 · 지도 핀 (흰 글자 대비 4.6:1)
    static let accentSoft = Color(rgb: 237, 244, 233)    // #EDF4E9 연한 초록 바탕 (배너 · 태그 · 보조 버튼)
    static let accentLine = Color(rgb: 210, 228, 201)    // #D2E4C9 연한 초록 테두리
    static let ink = Color(rgb: 28, 28, 30)
    static let sub = Color(rgb: 138, 132, 122)           // #8A847A 따뜻한 회색 보조 글자
    static let faint = Color(rgb: 179, 173, 163)         // #B3ADA3
    static let field = Color(rgb: 243, 240, 234)         // #F3F0EA 입력칸 (베이지 회색)
    static let group = Color(rgb: 248, 246, 242)         // #F8F6F2 묶음 바탕
    static let line = Color(rgb: 236, 231, 223)          // #ECE7DF 선
    static let danger = Color(rgb: 232, 72, 85)
    static let kakao = Color(rgb: 254, 229, 0)
    static let logo = Color(rgb: 207, 200, 188)          // 예전 타일 로고용 (지금 로고는 LogoMark)
}

// MARK: - 로고 · 검색

/// 앱 아이콘과 같은 마크(회색빛 베이지 타일) + 앱 이름
struct LogoView: View {
    var size: CGFloat = 22
    var color: Color = DB.ink

    var body: some View {
        HStack(spacing: size * 0.32) {
            LogoMark().frame(width: size * 1.3, height: size * 1.3)
            Text(AppConfig.shared.brandName)
                .font(.system(size: size, weight: .heavy))
                .foregroundStyle(color)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AppConfig.shared.brandName)
    }
}

/// 둘러방 마크 = 앱 아이콘(Assets › AppIcon)과 같은 그림.
/// 회색빛 베이지 타일 위에, 처음 방 큐브에 천장을 덮어 왼쪽 벽 · 천장 · 바닥이 ‘ㄷ’ 으로 이어진 흰 방 (안쪽 벽은 진한 베이지).
/// 100×100 칸 좌표. tile = false 면 타일 없이 방만 그린다(진한 바탕 위에 올릴 때).
struct LogoMark: View {
    var tile = true

    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height) / 100
            let ox = (size.width - 100 * s) / 2, oy = (size.height - 100 * s) / 2
            if tile {
                let rect = CGRect(x: ox, y: oy, width: 100 * s, height: 100 * s)
                let shape = Path(roundedRect: rect, cornerRadius: 22.37 * s, style: .continuous)
                ctx.fill(shape, with: .linearGradient(Gradient(colors: [Self.color(0xECE7DF), Self.color(0xDDD6CA)]),
                                                      startPoint: rect.origin, endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))
            }
            for face in Self.faces {
                var path = Path()
                path.addLines(stride(from: 0, to: face.xy.count, by: 2).map {
                    CGPoint(x: ox + face.xy[$0] * s, y: oy + face.xy[$0 + 1] * s)
                })
                path.closeSubpath()
                let color = Self.color(face.rgb)
                ctx.fill(path, with: .color(color))
                ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 0.3 * s, lineJoin: .round))   // 면 사이 실금 가리기
            }
        }
        .accessibilityHidden(true)
    }

    private struct Face {
        let rgb: UInt32; let xy: [CGFloat]
        init(_ rgb: UInt32, _ xy: [CGFloat]) { self.rgb = rgb; self.xy = xy }
    }

    private static func color(_ hex: UInt32) -> Color {
        Color(rgb: Double(hex >> 16 & 0xFF), Double(hex >> 8 & 0xFF), Double(hex & 0xFF))
    }

    /// 뒤에서 앞으로 그리는 순서
    private static let faces: [Face] = [
        Face(0xBEB19B, [50, 52.81, 79.45, 67.53, 79.45, 36.3, 50, 21.58]),   // 뒷벽 (ㄷ 안쪽)
        Face(0xF7F4EE, [64.72, 53.3, 75.32, 58.6, 75.32, 49.23, 64.72, 43.93]),   // 창
        Face(0xFFFFFF, [20.55, 67.53, 50, 52.81, 50, 21.58, 20.55, 36.3]),   // 왼쪽 벽
        Face(0xF8F6F1, [20.55, 67.53, 50, 52.81, 79.45, 67.53, 50, 82.25]),   // 바닥
        Face(0xE2B22A, [28.8, 64.58, 39.4, 69.88, 39.4, 63.64, 28.8, 58.34]),   // 침대 옆
        Face(0xC99A17, [39.4, 69.88, 54.12, 62.52, 54.12, 56.28, 39.4, 63.64]),   // 침대 앞
        Face(0xFFD84D, [28.8, 58.34, 43.52, 50.98, 54.12, 56.28, 39.4, 63.64]),   // 침대 위
        Face(0xFFFFFF, [39.99, 53.6, 43.52, 51.83, 52.36, 56.25, 48.82, 58.01]),   // 베개
        Face(0xEDE8DF, [16.73, 69.36, 50, 86, 50, 82.25, 16.73, 65.62]),   // 바닥 두께 (왼쪽 앞)
        Face(0xD4CBBB, [50, 86, 83.27, 69.36, 83.27, 65.62, 50, 82.25]),   // 바닥 두께 (오른쪽 앞)
        Face(0xEDE8DF, [16.73, 65.62, 20.55, 67.53, 20.55, 36.3, 16.73, 34.38]),   // 왼쪽 벽 끝
        Face(0xAC9D84, [79.45, 67.53, 83.27, 65.62, 83.27, 34.38, 79.45, 36.3]),   // 뒷벽 끝
        Face(0xEDE8DF, [16.73, 34.38, 50, 51.02, 50, 47.27, 16.73, 30.64]),   // 천장 두께 (왼쪽 앞)
        Face(0xD4CBBB, [50, 51.02, 83.27, 34.38, 83.27, 30.64, 50, 47.27]),   // 천장 두께 (오른쪽 앞)
        Face(0xFFFFFF, [16.73, 30.64, 50, 14, 83.27, 30.64, 50, 47.27]),   // 천장
    ]
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

/// 초록 큰 버튼 ("채팅하기", "매물 등록하기", "인증 완료하기")
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.bold))
            .foregroundStyle(Color.white)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(DB.accent.opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.35),
                        in: RoundedRectangle(cornerRadius: 14))
    }
}

/// 연한 초록 보조 버튼 ("입주 예상 공간", "내 가구 놓아보기")
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.bold))
            .foregroundStyle(DB.accent.opacity(isEnabled ? 1 : 0.4))
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(DB.accentSoft.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// 작은 알약 버튼. filled = 초록("매물 등록"), dark = 3D 뷰어 헤더("초기화", "평면뷰"), 기본 = 회색("전체 선택")
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
    private var background: Color { filled ? DB.accent : (dark ? Color.white.opacity(0.16) : DB.field) }
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
                    .foregroundStyle(checked ? DB.accent : DB.faint)
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

/// 옵션 표시용 연한 초록 태그
struct OptionTag: View {
    let label: String
    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(DB.accent)
            .background(DB.accentSoft, in: Capsule())
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
            .foregroundStyle(DB.accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(DB.accentSoft, in: Capsule())
            .overlay(Capsule().stroke(DB.accentLine))
    }
}

/// 3D 공간이 준비된 매물 표시 (카드 · 목록 · 지도 · 채팅에서 같은 모양: 큐브 + "3D")
struct ThreeDBadge: View {
    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "cube.fill").font(.system(size: 8, weight: .bold))
            Text("3D").font(.system(size: 10, weight: .heavy))
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(DB.accent, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("3D 공간 있음")
    }
}

/// 중개사 인증을 받은 사람이 올린 매물 표시 (집주인이 직접 올린 매물에는 붙지 않는다)
struct VerifiedBrokerBadge: View {
    var compact = false
    var body: some View {
        if compact {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.white, DB.accent)
                .padding(3)
                .background(Color.white, in: Circle())
                .accessibilityLabel("인증 중개사")
        } else {
            Label("인증 중개사", systemImage: "checkmark.seal.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(DB.accent)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(DB.accentSoft, in: Capsule())
        }
    }
}

/// 관심 매물 하트. framed = 상세 화면 하단의 네모 버튼, onPhoto = 사진 위 (안 눌렸으면 흰 하트 + 그림자)
struct HeartButton: View {
    let listingId: String
    var size: CGFloat = 22
    var framed = false
    var onPhoto = false
    @EnvironmentObject private var session: Session

    var body: some View {
        let on = session.isFavorite(listingId)
        Button {
            Task { await session.toggleFavorite(listingId) }
        } label: {
            Image(systemName: on ? "heart.fill" : "heart")
                .font(.system(size: size, weight: onPhoto ? .semibold : .regular))
                .foregroundStyle(onPhoto && !on ? Color.white : DB.danger)
                .shadow(color: onPhoto ? Color.black.opacity(0.4) : Color.clear, radius: 2, y: 1)
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

/// 홈 2열 카드: 큰 사진(3D 표시) · "월세 1000/57" · "원룸 · 7평 · 4층" · "관리비 7만 · 흑석동". ♡ 는 ListingTile 이 사진 위에 얹는다
struct ListingCard: View {
    let listing: Listing
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            RemoteImage(uri: listing.coverUri, placeholderIcon: "house")
                .aspectRatio(4 / 3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .topLeading) {
                    if listing.isSpaceReady { ThreeDBadge().padding(7) }
                }
                .overlay(alignment: .bottomLeading) {
                    if listing.agent?.isVerified == true { VerifiedBrokerBadge(compact: true).padding(6) }
                }
                .padding(.bottom, 6)
            Text(Fmt.price(listing)).font(.callout.weight(.heavy)).foregroundStyle(DB.ink).lineLimit(1)
            Text(Fmt.cardFacts(listing).ifEmpty(" ")).font(.footnote).foregroundStyle(DB.ink).lineLimit(1)
            Text(Fmt.cardSub(listing)).font(.caption).foregroundStyle(DB.sub).lineLimit(1)
        }
        .contentShape(Rectangle())
    }
}

/// 카드 + 사진 위 ♡. ♡ 는 NavigationLink 밖(겹쳐 놓기)이라 누르면 저장만 되고 상세로 넘어가지 않는다
struct ListingTile: View {
    let listing: Listing
    var body: some View {
        NavigationLink(value: AppRoute.listing(listing.listingId)) { ListingCard(listing: listing) }
            .buttonStyle(.plain)
            .overlay(alignment: .topTrailing) {
                HeartButton(listingId: listing.listingId, size: 20, onPhoto: true).padding(2)
            }
    }
}

/// 최근 본 매물 (옆으로 넘기는 한 줄): 작은 사진 · "500/31" · "상도동 · 원룸"
struct ListingMiniCard: View {
    let listing: Listing
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            RemoteImage(uri: listing.coverUri, placeholderIcon: "house")
                .frame(width: 128, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .topLeading) {
                    if listing.isSpaceReady { ThreeDBadge().padding(5) }
                }
                .padding(.bottom, 4)
            Text(Fmt.priceShort(listing)).font(.footnote.weight(.heavy)).foregroundStyle(DB.ink).lineLimit(1)
            Text([Fmt.dong(listing.location), Fmt.roomType(listing.roomType)].filter { !$0.isEmpty }.joined(separator: " · ").ifEmpty(" "))
                .font(.caption2).foregroundStyle(DB.sub).lineLimit(1)
        }
        .frame(width: 128, alignment: .leading)
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
                            Text([Fmt.dealLabel(listing), Fmt.cardFacts(listing)].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption.weight(.medium)).foregroundStyle(DB.ink).lineLimit(1)
                            if listing.agent?.isVerified == true { VerifiedBrokerBadge() }
                        }
                        Text(Fmt.cardSub(listing)).font(.caption).foregroundStyle(DB.sub).lineLimit(1)
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
        if let api = self as? APIError { return api.displayMessage }
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

    /// 서버는 422 VALIDATION_FAILED 에서 어느 칸이 틀렸는지 알려 주지 않는다. 그래서 화면이 자기 칸의 규칙(hint)을 대신 알려 준다
    func validationAwareMessage(hint: String) -> String {
        if let api = self as? APIError, api.serverCode == "VALIDATION_FAILED" { return hint }
        return userMessage
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

// MARK: - 빠른 필터 · 가구 비교 바로가기 (앱 화면 개선)

/// 검색창 아래 · 지도 위의 빠른 필터 한 줄: 3D로 보기 · 월세 · 전세 · 방 종류 (한 번 더 누르면 해제).
/// 보증금 · 월세 상한은 필터 시트에서. floating = 지도 위 (칩마다 그림자)
struct QuickFilterBar: View {
    @Binding var query: ListingQuery
    var floating = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                chip("3D로 보기", icon: "cube.fill", on: query.spaceOnly) { query.spaceOnly.toggle() }
                chip("월세", on: query.dealType == "MONTHLY") {
                    query.dealType = query.dealType == "MONTHLY" ? nil : "MONTHLY"
                }
                chip("전세", on: query.dealType == "JEONSE") {
                    if query.dealType == "JEONSE" {
                        query.dealType = nil
                    } else {
                        query.dealType = "JEONSE"
                        query.maxMonthly = nil
                    }
                }
                ForEach(Fmt.roomTypes.indices, id: \.self) { i in
                    let key = Fmt.roomTypes[i].key
                    chip(Fmt.roomTypes[i].label, on: query.roomType == key) {
                        query.roomType = query.roomType == key ? nil : key
                    }
                }
            }
            .padding(.horizontal, floating ? 16 : 20)
            .padding(.vertical, floating ? 6 : 1)
        }
    }

    private func chip(_ label: String, icon: String? = nil, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon { Image(systemName: icon).font(.system(size: 11, weight: .bold)) }
                Text(label)
            }
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 13)
            .frame(height: 34)
            .foregroundStyle(on ? Color.white : DB.ink)
            .background(on ? DB.accent : Color.white, in: Capsule())
            .overlay(Capsule().stroke(on ? Color.clear : DB.line))
            .shadow(color: floating ? Color.black.opacity(0.12) : Color.clear, radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// "내 가구가 들어가는 방 찾기" 바로가기 (홈 · 마이페이지) → 가구로 매물 비교
struct CompareBanner: View {
    var title = "내 침대 · 책상이 들어가는 방만 보기"
    var subtitle = "촬영해 둔 내 가구로 3D 매물을 자동으로 비교해요"

    var body: some View {
        NavigationLink(value: AppRoute.compare([])) {
            HStack(spacing: 12) {
                Image(systemName: "sofa")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: 40, height: 40)
                    .background(DB.accent, in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.bold)).foregroundStyle(DB.ink)
                    Text(subtitle).font(.caption).foregroundStyle(DB.sub)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(DB.accent)
            }
            .padding(12)
            .background(DB.accentSoft, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(DB.accentLine))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
