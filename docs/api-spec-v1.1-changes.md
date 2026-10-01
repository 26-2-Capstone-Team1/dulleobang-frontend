# 둘러방 API 명세 v1.1 변경안 (v1.0 대비)

작성 2026-09-30 · 근거: 팀 결정(2026-09-30)과 앱 대조 결과(`docs/api-spec-check.md`)
상태: **제안.** 백엔드 담당과 명세 작성자가 확인한 뒤 명세서(PDF · Markdown · OpenAPI)에 반영합니다.
괄호 안 번호는 팀 질문 목록 번호입니다. 여기 없는 부분은 v1.0 그대로입니다.

## 0. 한눈에 보기

| # | 팀 결정 | 명세 변경 | 장 |
|---|---|---|---|
| 1 | 백엔드는 이 변경을 반영한 명세를 따른다 | 이 문서 전체 | — |
| 2 | 채팅 추가 | 채팅 API 신규 | 8 |
| 3 | 관심 매물 서버 저장 | 찜 API 신규, 응답에 `isScrapped` | 6 |
| 4 | 신고 추가 | 신고 API 신규 | 7 |
| 5 | 중개사 인증 추가, 인증 중개사 표시, 일반인도 본인 집 등록 | 매물 등록을 모든 사용자에게 개방, 중개사 인증 신청 API 신규, 응답에 `owner.isVerifiedBroker` | 2 |
| 6 | 추천 매물 없음, 필터만 | 추천 API 만들지 않음 (홈 = 최신순 목록) | 4 |
| 7 | 카카오 + 구글 + 이메일 비밀번호 | 소셜 로그인 API 신규 | 1 |
| 8 | 방 종류는 앱 방식 | `propertyType` → `roomType` (ONE_ROOM · TWO_ROOM · THREE_ROOM · OFFICETEL) | 3 |
| 9 | 앱에만 있는 매물 필드 추가 | 총층 · 공급면적 · 방/욕실 수 · 입주 가능일 · 생활 환경 · 옵션 3종 추가 | 3 |
| 10 | 제목 · 설명 · 법정동 코드 필수 아님 | 세 필드를 선택으로 | 3 |
| 11 | 매물에 중개사 이름 · 사무소 · 전화 | `owner` 요약 객체 추가 | 2, 3 |
| 12 | 목록 요약에 방 종류 · 층 | `ListingSummary` 에 `roomType`, `floor` | 3 |
| 13 | 지역명 검색 + 지도 범위 검색 | `q`, `minLat…maxLng` 쿼리 추가 | 4 |
| 14 | 응답에 짧은 수명 주소 | `AssetRef` 에 `url`, `urlExpiresAt` | 5 |
| 15 | 깊이 · RoomPlan 을 AI 가 사용 | 촬영 업로드에 깊이 · 신뢰도 · RoomPlan 파일 추가 | 9 |
| 16 | AI 결과물 형식 | **보류** (AI 담당 확인 대기) | 12 |
| 17 | 창문 추가 | `RoomGeometry.windows` | 10 |
| 18 | 멱등 키 · ETag 유지. 충돌 판정은 GPU 서버에서 | 멱등 키 · ETag 유지. `inputSha256` · `clientCollisionReport` 삭제 → 서버 충돌 검사 작업 · 매물 비교 작업 신규 | 11 |
| — | 입주 상태는 명세 방식 | 변경 없음 (앱이 명세에 맞춤, 완료) | — |

## 1. 로그인 (7)

이메일 가입 · 로그인(`POST /auth/signup`, `POST /auth/login`)과 토큰 갱신 · 로그아웃은 v1.0 그대로 두고, 소셜 로그인을 추가합니다.

