"""둘러방 데모 데이터(mock_seed.json) 생성기.

- 매물 12개 (중앙대 주변 흑석동·상도동·노량진/본동), 사진은 rooms.py 로 그린 일러스트
- 3D 공간: rooms.py 가 사진을 그릴 때 쓴 방 크기·가구 배치를 그대로 뷰어 좌표계로 옮긴다
  (사진 좌표: x 오른쪽, z 앞쪽(카메라→뒷벽) / 뷰어 좌표: x 오른쪽, z 뒤쪽 → z_v = -z)
- 입주 상태(개인 가구 제거), 내 가구 4개, 채팅 3개, 3D 생성 중인 매물 1개(작업 J105)
"""
import json, os, random, sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
OUT_DIR = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "Dulleobang", "Resources", "Mock")
SEED_VERSION = 3          # 2: 입주 상태가 사용자별(createdBy · status), 매물에 latestRoomStateId 없음
                          # 3: 공간에 glass(서버가 LiDAR 로 찾은 투명 유리) 추가
FRONT = -1.0          # 사진 좌표에서 앞벽(현관 쪽) 위치. 카메라는 z = -0.9 에서 뒷벽을 본다
H = 2.4               # 층고


def r(v):
    return round(v + 0.0, 3)


def room_params(idx):
    """rooms.py _room_impl 과 같은 난수 순서로 방 크기를 얻는다"""
    rnd = random.Random(idx * 7919)
    rw = rnd.choice([3.2, 3.4, 3.6, 3.8])
    rd = rnd.choice([3.8, 4.2, 4.6])
    return rw, rd


def obj(lid, name, cat, x0, x1, z0, z1, h, own, yaw=0):
    """사진 좌표의 축 정렬 상자 → SceneObject (position = 상자 중심)"""
    return {
        "objectId": f"{lid}-{name}",
        "category": cat,
        "position": {"x": r((x0 + x1) / 2), "y": r(h / 2), "z": r(-(z0 + z1) / 2)},
        "rotation": {"yaw": yaw},
        "dimensions": {"width": r(x1 - x0), "height": r(h), "depth": r(z1 - z0)},
        "ownershipType": own,
    }


def opening(oid, kind, x, y, z, yaw, w, h):
    return {"id": oid, "type": kind, "position": {"x": r(x), "y": r(y), "z": r(z)},
            "rotation": {"yaw": yaw}, "dimensions": {"width": w, "height": h, "depth": 0.1}}


