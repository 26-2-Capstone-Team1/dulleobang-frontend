import PhotosUI
import SwiftUI

/// 매물 등록하기 (데모 "중개인의 매물 등록하기" 화면 + 둘러방 공간 촬영) — 5단계(기본 정보 · 가격 · 방 정보 · 사진·3D · 확인), 마지막에 미리보기:
/// 등록 명의 · 주소 · 가격 · 관리비 · 방 종류 · 층 · 면적(m²/평) · 방/욕실 수 · 입주 가능일 · 공간 자료(공간 촬영 | 이미지 선택) · 옵션
/// 제출 순서: POST /listings → POST /listings/{id}/images (선택한 사진) → POST /listings/{id}/captures (촬영본 zip)
/// 중간에 실패하면 끝난 단계는 건너뛰고 이어서 재시도한다.
struct ListingRegisterView: View {
    @EnvironmentObject private var session: Session
    @Environment(\.navigate) private var navigate

    // 매물 정보
    @State private var address = ""
    @State private var dealType = "MONTHLY"
    @State private var deposit = ""
    @State private var monthly = ""
    @State private var fee = ""
    @State private var roomType = "ONE_ROOM"
    @State private var floorText = ""
    @State private var totalFloorsText = ""
    @State private var areaText = ""
    @State private var supplyText = ""
    @State private var areaUnit = AreaUnit.sqm
    @State private var roomsText = "1"
    @State private var bathsText = "1"
    @State private var immediate = true
    @State private var moveInDate = Date()
    @State private var options: Set<String> = []

    // 공간 자료
    @State private var step = Step.basics
    @State private var stepHint: String?             // 다음으로 못 넘어간 이유 (아래 버튼 위에 빨갛게)
    @State private var showCapture = false
    @State private var captured: CapturedSpace?
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var photos: [PickedPhoto] = []
    @State private var selectedOrder: [UUID] = []
    @State private var loadingPhotos = false

    // 제출 상태
    @State private var createdId: String?
    @State private var photosUploaded = false
    @State private var captureUploaded = false
    @State private var stage: String?
    @State private var progress: Double?
    @State private var error: String?

    enum AreaUnit: Hashable { case sqm, pyeong }

    /// 등록 단계 (한 화면에 한 가지씩, 마지막에 세입자에게 보일 모습을 미리 본다)
    enum Step: Int, CaseIterable, Hashable {
        case basics, price, room, media, review

        var title: String {
            switch self {
            case .basics: return "기본 정보"
            case .price: return "가격"
            case .room: return "방 정보"
            case .media: return "사진 · 3D"
            case .review: return "확인"
            }
        }
    }

    /// 단계마다 꼭 필요한 칸 (나머지는 선택). nil = 다음으로 넘어가도 된다. buildRequest() 의 조건과 같다
    static func problem(for step: Step, address: String, dealType: String, deposit: String, monthly: String,
                        area: String) -> String? {
        switch step {
        case .basics:
            return address.trimmed.isEmpty ? "주소를 입력해 주세요" : nil
        case .price:
            if Int(deposit.trimmed) == nil { return "보증금을 숫자로 입력해 주세요 (만원)" }
            if dealType == "MONTHLY" && Int(monthly.trimmed) == nil { return "월세를 숫자로 입력해 주세요 (만원)" }
            return nil
        case .room:
            guard let a = Double(area.trimmed), a > 0 else { return "전용면적을 입력해 주세요" }
            return nil
        case .media, .review:
            return nil
        }
    }

