import UIKit

/// 화면에 쓰는 문자열 포맷 (StayView 데모 표기와 맞춤: "월세 500/31", "전세 2억 5000", "3층, 관리비 5만")
enum Fmt {
    // MARK: - 가격 (만원 단위)

    /// 12000 → "1억 2000", 20000 → "2억", 5000 → "5000"
    static func won(_ manwon: Int) -> String {
        let eok = manwon / 10000, rest = manwon % 10000
        if eok > 0 && rest > 0 { return "\(eok)억 \(rest)" }
        if eok > 0 { return "\(eok)억" }
        return "\(rest)"
    }

    static func isJeonse(dealType: String?, price: Price) -> Bool {
        if let d = dealType?.uppercased(), !d.isEmpty { return d == "JEONSE" || d == "전세" }
        return price.monthly == 0 && price.deposit > 0
    }
    static func isJeonse(_ l: Listing) -> Bool { isJeonse(dealType: l.dealType, price: l.price) }
    static func dealKey(_ l: Listing) -> String { isJeonse(l) ? "JEONSE" : "MONTHLY" }
    static func dealLabel(_ l: Listing) -> String { isJeonse(l) ? "전세" : "월세" }

    /// "월세 500/31" · "전세 2억 5000"
    static func price(dealType: String?, price p: Price) -> String {
        isJeonse(dealType: dealType, price: p) ? "전세 \(won(p.deposit))" : "월세 \(won(p.deposit))/\(p.monthly)"
    }
    static func price(_ l: Listing) -> String { price(dealType: l.dealType, price: l.price) }

    /// 지도 말풍선·목록용: "500/31" · "2억 5000"
    static func priceShort(dealType: String?, price p: Price) -> String {
        isJeonse(dealType: dealType, price: p) ? won(p.deposit) : "\(won(p.deposit))/\(p.monthly)"
    }
    static func priceShort(_ l: Listing) -> String { priceShort(dealType: l.dealType, price: l.price) }

    // MARK: - 방 · 층 · 관리비 · 면적

    static let roomTypes: [(key: String, label: String)] = [
        ("ONE_ROOM", "원룸"), ("TWO_ROOM", "투룸"), ("THREE_ROOM", "쓰리룸+"), ("OFFICETEL", "오피스텔"),
    ]

    /// "ONE_ROOM" → "원룸". 이미 한글이면 그대로, 없으면 ""
    static func roomType(_ key: String?) -> String {
        guard let key, !key.isEmpty else { return "" }
        if let i = roomTypes.firstIndex(where: { $0.key == key.uppercased() }) { return roomTypes[i].label }
        return key
    }

    static func floorLabel(_ f: Int) -> String {
        if f > 0 { return "\(f)층" }
        if f == 0 { return "반지하" }
        return "지하 \(-f)층"
    }

    /// 상세 · 관리비 행: "5만 원" / "없음" / "관리비 협의"
    static func fee(_ l: Listing) -> String {
        guard let f = l.maintenanceFee else { return "관리비 협의" }
        return f == 0 ? "없음" : "\(f)만 원"
    }

    /// 카드 셋째 줄: "4층, 관리비 6만" · 층 정보가 없으면 "26.44m² · 즉시"
    static func cardDetail(_ l: Listing) -> String {
        if let f = l.floor {
            let fee = l.maintenanceFee.map { $0 == 0 ? "관리비 없음" : "관리비 \($0)만" } ?? "관리비 협의"
            return "\(floorLabel(f)), \(fee)"
        }
        var parts: [String] = []
        if let a = l.area { parts.append(sqm(a)) }
        parts.append(available(l.availableFrom))
        return parts.joined(separator: " · ")
    }

    /// "3층 / 5층"
    static func floors(_ l: Listing) -> String {
        let a = l.floor.map { floorLabel($0) } ?? "-"
        let b = l.totalFloors.map { "\($0)층" } ?? "-"
        return "\(a) / \(b)"
    }