def space_for(lid, idx, unclassified=None):
    rw, rd = room_params(idx)
    L, R = -rw / 2, rw / 2
    v = idx % 5
    objects = []
    P, RO = "PERSONAL", "RENTAL_OPTION"

    def front_kitchen():
        # 앞벽(현관 쪽)에 붙어 있으므로 문짝이 방 안쪽(-z_v)을 보게 yaw 180
        objects.append(obj(lid, "fridge", "refrigerator", L + 0.05, L + 0.65, FRONT + 0.02, FRONT + 0.64, 1.55, RO, yaw=180))
        objects.append(obj(lid, "sink", "sink", L + 0.7, L + 1.9, FRONT + 0.02, FRONT + 0.62, 0.9, RO, yaw=180))

    if v == 0:      # 원룸: 붙박이장 · 침대(오른쪽) · 책상+의자(왼쪽)
        objects.append(obj(lid, "wardrobe", "storage", L + 0.05, L + 0.95, rd - 0.65, rd - 0.05, 1.95, RO))
        objects.append(obj(lid, "bed", "bed", R - 1.15, R - 0.05, rd - 2.05, rd - 0.05, 0.95, P))
        objects.append(obj(lid, "desk", "table", L + 0.05, L + 1.15, 1.3, 1.9, 0.75, P))
        objects.append(obj(lid, "chair", "chair", L + 0.35, L + 0.8, 1.0, 1.45, 0.95, P, yaw=180))
        front_kitchen()
    elif v == 1:    # 소파 + 선반
        objects.append(obj(lid, "sofa", "sofa", -0.85, 0.85, rd - 1.0, rd - 0.15, 0.85, P))
        sx0 = max(R - 0.85, 0.88)
        objects.append(obj(lid, "shelf", "storage", sx0, sx0 + 0.8, rd - 0.4, rd - 0.05, 1.2, P))
        front_kitchen()
    elif v == 2:    # 침대(가운데) + 협탁 2
        objects.append(obj(lid, "bed", "bed", -0.75, 0.75, rd - 2.1, rd - 0.1, 0.95, P))
        objects.append(obj(lid, "nightstand-l", "storage", -1.2, -0.85, rd - 0.45, rd - 0.05, 0.5, P))
        objects.append(obj(lid, "nightstand-r", "storage", 0.85, 1.2, rd - 0.45, rd - 0.05, 0.5, P))
        front_kitchen()
    elif v == 3:    # 주방 겸 원룸: 냉장고 · 세탁기 · 싱크대(뒷벽) + 책상·의자
        objects.append(obj(lid, "fridge", "refrigerator", L + 0.05, L + 0.65, rd - 0.7, rd - 0.08, 1.55, RO))
        objects.append(obj(lid, "washer", "washerDryer", L + 0.7, L + 1.3, rd - 0.65, rd - 0.05, 0.85, RO))
        objects.append(obj(lid, "sink", "sink", L + 1.35, L + 2.4, rd - 0.62, rd - 0.02, 0.88, RO))
        objects.append(obj(lid, "desk", "table", R - 1.3, R - 0.1, 1.6, 2.2, 0.75, P))
        objects.append(obj(lid, "chair", "chair", R - 0.9, R - 0.45, 1.25, 1.7, 0.95, P, yaw=180))
    else:           # 빈 방 + 붙박이장
        objects.append(obj(lid, "wardrobe", "storage", R - 0.95, R - 0.05, rd - 0.62, rd - 0.02, 1.95, RO))
        front_kitchen()

    for o in objects:
        if unclassified and o["objectId"].endswith(unclassified):
            o["ownershipType"] = None

    windows, doors = [], []
    if v in (0, 2, 4):
        windows.append(opening(f"{lid}-window", "window", 0, 1.5, -rd, 0, 1.4, 1.1))
    else:
        windows.append(opening(f"{lid}-window", "window", L, 1.475, -(rd - 1.55), 90, 1.3, 1.05))
    if v in (1, 3, 4):
        doors.append(opening(f"{lid}-door", "door", R, 1.05, -0.75, 90, 0.9, 2.1))
    else:
        doors.append(opening(f"{lid}-door", "door", R - 0.55, 1.05, -FRONT, 0, 0.9, 2.1))

    # 서버(tools/capture/glass_tools.py)가 LiDAR 로 찾는 투명 유리. 데모에서는 창마다 맑은 유리가 있다고 본다
    glass = [{"objectId": f"{lid}-glass-{k + 1}", "category": "glass", "glassKind": "window",
              "position": dict(w["position"]), "rotation": dict(w["rotation"]),
              "dimensions": {"width": w["dimensions"]["width"], "height": w["dimensions"]["height"], "depth": 0.01}}
             for k, w in enumerate(windows)]

    zb, zf = -rd, -FRONT
    walls = [
        {"id": f"{lid}-wall-back", "from": [r(L), r(zb)], "to": [r(R), r(zb)], "height": H},
        {"id": f"{lid}-wall-right", "from": [r(R), r(zb)], "to": [r(R), r(zf)], "height": H},
        {"id": f"{lid}-wall-front", "from": [r(R), r(zf)], "to": [r(L), r(zf)], "height": H},
        {"id": f"{lid}-wall-left", "from": [r(L), r(zf)], "to": [r(L), r(zb)], "height": H},
    ]
    depth = rd - FRONT
    space = {
        "roomGeometry": {
            "floorHeight": 0.0,
            "ceilingHeight": H,
            "walls": walls,
            "doors": doors,
            "windows": windows,
            "boundingBox": {"min": {"x": r(L), "y": 0.0, "z": r(zb)}, "max": {"x": r(R), "y": H, "z": r(zf)}},
        },
        "roomDimensions": {"width": rw, "depth": r(depth), "height": H, "area": r(rw * depth)},
        "objects": objects,
        "glass": glass,
    }
    return space, rw * depth


