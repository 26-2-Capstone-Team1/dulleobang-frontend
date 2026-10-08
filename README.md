# 둘러방 iOS 앱 (SwiftUI + ARKit + RoomPlan + three.js 뷰어)

제안서 3.2 Mobile Application 파트의 구현 코드입니다. iOS 17 이상, 실기기(ARKit) 전용입니다.

화면은 **StayView 데모(발표 자료 8–11쪽)와 와이어프레임(17쪽)** 을 그대로 따르고, 둘러방 기능(3D 공간 촬영·입주 예상 공간·내 가구 배치·매물 비교)을 그 안에 넣었습니다.

| 폴더 | 내용 | 제안서 / 주차 |
|---|---|---|
| `App/` | 진입점, 로그인/탭 전환(`Navigation`), 디자인 토큰·공용 컴포넌트(`Theme`), 표기(`Formatting`), 로그인·중개사·관심 매물(`Session`), 설정값 | 3주차 |
| `Core/Models` | API Codable 모델 (시퀀스 다이어그램 v2 + StayView 필드명 호환), 숫자/문자열 ID 겸용 `FlexibleID` | 3주차 |
| `Core/Network` | REST 클라이언트(봉투 응답 해제, 목록 형태 자동 인식, multipart, zip 스트리밍 업로드, 진행률), 엔드포인트 | 3–5주차 |
| `Core/Geometry` | `Room`(공간 정리), `CollisionChecker`(2D OBB SAT 충돌 판정 + 자동 배치) | 11–12주차 |
| `Core/Mock` | **데모 모드**: 서버 대신 응답하는 앱 내장 백엔드(`MockBackend`), 저장 형식·시드(`MockStore`) | 데모 |
| `Features/Auth` | 로그인(카카오/Google 로 시작하기), 가입 약관 동의 | 3주차 |
| `Features/Home` | 홈(최근 본 매물·새로 올라온 매물 + 필터), 검색 결과, 필터 | 3주차 |
| `Features/Browse` | 둘러보기 지도(가격 말풍선·묶음), 하단 매물 시트 | 3주차 |
| `Features/Listings` | 매물 상세(사진·가격·상세·옵션·3D 공간·채팅하기·신고), 매물 등록(공간 촬영/이미지 선택) | 3, 6주차 |
| `Features/Chat` | 채팅 목록·채팅방 | 3주차 |
| `Features/MyPage` | 마이페이지, 중개인 인증·인증 정보, 관심 매물, 내가 올린 매물, 알림, 설정(서버 주소·**오프라인 촬영**) | 3주차 |
| `Features/Capture` | ARKit 프레임·포즈·깊이 기록, 프레임 선별·촬영 가이드, RoomPlan(LiDAR), zip, 업로드 흐름 | 4–5주차 |
| `Features/Viewer` | WKWebView 3D 뷰어(1인칭/평면뷰), 스킴 핸들러, 에셋 캐시, 가구 구분(중개사) · 가구 빼 보기(모두), 가구 배치·저장 | 7–12주차 |
| `Features/Furniture` | 내 가구 목록, 가구 등록(→촬영) | 10주차 |
| `Features/Compare` | 같은 가구 구성을 여러 매물(관심 매물 우선)에 자동 배치해 비교 | 13주차 |
| `Resources/Viewer` | `index.html`, `viewer.js` (three.js + gaussian-splats-3d), `vendor/`(선택: 오프라인용 로컬 사본) | 7주차 |
| `Resources/Mock` | 데모 데이터: `mock_seed.json`(매물 12 · 3D 공간 8 · 입주 상태 5 · 가구 4 · 채팅 3), 매물·욕실·가구 사진 | 데모 |
| `DulleobangTests` | 충돌 판정·자동 배치·비교, 프레임 선별, 응답 디코딩(숫자 ID·봉투·Spring Page), 표기 테스트 | V-Model 단위 테스트 |

### 화면 구성 (StayView 데모 → 코드)

| 데모 화면 | 코드 | 둘러방에서 더한 것 |
|---|---|---|
| 로그인 · 회원가입(약관 3개) | `LoginView`, `DemoSignupSheet` | 카카오/구글 SDK 대신 이름·이메일 데모 가입. 디버그 빌드는 "로그인 없이 시작" |
| 홈: 최근 본 매물 · 새로 올라온 매물 (3열) | `HomeView` | 추천 없이 최신순 + 필터(거래 유형 · 방 종류 · 보증금 · 월세), 3D 준비된 매물에 `3D` 배지, 인증 중개사 매물에 ✓ 배지, 로그인하면 누구나 상단 "매물 등록" |
| 둘러보기: 지도 가격 말풍선 + "매물 · 총 N건" 시트 | `BrowseMapView` | 가까운 매물 묶음(숫자), 좌표 없으면 주소 지오코딩 |
| 채팅 목록 · 채팅방 | `ChatListView`, `ChatRoomView` | 3초 폴링(웹소켓 붙이기 전) |
| 마이페이지(일반/중개사 메뉴) | `MyPageView` | 내 가구 · 가구로 매물 비교 행 |
| 매물 상세: 사진 1/8 · 가격 정보 · 상세 정보 · ♡ + 채팅하기 | `ListingDetailView` | 옵션 태그, 생활 환경, **3D 공간 카드**(실측 치수 · 3D 둘러보기 · 입주 예상 공간 · 내 가구 놓아보기), 신고 |
| 3D 보기: 검정 헤더 · 초기화 · 평면뷰 | `SpaceViewerView` + `viewer.js` | 치수 표시, 가구 빼 보기(나만 보는 입주 상태) · 입주 예상/현재 전환, 가구 추가·충돌 색·저장, (중개사) 가구 구분 |
| 중개인 인증 → 중개사 인증 정보 | `AgentVerifyView`, `AgentInfoView` | 심사 중 / 반려 상태 카드 |
| 매물 등록하기: 등록 명의 · 주소 · 가격 · 면적(m²/평) · 입주 가능일 · 공간 자료(공간 촬영 \| 이미지 선택) · 상세 사진 선택 · 옵션 | `ListingRegisterView` | **공간 촬영 = 앱 내 ARKit/LiDAR 촬영** → 매물 생성 후 zip 업로드 → AI 3D 생성. 실패해도 "이어서 등록하기" |

로고 글자는 `AppConfig.brandName`("둘러방") 한 곳에서 바꿀 수 있습니다(StayView 로 쓰려면 여기만 수정). 보라 `#6C4DF6` 등 색은 `Theme.swift` 의 `DB`.

---

## 1. 빌드 & 실행

