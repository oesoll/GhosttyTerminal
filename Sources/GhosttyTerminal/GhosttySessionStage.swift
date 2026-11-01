import AppKit
import QuartzCore

/// 세션 화면의 무대: 쉬는 세션은 마지막 장면 위에 어두운 막을 얹어 보이고, 깨는 동안에는 막이 숨쉬며,
/// 새 표면이 화면을 다 채우고 조용해지면 막과 장면을 함께 걷어 낸다. 그동안 친 키는 붙잡았다가 그때 넘긴다.
///
/// 장면은 따로 찍은 그림이 아니라 끝난(또는 자식을 내린) 옛 표면 그 자체다 — 표면은 자식이 끝나도 마지막
/// 화면을 남긴다(`wait_after_command`). 새 표면은 그 아래에 깔려 보이지 않는 채로 그린다. 그래서 에이전트가
/// 다시 뜨며 화면을 채우는 순간(끊기는 듯 보이던 0.x초)은 끝까지 보이지 않는다.
///
/// 호스트는 표면을 직접 두던 자리에 이 무대를 두고, 표면을 만들어 건넨다(`show`·`attach`). 언제 덮고 언제
/// 걷을지는 호스트가 세션 상태(`sm-session state`)를 보고 정한다:
/// 쉬거나 멈춤 → `freeze(look: .dimmed)`, 깨는 중 → `attach(새 표면)` + `setLook(.waking)`,
/// 준비됨 → `revealWhenQuiet()`.
public final class GhosttySessionStage: NSView {
    /// 덮개의 모습.
    public enum Look: Equatable {
        /// 막 없이 장면만 — 깨어 있는 세션에 다시 붙을 때. 같은 화면이 이어지므로 덮인 줄 모른다.
        case clear
        /// 어두운 막 — 쉬는 중·멈춤. 움직이지 않는다.
        case dimmed
        /// 막이 숨쉰다 — 깨는 중.
        case waking
    }

    /// 지금 입력과 쓰기를 받는(또는 걷히면 받을) 표면. 깨는 동안에는 장면 아래의 새 표면이다.
    public private(set) var live: GhosttyTerminalView?
    /// 덮고 있는 마지막 장면. 없으면 덮개는 빈 바탕 위의 막이다.
    public private(set) var scene: GhosttyTerminalView?
    /// 덮여 있는가(키는 무대가 붙잡는다).
    public private(set) var isCovered = false
    public private(set) var look: Look = .clear

    /// 쉬는 막(`.dimmed`) 아래에서 친 키마다. 멈춘 세션은 이것을 신호로 깨운다(키는 버리지 않고 걷힐 때 넘긴다).
    public var onKeyWhileResting: (() -> Void)?
    /// 걷어 낸 뒤(새 표면이 키를 받기 시작한 뒤).
    public var onReveal: (() -> Void)?
    /// 더는 쓰지 않는 표면을 치운다. 기본은 표면을 닫는 것 — 남은 자식 정리 방식은 호스트가 정한다.
    public var dispose: (GhosttyTerminalView) -> Void = { $0.terminate() }

    /// 막 아래쪽 가운데의 짧은 글(예: "멈춤 · 아무 키나 누르면 깨어납니다"). nil이면 없다.
    public var caption: String? {
        didSet { shield.caption.stringValue = caption ?? ""; shield.caption.isHidden = caption == nil; applyCaption() }
    }
    /// 글의 아래 여백. 호스트가 표면 아래쪽을 잘라 보이면(Fine의 꼬리 줄 가리기) 그만큼 올린다.
    public var captionBottomInset: CGFloat = 14 { didSet { needsLayout = true } }
    /// 막의 짙기를 고르는 기준(밝은 테마는 옅게).
    public var theme: GhosttyTheme = .fallback {
        didSet {
            glow.accent = (accent ?? Self.defaultAccent(dark: theme.isDark)).cgColor
            if isCovered { applyLook(animated: false) }
        }
    }
    /// 깨는 동안 가장자리를 도는 빛의 색. 없으면 sm의 강조색(warmPink) — 강조색은 "무언가 돌고 있다"는
    /// 활동 표시에만 쓴다는 sm의 원칙에 깨어나는 중이 꼭 맞는다.
    public var accent: NSColor? {
        didSet { glow.accent = (accent ?? Self.defaultAccent(dark: theme.isDark)).cgColor }
    }

