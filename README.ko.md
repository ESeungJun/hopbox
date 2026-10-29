<p align="center"><img src="docs/images/icon.png" width="120" alt="HOPBOX"></p>

<h1 align="center">HOPBOX · 택배상자</h1>

<p align="center">맥의 전체화면 데스크톱 사이를 깡충깡충 오가는 작은 택배상자.<br>
한 화면에서 파일·글·이미지를 담고, 다른 화면에서 단축키를 누르면 거기 그대로 있습니다.</p>

<p align="center"><a href="README.md">English</a> · <b>한국어</b></p>

<p align="center"><img src="docs/images/hero.png" width="560" alt="HOPBOX: 상자를 열면 파일과 메모, 스크린샷이 부채꼴로 펼쳐진 모습"></p>

---

저는 전체화면 앱을 여러 데스크톱에 띄워 놓고 일합니다.
그런데 다른 화면의 파일을 첨부하거나 내용을 옮기려고 끌면, 마우스가 화면 끝에 막혀서 드래그가 끊겨 버립니다.
결국 전체화면을 풀고 창을 늘어놓고 할 일을 한 다음, 다시 전체화면으로 돌아가곤 했습니다.

HOPBOX 는 지금 보고 있는 화면으로 불러올 수 있는 상자입니다.
담고, 화면을 옮기고, 다시 불러서 꺼내면 됩니다.

## 쓰는 법

1. 어디서든 **⇧⌘F** 를 누릅니다. 전체화면 앱 위에서도 마우스 옆으로 택배가 툭 떨어집니다.
2. 파일을 상자에 **끌어다 놓거나**, 복사한 것(글·이미지·파일)을 **⌘V** 로 담습니다.
3. 다른 데스크톱으로 가서 **⇧⌘F** 를 다시 누르면 같은 상자가 그 화면으로 배달됩니다.
4. 상자를 누르면 Dock 스택처럼 부채꼴로 펼쳐집니다.
   항목을 **끌어서** 첨부하거나, **눌러서** 복사합니다.

## 기능

- **택배 받는 느낌** — 상자가 위에서 떨어져 납작하게 내려앉으며 먼지가 일고, 담긴 게 있으면 저절로 열립니다.
  무언가를 끌고 오면 상자가 들썩이고, 넣으면 통통 튀며 "+1" 이 떠오릅니다.
- **전체화면을 방해하지 않음** — 전체화면 앱 위에 떠도 포커스를 뺏거나 화면을 빠져나가게 하지 않습니다.
- **안전하게 꺼내기** — 끌어낼 때는 늘 복사로 나갑니다. Finder 로 끌어도 원본 파일이 옮겨지지 않습니다.
- **부채꼴, 그다음 목록** — 열 개까지는 부채꼴로 펼치고, "그 외 N개" 를 누르면 전체 목록이 열립니다. 목록에서는 한꺼번에 끌어낼 수 있습니다.
- **스크린샷 자동 담기** — 새로 찍은 스크린샷과 화면 기록을 바로 담습니다. macOS 에서 정한 저장 위치를 따라갑니다.
- **복사한 이미지 자동 담기** — Slack·브라우저에서 복사한 이미지와 클립보드 스크린샷(⌃⇧⌘4)도 담습니다.
  Finder 에서 복사한 파일, 스프레드시트 셀, 비밀번호 관리자의 값은 담지 않습니다.
- **되돌리기** — 빼거나 비운 것은 5초 동안 되돌릴 수 있습니다.
- **기억하기** — 앱을 다시 켜도 담긴 것이 남아 있습니다. 파일은 복사하지 않고 원본을 가리킵니다.

자동 담기 두 가지, 로그인 시 실행, 단축키는 메뉴 막대 아이콘에서 바꿀 수 있습니다.

## 설치

소스에서 빌드합니다. Xcode 없이 Command Line Tools(`xcode-select --install`)만 있으면 됩니다.

```bash
git clone https://github.com/ESeungJun/hopbox.git
cd hopbox
./build.sh install      # 택배상자.app 을 만들어 ~/Applications 에 설치하고 실행
```

macOS 13 이상. 임시 서명 앱이라 처음 열 때 확인 창이 뜰 수 있습니다(우클릭 → 열기).
따로 허용할 권한은 없습니다. 전역 단축키도 손쉬운 사용 권한 없이 동작합니다.

## 만든 재료

- **Swift · SwiftUI · AppKit** — 전체화면 데스크톱 위에 뜰 수 있는, 포커스를 뺏지 않는 패널을 쓴 메뉴 막대 앱
- **Carbon 단축키** — 추가 권한 없는 전역 단축키
- **QuickLook 미리보기** — Finder 처럼 내용이 보이는 미리보기

Claude Code 와 함께 만들었습니다.

## 개발

```bash
swift build             # 디버그 빌드
./build.sh              # build/택배상자.app
./build.sh install      # ~/Applications 에 설치하고 실행
```

<details>
<summary>프로젝트 구조</summary>

| 경로 | 역할 |
|---|---|
| `Sources/Hopbox/AppDelegate.swift` | 메뉴 막대, 전역 단축키, 설정 |
| `Sources/Hopbox/ShelfPanel.swift` | 떠 있는 패널: 배달 연출, 열기·닫기, 키보드, 드롭 받기 |
| `Sources/Hopbox/BoxLayout.swift` | 상태별 창 크기와 아이콘 자리 (상자가 튀지 않게) |
| `Sources/Hopbox/BoxView.swift` | 상자 아이콘과 애니메이션, 알림 |
| `Sources/Hopbox/FanView.swift` | Dock 스택식 부채꼴 |
| `Sources/Hopbox/ShelfView.swift` | 전체 목록 |
| `Sources/Hopbox/ShelfStore.swift` | 상자 내용: 담기·복사·되돌리기 가능한 빼기·저장 |
| `Sources/Hopbox/ScreenCaptureWatcher.swift` | 스크린샷·화면 기록·복사한 이미지 자동 담기 |
| `Sources/Hopbox/Shortcut.swift` | 단축키: 저장값, 표시 이름, 바꾸기 창 |
| `Sources/Hopbox/DragSource.swift` | 복사로만 끌어내기, 클릭과 끌기 구분 |
| `Sources/Hopbox/Thumbnails.swift` | QuickLook 미리보기 |

담긴 내용은 `~/Library/Application Support/Hopbox` 에 저장됩니다.

</details>