AGENTS = [
    {"userId": "9001", "name": "차유현", "officeName": "중앙공인중개사사무소", "phone": "010-0000-1001"},
    {"userId": "9002", "name": "김도윤", "officeName": "상도역 공인중개사", "phone": "010-0000-1002"},
    {"userId": "9003", "name": "이서진", "officeName": "노량진 한강부동산", "phone": "010-0000-1003"},
]

# (id, 주소, 좌표, 거래, 보증금, 월세, 방종류, 층, 건물층, 관리비, 입주, 옵션, 생활환경, 담당, 3D 상태)
L = [
    ("101", "서울 동작구 흑석동 중앙하이츠 402호", (37.5069, 126.9598), "MONTHLY", 1000, 57, "ONE_ROOM", 4, 5, 7, "IMMEDIATE",
     ["aircon", "fridge", "washer", "closet", "induction"],
     "중앙대 정문 도보 4분, 흑석역(9호선) 도보 8분. 1층에 편의점이 있고 골목 안쪽이라 조용해요.", "9001", "COMPLETED"),
    ("102", "서울 동작구 상도동 상도그린빌 201호", (37.5031, 126.9489), "MONTHLY", 500, 31, "ONE_ROOM", 2, 4, 5, "2026-10-15",
     ["aircon", "fridge", "washer", "induction"],
     "상도역(7호선) 도보 6분. 시장·마트가 가깝고 버스 정류장 바로 앞. 오래된 건물이지만 올수리했어요.", "9002", "COMPLETED"),
    ("103", "서울 동작구 흑석동 흑석리버뷰 303호", (37.5081, 126.9621), "MONTHLY", 700, 48, "ONE_ROOM", 3, 5, 6, "IMMEDIATE",
     ["aircon", "fridge", "washer", "bed", "induction"],
     "중앙대 후문 도보 6분. 남향 큰 창으로 채광이 좋아요. 주변에 카페·식당이 많습니다.", "9001", "NONE"),
    ("104", "서울 동작구 상도동 새싹빌 302호", (37.5018, 126.9534), "MONTHLY", 1000, 54, "ONE_ROOM", 3, 4, 8, "2026-11-01",
     ["aircon", "fridge", "washer", "induction"],
     "상도역 도보 9분. 주방 겸 원룸 구조, 세탁기·냉장고는 새 제품(옵션)이에요.", "me", "COMPLETED"),
    ("105", "서울 동작구 노량진동 노량진스테이 501호", (37.5112, 126.9471), "MONTHLY", 1500, 62, "ONE_ROOM", 5, 7, 9, "IMMEDIATE",
     ["aircon", "fridge", "washer", "closet", "elevator", "induction"],
     "노량진역(1·9호선) 도보 7분. 학원가·독서실 인접, 엘리베이터 있음. 비어 있는 넓은 방이라 가구 배치가 자유로워요.", "9003", "RUNNING"),
    ("106", "서울 동작구 흑석동 흑석역 센트럴오피스텔 702호", (37.5083, 126.9652), "MONTHLY", 1000, 80, "OFFICETEL", 7, 12, 12, "IMMEDIATE",
     ["aircon", "fridge", "washer", "closet", "elevator", "parking", "induction"],
     "흑석역 3번 출구 도보 2분 역세권 오피스텔. 무인택배함, 24시간 보안.", "9001", "COMPLETED"),
    ("107", "서울 동작구 상도동 푸른마을 301호", (37.4998, 126.9502), "JEONSE", 25000, 0, "TWO_ROOM", 3, 4, 10, "2026-12-01",
     ["aircon", "parking", "induction"],
     "상도근린공원 바로 앞 조용한 주택가 투룸. 거실 분리형, 주차 1대 가능.", "9002", "NONE"),
    ("108", "서울 동작구 흑석동 명수대빌라 101호", (37.5094, 126.9608), "MONTHLY", 300, 45, "ONE_ROOM", 1, 4, 5, "IMMEDIATE",
     ["aircon", "fridge", "washer"],
     "중앙대 정문 도보 3분. 1층이라 출입이 편하고 보증금 부담이 적어요.", "9001", "COMPLETED"),
    ("109", "서울 동작구 상도동 상도힐 202호", (37.4985, 126.9541), "MONTHLY", 2000, 40, "ONE_ROOM", 2, 5, 7, "2026-10-20",
     ["aircon", "fridge", "washer", "induction"],
     "상도역 도보 10분. 보증금 조정 가능(협의). 주방이 넓은 원룸이에요.", "me", "NONE"),
    ("110", "서울 동작구 본동 한강하우스 401호", (37.5106, 126.9552), "JEONSE", 18000, 0, "ONE_ROOM", 4, 6, 8, "2026-11-15",
     ["aircon", "fridge", "closet", "elevator", "induction"],
     "노들역(9호선) 도보 5분, 한강공원 산책로가 가까워요. 전세자금대출 가능.", "9003", "COMPLETED"),
    ("111", "서울 동작구 흑석동 한강뷰캐슬 602호", (37.5108, 126.9638), "MONTHLY", 3000, 90, "TWO_ROOM", 6, 8, 15, "2026-10-10",
     ["aircon", "fridge", "washer", "closet", "elevator", "parking", "induction"],
     "흑석동 한강변 신축 투룸. 거실에서 한강이 보이고 엘리베이터·주차 가능.", "9001", "NONE"),
    ("112", "서울 동작구 상도동 상도역 스카이오피스텔 905호", (37.5040, 126.9466), "MONTHLY", 1000, 65, "OFFICETEL", 9, 15, 10, "IMMEDIATE",
     ["aircon", "fridge", "washer", "elevator", "parking", "induction", "pet"],
     "상도역 1번 출구 도보 1분. 소형 반려동물 가능, 무인택배함.", "9002", "COMPLETED"),
]
RANK = ["106", "101", "102", "108", "112", "104", "110", "105", "103", "107", "109", "111"]
ROOM_STATES = ["101", "102", "106", "108", "112"]
UNCLASSIFIED = {"104": "chair"}      # 중개사(내 매물)가 직접 분류해 보도록 하나 남겨 둔다


