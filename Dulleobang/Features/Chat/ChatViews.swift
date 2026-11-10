import SwiftUI

/// 채팅 목록 (데모 3번째 화면): 로고 · 검색 · 매물 사진 / 가격 / "지역 · 방종류" / 마지막 메시지
struct ChatListView: View {
    var body: some View { TabStack { ChatListContent() } }
}

private struct ChatListContent: View {
    @State private var rooms: [ChatRoomSummary] = []
    @State private var search = ""
    @State private var loaded = false
    @State private var loadError: String?

    private var filtered: [ChatRoomSummary] {
        let q = search.trimmed
        guard !q.isEmpty else { return rooms }
        return rooms.filter { r in
            [r.counterpartName, r.listing?.location, r.lastMessage, r.listing.map { ChatRow.priceText($0) }]
                .compactMap { $0 }
                .contains { $0.localizedCaseInsensitiveContains(q) }
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            LogoView().frame(maxWidth: .infinity).padding(.top, 8)
            SearchField(placeholder: "검색", text: $search, cornerRadius: 10)
                .padding(.horizontal, 20)
            ScrollView {
                LazyVStack(spacing: 0) {
                    if !loaded {
                        ProgressView().padding(.top, 40)
                    } else if let loadError, rooms.isEmpty {
                        EmptyStateView(icon: "wifi.exclamationmark", title: "채팅을 불러오지 못했습니다", message: loadError)
                    } else if filtered.isEmpty {
                        EmptyStateView(icon: "bubble.left.and.bubble.right",
                                       title: search.isEmpty ? "아직 채팅이 없습니다" : "검색 결과가 없습니다",
                                       message: search.isEmpty ? "매물 상세에서 ‘채팅하기’를 눌러 중개사와 대화를 시작하세요." : nil)
                    }
                    ForEach(filtered) { r in
                        NavigationLink(value: AppRoute.chat(r.chatId)) { ChatRow(room: r) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
            .scrollDismissesKeyboard(.immediately)
        }
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await load() }
        .task {
            // 목록이 보이는 동안 10초마다 새 메시지 확인
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private func load() async {
        do {
            rooms = try await ChatAPI.rooms()
            loadError = nil
        } catch {
            if !error.isCancellation { loadError = error.userMessage }
        }
        loaded = true
    }
}

struct ChatRow: View {
    let room: ChatRoomSummary

    static func priceText(_ l: ChatListing) -> String {
        guard let p = l.price else { return "매물" }
        return Fmt.price(dealType: l.dealType, price: p)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            RemoteImage(uri: room.listing?.thumbnailUri, placeholderIcon: "house")
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 4) {
                Text(room.listing.map { Self.priceText($0) } ?? (room.counterpartName ?? "채팅"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DB.ink.opacity(0.75))
                Text(subtitle).font(.caption.weight(.medium)).foregroundStyle(DB.sub).lineLimit(1)
                Text(room.lastMessage ?? " ").font(.caption).foregroundStyle(DB.faint).lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 6) {
                Text(Fmt.chatTime(room.lastMessageAt)).font(.caption2).foregroundStyle(DB.faint)
                if let n = room.unreadCount, n > 0 {
                    Text("\(n)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(DB.accent, in: Capsule())
                }
            }
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        let place = room.listing?.location.map { Fmt.shortLocation($0) } ?? ""
        let type = Fmt.roomType(room.listing?.roomType)
        let parts = [place, type].filter { !$0.isEmpty }
        return parts.isEmpty ? (room.counterpartName ?? "") : parts.joined(separator: " · ")
    }
}

// MARK: - 채팅방

/// 채팅방 (데모 "임차인의 매물 보기" 4번째 화면): 헤더(가격 · "지역 방종류 층 · 중개사무소") · 위에 고정한 매물 카드(3D 보기 · 매물 보기)
/// · 날짜 구분선 · 보낸 시각이 붙은 말풍선 · 질문 칩 · 메시지 입력
struct ChatRoomView: View {
    let chatId: String
    @EnvironmentObject private var session: Session
    @Environment(\.navigate) private var navigate
    @State private var detail: ChatRoomDetail?
    @State private var messages: [ChatMessage] = []
    @State private var pending: [ChatMessage] = []
    @State private var text = ""
    @State private var error: String?
    @State private var loaded = false
    @State private var listing: Listing?                  // 위 매물 카드의 3D 보기 · 관리비 (한 번만 받아 온다)
    @State private var viewer: ViewerRoute?

    private var allMessages: [ChatMessage] { messages + pending }
    private var isReadOnly: Bool { detail?.readOnly == true }
    /// 서버는 메시지를 1000자까지 받는다 (UTF-16 단위로 세어 넉넉히 맞춘다)
    private static let maxMessage = 1000
    private var tooLong: Bool { text.trimmed.utf16.count > Self.maxMessage }
    private var canSend: Bool { !text.trimmed.isEmpty && !isReadOnly && !tooLong }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if loaded && allMessages.isEmpty {
                        Text("궁금한 점을 중개사에게 물어보세요.\n예: 현장과 같은 구조인지 확인해도 될까요?")
                            .font(.footnote).foregroundStyle(DB.sub).multilineTextAlignment(.center)
                            .padding(.top, 40)
                    }
                    ForEach(ChatTimeline.items(allMessages)) { item in
                        switch item {
                        case .day(let label):
                            Text(label)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(DB.sub)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(DB.field, in: Capsule())
                                .padding(.vertical, 4)
                        case .message(let m, let time):
                            MessageBubble(message: m, mine: isMine(m), time: time).id(m.id)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: allMessages.count) { _, _ in
                if let last = allMessages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { pinnedCard }
        .safeAreaInset(edge: .bottom) { inputBar }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { header }
        }
        .toolbar(.hidden, for: .tabBar)
        .task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .task(id: detail?.listing?.listingId) {
            guard let id = detail?.listing?.listingId, listing?.listingId != id else { return }
            listing = try? await ListingAPI.get(id)
        }
        .fullScreenCover(item: $viewer) { r in SpaceViewerView(route: r, isBroker: isListingOwner) }
        .errorAlert($error)
    }

    /// 대화 위에 고정한 매물 카드: 사진 · 가격 · 방 정보 · [3D 보기] [매물 보기]
    @ViewBuilder private var pinnedCard: some View {
        if let l = detail?.listing {
            HStack(spacing: 12) {
                RemoteImage(uri: l.thumbnailUri ?? listing?.coverUri, placeholderIcon: "house")
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text(ChatRow.priceText(l)).font(.subheadline.weight(.heavy)).foregroundStyle(DB.ink)
                    Text(pinnedFacts(l).ifEmpty(" ")).font(.caption).foregroundStyle(DB.sub).lineLimit(1)
                    HStack(spacing: 6) {
                        if let full = listing, full.isSpaceReady {
                            Button {
                                viewer = ViewerRoute(listing: full)
                            } label: {
                                Label("3D 보기", systemImage: "cube.fill")
                            }
                            .buttonStyle(.dbPill(filled: true))
                        }
                        if let id = l.listingId {
                            Button("매물 보기") { navigate(.listing(id)) }
                                .buttonStyle(.dbPill())
                        }
                    }
                    .padding(.top, 3)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(DB.group)
            .overlay(alignment: .bottom) { Rectangle().fill(DB.line).frame(height: 1) }
        }
    }

    /// "상도동 · 원룸 · 2층 · 관리비 5만"
    private func pinnedFacts(_ l: ChatListing) -> String {
        var parts: [String] = []
        if let loc = l.location { parts.append(Fmt.dong(loc)) }
        parts.append(Fmt.roomType(l.roomType))
        if let f = l.floor { parts.append(Fmt.floorLabel(f)) }
        if let fee = listing?.maintenanceFee { parts.append(fee == 0 ? "관리비 없음" : "관리비 \(fee)만") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// 이 매물을 올린 사람(중개사 · 집주인)이 보는 채팅이면 질문 칩을 숨긴다
    private var isListingOwner: Bool {
        guard let me = session.userId, let owner = listing?.agent?.userId else { return false }
        return me == owner
    }

    /// 첫 메시지 부담을 줄이는 질문 칩 (누르면 입력칸에 채워지고, 고쳐서 보낼 수 있다)
    static let quickQuestions = ["실제 구조가 3D랑 같나요?", "관리비에 뭐가 포함돼요?", "방 보러 가도 될까요?",
                                 "입주 날짜 조정되나요?", "주차 되나요?"]

    private var header: some View {
        Button {
            if let id = detail?.listing?.listingId { navigate(.listing(id)) }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline.weight(.bold)).foregroundStyle(DB.ink)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.caption2).foregroundStyle(DB.sub).lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var title: String {
        if let l = detail?.listing { return ChatRow.priceText(l) }
        return detail?.counterpartName ?? "채팅"
    }

    /// "상도동 원룸 3층 · 상도 공인중개사"
    private var subtitle: String {
        guard let d = detail else { return "" }
        var place: [String] = []
        if let loc = d.listing?.location { place.append(Fmt.shortLocation(loc)) }
        let type = Fmt.roomType(d.listing?.roomType)
        if !type.isEmpty { place.append(type) }
        if let f = d.listing?.floor { place.append(Fmt.floorLabel(f)) }
        let who = d.officeName ?? d.counterpartName
        return [place.joined(separator: " "), who ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var inputBar: some View {
        VStack(spacing: 8) {
            if !isListingOwner && text.isEmpty && !isReadOnly {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Self.quickQuestions, id: \.self) { q in
                            Button { text = q } label: {
                                Text(q)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(DB.accent)
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 6)
                                    .background(DB.accentSoft, in: Capsule())
                                    .overlay(Capsule().stroke(DB.accentLine))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
            if isReadOnly {
                Label("매물이 내려가 더 이상 메시지를 보낼 수 없습니다", systemImage: "lock.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DB.sub)
                    .padding(.horizontal, 12)
            } else if tooLong {
                Text("메시지는 \(Self.maxMessage)자까지 보낼 수 있습니다")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DB.danger)
                    .padding(.horizontal, 12)
            }
            HStack(spacing: 8) {
                Button {} label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .background(DB.field, in: Circle())
                }
                .disabled(true)
                .foregroundStyle(DB.sub)
                .accessibilityLabel("첨부 (준비 중)")

                TextField(isReadOnly ? "보낼 수 없는 채팅입니다" : "메시지 보내기", text: $text, axis: .vertical)
                    .lineLimit(1...4)
                    .disabled(isReadOnly)
                    .font(.subheadline)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(DB.field, in: RoundedRectangle(cornerRadius: 18))

                Button {
                    Task { await send() }
                } label: {
                    Text("전송")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .background(canSend ? DB.accent : DB.accent.opacity(0.35), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 8)
        .background(Color.white)
    }


    private func isMine(_ m: ChatMessage) -> Bool {
        guard let me = session.userId, let sender = m.senderId else { return false }
        return me == sender
    }

    private func refresh() async {
        do {
            let d = try await ChatAPI.room(chatId)
            detail = d
            let server = d.messages ?? []
            if server != messages { messages = server }
        } catch {
            if !error.isCancellation && !loaded { self.error = error.userMessage }
        }
        loaded = true
    }

    private func send() async {
        let body = text.trimmed
        guard !body.isEmpty, !isReadOnly, body.utf16.count <= Self.maxMessage else { return }
        text = ""
        let local = ChatMessage(messageId: "local-\(UUID().uuidString)", senderId: session.userId, senderName: session.name,
                                message: body, sentAt: Fmt.nowISO())
        pending.append(local)
        do {
            try await ChatAPI.send(chatId, message: body)
            await refresh()
            pending.removeAll { $0.id == local.id }
        } catch {
            pending.removeAll { $0.id == local.id }
            text = body
            self.error = "메시지를 보내지 못했습니다. " + error.validationAwareMessage(hint: "메시지는 1000자까지 보낼 수 있습니다.")
        }
    }
}

/// 말풍선 (+ 같은 사람이 같은 분에 보낸 묶음의 마지막에만 보낸 시각)
struct MessageBubble: View {
    let message: ChatMessage
    let mine: Bool
    var time: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if !mine {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(DB.faint)
            }
            HStack(alignment: .bottom, spacing: 6) {
                if mine {
                    Spacer(minLength: 50)
                    if let time { timeLabel(time) }
                }
                Text(message.message)
                    .font(.subheadline)
                    .foregroundStyle(mine ? Color.white : DB.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(mine ? DB.accent : DB.field, in: RoundedRectangle(cornerRadius: 14))
                    .opacity(message.messageId.hasPrefix("local-") ? 0.6 : 1)
                if !mine {
                    if let time { timeLabel(time) }
                    Spacer(minLength: 50)
                }
            }
        }
    }

    private func timeLabel(_ t: String) -> some View {
        Text(t).font(.caption2).foregroundStyle(DB.faint).fixedSize()
    }
}

/// 채팅방 말풍선 배치: 날짜가 바뀌면 구분선, 같은 사람이 같은 분에 연달아 보낸 말풍선은 마지막에만 시각을 붙인다
enum ChatTimeline {
    enum Item: Identifiable, Equatable {
        case day(String)
        case message(ChatMessage, time: String?)

        var id: String {
            switch self {
            case .day(let d): return "day-" + d
            case .message(let m, _): return m.id
            }
        }
    }

    static func items(_ messages: [ChatMessage], now: Date = Date(), calendar: Calendar = .current) -> [Item] {
        var out: [Item] = []
        var lastDay: String?
        let dates = messages.map { Fmt.parseDate($0.sentAt) }
        for (i, m) in messages.enumerated() {
            guard let date = dates[i] else {
                out.append(.message(m, time: nil))          // 보낸 시각을 모르면 구분선 · 시각 없이
                continue
            }
            let day = Fmt.chatDay(date, now: now, calendar: calendar)
            if day != lastDay {
                out.append(.day(day))
                lastDay = day
            }
            var sameGroupNext = false
            if i + 1 < messages.count, messages[i + 1].senderId == m.senderId, let next = dates[i + 1] {
                sameGroupNext = calendar.isDate(next, equalTo: date, toGranularity: .minute)
            }
            out.append(.message(m, time: sameGroupNext ? nil : Fmt.chatClock(date, calendar: calendar)))
        }
        return out
    }
}
