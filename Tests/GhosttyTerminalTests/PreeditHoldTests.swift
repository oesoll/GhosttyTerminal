import AppKit
import GhosttyKit
import XCTest
@testable import GhosttyTerminal

/// 입력기가 조합을 확정한 순간부터 프로그램이 그 글자를 되돌려 그릴 때까지 글자가 화면에서 빠지지 않고,
/// 그린 뒤에는 잡아 둔 글자가 남지 않는다(preedit-hold 패치 + commitComposition). 확정 즉시 조합 표시를
/// 지우던 때는 한글을 치다 스페이스를 누르면 직전 글자가 깜빡였다(10/31). 여기 프로그램은 받은 글자를
/// 40ms 뒤에 돌려준다 — Claude Code가 입력란을 다시 그리는 지연을 흉내 낸 것.
@MainActor
final class PreeditHoldTests: XCTestCase {
    func testCommitStaysOnScreenUntilEchoedAndLeavesNoGhost() throws {
        _ = NSApplication.shared
        try XCTSkipUnless(GhosttyRuntime.shared.isAvailable, "libghostty did not initialise")
        let size = NSSize(width: 400, height: 80)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 60, y: 60), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        NSApp.setActivationPolicy(.accessory)
        window.level = .floating
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("gt-slow-echo-\(UUID().uuidString).sh")
        try """
        printf '\\033[?25lREADY\\n'
        stty -icanon -echo
        exec python3 -u -c 'import os,time
        while True:
            b = os.read(0, 64)
            if not b: break
            time.sleep(0.04)
            os.write(1, b)'
        """.write(to: script, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: script) }
        let view = GhosttyTerminalView(launch: .init(command: "/bin/sh " + script.path, workingDirectory: NSHomeDirectory()),
                                       theme: .fallback, initialSize: size)
        view.frame = NSRect(origin: .zero, size: size)
        window.contentView = view
        window.orderFrontRegardless()
        window.makeFirstResponder(view)
        defer { view.terminate(); window.close() }
        XCTAssertTrue(wait { (view.readText(lastLines: 5) ?? "").contains("READY") }, "the echo program never started")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        // 둘째 줄: 첫 두 칸은 "한", 그 뒤 칸들은 확정 뒤 커서가 갈 자리("한 " 다음).
        let cell = view.cellSize
        let syllable = CGRect(x: 0, y: cell.height, width: cell.width * 2, height: cell.height)
        let beyond = CGRect(x: cell.width * 3, y: cell.height, width: cell.width * 4, height: cell.height)

        view.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        let composing = try XCTUnwrap(ink(window, syllable))
        XCTAssertGreaterThan(composing, 0, "the composing syllable was not drawn")

        view.commitComposition(["한", " "], composing: "")
        // 에코가 오기 전(40ms 안): 그 칸이 한 번도 비지 않아야 한다.
        var faintest = Double.infinity
        let committed = Date()
        while Date().timeIntervalSince(committed) < 0.035 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.004))
            faintest = min(faintest, try XCTUnwrap(ink(window, syllable)))
        }
        XCTAssertGreaterThan(faintest, composing / 4, "the committed syllable disappeared before its echo")

        // 에코가 온 뒤: 글자는 화면의 것이고, 잡아 둔 글자가 새 커서 자리에 남지 않는다.
        XCTAssertTrue(wait { (view.readText(lastLines: 5) ?? "").contains("한") }, "the echo never arrived")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertGreaterThan(try XCTUnwrap(ink(window, syllable)), composing / 4)
        XCTAssertLessThan(try XCTUnwrap(ink(window, beyond)), composing / 8, "the held text is still drawn after the echo")
    }

    private func wait(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    /// 창 왼쪽 위 기준 사각형에서 바탕(#1e1e1e)보다 밝은 만큼의 합(녹색).
    private func ink(_ window: NSWindow, _ rect: CGRect) -> Double? {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
              let symbol = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        let primary = NSScreen.screens.first?.frame.height ?? window.frame.maxY
        let screen = CGRect(x: window.frame.minX + rect.minX, y: primary - window.frame.maxY + rect.minY,
                            width: rect.width, height: rect.height)
        guard let image = unsafeBitCast(symbol, to: CreateImage.self)(screen, 1 << 3, UInt32(window.windowNumber), 1)?
            .takeRetainedValue() else { return nil }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var sum = 0.0
        for index in stride(from: 1, to: pixels.count, by: 4) { sum += max(0, Double(pixels[index]) - 0x1e) }
        return sum
    }
}
