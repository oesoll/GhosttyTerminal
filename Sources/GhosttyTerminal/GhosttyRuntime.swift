// Parts adapted from Ghostty (MIT, Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors).
// See LICENSE-ghostty in this folder.
import AppKit
import GhosttyKit

/// libghostty 앱 하나. 모든 창의 터미널 표면이 함께 쓴다.
///
/// 터미널을 웹뷰(xterm.js)가 아니라 libghostty가 그린다. 웹뷰는 터미널마다 WebKit 프로세스를 하나씩
/// 띄웠다(패널 4개면 4개, 각 수십 MB, 10/31 측정). libghostty는 앱 프로세스 안에서 Metal로 그리고,
/// PTY와 자식 프로세스도 표면이 직접 쥔다.
///
/// 설정은 사용자의 Ghostty 설정 파일을 읽지 않고 앱이 준 테마에서 만든다 — 앱 터미널의 색·글꼴은
/// 앱이 정한 값이어야 하고, Ghostty.app을 따로 쓰는 설정이 새어 들어오면 안 된다.
/// 이 파일과 GhosttyTerminalView의 입력 처리는 Ghostty macOS 앱(MIT, ghostty-org/ghostty)의
/// Ghostty.App.swift·SurfaceView_AppKit.swift를 필요한 만큼 옮긴 것이다.
public final class GhosttyRuntime {
    public static let shared = GhosttyRuntime()

    private(set) var app: ghostty_app_t?
    private var configs: [String: ghostty_config_t] = [:]

    private init() {
        // 에이전트 셸에서 앱을 다시 띄우면 그 셸의 NO_COLOR=1이 모든 터미널로 샌다(Codex가 색을 끈다).
        // ghostty_init이 지금의 환경을 잡아 두므로 그 전에 지운다.
        unsetenv("NO_COLOR")
        guard ghostty_init(0, CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else { return }
        guard let config = config(for: .fallback) else { return }

        var runtime = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: { _ in
                // 아무 스레드에서나 불린다. 앱 틱은 메인에서.
                DispatchQueue.main.async { GhosttyRuntime.shared.tick() }
            },
            action_cb: { _, target, action in
                GhosttyRuntime.perform(action, on: target)
            },
            read_clipboard_cb: { userdata, location, state, mimes, count, _ in
                GhosttyRuntime.readClipboard(userdata, location: location, state: state, mimes: mimes, count: count)
            },
            confirm_read_clipboard_cb: { userdata, _, state, _ in
                // 터미널 안의 프로그램이 맥 클립보드를 읽겠다는 요청(OSC 52 읽기)은 받지 않는다.
                guard let view = GhosttyTerminalView.from(userdata), let surface = view.surface else { return }
                ghostty_surface_deny_clipboard_request(surface, state)
            },
            write_clipboard_cb: { _, location, content, count, _ in
                GhosttyRuntime.writeClipboard(location: location, content: content, count: count)
            },
            close_surface_cb: { userdata, _ in
                DispatchQueue.main.async { GhosttyTerminalView.from(userdata)?.surfaceDidClose() }
            }
        )
        app = ghostty_app_new(&runtime, config)
    }

    /// libghostty를 쓸 수 있는가(초기화나 앱 생성이 실패하면 false).
    public var isAvailable: Bool { app != nil }

    private func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    /// 테마마다 설정 하나. 표면은 만들 때와 외형이 바뀔 때 이것을 받는다.
    func config(for theme: GhosttyTheme) -> ghostty_config_t? {
        let text = GhosttyConfigText.make(theme: theme)
        if let existing = configs[text] { return existing }
        guard let config = ghostty_config_new() else { return nil }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty-terminal-\(getpid())-\(configs.count).conf")
        do {
            try text.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            ghostty_config_free(config)
            return nil
        }
        ghostty_config_load_file(config, file.path)
        ghostty_config_finalize(config)
        try? FileManager.default.removeItem(at: file)
        configs[text] = config
        return config
    }

    // MARK: - Actions

