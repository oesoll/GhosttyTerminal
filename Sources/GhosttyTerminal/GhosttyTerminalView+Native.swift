// Parts adapted from Ghostty (MIT, Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors):
// SurfaceView_AppKit.swift (drops, context menu, accessibility), Ghostty.App.swift (openURL),
// Ghostty.Shell.swift (escape). See LICENSE-ghostty in this folder.
import AppKit
import GhosttyKit

/// 터미널이 보낸 진행률(OSC 9;4). `percent`는 보고하지 않았으면 nil.
public struct GhosttyProgress: Equatable, Sendable {
    public enum State: Equatable, Sendable { case remove, set, error, indeterminate, pause }
    public let state: State
    public let percent: Int?
}

// MARK: - 링크

/// ⌘-클릭한 링크를 연다. 터미널 출력은 출력하는 프로그램이 정한 값이라 그대로 운영체제에 넘기지 않는다 —
/// Ghostty와 같은 정책(UntrustedURL): http(s)·mailto·안전한 파일은 바로, 다른 스킴은 물어보고, 실행될 수
/// 있는 파일과 보이지 않는 문자가 섞인 값은 막는다.
enum GhosttyLinkOpener {
    /// 시험이 실제로 브라우저를 띄우지 않게 바꿔 끼운다.
    nonisolated(unsafe) static var open: (URL) -> Void = { NSWorkspace.shared.open($0) }
    nonisolated(unsafe) static var confirm: (URL, String) -> Bool = { url, display in
        let alert = NSAlert()
        alert.messageText = "이 링크를 열까요?"
        let handler = NSWorkspace.shared.urlForApplication(toOpen: url)
            .map { FileManager.default.displayName(atPath: $0.path) } ?? "등록된 앱"
        alert.informativeText = "\(display)\n\n\(handler)(으)로 열립니다. 터미널 출력이 만든 링크입니다."
        alert.addButton(withTitle: "열기")
        alert.addButton(withTitle: "취소")
        return alert.runModal() == .alertFirstButtonReturn
    }
    nonisolated(unsafe) static var block: (UntrustedURL.DenialReason, String) -> Void = { reason, display in
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "이 링크는 열지 않았습니다"
        alert.informativeText = "\(display)\n\n\(koreanReason(reason))"
        alert.runModal()
    }

    static func handle(_ value: String, kind: ghostty_action_open_url_kind_e) {
        switch kind {
        case GHOSTTY_ACTION_OPEN_URL_KIND_TEXT, GHOSTTY_ACTION_OPEN_URL_KIND_HTML:
            // libghostty가 스스로 만든 경로(설정 파일 등). 터미널 출력이 아니다.
            if let url = URL(string: value), url.scheme != nil { open(url) } else {
                open(URL(fileURLWithPath: NSString(string: value).standardizingPath))
            }
        default:
            // OSC 8 링크와 화면에서 찾은 URL은 믿지 않는다. 경로처럼 보이면 파일 URL로 바꿔 같은 정책을 탄다.
            let hasScheme = URL(string: value)?.scheme != nil
            let target = hasScheme || UntrustedURL.containsUnsafeCharacters(value)
                ? value
                : URL(fileURLWithPath: NSString(string: value).standardizingPath).absoluteString
            let untrusted = UntrustedURL(target)
            switch untrusted.decision {
            case .allow(let url): open(url)
            case .confirm(let url): if confirm(url, untrusted.displayString) { open(url) }
            case .deny(let reason): block(reason, untrusted.displayString)
            }
        }
    }

    static func koreanReason(_ reason: UntrustedURL.DenialReason) -> String {
        switch reason {
        case .malformedURL: "스킴이 있는 완전한 주소가 아닙니다."
        case .unsafeCharacters: "보이지 않거나 줄을 바꾸는 문자가 섞여 있습니다."
        case .invalidWebURL: "웹 주소에 호스트가 없습니다."
        case .inaccessibleFile: "그 파일이 없거나, 일반 파일·폴더가 아닙니다."
        case .unsafeFile: "열면 코드가 실행될 수 있는 파일입니다."
        }
    }
}

// MARK: - 끌어다 놓기

extension GhosttyTerminalView {
    static let dropTypes: Set<NSPasteboard.PasteboardType> = [.string, .fileURL]

    /// 셸이 한 낱말로 읽게 경로의 특수 문자 앞에 역슬래시를 붙인다(Ghostty.Shell.escape).
    static func shellEscaped(_ path: String) -> String {
        var result = path
        for character in "\\ ()[]{}<>\"'`!#$&;|*?\t" {
            result = result.replacingOccurrences(of: String(character), with: "\\\(character)")
        }
        return result
    }

    /// 놓은 것을 터미널에 넣을 글로: 파일은 이스케이프한 경로, 글은 그대로, 여럿이면 공백으로 잇는다.
    static func dropText(from pasteboard: NSPasteboard) -> String? {
        let parts = (pasteboard.pasteboardItems ?? []).compactMap { item -> String? in
            if let plist = item.propertyList(forType: .fileURL),
               let url = NSURL(pasteboardPropertyList: plist, ofType: .fileURL) as URL?, url.isFileURL {
                return shellEscaped(url.path)
            }
            return item.string(forType: .string)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let types = sender.draggingPasteboard.types, !Set(types).isDisjoint(with: Self.dropTypes) else { return [] }
        return .copy
    }

    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let text = Self.dropText(from: sender.draggingPasteboard) else { return false }
        // 놓은 글은 붙여넣기와 같은 길로 간다(괄호 붙여넣기 — Claude Code는 이미지 경로를 첨부로 받는다).
        DispatchQueue.main.async { [weak self] in self?.pasteText(text) }
        return true
    }

