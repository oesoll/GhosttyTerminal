# GhosttyTerminal

English · [한국어](README.ko.md)

A terminal you can drop into a macOS app as one `NSView`. It is [libghostty](https://github.com/ghostty-org/ghostty) — Ghostty's engine — drawing with Metal inside your process, with the PTY and the child process owned by the view. It is the terminal in [Fine](https://github.com/oesoll/Fine) and SpaceManager.

This is not an official Ghostty project.

## Why

The usual way to put a terminal in a Mac app is xterm.js in a `WKWebView`, and every web view starts its own WebKit process. Fine measured both side by side: six tabs took 690 MB across nine processes with the web view and 106 MB in one process with this package; 6.6 MB of output rendered in 0.04 s instead of 0.12 s; a new tab showed its first output in 59 ms instead of 158 ms.

What you get beyond raw libghostty:

- Keyboard and IME handling taken from Ghostty's own macOS view, so Korean, Japanese and Chinese composition work, plus an engine patch that keeps committed text on screen until the program echoes it — no flicker at each syllable or space.
- Command-click links, opened through Ghostty's safety policy: web and mail links open, other schemes ask first, executable files are refused.
- Dropped files paste as shell-escaped paths, a right-click menu, VoiceOver support, ⌘= / ⌘- / ⌘0 font size.
- `write(_:)` for raw bytes, `readText(lastLines:)` for the screen, callbacks for the bell, desktop notifications (OSC 9/777) and progress (OSC 9;4).
- `terminate(reapingAfter:)`: closing a surface sends SIGHUP once, and programs that ignore it (Claude Code does) would otherwise outlive the window.
- `GhosttySessionStage` for terminals that show a session living elsewhere (a multiplexer, an agent host): it keeps the last frame under a dim veil while the session rests, lets the new surface draw hidden underneath while it wakes (a slow light circles the edges), and fades the frame away once the new screen settles — keys typed meanwhile are held and delivered in order. `endProcess()` ends a surface's child but keeps its last screen.

## Install

Apple Silicon, macOS 14 or later.

```swift
.package(url: "https://github.com/oesoll/GhosttyTerminal.git", from: "0.2.0")
// target dependency:
.product(name: "GhosttyTerminal", package: "GhosttyTerminal")
```

SwiftPM downloads the prebuilt engine (35 MB) from this repository's release; you do not need Zig.

## Use

```swift
import GhosttyTerminal

let theme = GhosttyTheme(colors: ["background": "#1e1e1e", "foreground": "#e4e4e6"], minimumContrast: 4.5)
let terminal = GhosttyTerminalView(
    launch: .init(command: "/bin/zsh -l", workingDirectory: NSHomeDirectory()),
    theme: theme,
    startWhenSized: true   // start the child once the view knows its real size
)
window.contentView?.addSubview(terminal)
terminal.onExit = { code in print("exited", code) }
```

Colours use xterm.js names (`background`, `foreground`, `cursor`, `selectionBackground`, `black` … `brightWhite`); a transparent background (`rgba(0, 0, 0, 0)`) becomes Ghostty's `background-opacity`. The font is Menlo 13 with the system fallback for CJK; the package does not read the user's Ghostty config.

## Building the engine yourself

```sh
brew install zig   # 0.17
sh scripts/build-ghostty.sh
```

This clones Ghostty at commit `ae0dc1b` into `~/.cache/sm-ghostty`, applies the four patches in `scripts/ghostty-patches/` (quiet `login`, no cursor in unfocused panes, two-cell glyphs centred, and a committed input-method text held on screen until the program echoes it, so Korean does not flicker at each syllable or space) and writes `Frameworks/GhosttyKit.xcframework`. When that folder exists the package uses it instead of the download.

## Licence

MIT. Code adapted from Ghostty's macOS app is marked in the source and covered by [LICENSE-ghostty](Sources/GhosttyTerminal/LICENSE-ghostty). The prebuilt engine contains third-party libraries and fonts listed with their licences in [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md), including GNU libintl (LGPL-2.1-or-later), which you can replace and relink because the engine ships as a static archive.