1. **Xcode 27** 설치 (iOS 27 기기를 쓰려면 필수. macOS Tahoe 26.6 이상, Apple silicon Mac 필요), Xcode › Settings › Accounts 에 Apple ID 추가 (무료 계정으로 본인 폰 실행 가능)
2. `brew install xcodegen` → 이 폴더에서 `xcodegen generate` → `open Dulleobang.xcodeproj`
3. 타깃 Dulleobang › Signing & Capabilities › Team 선택 (번들 ID 가 겹치면 `project.yml` 의 `PRODUCT_BUNDLE_IDENTIFIER` 변경)
4. iPhone 을 케이블로 연결하고 잠금 해제 상태로 둔 채 "이 컴퓨터를 신뢰" → Xcode 의 **Preparing for development…** 가 끝날 때까지 대기 (처음 한 번, 10~30분)
   → iPhone 설정 › 개인정보 보호 및 보안 › **개발자 모드** 켜기(재시동) → Run. 개발자 모드 메뉴는 Xcode 에 한 번 연결한 뒤에야 나타납니다.
5. 처음 실행 시 "신뢰하지 않는 개발자" 가 뜨면 설정 › 일반 › VPN 및 기기 관리 에서 신뢰

XcodeGen 을 안 쓰면: 새 iOS App 프로젝트(SwiftUI) 를 만들고 `Dulleobang/` 의 Swift 파일을 추가하되,
**`Resources/Viewer` · `Resources/Mock` 폴더는 "Create folder references"(파란 폴더)로 추가**해야 합니다. Info.plist 키는 `project.yml` 의 `info.properties` 참고
(카메라·로컬 네트워크 사용 설명, ATS 로컬 허용, `UIFileSharingEnabled`).

> Swift 5 언어 모드로 설정되어 있습니다 (Swift 6 엄격 동시성 검사는 경고만 나옴).
> 이 코드는 컴파일러 없는 환경에서 작성했습니다. 처음 빌드 때 작은 오류가 나오면 오류 메시지와 파일을 공유해 주세요.

## 1-1. 데모 모드 (서버 없이 둘러보기)

**기본으로 켜져 있습니다.** 앱이 서버 대신 `Core/Mock/MockBackend` 에 요청을 보내고, 백엔드와 같은 경로·JSON 을 돌려줍니다.
화면·디코딩 코드는 실제 서버와 똑같이 동작하므로, 백엔드가 준비되면 **설정 › 데모 모드 › 데모 데이터 사용** 을 끄기만 하면 됩니다.
홈 로고 옆의 보라색 **데모** 표시를 누르면 바로 설정으로 갑니다.

| 들어 있는 것 | 내용 |
|---|---|
| 매물 12개 | 중앙대 주변 흑석동·상도동·노량진·본동. 월세/전세, 원룸·투룸·오피스텔, 사진 3장 + 욕실 1장, 지도 좌표, 옵션·생활 환경, 담당 중개사 3명(전화번호는 010-0000-xxxx 더미) |
| 3D 공간 8개 | 101·102·104·106·108·110·112 완료, **105 는 "3D 생성 중"** (상세 화면을 열면 약 45초 동안 진행률이 오르다 완료) |
| 입주 예상 | 101·102·106·108·112 에 **로그인한 사용자가 전에 만들어 둔** 입주 상태가 있음(개인 가구를 뺀 상태). 다른 매물(104·110 등)은 ‘가구 빼 보기’로 직접 만들어 봅니다. 104 는 의자 하나가 미분류라 중개사가 구분해 보는 용도 |
| 내 가구 4개 | 침대·책상·옷장·소파 (치수 포함, 3D 는 치수대로 그린 모형) → 가구 놓아보기 · 매물 비교가 바로 됩니다 |
| 채팅 3개 | 메시지를 보내면 2~3초 뒤 중개사가 자동 답장 (관리비·주차·방문·입주일 등 낱말에 맞춰) |
| 관심 매물 | 106·101 이 처음부터 담겨 있음 |

- **누구나 매물 등록**: 로그인하면 홈 › 매물 등록 또는 마이페이지 › 내 집 매물 올리기로 본인 집을 올릴 수 있고, 매물에는 "집주인 직접 등록" 으로 표시됩니다.
- **중개사 흐름(선택)**: 마이페이지 › 중개사 인증 신청 → 3초 뒤 자동 승인 → 올린 매물에 **인증 중개사** 배지가 붙고, 매물 **104·109 가 "내가 올린 매물"** 이 됩니다.
  104 상세 › 3D 공간 둘러보기 › **가구 구분** 에서 미분류 의자를 개인 가구로 정하고 저장하면, 매물을 보는 사람이 ‘가구 빼 보기’에서 뺄 수 있게 됩니다.
- **가구 빼 보기(임차인)**: 3D 공간 › **가구 빼 보기** 에서 개인 가구 중 뺄 것을 고르면 6초 뒤 그 가구가 빠진 입주 예상 공간이 열립니다. 만든 입주 상태는 나만 봅니다.
- **등록·촬영**: 매물 등록 · 공간 촬영 · 가구 촬영도 됩니다. 사진은 기기에 저장되고, AI 작업은 몇 초(공간 20초 · 가구 12초) 뒤 완료 처리됩니다.
  LiDAR 기기의 RoomPlan 구조(`roomplan_structure.json`)가 있으면 그 벽·문·창·가구로, 없으면 전용면적으로 직사각형 방을 만듭니다.
- **3D 뷰어**: 스캔 파일(PLY)이 없는 공간은 `viewer.js` 의 `buildBlockout` 이 벽·문·창·바닥과 가구 모형을 그립니다(1인칭/평면뷰, 치수, 입주 예상, 가구 배치·충돌 모두 동작). three.js 는 CDN 에서 받으므로 인터넷이 필요합니다(`vendor/` 에 사본을 넣으면 오프라인).
- 데모에서 바꾼 내용은 `Application Support/DemoData` 에 저장됩니다. **설정 › 데모 데이터 초기화** 로 처음 상태로 되돌립니다.
- 시드는 JSON 한 파일입니다. 매물·가격을 바꾸려면 `Resources/Mock/mock_seed.json` 을 고치고 `seedVersion` 을 올리세요(앱이 새 시드를 자동으로 다시 읽음).
  사진은 같은 폴더의 파일을 `bundle://Mock/L01_1.jpg` 처럼 가리킵니다. 사진·시드를 다시 만드는 스크립트: `tools/mockgen/` (Python + Pillow + NumPy,
  `python3 tools/mockgen/make_images.py && python3 tools/mockgen/make_seed.py`). 3D 공간은 사진을 그린 방 크기·가구 배치를 그대로 옮긴 것입니다.

## 2. 이번 주 할 일: 오프라인 촬영 → AI 팀원에게 capture.zip 전달

