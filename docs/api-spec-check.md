# 둘러방 API 명세서 v1.0.0 ↔ iOS 앱 대조 결과

작성 2026-09-30 · 대조 대상: `둘러방_API_명세서_v1.0.pdf`(2026-09-22, 45 API / 84 모델)와 현재 앱 코드
(`Core/Network/Endpoints.swift`, `Core/Network/APIClient.swift`, `Core/Models/Models.swift`, 촬영 모듈, README §3·§4).
판정 기준은 "명세서대로 구현한 서버에 지금 앱을 붙이면 동작하는가"입니다.

**업데이트 (같은 날)**: 팀 결정에 따라 입주 상태를 명세 방식(보는 사람이 각자 만들고 본인만 봄)으로 바꿨습니다. 아래 표에서 입주 상태 관련 항목은 바뀐 앱 기준으로 고쳤고, 남은 차이는 응답 필드 모양과 공통 헤더뿐입니다.

## 결론

앱이 실제로 호출하는 API 31개 중 18개는 명세서에 같은 메서드·경로가 있고, 13개는 명세서에 없습니다(코드에만 있고 화면에서
쓰지 않는 `GET /listings/{id}/objects`, `DELETE /room-states/{id}` 는 제외). 경로가 같은 18개 중 요청·응답 모양까지 그대로 맞는 것은
입주 상태 변경 때 추가한 `GET /listings/{id}/room-states` 하나뿐이고, 나머지는 본문이나 필수 헤더가 다릅니다.
명세서대로 만든 서버에 연결하고 데모 모드를 끄면 로그인 단계에서 막힙니다.

명세서 2쪽에 "실제 코드나 운영 서버를 제공받지 않았으므로, 기존 구현과의 일치 또는 팀 승인 완료를 의미하지 않습니다"라고
적혀 있습니다. 두 문서가 서로를 보지 않고 따로 만들어졌기 때문에 생긴 차이이고, 어느 쪽을 기준으로 삼을지는 팀이 정해야
합니다(7장).

## 1. 명세서 서버에 연결하면 생기는 일

