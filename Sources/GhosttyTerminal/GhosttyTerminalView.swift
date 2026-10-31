// Parts adapted from Ghostty (MIT, Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors).
// See LICENSE-ghostty in this folder.
import AppKit
import Carbon
import GhosttyKit

/// 터미널 하나 = libghostty 표면 하나. 표면이 PTY와 자식 프로세스를 직접 쥐고 Metal로 그린다.
///
/// 키 입력은 Ghostty macOS 앱의 SurfaceView_AppKit.swift(MIT)를 옮겼다. 특히 한글 조합은
/// `interpretKeyEvents`와 NSTextInputClient를 거쳐야 하고, 수정자를 바꾸지 않은 키는 원래 NSEvent를
/// 그대로 넘겨야 조합이 깨지지 않는다(Ghostty가 실측으로 남긴 주의).
public final class GhosttyTerminalView: NSView, NSTextInputClient {
    /// 표면을 띄울 명령. nil이면 로그인 셸.
    ///
    /// 명령은 셸 한 줄이다. 맥에서 libghostty는 이것을 `login -flp <사용자> /bin/bash --noprofile --norc
    /// -c "exec -l <명령>"`으로 띄운다 — 인자는 bash 문법으로 따옴표를 쳐서 넘긴다. `environment`는 앱의
    /// 환경에 더하는 것만 된다. 지울 변수는 명령 앞에 `/usr/bin/env -u NAME`을 붙인다.
    public struct Launch: Equatable {
        public var command: String?
        public var workingDirectory: String
        public var environment: [String: String]

        public init(command: String?, workingDirectory: String, environment: [String: String] = [:]) {
            self.command = command
            self.workingDirectory = workingDirectory
            self.environment = environment
        }
    }

    private(set) var surface: ghostty_surface_t?
    public let launch: Launch

    /// 자식 프로세스가 끝났다(종료 코드). 재연결할지는 세션이 정한다.
    public var onExit: ((Int32) -> Void)?
    public var onTitle: ((String) -> Void)?
    /// 셀 크기(포인트)가 정해지거나 바뀌었다. 글꼴이 표면을 만든 뒤에 정해지므로, 셀에 맞춰 자리를
    /// 잡는 호스트(Fine의 꼬리 줄 가리기)는 이것을 듣는다.
    public var onCellSize: ((NSSize) -> Void)?
    /// 벨(BEL). 없으면 앱이 뒤에 있을 때 Dock으로 한 번 알린다.
    public var onBell: (() -> Void)?
    /// 터미널 프로그램이 보낸 데스크톱 알림(OSC 9 / OSC 777): 제목, 본문.
    public var onNotification: ((String, String) -> Void)?
    /// 진행률(OSC 9;4). Claude Code는 Ghostty에서 작업 중 진행률을 보낸다.
    public var onProgress: ((GhosttyProgress) -> Void)?
    /// 손쉬운 사용이 읽는 화면 글(0.5초 캐시).
    var screenCache: (text: String, at: Date)?

    private var markedText = NSMutableAttributedString()
    /// keyDown 안에서만 non-nil. 그동안 IME가 확정한 글자를 모았다가 키 이벤트로 보낸다.
    private var keyTextAccumulator: [String]?
    private var lastPerformKeyEvent: TimeInterval?
    /// 셀 크기(포인트). 글꼴이 정해지기 전에는 Menlo 13pt의 근삿값.
    public private(set) var cellSize = NSSize(width: 8, height: 16)
    private var contentSize = NSSize.zero
    private var trackingArea: NSTrackingArea?
    private var pendingPresentation: (() -> Void)?
    private(set) var exited = false

    /// 프로세스 없는 빈 표면. 호스트 뷰의 갈아 끼우기만 시험할 때 쓴다.
    public override convenience init(frame: NSRect) {
        self.init(launch: nil, theme: .fallback)
        self.frame = frame
    }

    /// `startWhenSized`: 창에 들어가 실제 크기를 안 뒤에 표면(= 자식 프로세스)을 띄운다. `initialSize`를 주면
    /// 그 크기로 바로 띄운다(재연결: 화면 밖에서 붙어 보는 새 표면이 끊긴 표면과 같은 크기로).
    ///
    /// 왜: libghostty의 내장 런타임은 표면을 늘 800×600픽셀로 시작하고, 그 순간 자식이 뜬다. 에이전트에
    /// 붙는 `sm-session attach`는 그 작은 화면(약 51칸)을 보고 에이전트를 줄였다가, 곧 들어온 실제 크기로
    /// 다시 늘린다. 그 사이 에이전트가 좁은 폭으로 한 번 그린 화면이 "처음 열 때 잠깐 깨짐"이었다(10/31).
    public init(launch: Launch?, theme: GhosttyTheme, startWhenSized: Bool = false, initialSize: NSSize? = nil) {
        self.launch = launch ?? Launch(command: nil, workingDirectory: NSHomeDirectory())
        self.theme = theme
        super.init(frame: NSRect(origin: .zero, size: initialSize ?? NSSize(width: 800, height: 600)))
        // 파일·글을 끌어다 놓으면 붙여 넣는다(GhosttyTerminalView+Native).
        registerForDraggedTypes(Array(Self.dropTypes))
        guard let launch else { return }
        if startWhenSized && initialSize == nil {
            pendingLaunch = launch
            updateTrackingAreas()
            return
        }
        createSurface(launch, size: initialSize)
        updateTrackingAreas()
    }

