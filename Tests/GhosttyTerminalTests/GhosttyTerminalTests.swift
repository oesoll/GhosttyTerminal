import AppKit
import XCTest
@testable import GhosttyTerminal

final class GhosttyThemeTests: XCTestCase {
    func testTransparentBackgroundBecomesOpacity() {
        let theme = GhosttyTheme(colors: ["background": "rgba(0, 0, 0, 0)", "foreground": "#e4e4e6"],
                                 minimumContrast: 4.5)
        let lines = theme.configLines
        XCTAssertTrue(lines.contains("background = #000000"))
        XCTAssertTrue(lines.contains("background-opacity = 0"))
        XCTAssertTrue(lines.contains("foreground = #e4e4e6"))
        XCTAssertTrue(lines.contains("minimum-contrast = 4.5"))
    }

    func testOpaqueBackgroundHasNoOpacityLine() {
        let lines = GhosttyTheme(colors: ["background": "#FFF", "brightBlack": "#2c2c2e"]).configLines
        XCTAssertTrue(lines.contains("background = #ffffff"))
        XCTAssertFalse(lines.contains { $0.hasPrefix("background-opacity") })
        XCTAssertTrue(lines.contains("palette = 8=#2c2c2e"))
    }

    func testUnreadableColorIsLeftToGhostty() {
        XCTAssertNil(GhosttyTheme.parse("tomato"))
        XCTAssertFalse(GhosttyTheme(colors: ["cursor": "tomato"]).configLines.contains { $0.hasPrefix("cursor-color") })
    }
}

final class GhosttyWriteEncodingTests: XCTestCase {
    func testEveryNonPrintableByteIsEscaped() {
        let action = GhosttyTerminalView.textBindingAction(Data("a\\b\r\u{1b}[A한".utf8))
        let text = String(decoding: action, as: UTF8.self)
        XCTAssertEqual(text, "text:a\\x5cb\\x0d\\x1b[A\\xed\\x95\\x9c")
    }
}

/// 실제 libghostty 표면을 띄운다(창 없이). 자식 프로세스가 PTY로 쓰고 읽는 길을 끝까지 확인한다.
@MainActor
final class GhosttySurfaceTests: XCTestCase {
    private func makeView(_ command: String, directory: String = NSHomeDirectory(),
                          environment: [String: String] = [:]) throws -> GhosttyTerminalView {
        _ = NSApplication.shared
        try XCTSkipUnless(GhosttyRuntime.shared.isAvailable, "libghostty did not initialise")
        let view = GhosttyTerminalView(
            launch: .init(command: command, workingDirectory: directory, environment: environment),
            theme: .fallback, initialSize: NSSize(width: 640, height: 320))
        XCTAssertFalse(view.failedToStart)
        return view
    }

    private func waitForText(_ view: GhosttyTerminalView, timeout: TimeInterval = 5,
                             _ predicate: (String) -> Bool) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var last = ""
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            last = view.readText(lastLines: 200) ?? ""
            if predicate(last) { return last }
        }
        return last
    }

    func testRawWriteReachesTheChildAndTheScreenReadsBack() throws {
        let view = try makeView("/bin/sh -c 'printf \"READY\\n\"; exec cat'")
        defer { view.terminate() }
        _ = waitForText(view) { $0.contains("READY") }
        XCTAssertTrue(view.write(Data("hello 한글\r".utf8)))
        let screen = waitForText(view) { $0.components(separatedBy: "hello 한글").count >= 3 }
        // tty 에코 한 번 + cat 출력 한 번.
        XCTAssertEqual(screen.components(separatedBy: "hello 한글").count, 3, screen)
    }

    func testWorkingDirectoryAndEnvironmentReachTheChild() throws {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        let view = try makeView("/bin/sh -c 'echo \"DIR=$(pwd)\"; echo \"VAR=$GT_PROBE\"; sleep 5'",
                                directory: directory, environment: ["GT_PROBE": "probe-1"])
        defer { view.terminate() }
        let screen = waitForText(view) { $0.contains("VAR=") }
        XCTAssertTrue(screen.contains("DIR=\(directory)"), screen)
        XCTAssertTrue(screen.contains("VAR=probe-1"), screen)
    }

    func testReadTextReturnsOnlyTheLastLines() throws {
        let view = try makeView("/bin/sh -c 'for i in 1 2 3 4 5; do echo line$i; done; sleep 5'")
        defer { view.terminate() }
        _ = waitForText(view) { $0.contains("line5") }
        XCTAssertEqual(view.readText(lastLines: 2), "line4\nline5")
    }
}

/// Claude Code는 SIGHUP과 SIGTERM을 무시한다. 표면을 닫기만 하면 그런 자식이 살아남는다(10/31 실험).
@MainActor
final class GhosttyTerminationTests: XCTestCase {
    private func launchSignalIgnoringChild() throws -> (GhosttyTerminalView, pid_t) {
        _ = NSApplication.shared
        try XCTSkipUnless(GhosttyRuntime.shared.isAvailable, "libghostty did not initialise")
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("reap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let view = GhosttyTerminalView(
            launch: .init(command: "/bin/sh -c 'trap \"\" HUP TERM; echo $$ > \(pidFile.path); exec sleep 300'",
                          workingDirectory: NSHomeDirectory()),
            theme: .fallback, initialSize: NSSize(width: 640, height: 320))
        let deadline = Date().addingTimeInterval(5)
        while (try? String(contentsOf: pidFile, encoding: .utf8))?.isEmpty != false && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        let text = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return (view, try XCTUnwrap(pid_t(text)))
    }

    func testPlainCloseLeavesASignalIgnoringChild() throws {
        let (view, pid) = try launchSignalIgnoringChild()
        defer { kill(pid, SIGKILL) }
        view.terminate()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(kill(pid, 0), 0, "libghostty now kills it by itself — the reaper may be unnecessary")
    }

    func testReapingCloseKillsASignalIgnoringChild() throws {
        let (view, pid) = try launchSignalIgnoringChild()
        defer { kill(pid, SIGKILL) }
        let start = Date()
        view.terminate(reapingAfter: 0.3, synchronously: true)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertNil(ProcessGroupReaper.identity(of: pid), "child survived the reaper")
    }
}

/// libghostty 콜백이 뷰를 되찾는 길: 해제된 뷰를 되살리지 않는다(11/01 sm 크래시).
@MainActor
final class CallbackLookupTests: XCTestCase {
    func testAFreedViewIsNotRevivedFromItsPointer() {
        _ = NSApplication.shared
        var pointer: UnsafeMutableRawPointer?
        autoreleasepool {
            let view = GhosttyTerminalView(launch: nil, theme: .fallback)
            pointer = Unmanaged.passUnretained(view).toOpaque()
            XCTAssertTrue(GhosttyTerminalView.from(pointer) === view)
        }
        XCTAssertNil(GhosttyTerminalView.from(pointer))
    }

    func testClosingASurfaceThenDroppingTheViewDoesNotCrash() throws {
        _ = NSApplication.shared
        try XCTSkipUnless(GhosttyRuntime.shared.isAvailable, "libghostty did not initialise")
        for _ in 0..<20 {
            autoreleasepool {
                let view = GhosttyTerminalView(launch: .init(command: "/bin/sh -c 'exit 0'", workingDirectory: NSHomeDirectory()),
                                               theme: .fallback, initialSize: NSSize(width: 320, height: 160))
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                view.terminate()
            }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    }
}