    static func defaultAccent(dark: Bool) -> NSColor {
        dark ? NSColor(srgbRed: 0xf2 / 255.0, green: 0x73 / 255.0, blue: 0x80 / 255.0, alpha: 1)
             : NSColor(srgbRed: 0xc8 / 255.0, green: 0x48 / 255.0, blue: 0x5a / 255.0, alpha: 1)
    }

    private let veil = NSView()
    private let glow = WakeGlow()
    private let shield = Shield()
    private var heldKeys: [NSEvent] = []
    private var quietTimer: Timer?
    /// 덮개가 바뀔 때마다 늘어, 늦게 끝난 걷기 애니메이션이 새 덮개를 치우지 않게 한다.
    private var generation = 0

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        veil.wantsLayer = true
        veil.layer?.backgroundColor = NSColor.black.cgColor
        veil.layer?.opacity = 0
        veil.isHidden = true
        shield.stage = self
        shield.isHidden = true
        addSubview(veil)
        addSubview(glow)
        addSubview(shield)
    }

    public required init?(coder: NSCoder) { fatalError("not supported") }

    public override var isFlipped: Bool { true }

    // MARK: - 표면 바꾸기

    /// 이 표면을 바로 보인다(덮개 없음). 있던 표면·장면은 치운다.
    public func show(_ view: GhosttyTerminalView) {
        generation += 1
        stopQuietWatch()
        [scene, live].compactMap { $0 }.filter { $0 !== view }.forEach(discard)
        scene = nil
        place(view, below: veil)
        live = view
        uncover()
    }

    /// 표면도 장면도 덮개도 없앤다(탭을 닫거나 다른 앱으로 옮길 때).
    public func clear() {
        generation += 1
        stopQuietWatch()
        [scene, live].compactMap { $0 }.forEach(discard)
        scene = nil
        live = nil
        caption = nil
        uncover()
    }

    /// 보일 화면이 있는가(덮개의 장면이든 지금 표면이든).
    public var hasFrame: Bool { scene != nil || live != nil }

    /// 지금 표면을 마지막 장면으로 얼린다. 그 표면의 자식은 호스트가 이미 내렸거나 곧 내린다.
    /// 지금 표면이 없으면 빈 바탕 위에 막만 얹는다.
    public func freeze(look: Look = .dimmed) {
        generation += 1
        stopQuietWatch()
        if let live, live !== scene {
            if let scene { discard(scene) }
            scene = live
        }
        live = nil
        cover(look: look)
    }

    /// 앱을 다시 켜서 마지막 프레임이 없을 때: 세션 층이 남긴 마지막 화면 바이트(`sm-session screen`)를 숨은
    /// 표면에 먹여 장면을 만든다. 크기는 무대 크기 — 원래 크기와 같아야 그대로 그려진다.
    public func freeze(replaying screen: Data, look: Look = .dimmed) {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty-scene-\(UUID().uuidString).bin")
        guard (try? screen.write(to: file)) != nil else { return freeze(look: look) }
        // cat이 다 읽은 뒤 지운다. 끝난 표면은 화면을 남긴다(wait_after_command).
        let command = "/bin/sh -c 'cat \"$1\"; rm -f \"$1\"' scene " + GhosttySessionStage.shellQuoted(file.path)
        let size = bounds.width > 0 && bounds.height > 0 ? bounds.size : NSSize(width: 800, height: 600)
        let replay = GhosttyTerminalView(launch: .init(command: command, workingDirectory: NSTemporaryDirectory()),
                                         theme: theme, initialSize: size)
        freeze(look: look)
        if let scene { discard(scene) }
        place(replay, below: veil)
        scene = replay
    }

    /// 새 표면을 장면 아래에 깐다. 키는 계속 무대가 붙잡고, CLI 쓰기·읽기는 이 표면이 받는다.
    public func attach(_ view: GhosttyTerminalView) {
        generation += 1
        stopQuietWatch()
        if let live, live !== view, live !== scene { discard(live) }
        if let scene {
            place(view, below: scene)
        } else {
            place(view, below: veil)
        }
        live = view
        if !isCovered { cover(look: look) }
    }

    /// 깨우기를 거둔다(깨는 동안 누가 멈춤): 새 표면을 치우고 장면 + 어두운 막으로 돌아간다.
    public func cancelAttach() {
        generation += 1
        stopQuietWatch()
        if let live, live !== scene { discard(live) }
        live = nil
        setLook(.dimmed)
    }

    public func setLook(_ look: Look) {
        guard isCovered else { self.look = look; return }
        guard look != self.look else { return }
        self.look = look
        applyLook(animated: true)
    }

    // MARK: - 걷기

    /// 새 표면이 `quiet`초 동안 화면을 바꾸지 않으면 걷는다(에이전트가 화면을 다 채웠다). 세션 층이 준비됐다고
    /// 알린 뒤에, 또는 원격 탭이 다시 연결되기 시작할 때(그동안은 물을 곳이 없다 — 앱이 정한다) 부른다.
    /// 끝없이 바뀌는 화면(진행 표시)도 첫 출력부터 `limit`초면 걷는다. 출력이 아직 하나도 없으면(연결 중)
    /// `patience`초까지 기다린다 — 연결이 늦다고 빈 화면을 드러내지 않게.
    public func revealWhenQuiet(after quiet: TimeInterval = 0.25, limit: TimeInterval = 3,
                                patience: TimeInterval = 30) {
        guard isCovered, live != nil else { return }
        stopQuietWatch()
        let started = Date()
        var firstOutput: Date?
        var lastText: String?
        var lastChange = started
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let live = self.live else { return }
                let now = Date()
                let text = live.readText(lastLines: 400)
                if text != lastText { lastText = text; lastChange = now }
                let hasOutput = text?.isEmpty == false
                if hasOutput, firstOutput == nil { firstOutput = now }
                let settled = hasOutput && now.timeIntervalSince(lastChange) >= quiet
                let tooLong = firstOutput.map { now.timeIntervalSince($0) >= limit } ?? false
                if settled || tooLong || now.timeIntervalSince(started) >= patience { self.reveal() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        quietTimer = timer
    }

    /// 지금 걷는다. 장면과 막이 함께 옅어지고, 붙잡은 키를 순서대로 새 표면에 넘긴다.
    public func reveal(animated: Bool = true) {
        guard isCovered, let live else { return }
        stopQuietWatch()
        generation += 1
        let token = generation
        isCovered = false
        look = .clear
        shield.isHidden = true
        let tookKeys = window?.firstResponder === self || window?.firstResponder === shield
        if tookKeys || !heldKeys.isEmpty { live.focusTerminal() }
        let keys = heldKeys
        heldKeys = []
        keys.forEach { live.keyDown(with: $0) }

        let leaving = scene
        scene = nil
        let finish = { [weak self] in
            guard let self else { return }
            // 떠나던 장면은 그 사이 다시 덮였어도 치운다(새 덮개는 자기 장면을 따로 갖는다).
            if let leaving, leaving !== self.scene, leaving !== self.live { self.discard(leaving) }
            if self.generation == token { self.veil.isHidden = true }
        }
        veil.layer?.removeAllAnimations()
        guard animated, window != nil, !Self.reduceMotion || leaving != nil else {
            veil.layer?.opacity = 0
            glow.stop()
            finish()
            onReveal?()
            return
        }
        let duration = Self.reduceMotion ? 0.2 : 0.35
        let curve = Self.reduceMotion ? CAMediaTimingFunction(name: .linear)
                                      : CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
        // 장면과 막을 같은 곡선으로 함께 옅게 한다. AppKit의 animator()는 Ghostty 표면에서 애니메이션 없이 바로
        // 적용되고 완료도 곧바로 불러, 막이 한 프레임에 사라졌다(11/01 프레임 측정) — 그래서 레이어에 직접 건다.
        fade(veil.layer, to: 0, duration: duration, curve: curve)
        if let leaving {
            leaving.wantsLayer = true
            fade(leaving.layer, to: 0, duration: duration, curve: curve)
        }
        // 빛은 막보다 천천히, 돌던 채로 옅어진다.
        glow.withdraw(duration: Self.reduceMotion ? 0.2 : 0.9)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05) { finish() }
        onReveal?()
    }

    /// 키를 받을 곳으로 포커스를 옮긴다 — 덮였으면 무대가(붙잡으려고), 아니면 표면이.
    public func focus() {
        if isCovered { window?.makeFirstResponder(self) } else { live?.focusTerminal() }
    }

    // MARK: - 붙잡은 키

    public override var acceptsFirstResponder: Bool { isCovered }

    public override func keyDown(with event: NSEvent) {
        guard isCovered else { return super.keyDown(with: event) }
        heldKeys.append(event)
        if look == .dimmed { onKeyWhileResting?() }
    }

    /// 붙잡은 키 수(시험용).
    public var heldKeyCount: Int { heldKeys.count }

    // MARK: - 덮개

    private func cover(look: Look) {
        let wasCovered = isCovered
        isCovered = true
        self.look = look
        veil.isHidden = false
        shield.isHidden = false
        if let scene { scene.alphaValue = 1; scene.isShown = true }
        addSubview(veil, positioned: .above, relativeTo: nil)
        addSubview(glow, positioned: .above, relativeTo: nil)
        addSubview(shield, positioned: .above, relativeTo: nil)
        applyCaption()
        applyLook(animated: wasCovered || window != nil)
        if let window, let responder = window.firstResponder as? NSView, responder === live || responder === scene {
            window.makeFirstResponder(self)
        }
    }

    private func uncover() {
        isCovered = false
        look = .clear
        heldKeys = []
        veil.layer?.removeAllAnimations()
        veil.layer?.opacity = 0
        veil.isHidden = true
        glow.stop()
        shield.isHidden = true
    }

    /// 쉬는 막의 짙기. 어두운 테마는 글자가 가라앉아 보일 만큼, 밝은 테마는 회색으로 무너지지 않을 만큼.
    var dimOpacity: Float { theme.isDark ? 0.46 : 0.26 }

    private func applyLook(animated: Bool) {
        guard let layer = veil.layer else { return }
        let target: Float = look == .clear ? 0 : dimOpacity
        fade(layer, to: target, duration: animated ? 0.25 : 0, curve: CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1))
        // 깨는 동안: 가장자리에 강조색 빛이 맺혀 천천히 돌고, 가장자리 쪽에 옅은 점 격자가 비친다.
        if look == .waking { glow.seepIn(animated: animated) } else { glow.withdraw(duration: animated ? 0.3 : 0) }
    }

    /// 지금 보이는 값에서 출발해 옮긴다 — 도중에 바뀌어도 튀지 않는다.
    private func fade(_ layer: CALayer?, to value: Float, duration: CFTimeInterval, curve: CAMediaTimingFunction) {
        guard let layer else { return }
        let current = layer.presentation()?.opacity ?? layer.opacity
        layer.removeAnimation(forKey: "fade")
        layer.opacity = value
        guard duration > 0, current != value else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = current
        animation.toValue = value
        animation.duration = duration
        animation.timingFunction = curve
        layer.add(animation, forKey: "fade")
    }

    private func applyCaption() {
        shield.caption.textColor = NSColor.white.withAlphaComponent(0.78)
        needsLayout = true
    }

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    static func alphaImageForTests(_ bytes: [UInt8], width: Int, height: Int) -> CGImage? {
        WakeGlow.alphaImage(bytes, width: width, height: height)
    }

    // MARK: - 배치

    public override func layout() {
        super.layout()
        for view in [scene, live].compactMap({ $0 }) where view.frame != bounds { view.frame = bounds }
        veil.frame = bounds
        glow.frame = bounds
        shield.frame = bounds
        let label = shield.caption
        let size = label.intrinsicContentSize
        label.frame = NSRect(x: (bounds.width - size.width) / 2, y: bounds.height - captionBottomInset - size.height,
                             width: size.width, height: size.height)
    }

    private func place(_ view: GhosttyTerminalView, below other: NSView) {
        view.frame = bounds
        view.alphaValue = 1
        view.isShown = true
        if view.superview !== self { addSubview(view, positioned: .below, relativeTo: other) }
        else { addSubview(view, positioned: .below, relativeTo: other) }
    }

    private func discard(_ view: GhosttyTerminalView) {
        if window?.firstResponder === view { window?.makeFirstResponder(self) }
        view.removeFromSuperview()
        dispose(view)
    }

    private func stopQuietWatch() {
        quietTimer?.invalidate()
        quietTimer = nil
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 덮인 동안 장면 위에서 마우스를 받는다 — 끝난 표면이 선택·스크롤을 받지 않게, 누르면 무대가 키를 받게.
    private final class Shield: NSView {
        weak var stage: GhosttySessionStage?
        let caption: NSTextField = {
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 11.5, weight: .medium)
            label.alignment = .center
            label.isHidden = true
            return label
        }()

        override init(frame: NSRect) {
            super.init(frame: frame)
            addSubview(caption)
        }

        required init?(coder: NSCoder) { fatalError("not supported") }

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { isHidden ? nil : (frame.contains(point) ? self : nil) }
        override func mouseDown(with event: NSEvent) { stage?.focus() }
        override func rightMouseDown(with event: NSEvent) { stage?.focus() }
        override func scrollWheel(with event: NSEvent) {}
        override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
    }
}