    /// 지금 표면에 입힌 색.
    public private(set) var theme: GhosttyTheme
    /// 아직 띄우지 않은 명령(실제 크기를 기다리는 중).
    private var pendingLaunch: Launch?
    /// 표면이 생기기 전에 들어온 입력(시험·CLI가 붙여 넣는 글자, 리턴). 생기면 그대로 보낸다.
    private var pendingInput: [() -> Void] = []
    /// libghostty가 표면을 만들지 못했다.
    public private(set) var failedToStart = false

    private func createSurface(_ launch: Launch, size: NSSize?) {
        guard let app = GhosttyRuntime.shared.app else { failedToStart = true; return }
        let scale = Double(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)

        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque()))
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.scale_factor = scale
        config.font_size = 0
        // 끝나도 표면을 닫지 않는다 — 끊기기 전 마지막 화면을 남겨 둔 채 세션이 재연결을 정한다.
        config.wait_after_command = true
        config.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

        let keys = launch.environment.keys.sorted()
        let cKeys = keys.map { strdup($0) }
        let cValues = keys.map { strdup(launch.environment[$0] ?? "") }
        defer { (cKeys + cValues).forEach { free($0) } }
        var env = zip(cKeys, cValues).map { ghostty_env_var_s(key: $0, value: $1) }

        surface = launch.workingDirectory.withCString { cwd in
            config.working_directory = cwd
            return env.withUnsafeMutableBufferPointer { buffer in
                config.env_vars = buffer.baseAddress
                config.env_var_count = buffer.count
                if let command = launch.command {
                    return command.withCString { cmd in
                        config.command = cmd
                        return ghostty_surface_new(app, &config)
                    }
                }
                return ghostty_surface_new(app, &config)
            }
        }
        guard let surface else { failedToStart = true; return }
        if let config = GhosttyRuntime.shared.config(for: theme) {
            ghostty_surface_update_config(surface, config)
        }
        // 표면은 포커스된 채로 태어난다. 알려 주지 않으면 포커스 없는 패널마다 깜박이는 커서를 그린다(10/31).
        ghostty_surface_set_focus(surface, false)
        // 자식은 입출력 스레드에서 막 뜨는 중이다. 셸이 시작되고 attach가 화면 크기를 읽기 전에 실제 크기를 준다.
        if let size, size.width > 0, size.height > 0 {
            contentSize = size
            ghostty_surface_set_content_scale(surface, scale, scale)
            ghostty_surface_set_size(surface, UInt32(size.width * scale), UInt32(size.height * scale))
        }
        if window != nil {
            updateOcclusion()
            syncFocus()
        }
        let queued = pendingInput
        pendingInput = []
        queued.forEach { $0() }
    }

    /// 창 안에서 크기가 정해졌으면 기다리던 표면을 띄운다. SwiftUI는 한 번의 배치에서 크기를 여러 번
    /// 줄 수 있어, 다음 차례에 그때의 크기로 띄운다.
    private func startIfSized() {
        guard pendingLaunch != nil, window != nil, frame.width > 0, frame.height > 0, !startScheduled else { return }
        startScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self, let launch = self.pendingLaunch else { return }
            self.startScheduled = false
            guard self.window != nil, self.frame.width > 0, self.frame.height > 0 else { return }
            self.pendingLaunch = nil
            self.createSurface(launch, size: self.frame.size)
        }
    }

    private var startScheduled = false

    public required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        keyObservers.forEach(NotificationCenter.default.removeObserver)
        if let surface { ghostty_surface_free(surface) }
    }

    static func from(_ userdata: UnsafeMutableRawPointer?) -> GhosttyTerminalView? {
        guard let userdata else { return nil }
        return Unmanaged<GhosttyTerminalView>.fromOpaque(userdata).takeUnretainedValue()
    }

    // MARK: - 앱 쪽 연결

    /// 색을 바꾼다(외형 전환). 같은 테마의 설정은 런타임이 한 번만 만든다.
    public func setTheme(_ theme: GhosttyTheme) {
        self.theme = theme
        guard let surface, let config = GhosttyRuntime.shared.config(for: theme) else { return }
        ghostty_surface_update_config(surface, config)
    }

    public func focusTerminal() {
        guard isShown else { return }
        window?.makeFirstResponder(self)
    }

    /// 지금 터미널 앞에서 도는 프로세스 그룹의 리더(PTY의 tcgetpgrp). 셸이 작업 제어 없이 명령을 띄우면
    /// 맥에서는 libghostty가 띄운 `login`이다 — 그 그룹에 셸과 에이전트가 함께 있다.
    public var foregroundProcessIdentifier: pid_t? {
        guard let surface else { return nil }
        let pid = ghostty_surface_foreground_pid(surface)
        return pid > 0 ? pid_t(pid) : nil
    }

    /// 띄울 차례를 기다리는 표면도 도는 것으로 친다 — 세션이 그 사이에 다시 띄우지 않게.
    public var isProcessRunning: Bool { (surface != nil || pendingLaunch != nil) && !exited }

    /// 바이트를 그대로 PTY에 쓴다 — 키보드로 친 것과 같다(붙여넣기 괄호도 줄바꿈 변환도 없다).
    /// CLI가 탭에 글자와 특수키를 넣는 길이다(`fine send`·`fine keys`).
    @discardableResult
    public func write(_ data: Data) -> Bool {
        if surface == nil, pendingLaunch != nil, !exited {
            pendingInput.append { [weak self] in self?.write(data) }
            return true
        }
        guard let surface, !exited, !data.isEmpty else { return false }
        let action = Self.textBindingAction(data)
        return action.withUnsafeBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buffer.count) {
                ghostty_surface_binding_action(surface, $0, UInt(buffer.count))
            }
        }
    }

    /// libghostty에는 PTY에 바로 쓰는 C 함수가 없고, `text:` 바인딩 동작이 그 일을 한다(Zig 문자열 문법을
    /// 풀어 그대로 쓴다). 역슬래시와 출력 가능한 ASCII 밖의 바이트는 모두 `\xNN`으로 적어 해석의 여지를 없앤다.
    static func textBindingAction(_ data: Data) -> [UInt8] {
        let hex = Array("0123456789abcdef".utf8)
        var out = Array("text:".utf8)
        out.reserveCapacity(out.count + data.count * 2)
        for byte in data {
            if byte >= 0x20, byte < 0x7f, byte != UInt8(ascii: "\\") {
                out.append(byte)
            } else {
                out += [UInt8(ascii: "\\"), UInt8(ascii: "x"), hex[Int(byte >> 4)], hex[Int(byte & 0x0f)]]
            }
        }
        return out
    }

    /// 화면의 마지막 `lastLines`줄을 평문으로(tmux capture-pane에 해당). 줄 끝 공백과 빈 꼬리 줄은 빼고,
    /// 자동 줄바꿈된 줄은 한 줄로 잇는다. 요청이 지금 화면보다 길면 스크롤백까지 읽는다. 표면이 없으면 nil.
    public func readText(lastLines: Int) -> String? {
        guard let surface else { return nil }
        let rows = Int(ghostty_surface_size(surface).rows)
        let tag = lastLines <= rows ? GHOSTTY_POINT_ACTIVE : GHOSTTY_POINT_SCREEN
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        let whole = text.text.map {
            String(decoding: UnsafeRawBufferPointer(start: $0, count: Int(text.text_len)), as: UTF8.self)
        } ?? ""
        var lines = whole.components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return lines.suffix(max(1, lastLines)).joined(separator: "\n")
    }

    /// 글자를 붙여 넣는다(테스트와 CLI용). 붙여넣기라 셸이 바로 실행하지 않는다 — 실행은 `pressReturn`.
    public func sendText(_ text: String) {
        if surface == nil, pendingLaunch != nil { pendingInput.append { [weak self] in self?.sendText(text) }; return }
        guard let surface, !exited else { return }
        let length = text.utf8CString.count - 1
        text.withCString { ghostty_surface_text(surface, $0, UInt(length)) }
    }

    /// 리턴 키를 누른다.
    public func pressReturn() {
        if surface == nil, pendingLaunch != nil { pendingInput.append { [weak self] in self?.pressReturn() }; return }
        guard let surface, !exited else { return }
        var key = ghostty_input_key_s()
        key.keycode = 36 // kVK_Return
        key.mods = GHOSTTY_MODS_NONE
        key.consumed_mods = GHOSTTY_MODS_NONE
        key.unshifted_codepoint = 13
        key.action = GHOSTTY_ACTION_PRESS
        _ = "\r".withCString { ptr in
            key.text = ptr
            return ghostty_surface_key(surface, key)
        }
        key.text = nil
        key.action = GHOSTTY_ACTION_RELEASE
        _ = ghostty_surface_key(surface, key)
    }

    /// 표면을 닫는다. 자식 프로세스는 PTY가 닫히며 SIGHUP을 받는다 — 무시하는 자식은 살아남는다.
    public func terminate() {
        guard let surface else { return }
        self.surface = nil
        ghostty_surface_free(surface)
    }

    /// 표면을 닫고, 그래도 남은 자식은 SIGTERM, `grace`초 뒤 SIGKILL로 정리한다. Claude Code처럼 SIGHUP을
    /// 무시하는 프로그램을 직접 띄운 터미널은 이것으로 닫는다(ProcessGroupReaper 참고).
    /// `synchronously`: 앱 종료 경로 — 이 스레드에서 끝까지 기다린다.
    public func terminate(reapingAfter grace: TimeInterval, synchronously: Bool = false) {
        guard surface != nil else { return }
        var groups: [pid_t] = []
        if let foreground = foregroundProcessIdentifier {
            groups.append(foreground)
            // 작업 제어가 있는 셸이면 앞 그룹이 에이전트의 그룹이고, 셸·login은 세션 리더의 그룹에 있다.
            let session = getsid(foreground)
            if session > 0 { groups.append(session) }
        }
        let reaper = ProcessGroupReaper.snapshot(groups: groups)
        terminate()
        reaper.reap(grace: grace, synchronous: synchronously)
    }

    func childDidExit(code: Int32) {
        guard !exited else { return }
        exited = true
        onExit?(code)
    }

    func surfaceDidClose() {
        // wait_after_command라 프로세스 종료로는 오지 않는다. 사용자가 끝난 표면에서 키를 눌렀을 때 온다.
        childDidExit(code: 0)
    }

    func setMouseShape(_ shape: ghostty_action_mouse_shape_e) {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_TEXT: NSCursor.iBeam.set()
        case GHOSTTY_MOUSE_SHAPE_POINTER: NSCursor.pointingHand.set()
        default: NSCursor.arrow.set()
        }
    }

    func cellSizeDidChange(width: Double, height: Double) {
        // 화면 밖에서 띄운 표면(뒷탭)도 셀 크기를 알아야 호스트가 자리를 맞춘다. 배율은 표면을 만들 때와 같은 값.
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let size = NSSize(width: width / scale, height: height / scale)
        guard size.width > 0, size.height > 0, size != cellSize else { return }
        cellSize = size
        onCellSize?(size)
    }

    func didRender() {
        let done = pendingPresentation
        pendingPresentation = nil
        done?()
    }

    /// 탭을 바꿀 때 새 표면이 한 장을 그릴 때까지 옛 표면을 덮어 둔다. Metal은 붙자마자 그리므로
    /// 다음 런루프 두 번이면 충분하다(렌더 알림은 단일 스레드 런타임에서만 온다).
    public func prepareForPresentation(_ completion: @escaping () -> Void) {
        pendingPresentation = completion
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.didRender() }
    }

    public func cancelPresentation() {
        pendingPresentation = nil
    }

    // MARK: - 크기와 배율

    public override var acceptsFirstResponder: Bool { true }
    public override var isFlipped: Bool { false }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        contentSize = newSize
        updateSurfaceSize()
        startIfSized()
    }

    private func updateSurfaceSize() {
        guard let surface, contentSize.width > 0, contentSize.height > 0 else { return }
        let backing = convertToBacking(contentSize)
        if backing != lastBackingSize { sizeChanges += 1; lastBackingSize = backing }
        ghostty_surface_set_size(surface, UInt32(backing.width), UInt32(backing.height))
    }

    private var lastBackingSize = NSSize.zero
    /// 표면에 다른 크기를 건넨 횟수. 크기가 바뀔 때마다 PTY가 바뀌고 에이전트가 화면을 다시 그리므로, 배치가
    /// 움직이는 동안 이 수가 늘지 않는지 시험이 본다(sm a115fe5).
    public private(set) var sizeChanges = 0

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()
        }
        guard let surface, frame.width > 0, frame.height > 0 else { return }
        let backing = convertToBacking(frame)
        ghostty_surface_set_content_scale(surface, backing.width / frame.width, backing.height / frame.height)
        updateSurfaceSize()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        keyObservers.forEach(NotificationCenter.default.removeObserver)
        keyObservers = []
        if let window {
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                keyObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                    [weak self] _ in self?.syncFocus()
                })
            }
        }
        guard surface != nil else { startIfSized(); return }
        updateOcclusion()
        if window != nil { viewDidChangeBackingProperties() }
        syncFocus()
    }

    /// 겹쳐 둔 탭 가운데 지금 보이는 탭의 터미널인가. 숨은 탭은 창에 붙어 있어도 그리지 않고, 키를 받지
    /// 않는다 — 탭 전환이 터미널을 떼었다 붙이는 일이 되지 않게 겹쳐 두는데(10/31), 그때 숨은 에이전트에
    /// 글자가 들어가면 안 된다.
    public var isShown = true {
        didSet {
            guard isShown != oldValue else { return }
            // 키를 먼저 놓고 나서 그리기를 멈춘다. 반대로 하면 그리지 않는 채로 포커스가 바뀌어, 다시 보일 때
            // 첫 장면에 그 패널만 비어 보였다(10/31 연속 캡처).
            if !isShown, window?.firstResponder === self { window?.makeFirstResponder(nil) }
            updateOcclusion()
        }
    }

    /// 창에서 떨어졌거나 숨은 표면은 그리지 않는다 — 보이지 않는 탭이 GPU를 쓰지 않게. 다시 보이면 마지막
    /// 장면이 그대로 남아 있다가 다음 프레임부터 이어 그린다(빈 카드가 비치지 않는다).
    private func updateOcclusion() {
        guard let surface else { return }
        ghostty_surface_set_occlusion(surface, window != nil && isShown)
    }

    private var keyObservers: [NSObjectProtocol] = []

    /// 포커스는 "이 창이 앞에 있고, 이 터미널이 키를 받는다"일 때만. 아니면 커서를 그리지 않는다.
    private func syncFocus() {
        guard let surface else { return }
        ghostty_surface_set_focus(surface, window?.isKeyWindow == true && window?.firstResponder === self)
    }

    // MARK: - 포커스

    public override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result, let surface { ghostty_surface_set_focus(surface, window?.isKeyWindow ?? true) }
        return result
    }

    public override func resignFirstResponder() -> Bool {
        // 조합 중에 포커스를 잃으면(탭 전환, 에이전트가 연 탭) 그 글자를 직접 확정해 이 터미널로 보낸다.
        // 입력기도 확정을 보내 주지만 키 이벤트 없이 오면(NSApp.currentEvent == nil) insertText가 버려서
        // 글자가 사라졌다(10/31 제보). 입력기에는 조합을 버리라고 해 두 번 들어가지 않게 한다.
        if markedText.length > 0, keyTextAccumulator == nil {
            let text = markedText.string
            markedText.mutableString.setString("")
            inputContext?.discardMarkedText()
            syncPreedit()
            _ = committedText(GHOSTTY_ACTION_PRESS, text: text)
        }
        let result = super.resignFirstResponder()
        if result, let surface { ghostty_surface_set_focus(surface, false) }
        return result
    }

    private var isFocused: Bool { window?.firstResponder === self }

    // MARK: - 마우스

    public override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func mouseDown(with event: NSEvent) {
        if !isFocused { window?.makeFirstResponder(self) }
        sendButton(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, event)
    }

    public override func mouseUp(with event: NSEvent) {
        sendButton(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, event)
        if let surface { ghostty_surface_mouse_pressure(surface, 0, 0) }
    }

    public override func rightMouseDown(with event: NSEvent) {
        guard let surface,
              ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, Self.mods(event.modifierFlags))
        else { return super.rightMouseDown(with: event) }
    }

    public override func rightMouseUp(with event: NSEvent) {
        guard let surface,
              ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, Self.mods(event.modifierFlags))
        else { return super.rightMouseUp(with: event) }
    }

    public override func otherMouseDown(with event: NSEvent) {
        sendButton(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE, event)
    }

    public override func otherMouseUp(with event: NSEvent) {
        sendButton(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE, event)
    }

    private func sendButton(_ state: ghostty_input_mouse_state_e, _ button: ghostty_input_mouse_button_e, _ event: NSEvent) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(surface, state, button, Self.mods(event.modifierFlags))
    }

    public override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    public override func mouseExited(with event: NSEvent) {
        guard let surface, NSEvent.pressedMouseButtons == 0 else { return }
        // 음수는 커서가 표면 밖이라는 뜻이다.
        ghostty_surface_mouse_pos(surface, -1, -1, Self.mods(event.modifierFlags))
    }

    public override func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, frame.height - point.y, Self.mods(event.modifierFlags))
    }

    public override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    public override func rightMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    public override func otherMouseDragged(with event: NSEvent) { mouseMoved(with: event) }

    public override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precise = event.hasPreciseScrollingDeltas
        if precise {
            // Ghostty와 같은 배율 — 트랙패드는 두 배로 해야 손가락을 따라온다.
            x *= 2
            y *= 2
        }
        var mods: Int32 = precise ? 1 : 0
        mods |= Int32(Self.momentum(event.momentumPhase)) << 1
        ghostty_surface_mouse_scroll(surface, x, y, mods)
    }

    private static func momentum(_ phase: NSEvent.Phase) -> UInt8 {
        switch phase {
        case .began: 1
        case .stationary: 2
        case .changed: 3
        case .ended: 4
        case .cancelled: 5
        case .mayBegin: 6
        default: 0
        }
    }

    // MARK: - 키보드

    public override func keyDown(with event: NSEvent) {
        // 끝난 표면은 키를 받지 않는다 — libghostty는 끝난 표면에서 아무 키나 누르면 닫는다.
        // 재연결하는 동안에도 마지막 화면이 그대로 남아야 한다.
        if exited { return }
        guard let surface else {
            interpretKeyEvents([event])
            return
        }

        // option-as-alt 같은 설정에 따라 글자 해석에 쓸 수정자를 받는다.
        let translated = Self.flags(ghostty_surface_key_translation_mods(surface, Self.mods(event.modifierFlags)))
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if translated.contains(flag) { translationMods.insert(flag) } else { translationMods.remove(flag) }
        }
        // 수정자가 같으면 원래 이벤트를 그대로 써야 한다 — 새로 만들면 한글 조합이 깨진다.
        let translationEvent: NSEvent
        if translationMods == event.modifierFlags {
            translationEvent = event
        } else {
            translationEvent = NSEvent.keyEvent(
                with: event.type, location: event.locationInWindow, modifierFlags: translationMods,
                timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
                characters: event.characters(byApplyingModifiers: translationMods) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat, keyCode: event.keyCode) ?? event
        }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        keyTextAccumulator = []
        imeCommands = []
        defer { keyTextAccumulator = nil; imeCommands = nil }
        let markedTextBefore = markedText.length > 0
        let layoutBefore: String? = markedTextBefore ? nil : Self.keyboardLayoutID
        lastPerformKeyEvent = nil

        interpretKeyEvents([translationEvent])

        // 입력기가 키를 가져가 자판을 바꿨으면 터미널로 보내지 않는다.
        if !markedTextBefore && layoutBefore != Self.keyboardLayoutID { return }

        let composing = markedText.length > 0 || markedTextBefore

        // 조합 중이던 글자가 이 키로 확정됐으면 확정된 글자를 따로 보내고, 그 뒤에도 터미널에
        // 닿아야 하는 키만 다시 보낸다.
        if markedTextBefore, let list = keyTextAccumulator, !list.isEmpty {
            finishCommit(list.filter { !Self.isComposingControl($0, composing: composing) },
                         composing: markedText.string, requested: imeCommands ?? [], action: action,
                         event: event, translationEvent: translationEvent)
            return
        }
        syncPreedit(clearIfNeeded: markedTextBefore)

        if let list = keyTextAccumulator, !list.isEmpty {
            for text in list where !Self.isComposingControl(text, composing: composing) {
                _ = keyAction(action, event: event, translationEvent: translationEvent, text: text)
            }
        } else {
            if Self.isComposingControl(event.characters, composing: composing) { return }
            _ = keyAction(action, event: event, translationEvent: translationEvent,
                          text: Self.ghosttyCharacters(translationEvent), composing: composing)
        }
    }

    public override func keyUp(with event: NSEvent) {
        _ = keyAction(GHOSTTY_ACTION_RELEASE, event: event)
    }

    /// ⌘ 조합은 먼저 메뉴(sm 단축키)로 보낸다. 터미널 바인딩(복사·붙여넣기·전체 선택)과
    /// AppKit이 엉뚱하게 가로채는 ^⏎·^/만 여기서 처리한다.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, isFocused, let surface else { return false }

        var key = Self.keyEvent(event, GHOSTTY_ACTION_PRESS)
        var flags = ghostty_binding_flags_e(0)
        let isBinding = (event.characters ?? "").withCString { ptr in
            key.text = ptr
            return ghostty_surface_key_is_binding(surface, key, &flags)
        }
        if isBinding {
            keyDown(with: event)
            return true
        }

        let equivalent: String
        switch event.charactersIgnoringModifiers {
        case "\r":
            guard event.modifierFlags.contains(.control) else { return false }
            equivalent = "\r"
        case "/":
            // ^/는 맥이 삑 소리를 내므로 ^_로 보낸다.
            guard event.modifierFlags.contains(.control),
                  event.modifierFlags.isDisjoint(with: [.shift, .command, .option]) else { return false }
            equivalent = "_"
        default:
            if event.timestamp == 0 { return false }
            if !event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.control) {
                lastPerformKeyEvent = nil
                return false
            }
            // 메뉴가 처리하지 않고 다시 돌아온 ⌃ 조합(같은 타임스탬프)만 터미널로 보낸다.
            if let last = lastPerformKeyEvent, last == event.timestamp, !event.modifierFlags.contains(.command) {
                lastPerformKeyEvent = nil
                equivalent = event.characters ?? ""
                break
            }
            lastPerformKeyEvent = event.timestamp
            return false
        }

        guard let final = NSEvent.keyEvent(
            with: .keyDown, location: event.locationInWindow, modifierFlags: event.modifierFlags,
            timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
            characters: equivalent, charactersIgnoringModifiers: equivalent,
            isARepeat: event.isARepeat, keyCode: event.keyCode) else { return false }
        keyDown(with: final)
        return true
    }

    public override func flagsChanged(with event: NSEvent) {
        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }
        if hasMarkedText() { return }
        let mods = Self.mods(event.modifierFlags)
        var action = GHOSTTY_ACTION_RELEASE
        if mods.rawValue & mod != 0 {
            let sidePressed: Bool
            switch event.keyCode {
            case 0x3C: sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERSHIFTKEYMASK) != 0
            case 0x3E: sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCTLKEYMASK) != 0
            case 0x3D: sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERALTKEYMASK) != 0
            case 0x36: sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCMDKEYMASK) != 0
            default: sidePressed = true
            }
            if sidePressed { action = GHOSTTY_ACTION_PRESS }
        }
        _ = keyAction(action, event: event)
    }

    public override func doCommand(by selector: Selector) {
        imeCommands?.append(selector)
        // 메뉴가 처리하지 않은 ⌃ 조합을 이벤트 큐로 되돌려 keyDown에서 인코딩되게 한다.
        if let last = lastPerformKeyEvent, let current = NSApp.currentEvent, last == current.timestamp {
            NSApp.sendEvent(current)
        }
    }

    private func keyAction(_ action: ghostty_input_action_e, event: NSEvent, translationEvent: NSEvent? = nil,
                           text: String? = nil, composing: Bool = false) -> Bool {
        guard let surface else { return false }
        var key = Self.keyEvent(event, action, translationMods: translationEvent?.modifierFlags)
        key.composing = composing
        if let text, !text.isEmpty, let first = text.unicodeScalars.first, first.value >= 0x20 {
            return text.withCString { ptr in
                key.text = ptr
                return ghostty_surface_key(surface, key)
            }
        }
        return ghostty_surface_key(surface, key)
    }

    private func committedText(_ action: ghostty_input_action_e, text: String) -> Bool {
        guard let surface else { return false }
        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = 0
        key.composing = false
        key.mods = GHOSTTY_MODS_NONE
        key.consumed_mods = GHOSTTY_MODS_NONE
        key.unshifted_codepoint = 0
        return text.withCString { ptr in
            key.text = ptr
            return ghostty_surface_key(surface, key)
        }
    }

    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        preeditGeneration += 1
        if markedText.length > 0 {
            let text = markedText.string
            let length = text.utf8CString.count
            if length > 0 {
                text.withCString { ghostty_surface_preedit(surface, $0, UInt(length - 1)) }
            }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    // MARK: - NSTextInputClient

    public func hasMarkedText() -> Bool { markedText.length > 0 }

    public func markedRange() -> NSRange {
        markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange()
    }

    public func selectedRange() -> NSRange {
        guard let surface else { return NSRange() }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return NSRange() }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let value as NSAttributedString: markedText = NSMutableAttributedString(attributedString: value)
        case let value as String: markedText = NSMutableAttributedString(string: value)
        default: return
        }
        // 키 이벤트 밖에서 온 조합(자판 전환 등)은 바로 반영한다.
        if keyTextAccumulator == nil { syncPreedit() }
    }

    public func unmarkText() {
        guard markedText.length > 0 else { return }
        markedText.mutableString.setString("")
        // 키 처리 안에서 확정된 경우는 keyDown이 조합 표시를 넘긴다(commitComposition) — 여기서 지우면
        // 확정 글자가 화면에 다시 그려지기 전까지 비어 보인다.
        if keyTextAccumulator == nil { syncPreedit() }
    }

    /// 입력기가 조합을 확정했을 때: 확정 글자(와 새로 조합 중인 글자)를 조합 표시로 잡아 둔 채 PTY로 보낸다.
    /// 엔진(preedit-hold 패치)이 프로그램의 출력으로 커서가 움직인 그 처리 안에서 조합 표시를 새 조합만으로
    /// 바꾼다. 확정 즉시 지우면 프로그램이 입력란을 다시 그릴 때까지(Claude는 수십 ms) 글자가 사라졌다
    /// (10/31 제보 "띄어쓰기 때 이전에 입력하던 한글이 깜빡인다", 확정마다 26–44ms 빈 칸).
    /// `composing`: 이 키로 새로 시작된 조합(없으면 "") — 확정 글자가 그려진 뒤에도 남을 조합 표시.
    func commitComposition(_ texts: [String], composing after: String,
                           action: ghostty_input_action_e = GHOSTTY_ACTION_PRESS) {
        guard let surface else { return }
        if markedText.string != after { markedText = NSMutableAttributedString(string: after) }
        let display = texts.joined() + after
        display.withCString { displayPtr in
            after.withCString { afterPtr in
                ghostty_surface_preedit_hold(surface, displayPtr, UInt(display.utf8.count), afterPtr, UInt(after.utf8.count))
            }
        }
        preeditGeneration += 1
        let generation = preeditGeneration
        for text in texts { _ = committedText(action, text: text) }
        // 프로그램이 확정 글자를 되돌려 그리지 않으면(커서가 안 움직이면) 잡아 둔 것을 거둔다.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.preeditGeneration == generation else { return }
            self.syncPreedit()
        }
    }

    private var preeditGeneration = 0
    /// keyDown 안에서만 non-nil. 입력기가 이 키로 앱에 요청한 명령(뒤로 지우기, 줄 바꾸기 등).
    private var imeCommands: [Selector]?

    /// 입력기가 이 키로 조합을 확정했을 때. 두벌식은 조합 중 마지막 자모를 지울 때 그 자모를 확정하고
    /// 뒤로 지우기를 요청한다(insertText "ㄱ" + deleteBackward:, 10/31 입력 기록). 다른 앱은 확정한 글자에
    /// 그 명령을 적용해 지워지는데, 확정 글자만 보내고 요청을 버리면 "ㄱ"이 입력란에 남아 지우기를 한 번 더
    /// 눌러야 했다(10/31 제보). 그래서 입력기가 명령을 요청했으면 확정 글자 뒤에 그 키도 터미널로 보낸다.
    /// 이때는 잡아 두지 않는다 — 그 키가 방금 글자를 바로 지우거나 줄을 넘긴다.
    func finishCommit(_ texts: [String], composing after: String, requested: [Selector],
                      action: ghostty_input_action_e, event: NSEvent, translationEvent: NSEvent) {
        guard Self.shouldReplayAfterCommit(translationEvent) || Self.imeRequestedKey(requested, event: translationEvent) else {
            commitComposition(texts, composing: after, action: action)
            return
        }
        if markedText.string != after { markedText = NSMutableAttributedString(string: after) }
        syncPreedit()
        for text in texts { _ = committedText(action, text: text) }
        _ = keyAction(action, event: event, translationEvent: translationEvent, composing: false)
    }

    /// 입력기가 확정과 함께 이 키의 명령을 요청했는가. 맨 왼쪽 화살표는 입력기가 이미 커서를 두므로 뺀다
    /// (shouldReplayAfterCommit과 같은 이유).
    static func imeRequestedKey(_ requested: [Selector], event: NSEvent) -> Bool {
        guard !requested.isEmpty else { return false }
        if event.keyCode == 123, event.modifierFlags.isDisjoint(with: [.shift, .control, .option, .command]) { return false }
        return true
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    public func characterIndex(for point: NSPoint) -> Int { 0 }

    /// 조합 창(한글 후보 등)이 뜰 자리 — 커서 셀.
    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface else { return NSRect(origin: frame.origin, size: .zero) }
        var x = 0.0, y = 0.0
        var width = Double(cellSize.width), height = Double(cellSize.height)
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        if range.length == 0, width > 0 {
            width = 0
            x += Double(cellSize.width) * Double(range.location + range.length)
        }
        let viewRect = NSRect(x: x, y: frame.height - y, width: width, height: max(height, Double(cellSize.height)))
        let windowRect = convert(viewRect, to: nil)
        return window?.convertToScreen(windowRect) ?? windowRect
    }

    public func insertText(_ string: Any, replacementRange: NSRange) {
        guard NSApp.currentEvent != nil else { return }
        let chars: String
        switch string {
        case let value as NSAttributedString: chars = value.string
        case let value as String: chars = value
        default: return
        }
        unmarkText()
        if var accumulator = keyTextAccumulator {
            accumulator.append(chars)
            keyTextAccumulator = accumulator
            return
        }
        // IME·받아쓰기가 확정한 글자는 붙여넣기가 아니라 친 글자로 보낸다.
        if !chars.isEmpty { _ = committedText(GHOSTTY_ACTION_PRESS, text: chars) }
    }

    // MARK: - 변환 도우미

    static func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
        let raw = flags.rawValue
        if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        return ghostty_input_mods_e(mods)
    }

    static func flags(_ mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var flags = NSEvent.ModifierFlags()
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
        return flags
    }

    static func keyEvent(_ event: NSEvent, _ action: ghostty_input_action_e,
                         translationMods: NSEvent.ModifierFlags? = nil) -> ghostty_input_key_s {
        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = UInt32(event.keyCode)
        key.text = nil
        key.composing = false
        key.mods = mods(event.modifierFlags)
        // ⌃·⌘은 글자를 만드는 데 쓰이지 않는다고 본다(Ghostty의 오래된 규칙).
        key.consumed_mods = mods((translationMods ?? event.modifierFlags).subtracting([.control, .command]))
        key.unshifted_codepoint = 0
        if event.type == .keyDown || event.type == .keyUp,
           let chars = event.characters(byApplyingModifiers: []), let scalar = chars.unicodeScalars.first {
            key.unshifted_codepoint = scalar.value
        }
        return key
    }

    /// 제어 문자는 Ghostty가 직접 인코딩하므로 ⌃ 없는 글자로, 기능키(PUA)는 보내지 않는다.
    static func ghosttyCharacters(_ event: NSEvent) -> String? {
        guard let characters = event.characters else { return nil }
        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 { return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control)) }
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF { return nil }
        }
        return characters
    }

    /// 조합 중에 들어온 제어 문자 하나는 입력기 몫이다.
    static func isComposingControl(_ text: String?, composing: Bool) -> Bool {
        guard composing, let text else { return false }
        let scalars = text.unicodeScalars
        guard let first = scalars.first, scalars.index(after: scalars.startIndex) == scalars.endIndex else { return false }
        return first.value < 0x20
    }

    /// 조합이 확정된 뒤에도 터미널에 닿아야 하는 키. 맨 왼쪽 화살표는 한글 입력기가 이미 커서를 두므로 뺀다.
    static func shouldReplayAfterCommit(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 125, 124, 126: return true // 아래, 오른쪽, 위
        case 123: return !event.modifierFlags.isDisjoint(with: [.shift, .control, .option, .command])
        default: return false
        }
    }

    static var keyboardLayoutID: String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }
}