| 화면·기능 | 결과 | 원인 |
|---|---|---|
| 로그인 | 실패 | 앱이 부르는 `GET /auth/{kakao\|google}?email=&name=` 가 명세에 없어 404. 명세는 `POST /auth/signup`(비밀번호 12–128자) → `POST /auth/login` 이고, 응답 `TokenPair` 의 `user.userId` 를 앱 파서가 찾지 못해 로그인 API 만 바꿔도 실패 |
| 로그인 유지 | 15분 뒤 모든 요청 401 | access token 수명 15분, 앱에 토큰 갱신(`POST /auth/refresh`)이 없음 |
| 홈 추천 목록 | 뜨지만 내용이 틀림 | `/listings/recommended` 가 없어 앱이 `GET /listings` 로 대신함(여기까지는 정상). 가격이 원 단위라 앱이 만원으로 읽어 1만 배로 표시되고, 주소·사진·층·방 종류·면적이 비고, 관리비는 "협의"로 나오고, 3D 표시가 사라짐 |
| 검색(검색어 · 필터) | 400 오류 | 앱이 보내는 `location`, `dealType`, `roomType`, `maxPrice` 쿼리가 명세에 없고, 명세는 선언되지 않은 쿼리를 400 으로 거절. `maxDeposit` 만 쓰면 이름은 명세와 같아 200 이지만 만원 값이 원으로 해석돼 결과가 비어 있음 |
| 지도 | 핀이 하나도 안 뜸 | 지도는 조건 없이 목록을 받으므로 요청은 성공. 하지만 위도·경도가 `location` 객체 안에 있어 못 읽고, 주소도 빈 문자열이라 주소 검색(지오코딩)으로도 위치를 못 찾음 |
| 매물 3D 보기 | "아직 3D 공간이 없는 매물입니다" | 상세 화면은 매물의 `space3DInfo.status` 로 3D 여부를 판단하는데 명세 Listing 에는 이 필드가 없음(`hasSpace` · `currentSpaceVersion` 사용). 그래서 3D · 입주 예상 · 가구 놓아보기 버튼이 모두 사라지고 비교 화면도 비어 있음. 이 부분을 고쳐도 space 응답이 `{spaceVersion, bundle{sceneAsset…}}` 구조이고 파일이 URL 대신 `fileId` 라서 뷰어가 아무것도 읽지 못함 |
| 매물 등록 | 실패 | 요청 필드가 전부 다르고(제목·설명·법정동 코드 필수 등) `Idempotency-Key` 헤더가 필수 |
| 사진 · 촬영 업로드 | 실패 | 명세에는 multipart·zip 업로드가 없고, 업로드 세션(파일별 서명 URL 로 PUT + SHA-256 검증) 방식만 있음 |
| 매물 공개 | 불가능 | 명세는 등록 직후 DRAFT 이고 `PUT /listings/{id}/publication` 으로 게시해야 임차인에게 보임. 앱에는 게시 단계가 없음 |
| 중개사 인증 | 불가능 | 명세에는 신청 API 가 없음(운영자가 BROKER 역할을 부여). 앱은 역할(`user.roles`)을 읽지 않고 신청 상태로 중개사 여부를 판단 |
| 가구 목록 · 배치 | 모든 가구가 "3D 생성 중" | 모델 파일 구조(`modelUri` ↔ `model.modelAsset`)와 상태 값(`COMPLETED` ↔ `READY`)이 달라 완성된 가구도 계속 생성 중으로 보이고 배치 목록에서 고를 수 없음. 등록도 카테고리 값(`bed` ↔ `BED`) 때문에 거절 |
| 배치 저장 · 불러오기 (3D 화면에 들어간다고 가정) | 저장 실패, 불러오기는 조용히 빈 화면 | 저장 요청은 회전(yaw ↔ quaternion), `placementId`·`modelVersion`·`space` 필수, `If-None-Match`/`If-Match` 필수라 거절됨. 요청을 고쳐도 응답의 배치 항목을 앱이 읽지 못해 저장이 성공해도 오류로 표시 |
| 입주 상태(가구 빼기) | 흐름은 명세와 같음, 필드 모양만 다름 | 앱을 명세 방식으로 바꿈: 중개사는 가구 구분만, 보는 사람이 ‘가구 빼 보기’로 각자 만들고 본인만 봄, 버전(`sourceSpaceVersion`·`sourceObjectsVersion`) 전송, 뺄 가구 1개 이상 · 개인 가구만. 남은 차이: `Idempotency-Key`·`If-Match` 헤더, 결과가 `bundle` 이 아니라 `sceneUri`·`remainingObjects` 모양 |
| 채팅 · 신고 | 오류 | 채팅은 명세서 1장에서 "제외 범위", 신고 API 는 없음 |
| 관심 매물 | 기기에만 저장 | 명세에 없음. 앱이 이미 기기 저장으로 대신하므로 동작은 함 |

## 2. 공통 규칙 차이

| 항목 | 명세서 | 앱 | 맞추려면 |
|---|---|---|---|
| 기본 경로 | `/api/v1` | 기본값 `http://localhost:8080/api` | 설정 화면에서 서버 주소만 바꾸면 됨 |
| 인증 | `Authorization: Bearer` JWT (access 15분, refresh 14일·매번 회전) | `X-User-Id` 헤더 (토큰이 있으면 Bearer 도) | 앱에 가입·로그인·토큰 갱신 구현 |
| 역할 | `User.roles`: TENANT / BROKER, BROKER 는 운영자가 사전 등록 | `users/me/agent-profile` 신청·승인 상태 | 앱이 roles 로 중개사 판단 |
| 중복 요청 방지 | `Idempotency-Key` 필수: 매물·가구·업로드 세션 생성, 촬영 제출, 입주 상태 생성, 재시도, 토큰 갱신 | 없음 | 요청마다 UUID 헤더 |
| 동시 수정 방지 | `ETag` + `If-Match` 필수(없으면 428): 매물 수정·게시·삭제, 객체 분류, 가구 수정·삭제, 내 이름 수정, 배치 삭제. 배치 첫 저장은 `If-None-Match: *` | 없음 | 직전 GET 의 ETag 를 보관했다가 전송 |
| 모르는 필드 · 쿼리 | 422 / 400 으로 거절 | 서버가 모르는 필드는 무시한다고 가정하고 여분 필드를 보냄 | 명세 필드만 전송 |
| 목록 | `{items, page{nextCursor, hasNext}}`, 기본 20 · 최대 50 | `items` 는 읽음. 커서는 무시해서 첫 20개만 봄 | 커서 따라가기 |
| 오류 | `application/problem+json` `{status, code, detail, requestId, errors[]}` | `detail` 문구는 이미 읽음 | `code` 로 분기 추가 |
| 금액 | 원 (10000000 = 1천만 원) | 만원 | 표시·입력에서 변환 |
| 파일 | `AssetRef{fileId, contentType, byteSize, sha256, format}` → `GET /assets/{fileId}/download` 로 15분짜리 URL 발급 | 응답 안의 URL(`thumbnailUri`, `imageUris`, `3dgsUri`, `modelUri` …)을 바로 받음 | 다운로드 API 계층 + sha256 캐시 |
| 회전 | quaternion `{x,y,z,w}` (`Transform.rotation`) | yaw(도) `{yaw}` | 변환 (앱은 Y축 회전만 쓰므로 간단) |
| 객체 위치 | `transform.position` = 바닥 중심 | `position` = 상자 중심 | y 를 높이의 절반만큼 보정 |
| 열거값 | UPPER_SNAKE (`BED`, `WARDROBE`, `AIR_CONDITIONER`) | 소문자 (`bed`, `closet`, `aircon`) | 값 매핑 |
| ID | UUID 문자열 | 어떤 형식이든 받음 | 그대로 |
| 좌표계 | 미터, Y-up, 오른손, 카메라 −Z 정면 | 같음 | 그대로 |