| 메서드 · 경로 | 요청 | 응답 | 설명 |
|---|---|---|---|
| `POST /auth/oauth/kakao` | `{accessToken}` (카카오 SDK 가 준 토큰) | `200 TokenPair` | 서버가 카카오 사용자 정보 API 로 토큰을 검증하고 카카오 회원번호로 사용자를 찾거나 만든다 |
| `POST /auth/oauth/google` | `{idToken}` (구글 로그인 SDK 가 준 ID 토큰) | `200 TokenPair` | 서버가 구글 공개키로 ID 토큰(서명 · aud · exp)을 검증하고 `sub` 로 사용자를 찾거나 만든다 |

- 처음 들어온 소셜 사용자는 TENANT 로 만든다. 이메일이 있으면 저장하되, 같은 이메일의 기존 계정과 자동으로 합치지는 않는다 (다른 사람 계정 탈취 방지).
- `User` 에 `authProviders: ["EMAIL" | "KAKAO" | "GOOGLE"]` 와 `phone` (선택, 010-0000-0000 형식) 을 추가한다. 전화번호는 중개사 연락처 표시에 쓴다 (2장).
- 오류: 토큰 검증 실패 401 `INVALID_OAUTH_TOKEN`, 제공자 장애 503.
- 앱: 카카오 · 구글 네이티브 앱 키가 필요합니다 (카카오 개발자 콘솔 · Google Cloud 콘솔에서 발급).

## 2. 누구나 매물 등록 · 중개사 인증 (5, 11)

**권한 변경.** 매물 생성 권한을 `BROKER` 에서 **로그인한 모든 사용자** 로 바꿉니다. 매물의 `brokerId` 는 `ownerId`(등록한 사용자)로 이름을 바꾸고,
v1.0 표의 "소유 BROKER" 는 모두 "매물 소유자" 로 읽습니다 (매물 수정 · 게시 · 삭제 · 촬영 제출 · 객체 분류).

**인증 중개사 표시.** 매물 응답에 등록한 사람의 요약을 넣습니다. 인증 여부는 서버가 역할로 계산합니다.

```jsonc
"owner": {
  "userId": "…", "displayName": "차유현",
  "isVerifiedBroker": true,            // roles 에 BROKER 가 있으면 true
  "officeName": "상도 공인중개사",      // 인증 중개사만
  "phone": "010-1234-5678"             // 인증 중개사는 사무소 번호, 일반 소유자는 공개 동의한 경우만 (아니면 null)
}
```

**중개사 인증 신청 (신규).** 승인은 운영자가 관리 도구나 DB 에서 하고, 승인되면 그 사용자의 `roles` 에 BROKER 를 더합니다.

| 메서드 · 경로 | 요청 | 응답 |
|---|---|---|
| `GET /users/me/broker-verification` | | `200 {status: NONE \| PENDING \| APPROVED \| REJECTED, name, licenseNumber, officeName, phone, documentFileId, requestedAt, reviewedAt, rejectReason}` |
| `POST /users/me/broker-verification` | `{name, licenseNumber, officeName, phone, documentFileId}` | `201` 위와 같은 형태 (`status: PENDING`) |

- 서류(사업자 등록증 · 중개사 등록증 사진)는 업로드 세션에 새 목적 `BROKER_DOCUMENT` (JPEG/PNG 1장, targetType `USER`) 로 올린 뒤 `documentFileId` 를 보낸다.
- 반려되면 다시 신청할 수 있다. 심사 중에 다시 보내면 409 `VERIFICATION_PENDING`.

## 3. 매물 필드 (8, 9, 10, 11, 12)

**금액 단위는 v1.0 대로 원(KRW)을 유지합니다.** 앱이 만원으로 바꿔 보여 줍니다.

`ListingCreate` / `ListingPatch` / `Listing` 변경:

| 필드 | v1.0 | v1.1 |
|---|---|---|
| `title`, `description` | 필수 | **선택** (없으면 앱이 "상도동 원룸" 처럼 만들어 보여 줌) (10) |
| `propertyType` | STUDIO · OFFICETEL · VILLA · APARTMENT | **삭제 → `roomType`**: ONE_ROOM · TWO_ROOM · THREE_ROOM · OFFICETEL (8) |
| `location.regionCode` | 필수 | **선택** (10). `roadAddress` · 위도 · 경도는 필수 유지 |
| `location.detailAddress` | 없음 | **추가, 선택**: "302호" 같은 상세 주소. 매물 소유자에게만 돌려주고 다른 사람에게는 빼고 준다 |
| `price.maintenanceFee` | 필수 정수 | **null 허용** = 관리비 협의 |
| `floor` | 필수 | 선택 (null = 모름) |
| `totalFloors` | 없음 | **추가**, 정수, 선택 (9) |
| `supplyAreaM2` | 없음 | **추가**, 숫자, 선택 (9) |
| `roomCount`, `bathroomCount` | 없음 | **추가**, 정수, 선택 (9) |
| `availableFrom` | 없음 | **추가**: `"IMMEDIATE"` 또는 `YYYY-MM-DD` (9) |
| `livingEnvironment` | 없음 | **추가**, 문자열 0~500자, 선택: 교통 · 편의시설 설명 (9) |
| `rentalOptions` 값 | 10종 | **3종 추가**: `PARKING`, `PET_ALLOWED`, `ELEVATOR` (9) |
| `brokerId` | 있음 | **`ownerId` 로 이름 변경** + `owner` 요약 (2장) (11) |
| `isScrapped` | 없음 | **추가** (응답 전용, 로그인한 사용자 기준) (3) |
| `photos[]` | AssetRef | AssetRef + `url` · `urlExpiresAt` (5장) (14) |

`ListingSummary` 에 추가: `roomType`, `floor` (12), `owner` (`userId`, `displayName`, `isVerifiedBroker` 만), `isScrapped`, 그리고 `thumbnail` 에 `url` · `urlExpiresAt`.
관리비는 이미 `price.maintenanceFee` 에 있으므로 목록 카드("월세 500/31 · 원룸 · 3층, 관리비 5만")를 요약만으로 그릴 수 있습니다.

앱 옵션 값과의 대응: `aircon`→`AIR_CONDITIONER`, `fridge`→`REFRIGERATOR`, `washer`→`WASHING_MACHINE`, `bed`→`BED`, `desk`→`DESK`,
`closet`→`WARDROBE`, `induction`→`INDUCTION`, `parking`→`PARKING`, `pet`→`PET_ALLOWED`, `elevator`→`ELEVATOR`.

## 4. 검색 (6, 13)

추천 API 는 만들지 않습니다. 홈 화면은 `GET /listings?sort=LATEST` 로 최신 매물을 보여 주고, 사용자가 필터를 겁니다.
`GET /listings` 쿼리 변경:

| 쿼리 | 변경 | 설명 |
|---|---|---|
| `q` | **추가** | 지역명 · 주소 텍스트 검색 (예: `상도동`, `흑석동 원룸` 에서 방 종류 단어는 앱이 `roomType` 으로 옮겨 보냄). 도로명 · 지번 주소 · 동 이름에 대한 부분 일치, 공백으로 나눈 단어는 AND |
| `minLat`, `maxLat`, `minLng`, `maxLng` | **추가** | 지도에 보이는 범위. 네 개를 함께 보내야 하고, 하나라도 빠지면 400 |
| `roomType` | `propertyType` 대체 | 반복 가능 (`roomType=ONE_ROOM&roomType=OFFICETEL`) |
| `limit` | 최대 50 | 지도 범위가 있으면 **최대 200** (지도 핀용) |
| `regionCode` | 유지 | 선택 |

## 5. 파일 주소를 응답에 같이 주기 (14)

`AssetRef` 에 두 필드를 추가합니다. 목록 · 상세 · 공간 · 입주 상태 · 가구 응답이 파일을 담을 때 채웁니다.

