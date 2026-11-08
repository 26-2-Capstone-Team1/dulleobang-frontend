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
| 홈: 최근 본 매물 · 새로 올라온 매물 (3열) | `HomeView` | 추천 없이 최신순. **2열 큰 사진 카드**(사진 위 `3D` 표시 · ♡ · 인증 ✓), 검색창 아래 **빠른 칩**(3D로 보기 · 월세 · 전세 · 방 종류), 최근 본 매물은 옆으로 넘기는 한 줄, ‘내 가구가 들어가는 방’ 바로가기, 필터 시트(3D 공간 · 거래 유형 · 방 종류 · 보증금 · 월세), 로그인하면 누구나 상단 "매물 등록" |
| 둘러보기: 지도 가격 말풍선 + "매물 · 총 N건" 시트 | `BrowseMapView` | 위쪽 빠른 칩(홈과 같음), 3D 매물은 초록 핀, **핀을 누르면 미리보기 카드**(한 번 더 누르면 상세), "이 지역 매물 N건" 시트, 가까운 매물 묶음(숫자), 좌표 없으면 주소 지오코딩 |
| 채팅 목록 · 채팅방 | `ChatListView`, `ChatRoomView` | 위에 **매물 카드 고정**(3D 보기 · 매물 보기), 날짜 구분선 · 보낸 시각, 질문 칩(세입자 쪽), 3초 폴링(웹소켓 붙이기 전) |
| 마이페이지(일반/중개사 메뉴) | `MyPageView` | 프로필(역할), **바로가기 3칸**(관심 매물 · 내 가구 · 올린 매물), ‘내 가구로 맞는 방 찾기’ |
| 매물 상세: 사진 1/8 · 가격 정보 · 상세 정보 · ♡ + 채팅하기 | `ListingDetailView` | 사진 위 **[3D로 보기 · 평면도]**, 3D · LiDAR 실측 · 인증 표시, 가격 밑 핵심 4칸(전용 · 층 · 관리비 · 입주), **3D 공간 카드를 위로**(작은 평면도 · 실측 치수 · 3D 둘러보기 · 입주 예상 · 내 가구 놓아보기), 옵션 아이콘, 생활 환경, 위치(반경 150 m 원), 신고 |
| 3D 보기: 검정 헤더 · 초기화 · 평면뷰 | `SpaceViewerView` + `viewer.js` | 아래 **[둘러보기 \| 평면]** · **[지금 모습 \| 입주 예상 AI]** 전환, 이름 붙은 도구 칸(치수 · 가구 빼기 · 내 가구 · 저장 · (중개사) 가구 구분), 입주 예상에는 ‘AI로 만든 예상 모습’ 표시, 배치 결과 한 줄(모두 들어가요 / n개가 부딪혀요) |
| 중개인 인증 → 중개사 인증 정보 | `AgentVerifyView`, `AgentInfoView` | 심사 중 / 반려 상태 카드 |
| 매물 등록하기: 등록 명의 · 주소 · 가격 · 면적(m²/평) · 입주 가능일 · 공간 자료 · 상세 사진 선택 · 옵션 | `ListingRegisterView` | **5단계**(기본 정보 · 가격 · 방 정보 · 사진·3D · 확인) + 진행 막대, 단계마다 꼭 필요한 칸만 확인, 마지막에 세입자에게 보일 카드 미리보기. **공간 촬영 = 앱 내 ARKit/LiDAR 촬영**(안내는 촬영 화면과 같은 3가지) → 매물 생성 후 zip 업로드 → AI 3D 생성. 실패해도 "이어서 등록하기" |

로고 글자는 `AppConfig.brandName`("둘러방") 한 곳에서 바꿀 수 있습니다(StayView 로 쓰려면 여기만 수정). 세이지 그린 `#578049` 등 색은 `Theme.swift` 의 `DB`(`accent` · `accentSoft` · `accentLine`, 입력칸 · 선 · 보조 글자는 따뜻한 베이지 회색 — 앱 아이콘 베이지 · 지도 공원 초록에 맞춤). 로고 마크(ㄷ 방 큐브: 처음 방 큐브에 천장을 덮어 왼쪽 벽 · 천장 · 바닥이 ‘ㄷ’ — 회색빛 베이지 타일 위 흰 방)는 `Theme.swift` 의 `LogoMark` 이고, 앱 아이콘 `Dulleobang/Assets.xcassets/AppIcon.appiconset`(1024px 한 장)과 같은 그림입니다.

**앱 화면 개선 (참고한 앱)**: Zillow(사진 · 3D 투어 · 평면도를 한곳에, 카드의 3D 표시) · 직방 · 다방(빠른 필터, 실측 면적 + 평면도, 다방 ‘3D 매물 조회수 2.5배’) · Airbnb(핵심 정보 2×2, 지도 가격 핀 → 카드, 단계별 등록 + 최종 검토) · Matterport(아래 도구 막대 · 이름 붙은 버튼 · ‘AI Enhanced’ 표시)를 참고했습니다. 색 · 글꼴 · 공용 컴포넌트는 그대로 `Theme.swift` 를 씁니다.

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
데모 모드를 끄면 기본으로 팀 GCP 서버 `http://34.47.87.3:8080/api` 에 연결합니다 (`AppConfig.defaultBaseURL` 한 곳, 설정 › 백엔드 서버에서 바꾸거나 **기본 서버로** 로 되돌림).
아직 HTTP 만 있어서 ATS 예외(`NSAllowsArbitraryLoads`)를 켜 두었고, HTTPS 도메인이 생기면 이 값만 `https://` 로 바꾸고 예외를 지우면 됩니다.
서버 VM 이 꺼져 있거나 백엔드 앱이 아직 안 올라가 있으면 "서버에 연결할 수 없습니다" 가 나오니, 그동안은 데모 모드를 켜 두세요.
홈 로고 옆의 초록 **데모** 표시를 누르면 바로 설정으로 갑니다.

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
**폰을 아래로 30~45° 기울여 바닥이 화면 절반쯤 보이게 걸어온 길을 한 바퀴 더**(아래 막대의 "바닥 n%" 가 85% 이상), **이어서 폰을 위로 30~45° 기울여 천장이 크게 보이게 한 바퀴 더**(LiDAR 기기만, 막대의 "천장 n%" 가 70% 이상 — 안 늘면 40초 뒤 안내를 접으니 억지로 채우지는 마세요), 필요하면 높이를 바꿔 한 바퀴 더(500장 정도 — 초당 약 5장씩 저장) → 정지 → LiDAR 기기면 RoomPlan 후처리(수 초) → `capture.zip` 생성 → **공유 / AirDrop** 으로 노트북에 전송.
zip 은 파일 앱 › 나의 iPhone › 둘러방 › captures 에도 남습니다.