## 3. 엔드포인트 대조

판정: ✗ 동작 안 함 · △ 경로는 같고 일부만 읽힘

| 앱 호출 | 명세서 | 판정 | 차이 |
|---|---|---|---|
| `GET /auth/{kakao\|google}?email=&name=` | `POST /auth/signup`, `POST /auth/login` | ✗ 없음 | 이메일 · 비밀번호 방식(가입 12–128자, 로그인 1–128자). 응답 형태 4.6 |
| `POST /auth/logout` | `POST /auth/logout` | △ | 명세는 본문 `{refreshToken}` 필수, 204. 앱은 본문 없음(오류를 무시하므로 치명적이지 않음) |
| `GET /users/me/agent-profile` | 없음 | ✗ 없음 | 중개사는 운영자가 등록하고 `User.roles` 로 확인 |
| `POST /users/me/agent-profile` (multipart) | 없음 | ✗ 없음 | 위와 같음 |
| `GET /users/me/listings` | 같음 | △ | BROKER 전용. 항목이 `ListingSummary` 라 필드가 다름(4.1) |
| `GET /users/me/scraps` | 없음 | ✗ 없음 | 앱이 기기 저장으로 대신함 |
| `GET /listings?location=&dealType=&roomType=&maxDeposit=&maxPrice=` | `GET /listings` | ✗ | 조건 없는 호출(홈 · 지도)은 성공하지만 검색어 · 필터를 넣으면 쿼리 이름이 달라 400, `maxDeposit` 은 단위(만원 ↔ 원)가 다름. 명세 쿼리: `regionCode`(법정동 10자리 정확 일치), `leaseType`, `propertyType`, `minDeposit`/`maxDeposit`·`minMonthlyRent`/`maxMonthlyRent`(원), `minAreaM2`/`maxAreaM2`, `rentalOptions`(반복), `hasSpace`, `sort`, `limit`, `cursor`. 지역명 텍스트 검색은 없음. 앱의 지도 범위 쿼리(`minLat…`)는 코드만 있고 보내지 않음 |
| `GET /listings/recommended` | 없음 | ✗ 없음 | 앱이 `GET /listings` 로 대신함(동작) |
| `GET /listings/{id}` | 같음 | △ | 필드가 다름(4.1) |
| `POST /listings` | 같음 | ✗ | 본문 전부 다름 + `Idempotency-Key`. 응답(Listing)의 `listingId` 는 앱이 읽음 |
| `POST /listings/{id}/images` (multipart) | 업로드 세션(LISTING_PHOTO) → `PATCH /listings/{id}` `{photoFileIds}` + `If-Match` | ✗ 없음 | 사진 최대 20장(앱은 30장까지 허용) |
| `POST` / `DELETE /listings/{id}/scrap` | 없음 | ✗ 없음 | 앱이 기기 저장으로 대신함 |
| `POST /listings/{id}/reports` | 없음 | ✗ 없음 | 신고하기에서 오류 |
| 없음 | `PUT /listings/{id}/publication` | 앱에 없음 | 게시하지 않으면 임차인에게 보이지 않음 |
| `POST /listings/{id}/captures` (본문 = capture.zip) | `POST /upload-sessions` → 파일별 PUT → `POST /upload-sessions/{id}/complete` → `POST /listings/{id}/captures {uploadSessionId}` | ✗ | 5장 |
| `POST /furniture/{id}/captures` (zip) | 위와 같은 흐름(FURNITURE_CAPTURE) | ✗ | 5장 |
| `GET /ai-jobs/{jobId}` | 같음 | △ | 상태 이름은 대부분 같음. `progress`→`progressPercent`, `message`→`error.message`, `roomStateId`→`result.resourceId`. `RETRY_WAIT`·`CANCELED` 추가(4.5) |
| `GET /listings/{id}/space` | 같음 | ✗ | 본문 구조가 전부 다름(4.2) |
| `GET /listings/{id}/objects` | 같음 | (호출 안 함) | 앱에 함수만 있고 쓰지 않음(space 의 objects 를 씀). 호출하면 객체 항목 구조가 달라 디코딩 실패 |
| `PATCH /listings/{id}/objects` | 같음 | △ | 권한(소유 중개사)과 값(`UNKNOWN` 포함)은 명세와 같음. 명세의 `spaceVersion` 본문 필드와 `If-Match` 헤더가 아직 없음 |
| `POST /listings/{id}/room-states` `{sourceSpaceVersion, sourceObjectsVersion, removedObjectIds}` | 같음 | △ | 본문 · 규칙(개인 가구이면서 고정 설비가 아닌 것만, 1개 이상, 409 시 다시 불러오기) · 권한(보는 사람 누구나, 본인 전용)이 명세와 같음. `Idempotency-Key` 헤더만 없음 |
| `GET /room-states/{id}` | 같음 | △ | `status`(PROCESSING · READY · FAILED · CANCELED), 만든 사람 전용(404)은 명세와 같음. 결과 파일은 앱이 `sceneUri`·`remainingObjects`, 명세는 `bundle` |
| `GET /listings/{id}/room-states` | 같음 | △ | 내 입주 상태 목록(최신순)을 앱이 사용. `{items}` 는 읽고 커서는 무시 |
| `DELETE /room-states/{id}` | 같음 | △ | 앱에 함수 추가(화면에서는 아직 쓰지 않음). 204 |
| `GET /listings/{id}/placements` | 같음 | ✗ | 저장 전 404(앱은 빈 목록으로 처리). 항목 구조가 달라 저장된 배치도 조용히 빈 목록 |
| `PUT /listings/{id}/placements` | 같음 | ✗ | 4.4 + `If-None-Match: *` / `If-Match`. 응답의 배치 항목도 앱이 읽지 못해 성공해도 오류로 표시 |
| `GET /users/me/furniture` | 같음 | △ | 목록은 읽지만 필드가 달라 전부 "준비 안 됨"(4.3) |
| `GET /furniture/{id}` | 같음 | △ | 위와 같음 |
| `POST /furniture` `{name, category}` | 같음 | ✗ | `category` 대문자 열거 + `Idempotency-Key`. 응답의 `furnitureId` 는 앱이 읽음 |
| `GET /chat`, `POST /chat`, `GET /chat/{id}`, `POST /chat/{id}` | 없음 | ✗ 없음 | 명세서 1장 "제외 범위" |

