# GhosttyTerminal

[English](README.md) · 한국어

맥 앱에 `NSView` 하나로 넣는 터미널입니다. Ghostty의 엔진인 [libghostty](https://github.com/ghostty-org/ghostty)가 앱 프로세스 안에서 Metal로 그리고, PTY와 자식 프로세스도 이 뷰가 쥡니다. [Fine](https://github.com/oesoll/Fine)과 SpaceManager의 터미널이 이것입니다.

Ghostty 공식 프로젝트는 아닙니다.

## 왜 만들었나

맥 앱에 터미널을 넣는 흔한 방법은 `WKWebView` 안의 xterm.js인데, 웹뷰마다 WebKit 프로세스가 하나씩 뜹니다. Fine에서 둘을 나란히 재 보니 탭 여섯 개가 웹뷰로는 프로세스 아홉 개에 690MB, 이 패키지로는 한 프로세스에 106MB였습니다. 6.6MB 출력은 0.12초에서 0.04초로, 새 탭의 첫 화면은 158ms에서 59ms로 줄었습니다.

libghostty를 그대로 쓸 때보다 더 들어 있는 것:

- Ghostty macOS 앱의 키 입력·입력기 처리를 옮겨 와 한글·일본어·중국어 조합이 됩니다. 확정한 글자를 프로그램이 받아 그릴 때까지 잡아 두는 엔진 패치로, 음절이나 띄어쓰기마다 깜빡이지 않습니다.
- ⌘-클릭 링크는 Ghostty의 안전 정책을 거칩니다. 웹·메일 링크는 바로 열고, 다른 스킴은 먼저 묻고, 실행 파일은 막습니다.
- 파일을 끌어다 놓으면 셸에 맞게 이스케이프한 경로가 들어갑니다. 오른쪽 클릭 메뉴, VoiceOver, ⌘= ⌘- ⌘0 글꼴 크기.
- 바이트를 그대로 쓰는 `write(_:)`, 화면을 읽는 `readText(lastLines:)`, 벨·데스크톱 알림(OSC 9/777)·진행률(OSC 9;4) 콜백.
- `terminate(reapingAfter:)`: 표면을 닫으면 SIGHUP이 한 번 갈 뿐이라, 그걸 무시하는 프로그램(Claude Code)은 창이 닫힌 뒤에도 남습니다. 유예 뒤 정리합니다.

## 설치

Apple Silicon, macOS 14 이상.

```swift
.package(url: "https://github.com/oesoll/GhosttyTerminal.git", from: "0.1.0")
// 타깃 의존성:
.product(name: "GhosttyTerminal", package: "GhosttyTerminal")
```

SwiftPM이 이 저장소 릴리스에서 미리 빌드한 엔진(35MB)을 받습니다. zig는 없어도 됩니다.

## 엔진을 직접 빌드하려면

```sh
brew install zig   # 0.17
sh scripts/build-ghostty.sh
```

Ghostty 커밋 `ae0dc1b`를 `~/.cache/sm-ghostty`에 받아 `scripts/ghostty-patches/`의 패치 넷(조용한 `login`, 포커스 없는 패널의 커서 숨김, 두 칸 글자 가운데 정렬, 그리고 입력기가 확정한 글자를 프로그램이 받아 그릴 때까지 화면에 잡아 두기 — 한글을 칠 때 음절이나 띄어쓰기마다 깜빡이지 않게)을 얹고 `Frameworks/GhosttyKit.xcframework`를 만듭니다. 이 폴더가 있으면 패키지는 내려받은 것 대신 이것을 씁니다.

## 라이선스

MIT. Ghostty macOS 앱에서 옮긴 코드는 소스에 표시했고 [LICENSE-ghostty](Sources/GhosttyTerminal/LICENSE-ghostty)를 따릅니다. 미리 빌드한 엔진에 든 라이브러리와 글꼴의 라이선스는 [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md)에 있습니다. GNU libintl(LGPL-2.1 이상)도 들어 있는데, 엔진이 정적 아카이브라 바꿔서 다시 링크할 수 있습니다.