    private var isSubmitting: Bool { stage != nil }
    private var canSubmit: Bool {
        !isSubmitting && (createdId != nil || buildRequest() != nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            progressHeader
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(headline).font(.title2.weight(.bold)).foregroundStyle(DB.ink)
                            Text(subtitle).font(.subheadline).foregroundStyle(DB.sub)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .id("top")
                        switch step {
                        case .basics: basicsStep
                        case .price: priceStep
                        case .room: roomStep
                        case .media: mediaStep
                        case .review: reviewStep
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .padding(.bottom, 24)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: step) { _, _ in proxy.scrollTo("top", anchor: .top) }
            }
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .navigationTitle("매물 등록")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .navigationBarBackButtonHidden(isSubmitting)          // 업로드 중 뒤로 가면 끝난 뒤 엉뚱한 화면이 바뀌므로 막는다
        .onChange(of: pickerItems) { _, items in
            Task { await loadPhotos(items) }
        }
        .onChange(of: address) { _, _ in stepHint = nil }
        .onChange(of: deposit) { _, _ in stepHint = nil }
        .onChange(of: monthly) { _, _ in stepHint = nil }
        .onChange(of: areaText) { _, _ in stepHint = nil }
        .fullScreenCover(isPresented: $showCapture) {
            CaptureFlowView(target: .deferred(.room), onFinish: {}, onCaptured: { space in
                captured = space
                captureUploaded = false
            })
        }
        .errorAlert($error)
    }

    // MARK: - 단계