명세서에만 있는 API 중 앱에 꼭 필요한 것은 가입·로그인·토큰 갱신(`/auth/signup`, `/auth/login`, `/auth/refresh`), 업로드 세션
(`POST /upload-sessions`, `/complete`, `/upload-urls`), 파일 다운로드(`GET /assets/{fileId}/download`), 매물 게시
(`PUT /listings/{id}/publication`), 사진 연결용 `PATCH /listings/{id}` 입니다. 역할 확인에 `GET /users/me` 를 쓰면 편합니다.
매물·가구 삭제와 수정, 입주 상태 목록·삭제, 배치 삭제, `GET /users/me/placements`, `GET /captures/{id}`, 작업 재시도·취소는
앱에 해당 화면이 없어 선택 사항이고, `/internal/ai-jobs/*` 는 AI 워커용이라 앱과 무관합니다.

## 4. 필드 대조

### 4.1 매물 (Listing)

| 앱 | 명세서 |
|---|---|
| `location` (주소 문자열) | `location{regionCode(법정동 10자리), roadAddress, latitude, longitude}` 모두 필수 |
| `price{deposit, monthly}` 만원 + `dealType` | `price{leaseType, deposit, monthlyRent, maintenanceFee, currency:"KRW"}` 원 |
| `maintenanceFee` 만원, null = 관리비 협의 | `price.maintenanceFee` 원, 필수(협의 표현 없음) |
| `roomType`: ONE_ROOM · TWO_ROOM · THREE_ROOM · OFFICETEL | `propertyType`: STUDIO · OFFICETEL · VILLA · APARTMENT |
| `area` | `exclusiveAreaM2` |
| `floor` (선택) | `floor` (필수, 지하 음수) |
| `totalFloors`, `supplyArea`, `rooms`, `bathrooms`, `availableFrom`, `livingEnvironment` | 없음 |
| 없음 | `title`, `description` (필수) |
| `rentalOptions`: parking pet elevator aircon fridge washer bed desk closet induction | `rentalOptions`: AIR_CONDITIONER REFRIGERATOR WASHING_MACHINE INDUCTION GAS_STOVE BED DESK WARDROBE MICROWAVE TV (주차·반려동물·엘리베이터 없음) |
| `thumbnailUri`, `imageUris` (URL) | 목록 `thumbnail`, 상세 `photos` (AssetRef → 다운로드 API) |
| `agent{userId, name, officeName, phone}` | `brokerId` 만 |
| `isScrapped` | 없음 |
| `space3DInfo{status, jobId, latestRoomStateId}` | 목록 `hasSpace`, 상세 `currentSpaceVersion`, `activeJobId` |
| 없음 | `status`(DRAFT · PUBLISHED · ARCHIVED), `version`, `createdAt`, `updatedAt` |