촬영 팁: 밝게, 천천히(한 바퀴 돌리는 데 30초쯤), 제자리에서 돌리지 말고 걸으면서, 흰 벽만 비추지 말고 가구·모서리를 함께,
다른 사람은 방 밖으로. 3DGS는 서로 다른 위치에서 찍은 사진의 차이로 거리를 알아내므로, 제자리에서 돌리기만 하면 그 자리를 벗어난 시점이 뭉개집니다.
천장은 무늬가 거의 없어 폰이 위치를 놓치기 쉬우니, 벽 모서리나 조명이 같이 보이게 위로 30~45° 기울여 찍으세요(천장만 가득 찍지 않기).

**찍는 사람에게 부탁할 것은 두세 가지뿐**(앱 시작 화면에도 나옴): ① 방 전체를 천천히 한 바퀴 — 욕실 · 주방 같은 좁은 곳도 한 번씩 안에 들어가서, ② 다른 사람은 화면 밖으로, ③ (가능하면) 불 켜기. 어두우면 촬영을 시작하고 몇 초 뒤 손전등이 자동으로 켜져 끝날 때까지 켜져 있어요(오른쪽 위 버튼으로 끄기 · 설정(개발자)에서 자동 켜기 끄기).
나머지는 **화면 안내를 따르면 됩니다**: "너무 빨라요"(흔들림이 커서 사진을 버리기 직전), "OO쪽 벽에 아직 덜 찍힌 곳이 있어요"(RoomPlan 벽 · 바닥 중 사진 3장 미만에 나온 곳, 아래 `surfaceCoverage`),
"위치를 놓쳤어요 — 조금 뒤로 가서 다시 비추기"(추적이 끊김). 초점 고정 · 손떨림 보정 없음 · 초당 5장 저장 · 흔들린 사진 거르기는 앱이 알아서 합니다(초점은 시작 2초 뒤 고정, 설정(개발자)에서 끌 수 있음).
오른쪽 위 **촬영 지도**(미니맵): 초록 = 충분히 찍힌 벽, 노랑 · 주황 = 덜 찍힌 벽, 주황 점 = 덜 찍힌 바닥, 파란 점 = 내 위치(바라보는 방향이 늘 위쪽), 주황 동그라미 = 지금 안내하는 곳 — 첫 바퀴 뒤에는 화면 아래 화살표가 그쪽을 가리킵니다(바로 발밑이면 '발밑 바닥이 덜 찍혔어요').
팁(안 지켜도 됨 — 서버가 대부분 보정): 제자리에서 돌기보다 벽을 보며 옆으로(많이 돌기만 하면 안내 문구에 팁이 뜸), 물건과 40 cm 이상, 촬영 중 문 · 가구는 그대로(바꾸면 그 자리에 유령),
거울은 가리기, 한 번에 방 하나, 한 번 촬영은 3~5분 안으로(폰이 뜨거워지면 프레임이 빠짐 — `capture_log.json` 의 `thermal`).

**촬영 중 경고** — 화면 아래에 색 띠가 뜨고 진동합니다(같은 경고는 4초에 한 번, VoiceOver 는 소리로 읽음).
빨강은 지금 찍히는 사진이 망가지는 중, 주황은 결과가 나빠지는 촬영 습관입니다. 기준값은 `CaptureCoach.Config`(`Features/Capture/FrameSampler.swift`).

| 경고 | 언제 | 안내 |
|---|---|---|
| 위치를 놓쳤어요 (빨강) | ARKit 추적이 끊기거나 위치를 다시 찾는 중 0.5초 이상 | 조금 뒤로 가서 방금 찍은 곳을 천천히 다시 비추기 |
| 어두워서 사진이 흔들려요 (빨강) | 아래 흔들림 조건 + 셔터(평활)가 1/75초보다 김 (ARKit 은 60 fps 라 최대 1/60초) | 불을 켜거나 더 천천히 |
| 너무 빨라요 · 사진이 흔들려요 (빨강) | 예상 흔들림 5 px 이상이 0.4초 이상 (또는 ARKit 이 "움직임이 과함") | 천천히. **6 px 이상 흔들린 프레임은 저장하지 않음** |
| 무늬 없는 면만 보여요 (주황) | 화면 밝기 변화 점수 6 미만 1초 이상 (흰 벽 · 화이트보드만 가득) | 가구·문·모서리가 함께 보이게 물러나기 |
| 너무 가까워요 (주황) | LiDAR 로 잰 화면 가운데 거리 45 cm 미만 1초 이상 | 한 걸음 물러나기 |
| 제자리에서만 찍고 있어요 (주황, 방 촬영만) | 최근 8초 동안 35 cm 도 안 움직이고 바라보는 방향이 60° 이상 바뀜, 또는 15초가 지나도 이동 범위 1 m 미만이고 걷지 않음 | 방을 따라 걸으면서 (걸으면서도 많이 돌기만 하면 경고 대신 안내 문구에 '옆으로 걸으면 더 선명해요' 팁) |
| 바닥이 거의 안 찍혔어요 (주황, 방 촬영 · LiDAR 기기만) | 첫 바퀴(12방향 + 이동 범위 2 m)를 마쳤거나 60초가 지났는데, 걸어온 길 중 '바닥 사진'을 찍은 곳이 60% 미만이고 폰이 수평(20° 이상 숙이지 않음)인 채로 6초 | 폰을 30~45° 숙여 걸어온 길의 바닥을 찍기 |

