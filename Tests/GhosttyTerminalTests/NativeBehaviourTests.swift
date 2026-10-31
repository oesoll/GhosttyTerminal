import AppKit
import GhosttyKit
import XCTest
@testable import GhosttyTerminal

final class UntrustedLinkTests: XCTestCase {
    func testPolicy() throws {
        XCTAssertEqual(UntrustedURL("https://example.com/a").decision, .allow(URL(string: "https://example.com/a")!))
        XCTAssertEqual(UntrustedURL("https:relative").decision, .deny(.invalidWebURL))
        guard case .confirm = UntrustedURL("slack://open").decision else { return XCTFail("custom scheme must ask") }
        XCTAssertEqual(UntrustedURL("https://exa\u{202E}mple.com").decision, .deny(.unsafeCharacters))
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("gt-\(UUID().uuidString).sh")
        try "#!/bin/sh\necho hi\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        defer { try? FileManager.default.removeItem(at: script) }
        XCTAssertEqual(UntrustedURL(script.absoluteString).decision, .deny(.unsafeFile))
    }

    @MainActor
    func testOpenerRoutesEachKind() {
        var opened: [URL] = [], asked: [URL] = [], blocked: [UntrustedURL.DenialReason] = []
        let saved = (GhosttyLinkOpener.open, GhosttyLinkOpener.confirm, GhosttyLinkOpener.block)
        defer { (GhosttyLinkOpener.open, GhosttyLinkOpener.confirm, GhosttyLinkOpener.block) = saved }
        GhosttyLinkOpener.open = { opened.append($0) }
        GhosttyLinkOpener.confirm = { url, _ in asked.append(url); return false }
        GhosttyLinkOpener.block = { reason, _ in blocked.append(reason) }
        GhosttyLinkOpener.handle("https://example.com", kind: GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN)
        GhosttyLinkOpener.handle("zoommtg://join", kind: GHOSTTY_ACTION_OPEN_URL_KIND_OSC8)
        GhosttyLinkOpener.handle("/no/such/file/here", kind: GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN)
        XCTAssertEqual(opened, [URL(string: "https://example.com")!])
        XCTAssertEqual(asked, [URL(string: "zoommtg://join")!])
        XCTAssertEqual(blocked, [.inaccessibleFile])
    }
}