백엔드 없이도 됩니다. 로그인 화면 오른쪽 위 ⚙︎(또는 로그인 후 마이페이지 ⚙︎) = **설정**.
서버가 없으면 디버그 빌드의 **"로그인 없이 시작 (개발용)"** 으로 들어가면 됩니다.
**설정 › 오프라인 방 촬영** → 빨간 버튼으로 시작 → 방 입구에서 벽을 따라 **걸으면서** 천천히 한 바퀴(이동 범위 2 m 이상, 원 게이지가 다 참),
**폰을 아래로 30~45° 기울여 바닥이 화면 절반쯤 보이게 걸어온 길을 한 바퀴 더**(아래 막대의 "바닥 n%" 가 85% 이상), 필요하면 높이를 바꿔 한 바퀴 더(150장 정도) → 정지 → LiDAR 기기면 RoomPlan 후처리(수 초) → `capture.zip` 생성 → **공유 / AirDrop** 으로 노트북에 전송.
zip 은 파일 앱 › 나의 iPhone › 둘러방 › captures 에도 남습니다.

촬영 팁: 밝게, 천천히(한 바퀴 돌리는 데 30초쯤), 제자리에서 돌리지 말고 걸으면서, 흰 벽만 비추지 말고 가구·모서리를 함께,
다른 사람은 방 밖으로. 3DGS는 서로 다른 위치에서 찍은 사진의 차이로 거리를 알아내므로, 제자리에서 돌리기만 하면 그 자리를 벗어난 시점이 뭉개집니다.

**촬영 중 경고** — 화면 아래에 색 띠가 뜨고 진동합니다(같은 경고는 4초에 한 번, VoiceOver 는 소리로 읽음).
빨강은 지금 찍히는 사진이 망가지는 중, 주황은 결과가 나빠지는 촬영 습관입니다. 기준값은 `CaptureCoach.Config`(`Features/Capture/FrameSampler.swift`).

| 경고 | 언제 | 안내 |
|---|---|---|
| 위치를 놓쳤어요 (빨강) | ARKit 추적이 끊기거나 위치를 다시 찾는 중 0.5초 이상 | 방금 찍은 곳을 천천히 다시 비추기 |
| 어두워서 사진이 흔들려요 (빨강) | 아래 흔들림 조건 + 셔터(평활)가 1/75초보다 김 (ARKit 은 60 fps 라 최대 1/60초) | 불을 켜거나 더 천천히 |
| 너무 빨라요 · 사진이 흔들려요 (빨강) | 예상 흔들림 5 px 이상이 0.4초 이상 (또는 ARKit 이 "움직임이 과함") | 천천히. **10 px 이상 흔들린 프레임은 저장하지 않음** |
| 무늬 없는 면만 보여요 (주황) | 화면 밝기 변화 점수 6 미만 1초 이상 (흰 벽 · 화이트보드만 가득) | 가구·문·모서리가 함께 보이게 물러나기 |
| 너무 가까워요 (주황) | LiDAR 로 잰 화면 가운데 거리 45 cm 미만 1초 이상 | 한 걸음 물러나기 |
| 제자리에서만 찍고 있어요 (주황, 방 촬영만) | 최근 8초 동안 35 cm 도 안 움직이고 바라보는 방향이 60° 이상 바뀜, 또는 15초가 지나도 이동 범위 1 m 미만이고 걷지 않음 | 벽을 따라 걸으면서 |
| 바닥이 거의 안 찍혔어요 (주황, 방 촬영 · LiDAR 기기만) | 첫 바퀴(12방향 + 이동 범위 2 m)를 마쳤거나 60초가 지났는데, 걸어온 길 중 '바닥 사진'을 찍은 곳이 60% 미만이고 폰이 수평(20° 이상 숙이지 않음)인 채로 6초 | 폰을 30~45° 숙여 걸어온 길의 바닥을 찍기 |

예상 흔들림(px) = 화면 가운데 점이 움직이는 속도(회전 − 옆 이동 ÷ 가운데 거리, 가구를 바라보며 돌 때처럼 서로 상쇄되면 작아짐) × 셔터 시간(`ARCamera.exposureDuration`) × 초점거리(px).
5 px · 10 px 는 시작값입니다. 촬영본 `poses.json` 의 `blurPx` 와 실제 흐림을 비교해 조정하세요.
정지를 눌렀을 때 이동 범위가 1 m 미만이면 "제자리에서만 찍었어요", 바닥을 찍은 곳이 60% 미만이면 "바닥이 덜 찍혔어요" 를 묻습니다(더 찍기 / 그대로 끝내기).

**바닥 판단 (LiDAR)** — 저장한 프레임마다 깊이 지도에서 32×24 점(신뢰도 medium 이상, 0.2~5 m)을 월드 좌표로 바꿉니다.
그 높이 히스토그램(신뢰도 medium 이상 점만)에서 *가장 낮은, 점이 150개 이상 모인 높이*를 바닥으로 잡고 — 단 바로 위 25 cm 안에 3배 넘게 큰 수평면이 있으면 그쪽 —
(탁자 · 침대 윗면은 바닥보다 위라 걸러짐, capture 3 에서 −1.61 m vs RoomPlan −1.62 m),
점의 25% 이상이 바닥(± 5 cm)인 프레임을 '바닥 사진'으로 셉니다(수평으로 들면 보통 5% 안팎). 카메라가 지나간 자리(± 25 cm, 20 cm 칸)가 '걸어온 길',
바닥 사진을 찍은 자리 ± 50 cm 가 '바닥을 찍은 곳'이고, 화면 아래 막대의 **바닥 n%** = 걸어온 길 중 바닥을 찍은 곳의 비율입니다.
첫 바퀴가 끝나면 안내 문구가 "이제 폰을 아래로 30~45° 기울여 걸어온 길의 바닥을 찍어 주세요 (바닥 n%)" 로 바뀝니다(85% 미만일 때).
수평으로 들고 1.5 m 높이에서 보면 화면 아래 끝이 약 2 m 앞 바닥에 닿아, 발밑 · 가구 밑동 · 벽 쪽 바닥이 안 찍히고 3DGS 바닥에 구멍이 생깁니다
(capture 3: 152장 중 바닥 사진 2장 → 걸어온 길의 18% → 이 경고가 93초에 떴고 끝낼 때도 물었을 것). 바닥을 내려다보는 동안에는 '무늬 없는 면' 경고를 띄우지 않습니다.
바닥 비율의 분모는 격자 768점 전체라(5 m 넘는 먼 벽처럼 깊이가 없는 점 포함) 넓은 방에서 수평으로 든 프레임이 바닥 사진으로 잡히지 않고,
반들반들하거나 어두운 바닥은 신뢰도가 낮게 나와도 바닥 비율에는 셉니다.
방 바닥보다 6~25 cm 낮은 현관 · 욕실 · 베란다 바닥(바로 위에 3배 넘게 큰 바닥이 있는 수평면)도 바닥으로 셉니다. 바닥 높이를 못 찾는 동안은 이전 추정을 유지합니다.
이동 범위는 카메라가 지나간 위치의 바닥 기준 상자 대각선이라, 손떨림이 쌓여 늘어나지 않습니다(예전 "이동 거리" 는 손떨림까지 더해 제자리 촬영도 4.8 m 로 셌음).