예상 흔들림(px) = 화면 가운데 점이 움직이는 속도(회전 − 옆 이동 ÷ 가운데 거리, 가구를 바라보며 돌 때처럼 서로 상쇄되면 작아짐) × 셔터 시간(`ARCamera.exposureDuration`) × 초점거리(px).
5 px · 6 px 는 시작값입니다. 경고는 사진을 버리기(6 px) 직전에만 띄웁니다 — 3 px 부터 띄우면 AI 팀 new1(중앙값 3.7 px) 기준으로 거의 계속 떠 있게 됩니다. 촬영본 `poses.json` 의 `blurPx` 와 실제 흐림을 비교해 조정하세요.
정지를 눌렀을 때 이동 범위가 1 m 미만이면 "제자리에서만 찍었어요", 바닥을 찍은 곳이 60% 미만이면 "바닥이 덜 찍혔어요" 를 묻습니다(더 찍기 / 그대로 끝내기).
천장을 찍은 곳이 40% 미만이면(안내를 포기하지 않았다면) "천장이 덜 찍혔어요" 를 **촬영당 한 번만** 묻습니다.
천장은 선택 사항이라 위 표처럼 경고 띠 · 진동은 없고, 안내 문구와 막대의 "천장 n%" 로만 알립니다. 위를 20° 넘게 보는 동안에는 '무늬 없는 면' 경고도 띄우지 않습니다(천장은 대개 흰색).

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

**천장 판단 (LiDAR)** — 바닥과 같은 방식입니다. 저장한 프레임의 LiDAR 점 높이 히스토그램(바닥과 같은 것)에서
*카메라보다 0.4~3.5 m 위의, 점이 150개 이상 모인 가장 높은 높이*를 천장으로 잡고
(벽 점은 천장에서 끝나므로 맨 위가 천장이고, 옷장 · 선반 윗면은 천장보다 낮아 걸러짐 — 단 바로 아래 25 cm 안에 3배 넘게 큰 수평면이 있으면 그쪽),
점의 25% 이상이 천장(± 5 cm)이고 **폰을 위로 20° 이상 든** 프레임을 '천장 사진'으로 셉니다.
수평으로 든 프레임도 4×5 m 정도 방에서는 화면 위쪽에 먼 천장이 LiDAR 점의 25~30% 쯤 보이지만, 그건 맞은편 천장이지 걸어온 길 바로 위가 아니므로 세지 않습니다(그래서 위로 20° 이상 든 프레임만 셉니다).
천장 사진을 찍은 자리 ± 50 cm 가 '천장을 찍은 곳', 막대의 **천장 n%** = 걸어온 길(바닥과 같은 20 cm 칸) 중 천장을 찍은 곳의 비율입니다.
첫 바퀴가 끝난 뒤부터 보이고 40% 미만이면 주황입니다. 안내 문구는 바닥 단계(85% 이상) 다음, 가구 안내 앞에서
"이제 폰을 위로 30~45° 기울여 걸어온 길 위의 천장을 찍어 주세요 (천장 n%)" 로 바뀝니다(70% 미만일 때).
**같은 안내를 계속하지 않습니다.** 안내하는 동안 천장 비율이 40초 넘게 2%p 도 안 늘면(LiDAR 로 천장이 안 잡히는 어둡고 반들반들한 · 아주 높은 · 비스듬한 천장 등)
이번 촬영에서는 그 안내를 접고 막대 · 문구 · 정지 때의 질문에서 모두 빠집니다. 끝내는 것을 막지도 않습니다. 기준값은 `CaptureCoach.Config` 의 `ceiling…`.

**가구 전체 사진 (방 촬영 · LiDAR + RoomPlan)** — 가구마다 *전체가 한 화면에, 충분히 크게, 선명하게* 찍힌 사진이 한 장 이상 있게 안내하고, 되도록 여러 방향에서 모읍니다
(가구를 따로 3D 로 만들거나 재질을 다시 입힐 때 쓰는 대표 사진). 다른 가구나 사람에 **가려지거나 뒷면이 안 보이는 것은 어쩔 수 없다고 보고 통과 여부에 쓰지 않습니다**
(안 보이는 부분은 SAM 3D 가 메웁니다). 코드: `Features/Capture/FurnitureShots.swift`(`FurnitureShotConfig` 에 기준값).
- RoomPlan 이 스캔 중에 고쳐 주는 가구 상자(`RoomCaptureSessionDelegate.captureSession(_:didUpdate:)`)와 프레임마다의 카메라 포즈 · LiDAR 깊이(64×48 격자)로 10 Hz 마다 점검합니다.
- 통과 조건: ① 상자 꼭짓점 8개가 모두 화면 안(가장자리 2% 여유) ② 화면 가로나 세로의 30% 이상 ③ 예상 흔들림 6 px 이하.
  **가려짐은 통과 여부에 쓰지 않고 점수 · 기록용**입니다: 카메라 쪽 옆면 · 윗면에 면마다 5×5 점을 찍어 LiDAR 와 비교해 안 가려진 비율(`visible`)을 재고
  (상자 면보다 10 cm + 거리의 3% 넘게 앞에 무언가 있으면 가려진 점. 단 그것이 가구 자신 · 위에 놓인 물건(컵 · 책 · TV) · 바닥 · 이 가구에 붙은 더 작은 가구(식탁에 넣은 의자)면 치지 않음),
  덜 가려진 사진이 대표 사진으로 더 높은 점수를 받습니다. 가린 가구(`blockedBy`)도 사진마다 적습니다. 다만 5% 도 안 보이면(벽 너머 등) 본 것으로 치지 않습니다.
  깊이를 못 재면(5 m 밖 등) `visible` 은 비웁니다.
