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
                        .background(DB.purple, in: Capsule())
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

/// 채팅방 (데모 "임차인의 매물 보기" 4번째 화면): 헤더(가격 · "지역 방종류 층 · 중개사무소") · 말풍선 · 메시지 입력
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

    private var allMessages: [ChatMessage] { messages + pending }
    private var canSend: Bool { !text.trimmed.isEmpty }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if loaded && allMessages.isEmpty {
                        Text("궁금한 점을 중개사에게 물어보세요.\n예: 현장과 같은 구조인지 확인해도 될까요?")
                            .font(.footnote).foregroundStyle(DB.sub).multilineTextAlignment(.center)
                            .padding(.top, 40)
                    }
                    ForEach(allMessages) { m in
                        MessageBubble(message: m, mine: isMine(m)).id(m.id)
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
        .errorAlert($error)
    }

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

            TextField("메시지 보내기", text: $text, axis: .vertical)
                .lineLimit(1...4)
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
                    .background(canSend ? DB.purple : DB.purple.opacity(0.35), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
        .padding(.horizontal, 12)
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
        guard !body.isEmpty else { return }
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
            self.error = "메시지를 보내지 못했습니다. " + error.userMessage
        }
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    let mine: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if mine {
                Spacer(minLength: 60)
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(DB.faint)
            }
            Text(message.message)
                .font(.subheadline)
                .foregroundStyle(mine ? Color.white : DB.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(mine ? DB.purple : DB.field, in: RoundedRectangle(cornerRadius: 14))
                .opacity(message.messageId.hasPrefix("local-") ? 0.6 : 1)
            if !mine { Spacer(minLength: 60) }
        }
    }
}