```jsonc
{ "fileId": "…", "contentType": "image/jpeg", "byteSize": 482113, "sha256": "…", "format": "JPEG",
  "url": "https://cdn…/…?X-Amz-…",       // 추가: 바로 받을 수 있는 주소
  "urlExpiresAt": "2026-09-30T12:15:00.000Z" }  // 추가: 주소 만료 시각 (공개 주소면 null)
```

- 앱은 `url` 을 바로 쓰고, 만료됐거나 403 이면 `GET /assets/{fileId}/download` 로 다시 받습니다. 다운로드 API 는 그대로 둡니다.
- 공개된 매물 사진 · 썸네일은 만료 없는 CDN 주소를 줘도 됩니다. 원본 촬영 파일과 개인 가구 파일은 v1.0 처럼 소유자에게만.
- 서명 URL 에는 앱이 Authorization 헤더를 붙이지 않습니다 (S3 가 거절함).

## 6. 관심 매물 (3)

| 메서드 · 경로 | 응답 | 설명 |
|---|---|---|
| `PUT /listings/{listingId}/scrap` | `204` | 담기. 이미 담겨 있어도 204 (멱등) |
| `DELETE /listings/{listingId}/scrap` | `204` | 빼기. 없어도 204 |
| `GET /users/me/scraps` | `200 ListingPage` | 최근 담은 순. 공개 중인 매물만 |

## 7. 신고 (4)

| 메서드 · 경로 | 요청 | 응답 |
|---|---|---|
| `POST /listings/{listingId}/reports` | `{reason: FAKE_LISTING \| SPACE_MISMATCH \| WRONG_PRICE \| ALREADY_CONTRACTED \| OTHER, detail?: 0~1000자}` | `201 {reportId}` |

- 같은 사용자가 같은 매물을 24시간 안에 다시 신고하면 `200` 으로 기존 `reportId` 를 돌려준다.
- 앱 문구와의 대응: 허위 매물이에요 → FAKE_LISTING, 실제 공간과 사진 · 3D 가 달라요 → SPACE_MISMATCH, 가격 정보가 달라요 → WRONG_PRICE, 이미 거래된 매물이에요 → ALREADY_CONTRACTED, 기타 → OTHER.

## 8. 채팅 (2)

매물 문의용 1:1 채팅입니다. 상대방은 매물 소유자(중개사 또는 집주인)입니다. MVP 는 폴링(화면이 열려 있을 때 3~5초마다)으로 하고, 필요해지면 WebSocket 이나 SSE 를 붙입니다.

| 메서드 · 경로 | 요청 | 응답 |
|---|---|---|
| `POST /chats` | `{listingId}` | `201 Chat` (처음) / `200 Chat` (이미 있으면 기존 방) |
| `GET /chats` | `?cursor&limit` | `200 {items: [ChatSummary], page}` 최근 메시지 순 |
| `GET /chats/{chatId}` | | `200 Chat` |
| `GET /chats/{chatId}/messages` | `?before=<messageId>&limit` | `200 {items: [Message], page}` 최신 것부터 |
| `POST /chats/{chatId}/messages` | `{text: 1~1000자}` + `Idempotency-Key` | `201 Message` |
| `POST /chats/{chatId}/read` | `{lastReadMessageId}` | `204` |

```jsonc
// ChatSummary
{ "chatId": "…", "listing": ListingSummary, "counterpart": { "userId": "…", "displayName": "차유현", "isVerifiedBroker": true, "officeName": "상도 공인중개사" },
  "lastMessage": "토요일 오후 2시 괜찮으세요?", "lastMessageAt": "2026-09-30T03:00:00.000Z", "unreadCount": 1 }
// Message
{ "messageId": "…", "chatId": "…", "senderId": "…", "text": "…", "sentAt": "2026-09-30T03:00:00.000Z" }
```

- 채팅방은 (매물, 문의한 사용자) 당 하나. 매물 소유자는 자기 매물로 채팅방을 만들 수 없다 (409).
- 매물이 삭제 · 보관되면 기존 대화는 읽기만 가능.