- 통과한 프레임이 **저장되면** 화면 위 목록의 그 가구가 초록 ✓ 로 바뀌고 '성공' 진동이 옵니다. 아직 전체 사진이 없는 가구가 지금 화면에서 통과하면 이동 · 회전이 적어도 그 프레임을 저장합니다.
  ✓ 가 된 뒤에도 지금까지 없던 새 방향(바라보는 방향이 30° 이상 다름)에서 통과하면 계속 저장해 가구마다 최대 8방향을 모읍니다(✓ 옆 "3방향" = 모은 방향 수).
  사진이 넘치면 비슷한 방향의 낮은 점수부터 버리므로, 점수가 낮아도 새 방향은 남습니다.
- 같은 종류 · 같은 크기(가로 · 깊이 · 높이 ±6 cm) 가구는 하나만 찍혀도 함께 ✓ (민트, 식탁 의자 6개 등). 식탁 밑에 넣은 의자는 식탁 반대쪽(의자가 바깥으로 나온 쪽)에서 보면 통과합니다.
- 첫 바퀴(12방향 + 2 m)를 마쳤거나 60초가 지나면 화면 아래 초록 띠로 아직 전체 사진이 없는 가구 하나를 안내합니다:
  화면에 걸려 있으면 이유(다 안 들어와요 → 한두 걸음 물러나기 · 너무 작게 보여요 → 가까이 · 흔들렸어요),
  화면 밖이면 가장 가까운 가구 쪽(왼쪽 · 오른쪽 · 뒤). 촬영 경고(빨강 · 주황)가 떠 있으면 경고가 먼저입니다. 안내 문구도 바닥 · 천장 다음 단계로 "가구 n개는 아직 전체 사진이 없어요" 를 보여 줍니다.
- **같은 가구를 계속 재촉하지 않습니다.** 한 가구를 화면에 걸린 채 20초(화면 밖이라 "돌아 보세요" 만 한 시간은 45초) 안내했는데도 못 찍으면 그 가구는 포기하고 다음 가구로 넘어갑니다.
  포기한 가구는 화면 아래 안내 · 힌트 · 정지 때의 "더 찍을까요?" 질문에서 빠지고(`furniture_shots.json` 에는 `missing` 으로 남음), 정지 때 이미 물어본 가구는 다시 묻지 않습니다.
  전체 사진은 있지만 방향이 3개 미만인 가구는 "충분히 촬영했습니다" 뒤에 "가구 n개는 다른 방향에서도 찍으면 더 좋아요" 만 덧붙이고, 끝내는 것을 막지 않습니다.
- RoomPlan 이 상자를 8 cm · 8° 넘게 고치거나 가구를 나중에 찾으면, 지금까지 저장한 프레임으로 다시 점검합니다. 정지를 누를 때 아직 없는 가구(포기하지 않은 것)가 있으면 "전체 사진이 없는 가구가 있어요" 를 한 번 묻습니다.
- 촬영을 마치면 RoomPlan **최종** 가구 상자로 저장한 프레임을 모두 다시 점검해 `furniture_shots.json` 을 씁니다(아래 형식).