    /// libghostty가 앱에 맡기는 일. 처리하지 않은 것은 false를 돌려 기본 동작에 맡긴다.
    private static func perform(_ action: ghostty_action_s, on target: ghostty_target_s) -> Bool {
        guard target.tag == GHOSTTY_TARGET_SURFACE,
              let surface = target.target.surface,
              let view = GhosttyTerminalView.from(ghostty_surface_userdata(surface)) else { return false }
        switch action.tag {
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            // 처리했다고 답하면 libghostty가 터미널에 "Process exited" 문구를 쓰지 않는다 —
            // 재연결하는 동안 끊기기 전 마지막 화면이 그대로 남는다.
            let code = action.action.child_exited.exit_code
            DispatchQueue.main.async { view.childDidExit(code: Int32(bitPattern: code)) }
            return true
        case GHOSTTY_ACTION_SET_TITLE:
            if let title = action.action.set_title.title.map({ String(cString: $0) }) {
                DispatchQueue.main.async { view.onTitle?(title) }
            }
            return true
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            DispatchQueue.main.async { view.setMouseShape(action.action.mouse_shape) }
            return true
        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            return true
        case GHOSTTY_ACTION_CELL_SIZE:
            let size = action.action.cell_size
            DispatchQueue.main.async { view.cellSizeDidChange(width: Double(size.width), height: Double(size.height)) }
            return true
        case GHOSTTY_ACTION_RENDER:
            DispatchQueue.main.async { view.didRender() }
            return true
        case GHOSTTY_ACTION_OPEN_URL:
            // ⌘-클릭한 링크. 터미널 출력이 만든 값이라 안전 정책을 거친다(GhosttyLinkOpener).
            let link = action.action.open_url
            guard let pointer = link.url else { return true }
            let value = String(decoding: UnsafeRawBufferPointer(start: pointer, count: Int(link.len)), as: UTF8.self)
            let kind = link.kind
            DispatchQueue.main.async { GhosttyLinkOpener.handle(value, kind: kind) }
            return true
        case GHOSTTY_ACTION_RING_BELL:
            DispatchQueue.main.async { view.ringBell() }
            return true
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            let note = action.action.desktop_notification
            let title = note.title.map { String(cString: $0) } ?? ""
            let body = note.body.map { String(cString: $0) } ?? ""
            DispatchQueue.main.async { view.onNotification?(title, body) }
            return true
        case GHOSTTY_ACTION_PROGRESS_REPORT:
            let report = action.action.progress_report
            DispatchQueue.main.async { view.progressDidChange(report) }
            return true
        default:
            // 창·탭·분할·설정 열기 같은 앱 동작은 앱이 메뉴로 따로 갖는다.
            return false
        }
    }

    // MARK: - Clipboard

    private static func readClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?,
        mimes: UnsafePointer<UnsafePointer<CChar>?>?,
        count: Int
    ) -> ghostty_clipboard_read_result_e {
        guard location == GHOSTTY_CLIPBOARD_STANDARD,
              let view = GhosttyTerminalView.from(userdata), let surface = view.surface else {
            return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
        }
        // 글자만 붙인다. 요청한 형식에 text/plain이 없으면 붙일 것이 없다.
        var wantsText = false
        if let mimes {
            for index in 0..<count where mimes[index].map({ String(cString: $0) }) == "text/plain" {
                wantsText = true
            }
        }
        guard wantsText, let text = NSPasteboard.general.string(forType: .string) else {
            return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE
        }
        let mime = strdup("text/plain")
        let data = strdup(text)
        defer { free(mime); free(data) }
        var content = ghostty_clipboard_content_s(mime: mime, data: data, len: strlen(data!))
        withUnsafePointer(to: &content) { contents in
            var complete = ghostty_clipboard_complete_s(
                contents: contents, contents_len: 1, available: nil, available_len: 0,
                confirmed: true, remember: false)
            ghostty_surface_complete_clipboard_request(surface, &complete, state)
        }
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    /// 복사(⌘C)와 원격 tmux가 보내는 OSC 52 쓰기를 맥 클립보드로.
    private static func writeClipboard(
        location: ghostty_clipboard_e,
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        count: Int
    ) {
        guard location == GHOSTTY_CLIPBOARD_STANDARD, let content, count > 0 else { return }
        for index in 0..<count {
            let item = content[index]
            guard let mime = item.mime, String(cString: mime) == "text/plain", let data = item.data else { continue }
            let text = String(decoding: UnsafeRawBufferPointer(start: data, count: item.len), as: UTF8.self)
            DispatchQueue.main.async {
                NSPasteboard.general.declareTypes([.string], owner: nil)
                NSPasteboard.general.setString(text, forType: .string)
            }
            return
        }
    }
}