## 9. 촬영 업로드: 깊이 · RoomPlan (15)

AI 가 LiDAR 깊이와 RoomPlan 구조를 쓰므로, 실내 촬영(`ROOM_CAPTURE`) 업로드 세션이 아래 파일도 받게 합니다. 모두 선택이며, LiDAR 없는 기기는 v1.0 처럼 RGB + camera.json 만 보냅니다.

`UploadFileInput` 에 `role` 을 추가합니다.

| role | 형식 | 개수 | 설명 |
|---|---|---|---|
| `IMAGE` | JPEG/PNG RGB | 30~1000 | v1.0 그대로 |
| `CAMERA_MANIFEST` | camera.json | 1 | v1.0 그대로 |
| `DEPTH` | PNG uint16, 밀리미터, 0 = 측정 없음 (보통 256×192) | 0 또는 이미지 수만큼 | 추가 |
| `CONFIDENCE` | PNG uint8, 0 낮음 · 1 중간 · 2 높음 | 0 또는 이미지 수만큼 | 추가 |
| `ROOMPLAN` | JSON (Apple CapturedRoom 원본) | 0~1 | 추가 |
| `ROOMPLAN_STRUCTURE` | JSON (앱이 뽑은 벽 · 문 · 창 · 가구 상자, 미터) | 0~1 | 추가 |

`CameraFrame` 에 선택 필드를 추가합니다: `depthClientFileId`, `confidenceClientFileId`, `depthWidthPx`, `depthHeightPx`.
깊이 intrinsics 는 `intrinsics × (depthWidthPx / widthPx)` 로 계산합니다. 워커 입력(`ReconstructionInput`)에는 `depths`, `confidences` (DownloadGrant 배열)와 `roomplan`, `roomplanStructure` (DownloadGrant 또는 null)를 추가합니다.
검증: 깊이 · 신뢰도 파일은 camera.json 의 프레임이 참조해야 하고, 참조되지 않은 파일이 있으면 422.

## 10. 창문 (17)

`RoomGeometry` 에 `windows` 를 추가합니다 (0~200개). 충돌 판정에는 쓰지 않고 표시와 "창문 가림" 안내에만 씁니다.

```jsonc
"windows": [ { "windowId": "…", "roomId": "…", "transform": Transform, "width": 1.4, "height": 1.1, "sillHeight": 0.9 } ]
// transform.position = 창 중심, sillHeight = 바닥에서 창틀 아래까지 (m)
```

## 11. 공통 규칙 · 충돌 판정 (18)

- **Idempotency-Key: 유지.** 앱이 생성 · 제출 요청마다 UUID 를 붙입니다.
- **ETag / If-Match: 유지.** 앱이 직전 GET 의 ETag 를 보관했다가 수정 · 삭제 때 보냅니다.
- **충돌 판정은 서버(GPU 워커)가 공식 결과를 냅니다.** v1.0 의 "모바일 판정 + `clientCollisionReport` · `inputSha256`" 을 삭제하고 아래로 바꿉니다.

**역할 분담.** 폰은 가구를 끄는 동안 초록 · 빨강을 바로 보여 주는 미리보기 판정만 합니다 (벽 · 가구 상자 기준, 1초에 수십 번이라 서버를 오갈 수 없음).
저장한 배치의 정밀 판정(방 충돌 메시 × 가구 충돌 메시)과 여러 매물 비교는 서버가 AI 작업과 같은 큐 · 워커로 처리합니다.
가구 몇 개 수준의 메시 충돌은 CPU 로도 수 ms 라 GPU 가 꼭 필요하지는 않지만, 이미 있는 GPU 워커를 그대로 씁니다.

**서버 충돌 검사.** `PUT /listings/{id}/placements` 가 성공하면 서버가 `COLLISION_CHECK` 작업을 큐에 넣습니다 (`Job.type` 에 추가, `targetType: PLACEMENT_SET`).
`PlacementPut` 에서 `clientCollisionReport` 를 빼고, `PlacementSet` 에 검사 결과를 붙입니다.