목록용 `ListingSummary` 에는 `listingId, title, price, location, exclusiveAreaM2, thumbnail, hasSpace, status, createdAt` 만 있어서,
앱 카드가 보여주는 방 종류와 층이 빠집니다. 앱의 현재 파서로 읽으면 면적(`exclusiveAreaM2` 를 모름)과 관리비(`price` 안에 있음)도
비어서 "관리비 협의"로 표시됩니다.

### 4.2 3D 공간 (`GET /listings/{id}/space`)

| 앱 (`SpaceResponse`) | 명세서 (`Space` → `bundle`) |
|---|---|
| `3dgsUri` (URL) | `bundle.sceneAsset` (AssetRef, `DULLEOBANG_GS_PLY_V1`) |
| `pointsUri` | 없음 |
| `collisionGeometryUri` | `bundle.collisionAsset` (GLB) |
| `roomDimensions{width, depth, height, area}` | `bundle.roomDimensions{width, height, depth}` (면적은 방별 `rooms[].areaM2`) |
| `roomGeometry.floorHeight` / `ceilingHeight`(층고) | `geometry.rooms[].floorY` / `ceilingY` (둘 다 절대 높이) |
| `roomGeometry.walls[{from[x,z], to[x,z], height}]` | `geometry.rooms[].floorPolygon [[x,z]…]`(위에서 봐서 반시계) + `structuralColliders`(WALL 등) |
| `doors[{position, rotation{yaw}, dimensions}]` | `geometry.doors[{transform, width, height, openingType, hingePosition, sweepNode}]` |
| `windows[]` | 없음 |
| `boundingBox` | 없음(다각형에서 계산) |
| `objects[{objectId, category(bed…), position(상자 중심), rotation{yaw}, dimensions, ownershipType 또는 null}]` | `bundle.objects[{objectId, roomId, category(BED…), transform(바닥 중심 · quaternion), dimensions, boundingBox, ownershipType(UNKNOWN · PERSONAL · RENTAL_OPTION), removable, confidence, collisionNode}]` |
| 없음 | `listingId`, `spaceVersion`, `objectsVersion`, `isCurrent`, `bundle.geometryAsset`, `bundle.quality`, `createdAt` |

### 4.3 가구 (Furniture)

| 앱 | 명세서 |
|---|---|
| `furnitureId`, `name` | 같음 |
| `category`: bed desk sofa closet storage chair other | BED SOFA DESK TABLE CHAIR WARDROBE SHELF REFRIGERATOR WASHING_MACHINE AIR_CONDITIONER TV OTHER |
| `status`: COMPLETED | DRAFT · PROCESSING · READY · FAILED |
| `modelUri`, `collisionMeshUri` | `model.modelAsset`, `model.collisionAsset` (AssetRef) |
| `dimensions`, `boundingBox` | `model.dimensions`, `model.boundingBox` |
| `thumbnailUri` | 없음 |
| 없음 | `ownerId`, `measuredDimensions`, `version`, `model.modelVersion`, `model.quality`, `activeJobId`, `createdAt`, `updatedAt` |

### 4.4 배치 (`PUT /listings/{id}/placements`)