**가구 전체 사진 (방 촬영 · LiDAR + RoomPlan)** — 가구마다 *전체가 한 화면에, 가려지지 않고, 충분히 크게* 찍힌 사진이 한 장 이상 있게 안내합니다
(가구를 따로 3D 로 만들거나 재질을 다시 입힐 때 쓰는 대표 사진). 코드: `Features/Capture/FurnitureShots.swift`(`FurnitureShotConfig` 에 기준값).
- RoomPlan 이 스캔 중에 고쳐 주는 가구 상자(`RoomCaptureSessionDelegate.captureSession(_:didUpdate:)`)와 프레임마다의 카메라 포즈 · LiDAR 깊이(64×48 격자)로 10 Hz 마다 점검합니다.
- 통과 조건: ① 상자 꼭짓점 8개가 모두 화면 안(가장자리 2% 여유) ② 카메라 쪽 옆면 · 윗면에 면마다 5×5 점을 찍어 LiDAR 와 비교해 전체 85% 이상 · 면마다 60% 이상 안 가려짐
  (상자 면보다 10 cm + 거리의 3% 넘게 앞에 무언가 있으면 가려진 점. 단 그것이 가구 자신 · 위에 놓인 물건(컵 · 책 · TV) · 바닥 · 이 가구에 붙은 더 작은 가구(식탁에 넣은 의자)면 치지 않음)
  ③ 화면 가로나 세로의 30% 이상 ④ 예상 흔들림 6 px 이하. 깊이를 못 재면(5 m 밖 등) 가려짐은 모르는 것으로 보고 ①③④ 로만 판단합니다.
- 통과한 프레임이 **저장되면** 화면 위 목록의 그 가구가 초록 ✓ 로 바뀌고 '성공' 진동이 옵니다. 아직 전체 사진이 없는 가구가 지금 화면에서 통과하면 이동 · 회전이 적어도 그 프레임을 저장합니다(가구마다 한 번).
- 같은 종류 · 같은 크기(가로 · 깊이 · 높이 ±6 cm) 가구는 하나만 찍혀도 함께 ✓ (민트, 식탁 의자 6개 등). 식탁 밑에 넣은 의자는 식탁 반대쪽(의자가 바깥으로 나온 쪽)에서 보면 통과합니다.
- 첫 바퀴(12방향 + 2 m)를 마쳤거나 60초가 지나면 화면 아래 보라 띠로 아직 전체 사진이 없는 가구 하나를 안내합니다:
  화면에 걸려 있으면 이유(다 안 들어와요 → 한두 걸음 물러나기 · ○○에 가려져 있어요 → 가리는 것이 없는 쪽으로 · 너무 작게 보여요 → 가까이 · 흔들렸어요),
  화면 밖이면 가장 가까운 가구 쪽(왼쪽 · 오른쪽 · 뒤). 촬영 경고(빨강 · 주황)가 떠 있으면 경고가 먼저입니다. 안내 문구도 바닥 다음 단계로 "가구 n개는 아직 전체 사진이 없어요" 를 보여 줍니다.
- RoomPlan 이 상자를 8 cm · 8° 넘게 고치거나 가구를 나중에 찾으면, 지금까지 저장한 프레임으로 다시 점검합니다. 정지를 누를 때 아직 없는 가구가 있으면 "전체 사진이 없는 가구가 있어요" 를 묻습니다.
- 촬영을 마치면 RoomPlan **최종** 가구 상자로 저장한 프레임을 모두 다시 점검해 `furniture_shots.json` 을 씁니다(아래 형식).