/// 깨는 중의 가장자리 효과. ego lite·Codex가 브라우저를 잡을 때의 가장자리 빛을 참고만 했고(SEOL 11/01),
/// 우리 앱 식으로 다시 만들었다: 색은 sm의 강조색, 세기는 은은하게, 숨쉬는 대신 빛의 밝은 자리가 가장자리를
/// 따라 천천히(한 바퀴 9초) 돈다. 가장자리 쪽에만 아주 옅은 점 격자가 비친다.
///
/// 구성: 가장자리 띠 모양의 가림막(안쪽 약 80pt에서 사라짐, 모서리가 진함)을 쓴 그릇 안에서, 원뿔 그라데이션
/// (밝은 호 둘 — 하나는 진하고 하나는 옅다)이 돈다. 그릇은 돌지 않으므로 빛은 늘 테두리 위에만 맺힌다.
/// 모든 전환은 보이는 값에서 출발한다 — 끊기거나 튀는 순간이 없어야 한다.
private final class WakeGlow: NSView {
    var accent: CGColor = GhosttySessionStage.defaultAccent(dark: true).cgColor {
        didSet { applyAccent() }
    }
    private let orbit = CALayer()
    private let orbitMask = CALayer()
    private let light = CAGradientLayer()
    private let dotsLayer = CALayer()
    private let dotsMask = CALayer()
    private var rendered: (size: CGSize, scale: CGFloat)?
    private var active = false
    private var withdrawToken = 0
    static let turn: CFTimeInterval = 9

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        isHidden = true
        dotsLayer.backgroundColor = CGColor(gray: 1, alpha: 1)
        dotsLayer.mask = dotsMask
        orbit.mask = orbitMask
        light.type = .conic
        light.startPoint = CGPoint(x: 0.5, y: 0.5)
        light.endPoint = CGPoint(x: 0.5, y: 0)
        orbit.addSublayer(light)
        for mask in [orbitMask, dotsMask] {
            mask.contentsGravity = .resize
            mask.minificationFilter = .linear
            mask.magnificationFilter = .linear
        }
        dotsMask.magnificationFilter = .nearest
        for layer in [dotsLayer, orbit] {
            layer.opacity = 0
            self.layer?.addSublayer(layer)
        }
        applyAccent()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// 밝은 호 둘: 진한 것(0.55)과 맞은편의 옅은 것(0.28). 그 사이에도 아주 옅은 빛(0.08)이 깔려 테두리가 끊기지
    /// 않는다. 첫 색과 끝 색이 같아 이음매가 없다.
    private func applyAccent() {
        let tone = { (alpha: CGFloat) in self.accent.copy(alpha: alpha) ?? self.accent }
        light.colors = [0.08, 0.08, 0.55, 0.08, 0.08, 0.28, 0.08, 0.08].map(tone)
        light.locations = [0, 0.04, 0.17, 0.32, 0.56, 0.68, 0.82, 1]
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [orbit, orbitMask, dotsLayer, dotsMask] { layer.frame = bounds }
        // 도는 원뿔은 대각선 길이의 정사각형이라 어느 각도에서도 그릇을 덮는다.
        let side = hypot(bounds.width, bounds.height)
        light.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        light.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
        if active { renderIfNeeded() }
    }

