import AppKit
import AVFoundation

private enum DefaultsKey {
    static let message = "message"
    static let intervalMinutes = "intervalMinutes"
    static let isPaused = "isPaused"
    static let playSound = "playSound"
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let nextItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "", action: #selector(togglePause), keyEquivalent: "")
    private let soundItem = NSMenuItem(title: "", action: #selector(toggleSound), keyEquivalent: "")
    private var controlPanel: ControlPanel?
    private var flightWindow: FlightWindow?
    private var flybyPlayer: AVAudioPlayer?
    private var reminderTimer: Timer?
    private var clockTimer: Timer?
    private var nextReminderDate = Date()
    private var isPaused = UserDefaults.standard.bool(forKey: DefaultsKey.isPaused)

    private var message: String {
        get {
            let saved = UserDefaults.standard.string(forKey: DefaultsKey.message) ?? ""
            return saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "该喝水啦" : saved
        }
        set {
            UserDefaults.standard.set(newValue, forKey: DefaultsKey.message)
        }
    }

    private var intervalMinutes: Double {
        get {
            let saved = UserDefaults.standard.double(forKey: DefaultsKey.intervalMinutes)
            return saved > 0 ? saved : 45
        }
        set {
            UserDefaults.standard.set(max(1, newValue), forKey: DefaultsKey.intervalMinutes)
        }
    }

    private var playSound: Bool {
        get {
            if UserDefaults.standard.object(forKey: DefaultsKey.playSound) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: DefaultsKey.playSound)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: DefaultsKey.playSound)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ProcessInfo.processInfo.disableAutomaticTermination("Airmessage keeps reminder timers running.")
        NSApp.setActivationPolicy(.regular)
        setupMenu()
        scheduleNextReminder(from: Date())
        startClock()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            showFlight(message: message)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "✈︎ Air"
        statusItem.button?.toolTip = "Airmessage"
        statusItem.menu = menu

        menu.addItem(NSMenuItem(title: "Airmessage", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(nextItem)
        menu.addItem(makeMenuItem(title: "打开控制面板", action: #selector(showControlPanel), keyEquivalent: "o"))
        menu.addItem(makeMenuItem(title: "现在试飞", action: #selector(showReminderNow), keyEquivalent: "r"))
        menu.addItem(pauseItem)
        menu.addItem(.separator())
        menu.addItem(makeMenuItem(title: "修改提醒文字...", action: #selector(editMessage), keyEquivalent: "m"))
        menu.addItem(makeMenuItem(title: "自定义间隔...", action: #selector(editInterval), keyEquivalent: "i"))

        let presets = NSMenu()
        [15, 30, 45, 60, 90, 120].forEach { minutes in
            let item = makeMenuItem(title: "\(minutes) 分钟", action: #selector(selectPresetInterval(_:)), keyEquivalent: "")
            item.representedObject = minutes
            presets.addItem(item)
        }
        let presetsItem = NSMenuItem(title: "快速间隔", action: nil, keyEquivalent: "")
        menu.addItem(presetsItem)
        menu.setSubmenu(presets, for: presetsItem)

        menu.addItem(soundItem)
        menu.addItem(.separator())
        menu.addItem(makeMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
        pauseItem.target = self
        soundItem.target = self
        updateMenu()
    }

    private func makeMenuItem(title: String, action: Selector, keyEquivalent: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    private func startClock() {
        clockTimer?.invalidate()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateMenu()
            }
        }
    }

    private func scheduleNextReminder(from date: Date) {
        reminderTimer?.invalidate()
        nextReminderDate = date.addingTimeInterval(intervalMinutes * 60)

        guard !isPaused else {
            updateMenu()
            return
        }

        reminderTimer = Timer.scheduledTimer(withTimeInterval: intervalMinutes * 60, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.fireReminder()
            }
        }
        updateMenu()
    }

    private func fireReminder() {
        showFlight(message: message)
        scheduleNextReminder(from: Date())
    }

    private func showFlight(message: String) {
        if playSound {
            playFlybySound()
        }

        if flightWindow == nil {
            flightWindow = FlightWindow(message: message)
        } else {
            flightWindow?.setMessage(message)
        }

        flightWindow?.fly {}
    }

    private func playFlybySound() {
        guard let url = Bundle.main.url(forResource: "flyby", withExtension: "wav") else {
            NSSound(named: NSSound.Name("Submarine"))?.play()
            return
        }

        do {
            flybyPlayer = try AVAudioPlayer(contentsOf: url)
            flybyPlayer?.volume = 0.34
            flybyPlayer?.prepareToPlay()
            flybyPlayer?.play()
        } catch {
            NSSound(named: NSSound.Name("Submarine"))?.play()
        }
    }

    private func updateMenu() {
        let pauseText = isPaused ? "已暂停" : formattedRemainingTime()
        nextItem.title = "下次提醒：\(pauseText)"
        pauseItem.title = isPaused ? "继续提醒" : "暂停提醒"
        soundItem.title = playSound ? "提示音：开" : "提示音：关"
        statusItem.button?.contentTintColor = isPaused ? .secondaryLabelColor : .labelColor
    }

    private func formattedRemainingTime() -> String {
        let seconds = max(0, Int(nextReminderDate.timeIntervalSinceNow.rounded()))
        if seconds < 60 {
            return "\(seconds) 秒后"
        }
        let minutes = seconds / 60
        let rest = seconds % 60
        return rest == 0 ? "\(minutes) 分钟后" : "\(minutes) 分 \(rest) 秒后"
    }

    @objc private func showReminderNow() {
        showFlight(message: message)
    }

    @objc private func showControlPanel() {
        if controlPanel == nil {
            controlPanel = ControlPanel(
                getMessage: { [weak self] in self?.message ?? "该喝水啦" },
                getInterval: { [weak self] in self?.intervalMinutes ?? 45 },
                getPaused: { [weak self] in self?.isPaused ?? false },
                testFlight: { [weak self] in self?.showReminderNow() },
                togglePause: { [weak self] in self?.togglePause() },
                editMessage: { [weak self] in self?.editMessage() },
                editInterval: { [weak self] in self?.editInterval() },
                quit: { NSApp.terminate(nil) }
            )
        }

        controlPanel?.show()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func togglePause() {
        isPaused.toggle()
        UserDefaults.standard.set(isPaused, forKey: DefaultsKey.isPaused)
        scheduleNextReminder(from: Date())
    }

    @objc private func toggleSound() {
        playSound.toggle()
        updateMenu()
    }

    @objc private func editMessage() {
        let field = NSTextField(string: message)
        field.placeholderString = "例如：起来喝口水"
        field.frame.size.width = 260

        let alert = NSAlert()
        alert.messageText = "提醒文字"
        alert.informativeText = "保持短一点，飞过屏幕时会更轻盈。"
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        if alert.runModal() == .alertFirstButtonReturn {
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            message = value.isEmpty ? "该喝水啦" : value
        }
    }

    @objc private func editInterval() {
        let field = NSTextField(string: "\(Int(intervalMinutes))")
        field.placeholderString = "分钟"
        field.frame.size.width = 120

        let alert = NSAlert()
        alert.messageText = "提醒间隔"
        alert.informativeText = "输入分钟数，适合低频提醒，比如 45 或 90。"
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        if alert.runModal() == .alertFirstButtonReturn,
           let value = Double(field.stringValue),
           value > 0 {
            intervalMinutes = value
            scheduleNextReminder(from: Date())
        }
    }

    @objc private func selectPresetInterval(_ sender: NSMenuItem) {
        guard let minutes = sender.representedObject as? Int else { return }
        intervalMinutes = Double(minutes)
        scheduleNextReminder(from: Date())
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

final class FlightWindow: NSWindow {
    private let flightView: FlightView
    private var animationTimer: Timer?
    private var animationStartedAt = Date()
    private var animationDuration: TimeInterval = 12.0
    private var animationStartX: CGFloat = 0
    private var animationEndX: CGFloat = 0
    private var animationY: CGFloat = 0
    private var animationCompletion: (@MainActor () -> Void)?
    private let contentWidth: CGFloat

    init(message: String) {
        let screenFrame = NSScreen.main?.frame ?? .init(x: 0, y: 0, width: 1440, height: 900)
        contentWidth = min(760, screenFrame.width * 0.74)

        flightView = FlightView(message: message, maxFlightWidth: contentWidth)
        super.init(
            contentRect: screenFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        alphaValue = 1
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.normalWindow)) - 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = flightView
    }

    func fly(completion: @MainActor @escaping () -> Void) {
        guard let screenFrame = NSScreen.main?.frame else {
            completion()
            return
        }

        animationTimer?.invalidate()

        animationStartedAt = Date()
        animationStartX = -320
        animationEndX = screenFrame.width + 48
        animationY = screenFrame.height * 0.60
        animationCompletion = completion
        flightView.setFlightPosition(x: animationStartX, y: animationY, opacity: 0)
        displayIfNeeded()
        orderFrontRegardless()
        animationTimer = Timer.scheduledTimer(
            timeInterval: 1.0 / 60.0,
            target: self,
            selector: #selector(stepFlightAnimation),
            userInfo: nil,
            repeats: true
        )
    }

    func setMessage(_ message: String) {
        flightView.setMessage(message)
    }

    @objc private func stepFlightAnimation() {
        let elapsed = Date().timeIntervalSince(animationStartedAt)
        let progress = min(1, elapsed / animationDuration)
        let eased = smoothstep(progress)
        let x = animationStartX + (animationEndX - animationStartX) * eased
        let lift = sin(progress * .pi * 2.0) * 8
        flightView.setFlightPosition(x: x, y: animationY + lift, opacity: opacity(for: progress))

        if progress >= 1 {
            animationTimer?.invalidate()
            animationTimer = nil
            flightView.setFlightPosition(x: animationEndX, y: animationY, opacity: 0)
            let completion = animationCompletion
            animationCompletion = nil
            completion?()
        }
    }

    private func smoothstep(_ value: Double) -> Double {
        value * value * (3 - 2 * value)
    }

    private func opacity(for progress: Double) -> CGFloat {
        let fadeIn = min(1, progress / 0.12)
        let fadeOut = min(1, (1 - progress) / 0.16)
        return CGFloat(max(0, min(fadeIn, fadeOut)))
    }
}

@MainActor
final class ControlPanel: NSObject {
    private let window: NSPanel
    private let messageLabel = NSTextField(labelWithString: "")
    private let intervalLabel = NSTextField(labelWithString: "")
    private let pauseButton = NSButton(title: "", target: nil, action: nil)
    private let getMessage: () -> String
    private let getInterval: () -> Double
    private let getPaused: () -> Bool
    private let testFlight: () -> Void
    private let togglePauseAction: () -> Void
    private let editMessageAction: () -> Void
    private let editIntervalAction: () -> Void
    private let quitAction: () -> Void

    init(
        getMessage: @escaping () -> String,
        getInterval: @escaping () -> Double,
        getPaused: @escaping () -> Bool,
        testFlight: @escaping () -> Void,
        togglePause: @escaping () -> Void,
        editMessage: @escaping () -> Void,
        editInterval: @escaping () -> Void,
        quit: @escaping () -> Void
    ) {
        self.getMessage = getMessage
        self.getInterval = getInterval
        self.getPaused = getPaused
        self.testFlight = testFlight
        togglePauseAction = togglePause
        editMessageAction = editMessage
        editIntervalAction = editInterval
        quitAction = quit

        window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 230),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.title = "Airmessage"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = makeContentView()
        update()
    }

    func show() {
        update()
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeContentView() -> NSView {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 230))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let title = NSTextField(labelWithString: "✈︎ Air")
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        title.alignment = .center

        messageLabel.font = .systemFont(ofSize: 15, weight: .medium)
        messageLabel.alignment = .center
        messageLabel.lineBreakMode = .byTruncatingTail

        intervalLabel.font = .systemFont(ofSize: 13, weight: .regular)
        intervalLabel.textColor = .secondaryLabelColor
        intervalLabel.alignment = .center

        let testButton = makeButton("现在试飞", action: #selector(testFlightPressed))
        pauseButton.target = self
        pauseButton.action = #selector(togglePausePressed)
        pauseButton.bezelStyle = .rounded
        let messageButton = makeButton("修改文字", action: #selector(editMessagePressed))
        let intervalButton = makeButton("修改间隔", action: #selector(editIntervalPressed))
        let quitButton = makeButton("退出", action: #selector(quitPressed))

        let buttonGrid = NSGridView(views: [
            [testButton, pauseButton],
            [messageButton, intervalButton],
            [quitButton, NSView()]
        ])
        buttonGrid.columnSpacing = 10
        buttonGrid.rowSpacing = 10
        buttonGrid.translatesAutoresizingMaskIntoConstraints = false
        buttonGrid.column(at: 0).width = 138
        buttonGrid.column(at: 1).width = 138

        let stack = NSStackView(views: [title, messageLabel, intervalLabel, buttonGrid])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 24)
        ])

        return root
    }

    private func makeButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func update() {
        messageLabel.stringValue = getMessage()
        intervalLabel.stringValue = "每 \(Int(getInterval())) 分钟提醒一次"
        pauseButton.title = getPaused() ? "继续提醒" : "暂停提醒"
    }

    @objc private func testFlightPressed() {
        testFlight()
    }

    @objc private func togglePausePressed() {
        togglePauseAction()
        update()
    }

    @objc private func editMessagePressed() {
        editMessageAction()
        update()
    }

    @objc private func editIntervalPressed() {
        editIntervalAction()
        update()
    }

    @objc private func quitPressed() {
        quitAction()
    }
}

final class FlightView: NSView {
    private var message: String
    private let maxFlightWidth: CGFloat
    private let bannerLayer = CAShapeLayer()
    private let ropeLayer = CAShapeLayer()
    private let flagHighlightLayer = CAShapeLayer()
    private let textLayer = CATextLayer()
    private let planeLayer = CAShapeLayer()
    private let wingLayer = CAShapeLayer()
    private let tailLayer = CAShapeLayer()
    private let windowLayer = CAShapeLayer()
    private var flightOrigin = CGPoint(x: 0, y: 0)
    private var flightOpacity: CGFloat = 1
    private var bannerWidth: CGFloat = 180

    init(message: String, maxFlightWidth: CGFloat) {
        self.message = message
        self.maxFlightWidth = maxFlightWidth
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        setupLayers()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        bannerWidth = min(maxFlightWidth - 122, max(180, CGFloat(message.count) * 18 + 56))
        positionLayers()
    }

    func setFlightPosition(x: CGFloat, y: CGFloat, opacity: CGFloat) {
        flightOrigin = CGPoint(x: x, y: y)
        flightOpacity = opacity
        positionLayers()
    }

    func setMessage(_ message: String) {
        self.message = message
        textLayer.string = message
        needsLayout = true
    }

    private func positionLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let bannerFrame = CGRect(x: flightOrigin.x, y: flightOrigin.y + 18, width: bannerWidth, height: 50)
        bannerLayer.frame = bannerFrame
        bannerLayer.path = flagPath(in: CGRect(origin: .zero, size: bannerFrame.size), wave: sin(flightOrigin.x / 90) * 2.5).cgPath
        flagHighlightLayer.frame = bannerFrame
        flagHighlightLayer.path = flagHighlightPath(in: CGRect(origin: .zero, size: bannerFrame.size)).cgPath

        textLayer.frame = bannerFrame.insetBy(dx: 20, dy: 13)

        let planeFrame = CGRect(x: bannerFrame.maxX + 20, y: flightOrigin.y + 4, width: 126, height: 78)
        ropeLayer.frame = bounds
        ropeLayer.path = ropePath(from: CGPoint(x: bannerFrame.maxX - 4, y: bannerFrame.midY), to: CGPoint(x: planeFrame.minX + 8, y: planeFrame.midY - 1)).cgPath

        planeLayer.frame = planeFrame
        planeLayer.path = planePath(in: planeLayer.bounds).cgPath
        wingLayer.frame = planeFrame
        wingLayer.path = wingPath(in: wingLayer.bounds).cgPath
        tailLayer.frame = planeFrame
        tailLayer.path = tailPath(in: tailLayer.bounds).cgPath
        windowLayer.frame = planeFrame
        windowLayer.path = windowPath(in: windowLayer.bounds).cgPath

        bannerLayer.opacity = Float(flightOpacity)
        ropeLayer.opacity = Float(flightOpacity * 0.78)
        flagHighlightLayer.opacity = Float(flightOpacity)
        textLayer.opacity = Float(flightOpacity)
        planeLayer.opacity = Float(flightOpacity)
        wingLayer.opacity = Float(flightOpacity)
        tailLayer.opacity = Float(flightOpacity)
        windowLayer.opacity = Float(flightOpacity)

        CATransaction.commit()
    }

    private func setupLayers() {
        bannerLayer.fillColor = NSColor(calibratedRed: 0.30, green: 0.58, blue: 0.66, alpha: 0.92).cgColor
        bannerLayer.shadowColor = NSColor.black.cgColor
        bannerLayer.shadowOpacity = 0.20
        bannerLayer.shadowRadius = 12
        bannerLayer.shadowOffset = CGSize(width: 0, height: -4)

        flagHighlightLayer.fillColor = NSColor(calibratedWhite: 1, alpha: 0.16).cgColor
        ropeLayer.fillColor = nil
        ropeLayer.strokeColor = NSColor(calibratedRed: 0.64, green: 0.76, blue: 0.79, alpha: 0.86).cgColor
        ropeLayer.lineWidth = 1.5
        ropeLayer.lineCap = .round

        textLayer.string = message
        textLayer.foregroundColor = NSColor.white.cgColor
        textLayer.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        textLayer.fontSize = 17
        textLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        textLayer.truncationMode = .end
        textLayer.alignmentMode = .center

        planeLayer.fillColor = NSColor(calibratedRed: 0.94, green: 0.97, blue: 0.98, alpha: 1).cgColor
        planeLayer.strokeColor = NSColor(calibratedRed: 0.42, green: 0.54, blue: 0.62, alpha: 0.95).cgColor
        planeLayer.lineWidth = 1.2
        planeLayer.shadowColor = NSColor.black.cgColor
        planeLayer.shadowOpacity = 0.20
        planeLayer.shadowRadius = 10
        planeLayer.shadowOffset = CGSize(width: 0, height: -2)

        wingLayer.fillColor = NSColor(calibratedRed: 0.34, green: 0.74, blue: 0.82, alpha: 1).cgColor
        wingLayer.strokeColor = NSColor(calibratedRed: 0.18, green: 0.52, blue: 0.62, alpha: 0.82).cgColor
        wingLayer.lineWidth = 1

        tailLayer.fillColor = NSColor(calibratedRed: 0.34, green: 0.74, blue: 0.82, alpha: 1).cgColor
        tailLayer.strokeColor = NSColor(calibratedRed: 0.18, green: 0.52, blue: 0.62, alpha: 0.82).cgColor
        tailLayer.lineWidth = 1

        windowLayer.fillColor = NSColor(calibratedRed: 0.24, green: 0.45, blue: 0.58, alpha: 0.9).cgColor

        layer?.addSublayer(bannerLayer)
        layer?.addSublayer(flagHighlightLayer)
        layer?.addSublayer(textLayer)
        layer?.addSublayer(ropeLayer)
        layer?.addSublayer(tailLayer)
        layer?.addSublayer(wingLayer)
        layer?.addSublayer(planeLayer)
        layer?.addSublayer(windowLayer)

        let bob = CABasicAnimation(keyPath: "transform.translation.y")
        bob.fromValue = -4
        bob.toValue = 4
        bob.duration = 0.72
        bob.autoreverses = true
        bob.repeatCount = .infinity
        bob.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        planeLayer.add(bob, forKey: "bob")
        wingLayer.add(bob, forKey: "bob")
        tailLayer.add(bob, forKey: "bob")
        windowLayer.add(bob, forKey: "bob")
    }

    private func flagPath(in rect: CGRect, wave: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: CGPoint(x: rect.minX + 12, y: rect.minY + 2))
        path.curve(to: CGPoint(x: rect.maxX - 6, y: rect.minY + 8 + wave), controlPoint1: CGPoint(x: rect.width * 0.32, y: rect.minY - 5), controlPoint2: CGPoint(x: rect.width * 0.68, y: rect.minY + 12))
        path.curve(to: CGPoint(x: rect.maxX - 12, y: rect.maxY - 7 - wave), controlPoint1: CGPoint(x: rect.maxX + 6, y: rect.midY + 6), controlPoint2: CGPoint(x: rect.maxX - 2, y: rect.maxY - 4))
        path.curve(to: CGPoint(x: rect.minX + 10, y: rect.maxY - 3), controlPoint1: CGPoint(x: rect.width * 0.68, y: rect.maxY - 15), controlPoint2: CGPoint(x: rect.width * 0.28, y: rect.maxY + 6))
        path.curve(to: CGPoint(x: rect.minX + 12, y: rect.minY + 2), controlPoint1: CGPoint(x: rect.minX - 3, y: rect.maxY - 12), controlPoint2: CGPoint(x: rect.minX - 2, y: rect.minY + 12))
        path.close()
        return path
    }

    private func flagHighlightPath(in rect: CGRect) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: CGPoint(x: rect.minX + 18, y: rect.maxY - 13))
        path.curve(to: CGPoint(x: rect.maxX - 22, y: rect.maxY - 14), controlPoint1: CGPoint(x: rect.width * 0.36, y: rect.maxY - 4), controlPoint2: CGPoint(x: rect.width * 0.65, y: rect.maxY - 21))
        path.curve(to: CGPoint(x: rect.maxX - 38, y: rect.maxY - 22), controlPoint1: CGPoint(x: rect.maxX - 26, y: rect.maxY - 19), controlPoint2: CGPoint(x: rect.maxX - 32, y: rect.maxY - 22))
        path.curve(to: CGPoint(x: rect.minX + 22, y: rect.maxY - 22), controlPoint1: CGPoint(x: rect.width * 0.62, y: rect.maxY - 29), controlPoint2: CGPoint(x: rect.width * 0.28, y: rect.maxY - 15))
        path.close()
        return path
    }

    private func ropePath(from start: CGPoint, to end: CGPoint) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: start)
        path.curve(to: end, controlPoint1: CGPoint(x: start.x + 14, y: start.y + 6), controlPoint2: CGPoint(x: end.x - 20, y: end.y - 5))
        return path
    }

    private func planePath(in rect: CGRect) -> NSBezierPath {
        let path = NSBezierPath()
        let sx = rect.width / 126
        let sy = rect.height / 78

        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: x * sx, y: y * sy)
        }

        path.move(to: p(8, 38))
        path.curve(to: p(76, 51), controlPoint1: p(28, 38), controlPoint2: p(51, 43))
        path.curve(to: p(120, 40), controlPoint1: p(96, 59), controlPoint2: p(116, 55))
        path.curve(to: p(82, 28), controlPoint1: p(122, 30), controlPoint2: p(100, 26))
        path.curve(to: p(21, 28), controlPoint1: p(58, 30), controlPoint2: p(36, 24))
        path.curve(to: p(8, 38), controlPoint1: p(13, 31), controlPoint2: p(9, 34))
        path.close()
        return path
    }

    private func wingPath(in rect: CGRect) -> NSBezierPath {
        let path = NSBezierPath()
        let sx = rect.width / 126
        let sy = rect.height / 78

        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: x * sx, y: y * sy)
        }

        path.move(to: p(49, 39))
        path.line(to: p(35, 70))
        path.curve(to: p(75, 50), controlPoint1: p(47, 66), controlPoint2: p(62, 56))
        path.close()
        return path
    }

    private func tailPath(in rect: CGRect) -> NSBezierPath {
        let path = NSBezierPath()
        let sx = rect.width / 126
        let sy = rect.height / 78

        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: x * sx, y: y * sy)
        }