**방이 좁아 다 안 들어올 때 (폰 돌리기 · 촬영 뒤 0.5× 광각)** — ARKit(LiDAR · RoomPlan)은 스캔 중 **1× 카메라 영상만** 앱에 줍니다.
world tracking 이 울트라 와이드를 내부에서 쓰지만 API 로 열어 주지 않고([Apple 포럼 답변](https://developer.apple.com/forums/thread/831657)),
스캔 중에 다른 카메라를 따로 열면 ARSession 이 끊겨 전체 촬영본의 포즈가 망가질 수 있습니다. 그래서 두 단계로 나눴습니다.
- 스캔 중: 1× 화각은 센서 긴 쪽(1920) 약 65° · 짧은 쪽(1440) 약 51° 입니다. 가구가 짧은 쪽으로만 넘치면 안내 띠가
  "폰을 가로로(또는 세로로) 돌려 찍으면 더 넓게 들어와요" 로 바뀝니다(세로로 든 폰에서 좌우 51° → 가로로 들면 65°, 약 30% 넓어짐).
  그래도 같은 가구가 8초 넘게 다 안 들어오면 "촬영을 마칠 때 0.5× 광각으로 한 장 찍을 수 있어요" 를 안내합니다.
- 정지를 누를 때: 전체 사진이 없는 가구 중 '다 안 들어옴 · 가려짐' 인 것이 있으면 경고에 **끝내고 0.5× 광각으로 찍기** 버튼이 생깁니다.
  고르면 RoomPlan 최종 결과를 받고 ARSession 을 멈춘 뒤 0.5× 카메라(AVFoundation `builtInUltraWideCamera`)를 열어,
  그런 가구만 한 장씩 찍게 합니다(같은 모양 가구는 한 장, '다 안 들어옴' 먼저, 건너뛰기 가능). 저장: `wide/NNN.jpg` + `wide_shots.json`.
- 0.5× 사진에는 **ARKit 포즈 · LiDAR 깊이가 없습니다.** 서버에서 frames/ 와 특징점 매칭으로 위치를 찾거나(COLMAP `image_registrator` · hloc),
  단일 사진 3D(SAM 3D) 입력 · SAM 3 마스크(글자 프롬프트 = category)로 쓰세요. `K` 는 AVFoundation 이 준 근사값(왜곡 보정된 사진 기준)입니다.

## 3. capture.zip 형식 (AI 팀원용)

```
capture/
  meta.json                 기기, 해상도, 좌표계 설명, frameCount, roomplan 여부
  poses.json                프레임별 카메라 포즈·내부 파라미터 (아래)
  frames/000000.jpg …       1920×1440 JPEG, 센서 원래 방향(가로), 회전하지 않음 → K 가 그대로 맞음
  depth/000000.png …        (LiDAR) 256×192 16-bit PNG, 밀리미터, 0 = 무효. RGB 와 같은 방향 ← AI 가 쓰는 원본
  confidence/000000.png …   (LiDAR) 8-bit PNG, 0 low / 1 medium / 2 high ← 원본
  depth_vis/000000.jpg …    (LiDAR) 깊이 히트맵 (Turbo: 0.2 m 파랑 → 5 m 빨강, 검정 = 측정 없음) ← 사람이 보는 용도
  confidence_vis/000000.png (LiDAR) 신뢰도 색 (빨강 low · 노랑 medium · 초록 high) ← 사람이 보는 용도
  depth.json                (LiDAR) 파일 설명 + 프레임별 요약: 측정 비율, 최소·중앙·최대 거리(m), 신뢰도 비율, colorToDepthScale
  roomplan.json             (LiDAR+RoomPlan) Apple CapturedRoom 원본 JSON
  roomplan_structure.json   (LiDAR+RoomPlan) 우리 API 형식 roomGeometry/roomDimensions/objects — 구조 추출 정답·대체값
  roomplan.usdz             (LiDAR+RoomPlan) 파라메트릭 3D 모델
  furniture_shots.json      (LiDAR+RoomPlan) 가구별 '전체 사진' frameId + 그 사진 속 상자 위치(bbox) (아래)
  wide/000.jpg …            (끝낼 때 0.5× 광각을 고른 경우) 0.5× 광각 가구 사진, 센서 원래 방향(가로) — 포즈 · 깊이 없음
  wide_shots.json           (위와 같음) 사진마다 objectId · 같은 모양 가구(alsoFor) · 찍은 이유 · 해상도 · 근사 K
```

`poses.json` 항목:
```json
{ "frameId": 12, "ts": 18234.51, "width": 1920, "height": 1440, "tracking": "normal", "depth": true,
  "K": { "fx": 1445.3, "fy": 1445.3, "cx": 959.1, "cy": 718.4 },
  "T_wc": [[r00, r01, r02, tx], [r10, r11, r12, ty], [r20, r21, r22, tz], [0, 0, 0, 1]],
  "exposureS": 0.008333, "blurPx": 1.7, "floorShare": 0.41 }
```
`exposureS` 는 셔터 시간(초), `blurPx` 는 저장 순간의 예상 흔들림(px, JPG 해상도 기준), `floorShare` 는 그 프레임의 LiDAR 점 중 바닥인 비율입니다
(흐린 프레임 거르기 · 바닥 사진 고르기에 쓰세요, 예전 촬영본에는 없음). `meta.json` 에는 `floorHeightM`(LiDAR 로 찾은 바닥 높이, ARKit 월드 y),
`walkedFloorCoverage`(걸어온 길 중 바닥을 찍은 곳의 비율), `floorPhotos`(바닥 사진 수)가 들어갑니다.

`furniture_shots.json` (가구마다 전체가 한 화면에 가려지지 않고 찍힌 프레임. objectId 는 `roomplan_structure.json` 과 같음):
```json
{ "version": 1, "frameCount": 153,
  "rule": { "minVisible": 0.85, "minFaceVisible": 0.6, "minFill": 0.3, "maxBlurPx": 6, "marginFrac": 0.02, "twinTolM": 0.06 },
  "objects": [
    { "objectId": "…", "category": "chair", "label": "의자 2", "status": "full",
      "shots": [ { "frameId": 37, "score": 0.91, "visible": 1.0, "fill": 0.5, "viewYawDeg": 45.0, "distanceM": 1.86,
                   "bbox": [612.4, 233.0, 1381.9, 1197.5] } ] },
    { "objectId": "…", "category": "chair", "label": "의자 3", "status": "shared", "sharedWith": "…",
      "problem": "blocked", "blockedBy": "…", "tuckedInto": "…", "shots": [ … 가장 나았던 1장 ] },
    { "objectId": "…", "category": "sofa", "label": "소파", "status": "missing", "problem": "notWhole", "shots": [ … ] } ] }
```
`status`: `full` = 전체 사진 있음(점수 순 · 바라보는 방향이 40° 이상 다른 사진 최대 3장), `shared` = 같은 모양 가구(`sharedWith`)의 사진으로 대신, `missing` = 없음
(`problem`: notWhole 다 안 들어옴 · blocked 가려짐(`blockedBy` 가린 가구) · tooFar 작음 · blurry 흔들림 · notInView 안 찍힘, `shots` 에는 가장 나았던 1장).
`bbox` 는 그 JPG 속 RoomPlan 상자 범위 `[u0, v0, u1, v1]`(px, 센서 원래 방향 = K 와 같은 좌표) → SAM 3 상자 프롬프트로 가구 마스크를 뽑는 데 쓰세요.
`tuckedInto` = 부피의 15% 이상이 그 가구 상자 안(식탁 밑에 넣은 의자 → 식탁)이라 어느 방향에서도 일부는 안 보이는 가구. `visible` 이 없으면 LiDAR 로 가려짐을 못 잰 것입니다.

`wide_shots.json` (촬영을 마친 뒤 0.5× 광각으로 찍은 가구 사진):
```json
{ "version": 1, "camera": "builtInUltraWideCamera (0.5x) · AVFoundation · ARKit/RoomPlan 스캔을 마친 뒤",
  "shots": [ { "file": "wide/000.jpg", "objectId": "…", "alsoFor": ["…"], "category": "sofa", "label": "소파",
               "reason": "notWhole", "width": 4032, "height": 3024,
               "K": { "fx": 1580.2, "fy": 1580.2, "cx": 2016.0, "cy": 1512.0 }, "takenAt": "2026-10-08T08:12:31Z" } ] }
```
`objectId` · `alsoFor` 는 `furniture_shots.json` · `roomplan_structure.json` 과 같은 id 입니다(같은 모양 가구는 이 사진 한 장을 함께 씀).

- **좌표계**: ARKit 월드 = **미터**, Y-up, 오른손. `T_wc` 는 camera→world, row-major, `ARCamera.transform` 그대로.
- **카메라 축**: x 오른쪽, y 위, −z 정면 = OpenGL / nerfstudio `transforms.json` 규약. (COLMAP/OpenCV 는 y·z 부호 반대)
- 모든 결과물(3DGS PLY, collision.glb, roomGeometry, objects)을 **이 미터 좌표계 그대로** 내보내 주세요. 그러면 앱에서 추가 변환 없이 겹칩니다.
- 프레임은 15 cm 이동 또는 10° 회전마다, 추적 상태가 normal 이고 예상 흔들림이 10 px 미만일 때만 저장됩니다(가구 촬영은 7.5 cm).

**깊이가 검게 보이는 이유**: `depth/*.png` 는 거리(mm)를 16비트 정수로 그대로 담은 **데이터**입니다. 방 안 거리는 250–5000 정도라
0–65535 범위의 뷰어에서는 거의 검게 보이는 게 정상이고(confidence 도 0/1/2 라 검정), 사람이 볼 때는 `depth_vis/` · `confidence_vis/` 를 보면 됩니다.
히트맵은 색으로 바꾸면서 정확한 거리가 사라지므로 AI 입력으로는 원본을 쓰세요. 전체 깊이 값을 JSON 으로 풀면 프레임당 수백 KB 라
`depth.json` 에는 요약만 넣었습니다. 파이썬에서 원본 읽기:

```python
import numpy as np, json
from PIL import Image
depth_m = np.array(Image.open("capture/depth/000000.png")).astype(np.float32) / 1000   # (192, 256) 미터, 0 = 없음
conf = np.array(Image.open("capture/confidence/000000.png"))                            # 0/1/2
pose = json.load(open("capture/poses.json"))[0]                                          # K 는 1920×1440 기준
s = 256 / pose["width"]; fx, fy, cx, cy = (pose["K"][k] * s for k in ("fx", "fy", "cx", "cy"))  # 깊이 해상도 K
```

예전 촬영본(히트맵이 없는 zip)은 `python3 tools/capture/depth_tools.py <capture 폴더 또는 zip>` 로 같은 `depth_vis/` · `confidence_vis/` · `depth.json` 을 만들 수 있고,
**`points.ply`**(모든 프레임의 신뢰도 높은 깊이를 카메라 위치로 합친 컬러 점군, 미터 좌표)도 함께 만듭니다. `--npy` 를 주면 프레임별 float32 미터 배열(`depth_m/*.npy`)도 저장합니다.

## 4. 백엔드 API 계약 (앱이 기대하는 형태)

인증: `Authorization: Bearer <accessToken>` (키체인에 저장, 401 이 오면 `POST /auth/refresh` 를 한 번 부르고 원 요청을 다시 보냄) + 데모 서버 호환용 `X-User-Id`.
요청 안전장치(명세 v1): 모든 POST 에 `Idempotency-Key`(요청마다 UUID, 네트워크가 끊겨 다시 보낼 때 같은 값), 수정 · 삭제에 `If-Match`(직전 응답의 `ETag`),
배치 첫 저장은 `If-None-Match: *`. 가구 구분 PATCH 는 `If-Match: "<objectsVersion>"`. 배치 저장이 428 이면 앱이 ETag 를 받아 한 번 다시 보내고,
412 는 덮어쓰지 않고 알립니다(배치는 "덮어쓰기" 를 고르면 지금 버전을 받아 다시 저장, 가구 구분은 닫고 새로 불러옴).
촬영 업로드는 multipart 가 아니라 **zip 원본을 body 로** 보냅니다 (`Content-Type: application/zip`). 사진·서류는 multipart 입니다.

**응답 형태는 너그럽게 받습니다**: ID 는 숫자(`12`)든 문자열(`"12"`)이든 OK, `{status, message, data}` 봉투는 자동으로 벗기고,
목록은 `[…]` / `{data:[…]}` / `{content:[…]}`(Spring Page) / `{listings:[…]}` 모두 인식합니다. 매물은 StayView 클래스 다이어그램 필드명
(`spaceId`, `address`, `deposit`, `monthlyRent`, `availableDate`, `images[{imageUrl, imageOrder}]`)도 받습니다.
서버에 아직 없는 API(404/405/501)는 앱이 대신 동작합니다: 관심 매물은 기기에 저장, 내가 올린 매물 = 전체 중 내 것. 추천 API 는 쓰지 않습니다(홈 = 최신순 목록).

| 메서드 | 경로 | 요청 | 응답 |
|---|---|---|---|
| POST | `/auth/signup` | `{email, password(12~128자), displayName}` | `201 User` (토큰 없음 → 앱이 이어서 login) · 중복 이메일 409 |
| POST | `/auth/login` | `{email, password}` | `TokenPair {accessToken, refreshToken, expiresIn, user{userId, email, displayName, roles}}` · 틀리면 401 |
| POST | `/auth/oauth/kakao` · `/auth/oauth/google` | 카카오 `{accessToken}` · 구글 `{idToken}` (SDK 가 준 토큰, 서버가 검증) | `TokenPair` |
| POST | `/auth/refresh` | `{refreshToken}` | `TokenPair` (refresh 토큰도 매번 새로) · 만료 401 → 앱이 로그아웃 |
| POST | `/auth/logout` | `{refreshToken}` | `204` |
| GET | `/users/me/agent-profile` | | `{status: PENDING\|APPROVED\|REJECTED, name, licenseNumber, officeName, documentName, rejectReason?}` · 신청 전 404 |
| POST | `/users/me/agent-profile` | multipart: `name, licenseNumber, officeName, documentName, document`(이미지) | `AgentProfile` |
| GET | `/users/me/listings` | | `[Listing]` |
| GET | `/users/me/scraps` | | `[Listing]` (관심 매물) |
| POST / DELETE | `/listings/{id}/scrap` | | `200` |
| GET | `/listings?location=&dealType=&roomType=&maxDeposit=&maxPrice=&minLat=&maxLat=&minLng=&maxLng=` | 지도 화면은 보이는 범위(사방 25% 여유)를 `minLat…maxLng` 로 보냄. 기본 정렬 = 최신순 | `[Listing]` (각 매물 `agent.isVerifiedBroker`) |
| POST | `/listings` | `{location, dealType, price:{deposit,monthly}, maintenanceFee?, roomType, floor?, totalFloors?, area, supplyArea?, rooms?, bathrooms?, availableFrom, rentalOptions[], latitude?, longitude?}` | `201 {listingId}` |
| POST | `/listings/{id}/images` | multipart: `images` 여러 개 (선택 순서 = 표시 순서) | `200` |
| POST | `/listings/{id}/reports` | `{reason, detail?}` | `200` |
| GET | `/chat` | | `[{chatId, listing:{listingId, price, dealType, location, roomType, floor, thumbnailUri}, counterpartName, lastMessage, lastMessageAt, unreadCount}]` |
| POST | `/chat` | `{listingId}` | `{chatId}` (있으면 기존 방) |
| GET | `/chat/{chatId}` | | `{chatId, listing, counterpartName, officeName, messages:[{messageId, senderId, senderName, message, sentAt}]}` |
| POST | `/chat/{chatId}` | `{message}` | `200` |
| GET | `/listings/{id}` | | `Listing` |
| POST | `/listings/{id}/captures` | body = capture.zip | `202 {jobId, status}` |
| GET | `/ai-jobs/{jobId}` | | `{jobId, status: QUEUED\|RUNNING\|COMPLETED\|FAILED, progress?, message?, roomStateId?}` |
| GET | `/listings/{id}/space` | | `SpaceResponse` |
| GET | `/listings/{id}/objects` | | `{objects:[SceneObject]}` |
| PATCH | `/listings/{id}/objects` | `{objects:[{objectId, ownershipType: PERSONAL\|RENTAL_OPTION\|UNKNOWN}]}` — **매물을 올린 중개사만**(아니면 403), 바뀌면 `objectsVersion` +1 | `{objectsVersion}` |
| POST | `/listings/{id}/room-states` | `{sourceSpaceVersion?, sourceObjectsVersion?, removedObjectIds:[1개 이상, PERSONAL 이면서 고정 설비가 아닌 것]}` — 매물을 보는 누구나. 버전이 지금과 다르면 409, 규칙 위반 422 | `202 {jobId, status, roomStateId}` |
| GET | `/listings/{id}/room-states` | | 이 매물에서 **내가 만든** 입주 상태, 최근 것이 앞 `{items:[RoomState]}` |
| GET | `/room-states/{roomStateId}` | | 만든 사람만(아니면 404) `{roomStateId, listingId, createdBy, status: PROCESSING\|READY\|FAILED\|CANCELED, jobId, sourceSpaceVersion, sourceObjectsVersion, createdAt, removedObjectIds[], sceneUri?, collisionGeometryUri?, remainingObjects[]?}` |
| DELETE | `/room-states/{roomStateId}` | | 만든 사람만, `204` |
| GET/PUT | `/listings/{id}/placements` | `{placements:[Placement]}` | `{placementSetId, savedAt, placements?}` |
| GET | `/users/me/furniture` | | `{furniture:[Furniture]}` |
| POST | `/furniture` | `{name, category}` | `201 {furnitureId}` |
| POST | `/furniture/{id}/captures` | body = capture.zip | `202 {jobId, status}` |
| GET | `/furniture/{id}` | | `Furniture` |

**입주 상태 (명세 v1 방식)**: 가구 구분(개인 가구 / 임대 옵션)은 매물을 올린 중개사가 하고, 가구를 뺀 입주 상태는 매물을 보는 사람이 ‘가구 빼 보기’에서 각자 만듭니다. 입주 상태는 **만든 사람만** 볼 수 있어서 매물에는 붙지 않고, 앱은 `GET /listings/{id}/room-states` 로 내 것 중 최신 완성본(`READY`, 지금 `spaceVersion` 으로 만든 것)을 찾아 ‘입주 예상 공간’으로 엽니다. 요청에는 GET space 에서 받은 `spaceVersion` · `objectsVersion` 을 그대로 보내고, 그 사이 중개사가 구분을 바꾸면 서버는 409 를 돌려줍니다(앱은 다시 불러옴).

```jsonc
// Listing (가격 단위: 만원. 전세는 monthly 0 + dealType "JEONSE")
{ "listingId": "12", "location": "서울 동작구 상도동 123-4, 302호", "dealType": "MONTHLY",
  "price": {"deposit": 500, "monthly": 31}, "maintenanceFee": 5, "roomType": "ONE_ROOM",   // ONE_ROOM | TWO_ROOM | THREE_ROOM | OFFICETEL
  "floor": 3, "totalFloors": 5, "area": 23.8, "supplyArea": 33.05, "rooms": 1, "bathrooms": 1,
  "availableFrom": "IMMEDIATE",                                   // 또는 "2026-10-01"
  "rentalOptions": ["aircon","washer"],                           // parking pet elevator aircon fridge washer bed desk closet induction
  "thumbnailUri": "https://…", "imageUris": ["https://…", "…"], "latitude": 37.5029, "longitude": 126.9477,
  "livingEnvironment": "상도역 도보 3분, 편의점 1분",
  "agent": { "userId": "5", "name": "차유현", "officeName": "상도 공인중개사", "phone": "010-…",
             "isVerifiedBroker": true },                       // false = 집주인 직접 등록 (phone 은 null 가능)
  "isScrapped": false,
  "space3DInfo": { "status": "COMPLETED", "jobId": "j-1" } }                  // 입주 상태는 매물에 붙지 않는다 (사용자별)

// SpaceResponse — 좌표는 모두 미터, ARKit 월드. yaw: +Y 축 반시계(위에서 볼 때), 도(°)
{ "3dgsUri": "https://…/scene_current.ply",        // 3DGS (없으면 pointsUri 로 포인트클라우드 표시)
  "pointsUri": "https://…/points.ply",              // 선택: 7–8주차 MVP 용 x y z r g b PLY
  "collisionGeometryUri": "https://…/collision.glb",
  "spaceVersion": 1, "objectsVersion": 3,             // 다시 촬영하면 spaceVersion +1, 가구 구분을 바꾸면 objectsVersion +1
  "roomDimensions": { "width": 3.4, "depth": 2.8, "height": 2.35, "area": 9.52 },
  "roomGeometry": {
    "floorHeight": -1.42, "ceilingHeight": 2.35,     // floorHeight = 바닥의 절대 Y(ARKit 월드), ceilingHeight = 층고(바닥 기준 높이)
    "walls":   [ { "id": "w1", "from": [x, z], "to": [x, z], "height": 2.35 } ],   // 벽의 실내면 선분
    "doors":   [ { "id": "d1", "type": "door",   "position": {x,y,z}, "rotation": {"yaw": 0}, "dimensions": {width,height,depth} } ],
    "windows": [ { "id": "n1", "type": "window", "position": {x,y,z}, "rotation": {"yaw": 0}, "dimensions": {width,height,depth} } ],
    "boundingBox": { "min": {x,y,z}, "max": {x,y,z} } },
  "objects": [ { "objectId": "o3", "category": "bed", "position": {x,y,z},      // position = OBB 중심
                 "rotation": {"yaw": 90}, "dimensions": {"width": 2.0, "height": 0.5, "depth": 1.5},
                 "ownershipType": null,                                          // PERSONAL | RENTAL_OPTION | UNKNOWN(또는 null)
                 "removable": true } ] }                                         // false = 고정 설비(싱크대 등). 없으면 종류로 판단

// Furniture
{ "furnitureId": "f7", "name": "자취방 침대", "category": "bed", "status": "COMPLETED",
  "modelUri": "https://…/furniture.glb",   // 미터, 원점 = 바닥 중심, Y-up (앱이 dimensions 에 맞춰 크기 보정)
  "dimensions": {"width": 1.1, "height": 0.45, "depth": 2.0}, "boundingBox": {…}, "collisionMeshUri": "…" }

// Placement — position = 가구 바닥 중심(y = floorHeight)
{ "furnitureId": "f7", "position": {x,y,z}, "rotation": {"yaw": 90}, "isPlaceable": true,
  "collisions": [ { "with": "w2", "type": "wall", "overlap": 0.03 } ] }
```

URI 는 앱이 직접 받을 수 있는 **http(s) URL**(pre-signed 가능) 또는 서버 기준 상대 경로(`/files/…`)여야 합니다. `s3://` 는 앱이 못 받습니다.

### 4-1. 소셜 로그인 설정 (카카오 · 구글)

앱은 SDK 가 준 토큰을 `POST /auth/oauth/{kakao|google}` 로 서버에 넘기고, 서버가 검증한 뒤 우리 토큰(TokenPair)을 줍니다.
SDK 연결 자리는 `App/Session.swift` 의 `SocialLogin.token(for:)` 하나입니다. 앱 키가 없으면 "앱 키를 설정한 뒤 쓸 수 있어요" 를 보여 주고,
데모 모드에서는 SDK 대신 이름 · 이메일 가입 시트로 동작합니다.

| | 카카오 | 구글 |
|---|---|---|
| 키 발급 | Kakao Developers › 내 애플리케이션 › 네이티브 앱 키, 플랫폼에 iOS 번들 ID 등록, 카카오 로그인 활성화 | Google Cloud 콘솔 › OAuth 클라이언트 ID(iOS), 번들 ID 등록 |
| 패키지 (SPM) | `https://github.com/kakao/kakao-ios-sdk` (KakaoSDKAuth, KakaoSDKUser) | `https://github.com/google/GoogleSignIn-iOS` |
| Info.plist | URL Scheme `kakao{네이티브 앱 키}`, `LSApplicationQueriesSchemes`: `kakaokompassauth`, `kakaolink` | URL Scheme = 역순 클라이언트 ID, `GIDClientID` |
| 토큰 | `UserApi.shared.loginWithKakaoTalk` (없으면 `loginWithKakaoAccount`) → `oauthToken.accessToken` | `GIDSignIn.sharedInstance.signIn(withPresenting:)` → `user.idToken?.tokenString` |
| 서버 검증 | `GET https://kapi.kakao.com/v2/user/me` (Authorization: Bearer 토큰) 로 회원번호 확인 | 구글 공개키로 ID 토큰 서명 · `aud`(클라이언트 ID) · `exp` 검증, `sub` 사용 |

## 5. 3D 뷰어 구조

- SwiftUI 안의 `WKWebView` 가 `dulleobang://app/index.html` 을 엽니다. `ViewerAssetHandler`(WKURLSchemeHandler)가
  번들의 `Resources/Viewer` 와 내려받은 3D 파일(`AssetCache`, `dulleobang://app/assets/…`)을 1 MB 청크로 스트리밍합니다.
- three.js / gaussian-splats-3d 는 기본적으로 jsDelivr CDN 에서 받습니다(인터넷 필요). 시연 때 불안하면
  `Resources/Viewer/vendor/README.txt` 대로 로컬 사본을 넣으면 자동으로 그쪽을 씁니다(설정 탭에 "앱 내장" 표시).
- Swift → JS: `window.DV.loadScene / setMode('walk'|'overview') / resetView / setOverlay / setObjectOwnership / addFurniture / setFurnitureState / setFurnitureTransform / removeFurniture`
- JS → Swift: `ready / loaded / progress / error / select / transform / furnitureLoaded`
- **충돌 판정은 Swift(`CollisionChecker`)가 합니다.** JS 는 드래그 중 위치를 보내고 결과 색(초록/빨강)만 칠합니다 → 규칙이 한 곳에만 있고 XCTest 로 검증됩니다.
- 조작: 1인칭 = 한 손가락 둘러보기, 두 손가락 드래그 이동 / 평면뷰 = 위에서 내려다보며 시작, 한 손가락 회전·기울이기, 핀치 줌, 두 손가락 이동 / 가구 = 누른 채 드래그, 카드의 ⟲⟳ 로 15° 회전. "초기화" = 처음 시점, 가구를 추가하면 자동으로 평면뷰.
- 평면뷰는 카메라 near plane 을 천장 너머로 밀어 천장을 걷어낸 것처럼 보입니다(스플랫·포인트·메시 공통 트릭).
- **JS 디버깅**: 폰을 Mac 에 연결 → Mac Safari › 개발자 › (폰 이름) › Dulleobang Viewer. 콘솔·네트워크를 볼 수 있습니다.

## 6. 테스트

Xcode › Product › Test (시뮬레이터 가능). 충돌 판정 13개 시나리오(벽 접촉 허용, 3 cm 침범 = overlap 0.03, 문 앞 차단,
창틀 높이, 개인 가구 제외·임대 옵션 충돌, 회전 벽, 다른 가구, 자동 배치, 비교), 프레임 선별, JSON 디코딩, URI 해석,
응답 호환(숫자 ID · 봉투 · Spring Page · StayView 필드명 · 채팅 content 필드), 가격/층/면적/주소 표기, 검색어 해석,
데모 모드(번들 시드가 모델로 디코딩되는지, 목록·필터·상세·공간·입주 상태·관심 매물·채팅·자동 답장·매물 등록·중개사 신청 흐름).
충돌 기하는 같은 시나리오를 파이썬으로 먼저 계산해 검증했습니다.

## 7. 알려진 제약 / TODO

- Xcode 에서 실행 중 RoomPlan(방 촬영) 화면이 `MTLDebugRenderCommandEncoder … realitykit::fsSurfacePbr … tonemapLUT` 로 멈추면: iOS 27 RealityKit 의 Metal API 검증 오류입니다(우리 코드 아님). 스킴에서 Metal API Validation 을 꺼 두었습니다(`project.yml` › schemes › run › `enableGPUValidationMode: false`). 홈 화면에서 앱을 직접 실행하면 검증이 없어 멈추지 않습니다.
- 컴파일 검증 전 코드입니다. RoomPlan 의 커스텀 ARSession 연동(`RoomCaptureView(frame:arSession:)`, `stop(pauseARSession:)`)은 iOS 17 API 입니다.
- 업로드는 포그라운드 URLSession 입니다(촬영 직후 화면을 유지). 백그라운드 업로드가 필요하면 background configuration 으로 교체.
- 3D 생성 완료 알림은 3~5초 폴링입니다. 푸시(APNs)를 붙이면 `JobAPI.wait` 만 교체하면 됩니다.
- 로그인은 데모 방식(이름·이메일)입니다. 실제 카카오/구글 로그인은 각 SDK(앱 키, URL 스킴, `LSApplicationQueriesSchemes`)를 붙이고 `Session.login` 만 바꾸면 됩니다.
- 채팅은 3초 폴링입니다. 서버에 WebSocket/STOMP 가 생기면 `ChatRoomView.refresh` 를 교체하세요. 알림 화면은 빈 상태만 있습니다.
- 서버에 중개사 인증 API 가 없으면 디버그 빌드에서는 기기에만 "승인" 상태로 저장해 인증 중개사 흐름을 볼 수 있습니다(설정 › 중개사 모드). 매물 등록 자체는 인증 없이도 됩니다.
- 지도는 서버 좌표(latitude/longitude)를 쓰고, 없으면 기기에서 주소를 지오코딩합니다(호수·동 표기는 쉼표 앞까지만 사용).
- 큰 3DGS PLY(수백 MB)는 모바일 메모리에 부담입니다. AI 쪽에서 `.ksplat` 변환이나 SH 차수 축소(0~1차)를 권장합니다 — 뷰어는 `.ply/.splat/.ksplat` 확장자를 모두 받습니다.
