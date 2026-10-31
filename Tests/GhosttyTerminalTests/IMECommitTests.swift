import AppKit
import GhosttyKit
import XCTest
@testable import GhosttyTerminal

/// 입력기가 조합을 끝내는 두 순간에 글자가 프로그램에 제대로 닿는가(10/31 제보).
/// - 두벌식은 조합 중 마지막 자모를 지울 때 그 자모를 확정하고 뒤로 지우기를 요청한다. 확정 글자만 보내면
///   입력란에 "ㄱ"이 남아 지우기를 한 번 더 눌러야 했다.
/// - 조합 중에 포커스를 잃으면(탭 전환) 그 글자가 사라졌다.
/// 실제 입력기는 앞에 있는 앱의 실제 키만 받으므로, 입력기가 부르는 차례를 그대로 흉내 낸다.
@MainActor
final class IMECommitTests: XCTestCase {
    private var log: URL!
    private var script: URL!

    override func setUp() async throws {
        log = FileManager.default.temporaryDirectory.appendingPathComponent("gt-ime-\(UUID().uuidString)")
        script = FileManager.default.temporaryDirectory.appendingPathComponent("gt-ime-\(UUID().uuidString).sh")
        try "printf 'READY\\n'; stty raw -echo; exec cat > '\(log.path)'\n".write(to: script, atomically: true, encoding: .utf8)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: log)
        try? FileManager.default.removeItem(at: script)
    }

    private func makeView() throws -> GhosttyTerminalView {
        _ = NSApplication.shared
        try XCTSkipUnless(GhosttyRuntime.shared.isAvailable, "libghostty did not initialise")
        let view = GhosttyTerminalView(launch: .init(command: "/bin/sh " + script.path, workingDirectory: NSHomeDirectory()),
                                       theme: .fallback, initialSize: NSSize(width: 400, height: 100))
        XCTAssertTrue(wait { (view.readText(lastLines: 5) ?? "").contains("READY") }, "the recorder never started")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        return view
    }

    private var received: [UInt8] { Array((try? Data(contentsOf: log)) ?? Data()) }

    private func wait(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    func testBackspaceThatCommitsTheLastJamoAlsoDeletesIt() throws {
        let view = try makeView()
        defer { view.terminate() }
        view.setMarkedText("ㄱ", selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        let backspace = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0, context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}",
            isARepeat: false, keyCode: 51))
        // 입력기가 keyDown 안에서 한 일: insertText("ㄱ") + doCommand(deleteBackward:), 새 조합은 없음.
        view.finishCommit(["ㄱ"], composing: "", requested: [#selector(NSResponder.deleteBackward(_:))],
                          action: GHOSTTY_ACTION_PRESS, event: backspace, translationEvent: backspace)
        let expected = Array("ㄱ".utf8) + [0x7f]
        XCTAssertTrue(wait { received == expected }, "the program received \(received), not ㄱ then delete")
        XCTAssertFalse(view.hasMarkedText())
    }

    func testCommitWithoutARequestDoesNotSendTheKey() throws {
        let view = try makeView()
        defer { view.terminate() }
        let space = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        // 스페이스로 확정: 입력기가 공백까지 확정 글자에 넣고 명령은 요청하지 않는다.
        view.finishCommit(["가 "], composing: "", requested: [], action: GHOSTTY_ACTION_PRESS,
                          event: space, translationEvent: space)
        XCTAssertTrue(wait { received == Array("가 ".utf8) }, "the program received \(received)")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(received, Array("가 ".utf8), "the space was sent twice")
    }

    func testLosingFocusWhileComposingCommitsTheSyllable() throws {
        let view = try makeView()
        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 400, height: 100), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { view.terminate(); window.close() }
        XCTAssertTrue(window.makeFirstResponder(view))
        view.setMarkedText("가", selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertTrue(wait { received == Array("가".utf8) }, "the composing syllable was lost: \(received)")
        XCTAssertFalse(view.hasMarkedText())
    }
}