final class DropTextTests: XCTestCase {
    func testFilesBecomeEscapedPathsAndTextStaysText() {
        let board = NSPasteboard(name: .init("gt-drop-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        let file = NSPasteboardItem()
        file.setString(URL(fileURLWithPath: "/tmp/스크린샷 (1).png").absoluteString, forType: .fileURL)
        let text = NSPasteboardItem()
        text.setString("hello", forType: .string)
        board.writeObjects([file, text])
        XCTAssertEqual(GhosttyTerminalView.dropText(from: board), "/tmp/스크린샷\\ \\(1\\).png hello")
    }
}

/// 실제 표면으로: 붙여넣기, 메뉴, 손쉬운 사용, 글꼴 크기, 벨·알림·진행률, ⌘-클릭 링크.
@MainActor
final class NativeSurfaceTests: XCTestCase {
    private func makeView(_ command: String) throws -> GhosttyTerminalView {
        _ = NSApplication.shared
        try XCTSkipUnless(GhosttyRuntime.shared.isAvailable, "libghostty did not initialise")
        let view = GhosttyTerminalView(launch: .init(command: command, workingDirectory: NSHomeDirectory()),
                                       theme: .fallback, initialSize: NSSize(width: 640, height: 320))
        XCTAssertFalse(view.failedToStart)
        return view
    }

    private func wait(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    func testPasteMenuAndAccessibility() throws {
        let view = try makeView("/bin/sh -c 'printf \"READY\\n\"; exec cat'")
        defer { view.terminate() }
        XCTAssertTrue(wait { view.readText(lastLines: 5)?.contains("READY") == true })
        view.pasteText("붙여넣은 글\r")
        XCTAssertTrue(wait { (view.readText(lastLines: 10) ?? "").components(separatedBy: "붙여넣은 글").count == 3 },
                      view.readText(lastLines: 10) ?? "")

        let right = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
                                                     timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                                                     clickCount: 1, pressure: 1))
        XCTAssertEqual(view.menu(for: right)?.items.map(\.title), ["붙여넣기", "", "전체 선택"])
        view.selectAll(nil)
        XCTAssertTrue(wait { view.hasSelection })
        XCTAssertEqual(view.menu(for: right)?.items.first?.title, "복사")

        XCTAssertTrue(view.isAccessibilityElement())
        XCTAssertEqual(view.accessibilityRole(), .textArea)
        XCTAssertTrue((view.accessibilityValue() as? String)?.contains("READY") == true)
        XCTAssertNotNil(view.accessibilitySelectedText())
    }

    func testFontSizeKeysChangeTheCell() throws {
        let view = try makeView("/bin/sh -c 'sleep 10'")
        defer { view.terminate() }
        XCTAssertTrue(wait { view.cellSize.height > 0 && view.cellSize != NSSize(width: 8, height: 16) })
        let before = view.cellSize
        XCTAssertTrue(view.performBinding("increase_font_size:1"))
        XCTAssertTrue(wait { view.cellSize.height > before.height }, "cell \(view.cellSize) vs \(before)")
        XCTAssertTrue(view.performBinding("reset_font_size"))
        XCTAssertTrue(wait { view.cellSize == before })
    }

    func testBellNotificationAndProgressReachTheApp() throws {
        var bells = 0
        var notes: [String] = []
        var progress: [GhosttyProgress] = []
        let view = try makeView("/bin/sh -c 'sleep 0.3; printf \"\\a\"; printf \"\\033]9;osc nine\\007\"; sleep 1.2; printf \"\\033]777;notify;제목;본문\\007\"; printf \"\\033]9;4;1;42\\007\"; sleep 5'")
        defer { view.terminate() }
        view.onBell = { bells += 1 }
        view.onNotification = { notes.append("\($0)|\($1)") }
        view.onProgress = { progress.append($0) }
        // libghostty는 알림을 앱 전체에서 1초에 하나로 묶는다 — 두 알림 사이를 띄운다.
        XCTAssertTrue(wait(8) { bells > 0 && notes.count >= 2 && !progress.isEmpty },
                      "bells \(bells) notes \(notes) progress \(progress)")
        XCTAssertTrue(notes.contains { $0.hasSuffix("|osc nine") }, "\(notes)")
        XCTAssertTrue(notes.contains("제목|본문"), "\(notes)")
        XCTAssertEqual(progress.first, GhosttyProgress(state: .set, percent: 42))
    }

    func testCommandClickOnALinkGoesThroughTheOpener() throws {
        var opened: [URL] = []
        let saved = GhosttyLinkOpener.open
        defer { GhosttyLinkOpener.open = saved }
        GhosttyLinkOpener.open = { opened.append($0) }
        let view = try makeView("/bin/sh -c 'printf \"see https://example.com/fine here\\n\"; sleep 10'")
        defer { view.terminate() }
        XCTAssertTrue(wait { view.readText(lastLines: 3)?.contains("example.com") == true })
        XCTAssertTrue(wait { view.cellSize != NSSize(width: 8, height: 16) })
        let surface = try XCTUnwrap(view.surface)
        // 화면 좌표(포인트, 위에서부터): 첫 줄, "https" 안쪽 칸.
        let x = view.cellSize.width * 10.5, y = view.cellSize.height * 0.5
        ghostty_surface_mouse_pos(surface, x, y, GHOSTTY_MODS_SUPER)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_SUPER)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_SUPER)
        XCTAssertTrue(wait { !opened.isEmpty }, "no OPEN_URL")
        XCTAssertEqual(opened.first, URL(string: "https://example.com/fine"))
    }
}