    /// 붙여넣기(⌘V와 같은 길: 프로그램이 원하면 괄호 붙여넣기로 감싼다).
    public func pasteText(_ text: String) {
        guard let surface, !exited, !text.isEmpty else { return }
        text.withCString { ghostty_surface_paste_text(surface, $0, UInt(strlen($0))) }
    }
}

// MARK: - 오른쪽 클릭 메뉴

extension GhosttyTerminalView: NSMenuItemValidation {
    public override func menu(for event: NSEvent) -> NSMenu? {
        switch event.type {
        case .rightMouseDown:
            break
        case .leftMouseDown:
            // ⌃-클릭: 마우스를 쓰는 터미널 프로그램(마우스 보고 모드)에는 그대로 보낸다.
            guard event.modifierFlags.contains(.control), let surface,
                  !ghostty_surface_mouse_captured(surface) else { return nil }
            _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT,
                                             Self.mods(event.modifierFlags))
        default:
            return nil
        }
        let menu = NSMenu()
        if hasSelection {
            menu.addItem(withTitle: "복사", action: #selector(copy(_:)), keyEquivalent: "")
        }
        menu.addItem(withTitle: "붙여넣기", action: #selector(paste(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "전체 선택", action: #selector(selectAll(_:)), keyEquivalent: "")
        return menu
    }

    var hasSelection: Bool {
        guard let surface else { return false }
        return ghostty_surface_has_selection(surface)
    }

    @objc func copy(_ sender: Any?) { performBinding("copy_to_clipboard") }
    @objc func paste(_ sender: Any?) { performBinding("paste_from_clipboard") }
    @objc override public func selectAll(_ sender: Any?) { performBinding("select_all") }

    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)): hasSelection
        case #selector(paste(_:)): NSPasteboard.general.string(forType: .string) != nil
        default: true
        }
    }

    @discardableResult
    func performBinding(_ action: String) -> Bool {
        guard let surface else { return false }
        return action.withCString { ghostty_surface_binding_action(surface, $0, UInt(strlen($0))) }
    }
}

// MARK: - 손쉬운 사용(VoiceOver)

extension GhosttyTerminalView {
    /// 화면 전체 글. VoiceOver는 한 번 읽을 때 여러 번 묻는다 — 0.5초 동안은 같은 글을 돌려준다(Ghostty와 같다).
    var accessibleScreen: String {
        let now = Date()
        if let cache = screenCache, now.timeIntervalSince(cache.at) < 0.5 { return cache.text }
        let text = readText(lastLines: Int.max) ?? ""
        screenCache = (text, now)
        return text
    }

    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    public override func accessibilityHelp() -> String? { "터미널" }
    public override func accessibilityValue() -> Any? { accessibleScreen }
    public override func accessibilitySelectedTextRange() -> NSRange { selectedRange() }

    public override func accessibilitySelectedText() -> String? {
        guard let surface else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        let value = String(cString: text.text)
        return value.isEmpty ? nil : value
    }

    public override func accessibilityNumberOfCharacters() -> Int { (accessibleScreen as NSString).length }

    public override func accessibilityVisibleCharacterRange() -> NSRange {
        NSRange(location: 0, length: (accessibleScreen as NSString).length)
    }

    public override func accessibilityLine(for index: Int) -> Int {
        let screen = accessibleScreen as NSString
        let prefix = screen.substring(to: min(max(0, index), screen.length))
        return prefix.components(separatedBy: .newlines).count - 1
    }

    public override func accessibilityString(for range: NSRange) -> String? {
        let screen = accessibleScreen as NSString
        guard range.location >= 0, NSMaxRange(range) <= screen.length else { return nil }
        return screen.substring(with: range)
    }

    public override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        guard let text = accessibilityString(for: range) else { return nil }
        var attributes: [NSAttributedString.Key: Any] = [:]
        if let surface, let raw = ghostty_surface_quicklook_font(surface) {
            let font = Unmanaged<CTFont>.fromOpaque(raw)
            attributes[.font] = font.takeUnretainedValue()
            font.release()
        }
        return NSAttributedString(string: text, attributes: attributes)
    }
}

// MARK: - 벨·알림·진행률

extension GhosttyTerminalView {
    /// 벨(BEL). 앱이 정하지 않았으면, 앱이 앞에 있지 않을 때만 Dock으로 한 번 알린다(소리는 내지 않는다).
    func ringBell() {
        if let onBell { onBell(); return }
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    func progressDidChange(_ report: ghostty_action_progress_report_s) {
        let state: GhosttyProgress.State
        switch report.state {
        case GHOSTTY_PROGRESS_STATE_REMOVE: state = .remove
        case GHOSTTY_PROGRESS_STATE_ERROR: state = .error
        case GHOSTTY_PROGRESS_STATE_INDETERMINATE: state = .indeterminate
        case GHOSTTY_PROGRESS_STATE_PAUSE: state = .pause
        default: state = .set
        }
        onProgress?(GhosttyProgress(state: state, percent: report.progress >= 0 ? Int(report.progress) : nil))
    }
}