**방이 좁아 다 안 들어올 때 (폰 돌리기 · 촬영 뒤 0.5× 광각)** — ARKit(LiDAR · RoomPlan)은 스캔 중 **1× 카메라 영상만** 앱에 줍니다.
world tracking 이 울트라 와이드를 내부에서 쓰지만 API 로 열어 주지 않고([Apple 포럼 답변](https://developer.apple.com/forums/thread/831657)),
스캔 중에 다른 카메라를 따로 열면 ARSession 이 끊겨 전체 촬영본의 포즈가 망가질 수 있습니다. 그래서 두 단계로 나눴습니다.
- 스캔 중: 1× 화각은 센서 긴 쪽(1920) 약 67° · 짧은 쪽(1440) 약 53° 입니다(K 의 fx≈1445 로 계산). 가구가 짧은 쪽으로만 넘치면 안내 띠가
  "폰을 가로로(또는 세로로) 돌려 찍으면 더 넓게 들어와요" 로 바뀝니다(세로로 든 폰에서 좌우 53° → 가로로 들면 67°, 같은 거리에서 폭이 4/3 배).
  그래도 같은 가구가 8초 넘게 다 안 들어오면 "촬영을 마칠 때 0.5× 광각으로 한 장 찍을 수 있어요" 를 안내합니다.
- 정지를 누를 때: 전체 사진이 없는 가구 중 '다 안 들어옴' 인 것이 있으면(안내를 포기한 가구 포함) 경고에 **끝내고 0.5× 광각으로 찍기** 버튼이 생깁니다.
  다른 가구에 가려진 것은 광각 대상이 아닙니다. 그 밖에 물을 것이 없으면 "방이 좁아 다 못 찍은 가구가 있어요" 로 한 번만 제안합니다.
  고르면 RoomPlan 최종 결과를 받고 ARSession 을 멈춘 뒤 0.5× 카메라(AVFoundation `builtInUltraWideCamera`)를 열어,
  그런 가구만 한 장씩 찍게 합니다(같은 모양 가구는 한 장, 건너뛰기 가능). 저장: `wide/NNN.jpg` + `wide_shots.json`.
- 0.5× 사진에는 **ARKit 포즈 · LiDAR 깊이가 없고, 메인 카메라와 같은 순간에 찍은 것도 아닙니다.** 서버에서 frames/ 와 특징점 매칭으로 위치를 찾거나(COLMAP `image_registrator` · hloc),
  단일 사진 3D(SAM 3D) 입력 · SAM 3 마스크(글자 프롬프트 = category)로 쓰세요. 왜곡 보정 · 화각 · extrinsic 은 `meta.json` 의 `cameras.ultraWide`(아래 `cameras` 설명),
  사진별 `K` 는 영상 프레임의 intrinsic matrix 를 사진 크기로 환산한 근사값입니다.

## 3. capture.zip 형식 (AI 팀원용)

```
capture/
  meta.json                 기기, 해상도, 좌표계 설명, frameCount, roomplan 여부, sampling(프레임 저장 규칙), surfaceCoverage(벽 · 바닥이 사진 3장 이상에 나온 비율), cameras(카메라 · 왜곡 · 화각 · 깊이와의 관계, 0.5× 를 찍었으면 초광각 항목 포함)
  poses.json                프레임별 카메라 포즈·내부 파라미터 (아래)
  capture_log.json          촬영 중에 생긴 일: 추적이 끊긴 구간(이유) · 흔들림 · 쓰기 대기로 건너뛴 폴링 수 · 발열 상태 · 초점 고정 · 깊이 출처 (아래)
  frames/000000.jpg …       1920×1440 JPEG, 센서 원래 방향(가로), 회전하지 않음 → K 가 그대로 맞음
  depth/000000.png …        (LiDAR) 256×192 16-bit PNG, 밀리미터, 0 = 무효. RGB 와 같은 방향 ← AI 가 쓰는 원본
  confidence/000000.png …   (LiDAR) 8-bit PNG, 0 low / 1 medium / 2 high ← 원본
  depth_vis/000000.jpg …    (LiDAR) 깊이 히트맵 (Turbo: 0.2 m 파랑 → 5 m 빨강, 검정 = 측정 없음) ← 사람이 보는 용도
  confidence_vis/000000.png (LiDAR) 신뢰도 색 (빨강 low · 노랑 medium · 초록 high) ← 사람이 보는 용도
  depth.json                (LiDAR) 파일 설명 + 프레임별 요약: 측정 비율, 최소·중앙·최대 거리(m), 신뢰도 비율, colorToDepthScale
  roomplan.json             (LiDAR+RoomPlan) Apple CapturedRoom 원본 JSON
  roomplan_structure.json   (LiDAR+RoomPlan) 우리 API 형식 roomGeometry/roomDimensions/objects — 구조 추출 정답·대체값
  roomplan.usdz             (LiDAR+RoomPlan) 파라메트릭 3D 모델
  furniture_shots.json      (LiDAR+RoomPlan) 가구별 '전체 사진' frameId(서로 다른 방향 최대 8장) + 그 사진 속 상자 위치(bbox) · 가려진 정도 (아래)
  wide/000.jpg …            (끝낼 때 0.5× 광각을 고른 경우) 0.5× 광각 가구 사진, 센서 원래 방향(가로) — 포즈 · 깊이 없음
  wide_shots.json           (위와 같음) 사진마다 objectId · 같은 모양 가구(alsoFor) · 찍은 이유 · 해상도 · 근사 K (카메라 정보는 meta.json 의 cameras.ultraWide)
```

`poses.json` 항목:
```json
{ "frameId": 12, "ts": 18234.51, "width": 1920, "height": 1440, "tracking": "normal", "depth": true,
  "K": { "fx": 1445.3, "fy": 1445.3, "cx": 959.1, "cy": 718.4 },
  "T_wc": [[r00, r01, r02, tx], [r10, r11, r12, ty], [r20, r21, r22, tz], [0, 0, 0, 1]],
  "exposureS": 0.008333, "blurPx": 1.7, "floorShare": 0.41, "ceilingShare": 0.0,
  "iso": 320, "focusLocked": true, "lensPosition": 0.71, "depthSource": "sceneDepth", "trackingNormalForS": 12.4, "torch": false }
```
`exposureS` 는 셔터 시간(초), `blurPx` 는 저장 순간의 예상 흔들림(px, JPG 해상도 기준), `floorShare` 는 그 프레임의 LiDAR 점 중 바닥인 비율입니다
(흐린 프레임 거르기 · 바닥 사진 고르기에 쓰세요, 예전 촬영본에는 없음). `meta.json` 에는 `floorHeightM`(LiDAR 로 찾은 바닥 높이, ARKit 월드 y),
`walkedFloorCoverage`(걸어온 길 중 바닥을 찍은 곳의 비율), `floorPhotos`(바닥 사진 수)가 들어갑니다.
천장도 같은 방식입니다(LiDAR 로 천장 높이를 찾았을 때만): `ceilingShare` = 그 프레임의 LiDAR 점 중 천장인 비율(흰 천장만 가득한 프레임은 특징점 매칭에 불리하니 걸러 쓸 수 있음),
`meta.json` 의 `ceilingHeightM`(천장 높이, ARKit 월드 y), `walkedCeilingCoverage`(걸어온 길 위의 천장을 찍은 곳의 비율), `ceilingPhotos`(폰을 위로 들고 천장이 25% 이상 찍힌 사진 수).
`ceilingHeightM − floorHeightM` 이 층고이니 RoomPlan 의 `ceilingHeight` 와 비교해 보세요.

2026-10-27 이후 촬영본의 `poses.json` 에는 `iso`(밝기를 올린 정도 — 높을수록 노이즈), `focusLocked` · `lensPosition`(초점이 고정됐는지와 렌즈 위치 — 고정됐으면 프레임마다 같고 K 도 거의 안 변함),
`depthSource`(`sceneDepth`, 또는 ARKit 이 여러 프레임을 평활한 `smoothedSceneDepth` — 섞여 있으면 하나만 골라 쓰세요), `trackingNormalForS`(이 프레임까지 추적이 정상으로 이어진 초 — 막 회복한 직후 프레임은 포즈가 튈 수 있음), `torch`(손전등을 켠 채 찍었는지)가 더 들어갑니다.
손떨림 보정(EIS)은 없습니다: 프레임은 ARKit `capturedImage` 그대로이고 ARKit 은 이 이미지를 프레임마다 잘라내거나 옮기지 않습니다.

`capture_log.json` (2026-10-27 이후 촬영본):
```json
{ "captureId": "…", "stabilization": "none: …", "startTs": 18200.1, "endTs": 18330.7, "polls": 1306,
  "skippedPolls": { "blurry": 210, "busy": 0 },
  "tracking": [ { "startTs": 18200.1, "endTs": 18201.3, "state": "limited", "reason": "initializing" },
                { "startTs": 18251.0, "endTs": 18252.4, "state": "limited", "reason": "excessiveMotion" } ],
  "thermal": [ { "ts": 18200.1, "state": "nominal" }, { "ts": 18310.2, "state": "fair" } ],
  "focus": { "lockEnabled": true, "lockedAtTs": 18202.2, "lensPosition": 0.71, "relocks": 0 },
  "depthSources": { "sceneDepth": 539 },
  "torch": { "autoEnabled": true, "events": [ { "ts": 18240.3, "on": true, "by": "auto", "trigger": "ISO 1250 · 셔터 0.0167초" } ] } }
```
시각(`…Ts`, `ts`)은 `poses.json` 의 `ts` 와 같은 ARKit 시계(초)라 프레임과 바로 맞춰 볼 수 있습니다. `skippedPolls` = 저장할 차례였는데 흔들림(`blurry`) · 쓰기 대기(`busy`)로 건너뛴 폴링 수(10 Hz 라 프레임 수의 약 2배),
`tracking` = 추적이 normal 이 아니었던 구간과 이유(처음 위치를 잡는 `initializing` 포함, `endTs` 가 없으면 끝까지 회복 못 함), `thermal` = 기기 발열 상태(`serious` 부터 iOS 가 성능을 낮춤),
`focus.relocks` = ARKit · RoomPlan 이 초점 고정을 풀어 다시 잠근 횟수, `focus.note` = 잠그지 못한 이유.
`torch.events` = 손전등을 켜고 끈 기록(`auto` 어두워서 · `user` 화면 버튼 · `relight` iOS 가 꺼서 다시 켬 · `end` 촬영 끝). 손전등을 켠 프레임(`poses.json` 의 `torch: true`)은 빛이 카메라와 함께 움직여 밝기 · 그림자가 프레임마다 다릅니다.

`meta.json` 의 `surfaceCoverage` (LiDAR + RoomPlan 촬영본, 2026-10-27 이후): `{ "walls": 0.91, "floor": 1.0, "overall": 0.92, "samples": 366, "blocked": 11, "minViews": 3 }` —
RoomPlan 벽(30 cm 간격) · 바닥(벽을 이어 만든 다각형 안, 40 cm 간격)에 찍은 점 중 저장한 사진 3장 이상에 (화면 안 · 너무 비스듬하지 않게 · LiDAR 로 보아 가려지지 않고) 나온 비율.
화면에 들어왔는데 3번 넘게 매번 앞에 무언가 있던 점(옷장 뒤 벽 등)은 `blocked` 로 빼고 셉니다. 촬영 중 "OO쪽 벽에 아직 덜 찍힌 곳이 있어요" 안내가 같은 계산을 씁니다(첫 바퀴 뒤부터, 전체 85% 가 넘으면 멈춤).
위 값은 10월 8일 촬영본으로 돌려 본 결과이고, 기준 3장은 AI 팀 분석(3장 미만으로 보인 점 비율 10%p 마다 약 −0.8 dB)입니다.

`furniture_shots.json` (가구마다 전체가 한 화면에 찍힌 프레임 — 다른 가구가 가린 정도는 기록만 하고 통과 여부엔 안 씀. objectId 는 `roomplan_structure.json` 과 같음):
```json
{ "version": 2, "frameCount": 153,
  "rule": { "minFill": 0.3, "maxBlurPx": 6, "marginFrac": 0.02, "minSeen": 0.05, "twinTolM": 0.06, "yawGapDeg": 30 },
  "objects": [
    { "objectId": "…", "category": "chair", "label": "의자 2", "status": "full",
      "shots": [ { "frameId": 37, "score": 0.91, "visible": 1.0, "fill": 0.5, "viewYawDeg": 45.0, "distanceM": 1.86,
                   "bbox": [612.4, 233.0, 1381.9, 1197.5] },
                 { "frameId": 81, "score": 0.57, "visible": 0.76, "blockedBy": "…", "fill": 0.42, "viewYawDeg": 180.0, "distanceM": 2.0,
                   "bbox": [ … ] }, … 서로 30° 이상 다른 방향 최대 8장 ] },
    { "objectId": "…", "category": "chair", "label": "의자 3", "status": "shared", "sharedWith": "…",
      "problem": "notWhole", "tuckedInto": "…", "shots": [ … 가장 나았던 1장 ] },
    { "objectId": "…", "category": "sofa", "label": "소파", "status": "missing", "problem": "notWhole", "shots": [ … ] } ] }
```
`status`: `full` = 전체 사진 있음(점수 순 · 바라보는 방향이 `rule.yawGapDeg`(30°) 이상 서로 다른 사진 최대 8장 — 방향이 많을수록 SAM 3D 에 넣을 뷰가 많음), `shared` = 같은 모양 가구(`sharedWith`)의 사진으로 대신, `missing` = 없음
(`problem`: notWhole 다 안 들어옴 · tooFar 작음 · blurry 흔들림 · notInView 안 찍힘 또는 거의 안 보임(`visible` < `rule.minSeen`), `shots` 에는 가장 나았던 1장). 다른 가구가 가린 것은 `problem` 이 아닙니다.
`bbox` 는 그 JPG 속 RoomPlan 상자 범위 `[u0, v0, u1, v1]`(px, 센서 원래 방향 = K 와 같은 좌표) → SAM 3 상자 프롬프트로 가구 마스크를 뽑는 데 쓰세요.
`visible` = 카메라 쪽 면 중 안 가려진 비율(없으면 LiDAR 로 못 잰 것), `blockedBy` = 그 사진에서 가장 많이 가린 다른 가구의 objectId(안 가렸거나 가구가 아닌 것 · 사람이 가리면 없음) — 마스크 신뢰도나 뷰 가중치를 정할 때 쓰세요.
`tuckedInto` = 부피의 15% 이상이 그 가구 상자 안(식탁 밑에 넣은 의자 → 식탁)이라 어느 방향에서도 일부는 안 보이는 가구.

`wide_shots.json` (촬영을 마친 뒤 0.5× 광각으로 찍은 가구 사진, 숫자는 예시):
```json
{ "version": 1, "camera": "builtInUltraWideCamera (0.5x) · AVFoundation · ARKit/RoomPlan 스캔을 마친 뒤",
  "shots": [ { "file": "wide/000.jpg", "objectId": "…", "alsoFor": ["…"], "category": "sofa", "label": "소파",
               "reason": "notWhole", "width": 4032, "height": 3024,
               "K": { "fx": 1580.2, "fy": 1580.2, "cx": 2016.0, "cy": 1512.0 }, "takenAt": "2026-10-08T08:12:31Z" } ] }
```
`objectId` · `alsoFor` 는 `furniture_shots.json` · `roomplan_structure.json` 과 같은 id 입니다(같은 모양 가구는 이 사진 한 장을 함께 씀).

`meta.json` 의 `cameras` (어느 카메라로 어떻게 찍었는지 — 사진을 맞추고 왜곡을 펼 때 쓰세요. `main` = 스캔 중 ARKit 1× 프레임, `ultraWide` = 끝낸 뒤 찍은 0.5× 사진, 찍은 경우에만):
```json
{ "cameras": {
    "main": { "camera": "메인 광각(1×) — ARKit capturedImage (frames/)", "api": "ARKit", "imageSize": [1920, 1440],
              "intrinsics": "poses.json 의 K — 프레임마다 (fx, fy, cx, cy), imageSize 기준",
              "fxMedian": 1445.3, "fovDeg": { "horizontalDeg": 67.2, "verticalDeg": 53.0 },
              "distortion": { "model": "pinhole", "note": "ARKit 은 왜곡 계수를 주지 않는다 …" },
              "depth": { "source": "LiDAR (ARKit sceneDepth)", "imageSize": [256, 192], "colorToDepthScale": [0.1333, 0.1333], "note": "…" } },
    "ultraWide": { "camera": "초광각(0.5×) — builtInUltraWideCamera", "deviceType": "AVCaptureDeviceTypeBuiltInUltraWideCamera", "imageSize": [4032, 3024],
                   "geometricDistortionCorrection": { "supported": true, "enabled": true },
                   "distortion": { "model": "pinhole", "note": "Apple 의 왜곡 보정(GDC)이 켜진 사진이라 핀홀로 간주한다 …" },
                   "fovDeg": { "horizontalFromK": …, "verticalFromK": …, "horizontalGdcCorrected": …, "horizontalUncorrected": … },
                   "extrinsicToMain": { "from": "ultraWide", "to": "main", "R": [[…], […], […]], "t_mm": [ … ], "formula": "X_main = R · X_ultraWide + t …" },
                   "depth": "없음 …", "pose": "없음 …" } } }
```
- **프레임별 intrinsic**: `main` 은 `poses.json` 의 `K`, `ultraWide` 는 `wide_shots.json` 의 사진별 `K`(사진 해상도 기준)입니다.
- **왜곡**: ARKit 은 왜곡 계수를 주지 않아 `main` 은 K 만 있는 핀홀로 취급했습니다. `ultraWide` 는 Apple 의 왜곡 보정(GDC)을 켠 채 찍습니다(지원 기기의 기본값이고 코드에서도 켬 — 실제로 켜졌는지는
  `geometricDistortionCorrection.enabled`). 이 방식에서는 Apple 이 보정표(`lensDistortionLookupTable`)를 주지 않습니다 — Apple 문서상 GDC 를 끄고 가상 장치(트리플 카메라)의 구성 사진 모드로 찍어야 제공됩니다.
  보정 뒤 남은 왜곡은 **재지 않았으니**, 시험 촬영에서 직선(문틀 · 타일)이 펴졌는지 확인해 주세요. 펴지지 않았다면 GDC 를 끄고 보정표를 받는 촬영 방식을 추가할 수 있습니다.
- **화각 · 크기 · 깊이**: `fovDeg` 에는 K 로 계산한 화각(`…FromK`)과 Apple 이 알려 준 화각(GDC 뒤 `horizontalGdcCorrected` · 전 `horizontalUncorrected`)을 함께 적었습니다.
  K 가 보정 뒤 사진 기준이면 `horizontalFromK` ≈ `horizontalGdcCorrected` 입니다(`horizontalUncorrected` 에 가까우면 K 가 보정 전 기준). 깊이는 `main` 에만 있고 컬러와 같은 4:3 화각 전체를 덮습니다
  (깊이 K = 컬러 K × `colorToDepthScale`). 0.5× 사진에는 깊이가 없습니다.
- **extrinsic**: `extrinsicToMain` 은 두 렌즈 사이의 공장 보정 위치 관계입니다(`AVCaptureDevice.extrinsicMatrix(from:to:)`, 이동은 mm). 0.5× 사진은 ARKit 프레임과 같은 순간에 찍지 않아
  이 값만으로 사진의 월드 포즈는 구할 수 없고, 카메라 축 방향 규약은 Apple 문서에 없습니다. 기기가 값을 주지 않으면 이 키가 없습니다.

- **좌표계**: ARKit 월드 = **미터**, Y-up, 오른손. `T_wc` 는 camera→world, row-major, `ARCamera.transform` 그대로.
- **카메라 축**: x 오른쪽, y 위, −z 정면 = OpenGL / nerfstudio `transforms.json` 규약. (COLMAP/OpenCV 는 y·z 부호 반대)
- 모든 결과물(3DGS PLY, collision.glb, roomGeometry, objects)을 **이 미터 좌표계 그대로** 내보내 주세요. 그러면 앱에서 추가 변환 없이 겹칩니다.
- 프레임은 **초당 최대 약 5장** 저장됩니다(10 Hz 로 확인, 저장 간격 0.18초 이상). 조건: 추적 상태 normal, 예상 흔들림 6 px 미만, 직전에 저장한 프레임에서 2 cm 이상 이동 또는 2° 이상 회전(가구 촬영은 1 cm) — 가만히 서 있으면 같은 사진을 쌓지 않습니다. 이 규칙은 `meta.json` 의 `sampling`(`pollHz` · `minIntervalS` · `minMoveM` · `minTurnDeg` · `maxBlurPx` · `jpegQuality`)에 적힙니다. 2026-10-25 이전 촬영본은 15 cm / 10° / 0.3초 / 10 px 규칙이고 이 키가 없습니다.

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

**투명 유리(유리창 · 유리벽 · 유리문)** 가 있는 방은 LiDAR 가 유리를 통과해 옆방 · 복도까지 찍혀서, 그 깊이로 만든 메시 · 점군에 벽 밖 덩어리가
붙고 유리 자리는 구멍이 납니다. `python3 tools/capture/glass_tools.py <capture 폴더 또는 zip>` 은 RoomPlan 벽을 기준으로 벽 밖으로 나간 LiDAR 점을 찾아
창 · 문 · 벽마다 유리인지 판단하고(`glass.json`) 다음을 만듭니다(RoomPlan 결과가 있는 LiDAR 방 촬영본만):
**`glass.glb`** — 유리로 판단한 자리마다 크기 · 위치 · 방향을 맞춘 유리 3D 물체(두께 1 cm 상자, 유리 하나 = 노드 하나). ARKit 월드 좌표라 메시 · 3DGS 와
같은 자리에 겹치고 three.js `GLTFLoader` 로 그대로 불러옵니다. 재질은 블록아웃 뷰의 유리처럼 반투명 하늘색(`#cfe7ff`, 알파 0.35)이고,
`glass.json` 의 `objects` 는 SpaceResponse.objects 와 같은 형식(category `"glass"`, position = 중심, rotation.yaw, dimensions)입니다.
**`depth_clean/`**(depth/ 와 같은 형식, 벽 밖 픽셀만 0 — TSDF 등 메시 입력으로 이걸 쓰세요) · `points_clean.ply`, 같은 유리 상자의 OBJ/PLY(`glass_panes.obj/.mtl/.ply`),
프레임별 마스크 `glass_mask/`(흰색 = 유리 · 열린 문 너머가 보이는 픽셀 → 텍스처 · 3DGS 학습에서 뺄 곳).
이미 만든 메시는 `--mesh mesh.ply`(또는 `.obj`)로 주면 꼭짓점이 모두 방 밖인 면을 지운 `mesh_room.ply` 를 옆에 만듭니다(OBJ 는 유리 상자까지 붙임).
메시는 원점 이동 · 축 변환 없이 촬영 좌표계(ARKit 월드, m) 그대로여야 합니다. 열린 문 · 통로는 유리 물체 없이 벽 밖 점만 지우고, 거울도 같은 방식으로 '거울 속 방' 이 지워집니다.
서버가 `glass.json` 의 `objects` 를 공간 응답의 **`glass`** 로 넘기면(아래 4장 SpaceResponse) 앱 뷰어가 그 자리에 반투명 유리를 그리고, 같은 자리의 RoomPlan 창 · 문 상자 대신
실제 유리 크기로 보여 줍니다. `objects` 에 category `"glass"` 로 섞여 와도 앱이 유리로 옮겨서 가구 목록 · 가구 구분에는 나오지 않습니다. 데모 데이터(seed 3)는 창마다 유리가 있습니다.

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
                 "removable": true } ],                                          // false = 고정 설비(싱크대 등). 없으면 종류로 판단
  "glass": [ { "objectId": "glass-1", "glassKind": "window",                    // 선택: 서버가 LiDAR 로 찾은 투명 유리 (glass.json 의 objects 그대로)
               "position": {x,y,z}, "rotation": {"yaw": 1.0},                    // glassKind: window | door | wall | gap, position = 중심
               "dimensions": {"width": 2.55, "height": 1.57, "depth": 0.01} } ] } // 뷰어가 반투명 유리로 그림. 가구 목록 · 가구 구분 · 충돌엔 안 들어감

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
- 조작: 1인칭 = 한 손가락 둘러보기, 두 손가락 끌기 = 이동 · 오므리기 = 넓게(화각 30–100°, 가장 넓으면 뒤로 물러남) · 벌리기 = 가깝게 / 평면뷰 = 위에서 내려다보며 시작, 한 손가락 회전·기울이기, 핀치 줌, 두 손가락 이동 / 가구 = **눌러서 고른 뒤** 끌어서 옮기기(고르지 않은 가구 위에서는 카메라 조작이라 가구가 많아도 줌 · 둘러보기가 됨), 카드의 ⟲⟳ 로 15° 회전. 초기화(↺) = 처음 시점 · 화각, 가구를 추가하면 자동으로 평면뷰.
- 평면뷰는 카메라 near plane 을 천장 너머로 밀어 천장을 걷어낸 것처럼 보입니다(스플랫·포인트·메시 공통 트릭).
- **JS 디버깅**: 폰을 Mac 에 연결 → Mac Safari › 개발자 › (폰 이름) › Dulleobang Viewer. 콘솔·네트워크를 볼 수 있습니다.

## 6. 테스트

Xcode › Product › Test (시뮬레이터 가능). 충돌 판정 13개 시나리오(벽 접촉 허용, 3 cm 침범 = overlap 0.03, 문 앞 차단,
창틀 높이, 개인 가구 제외·임대 옵션 충돌, 회전 벽, 다른 가구, 자동 배치, 비교), 프레임 선별, JSON 디코딩, URI 해석,
응답 호환(숫자 ID · 봉투 · Spring Page · StayView 필드명 · 채팅 content 필드), 가격/층/면적/주소 표기, 검색어 해석,
데모 모드(번들 시드가 모델로 디코딩되는지, 목록·필터·상세·공간·입주 상태·관심 매물·채팅·자동 답장·매물 등록·중개사 신청 흐름).
앱 화면: 카드 문구(평 · 동 · 관리비), ‘3D로 보기’ 필터, 채팅 날짜 구분선 · 보낸 시각, 매물 등록 단계별 필수 칸.
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