| 앱 | 명세서 (`PlacementPut`) |
|---|---|
| 없음 | `space{kind: ORIGINAL \| ROOM_STATE, spaceVersion, roomStateId}` |
| `placements[].furnitureId` | 같음 |
| 없음 | `placements[].placementId`(앱이 만드는 UUID), `modelVersion` |
| `position{x,y,z}`, `rotation{yaw}` | `transform{position{x,y,z}, rotation{x,y,z,w}}` |
| 가구마다 `isPlaceable`, `collisions[{with, type, overlap}]` | 세트 전체 `clientCollisionReport{rulesVersion:"1.0", evaluatedAt, inputSha256(RFC 8785 JCS), isPlaceable, collisions[{placementId, kind, targetId, penetrationM}]}` 또는 null |

충돌 종류도 다릅니다. 앱은 wall · object · door · window · bounds · furniture, 명세는 WALL · CEILING · DOOR_FRAME · DOOR_SWEEP ·
EXISTING_OBJECT · FURNITURE · OUTSIDE_ROOM · UNSUPPORTED 입니다. 응답 `PlacementSet` 의 `placementSetId`, `savedAt` 은 이름이 같지만,
앱은 응답의 `placements` 항목도 자기 형식(`position`, `rotation.yaw`)으로 읽으려 해서 배치가 1개 이상이면 응답 전체를 읽지 못합니다.

### 4.5 AI 작업 (Job)

| 앱 (`AIJob`) | 명세서 |
|---|---|
| `jobId` | 같음 |
| `status`: QUEUED · RUNNING · COMPLETED · FAILED | 여기에 RETRY_WAIT · CANCELED 추가 |
| `progress` (0–100) | `progressPercent`, `stage`, `attemptNo` |
| `message` | `error{code, message, retryable}` |
| `roomStateId` | `result{resourceType, resourceId, version}` |
| 없음 | `type`, `targetType`, `targetId`, `retryOfJobId`, `pollAfterSeconds`, `createdAt`, `updatedAt`, `finishedAt` |

### 4.6 로그인

| 앱 | 명세서 |
|---|---|
| `GET /auth/{provider}?email=&name=` | `POST /auth/signup {email, password(12–128자), displayName}` → 201 User(토큰 없음), `POST /auth/login {email, password}` → TokenPair |
| 응답 `{userId, name, email, accessToken?}` | `TokenPair{accessToken, refreshToken, tokenType:"Bearer", expiresIn:900, refreshExpiresIn, user{userId, email, displayName, roles[], version, createdAt}}` |
| 토큰 갱신 없음 | `POST /auth/refresh {refreshToken}` + `Idempotency-Key`, 매번 새 refresh token |
| 로그아웃 본문 없음 | `{refreshToken}` → 204 |

## 5. 촬영 데이터 (capture.zip ↔ 업로드 세션 + camera.json)

명세서는 zip 을 받지 않습니다. 파일마다 크기와 SHA-256 을 계산해 `POST /upload-sessions` 로 목록을 등록하고, 서버가 준 서명 URL 에
파일을 하나씩 PUT 한 뒤(`x-amz-checksum-sha256` 헤더, 앱의 Authorization 헤더는 붙이지 않음) `complete` 로 검증하고, 마지막에
`POST /listings/{id}/captures {uploadSessionId}` 를 보냅니다. 방 촬영이 200장이면 PUT 이 201번입니다. 허용 파일은 RGB JPEG/PNG 와
`camera.json` 1개뿐이고, camera.json 의 프레임 목록이 올린 이미지 목록과 정확히 같아야 합니다.

| 앱 `poses.json` | 명세서 `camera.json` (CameraManifest) |
|---|---|
| 없음 | `schemaVersion:"1.0"`, `platform:"ARKIT"`, `coordinateSystem:"RH_Y_UP_Z_BACK"`, `unit:"METER"`, `matrixLayout:"COLUMN_MAJOR"`, `captureStartedAt` |
| `frameId`(0, 1, 2…) + `frames/000000.jpg` | `imageClientFileId` (앱이 만든 UUID, 업로드 파일과 1:1) |
| `ts` (기기 부팅 후 초, 실수) | `timestampUs` (촬영 시작 후 마이크로초, 정수, 단조 증가) |
| `width`, `height` | `widthPx`, `heightPx` (640×480 이상) |
| `K{fx, fy, cx, cy}` (저장 해상도 기준) | `intrinsics{fx, fy, cx, cy}` 같은 의미 |
| `T_wc` 4×4 행 우선 중첩 배열 | `cameraToWorld` 16개 1차원 배열, 열 우선(평행이동은 0부터 센 인덱스 12 · 13 · 14, 즉 13–15번째 값) |
| `tracking:"normal"` (normal 프레임만 저장) | `trackingState:"NORMAL"` (NORMAL 만 허용) |
| `depth/`, `confidence/`, `depth_vis/`, `confidence_vis/`, `depth.json`, `roomplan.json`, `roomplan_structure.json`, `roomplan.usdz`, `meta.json` | 넣을 곳 없음 |

