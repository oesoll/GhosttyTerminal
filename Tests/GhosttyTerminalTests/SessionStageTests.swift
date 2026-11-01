import AppKit
import XCTest
@testable import GhosttyTerminal

/// 쉬는 세션의 무대: 장면 + 막, 붙잡은 키, 조용해지면 걷기, 저장 화면으로 장면 만들기.
@MainActor
final class SessionStageTests: XCTestCase {
    private var window: NSWindow!
    private var stage: GhosttySessionStage!

    override func setUpWithError() throws {
        _ = NSApplication.shared
        try XCTSkipUnless(GhosttyRuntime.shared.isAvailable, "libghostty did not initialise")
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 320), styleMask: [.titled],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false   // ARC가 해제한다 — close()가 한 번 더 해제하면 시험이 죽는다
        stage = GhosttySessionStage(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
        window.contentView = stage
    }

    override func tearDown() {
        [stage?.scene, stage?.live].compactMap { $0 }.forEach { $0.terminate() }
        window?.close()
    }

    private func surface(_ command: String) -> GhosttyTerminalView {
        GhosttyTerminalView(launch: .init(command: command, workingDirectory: NSHomeDirectory()),
                            theme: .fallback, initialSize: NSSize(width: 640, height: 320))
    }

    private func wait(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    private func key(_ characters: String, code: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                         windowNumber: window.windowNumber, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    /// 쉬는 동안 친 키는 버리지 않고, 새 표면이 화면을 다 그린 뒤(조용해진 뒤) 순서대로 들어간다.
    func testKeysHeldWhileCoveredReachTheNewSurfaceAfterItSettles() throws {
        let old = surface("/bin/sh -c 'printf \"OLD SCREEN\\n\"; sleep 30'")
        stage.show(old)
        XCTAssertTrue(wait { old.readText(lastLines: 5)?.contains("OLD SCREEN") == true })
        old.focusTerminal()
        old.endProcess()
        XCTAssertTrue(wait { !old.isProcessRunning }, "endProcess left the child running")
        XCTAssertEqual(old.readText(lastLines: 5)?.contains("OLD SCREEN"), true, "the frame did not survive")

        var wakeRequests = 0
        stage.onKeyWhileResting = { wakeRequests += 1 }
        stage.freeze(look: .dimmed)
        XCTAssertTrue(stage.isCovered)
        XCTAssertTrue(window.firstResponder === stage, "covered stage does not take the keys")
        stage.keyDown(with: key("a", code: 0))
        stage.keyDown(with: key("b", code: 11))
        XCTAssertEqual(wakeRequests, 2, "each key under the resting veil asks to wake")
        stage.setLook(.waking)
        stage.keyDown(with: key("c", code: 8))
        XCTAssertEqual(wakeRequests, 2, "keys while waking are only held")

        // 새 표면은 0.6초 동안 0.1초마다 그리다가 멈춘다(에이전트가 화면을 채우는 모양). 걷기는 그 뒤여야 한다.
        // 그보다 긴 공백은 조용함과 구별할 수 없다 — 그래서 호스트는 세션 층이 ready라고 한 뒤에야 부른다.
        let fresh = surface("/bin/sh -c 'for i in 1 2 3 4 5 6; do printf \"line $i\\n\"; sleep 0.1; done; printf \"READY\\n\"; exec cat'")
        stage.attach(fresh)
        stage.setLook(.waking)
        var screenAtReveal = ""
        stage.onReveal = { screenAtReveal = fresh.readText(lastLines: 5) ?? "" }
        stage.revealWhenQuiet(after: 0.25, limit: 5)
        XCTAssertTrue(stage.isCovered)
        XCTAssertTrue(wait(6) { !stage.isCovered }, "never revealed")
        XCTAssertTrue(screenAtReveal.contains("READY"), "revealed before the new screen settled: \(screenAtReveal)")
        XCTAssertTrue(window.firstResponder === fresh, "the new surface did not take the keys")
        XCTAssertTrue(wait { fresh.readText(lastLines: 5)?.contains("abc") == true },
                      "held keys did not arrive in order: \(fresh.readText(lastLines: 5) ?? "")")
        XCTAssertTrue(wait { old.superview == nil }, "the frozen scene was not cleared")
        XCTAssertNil(stage.scene)
        XCTAssertTrue(stage.live === fresh)
    }

    /// 앱을 다시 켜서 프레임이 없을 때: 세션 층이 남긴 화면 바이트가 장면이 된다.
    func testReplayedScreenBecomesTheScene() {
        let bytes = Data("\u{1b}[2J\u{1b}[H마지막 화면\r\n> 대기 중\r\n".utf8)
        stage.freeze(replaying: bytes)
        XCTAssertTrue(stage.isCovered)
        XCTAssertEqual(stage.look, .dimmed)
        XCTAssertTrue(wait { stage.scene?.readText(lastLines: 5)?.contains("> 대기 중") == true },
                      stage.scene?.readText(lastLines: 5) ?? "no scene")
        XCTAssertNil(stage.live)
    }

    /// 깨는 동안 누가 멈추면 새 표면을 치우고 어두운 막으로 돌아간다. 장면은 그대로다.
    func testCancelAttachGoesBackToTheDimmedScene() {
        let old = surface("/bin/sh -c 'printf \"KEEP\\n\"'")
        stage.show(old)
        XCTAssertTrue(wait { old.readText(lastLines: 5)?.contains("KEEP") == true })
        stage.freeze(look: .dimmed)
        let fresh = surface("/bin/sh -c 'sleep 30'")
        stage.attach(fresh)
        stage.setLook(.waking)
        XCTAssertEqual(stage.look, .waking)
        stage.cancelAttach()
        XCTAssertEqual(stage.look, .dimmed)
        XCTAssertTrue(stage.isCovered)
        XCTAssertNil(stage.live)
        XCTAssertNil(fresh.superview)
        XCTAssertTrue(stage.scene === old)
    }

    /// 깨는 중 효과의 그림(점 격자·빛의 가림막)이 실제로 만들어진다 — 못 만들면 효과가 소리 없이 사라진다.
    func testWakeEffectArtworkRenders() {
        XCTAssertNotNil(GhosttySessionStage.alphaImageForTests([0, 128, 255, 64], width: 2, height: 2))
    }

    /// 밝은 테마는 옅게 덮는다(회색으로 무너지지 않게).
    func testDimFollowsTheTheme() {
        stage.theme = GhosttyTheme(colors: ["background": "#fafafa"])
        let light = stage.dimOpacity
        stage.theme = GhosttyTheme(colors: ["background": "#1e1e1e"])
        XCTAssertLessThan(light, stage.dimOpacity)
    }
}