        path.move(to: p(24, 33))
        path.line(to: p(8, 58))
        path.line(to: p(42, 39))
        path.close()
        return path
    }

    private func windowPath(in rect: CGRect) -> NSBezierPath {
        let path = NSBezierPath()
        let sx = rect.width / 126
        let sy = rect.height / 78

        [88, 99, 110].forEach { x in
            let oval = NSBezierPath(ovalIn: CGRect(x: CGFloat(x) * sx, y: 41 * sy, width: 5 * sx, height: 4 * sy))
            path.append(oval)
        }

        return path
    }
}

extension NSBezierPath {
    var cgPath: CGPath {
        let path = CGMutablePath()
        var points = [NSPoint](repeating: .zero, count: 3)

        for index in 0..<elementCount {
            switch element(at: index, associatedPoints: &points) {
            case .moveTo:
                path.move(to: points[0])
            case .lineTo:
                path.addLine(to: points[0])
            case .curveTo, .cubicCurveTo:
                path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .quadraticCurveTo:
                path.addQuadCurve(to: points[1], control: points[0])
            case .closePath:
                path.closeSubpath()
            @unknown default:
                break
            }
        }

        return path
    }
}

@main
enum AirmessageMain {
    @MainActor
    private static var appDelegate: AppDelegate?

    @MainActor
    static func main() {
        let app = NSApplication.shared
        ProcessInfo.processInfo.disableAutomaticTermination("Airmessage keeps reminder timers running.")
        appDelegate = AppDelegate()
        app.delegate = appDelegate
        app.run()
    }
}
