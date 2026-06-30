# PerfMon Overlay v1.1

항상 위 표시되는 반투명 시스템 모니터 (Windows 10 / 11 전용 빌드)

## 기능
- CPU 사용률 + 온도
- 메모리 사용률 + 사용량(GB)
- 디스크 Read / Write 두 개 라인
- 네트워크 Download / Upload 두 개 라인
- 배경 투명도 슬라이더 (우클릭)
- 창 위치 / 크기 자동 저장
- Windows 시작 시 자동 실행

---

## 빌드 방법 (Windows에서)

### 요구사항
- Node.js 18+ (https://nodejs.org)

### 빌드

```bat
cd perfmon
npm install
npm run build
```

→ `dist/PerfMon Overlay Setup.exe` 생성됨 (Windows 10/11 x64)

---

## 개발 모드 실행

```bat
npm install
npm start
```

---

## 조작

| 동작            | 방법                        |
|-----------------|-----------------------------|
| 창 이동         | 아무 곳이나 드래그          |
| 창 크기 변경    | 모서리 드래그               |
| 투명도 조절     | 우클릭 → 슬라이더           |
| 항상 위 ON/OFF  | 우클릭 메뉴                 |
| 패널 숨기기     | 우클릭 → 각 패널 토글       |
| 트레이 메뉴     | 시스템 트레이 아이콘 우클릭 |
| 종료            | 트레이 → 완전 종료          |

---

## 시작프로그램 등록
빌드된 exe를 설치하면 자동으로 레지스트리에 등록됩니다.
수동 해제: 트레이 우클릭 → 시작프로그램 → 자동 시작 OFF

---

## 파일 구조

```
perfmon/
├── package.json
├── src/
│   ├── main.js       ← Electron 메인 (OS 데이터, 트레이, 위치 저장)
│   ├── preload.js    ← IPC 브리지
│   └── index.html    ← UI + 그래프
└── assets/
    └── icon.ico      ← (선택) 교체 가능
```

---

## 그래프 색상 변경

`src/index.html` 상단:

```js
// CPU: #00c3ff (파랑)
// Mem: #a855f7 (보라)
// Disk Read: #f97316 / Write: #fb923c (주황 계열)
// Net Down: #22c55e / Up: #4ade80 (초록 계열)
```

## 초기 창 크기 변경

`src/main.js`:
```js
const size = Store.size || { w: 78, h: 200 };
```