    /// 23.8 → "23.8m²", 26.44 → "26.44m²"
    static func sqm(_ v: Double) -> String {
        var s = String(format: "%.2f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s + "m²"
    }

    /// "23.8m² / 33.05m²"
    static func areas(_ l: Listing) -> String {
        let a = l.area.map { sqm($0) } ?? "-"
        let s = l.supplyArea.map { sqm($0) } ?? "-"
        return "\(a) / \(s)"
    }

    /// "1개 / 1개"
    static func roomsBaths(_ l: Listing) -> String {
        let r = l.rooms.map { "\($0)개" } ?? "-"
        let b = l.bathrooms.map { "\($0)개" } ?? "-"
        return "\(r) / \(b)"
    }

    /// "IMMEDIATE" → "즉시", "2026-10-01" → "2026.10.01", nil → "협의"
    static func available(_ s: String?) -> String {
        guard let s = s?.trimmed, !s.isEmpty else { return "협의" }
        if s.uppercased() == "IMMEDIATE" || s == "즉시" { return "즉시" }
        return String(s.prefix(10)).replacingOccurrences(of: "-", with: ".")
    }

    static func isoDay(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    /// "서울 동작구 상도동 123-4, 302호" → "동작구 상도동"
    static func shortLocation(_ s: String) -> String {
        let tokens = s.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        let suffixes = ["구", "동", "읍", "면", "군"]
        let picked = tokens.filter { t in
            t.first?.isNumber == false && suffixes.contains(where: { t.hasSuffix($0) })
        }
        if !picked.isEmpty { return picked.suffix(2).joined(separator: " ") }
        return tokens.prefix(2).joined(separator: " ")
    }

    /// RoomPlan 가구 종류(영문) → 한글. 모르는 값은 그대로
    static func objectLabel(_ category: String) -> String {
        switch category {
        case "bed": return "침대"
        case "table", "desk": return "책상"
        case "chair": return "의자"
        case "sofa": return "소파"
        case "storage": return "수납장"
        case "closet", "wardrobe": return "옷장"
        case "refrigerator": return "냉장고"
        case "washerDryer": return "세탁기"
        case "sink": return "싱크대"
        case "stove": return "가스레인지"
        case "oven": return "오븐"
        case "dishwasher": return "식기세척기"
        case "toilet": return "변기"
        case "bathtub": return "욕조"
        case "television": return "TV"
        case "fireplace": return "벽난로"
        case "stairs": return "계단"
        default: return category
        }
    }

    /// 받침에 맞는 조사: "침대" → "침대와", "책상" → "책상과"
    static func withAnd(_ word: String) -> String {
        guard let last = word.unicodeScalars.last, (0xAC00...0xD7A3).contains(last.value) else { return word + "와" }
        return word + ((last.value - 0xAC00) % 28 == 0 ? "와" : "과")
    }

    // 3D 치수 (기존 화면용)
    static func m(_ v: Double) -> String { String(format: "%.2f m", v) }
    static func area(_ v: Double) -> String { String(format: "%.1f㎡ (%.1f평)", v, v / 3.3058) }
    static func dims(_ d: Dimensions) -> String { String(format: "%.2f × %.2f × %.2f m", d.width, d.depth, d.height) }

    // MARK: - 옵션

    static let options: [(key: String, label: String)] = [
        ("parking", "주차"), ("pet", "반려동물"), ("elevator", "엘리베이터"), ("aircon", "에어컨"), ("fridge", "냉장고"),
        ("washer", "세탁기"), ("bed", "침대"), ("desk", "책상"), ("closet", "옷장"), ("induction", "인덕션"),
    ]
    static func optionLabel(_ key: String) -> String {
        if let i = options.firstIndex(where: { $0.key == key }) { return options[i].label }
        return key
    }

    // MARK: - 채팅 시간

    /// ISO8601(타임존 포함) 과 Spring LocalDateTime("2026-09-24T14:03:00") 둘 다 받는다
    static func parseDate(_ s: String?) -> Date? {
        guard let s = s?.trimmed, !s.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss",
                       "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm"] {
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    /// 오늘이면 "오후 3:04", 어제면 "어제", 올해면 "9월 24일", 그 외 "2025.9.24"
    static func chatTime(_ s: String?) -> String {
        guard let d = parseDate(s) else { return "" }
        let cal = Calendar.current
        if cal.isDateInYesterday(d) { return "어제" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        if cal.isDateInToday(d) { f.dateFormat = "a h:mm" }
        else if cal.isDate(d, equalTo: Date(), toGranularity: .year) { f.dateFormat = "M월 d일" }
        else { f.dateFormat = "yyyy.M.d" }
        return f.string(from: d)
    }

    /// 지금 시각 ISO8601 (보낸 메시지 임시 표시용)
    static func nowISO() -> String { ISO8601DateFormatter().string(from: Date()) }

    // MARK: - 카드 · 상세 · 채팅 (앱 화면 개선)

    /// 23.06 → "7평", 21.54 → "6.5평" (소수 한 자리, .0 은 뗀다)
    static func pyeong(_ sqm: Double) -> String {
        let p = (sqm / 3.3058 * 10).rounded() / 10
        return (p == p.rounded() ? String(Int(p)) : String(format: "%.1f", p)) + "평"
    }

    /// 상세 핵심 칸: 23.06 → "23.1㎡ · 7평"
    static func areaShort(_ sqm: Double) -> String { String(format: "%.1f㎡ · ", sqm) + pyeong(sqm) }

    /// 카드 둘째 줄: "원룸 · 7평 · 4층" (없는 값은 뺀다)
    static func cardFacts(_ l: Listing) -> String {
        var parts: [String] = []
        let type = roomType(l.roomType)
        if !type.isEmpty { parts.append(type) }
        if let a = l.area, a > 0 { parts.append(pyeong(a)) }
        if let f = l.floor { parts.append(floorLabel(f)) }
        return parts.joined(separator: " · ")
    }

    /// 카드 셋째 줄: "관리비 7만 · 흑석동"
    static func cardSub(_ l: Listing) -> String {
        let fee = l.maintenanceFee.map { $0 == 0 ? "관리비 없음" : "관리비 \($0)만" } ?? "관리비 협의"
        let place = dong(l.location)
        return place.isEmpty ? fee : "\(fee) · \(place)"
    }

    /// "서울 동작구 흑석동 중앙하이츠 402호" → "흑석동" (동 · 읍 · 면이 없으면 구, 그것도 없으면 "")
    static func dong(_ s: String) -> String {
        let tokens = s.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        let named = tokens.filter { $0.first?.isNumber == false }
        if let d = named.first(where: { t in ["동", "읍", "면"].contains(where: { t.hasSuffix($0) }) }) { return d }
        return named.first(where: { $0.hasSuffix("구") }) ?? ""
    }

    /// 상세 관리비 칸: "7만 원" · "없음" · "협의"
    static func feeShort(_ l: Listing) -> String {
        guard let f = l.maintenanceFee else { return "협의" }
        return f == 0 ? "없음" : "\(f)만 원"
    }

    /// 옵션 아이콘 (SF Symbols). 모르는 값은 체크 표시
    static func optionIcon(_ key: String) -> String {
        switch key {
        case "parking": return "car.fill"
        case "pet": return "pawprint.fill"
        case "elevator": return "arrow.up.arrow.down.square"
        case "aircon": return "air.conditioner.horizontal"
        case "fridge": return "refrigerator"
        case "washer": return "washer"
        case "bed": return "bed.double"
        case "desk": return "table.furniture"
        case "closet": return "cabinet"
        case "induction": return "cooktop"
        default: return "checkmark.circle"
        }
    }

    /// 채팅 날짜 구분선: "오늘" · "어제" · "10월 26일 (월)" · 다른 해면 "2025년 9월 24일 (수)"
    static func chatDay(_ d: Date, now: Date = Date(), calendar cal: Calendar = .current) -> String {
        if cal.isDate(d, inSameDayAs: now) { return "오늘" }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(d, inSameDayAs: y) { return "어제" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.dateFormat = cal.isDate(d, equalTo: now, toGranularity: .year) ? "M월 d일 (E)" : "yyyy년 M월 d일 (E)"
        return f.string(from: d)
    }

    /// 말풍선 옆 시각: "오후 3:12"
    static func chatClock(_ d: Date, calendar cal: Calendar = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.dateFormat = "a h:mm"
        return f.string(from: d)
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

extension UIImage {
    /// 긴 변이 maxPixel 을 넘으면 비율 유지로 줄인다 (업로드 용량 · 메모리 절약). 방향(EXIF)은 그리면서 반영된다.
    func downscaled(maxPixel: CGFloat) -> UIImage {
        let w = size.width * scale, h = size.height * scale
        let longest = max(w, h)
        guard longest > maxPixel, longest > 0 else { return self }
        let ratio = maxPixel / longest
        let target = CGSize(width: (w * ratio).rounded(), height: (h * ratio).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