def build():
    listings, spaces, room_states, jobs = [], {}, {}, []
    for (lid, loc, (lat, lng), deal, dep, mon, rtype, fl, tfl, fee, avail, opts, env, owner, st3d) in L:
        n = int(lid) - 100
        idx = n - 1
        space, room_area = space_for(lid, idx, UNCLASSIFIED.get(lid))
        extra = {"ONE_ROOM": 3.3, "OFFICETEL": 3.6, "TWO_ROOM": 18.5}[rtype]
        area = round(room_area + extra, 2)
        supply = round(area * {"ONE_ROOM": 1.32, "OFFICETEL": 1.9, "TWO_ROOM": 1.3}[rtype], 2)
        imgs = [f"bundle://Mock/L{n:02d}_{k}.jpg" for k in (1, 2, 3)] + [f"bundle://Mock/bath_{(idx % 3) + 1}.jpg"]
        info = {"status": st3d}
        if st3d in ("COMPLETED", "RUNNING"):
            spaces[lid] = dict(space, spaceVersion=1, objectsVersion=1)
        if st3d == "RUNNING":
            info["jobId"] = "J105"
            jobs.append({"jobId": "J105", "kind": "SPACE", "targetId": lid, "duration": 45, "finished": False})
        if lid in ROOM_STATES:
            # 명세 v1: 입주 상태는 만든 사람만 본다. "me" = 로그인한 사용자가 처음부터 가지고 있는 입주 상태
            rs = f"RS{lid}"
            removed = [o["objectId"] for o in space["objects"] if o["ownershipType"] == "PERSONAL"]
            room_states[rs] = {"roomStateId": rs, "listingId": lid, "createdBy": "me", "status": "READY",
                               "sourceSpaceVersion": 1, "sourceObjectsVersion": 1,
                               "createdAt": f"2026-09-2{n % 10}T0{n % 10}:00:00Z", "removedObjectIds": removed}
        listing = {
            "listingId": lid, "location": loc, "price": {"deposit": dep, "monthly": mon}, "dealType": deal,
            "maintenanceFee": fee, "roomType": rtype, "floor": fl, "totalFloors": tfl, "area": area, "supplyArea": supply,
            "rooms": 2 if rtype == "TWO_ROOM" else 1, "bathrooms": 1, "availableFrom": avail, "rentalOptions": opts,
            "thumbnailUri": imgs[0], "imageUris": imgs, "latitude": lat, "longitude": lng, "livingEnvironment": env,
            "space3DInfo": info,
        }
        entry = {"listing": listing, "ownerId": owner, "rank": RANK.index(lid) + 1}
        if owner == "me":
            entry["fallbackOwnerId"] = "9002"
        listings.append(entry)

    furniture = [
        {"furnitureId": "201", "name": "슈퍼싱글 침대", "category": "bed", "status": "COMPLETED", "modelUri": "box",
         "dimensions": {"width": 1.1, "height": 0.9, "depth": 2.05}, "thumbnailUri": "bundle://Mock/F_bed.jpg"},
        {"furnitureId": "202", "name": "컴퓨터 책상", "category": "desk", "status": "COMPLETED", "modelUri": "box",
         "dimensions": {"width": 1.2, "height": 0.74, "depth": 0.6}, "thumbnailUri": "bundle://Mock/F_desk.jpg"},
        {"furnitureId": "203", "name": "2도어 옷장", "category": "closet", "status": "COMPLETED", "modelUri": "box",
         "dimensions": {"width": 0.9, "height": 1.8, "depth": 0.5}, "thumbnailUri": "bundle://Mock/F_closet.jpg"},
        {"furnitureId": "204", "name": "2인 소파", "category": "sofa", "status": "COMPLETED", "modelUri": "box",
         "dimensions": {"width": 1.5, "height": 0.8, "depth": 0.8}, "thumbnailUri": "bundle://Mock/F_sofa.jpg"},
    ]

    chats = [
        {"chatId": "C1", "listingId": "102", "agentId": "9002", "unread": 1, "messages": [
            {"fromMe": False, "text": "안녕하세요, 상도역 공인중개사 김도윤입니다. 문의 주신 매물은 아직 계약 가능합니다.", "minutesAgo": 2890},
            {"fromMe": True, "text": "혹시 관리비에 인터넷도 포함인가요?", "minutesAgo": 2870},
            {"fromMe": False, "text": "네, 관리비 5만 원에 인터넷·수도가 포함이고 전기·가스는 따로 나옵니다.", "minutesAgo": 2862},
            {"fromMe": True, "text": "이번 주 토요일에 방 보러 가도 될까요?", "minutesAgo": 35},
            {"fromMe": False, "text": "토요일 오후 2시 괜찮으세요? 앱에서 3D로 먼저 둘러보고 오시면 더 좋아요.", "minutesAgo": 12},
        ]},
        {"chatId": "C2", "listingId": "101", "agentId": "9001", "unread": 0, "messages": [
            {"fromMe": True, "text": "입주 날짜 조율 가능할까요? 10월 중순쯤 들어가고 싶어요.", "minutesAgo": 1600},
            {"fromMe": False, "text": "집주인분께 여쭤보니 10월 15일 이후면 가능하다고 하십니다.", "minutesAgo": 1540},
            {"fromMe": True, "text": "감사합니다! 계약 전에 한 번 더 연락드릴게요.", "minutesAgo": 1535},
        ]},
        {"chatId": "C3", "listingId": "108", "agentId": "9001", "unread": 2, "messages": [
            {"fromMe": False, "text": "문의하신 흑석동 원룸 사진을 추가로 올려 두었어요.", "minutesAgo": 190},
            {"fromMe": False, "text": "‘입주 예상 공간’에서 기존 가구를 뺀 모습도 확인해 보세요.", "minutesAgo": 188},
        ]},
    ]

    return {
        "seedVersion": SEED_VERSION,
        "agents": AGENTS,
        "listings": listings,
        "spaces": spaces,
        "roomStates": room_states,
        "furniture": furniture,
        "chats": chats,
        "jobs": jobs,
        "defaultScraps": ["106", "101"],
    }


if __name__ == "__main__":
    os.makedirs(OUT_DIR, exist_ok=True)
    seed = build()
    with open(os.path.join(OUT_DIR, "mock_seed.json"), "w", encoding="utf-8") as f:
        json.dump(seed, f, ensure_ascii=False, indent=1)
    print("listings", len(seed["listings"]), "spaces", len(seed["spaces"]), "roomStates", len(seed["roomStates"]))
    for e in seed["listings"]:
        l = e["listing"]
        print(l["listingId"], l["roomType"], l["area"], seed["spaces"].get(l["listingId"], {}).get("roomDimensions"))