    /// 맺힌다: 천천히 시작해 부드럽게 멈추며 들어오고(0.7초), 빛은 처음부터 돌고 있다.
    func seepIn(animated: Bool) {
        withdrawToken += 1
        active = true
        isHidden = false
        renderIfNeeded()
        let entry = animated ? 0.7 : 0
        let ease = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
        fade(dotsLayer, to: 1, duration: entry, curve: ease)
        fade(orbit, to: 1, duration: entry, curve: ease)
        guard !GhosttySessionStage.reduceMotion, light.animation(forKey: "turn") == nil else { return }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = -2 * Double.pi   // 시계 방향
        turn.duration = Self.turn
        turn.repeatCount = .infinity
        turn.timingFunction = CAMediaTimingFunction(name: .linear)
        light.add(turn, forKey: "turn")
    }

    /// 옅어진다: 지금 보이는 세기에서 0으로. 도는 것은 멈추지 않는다(멈추는 순간이 튀어 보인다).
    func withdraw(duration: CFTimeInterval) {
        guard active else { return }
        active = false
        withdrawToken += 1
        let token = withdrawToken
        let curve = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
        fade(dotsLayer, to: 0, duration: min(duration, 0.4), curve: curve)
        fade(orbit, to: 0, duration: duration, curve: curve)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05) { [weak self] in
            guard let self, self.withdrawToken == token else { return }
            self.stop()
        }
    }

    /// 바로 치운다(그림도 버린다).
    func stop() {
        active = false
        withdrawToken += 1
        for layer in [orbit, dotsLayer] { layer.removeAllAnimations(); layer.opacity = 0 }
        light.removeAllAnimations()
        dotsMask.contents = nil
        orbitMask.contents = nil
        rendered = nil
        isHidden = true
    }

    private func fade(_ layer: CALayer, to value: Float, duration: CFTimeInterval, curve: CAMediaTimingFunction) {
        let current = layer.presentation()?.opacity ?? layer.opacity
        layer.removeAnimation(forKey: "fade")
        layer.opacity = value
        guard duration > 0, abs(current - value) > 0.001 else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = current
        animation.toValue = value
        animation.duration = duration
        animation.timingFunction = curve
        layer.add(animation, forKey: "fade")
    }

    // MARK: - 그림

    private func renderIfNeeded() {
        let size = bounds.size
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        guard size.width > 1, size.height > 1 else { return }
        if let rendered, rendered.size == size, rendered.scale == scale { return }
        rendered = (size, scale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dotsMask.contents = Self.dotGrid(size: size, scale: scale)
        dotsMask.contentsScale = scale
        orbitMask.contents = Self.edgeFalloff(size: size, step: 6)
        CATransaction.commit()
    }

    /// 가장자리까지의 거리 d(포인트)에서 0…1. 두 축을 스크린 합성해 모서리가 진하다.
    static func edge(x: CGFloat, y: CGFloat, size: CGSize, reach: CGFloat, power: CGFloat) -> CGFloat {
        func one(_ d: CGFloat) -> CGFloat {
            let t = max(0, min(1, d / reach))
            let smooth = t * t * (3 - 2 * t)
            return pow(1 - smooth, power)
        }
        let ex = one(min(x, size.width - x)), ey = one(min(y, size.height - y))
        return 1 - (1 - ex) * (1 - ey)
    }

    /// 빛의 가림막: 가장자리 1.0 → 안쪽 약 80pt에서 0.
    static func edgeFalloff(size: CGSize, step: CGFloat) -> CGImage? {
        let width = max(2, Int((size.width / step).rounded(.up))), height = max(2, Int((size.height / step).rounded(.up)))
        var bytes = [UInt8](repeating: 0, count: width * height)
        for row in 0..<height {
            for column in 0..<width {
                let x = (CGFloat(column) + 0.5) * size.width / CGFloat(width)
                let y = (CGFloat(row) + 0.5) * size.height / CGFloat(height)
                bytes[row * width + column] = UInt8(255 * edge(x: x, y: y, size: size, reach: 80, power: 1.7))
            }
        }
        return alphaImage(bytes, width: width, height: height)
    }

    /// 점 격자: 점 1.5pt, 간격 8pt, 화면 배율 그대로. 가장자리 쪽에만 옅게(최대 0.26) — 가운데는 비운다.
    static func dotGrid(size: CGSize, scale: CGFloat) -> CGImage? {
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        guard width > 0, height > 0 else { return nil }
        let spacing = 8 * scale, dot = max(1, Int((1.5 * scale).rounded()))
        var bytes = [UInt8](repeating: 0, count: width * height)
        var y = (spacing - CGFloat(dot)) / 2
        while Int(y) + dot <= height {
            var x = (spacing - CGFloat(dot)) / 2
            while Int(x) + dot <= width {
                let strength = 0.26 * edge(x: x / scale, y: y / scale, size: size, reach: 160, power: 1.4)
                let value = UInt8(255 * strength)
                for dy in 0..<dot {
                    let base = (Int(y) + dy) * width + Int(x)
                    for dx in 0..<dot { bytes[base + dx] = value }
                }
                x += spacing
            }
            y += spacing
        }
        return alphaImage(bytes, width: width, height: height)
    }

    /// 가림막으로 쓸 그림(알파가 값). 알파만 있는 그림은 회색 색공간으로 만들 수 없어(nil) 회색+알파로 만든다.
    static func alphaImage(_ bytes: [UInt8], width: Int, height: Int) -> CGImage? {
        var pixels = [UInt8](repeating: 0, count: width * height * 2)
        for index in 0..<bytes.count {
            pixels[index * 2] = bytes[index]       // 미리 곱한 흰색
            pixels[index * 2 + 1] = bytes[index]
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 16, bytesPerRow: width * 2,
                       space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

extension GhosttyTerminalView {
    /// 표면은 남기고 자식만 끝낸다 — 마지막 화면이 그대로 남아 멈춘 장면이 된다. 가려진 탭에서 세션을 보던
    /// `sm-session attach`를 내릴 때 쓴다(에이전트는 다른 프로세스 그룹이라 함께 끝나지 않는다).
    public func endProcess(_ signal: Int32 = SIGHUP) {
        guard let leader = foregroundProcessIdentifier else { return }
        kill(-leader, signal)
        kill(leader, signal)
    }
}