    /// 위: 5칸 진행 막대 + 단계 이름 (지금 단계는 초록)
    private var progressHeader: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                ForEach(Step.allCases, id: \.self) { s in
                    Capsule()
                        .fill(s.rawValue <= step.rawValue ? DB.accent : DB.line)
                        .frame(height: 5)
                }
            }
            HStack(spacing: 0) {
                ForEach(Step.allCases, id: \.self) { s in
                    Text(s.title)
                        .font(.caption2.weight(s == step ? .bold : .medium))
                        .foregroundStyle(s == step ? DB.accent : DB.faint)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Step.allCases.count)단계 중 \(step.rawValue + 1)단계, \(step.title)")
    }

    private var headline: String {
        switch step {
        case .basics: return "어떤 집인가요?"
        case .price: return "가격을 알려 주세요"
        case .room: return "방 정보를 적어 주세요"
        case .media: return "방을 한 바퀴 촬영해 주세요"
        case .review: return "이대로 올릴까요?"
        }
    }

    private var subtitle: String {
        switch step {
        case .basics: return "주소와 방 종류부터 알려 주세요."
        case .price: return "만원 단위로 적어 주세요."
        case .room: return "전용면적만 꼭 필요하고 나머지는 선택이에요."
        case .media: return "촬영본으로 3D 공간 · 실측 치수 · 평면도가 자동으로 만들어져요. 사진은 따로 골라도 돼요."
        case .review: return "등록하면 사진과 촬영본이 올라가고 3D 공간 생성이 시작돼요."
        }
    }

    private var basicsStep: some View {
        VStack(alignment: .leading, spacing: 28) {
            ownerCard
            if createdId != nil {
                Label("매물 정보는 저장되었습니다. 남은 업로드를 이어서 진행합니다.", systemImage: "checkmark.circle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(DB.accent)
            }
            FieldBlock(title: "주소") {
                DBTextField(placeholder: "예: 서울 동작구 상도동 123-4, 302호", text: $address)
            }
            FieldBlock(title: "방 종류") {
                FlowStack {
                    ForEach(Fmt.roomTypes.indices, id: \.self) { i in
                        Chip(label: Fmt.roomTypes[i].label, selected: roomType == Fmt.roomTypes[i].key) {
                            roomType = Fmt.roomTypes[i].key
                        }
                    }
                }
            }
        }
    }

    private var priceStep: some View {
        VStack(alignment: .leading, spacing: 28) {
            FieldBlock(title: "가격", subtitle: "만원 단위") {
                SegmentedPills(options: [(value: "MONTHLY", label: "월세"), (value: "JEONSE", label: "전세")],
                               selection: $dealType)
                HStack(spacing: 10) {
                    DBTextField(placeholder: "보증금", text: $deposit, keyboard: .numberPad)
                    if dealType == "MONTHLY" {
                        DBTextField(placeholder: "월세", text: $monthly, keyboard: .numberPad)
                    }
                }
                if let d = Int(deposit.trimmed) {
                    Text(dealType == "JEONSE" ? "전세 \(Fmt.won(d))" : "월세 \(Fmt.won(d))/\(Int(monthly.trimmed) ?? 0)")
                        .font(.caption).foregroundStyle(DB.sub)
                }
            }
            FieldBlock(title: "관리비", subtitle: "만원 단위 · 비워 두면 ‘관리비 협의’로 표시됩니다") {
                DBTextField(placeholder: "예: 5", text: $fee, keyboard: .numberPad)
            }
        }
    }

    private var roomStep: some View {
        VStack(alignment: .leading, spacing: 28) {
            FieldBlock(title: "면적") {
                HStack(spacing: 10) {
                    DBTextField(placeholder: "전용면적", text: $areaText, keyboard: .decimalPad)
                    SegmentedPills(options: [(value: AreaUnit.sqm, label: "m²"), (value: AreaUnit.pyeong, label: "평")],
                                   selection: $areaUnit, height: 34)
                        .frame(width: 112)
                }
                DBTextField(placeholder: "공급면적 (선택)", text: $supplyText, keyboard: .decimalPad)
            }
            FieldBlock(title: "층") {
                HStack(spacing: 10) {
                    DBTextField(placeholder: "해당층", text: $floorText, keyboard: .numbersAndPunctuation)
                    DBTextField(placeholder: "건물층", text: $totalFloorsText, keyboard: .numberPad)
                }
            }
            FieldBlock(title: "방 수 / 욕실 수") {
                HStack(spacing: 10) {
                    DBTextField(placeholder: "방 수", text: $roomsText, keyboard: .numberPad)
                    DBTextField(placeholder: "욕실 수", text: $bathsText, keyboard: .numberPad)
                }
            }
            FieldBlock(title: "입주 가능일") {
                SegmentedPills(options: [(value: true, label: "즉시"), (value: false, label: "날짜 선택")], selection: $immediate)
                if !immediate {
                    DatePicker("입주 가능일", selection: $moveInDate, in: Date()..., displayedComponents: .date)
                        .datePickerStyle(.compact)
                        .environment(\.locale, Locale(identifier: "ko_KR"))
                        .padding(.horizontal, 16)
                        .frame(height: 50)
                        .background(DB.field, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            FieldBlock(title: "옵션", subtitle: "있는 것을 모두 눌러 주세요") {
                FlowStack {
                    ForEach(Fmt.options.indices, id: \.self) { i in
                        let key = Fmt.options[i].key
                        Chip(label: Fmt.options[i].label, selected: options.contains(key)) {
                            if options.contains(key) { _ = options.remove(key) } else { _ = options.insert(key) }
                        }
                    }
                }
            }
        }
    }

    private var mediaStep: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 14) { capturePanel }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("사진").font(.title3.weight(.bold)).foregroundStyle(DB.ink)
                    Text("선택 · 최대 \(AppConfig.shared.maxListingPhotos)장").font(.caption).foregroundStyle(DB.sub)
                }
                imagePanel
            }
        }
    }

    private var reviewStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Text("세입자에게 이렇게 보여요").font(.caption.weight(.bold)).foregroundStyle(DB.accent)
                previewCard
                if captured != nil {
                    Text("3D 표시는 촬영본으로 3D 공간이 만들어지면 붙어요.").font(.caption).foregroundStyle(DB.sub)
                }
            }
            reviewSection("기본 정보", .basics) {
                InfoRow(label: "주소", value: address.trimmed.ifEmpty("-"))
                InfoRow(label: "방 종류", value: Fmt.roomType(roomType))
            }
            reviewSection("가격", .price) {
                InfoRow(label: dealType == "JEONSE" ? "전세" : "월세", value: Fmt.priceShort(draftListing))
                InfoRow(label: "관리비", value: Fmt.fee(draftListing))
            }
            reviewSection("방 정보", .room) {
                InfoRow(label: "전용면적", value: draftListing.area.map { Fmt.areaShort($0) } ?? "-")
                InfoRow(label: "층", value: Fmt.floors(draftListing))
                InfoRow(label: "방 / 욕실", value: Fmt.roomsBaths(draftListing))
                InfoRow(label: "입주 가능일", value: Fmt.available(draftListing.availableFrom))
                InfoRow(label: "옵션", value: optionSummary)
            }
            reviewSection("사진 · 3D", .media) {
                InfoRow(label: "공간 촬영", value: captureSummary)
                InfoRow(label: "사진", value: selectedOrder.isEmpty ? "없음" : "\(selectedOrder.count)장")
            }
            if captured == nil && selectedOrder.isEmpty {
                Label("사진도 공간 촬영도 없으면 세입자에게 사진 없이 보여요", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.orange)
            }
            if createdId != nil {
                Label("매물 정보는 저장되었습니다. 남은 업로드를 이어서 진행합니다.", systemImage: "checkmark.circle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(DB.accent)
            }
        }
    }

    private var optionSummary: String {
        let names = Fmt.options.filter { options.contains($0.key) }.map { $0.label }
        return names.isEmpty ? "없음" : names.joined(separator: ", ")
    }

    private var captureSummary: String {
        guard let c = captured else { return "없음" }
        return "\(c.frameCount)장 · " + (captureUploaded ? "업로드 완료" : "등록할 때 업로드")
    }

    /// 확인 단계 묶음: 제목 + [수정] (그 단계로 돌아가기 · 매물 정보를 이미 저장했으면 막는다)
    private func reviewSection<C: View>(_ title: String, _ target: Step, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.headline.weight(.bold)).foregroundStyle(DB.ink)
                Spacer()
                Button("수정") { go(to: target) }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DB.accent)
                    .disabled(isSubmitting || createdId != nil)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DB.group, in: RoundedRectangle(cornerRadius: 14))
    }

    /// 세입자에게 보일 카드 그대로 (첫 사진 · 가격 · 방 정보)
    private var previewCard: some View {
        let l = draftListing
        return HStack(spacing: 14) {
            Group {
                if let first = orderedPhotos.first {
                    Image(uiImage: first.thumb).resizable().scaledToFill()
                } else {
                    ImagePlaceholder(icon: "house")
                }
            }
            .frame(width: 110, height: 84)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text(Fmt.price(l)).font(.headline.weight(.heavy)).foregroundStyle(DB.ink).lineLimit(1)
                Text(Fmt.cardFacts(l).ifEmpty(" ")).font(.footnote).foregroundStyle(DB.ink).lineLimit(1)
                Text(Fmt.cardSub(l)).font(.caption).foregroundStyle(DB.sub).lineLimit(1)
                if session.isBroker { VerifiedBrokerBadge() }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(DB.line))
    }

    /// 입력한 값으로 만든 미리보기용 매물 (실제 등록 요청은 buildRequest)
    private var draftListing: Listing {
        let factor = areaUnit == .pyeong ? 3.3058 : 1.0
        return Listing(listingId: createdId ?? "draft", location: address.trimmed,
                       price: Price(deposit: Int(deposit.trimmed) ?? 0, monthly: dealType == "JEONSE" ? 0 : (Int(monthly.trimmed) ?? 0)),
                       dealType: dealType, maintenanceFee: Int(fee.trimmed), roomType: roomType,
                       floor: Int(floorText.trimmed), totalFloors: Int(totalFloorsText.trimmed),
                       area: Double(areaText.trimmed).map { $0 * factor },
                       rooms: Int(roomsText.trimmed), bathrooms: Int(bathsText.trimmed),
                       availableFrom: immediate ? "IMMEDIATE" : Fmt.isoDay(moveInDate))
    }


    // MARK: - 등록 명의

    private var ownerCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("등록 명의").font(.caption.weight(.bold)).foregroundStyle(DB.accent)
                if session.isBroker { VerifiedBrokerBadge() }
            }
            if session.isBroker {
                Text(session.agent?.name ?? session.displayName).font(.headline.weight(.bold)).foregroundStyle(DB.ink)
                let line = [session.agent?.officeName, session.agent?.licenseNumber].compactMap { $0 }.joined(separator: " · ")
                if !line.isEmpty { Text(line).font(.caption).foregroundStyle(DB.sub) }
            } else {
                Text(session.displayName).font(.headline.weight(.bold)).foregroundStyle(DB.ink)
                Text("집주인 직접 등록 · 중개사 인증을 받으면 ‘인증 중개사’로 표시됩니다")
                    .font(.caption).foregroundStyle(DB.sub)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DB.group, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - 공간 촬영

    @ViewBuilder private var capturePanel: some View {
        if let c = captured {
            VStack(alignment: .leading, spacing: 10) {
                Label("공간 촬영 완료", systemImage: "checkmark.circle.fill")
                    .font(.headline).foregroundStyle(DB.accent)
                Text("\(c.frameCount)장 · \(String(format: "%.0f", c.sizeMB)) MB · LiDAR 깊이 \(c.hasDepth ? "✓" : "없음") · 방 구조 \(c.hasRoomPlan ? "✓" : "없음")")
                    .font(.caption).foregroundStyle(DB.ink)
                Text(captureUploaded ? "업로드 완료 · 3D 공간 생성이 시작되었습니다."
                                     : "매물을 등록하면 촬영본이 업로드되고 3D 공간 생성이 시작됩니다.")
                    .font(.caption).foregroundStyle(DB.sub)
                if !captureUploaded {
                    HStack(spacing: 8) {
                        Button("다시 촬영") {
                            discardCapture()
                            showCapture = true
                        }
                        .buttonStyle(.dbPill())
                        Button("삭제") { discardCapture() }.buttonStyle(.dbPill())
                    }
                    .disabled(isSubmitting)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DB.accentSoft, in: RoundedRectangle(cornerRadius: 14))
        } else {
            Button {
                showCapture = true
            } label: {
                VStack(spacing: 8) {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .frame(width: 58, height: 58)
                        .background(DB.accent, in: Circle())
                    Text("공간 촬영 시작하기").font(.headline.weight(.bold)).foregroundStyle(DB.accent)
                    Text(RoomPlanController.isSupported ? "2~3분 · 실측 치수와 벽 · 문 · 창 구조까지 저장돼요"
                                                        : "2~3분 · LiDAR 가 없는 기기라 사진과 카메라 위치만 저장돼요")
                        .font(.caption).foregroundStyle(DB.sub).multilineTextAlignment(.center)
                }
                .padding(.vertical, 24)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity)
                .background(DB.accentSoft.opacity(0.6), in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(DB.accent.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // 촬영 화면 시작 전 안내와 같은 세 가지 (예전 6줄 안내 대신 · 나머지는 촬영 화면 안내가 맡는다)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(PreScanChecklist.items(for: .room)) { item in
                    HStack(spacing: 10) {
                        Image(systemName: item.icon)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(DB.accent)
                            .frame(width: 34, height: 34)
                            .background(DB.accentSoft, in: RoundedRectangle(cornerRadius: 10))
                        Text(item.text).font(.subheadline.weight(.medium)).foregroundStyle(DB.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func discardCapture() {
        if let c = captured { CapturePackager.cleanup(c.captureDir) }
        captured = nil
        captureUploaded = false
    }

    // MARK: - 이미지 선택

    @ViewBuilder private var imagePanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            tip("방 전체가 보이는 사진을 먼저 골라 주세요. 고른 순서대로 상세 화면에 보여요.")
        }
        PhotosPicker(selection: $pickerItems, maxSelectionCount: AppConfig.shared.maxListingPhotos,
                     selectionBehavior: .ordered, matching: .images) {
            dashedBox(title: photos.isEmpty ? "이미지 선택하기" : "이미지 다시 고르기",
                      message: photos.isEmpty ? "JPG, PNG, HEIC 형식의 방 사진을 여러 장 선택할 수 있어요."
                                              : "지금 \(photos.count)장을 불러왔습니다. 최대 \(AppConfig.shared.maxListingPhotos)장",
                      icon: "photo.on.rectangle")
        }
        .disabled(isSubmitting)
        if loadingPhotos {
            HStack(spacing: 8) {
                ProgressView()
                Text("사진 불러오는 중…").font(.caption).foregroundStyle(DB.sub)
            }
        }
        if !photos.isEmpty { photoGrid }
    }

    private var photoGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("상세 사진 선택").font(.headline.weight(.bold)).foregroundStyle(DB.ink)
                    Text("\(photos.count)장 중 \(selectedOrder.count)장 표시").font(.caption).foregroundStyle(DB.sub)
                }
                Spacer()
                Button("전체 선택") { selectedOrder = photos.map(\.id) }.buttonStyle(.dbPill())
                Button("비우기") { selectedOrder = [] }.buttonStyle(.dbPill())
            }
            Text("체크한 사진만 상세 페이지의 메인 사진과 썸네일 목록에 표시됩니다. 번호 순서대로 보여요.")
                .font(.caption).foregroundStyle(DB.sub)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(photos) { p in photoTile(p) }
            }
        }
        .disabled(isSubmitting)
    }

    private func photoTile(_ p: PickedPhoto) -> some View {
        let order = selectedOrder.firstIndex(of: p.id)
        return Button {
            if let i = selectedOrder.firstIndex(of: p.id) { _ = selectedOrder.remove(at: i) } else { selectedOrder.append(p.id) }
            photosUploaded = false
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay { Image(uiImage: p.thumb).resizable().scaledToFill() }
                    .clipped()
                VStack(alignment: .leading, spacing: 1) {
                    Text(p.name).font(.caption2.weight(.semibold)).foregroundStyle(DB.ink).lineLimit(1)
                    Text("\(p.sizeKB)KB").font(.caption2).foregroundStyle(DB.sub)
                }
                .padding(6)
            }
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(order != nil ? DB.ink : DB.line, lineWidth: order != nil ? 2 : 1))
            .overlay(alignment: .topTrailing) {
                ZStack {
                    if let order {
                        Circle().fill(DB.ink)
                        Text("\(order + 1)").font(.caption2.weight(.bold)).foregroundStyle(Color.white)
                    } else {
                        Circle().fill(Color.white.opacity(0.85))
                        Circle().stroke(DB.line)
                    }
                }
                .frame(width: 22, height: 22)
                .padding(6)
            }
        }
        .buttonStyle(.plain)
    }

    private var orderedPhotos: [PickedPhoto] {
        selectedOrder.compactMap { id in photos.first { $0.id == id } }
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        loadingPhotos = true
        defer { loadingPhotos = false }
        let maxPixel = AppConfig.shared.photoMaxPixel
        var out: [PickedPhoto] = []
        for (i, item) in items.enumerated() {
            guard let raw = try? await item.loadTransferable(type: Data.self) else { continue }
            let processed = await Task.detached(priority: .userInitiated) { () -> (Data, UIImage)? in
                guard let img = UIImage(data: raw) else { return nil }
                let scaled = img.downscaled(maxPixel: maxPixel)
                guard let jpeg = scaled.jpegData(compressionQuality: 0.85) else { return nil }
                return (jpeg, scaled.downscaled(maxPixel: 360))
            }.value
            guard let processed else { continue }
            out.append(PickedPhoto(name: String(format: "photo_%02d.jpg", i + 1), data: processed.0, thumb: processed.1))
        }
        photos = out
        selectedOrder = out.map(\.id)
        photosUploaded = false
    }

    // MARK: - 공통 조각

    private func tip(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("·").font(.caption.weight(.bold))
            Text(text).font(.caption.weight(.medium)).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(DB.ink.opacity(0.8))
    }

    private func dashedBox(title: String, message: String, icon: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.title2).foregroundStyle(DB.accent)
            Text(title).font(.subheadline.weight(.bold)).foregroundStyle(DB.ink)
            Text(message).font(.caption).foregroundStyle(DB.sub).multilineTextAlignment(.center)
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(DB.line, style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])))
        .contentShape(Rectangle())
    }

    /// 아래 버튼: [이전] [다음] · 마지막 단계는 [이전] [매물 등록하기] (업로드 중이면 진행률)
    private var bottomBar: some View {
        VStack(spacing: 6) {
            if let stage {
                HStack(spacing: 8) {
                    if let progress { ProgressView(value: progress).frame(width: 120) } else { ProgressView() }
                    Text(stage + (progress.map { " \(Int($0 * 100))%" } ?? "")).font(.caption).foregroundStyle(DB.sub)
                }
            } else if let stepHint {
                Label(stepHint, systemImage: "exclamationmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DB.danger)
            }
            HStack(spacing: 10) {
                if step != .basics {
                    Button("이전") { go(to: Step(rawValue: step.rawValue - 1) ?? .basics) }
                        .buttonStyle(.dbSecondary)
                        .frame(width: 100)
                        .disabled(isSubmitting)
                }
                if step == .review {
                    Button {
                        Task { await submit() }
                    } label: {
                        Text(isSubmitting ? "등록 중…" : (createdId == nil ? "매물 등록하기" : "이어서 등록하기"))
                    }
                    .buttonStyle(.dbPrimary)
                    .disabled(!canSubmit)
                } else {
                    Button(step == .media ? "다음 · 확인하기" : "다음") { next() }
                        .buttonStyle(.dbPrimary)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .background(Color.white)
    }

    /// 지금 단계에서 꼭 필요한 칸을 확인하고 다음 단계로
    private func next() {
        if let p = Self.problem(for: step, address: address, dealType: dealType, deposit: deposit, monthly: monthly,
                                area: areaText) {
            stepHint = p
            return
        }
        go(to: Step(rawValue: step.rawValue + 1) ?? .review)
    }

    private func go(to s: Step) {
        stepHint = nil
        withAnimation(.easeInOut(duration: 0.2)) { step = s }
    }


    // MARK: - 제출

    private func buildRequest() -> CreateListingRequest? {
        let addr = address.trimmed
        guard !addr.isEmpty, let dep = Int(deposit.trimmed) else { return nil }
        let mon: Int? = dealType == "JEONSE" ? 0 : Int(monthly.trimmed)
        guard let mon, let a = Double(areaText.trimmed), a > 0 else { return nil }
        let factor = areaUnit == .pyeong ? 3.3058 : 1.0
        func round2(_ v: Double) -> Double { (v * factor * 100).rounded() / 100 }
        return CreateListingRequest(
            location: addr,
            dealType: dealType,
            price: Price(deposit: dep, monthly: mon),
            maintenanceFee: Int(fee.trimmed),
            roomType: roomType,
            floor: Int(floorText.trimmed),
            totalFloors: Int(totalFloorsText.trimmed),
            area: round2(a),
            supplyArea: Double(supplyText.trimmed).map { round2($0) },
            rooms: Int(roomsText.trimmed),
            bathrooms: Int(bathsText.trimmed),
            availableFrom: immediate ? "IMMEDIATE" : Fmt.isoDay(moveInDate),
            rentalOptions: Fmt.options.map { $0.key }.filter { options.contains($0) },
            latitude: nil,
            longitude: nil)
    }

    private func submit() async {
        do {
            // 1) 매물 정보 (이미 만들었으면 건너뜀)
            if createdId == nil {
                guard var req = buildRequest() else {
                    error = "주소 · 가격 · 면적을 확인해 주세요"
                    return
                }
                stage = "주소 위치 확인 중"
                if let c = await Geocoder.shared.coordinate(for: req.location) {
                    req.latitude = c.latitude
                    req.longitude = c.longitude
                }
                stage = "매물 정보 등록 중"
                createdId = try await ListingAPI.create(req).listingId
            }
            guard let id = createdId else { return }

            // 2) 상세 사진 (선택한 순서대로)
            let chosen = orderedPhotos
            if !chosen.isEmpty && !photosUploaded {
                stage = "사진 업로드 중"
                progress = 0
                let files = chosen.enumerated().map { (filename: String(format: "photo_%02d.jpg", $0.offset + 1), data: $0.element.data) }
                try await ListingAPI.uploadImages(id, images: files) { p in
                    Task { @MainActor in progress = p }
                }
                photosUploaded = true
            }

            // 3) 공간 촬영본 → AI 3D 생성 시작
            if let cap = captured, !captureUploaded {
                stage = "공간 촬영본 업로드 중"
                progress = 0
                _ = try await ListingAPI.uploadCapture(id, zip: cap.zipURL) { p in
                    Task { @MainActor in progress = p }
                }
                captureUploaded = true
                CapturePackager.cleanup(cap.captureDir)
            }

            stage = nil
            progress = nil
            session.toast = "매물을 등록했습니다"
            navigate.replaceTop(.listing(id))
        } catch {
            stage = nil
            progress = nil
            if !error.isCancellation { self.error = error.userMessage + "\n‘이어서 등록하기’로 다시 시도할 수 있습니다." }
        }
    }
}

/// 선택한 매물 사진 (업로드용 JPEG + 썸네일)
struct PickedPhoto: Identifiable {
    let id = UUID()
    let name: String
    let data: Data
    let thumb: UIImage
    var sizeKB: Int { data.count / 1024 }
}