월드 원점도 다릅니다. 명세는 바닥이 y = 0 이고(최초로 안정된 바닥 기준점), ARKit 원점은 촬영을 시작한 순간의 폰 위치라 바닥이
대략 y = −1.3 m 입니다. 지금 앱이 바닥 높이를 아는 경우는 RoomPlan 결과가 있을 때뿐이라(평면 인식은 켜져 있지만 값을 읽지 않음),
LiDAR 없는 기기의 방 촬영과 가구 촬영에서는 바닥 평면을 읽는 코드를 추가해야 합니다. 프레임 수 제한은 방 30–1000장, 가구 12–300장인데
앱은 최소(방 30장, 가구 15장)만 검사하고 최대는 검사하지 않아서, 오래 촬영하면 명세 서버가 거절합니다.

가장 큰 문제는 LiDAR 깊이와 RoomPlan 결과입니다. 명세대로면 AI 는 RGB 와 카메라 포즈만 받습니다. 깊이 지도와 RoomPlan 구조(벽 · 문 ·
가구 상자)는 앱이 이미 만들고 있고 AI 쪽에 가장 쓸모 있는 입력이라, 명세에 선택 파일로 추가하도록 요청하는 것을 권합니다
(예: 촬영용 업로드에 depth PNG 와 roomplan JSON 허용, CameraFrame 에 `depthClientFileId` 추가).

## 6. 이미 맞는 것

핵심 3D 흐름의 경로 이름(listings, space, objects, room-states, placements, furniture, ai-jobs, users/me/…)이 같아서 경로를 새로
설계할 필요는 없습니다. 좌표계(미터, Y-up, 오른손, 카메라 −Z 정면)와 가구 원점(바닥 중심)이 같습니다. 목록 봉투 `{items}`,
오류 문구 `detail`, UUID ID, 객체 분류 값 PERSONAL · RENTAL_OPTION, 작업 상태 이름 대부분은 앱이 이미 읽을 수 있습니다.
명세의 3DGS 파일 형식(`DULLEOBANG_GS_PLY_V1`)은 표준 3DGS PLY 의 부분집합이라 앱 뷰어(gaussian-splats-3d)가 읽을 가능성이 높습니다
(실제 파일로 확인 필요). 촬영은 추적 상태가 normal 인 프레임만 저장하고 K 를 저장 해상도 기준으로 기록하므로 명세의 카메라 조건과
맞습니다.

## 7. 팀이 정할 것

먼저 어느 문서를 기준으로 할지 정해야 합니다. 백엔드 팀원이 이 명세서대로 서버를 만든다면 앱을 명세에 맞추는 것이 맞고(8장),
명세가 MVP 에 비해 무겁다고 보면 명세를 줄여 앱 계약(README §4)에 가깝게 만드는 방법도 있습니다. 어느 쪽이든 아래 항목은 명세
작성자와 먼저 정리하는 것이 좋습니다.