/// 테마를 Ghostty 설정 글로 옮긴다. 글꼴·커서·단축키는 두 앱(sm, Fine)이 같은 값을 쓴다 — 두 앱에서
/// 같은 터미널을 보게.
enum GhosttyConfigText {
    static func make(theme: GhosttyTheme) -> String {
        var lines = [
            // xterm 시절 실제로 보이던 글꼴. terminal.html의 목록은 D2Coding이 먼저였지만,
            // WebKit은 사용자가 설치한 글꼴(~/Library/Fonts)을 웹 콘텐츠에 보이지 않아 실제로는
            // Menlo와 시스템 한글 글꼴로 그려졌다(10/31 WKWebView 글자 폭 실측). 그 목록을 그대로
            // 옮겼더니 D2Coding이 나와 "눈이 아프다"는 평(10/31) — 내장 D2Coding을 철회했던 이유와 같다.
            // 한글 글꼴은 적지 않는다. 적으면 Ghostty가 주 글꼴로 보고 크기 보정을 건너뛰어, 두 칸 안에서
            // 한글이 작게 그려져 음절 사이가 단어 사이처럼 벌어졌다(10/31 실제 창 캡처). 비워 두면 시스템이
            // 같은 Apple SD Gothic Neo를 대체 글꼴로 고르고, Ghostty가 Menlo 높이에 맞춰 키운다(네이티브 Ghostty와 같다).
            "font-family = Menlo",
            "font-size = 13",
            // xterm(WebKit)은 글자를 다듬어 굵게 그렸다. Ghostty 기본은 다듬기가 꺼져 있어 같은 Menlo 13이 잉크가
            // 25% 적었다(10/31 실측: 웹뷰 1,403,583 vs 1,053,623, thicken을 켜면 1,403,449) — "너무 얇다"는 평.
            "font-thicken = true",
            "cursor-style = bar",
            "cursor-style-blink = true",
            "macos-option-as-alt = false",
            // 여백은 앱의 카드가 준다.
            "window-padding-x = 0",
            "window-padding-y = 0",
            "window-padding-balance = false",
            // 원격(아치·누크)과 tmux에 xterm-ghostty terminfo가 없다.
            "term = xterm-256color",
            // 사용자의 셸 설정에 손대지 않는다.
            "shell-integration = none",
            "confirm-close-surface = false",
            // 여러 줄 붙여넣기에서 확인 창을 띄우지 않는다(xterm 때와 같다).
            "clipboard-paste-protection = false",
            "clipboard-read = deny",
            "clipboard-write = allow",
            // 단축키는 앱 메뉴가 갖는다. 터미널에는 복사·붙여넣기·전체 선택과 글꼴 크기만 남긴다.
            "keybind = clear",
            "keybind = super+c=copy_to_clipboard",
            "keybind = super+v=paste_from_clipboard",
            "keybind = super+a=select_all",
            // 글꼴 크기(⌘= ⌘+ 키우기, ⌘- 줄이기, ⌘0 되돌리기). 두 앱 메뉴가 쓰지 않는 키다(10/31 확인).
            "keybind = super+equal=increase_font_size:1",
            "keybind = super+plus=increase_font_size:1",
            "keybind = super+minus=decrease_font_size:1",
            "keybind = super+zero=reset_font_size",
        ]
        lines += theme.configLines
        return lines.joined(separator: "\n") + "\n"
    }
}
