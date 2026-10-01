import PhotosUI
import SwiftUI

/// 매물 등록하기 (데모 "중개인의 매물 등록하기" 화면 + 둘러방 공간 촬영):
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
    @State private var mediaTab = MediaTab.capture
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
    enum MediaTab: Hashable { case capture, images }

    private var isSubmitting: Bool { stage != nil }
    private var canSubmit: Bool {
        !isSubmitting && (createdId != nil || buildRequest() != nil)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                headerSection
                priceSection
                roomSection
                mediaSection
                optionSection
            }
            .padding(.horizontal, 24)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) { submitBar }
        .toolbar(.hidden, for: .tabBar)
        .navigationBarBackButtonHidden(isSubmitting)          // 업로드 중 뒤로 가면 끝난 뒤 엉뚱한 화면이 바뀌므로 막는다
        .onChange(of: pickerItems) { _, items in
            Task { await loadPhotos(items) }
        }
        .fullScreenCover(isPresented: $showCapture) {
            CaptureFlowView(target: .deferred(.room), onFinish: {}, onCaptured: { space in
                captured = space
                captureUploaded = false
            })
        }
        .errorAlert($error)
    }

    // MARK: - 입력 칸

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text("매물 등록하기").font(.title.weight(.bold)).foregroundStyle(DB.ink)
            ownerCard
            if createdId != nil {
                Label("매물 정보는 저장되었습니다. 남은 업로드를 이어서 진행합니다.", systemImage: "checkmark.circle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(DB.purple)
            }
        }
    }

    private var priceSection: some View {
        VStack(alignment: .leading, spacing: 28) {
            FieldBlock(title: "주소") {
                DBTextField(placeholder: "예: 서울 동작구 상도동 123-4, 302호", text: $address)
            }

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

    private var roomSection: some View {
        VStack(alignment: .leading, spacing: 28) {
            FieldBlock(title: "방 종류") {
                FlowStack {
                    ForEach(Fmt.roomTypes.indices, id: \.self) { i in
                        Chip(label: Fmt.roomTypes[i].label, selected: roomType == Fmt.roomTypes[i].key) {
                            roomType = Fmt.roomTypes[i].key
                        }
                    }
                }
            }

            FieldBlock(title: "층") {
                HStack(spacing: 10) {
                    DBTextField(placeholder: "해당층", text: $floorText, keyboard: .numbersAndPunctuation)
                    DBTextField(placeholder: "건물층", text: $totalFloorsText, keyboard: .numberPad)
                }
            }

            FieldBlock(title: "면적") {
                HStack(spacing: 10) {
                    DBTextField(placeholder: "전용면적", text: $areaText, keyboard: .decimalPad)
                    SegmentedPills(options: [(value: AreaUnit.sqm, label: "m²"), (value: AreaUnit.pyeong, label: "평")],
                                   selection: $areaUnit, height: 34)
                        .frame(width: 112)
                }
                DBTextField(placeholder: "공급면적 (선택)", text: $supplyText, keyboard: .decimalPad)
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
        }
    }

    private var mediaSection: some View {
        VStack(alignment: .leading, spacing: 28) {
            FieldBlock(title: "공간 자료", subtitle: "방을 촬영하거나 준비된 이미지를 선택해 매물에 연결하세요.") {
                SegmentedPills(options: [(value: MediaTab.capture, label: captured == nil ? "공간 촬영" : "공간 촬영 ✓"),
                                         (value: MediaTab.images, label: selectedOrder.isEmpty ? "이미지 선택" : "이미지 선택 ✓")],
                               selection: $mediaTab, height: 44)
                if mediaTab == .capture { capturePanel } else { imagePanel }
            }
        }
    }

    private var optionSection: some View {
        VStack(alignment: .leading, spacing: 28) {
            FieldBlock(title: "옵션 선택") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Fmt.options.indices, id: \.self) { i in
                        let key = Fmt.options[i].key
                        CheckRow(label: Fmt.options[i].label, checked: options.contains(key)) {
                            if options.contains(key) { _ = options.remove(key) } else { _ = options.insert(key) }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 등록 명의

    private var ownerCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("등록 명의").font(.caption.weight(.bold)).foregroundStyle(DB.purple)
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
                    .font(.headline).foregroundStyle(DB.purple)
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
            .background(DB.purpleSoft, in: RoundedRectangle(cornerRadius: 14))
        } else {
            VStack(alignment: .leading, spacing: 6) {
                tip("방 입구에서 시작해 벽을 따라 걸으면서 천천히 한 바퀴 돌아 주세요 (2~3분).")
                tip("창문 · 문 · 방 구석이 모두 화면에 들어오게, 다른 사람은 방 밖에서 기다리게 해 주세요.")
                tip("그다음 폰을 아래로 30~45° 기울여 바닥이 화면 절반쯤 보이게 한 바퀴 더 돌아 주세요.")
                tip("너무 빠르거나 제자리에서만 찍거나 바닥이 덜 찍히면 촬영 화면에 경고가 떠요.")
                tip(RoomPlanController.isSupported ? "LiDAR 기기라서 실제 치수와 벽·문·창 구조가 함께 저장됩니다."
                                                   : "LiDAR 가 없는 기기입니다. 사진과 카메라 위치만 저장됩니다.")
            }
            Button {
                showCapture = true
            } label: {
                dashedBox(title: "공간 촬영 시작하기", message: "촬영본으로 3D 공간 · 실측 치수 · 입주 예상 공간을 만듭니다.",
                          icon: "camera.viewfinder")
            }
            .buttonStyle(.plain)
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
            tip("방 전체 구조가 보이는 사진을 먼저 선택해 주세요.")
            tip("창가, 주방, 욕실 입구처럼 생활 동선이 드러나는 사진을 함께 올리면 좋아요.")
            tip("어둡거나 흔들린 사진은 제외하고, 같은 방향의 중복 사진은 줄여주세요.")
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
            Image(systemName: icon).font(.title2).foregroundStyle(DB.purple)
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

    private var submitBar: some View {
        VStack(spacing: 6) {
            if let stage {
                HStack(spacing: 8) {
                    if let progress { ProgressView(value: progress).frame(width: 120) } else { ProgressView() }
                    Text(stage + (progress.map { " \(Int($0 * 100))%" } ?? "")).font(.caption).foregroundStyle(DB.sub)
                }
            }
            Button {
                Task { await submit() }
            } label: {
                Text(isSubmitting ? "등록 중…" : (createdId == nil ? "매물 등록하기" : "이어서 등록하기"))
            }
            .buttonStyle(.dbPrimary)
            .disabled(!canSubmit)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .background(Color.white)
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