| 항목 | 현재 | 정할 것 |
|---|---|---|
| 채팅 | 앱에 있음, 명세는 제외 | 명세에 추가할지, 앱에서 숨길지 |
| 관심 매물 | 앱에 있음(기기 저장으로 대체 가능), 명세 없음 | 서버 저장이 필요한지 |
| 신고 | 앱에 있음, 명세 없음 | 추가할지, 숨길지 |
| 중개사 인증 신청 | 앱에 신청 화면, 명세는 운영자 등록 | 신청 API 를 추가할지, 앱 화면을 안내 문구로 바꿀지 |
| 추천 매물 | 앱에 있음(전체 목록으로 대체 중) | 명세의 `sort` 로 충분한지 |
| 입주 상태 공유 | **결정됨: 명세 방식** (보는 사람이 각자 만들고 본인만 봄). 앱에 ‘가구 빼 보기’ 추가 · 매물의 `latestRoomStateId` 제거 완료 | — |
| 중개사 이름 · 사무소 · 전화 | 앱 매물 상세 · 채팅에 표시, 명세 Listing 에는 `brokerId` 뿐 | Listing 에 중개사 요약을 넣을지 |
| 방 종류 | 앱은 원룸 · 투룸 · 쓰리룸 · 오피스텔, 명세는 STUDIO · OFFICETEL · VILLA · APARTMENT | 방 개수 기준과 건물 유형 기준 중 무엇을 쓸지 |
| 매물 필드 | 앱의 총층 · 공급면적 · 방/욕실 수 · 입주 가능일 · 생활 환경, 옵션 주차 · 반려동물 · 엘리베이터가 명세에 없음. 명세의 제목 · 설명 · 법정동 코드는 앱에 없음 | 필드 목록 합의 |
| 목록 카드 | 앱 카드가 방 종류 · 층을 보여주는데 `ListingSummary` 에 없음 | `ListingSummary` 에 `propertyType`, `floor` 추가 여부 |
| 사진 URL | 명세는 사진마다 다운로드 API 를 따로 호출해야 함(목록 20개면 20번) | 목록 · 상세 응답에 짧은 수명 URL 을 같이 줄지 |
| 깊이 · RoomPlan | 앱이 촬영하지만 명세에 받을 곳이 없음 | 업로드에 선택 파일로 추가 |
| 창문 | 앱 뷰어가 창문을 그림, 명세 geometry 에 없음 | 추가 여부 |
| 검색 · 지도 | 앱은 지역명 검색, 지도는 전체 목록을 받아 화면 영역으로 거름. 명세는 법정동 코드 정확 일치만 있고 한 번에 최대 50개 | 지역명 검색을 명세에 넣을지, 지도용 전체 목록을 커서 반복으로 받을지 범위 쿼리를 추가할지 |
| 무거운 규칙 | 멱등 키 저장, 모든 수정의 ETag, 배치 `inputSha256`(JCS) | MVP 에서 전부 지킬지 |

## 8. 명세서 기준으로 갈 때 앱 작업

| 작업 | 주로 바뀌는 곳 | 크기 |
|---|---|---|
| 이메일 · 비밀번호 가입/로그인, 토큰 저장(키체인) · 자동 갱신, roles 로 중개사 판단 | `Session`, `LoginView`, `APIClient` | 중 |
| 공통 헤더(`Idempotency-Key`, ETag 보관 · `If-Match`), problem+json `code` 처리, 커서 페이지 | `APIClient` | 중 |
| 모델 교체: Listing · Space · Furniture · Placement · Job · RoomState (원 단위, quaternion, 대문자 열거, AssetRef) | `Models.swift`, `Formatting`, 화면 전반 | 대 |
| 파일 다운로드 계층: fileId → 다운로드 API → sha256 캐시 | `AssetCache`, `RemoteImage` | 중 |
| 촬영 업로드: poses.json → camera.json 변환(열 우선, 마이크로초, 바닥 원점), 파일별 SHA-256, 업로드 세션 · PUT · complete · captures | `Capture`, `Endpoints` | 대 |
| 매물 등록: 제목 · 설명 · 법정동 코드(주소 검색) · 명세 필드, 사진 업로드 세션 + `photoFileIds`, 게시 버튼 | `ListingRegisterView`, `ListingDetailView` | 중 |
| 입주 상태: 중개사 분류 화면과 임차인 제거 화면 분리, 버전 전송, 제거할 객체가 없으면 요청 대신 원본 공간 사용 | `ObjectOwnershipView`, `SpaceViewerView` | **완료** |
| 배치: `placementId` · `modelVersion` · `space` 선택 · quaternion, `If-None-Match`/`If-Match` | `SpaceViewerModel` | 소 |
| 명세 밖 기능(채팅 · 신고 · 중개사 신청)을 7장 결정대로 숨기거나 유지 | `Chat`, `MyPage` | 소 |
| 데모 모드: MockBackend 를 명세 형식으로 바꿔 서버 없이도 계속 동작 | `Core/Mock` | 중 |

명세로 옮길 때 함께 고칠 작은 점도 있습니다. `JobAPI.wait` 는 CANCELED 를 끝난 상태로 보지 않아서, 명세 서버에서 작업이 취소되면
화면이 닫힐 때까지 몇 초마다 계속 조회합니다(지금 계약에는 CANCELED 가 없어 문제 없음). `APIClient.download` 는 로그인 토큰이 있으면
모든 다운로드에 Authorization 헤더를 붙이는데, S3 서명 URL 에 이 헤더가 붙으면 S3 가 요청을 거절하므로 우리 서버 주소일 때만 붙이도록
바꿔야 합니다. 촬영 프레임 수 상한(방 1000장, 가구 300장)도 추가해야 합니다.
