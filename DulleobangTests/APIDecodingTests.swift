import XCTest
@testable import Dulleobang

/// 백엔드 응답 형태가 조금 달라도(숫자 ID · 봉투 · Spring Page · StayView 필드명) 디코딩되는지
final class APIDecodingTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    func testNumericIdsDecodeAsStrings() throws {
        let l = try decode(Listing.self, #"""
        {"listingId": 12, "location": "서울 동작구 상도동", "price": {"deposit": 500, "monthly": 31},
         "space3DInfo": {"status": "COMPLETED", "jobId": 7, "latestRoomStateId": 3},
         "agent": {"userId": 5, "name": "차유현"}}
        """#)
        XCTAssertEqual(l.listingId, "12")
        XCTAssertEqual(l.space3DInfo?.jobId, "7")          // 예전 서버의 latestRoomStateId 는 무시한다 (입주 상태는 사용자별)
        XCTAssertEqual(l.agent?.userId, "5")
        XCTAssertTrue(l.isSpaceReady)
    }

    func testStayViewFieldNamesDecode() throws {
        let l = try decode(Listing.self, #"""
        {"spaceId": 3, "address": "서울 동작구 상도동", "deposit": 1000, "monthlyRent": 54, "maintenanceFee": 6,
         "roomType": "ONE_ROOM", "availableDate": "2026-10-01",
         "images": [{"imageUrl": "/b.jpg", "imageOrder": 2}, {"imageUrl": "/a.jpg", "imageOrder": 1}]}
        """#)
        XCTAssertEqual(l.listingId, "3")
        XCTAssertEqual(l.location, "서울 동작구 상도동")
        XCTAssertEqual(l.price, Price(deposit: 1000, monthly: 54))
        XCTAssertEqual(l.imageUris, ["/a.jpg", "/b.jpg"])
        XCTAssertEqual(Fmt.available(l.availableFrom), "2026.10.01")
    }

    func testMissingOptionalIdDecodesToNil() throws {
        let job = try decode(AIJob.self, #"{"jobId": "j1", "status": "RUNNING"}"#)
        XCTAssertEqual(job.jobId, "j1")
        XCTAssertNil(job.roomStateId)
        XCTAssertNil(job.percent)
    }

    func testEnvelopeIsUnwrapped() throws {
        let r: OpenChatResponse = try APIClient.decodeResponse(Data(#"{"status": 200, "message": "OK", "data": {"chatId": 9}}"#.utf8))
        XCTAssertEqual(r.chatId, "9")
    }

    func testFlexibleListAcceptsCommonShapes() throws {
        let page = #"{"success": true, "data": {"content": [{"listingId": 1, "location": "흑석동", "price": {"deposit": 500, "monthly": 50}}], "totalElements": 1}}"#
        XCTAssertEqual(try APIClient.decodeResponse(Data(page.utf8), as: FlexibleList<Listing>.self).items.map(\.listingId), ["1"])

        let plain = #"[{"listingId": "a", "location": "x", "price": {"deposit": 1, "monthly": 1}}]"#
        XCTAssertEqual(try APIClient.decodeResponse(Data(plain.utf8), as: FlexibleList<Listing>.self).items.count, 1)

        let keyed = #"{"listings": []}"#
        XCTAssertEqual(try APIClient.decodeResponse(Data(keyed.utf8), as: FlexibleList<Listing>.self).items.count, 0)
    }

    func testRoomStateRemovedIdsAcceptNumbers() throws {
        let rs = try decode(RoomState.self, #"{"roomStateId": 4, "removedObjectIds": [3, "o7"]}"#)
        XCTAssertEqual(rs.roomStateId, "4")
        XCTAssertEqual(rs.removedObjectIds, ["3", "o7"])
        XCTAssertNil(rs.remainingObjects)
        XCTAssertTrue(rs.isReady)                          // status 가 없으면 완성본으로 본다
    }

    func testRoomStateStatusAndRemovableRules() throws {
        let rs = try decode(RoomState.self, #"{"roomStateId": "rs1", "listingId": 7, "createdBy": 5, "status": "PROCESSING", "jobId": 9, "removedObjectIds": ["a"]}"#)
        XCTAssertEqual(rs.listingId, "7")
        XCTAssertEqual(rs.createdBy, "5")
        XCTAssertTrue(rs.isProcessing)
        XCTAssertFalse(rs.isReady)

        func obj(_ category: String, _ type: String?, removable: Bool? = nil) -> SceneObject {
            SceneObject(objectId: category, category: category, position: .zero, rotation: Rotation(yaw: 0),
                        dimensions: Dimensions(width: 1, height: 1, depth: 1), ownershipType: type, removable: removable)
        }
        XCTAssertTrue(obj("bed", "PERSONAL").canRemove)
        XCTAssertFalse(obj("bed", "RENTAL_OPTION").canRemove)
        XCTAssertFalse(obj("bed", "UNKNOWN").canRemove)
        XCTAssertTrue(obj("bed", "UNKNOWN").isUnclassified)
        XCTAssertFalse(obj("sink", "PERSONAL").canRemove)                  // 고정 설비
        XCTAssertTrue(obj("sink", "PERSONAL", removable: true).canRemove)  // 서버가 정해 주면 그 값을 따른다
        XCTAssertFalse(obj("bed", "PERSONAL", removable: false).canRemove)

        // 최신순 정렬: createdAt 이 같거나 없으면 받은 순서
        let a = RoomState(roomStateId: "a", createdAt: "2026-09-21T01:00:00Z")
        let b = RoomState(roomStateId: "b", createdAt: "2026-09-30T01:00:00Z")
        let c = RoomState(roomStateId: "c")
        XCTAssertEqual(RoomStateAPI.newestFirst([a, c, b]).map(\.roomStateId), ["b", "a", "c"])

        // 다시 촬영(공간 버전 2)하기 전에 만든 입주 상태는 건너뛰고, 만드는 중인 것도 건너뛴다
        let old = RoomState(roomStateId: "old", status: "READY", sourceSpaceVersion: 1, createdAt: "2026-09-29T01:00:00Z")
        let busy = RoomState(roomStateId: "busy", status: "PROCESSING", sourceSpaceVersion: 2, createdAt: "2026-09-30T02:00:00Z")
        let good = RoomState(roomStateId: "good", status: "READY", sourceSpaceVersion: 2, createdAt: "2026-09-30T01:00:00Z")
        XCTAssertEqual(RoomStateAPI.pickLatestReady([old, busy, good], spaceVersion: 2)?.roomStateId, "good")
        XCTAssertEqual(RoomStateAPI.pickLatestReady([old], spaceVersion: 1)?.roomStateId, "old")
        XCTAssertNil(RoomStateAPI.pickLatestReady([old, busy], spaceVersion: 2))
    }

    func testListingRoundTripsThroughEncoder() throws {
        let l = Listing(listingId: "L1", location: "흑석동", price: Price(deposit: 500, monthly: 50), roomType: "ONE_ROOM", floor: 3)
        let back = try JSONDecoder().decode(Listing.self, from: JSONEncoder().encode(l))
        XCTAssertEqual(back, l)
    }

    func testChatMessageAcceptsContentField() throws {
        let m = try decode(ChatMessage.self, #"{"id": 1, "senderId": 2, "content": "안녕하세요", "createdAt": "2026-09-24T14:03:00"}"#)
        XCTAssertEqual(m.messageId, "1")
        XCTAssertEqual(m.senderId, "2")
        XCTAssertEqual(m.message, "안녕하세요")
        XCTAssertNotNil(Fmt.parseDate(m.sentAt))
    }

    func testAPIErrorServerMessage() {
        XCTAssertEqual(APIError(status: 400, body: #"{"message": "주소를 입력해 주세요"}"#).serverMessage, "주소를 입력해 주세요")
        XCTAssertNil(APIError(status: 500, body: "Internal Server Error").serverMessage)
        XCTAssertTrue(APIError(status: 404, body: "").isMissingEndpoint)
    }
}

final class FormattingTests: XCTestCase {
    func testWon() {
        XCTAssertEqual(Fmt.won(25000), "2억 5000")
        XCTAssertEqual(Fmt.won(20000), "2억")
        XCTAssertEqual(Fmt.won(5000), "5000")
    }

    func testPriceLabels() {
        let monthly = Listing(listingId: "1", location: "", price: Price(deposit: 500, monthly: 31))
        let jeonse = Listing(listingId: "2", location: "", price: Price(deposit: 25000, monthly: 0))
        XCTAssertEqual(Fmt.price(monthly), "월세 500/31")
        XCTAssertEqual(Fmt.price(jeonse), "전세 2억 5000")
        XCTAssertEqual(Fmt.priceShort(monthly), "500/31")
        XCTAssertEqual(Fmt.priceShort(jeonse), "2억 5000")
    }

    func testCardDetail() {
        var l = Listing(listingId: "1", location: "", price: Price(deposit: 500, monthly: 31), maintenanceFee: 5, floor: 3)
        XCTAssertEqual(Fmt.cardDetail(l), "3층, 관리비 5만")
        l.floor = nil
        l.area = 26.44
        l.availableFrom = "IMMEDIATE"
        XCTAssertEqual(Fmt.cardDetail(l), "26.44m² · 즉시")
    }

    func testShortLocation() {
        XCTAssertEqual(Fmt.shortLocation("서울 동작구 상도동 123-4, 302호"), "동작구 상도동")
        XCTAssertEqual(Fmt.shortLocation("서울 영등포구 당산동"), "영등포구 당산동")
    }

    func testAreasAndFloors() {
        let l = Listing(listingId: "1", location: "", price: Price(deposit: 1, monthly: 1),
                        floor: 3, totalFloors: 5, area: 23.8, supplyArea: 33.05)
        XCTAssertEqual(Fmt.floors(l), "3층 / 5층")
        XCTAssertEqual(Fmt.areas(l), "23.8m² / 33.05m²")
    }

    func testQueryParseAndMatch() {
        let q = ListingQuery.parse("상도동 원룸 월세")
        XCTAssertEqual(q.text, "상도동")
        XCTAssertEqual(q.roomType, "ONE_ROOM")
        XCTAssertEqual(q.dealType, "MONTHLY")
        let hit = Listing(listingId: "1", location: "서울 동작구 상도동", price: Price(deposit: 500, monthly: 31),
                          dealType: "MONTHLY", roomType: "ONE_ROOM")
        let miss = Listing(listingId: "2", location: "서울 동작구 흑석동", price: Price(deposit: 500, monthly: 31),
                           dealType: "MONTHLY", roomType: "ONE_ROOM")
        XCTAssertTrue(q.matches(hit))
        XCTAssertFalse(q.matches(miss))
    }
}

/// 데모 모드(서버 없이 둘러보기): 번들 시드가 앱 모델로 디코딩되고, 데모 백엔드가 주요 흐름에 응답하는지
final class MockBackendTests: XCTestCase {
    private let me = "12345"

    private func call<T: Decodable>(_ backend: MockBackend, _ method: String, _ path: String,
                                    query: [URLQueryItem] = [], body: (any Encodable)? = nil,
                                    parts: [MultipartPart] = [], headers: [String: String] = [:],
                                    as type: T.Type = T.self) async throws -> T {
        var r = MockRequest(method: method, path: path, query: query, parts: parts, userId: me, headers: headers)
        if let body { r.body = try JSONEncoder().encode(body) }
        let (data, resp) = await backend.respond(r)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw APIError(status: status, body: String(decoding: data, as: UTF8.self)) }
        return try APIClient.decodeResponse(data, as: T.self)
    }

    private func list<T: Decodable>(_ backend: MockBackend, _ path: String, query: [URLQueryItem] = [],
                                    of type: T.Type) async throws -> [T] {
        try await call(backend, "GET", path, query: query, as: FlexibleList<T>.self).items
    }

    func testBundledSeedMatchesModels() throws {
        let seed = try MockBackend.bundledSeed()
        XCTAssertEqual(seed.listings.count, 12)
        for m in seed.listings {
            let l = m.listing
            XCTAssertTrue(l.hasCoordinate, "\(l.listingId) 좌표")
            XCTAssertFalse(l.photoUris.isEmpty, "\(l.listingId) 사진")
            for uri in l.photoUris { XCTAssertNotNil(MockFiles.localURL(for: uri), "번들에 없는 사진: \(uri)") }
            if ["COMPLETED", "RUNNING"].contains(l.space3DInfo?.status ?? "") {
                let space = try XCTUnwrap(seed.spaces[l.listingId], "\(l.listingId) 3D 공간")
                XCTAssertEqual(space.roomGeometry?.walls.count, 4)
                XCTAssertFalse(space.objects.isEmpty)
            }
        }
        // 시드 입주 상태: 로그인한 사용자("me") 것이고, 개인 가구만 뺐다
        XCTAssertFalse(seed.roomStates.isEmpty)
        for (id, state) in seed.roomStates {
            XCTAssertEqual(state.roomStateId, id)
            XCTAssertEqual(state.createdBy, "me")
            XCTAssertTrue(state.isReady)
            let space = try XCTUnwrap(seed.spaces[state.listingId ?? ""], "\(id) 의 매물 공간")
            XCTAssertFalse(state.removedObjectIds.isEmpty)
            for oid in state.removedObjectIds {
                let o = try XCTUnwrap(space.objects.first { $0.objectId == oid }, "\(id): 없는 가구 \(oid)")
                XCTAssertTrue(o.canRemove, "\(id): \(oid) 는 뺄 수 없는 가구")
            }
            XCTAssertEqual(state.sourceObjectsVersion, space.objectsVersion)
        }
        XCTAssertTrue(seed.furniture.allSatisfy(\.isReady))
    }

    func testListingsDetailAndSpace() async throws {
        let backend = MockBackend(storeURL: nil)
        let all = try await list(backend, "listings", of: Listing.self)
        XCTAssertEqual(all.count, 12)
        let jeonse = try await list(backend, "listings", query: [URLQueryItem(name: "dealType", value: "JEONSE")], of: Listing.self)
        XCTAssertEqual(Set(jeonse.map(\.listingId)), ["107", "110"])

        let l: Listing = try await call(backend, "GET", "listings/101")
        XCTAssertEqual(l.agent?.name, "차유현")
        XCTAssertTrue(l.isSpaceReady)
        let space: SpaceResponse = try await call(backend, "GET", "listings/101/space")
        let room = Room(space: space)
        XCTAssertEqual(room.walls.count, 4)
        XCTAssertEqual(space.spaceVersion, 1)
        XCTAssertEqual(space.glass.count, room.windows.count, "데모 공간은 창마다 서버가 찾은 유리가 있다 (seed 3)")
        XCTAssertEqual(room.glass.count, space.glass.count)
        let mine = try await list(backend, "listings/101/room-states", of: RoomState.self)
        let rsId = try XCTUnwrap(mine.first?.roomStateId)
        let rs: RoomState = try await call(backend, "GET", "room-states/\(rsId)")
        XCTAssertEqual(rs.createdBy, me)
        XCTAssertLessThan(room.applying(rs).objects.count, room.objects.count)

        // 내 가구가 실제로 들어가는 자리를 찾는다 (가구 배치 · 매물 비교가 데모 공간에서 동작)
        let furniture = try await list(backend, "users/me/furniture", of: Furniture.self)
        XCTAssertEqual(furniture.count, 4)
        let bed = try XCTUnwrap(furniture.first { $0.category == "bed" }?.dimensions)
        XCTAssertNotNil(CollisionChecker.autoFit(bed, room: room.applying(rs)))
    }

    func testScrapChatAndAutoReply() async throws {
        let backend = MockBackend(storeURL: nil)
        let _: Empty = try await call(backend, "POST", "listings/103/scrap")
        let scraps = try await list(backend, "users/me/scraps", of: Listing.self)
        XCTAssertEqual(scraps.first?.listingId, "103")
        XCTAssertEqual(scraps.first?.isScrapped, true)

        let opened: OpenChatResponse = try await call(backend, "POST", "chat", body: OpenChatRequest(listingId: "103"))
        let again: OpenChatResponse = try await call(backend, "POST", "chat", body: OpenChatRequest(listingId: "103"))
        XCTAssertEqual(opened.chatId, again.chatId)
        let _: Empty = try await call(backend, "POST", "chat/\(opened.chatId)", body: SendMessageRequest(message: "주차 되나요?"))
        let detail: ChatRoomDetail = try await call(backend, "GET", "chat/\(opened.chatId)")
        XCTAssertEqual(detail.messages?.count, 2)                        // 인사 + 내 메시지 (답장은 몇 초 뒤)
        XCTAssertEqual(detail.messages?.last?.senderId, me)
        XCTAssertEqual(detail.counterpartName, "차유현")
        let rooms = try await list(backend, "chat", of: ChatRoomSummary.self)
        XCTAssertEqual(rooms.first?.chatId, opened.chatId)                // 최근 대화가 맨 위
        XCTAssertTrue(MockBackend.autoReply(to: "주차 되나요?", listing: nil).contains("주차"))
    }

    func testRegisterListingAndObjectClassification() async throws {
        // 기기의 개발자 설정(중개사 모드)이 켜져 있어도 결과가 같게: 처음엔 끄고, 끝나면 원래대로
        let previous = UserDefaults.standard.object(forKey: "localAgent")
        UserDefaults.standard.removeObject(forKey: "localAgent")
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: "localAgent") }
            else { UserDefaults.standard.removeObject(forKey: "localAgent") }
        }
        let backend = MockBackend(storeURL: nil)
        let req = CreateListingRequest(location: "서울 동작구 흑석동 테스트빌 101호", dealType: "MONTHLY",
                                       price: Price(deposit: 500, monthly: 40), maintenanceFee: 5, roomType: "ONE_ROOM",
                                       floor: 1, totalFloors: 3, area: 20, supplyArea: nil, rooms: 1, bathrooms: 1,
                                       availableFrom: "IMMEDIATE", rentalOptions: ["aircon"], latitude: nil, longitude: nil)
        let created: CreateListingResponse = try await call(backend, "POST", "listings", body: req)
        let mine = try await list(backend, "users/me/listings", of: Listing.self)
        let l = try XCTUnwrap(mine.first { $0.listingId == created.listingId })
        XCTAssertTrue(l.hasCoordinate)                                    // 지오코딩 없이도 지도에 찍힌다
        // 중개사 인증 없이도 올릴 수 있고, 집주인 직접 등록으로 표시된다 (연락처 비공개)
        XCTAssertEqual(l.agent?.userId, me)
        XCTAssertEqual(l.agent?.isVerifiedBroker, false)
        XCTAssertNil(l.agent?.phone)
        let brokerListing: Listing = try await call(backend, "GET", "listings/101")
        XCTAssertEqual(brokerListing.agent?.isVerifiedBroker, true)

        // 내가 올린 매물에 공간이 생기면 가구 구분은 내가(등록한 중개사) 할 수 있다. 바뀌면 objectsVersion 이 오른다
        let _: Accepted = try await call(backend, "POST", "listings/\(created.listingId)/captures")
        let before: SpaceResponse = try await call(backend, "GET", "listings/\(created.listingId)/space")
        XCTAssertEqual(before.spaceVersion, 1)
        let _: Empty = try await call(backend, "PATCH", "listings/\(created.listingId)/objects",
                                      body: ObjectOwnershipPatch(objects: []), headers: ["If-Match": "\"1\""])
        let after: SpaceResponse = try await call(backend, "GET", "listings/\(created.listingId)/space")
        XCTAssertEqual(after.objectsVersion, before.objectsVersion)          // 바뀐 게 없으면 그대로

        // 다른 중개사의 매물은 구분할 수 없다
        do {
            let _: Empty = try await call(backend, "PATCH", "listings/101/objects",
                                          body: ObjectOwnershipPatch(objects: [.init(objectId: "101-bed", ownershipType: "RENTAL_OPTION")]))
            XCTFail("남의 매물 구분이 통과됨")
        } catch let e as APIError {
            XCTAssertEqual(e.status, 403)
        }

        // 중개사(개발용 중개사 모드)가 자기 매물 104 의 미분류 의자를 개인 가구로 정하면 objectsVersion 이 오르고,
        // 예전 버전으로 보낸 입주 상태 요청은 409, 새 버전이면 그 의자를 뺄 수 있다
        UserDefaults.standard.set(true, forKey: "localAgent")
        let s104: SpaceResponse = try await call(backend, "GET", "listings/104/space")
        let chair = try XCTUnwrap(s104.objects.first { $0.isUnclassified }?.objectId)
        let _: Empty = try await call(backend, "PATCH", "listings/104/objects",
                                      body: ObjectOwnershipPatch(objects: [.init(objectId: chair, ownershipType: "PERSONAL")]),
                                      headers: ["If-Match": "\"\(s104.objectsVersion ?? 1)\""])
        let s104b: SpaceResponse = try await call(backend, "GET", "listings/104/space")
        XCTAssertEqual(s104b.objectsVersion, (s104.objectsVersion ?? 1) + 1)
        do {
            let _: Accepted = try await call(backend, "POST", "listings/104/room-states",
                                             body: RoomStateRequest(sourceSpaceVersion: s104.spaceVersion,
                                                                    sourceObjectsVersion: s104.objectsVersion, removedObjectIds: [chair]))
            XCTFail("예전 구분 버전인데 통과됨")
        } catch let e as APIError {
            XCTAssertEqual(e.status, 409)
        }
        let fresh: Accepted = try await call(backend, "POST", "listings/104/room-states",
                                             body: RoomStateRequest(sourceSpaceVersion: s104b.spaceVersion,
                                                                    sourceObjectsVersion: s104b.objectsVersion, removedObjectIds: [chair]))
        XCTAssertNotNil(fresh.roomStateId)

        // 중개사 인증 신청 → 심사 중
        let profile: AgentProfile = try await call(backend, "POST", "users/me/agent-profile", parts: [
            .field(name: "name", value: "홍길동"), .field(name: "licenseNumber", value: "1234"),
            .field(name: "officeName", value: "테스트 공인중개사"),
            .file(name: "document", filename: "doc.jpg", mimeType: "image/jpeg", data: Data([0xFF, 0xD8])),
        ])
        XCTAssertTrue(profile.isPending)
    }

    /// 명세 v1 입주 상태: 보는 사람이 각자 만들고, 만든 사람만 본다
    func testRoomStatesArePrivateAndValidated() async throws {
        let backend = MockBackend(storeURL: nil)
        let space: SpaceResponse = try await call(backend, "GET", "listings/108/space")
        let personal = space.objects.filter(\.canRemove).map(\.objectId)
        let rental = try XCTUnwrap(space.objects.first { $0.isRentalOption }?.objectId)
        XCTAssertFalse(personal.isEmpty)

        func expect(_ status: Int, _ body: RoomStateRequest, file: StaticString = #filePath, line: UInt = #line) async {
            do {
                let _: Accepted = try await call(backend, "POST", "listings/108/room-states", body: body)
                XCTFail("\(status) 이어야 하는데 통과됨", file: file, line: line)
            } catch let e as APIError {
                XCTAssertEqual(e.status, status, e.body, file: file, line: line)
            } catch {
                XCTFail("\(error)", file: file, line: line)
            }
        }
        await expect(422, RoomStateRequest(removedObjectIds: []))                          // 빈 목록
        await expect(422, RoomStateRequest(removedObjectIds: [rental]))                    // 임대 옵션은 못 뺀다
        await expect(422, RoomStateRequest(removedObjectIds: [personal[0], personal[0]]))  // 중복
        await expect(409, RoomStateRequest(sourceSpaceVersion: space.spaceVersion,
                                           sourceObjectsVersion: (space.objectsVersion ?? 1) + 1,
                                           removedObjectIds: [personal[0]]))               // 그 사이 구분이 바뀜

        // 개인 가구 하나만 빼 본다 → 만들자마자 목록 맨 앞에 "만드는 중"으로 보인다
        let acc: Accepted = try await call(backend, "POST", "listings/108/room-states",
                                           body: RoomStateRequest(sourceSpaceVersion: space.spaceVersion,
                                                                  sourceObjectsVersion: space.objectsVersion,
                                                                  removedObjectIds: [personal[0]]))
        let rsId = try XCTUnwrap(acc.roomStateId)
        let mine = try await list(backend, "listings/108/room-states", of: RoomState.self)
        XCTAssertEqual(mine.first?.roomStateId, rsId)
        XCTAssertEqual(mine.first?.isProcessing, true)
        XCTAssertEqual(mine.first?.removedObjectIds, [personal[0]])
        let job: AIJob = try await call(backend, "GET", "ai-jobs/\(acc.jobId)")
        XCTAssertFalse(job.isFailed)

        // 다른 사용자는 내 입주 상태를 볼 수도, 지울 수도 없다
        let other = MockRequest(method: "GET", path: "room-states/\(rsId)", userId: "99999")
        let (_, resp) = await backend.respond(other)
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 404)
        let (listData, _) = await backend.respond(MockRequest(method: "GET", path: "listings/108/room-states", userId: "99999"))
        let theirs = try APIClient.decodeResponse(listData, as: FlexibleList<RoomState>.self).items
        XCTAssertFalse(theirs.contains { $0.roomStateId == rsId })
        let (_, delResp) = await backend.respond(MockRequest(method: "DELETE", path: "room-states/\(rsId)", userId: "99999"))
        XCTAssertEqual((delResp as? HTTPURLResponse)?.statusCode, 404)

        // 나는 지울 수 있다
        let _: Empty = try await call(backend, "DELETE", "room-states/\(rsId)")
        let afterDelete = try await list(backend, "listings/108/room-states", of: RoomState.self)
        XCTAssertFalse(afterDelete.contains { $0.roomStateId == rsId })
    }

    /// 명세 v1 요청 안전장치: 같은 Idempotency-Key 는 한 번만 처리, 배치 저장 · 가구 구분은 ETag 로 덮어쓰기 방지
    func testIdempotencyAndPreconditions() async throws {
        let backend = MockBackend(storeURL: nil)
        func raw(_ method: String, _ path: String, body: (any Encodable)? = nil,
                 headers: [String: String] = [:]) async throws -> (status: Int, etag: String?, data: Data) {
            var r = MockRequest(method: method, path: path, userId: me, headers: headers)
            if let body { r.body = try JSONEncoder().encode(body) }
            let (data, resp) = await backend.respond(r)
            let http = resp as? HTTPURLResponse
            return (http?.statusCode ?? 0, http?.value(forHTTPHeaderField: "ETag"), data)
        }

        // 같은 키 · 같은 내용 → 같은 결과 (입주 상태가 두 개 생기지 않음), 같은 키 · 다른 내용 → 409
        let space: SpaceResponse = try await call(backend, "GET", "listings/106/space")
        let personal = space.objects.filter(\.canRemove).map(\.objectId)
        XCTAssertGreaterThanOrEqual(personal.count, 2)
        let key = ["Idempotency-Key": "k-1"]
        let first = try await raw("POST", "listings/106/room-states", body: RoomStateRequest(removedObjectIds: [personal[0]]), headers: key)
        let again = try await raw("POST", "listings/106/room-states", body: RoomStateRequest(removedObjectIds: [personal[0]]), headers: key)
        XCTAssertEqual(first.status, 202)
        XCTAssertEqual(again.status, 202)
        XCTAssertEqual(try APIClient.decodeResponse(first.data, as: Accepted.self).roomStateId,
                       try APIClient.decodeResponse(again.data, as: Accepted.self).roomStateId)
        let reused = try await raw("POST", "listings/106/room-states", body: RoomStateRequest(removedObjectIds: [personal[1]]), headers: key)
        XCTAssertEqual(reused.status, 409)

        // 배치: 첫 저장은 If-None-Match: *, 다음은 If-Match. 헤더가 없으면 428, 낡은 버전이면 412
        let body = PlacementsRequest(placements: [])
        let path = "listings/106/placements"
        let empty = try await raw("GET", path)
        XCTAssertNil(empty.etag)
        let noHeader = try await raw("PUT", path, body: body)
        XCTAssertEqual(noHeader.status, 428)
        let created = try await raw("PUT", path, body: body, headers: ["If-None-Match": "*"])
        XCTAssertEqual(created.status, 200)
        XCTAssertEqual(created.etag, "\"1\"")
        let duplicate = try await raw("PUT", path, body: body, headers: ["If-None-Match": "*"])
        XCTAssertEqual(duplicate.status, 412)
        let updated = try await raw("PUT", path, body: body, headers: ["If-Match": "\"1\""])
        XCTAssertEqual(updated.status, 200)
        XCTAssertEqual(updated.etag, "\"2\"")
        let stale = try await raw("PUT", path, body: body, headers: ["If-Match": "\"1\""])
        XCTAssertEqual(stale.status, 412)
        let current = try await raw("GET", path)
        XCTAssertEqual(current.etag, "\"2\"")

        // 앱이 붙이는 헤더 규칙
        XCTAssertTrue(RequestSafety.needsIdempotencyKey("POST"))
        XCTAssertFalse(RequestSafety.needsIdempotencyKey("GET"))
        XCTAssertTrue(RequestSafety.isCreateOrReplace("listings/106/placements"))
        XCTAssertFalse(RequestSafety.isCreateOrReplace("listings/106/objects"))
    }

    /// 이메일 가입 · 로그인, 카카오 · 구글(데모 토큰), 토큰 갱신
    func testEmailSocialAndRefreshLogin() async throws {
        let backend = MockBackend(storeURL: nil)
        func expectStatus(_ status: Int, _ work: () async throws -> Void, line: UInt = #line) async {
            do { try await work(); XCTFail("\(status) 이어야 하는데 통과됨", line: line) }
            catch let e as APIError { XCTAssertEqual(e.status, status, line: line) }
            catch { XCTFail("\(error)", line: line) }
        }
        let password = "correct horse battery"
        await expectStatus(422) {
            let _: Empty = try await self.call(backend, "POST", "auth/signup",
                                               body: SignupRequest(email: "a@b.com", password: "short", displayName: "가나"))
        }
        let _: Empty = try await call(backend, "POST", "auth/signup",
                                      body: SignupRequest(email: "A@b.com", password: password, displayName: "가나"))
        await expectStatus(409) {
            let _: Empty = try await self.call(backend, "POST", "auth/signup",
                                               body: SignupRequest(email: "a@b.com", password: password, displayName: "다라"))
        }
        await expectStatus(401) {
            let _: AuthResponse = try await self.call(backend, "POST", "auth/login",
                                                      body: LoginRequest(email: "a@b.com", password: "wrong password!!"))
        }
        let tokens: AuthResponse = try await call(backend, "POST", "auth/login", body: LoginRequest(email: "a@b.com", password: password))
        XCTAssertEqual(tokens.name, "가나")
        XCTAssertEqual(tokens.roles, ["TENANT"])
        let refresh = try XCTUnwrap(tokens.refreshToken)
        let next: AuthResponse = try await call(backend, "POST", "auth/refresh", body: RefreshRequest(refreshToken: refresh))
        XCTAssertEqual(next.userId, tokens.userId)
        XCTAssertNotEqual(next.refreshToken, refresh)                       // 매번 새 refresh 토큰
        await expectStatus(401) {
            let _: AuthResponse = try await self.call(backend, "POST", "auth/refresh", body: RefreshRequest(refreshToken: "garbage"))
        }
        let kakao: AuthResponse = try await call(backend, "POST", "auth/oauth/kakao", body: ["accessToken": "demo:c@d.com:카카오"])
        XCTAssertEqual(kakao.name, "카카오")
        XCTAssertNotEqual(kakao.userId, tokens.userId)                      // 이메일 계정과 자동으로 합치지 않는다

        // 명세의 TokenPair (user 안의 userId) 를 앱이 읽는다
        let json = #"{"accessToken":"a","refreshToken":"r","tokenType":"Bearer","expiresIn":900,"user":{"userId":"u1","email":"x@y.z","displayName":"홍","roles":["TENANT","BROKER"]}}"#
        let pair = try APIClient.decodeResponse(Data(json.utf8), as: AuthResponse.self)
        XCTAssertEqual(pair.userId, "u1")
        XCTAssertEqual(pair.name, "홍")
        XCTAssertEqual(pair.refreshToken, "r")
        XCTAssertEqual(pair.roles, ["TENANT", "BROKER"])
    }

    func testKoreanParticle() {
        XCTAssertEqual(Fmt.withAnd("침대"), "침대와")
        XCTAssertEqual(Fmt.withAnd("책상"), "책상과")
        XCTAssertEqual(Fmt.withAnd("TV"), "TV와")
        XCTAssertEqual(Fmt.objectLabel("washerDryer"), "세탁기")
    }
}

/// 앱 화면 개선: 카드 · 상세 문구, 빠른 필터(3D만), 채팅 날짜 구분 · 시각, 매물 등록 단계 확인
final class AppScreenTests: XCTestCase {
    private func listing(location: String = "서울 동작구 흑석동 중앙하이츠 402호", fee: Int? = 7, area: Double? = 23.06,
                         floor: Int? = 4, status: String? = nil) -> Listing {
        var l = Listing(listingId: "1", location: location, price: Price(deposit: 1000, monthly: 57), dealType: "MONTHLY",
                        maintenanceFee: fee, roomType: "ONE_ROOM", floor: floor, totalFloors: 5, area: area)
        if let status { l.space3DInfo = Space3DInfo(status: status) }
        return l
    }

    func testPyeongAndAreaShort() {
        XCTAssertEqual(Fmt.pyeong(23.06), "7평")
        XCTAssertEqual(Fmt.pyeong(21.54), "6.5평")
        XCTAssertEqual(Fmt.pyeong(34.82), "10.5평")
        XCTAssertEqual(Fmt.areaShort(23.06), "23.1㎡ · 7평")
    }

    func testCardLines() {
        let l = listing()
        XCTAssertEqual(Fmt.cardFacts(l), "원룸 · 7평 · 4층")
        XCTAssertEqual(Fmt.cardSub(l), "관리비 7만 · 흑석동")
        XCTAssertEqual(Fmt.feeShort(l), "7만 원")
        let bare = listing(location: "", fee: nil, area: nil, floor: nil)
        XCTAssertEqual(Fmt.cardFacts(bare), "원룸")
        XCTAssertEqual(Fmt.cardSub(bare), "관리비 협의")
        XCTAssertEqual(Fmt.feeShort(bare), "협의")
        XCTAssertEqual(Fmt.cardSub(listing(fee: 0)), "관리비 없음 · 흑석동")
    }

    func testDong() {
        XCTAssertEqual(Fmt.dong("서울 동작구 흑석동 중앙하이츠 402호"), "흑석동")
        XCTAssertEqual(Fmt.dong("서울 동작구 상도동 123-4, 302호"), "상도동")
        XCTAssertEqual(Fmt.dong("서울 영등포구"), "영등포구")
        XCTAssertEqual(Fmt.dong(""), "")
    }

    func testOptionIcons() {
        for o in Fmt.options { XCTAssertNotEqual(Fmt.optionIcon(o.key), "checkmark.circle", o.key) }
        XCTAssertEqual(Fmt.optionIcon("sauna"), "checkmark.circle")
    }

    func testSpaceOnlyFilter() {
        var q = ListingQuery()
        XCTAssertFalse(q.isFiltered)
        q.spaceOnly = true
        XCTAssertTrue(q.isFiltered)
        XCTAssertFalse(q.hasPriceLimit, "빠른 칩은 필터 버튼을 켜지 않는다")
        XCTAssertTrue(q.matches(listing(status: "COMPLETED")))
        XCTAssertFalse(q.matches(listing(status: "RUNNING")))
        XCTAssertFalse(q.matches(listing()))
        XCTAssertFalse(q.items.contains { $0.name.lowercased().contains("space") }, "서버에는 보내지 않고 받은 목록에서 거른다")
        q.maxDeposit = 1000
        XCTAssertTrue(q.hasPriceLimit)
    }

    func testChatTimelineDaysAndTimes() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let now = ISO8601DateFormatter().date(from: "2026-10-28T01:00:00Z")!     // 10월 28일 오전 10시 (한국)
        func msg(_ id: String, _ who: String, _ at: String) -> ChatMessage {
            ChatMessage(messageId: id, senderId: who, senderName: nil, message: id, sentAt: at)
        }
        let items = ChatTimeline.items([
            msg("a", "agent", "2026-10-26T06:12:00Z"),     // 월요일 오후 3:12
            msg("b", "me", "2026-10-26T06:32:10Z"),
            msg("c", "me", "2026-10-26T06:32:40Z"),        // 같은 사람 · 같은 분 → b 에는 시각을 붙이지 않는다
            msg("d", "agent", "2026-10-28T00:28:00Z"),     // 오늘 오전 9:28
        ], now: now, calendar: cal)
        XCTAssertEqual(items.count, 6)
        XCTAssertEqual(items[0], .day("10월 26일 (월)"))
        XCTAssertEqual(items[1], .message(msg("a", "agent", "2026-10-26T06:12:00Z"), time: "오후 3:12"))
        if case .message(_, let t) = items[2] { XCTAssertNil(t) } else { XCTFail("b") }
        if case .message(_, let t) = items[3] { XCTAssertEqual(t, "오후 3:32") } else { XCTFail("c") }
        XCTAssertEqual(items[4], .day("오늘"))
        if case .message(_, let t) = items[5] { XCTAssertEqual(t, "오전 9:28") } else { XCTFail("d") }
    }

    func testRegisterStepsCheckOnlyRequiredFields() {
        typealias V = ListingRegisterView
        XCTAssertEqual(V.Step.allCases.count, 5)
        XCTAssertNotNil(V.problem(for: .basics, address: "  ", dealType: "MONTHLY", deposit: "", monthly: "", area: ""))
        XCTAssertNil(V.problem(for: .basics, address: "서울 동작구 상도동", dealType: "MONTHLY", deposit: "", monthly: "", area: ""))
        XCTAssertNotNil(V.problem(for: .price, address: "", dealType: "MONTHLY", deposit: "500", monthly: "", area: ""))
        XCTAssertNil(V.problem(for: .price, address: "", dealType: "JEONSE", deposit: "25000", monthly: "", area: ""))
        XCTAssertNotNil(V.problem(for: .room, address: "", dealType: "MONTHLY", deposit: "", monthly: "", area: "0"))
        XCTAssertNil(V.problem(for: .room, address: "", dealType: "MONTHLY", deposit: "", monthly: "", area: "23.5"))
        XCTAssertNil(V.problem(for: .media, address: "", dealType: "MONTHLY", deposit: "", monthly: "", area: ""), "사진 · 촬영은 선택")
    }
}

/// 서버 주소를 따로 넣지 않으면 팀 GCP 서버로 간다 (기기에 저장해 둔 주소는 테스트 뒤 되돌림)
final class ServerConfigTests: XCTestCase {
    func testDefaultServerIsTeamBackend() {
        let saved = UserDefaults.standard.string(forKey: "baseURL")
        UserDefaults.standard.removeObject(forKey: "baseURL")
        defer { if let saved { UserDefaults.standard.set(saved, forKey: "baseURL") } }
        XCTAssertEqual(AppConfig.shared.baseURL.absoluteString, "http://34.47.87.3:8080/api")
        XCTAssertEqual(AssetURL.resolve("/files/a.ply")?.absoluteString, "http://34.47.87.3:8080/files/a.ply")
    }
}