```jsonc
"validationAuthority": "SERVER",                  // v1.0 의 CLIENT_ONLY 대체
"collisionCheck": {
  "status": "PENDING",                            // PENDING | RUNNING | DONE | FAILED
  "jobId": "…", "checkedVersion": 3,              // 이 배치 세트 version 에 대한 결과 (다시 저장하면 새 검사)
  "rulesVersion": "1.1",
  "isPlaceable": false,                           // DONE 일 때만
  "collisions": [ { "placementId": "…", "kind": "EXISTING_OBJECT", "targetId": "…", "penetrationM": 0.04 } ],
  "warnings": ["DOOR_SWEEP_UNKNOWN", "WINDOW_BLOCKED"],
  "checkedAt": "2026-09-30T03:00:05.000Z"
}
```

- 충돌 종류는 v1.0 그대로(WALL · CEILING · DOOR_FRAME · DOOR_SWEEP · EXISTING_OBJECT · FURNITURE · OUTSIDE_ROOM · UNSUPPORTED), 창문은 막는지만 `WINDOW_BLOCKED` 경고로 알립니다.
- 앱은 저장 후 `GET /ai-jobs/{jobId}` 로 기다렸다가 배치를 다시 받아 서버 결과를 보여 줍니다. 서버 결과와 폰 미리보기가 다르면 서버 결과를 따릅니다.
- 워커 입력: 공간 충돌 GLB, 배치된 가구들의 충돌 GLB(각 `modelVersion`), 배치 transform. 워커는 결과 JSON 만 올립니다.

**매물 비교 (신규).** 같은 가구 구성을 여러 매물에 자동으로 놓아 보고 비교합니다.

| 메서드 · 경로 | 요청 | 응답 |
|---|---|---|
| `POST /users/me/placement-comparisons` | `{listingIds: [1~10개], furnitureIds: [1~20개], useMyRoomStates: true}` + `Idempotency-Key` | `202 {comparisonId, jobId}` (`Job.type: PLACEMENT_COMPARISON`) |
| `GET /placement-comparisons/{comparisonId}` | | `200 {status, results: [{listingId, roomStateId, fits, freeAreaM2, blockedFurnitureIds, placements: [PlacementItem]}]}` 들어가는 매물 · 빈 면적 순 |

`useMyRoomStates` 가 true 면 매물마다 내 최신 입주 상태(가구를 뺀 공간)를 기준으로 합니다. 결과의 `placements` 는 그대로 `PUT placements` 에 쓸 수 있습니다.

## 12. 보류: AI 결과물 형식 (16)

AI 담당의 확인을 기다립니다: 3DGS 결과 `DULLEOBANG_GS_PLY_V1`(SH degree 0), 충돌용 GLB(노드 이름 규칙), `ROOM_GEOMETRY_V1` JSON(이번에 `windows` 추가), 가구 제거 결과.
형식이 바뀌면 워커 API(41~45)와 `SpaceBundle` 을 같이 고칩니다.

## 13. 앱이 맞출 일 (참고)

v1.1 이 확정되면 앱은 다음을 바꿉니다: 원 ↔ 만원 변환, `location` 객체, `AssetRef.url` 읽기와 만료 시 재발급, 회전 yaw ↔ quaternion,
업로드 세션(파일별 SHA-256 · PUT · complete)과 camera.json 변환(열 우선 행렬 · 마이크로초 · 바닥 원점), 토큰 갱신, 게시(`PUT /listings/{id}/publication`) 버튼,
채팅 · 찜 · 신고 경로 변경, 배치 저장 후 서버 충돌 결과 표시 · 매물 비교를 서버 작업으로 전환. 누구나 등록 · 인증 뱃지 · 추천 제거 · 지도 범위 검색 · 멱등 키 · ETag · 세 가지 로그인은 데모 모드 기준으로 먼저 반영합니다.
