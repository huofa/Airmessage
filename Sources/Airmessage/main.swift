import AppKit
import AVFoundation
import Carbon.HIToolbox

private enum DefaultsKey {
    static let message = "message"
    static let intervalMinutes = "intervalMinutes"
    static let reminders = "reminders"
    static let isPaused = "isPaused"
    static let playSound = "playSound"
    static let selectedSound = "selectedSound"
    static let flightRepeatCount = "flightRepeatCount"
    static let flightDurationSeconds = "flightDurationSeconds"
}

private struct SoundChoice {
    let id: String
    let title: String
    let fileName: String
    let fileExtension: String
    let volume: Float
}

private struct ReminderItem: Codable, Identifiable, Equatable {
    var id: String
    var message: String
    var nextFireAt: Date
    var intervalMinutes: Int?
    var flightRepeatCount: Int
    var isEnabled: Bool

    var isRepeating: Bool {
        intervalMinutes != nil
    }
}

private struct FlightJob {
    let message: String
    let repetitions: Int
}

private func airmessageHotKeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return noErr }
    let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
    Task { @MainActor in
        delegate.handleSystemHotKey()
    }
    return noErr
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let nextItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "", action: #selector(togglePause), keyEquivalent: "")
    private let soundItem = NSMenuItem(title: "", action: #selector(toggleSound), keyEquivalent: "")
    private let remindersMenuItem = NSMenuItem(title: "提醒列表", action: nil, keyEquivalent: "")
    private var soundChoiceItems: [NSMenuItem] = []
    private var controlPanel: ControlPanel?
    private var flightWindow: FlightWindow?
    private var flightSequenceTask: Task<Void, Never>?
    private var flightQueue: [FlightJob] = []
    private var isRunningFlightQueue = false
    private var flybyPlayer: AVAudioPlayer?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerRef: EventHandlerRef?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var reminderTimer: Timer?
    private var clockTimer: Timer?
    private var reminders: [ReminderItem] = []
    private var nextReminderDate: Date?
    private var isPaused = UserDefaults.standard.bool(forKey: DefaultsKey.isPaused)
    private let soundChoices = [
        SoundChoice(id: "long", title: "长空气声 11 秒", fileName: "flyby_long", fileExtension: "mp3", volume: 0.72),
        SoundChoice(id: "soft", title: "柔和掠过声", fileName: "flyby", fileExtension: "wav", volume: 0.62),
        SoundChoice(id: "jet", title: "强劲喷气 28 秒", fileName: "flyby_jet", fileExtension: "mp3", volume: 0.48)
    ]

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

    private var selectedSoundID: String {
        get {
            let saved = UserDefaults.standard.string(forKey: DefaultsKey.selectedSound) ?? ""
            return soundChoices.contains { $0.id == saved } ? saved : "long"
        }
        set {
            UserDefaults.standard.set(newValue, forKey: DefaultsKey.selectedSound)
        }
    }

    private var selectedSoundChoice: SoundChoice {
        soundChoices.first { $0.id == selectedSoundID } ?? soundChoices[0]
    }

    private var flightRepeatCount: Int {
        get {
            let saved = UserDefaults.standard.integer(forKey: DefaultsKey.flightRepeatCount)
            return saved > 0 ? saved : 1
        }
        set {
            UserDefaults.standard.set(max(1, min(12, newValue)), forKey: DefaultsKey.flightRepeatCount)
        }
    }

    private var flightDurationSeconds: Double {
        get {
            let saved = UserDefaults.standard.double(forKey: DefaultsKey.flightDurationSeconds)
            return saved > 0 ? saved : 12
        }
        set {
            UserDefaults.standard.set(max(4, min(45, newValue)), forKey: DefaultsKey.flightDurationSeconds)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ProcessInfo.processInfo.disableAutomaticTermination("Airmessage keeps reminder timers running.")
        NSApp.setActivationPolicy(.regular)
        reminders = loadReminders()
        setupMenu()
        scheduleNextReminder()
        startClock()
        startShortcutMonitoring()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            enqueueFlights([FlightJob(message: primaryReminder.message, repetitions: 1)])
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            if let icon = makeStatusBarIcon() {
                button.image = icon
                button.imagePosition = .imageOnly
            } else {
                button.title = "✈︎ Air"
            }
            button.toolTip = "Airmessage"
        }
        statusItem.menu = menu

        menu.addItem(NSMenuItem(title: "Airmessage", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(nextItem)
        menu.addItem(makeMenuItem(title: "打开控制面板", action: #selector(showControlPanel), keyEquivalent: "o"))
        menu.addItem(makeMenuItem(title: "现在试飞  ⌘⌥0", action: #selector(showReminderNow), keyEquivalent: ""))
        menu.addItem(pauseItem)
        menu.addItem(.separator())
        menu.addItem(makeMenuItem(title: "新建提醒...", action: #selector(addReminder), keyEquivalent: "n"))
        menu.addItem(remindersMenuItem)
        menu.addItem(makeMenuItem(title: "修改默认提醒文字...", action: #selector(editMessage), keyEquivalent: "m"))
        menu.addItem(makeMenuItem(title: "默认提醒间隔...", action: #selector(editInterval), keyEquivalent: "i"))
        menu.addItem(makeMenuItem(title: "默认飞行次数...", action: #selector(editFlightRepeatCount), keyEquivalent: ""))
        menu.addItem(makeMenuItem(title: "飞行时长...", action: #selector(editFlightDuration), keyEquivalent: ""))

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
        let soundMenu = NSMenu()
        soundChoiceItems = soundChoices.map { choice in
            let item = makeMenuItem(title: choice.title, action: #selector(selectSound(_:)), keyEquivalent: "")
            item.representedObject = choice.id
            soundMenu.addItem(item)
            return item
        }
        let soundMenuItem = NSMenuItem(title: "选择音效", action: nil, keyEquivalent: "")
        menu.addItem(soundMenuItem)
        menu.setSubmenu(soundMenu, for: soundMenuItem)
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

    private func makeStatusBarIcon() -> NSImage? {
        let iconURL = Bundle.main.url(forResource: "StatusIcon", withExtension: "png")
            ?? Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
        guard let iconURL,
              let icon = NSImage(contentsOf: iconURL) else {
            return nil
        }

        icon.size = NSSize(width: 19, height: 19)
        icon.isTemplate = false
        return icon
    }

    private func startClock() {
        clockTimer?.invalidate()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateMenu()
            }
        }
    }

    private func startShortcutMonitoring() {
        registerSystemHotKey()

        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard Self.isRightCommandRightOptionZero(event) else {
                return
            }

            Task { @MainActor in
                self?.showReminderNow()
            }
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard Self.isRightCommandRightOptionZero(event) else {
                return event
            }

            self?.showReminderNow()
            return nil
        }
    }

    private static func isRightCommandRightOptionZero(_ event: NSEvent) -> Bool {
        let rawFlags = event.modifierFlags.rawValue
        let rightCommandMask: UInt = 0x00000010
        let rightOptionMask: UInt = 0x00000040
        let hasRightCommand = rawFlags & rightCommandMask == rightCommandMask
        let hasRightOption = rawFlags & rightOptionMask == rightOptionMask
        return hasRightCommand && hasRightOption && event.keyCode == UInt16(kVK_ANSI_0)
    }

    private func registerSystemHotKey() {
        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: 1)
        let modifiers = UInt32(cmdKey | optionKey)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_0),
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            airmessageHotKeyHandler,
            1,
            &eventSpec,
            Unmanaged.passUnretained(self).toOpaque(),
            &hotKeyHandlerRef
        )
    }

    fileprivate func handleSystemHotKey() {
        showReminderNow()
    }

    private static let hotKeySignature: OSType = {
        let scalars = Array("AMsg".unicodeScalars)
        return scalars.reduce(OSType(0)) { ($0 << 8) + OSType($1.value) }
    }()

    private var primaryReminder: ReminderItem {
        if let enabled = reminders.first(where: { $0.isEnabled }) {
            return enabled
        }
        if let first = reminders.first {
            return first
        }
        return ReminderItem(
            id: UUID().uuidString,
            message: message,
            nextFireAt: Date().addingTimeInterval(intervalMinutes * 60),
            intervalMinutes: Int(intervalMinutes),
            flightRepeatCount: flightRepeatCount,
            isEnabled: true
        )
    }

    private func loadReminders() -> [ReminderItem] {
        if let data = UserDefaults.standard.data(forKey: DefaultsKey.reminders),
           let saved = try? JSONDecoder().decode([ReminderItem].self, from: data),
           !saved.isEmpty {
            return saved
        }

        return [
            ReminderItem(
                id: UUID().uuidString,
                message: message,
                nextFireAt: Date().addingTimeInterval(intervalMinutes * 60),
                intervalMinutes: Int(intervalMinutes),
                flightRepeatCount: flightRepeatCount,
                isEnabled: true
            )
        ]
    }

    private func saveReminders() {
        if let data = try? JSONEncoder().encode(reminders) {
            UserDefaults.standard.set(data, forKey: DefaultsKey.reminders)
        }
    }

    private func scheduleNextReminder() {
        reminderTimer?.invalidate()
        nextReminderDate = reminders
            .filter(\.isEnabled)
            .map(\.nextFireAt)
            .min()

        guard !isPaused, let nextReminderDate else {
            updateMenu()
            return
        }

        let interval = max(1, nextReminderDate.timeIntervalSinceNow)
        reminderTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.fireReminder()
            }
        }
        updateMenu()
    }

    private func fireReminder() {
        let now = Date()
        var jobs: [FlightJob] = []
        for index in reminders.indices {
            guard reminders[index].isEnabled, reminders[index].nextFireAt <= now.addingTimeInterval(0.5) else {
                continue
            }

            jobs.append(FlightJob(message: reminders[index].message, repetitions: reminders[index].flightRepeatCount))
            if let minutes = reminders[index].intervalMinutes {
                repeat {
                    reminders[index].nextFireAt = reminders[index].nextFireAt.addingTimeInterval(TimeInterval(minutes * 60))
                } while reminders[index].nextFireAt <= now
            } else {
                reminders[index].isEnabled = false
            }
        }

        saveReminders()
        if !jobs.isEmpty {
            enqueueFlights(jobs)
        }
        scheduleNextReminder()
    }

    private func enqueueFlights(_ jobs: [FlightJob]) {
        flightQueue.append(contentsOf: jobs)
        guard !isRunningFlightQueue else { return }
        runFlightQueue()
    }

    private func runFlightQueue() {
        guard !flightQueue.isEmpty else {
            isRunningFlightQueue = false
            return
        }

        isRunningFlightQueue = true
        let job = flightQueue.removeFirst()
        flightSequenceTask = Task { @MainActor in
            let count = max(1, job.repetitions)
            for index in 0..<count {
                if Task.isCancelled { return }

                if playSound {
                    playFlybySound()
                }

                if flightWindow == nil {
                    flightWindow = FlightWindow(message: job.message)
                } else {
                    flightWindow?.setMessage(job.message)
                }

                await withCheckedContinuation { continuation in
                    flightWindow?.fly(duration: flightDurationSeconds) {
                        continuation.resume()
                    }
                }

                if Task.isCancelled { return }

                if index < count - 1 {
                    try? await Task.sleep(for: .seconds(2))
                }
            }

            runFlightQueue()
        }
    }

    private func playFlybySound() {
        let choice = selectedSoundChoice
        guard let url = soundURL(fileName: choice.fileName, fileExtension: choice.fileExtension) else {
            NSSound(named: NSSound.Name("Submarine"))?.play()
            return
        }

        do {
            flybyPlayer = try AVAudioPlayer(contentsOf: url)
            flybyPlayer?.volume = choice.volume
            flybyPlayer?.prepareToPlay()
            flybyPlayer?.play()
        } catch {
            NSSound(named: NSSound.Name("Submarine"))?.play()
        }
    }

    private func soundURL(fileName: String, fileExtension: String) -> URL? {
        if let url = Bundle.main.url(forResource: fileName, withExtension: fileExtension) {
            return url
        }

        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        let resourceURL = executableURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/\(fileName).\(fileExtension)")
        return FileManager.default.fileExists(atPath: resourceURL.path) ? resourceURL : nil
    }

    private func updateMenu() {
        let pauseText = isPaused ? "已暂停" : formattedRemainingTime()
        nextItem.title = "下次提醒：\(pauseText)"
        pauseItem.title = isPaused ? "继续提醒" : "暂停提醒"
        soundItem.title = playSound ? "提示音：开" : "提示音：关"
        rebuildRemindersMenu()
        soundChoiceItems.forEach { item in
            item.state = (item.representedObject as? String) == selectedSoundID ? .on : .off
        }
        statusItem.button?.contentTintColor = isPaused ? .secondaryLabelColor : .labelColor
    }

    private func formattedRemainingTime() -> String {
        guard let nextReminderDate else {
            return reminders.isEmpty ? "无提醒" : "无启用提醒"
        }

        let seconds = max(0, Int(nextReminderDate.timeIntervalSinceNow.rounded()))
        if seconds < 60 {
            return "\(seconds) 秒后"
        }
        let minutes = seconds / 60
        let rest = seconds % 60
        return rest == 0 ? "\(minutes) 分钟后" : "\(minutes) 分 \(rest) 秒后"
    }

    @objc private func showReminderNow() {
        enqueueFlights([FlightJob(message: primaryReminder.message, repetitions: primaryReminder.flightRepeatCount)])
    }

    @objc private func showControlPanel() {
        if controlPanel == nil {
            controlPanel = ControlPanel(
                getMessage: { [weak self] in self?.primaryReminder.message ?? "该喝水啦" },
                getInterval: { [weak self] in Double(self?.primaryReminder.intervalMinutes ?? 0) },
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
        scheduleNextReminder()
    }

    @objc private func toggleSound() {
        playSound.toggle()
        updateMenu()
    }

    @objc private func selectSound(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        selectedSoundID = id
        updateMenu()
    }

    @objc private func editMessage() {
        let current = primaryReminder
        let field = NSTextField(string: current.message)
        field.placeholderString = "例如：起来喝口水"
        field.frame.size.width = 260

        let alert = NSAlert()
        alert.messageText = "默认提醒文字"
        alert.informativeText = "会修改第一条提醒。保持短一点，飞过屏幕时会更轻盈。"
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        if alert.runModal() == .alertFirstButtonReturn {
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            updatePrimaryReminder { reminder in
                reminder.message = value.isEmpty ? "该喝水啦" : value
            }
        }
    }

    @objc private func editInterval() {
        let current = primaryReminder
        let field = NSTextField(string: "\(current.intervalMinutes ?? 45)")
        field.placeholderString = "分钟"
        field.frame.size.width = 120

        let alert = NSAlert()
        alert.messageText = "默认提醒间隔"
        alert.informativeText = "会修改第一条提醒。输入分钟数，适合低频提醒，比如 45 或 90。"
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        if alert.runModal() == .alertFirstButtonReturn,
           let value = Double(field.stringValue),
           value > 0 {
            updatePrimaryReminder { reminder in
                reminder.intervalMinutes = Int(value)
                reminder.nextFireAt = Date().addingTimeInterval(value * 60)
                reminder.isEnabled = true
            }
        }
    }

    @objc private func editFlightRepeatCount() {
        let field = NSTextField(string: "\(primaryReminder.flightRepeatCount)")
        field.placeholderString = "次数"
        field.frame.size.width = 120

        let alert = NSAlert()
        alert.messageText = "默认飞行次数"
        alert.informativeText = "会修改第一条提醒。定时提醒触发后循环飞几次，中间间隔 2 秒。"
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        if alert.runModal() == .alertFirstButtonReturn,
           let value = Int(field.stringValue),
           value > 0 {
            updatePrimaryReminder { reminder in
                reminder.flightRepeatCount = max(1, min(12, value))
            }
        }
    }

    @objc private func editFlightDuration() {
        let field = NSTextField(string: "\(Int(flightDurationSeconds))")
        field.placeholderString = "秒"
        field.frame.size.width = 120

        let alert = NSAlert()
        alert.messageText = "飞行时长"
        alert.informativeText = "输入每次飞过桌面的秒数，数值越大速度越慢。"
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        if alert.runModal() == .alertFirstButtonReturn,
           let value = Double(field.stringValue),
           value > 0 {
            flightDurationSeconds = value
        }
    }

    @objc private func selectPresetInterval(_ sender: NSMenuItem) {
        guard let minutes = sender.representedObject as? Int else { return }
        updatePrimaryReminder { reminder in
            reminder.intervalMinutes = minutes
            reminder.nextFireAt = Date().addingTimeInterval(TimeInterval(minutes * 60))
            reminder.isEnabled = true
        }
    }

    private func updatePrimaryReminder(_ change: (inout ReminderItem) -> Void) {
        if reminders.isEmpty {
            reminders.append(primaryReminder)
        }

        change(&reminders[0])
        saveReminders()
        scheduleNextReminder()
    }

    private func rebuildRemindersMenu() {
        let submenu = NSMenu()
        if reminders.isEmpty {
            submenu.addItem(NSMenuItem(title: "暂无提醒", action: nil, keyEquivalent: ""))
        } else {
            for reminder in reminders.sorted(by: { $0.nextFireAt < $1.nextFireAt }) {
                let title = reminderSummary(reminder)
                let testItem = makeMenuItem(title: "试飞：\(title)", action: #selector(testReminder(_:)), keyEquivalent: "")
                testItem.representedObject = reminder.id
                submenu.addItem(testItem)

                let toggleTitle = reminder.isEnabled ? "停用：\(reminder.message)" : "启用：\(reminder.message)"
                let toggleItem = makeMenuItem(title: toggleTitle, action: #selector(toggleReminder(_:)), keyEquivalent: "")
                toggleItem.representedObject = reminder.id
                submenu.addItem(toggleItem)

                let deleteItem = makeMenuItem(title: "删除：\(reminder.message)", action: #selector(deleteReminder(_:)), keyEquivalent: "")
                deleteItem.representedObject = reminder.id
                submenu.addItem(deleteItem)
                submenu.addItem(.separator())
            }
        }

        submenu.addItem(makeMenuItem(title: "新建提醒...", action: #selector(addReminder), keyEquivalent: ""))
        remindersMenuItem.submenu = submenu
    }

    private func reminderSummary(_ reminder: ReminderItem) -> String {
        let mode = reminder.intervalMinutes.map { "每 \($0) 分钟" } ?? "一次"
        let state = reminder.isEnabled ? "" : "已停用，"
        return "\(state)\(reminder.message) · \(mode) · \(formatDate(reminder.nextFireAt)) · 飞 \(reminder.flightRepeatCount) 次"
    }

    private func formatDate(_ date: Date) -> String {
        Self.reminderDateFormatter.string(from: date)
    }

    @objc private func addReminder() {
        guard let reminder = presentReminderEditor() else { return }
        reminders.append(reminder)
        saveReminders()
        scheduleNextReminder()
    }

    @objc private func testReminder(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let reminder = reminders.first(where: { $0.id == id }) else {
            return
        }

        enqueueFlights([FlightJob(message: reminder.message, repetitions: reminder.flightRepeatCount)])
    }

    @objc private func toggleReminder(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let index = reminders.firstIndex(where: { $0.id == id }) else {
            return
        }

        reminders[index].isEnabled.toggle()
        if reminders[index].isEnabled, reminders[index].nextFireAt < Date() {
            if let minutes = reminders[index].intervalMinutes {
                reminders[index].nextFireAt = Date().addingTimeInterval(TimeInterval(minutes * 60))
            } else {
                reminders[index].nextFireAt = Date().addingTimeInterval(60)
            }
        }
        saveReminders()
        scheduleNextReminder()
    }

    @objc private func deleteReminder(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        reminders.removeAll { $0.id == id }
        if reminders.isEmpty {
            reminders.append(primaryReminder)
        }
        saveReminders()
        scheduleNextReminder()
    }

    private func presentReminderEditor() -> ReminderItem? {
        let now = Date()
        let labelWidth: CGFloat = 72
        let fieldX: CGFloat = 92
        let fieldWidth: CGFloat = 238
        let rowHeight: CGFloat = 28
        let form = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 152))

        let messageField = NSTextField(string: "该喝水啦")
        messageField.placeholderString = "提醒事项"
        messageField.frame = NSRect(x: fieldX, y: 120, width: fieldWidth, height: rowHeight)

        let dateField = NSTextField(string: Self.reminderDateFormatter.string(from: now.addingTimeInterval(3600)))
        dateField.placeholderString = "yyyy-MM-dd HH:mm"
        dateField.frame = NSRect(x: fieldX, y: 82, width: fieldWidth, height: rowHeight)

        let repeatPopup = NSPopUpButton()
        repeatPopup.frame = NSRect(x: fieldX, y: 44, width: fieldWidth, height: rowHeight)
        let repeatOptions = [
            ("一次性提醒", 0),
            ("每 10 分钟", 10),
            ("每 20 分钟", 20),
            ("每 30 分钟", 30),
            ("每 40 分钟", 40),
            ("每 50 分钟", 50),
            ("每 60 分钟", 60)
        ]
        repeatOptions.forEach { title, minutes in
            repeatPopup.addItem(withTitle: title)
            repeatPopup.lastItem?.representedObject = minutes
        }

        let repeatCountField = NSTextField(string: "1")
        repeatCountField.placeholderString = "1-12"
        repeatCountField.frame = NSRect(x: fieldX, y: 6, width: 80, height: rowHeight)

        [
            ("提醒事项", 120),
            ("首次时间", 82),
            ("提醒方式", 44),
            ("飞行次数", 6)
        ].forEach { title, y in
            let label = NSTextField(labelWithString: title)
            label.alignment = .right
            label.frame = NSRect(x: 0, y: CGFloat(y) + 5, width: labelWidth, height: 18)
            form.addSubview(label)
        }

        form.addSubview(messageField)
        form.addSubview(dateField)
        form.addSubview(repeatPopup)
        form.addSubview(repeatCountField)

        let alert = NSAlert()
        alert.messageText = "新建提醒"
        alert.informativeText = "时间格式：yyyy-MM-dd HH:mm，例如 2026-06-04 18:30。"
        alert.accessoryView = form
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }

        let text = messageField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let date = Self.reminderDateFormatter.date(from: dateField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? now.addingTimeInterval(3600)
        let minutes = repeatPopup.selectedItem?.representedObject as? Int ?? 0
        let repeatCount = max(1, min(12, Int(repeatCountField.stringValue) ?? 1))

        return ReminderItem(
            id: UUID().uuidString,
            message: text.isEmpty ? "该喝水啦" : text,
            nextFireAt: date,
            intervalMinutes: minutes == 0 ? nil : minutes,
            flightRepeatCount: repeatCount,
            isEnabled: true
        )
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private static let reminderDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}

final class FlightWindow: NSWindow {
    private let flightView: FlightView
    private var animationTimer: Timer?
    private var mouseMonitor: Any?
    private var animationStartedAt = Date()
    private var animationDuration: TimeInterval = 12.0
    private var animationStartX: CGFloat = 0
    private var animationEndX: CGFloat = 0
    private var animationY: CGFloat = 0
    private var animationCompletion: (@MainActor () -> Void)?
    private var isDraggingFlight = false
    private var dragOffset = CGPoint.zero
    private var currentFlightX: CGFloat = 0
    private var currentFlightY: CGFloat = 0
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
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.normalWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = flightView
        startMouseMonitoring()
    }

    func fly(duration: TimeInterval, completion: @MainActor @escaping () -> Void) {
        guard let screenFrame = NSScreen.main?.frame else {
            completion()
            return
        }

        animationTimer?.invalidate()
        isDraggingFlight = false

        animationStartedAt = Date()
        animationDuration = max(4, min(45, duration))
        animationStartX = -320
        animationEndX = screenFrame.width + 48
        animationY = screenFrame.height * 0.60
        animationCompletion = completion
        flightView.updateOcclusionMask(excluding: topmostUserWindowRects(in: screenFrame))
        setFlightPosition(x: animationStartX, y: animationY, opacity: 0)
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
        guard !isDraggingFlight else { return }

        let elapsed = Date().timeIntervalSince(animationStartedAt)
        let progress = min(1, elapsed / animationDuration)
        let eased = smoothstep(progress)
        let x = animationStartX + (animationEndX - animationStartX) * eased
        let lift = sin(progress * .pi * 2.0) * 13 + sin(progress * .pi * 4.6 + 0.45) * 4
        if let screenFrame = NSScreen.main?.frame {
            flightView.updateOcclusionMask(excluding: topmostUserWindowRects(in: screenFrame))
        }
        setFlightPosition(x: x, y: animationY + lift, opacity: opacity(for: progress))

        if progress >= 1 {
            animationTimer?.invalidate()
            animationTimer = nil
            setFlightPosition(x: animationEndX, y: animationY, opacity: 0)
            let completion = animationCompletion
            animationCompletion = nil
            completion?()
        }
    }

    private func setFlightPosition(x: CGFloat, y: CGFloat, opacity: CGFloat) {
        currentFlightX = x
        currentFlightY = y
        flightView.setFlightPosition(x: x, y: y, opacity: opacity)
    }

    private func startMouseMonitoring() {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            Task { @MainActor in
                self?.handleMouseEvent(event)
            }
        }
    }

    private func handleMouseEvent(_ event: NSEvent) {
        guard flightView.currentOpacity > 0.05 else { return }

        let location = event.locationInWindow
        let screenPoint = event.window == nil ? NSEvent.mouseLocation : convertPoint(toScreen: location)
        let localPoint = CGPoint(x: screenPoint.x - frame.minX, y: screenPoint.y - frame.minY)

        switch event.type {
        case .leftMouseDown:
            guard flightView.flightHitFrame.insetBy(dx: -18, dy: -18).contains(localPoint) else { return }
            isDraggingFlight = true
            dragOffset = CGPoint(x: localPoint.x - currentFlightX, y: localPoint.y - currentFlightY)
        case .leftMouseDragged:
            guard isDraggingFlight else { return }
            let x = localPoint.x - dragOffset.x
            let y = localPoint.y - dragOffset.y
            setFlightPosition(x: x, y: y, opacity: 1)
        case .leftMouseUp:
            guard isDraggingFlight else { return }
            isDraggingFlight = false
            resumeFlightFromCurrentPosition()
        default:
            break
        }
    }

    private func resumeFlightFromCurrentPosition() {
        guard let screenFrame = NSScreen.main?.frame else { return }

        animationStartX = currentFlightX
        animationEndX = screenFrame.width + 48
        animationY = currentFlightY
        animationStartedAt = Date()

        let remainingDistance = max(1, animationEndX - animationStartX)
        let fullDistance = max(1, screenFrame.width + 48 - (-320))
        animationDuration = max(1.2, animationDuration * Double(remainingDistance / fullDistance))

        if animationTimer == nil {
            animationTimer = Timer.scheduledTimer(
                timeInterval: 1.0 / 60.0,
                target: self,
                selector: #selector(stepFlightAnimation),
                userInfo: nil,
                repeats: true
            )
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

    private func topmostUserWindowRects(in screenFrame: CGRect) -> [CGRect] {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        let currentPID = ProcessInfo.processInfo.processIdentifier
        var targetPID: pid_t?
        var rects: [CGRect] = []

        for window in windows {
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID != currentPID,
                  let ownerName = window[kCGWindowOwnerName as String] as? String,
                  ownerName != "Finder",
                  let layer = window[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let alpha = window[kCGWindowAlpha as String] as? Double,
                  alpha > 0.05,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = windowRect(from: bounds, screenFrame: screenFrame),
                  rect.width > 180,
                  rect.height > 120,
                  !isDesktopSized(rect, screenFrame: screenFrame) else {
                continue
            }

            if targetPID == nil {
                targetPID = ownerPID
            }

            guard ownerPID == targetPID else {
                break
            }

            rects.append(rect)
        }

        return rects
    }

    private func isDesktopSized(_ rect: CGRect, screenFrame: CGRect) -> Bool {
        rect.width > screenFrame.width * 0.92 && rect.height > screenFrame.height * 0.82
    }

    private func windowRect(from bounds: [String: Any], screenFrame: CGRect) -> CGRect? {
        guard let x = bounds["X"] as? CGFloat,
              let yFromTop = bounds["Y"] as? CGFloat,
              let width = bounds["Width"] as? CGFloat,
              let height = bounds["Height"] as? CGFloat else {
            return nil
        }

        return CGRect(x: x, y: screenFrame.height - yFromTop - height, width: width, height: height)
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
        let interval = Int(getInterval())
        intervalLabel.stringValue = interval > 0 ? "每 \(interval) 分钟提醒一次" : "一次性提醒"
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
    private let bellyAccentLayer = CAShapeLayer()
    private let rearWingLayer = CAShapeLayer()
    private let wingLayer = CAShapeLayer()
    private let tailLayer = CAShapeLayer()
    private let tailHookLayer = CAShapeLayer()
    private let windowLayer = CAShapeLayer()
    private let visibilityMaskLayer = CAShapeLayer()
    private var flightOrigin = CGPoint(x: 0, y: 0)
    private var flightOpacity: CGFloat = 1
    private var bannerWidth: CGFloat = 132
    private(set) var flightHitFrame = CGRect.zero
    var currentOpacity: CGFloat {
        flightOpacity
    }

    init(message: String, maxFlightWidth: CGFloat) {
        self.message = message
        self.maxFlightWidth = maxFlightWidth
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        setupLayers()
        layer?.mask = visibilityMaskLayer
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        bannerWidth = min(maxFlightWidth - 122, max(112, CGFloat(message.count) * 12 + 40))
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

    func updateOcclusionMask(excluding rects: [CGRect]) {
        guard bounds.width > 0, bounds.height > 0 else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let path = CGMutablePath()
        path.addRect(bounds)
        rects.forEach { path.addRect($0.insetBy(dx: -8, dy: -8)) }
        visibilityMaskLayer.frame = bounds
        visibilityMaskLayer.fillRule = .evenOdd
        visibilityMaskLayer.path = path

        CATransaction.commit()
    }

    private func positionLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let flutter = sin(flightOrigin.x / 82) * 4.5
        let formationBob = sin(flightOrigin.x / 46) * 3.4 + sin(flightOrigin.x / 119) * 1.8
        let bannerFrame = CGRect(x: flightOrigin.x, y: flightOrigin.y + 12 + formationBob, width: bannerWidth, height: 40)
        bannerLayer.frame = bannerFrame
        bannerLayer.path = flagPath(in: CGRect(origin: .zero, size: bannerFrame.size), wave: flutter).cgPath
        flagHighlightLayer.frame = bannerFrame
        flagHighlightLayer.path = flagHighlightPath(in: CGRect(origin: .zero, size: bannerFrame.size)).cgPath

        textLayer.frame = bannerFrame.insetBy(dx: 17, dy: 12)

        let planeFrame = CGRect(x: bannerFrame.maxX + 9, y: flightOrigin.y + 4 + formationBob, width: 154, height: 79)
        flightHitFrame = bannerFrame.union(planeFrame)
        ropeLayer.frame = bounds
        let tailAnchor = CGPoint(x: planeFrame.minX + 14, y: planeFrame.minY + 36)
        ropeLayer.path = ropePath(from: CGPoint(x: bannerFrame.maxX - 1, y: bannerFrame.midY), to: tailAnchor).cgPath
        tailHookLayer.frame = CGRect(x: tailAnchor.x - 2.5, y: tailAnchor.y - 2.5, width: 5, height: 5)
        tailHookLayer.path = NSBezierPath(ovalIn: tailHookLayer.bounds).cgPath

        planeLayer.frame = planeFrame
        planeLayer.path = planePath(in: planeLayer.bounds).cgPath
        bellyAccentLayer.frame = planeFrame
        bellyAccentLayer.path = bellyAccentPath(in: bellyAccentLayer.bounds).cgPath
        rearWingLayer.frame = planeFrame
        rearWingLayer.path = rearWingPath(in: rearWingLayer.bounds).cgPath
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
        tailLayer.opacity = Float(flightOpacity)
        rearWingLayer.opacity = Float(flightOpacity)
        wingLayer.opacity = Float(flightOpacity)
        planeLayer.opacity = Float(flightOpacity)
        bellyAccentLayer.opacity = Float(flightOpacity * 0.85)
        tailHookLayer.opacity = 0
        windowLayer.opacity = Float(flightOpacity)

        CATransaction.commit()
    }

    private func setupLayers() {
        bannerLayer.fillColor = NSColor(calibratedRed: 0.19, green: 0.82, blue: 0.90, alpha: 0.48).cgColor
        bannerLayer.strokeColor = NSColor(calibratedRed: 0.79, green: 0.98, blue: 1.0, alpha: 0.58).cgColor
        bannerLayer.lineWidth = 1.2
        bannerLayer.shadowColor = NSColor(calibratedRed: 0.06, green: 0.70, blue: 0.92, alpha: 1).cgColor
        bannerLayer.shadowOpacity = 0.34
        bannerLayer.shadowRadius = 16
        bannerLayer.shadowOffset = CGSize(width: 0, height: -2)

        flagHighlightLayer.fillColor = NSColor(calibratedRed: 0.88, green: 1.0, blue: 1.0, alpha: 0.30).cgColor
        ropeLayer.fillColor = nil
        ropeLayer.strokeColor = NSColor(calibratedRed: 0.48, green: 0.90, blue: 0.96, alpha: 0.90).cgColor
        ropeLayer.lineWidth = 1.35
        ropeLayer.lineCap = .round

        textLayer.string = message
        textLayer.foregroundColor = NSColor(calibratedWhite: 1, alpha: 0.98).cgColor
        textLayer.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        textLayer.fontSize = 13
        textLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        textLayer.truncationMode = .end
        textLayer.alignmentMode = .center

        planeLayer.fillColor = NSColor(calibratedRed: 0.99, green: 0.995, blue: 1.0, alpha: 1).cgColor
        planeLayer.strokeColor = NSColor(calibratedRed: 0.76, green: 0.95, blue: 1.0, alpha: 0.86).cgColor
        planeLayer.lineWidth = 1.15
        planeLayer.shadowColor = NSColor(calibratedRed: 0.02, green: 0.55, blue: 0.88, alpha: 1).cgColor
        planeLayer.shadowOpacity = 0.16
        planeLayer.shadowRadius = 10
        planeLayer.shadowOffset = CGSize(width: 0, height: -2)

        bellyAccentLayer.fillColor = nil
        bellyAccentLayer.strokeColor = NSColor(calibratedRed: 0.03, green: 0.55, blue: 0.96, alpha: 0.42).cgColor
        bellyAccentLayer.lineWidth = 2.0
        bellyAccentLayer.lineCap = .round

        rearWingLayer.fillColor = NSColor(calibratedRed: 0.70, green: 0.98, blue: 0.99, alpha: 0.64).cgColor
        rearWingLayer.strokeColor = NSColor(calibratedWhite: 1, alpha: 0.56).cgColor
        rearWingLayer.lineWidth = 0.9

        wingLayer.fillColor = NSColor(calibratedRed: 0.19, green: 0.82, blue: 0.90, alpha: 0.90).cgColor
        wingLayer.strokeColor = NSColor(calibratedRed: 0.78, green: 0.98, blue: 1.0, alpha: 0.62).cgColor
        wingLayer.lineWidth = 1

        tailLayer.fillColor = NSColor(calibratedRed: 0.25, green: 0.86, blue: 0.92, alpha: 0.95).cgColor
        tailLayer.strokeColor = NSColor(calibratedRed: 0.04, green: 0.62, blue: 0.88, alpha: 0.72).cgColor
        tailLayer.lineWidth = 1

        tailHookLayer.fillColor = NSColor(calibratedRed: 0.72, green: 0.94, blue: 0.98, alpha: 0.96).cgColor
        tailHookLayer.strokeColor = NSColor(calibratedWhite: 1, alpha: 0.72).cgColor
        tailHookLayer.lineWidth = 0.7

        windowLayer.fillColor = NSColor(calibratedRed: 0.03, green: 0.55, blue: 0.92, alpha: 0.88).cgColor

        layer?.addSublayer(bannerLayer)
        layer?.addSublayer(flagHighlightLayer)
        layer?.addSublayer(textLayer)
        layer?.addSublayer(ropeLayer)
        layer?.addSublayer(tailLayer)
        layer?.addSublayer(rearWingLayer)
        layer?.addSublayer(wingLayer)
        layer?.addSublayer(planeLayer)
        layer?.addSublayer(bellyAccentLayer)
        layer?.addSublayer(windowLayer)

        // The whole flight assembly already rises and falls together in FlightWindow.
        // Keep individual layers unanimated so the rope remains attached to the tail.
    }

    private func flagPath(in rect: CGRect, wave: CGFloat) -> NSBezierPath {
        let wave = wave * 0.16
        let r = rect.insetBy(dx: 1.0, dy: 2.5)
        let path = NSBezierPath()
        let radius = r.height / 2
        path.move(to: CGPoint(x: r.minX + radius, y: r.minY))
        path.curve(to: CGPoint(x: r.maxX - radius, y: r.minY + wave), controlPoint1: CGPoint(x: r.midX - 34, y: r.minY - 1.8), controlPoint2: CGPoint(x: r.midX + 36, y: r.minY + 2.0))
        path.curve(to: CGPoint(x: r.maxX, y: r.midY), controlPoint1: CGPoint(x: r.maxX - 6, y: r.minY + 1), controlPoint2: CGPoint(x: r.maxX, y: r.minY + 7))
        path.curve(to: CGPoint(x: r.maxX - radius, y: r.maxY - wave), controlPoint1: CGPoint(x: r.maxX, y: r.maxY - 7), controlPoint2: CGPoint(x: r.maxX - 6, y: r.maxY - 1))
        path.curve(to: CGPoint(x: r.minX + radius, y: r.maxY), controlPoint1: CGPoint(x: r.midX + 34, y: r.maxY + 1.8), controlPoint2: CGPoint(x: r.midX - 36, y: r.maxY - 2.0))
        path.curve(to: CGPoint(x: r.minX, y: r.midY), controlPoint1: CGPoint(x: r.minX + 6, y: r.maxY - 1), controlPoint2: CGPoint(x: r.minX, y: r.maxY - 7))
        path.curve(to: CGPoint(x: r.minX + radius, y: r.minY), controlPoint1: CGPoint(x: r.minX, y: r.minY + 7), controlPoint2: CGPoint(x: r.minX + 6, y: r.minY + 1))
        path.close()
        return path
    }

    private func flagHighlightPath(in rect: CGRect) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: CGPoint(x: rect.minX + 22, y: rect.maxY - 10))
        path.curve(to: CGPoint(x: rect.maxX - 26, y: rect.maxY - 11), controlPoint1: CGPoint(x: rect.width * 0.34, y: rect.maxY - 3), controlPoint2: CGPoint(x: rect.width * 0.67, y: rect.maxY - 15))
        path.line(to: CGPoint(x: rect.maxX - 42, y: rect.maxY - 16))
        path.curve(to: CGPoint(x: rect.minX + 28, y: rect.maxY - 16), controlPoint1: CGPoint(x: rect.width * 0.61, y: rect.maxY - 22), controlPoint2: CGPoint(x: rect.width * 0.30, y: rect.maxY - 12))
        path.close()
        return path
    }

    private func ropePath(from start: CGPoint, to end: CGPoint) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: start)
        path.curve(to: end, controlPoint1: CGPoint(x: start.x + 14, y: start.y + 6), controlPoint2: CGPoint(x: end.x - 20, y: end.y - 5))
        return path
    }

    private func bellyAccentPath(in rect: CGRect) -> NSBezierPath {
        let path = NSBezierPath()
        let sx = rect.width / 126
        let sy = rect.height / 78

        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: x * sx, y: y * sy)
        }

        path.move(to: p(12, 30))
        path.curve(to: p(113, 31), controlPoint1: p(36, 19), controlPoint2: p(85, 22))
        return path
    }

    private func planePath(in rect: CGRect) -> NSBezierPath {
        let path = NSBezierPath()
        let sx = rect.width / 126
        let sy = rect.height / 78

        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: x * sx, y: y * sy)
        }

        path.move(to: p(4, 40))
        path.curve(to: p(52, 43), controlPoint1: p(19, 35), controlPoint2: p(36, 38))
        path.curve(to: p(86, 52), controlPoint1: p(64, 46), controlPoint2: p(74, 51))
        path.curve(to: p(121, 43), controlPoint1: p(104, 58), controlPoint2: p(119, 53))
        path.curve(to: p(111, 29), controlPoint1: p(125, 35), controlPoint2: p(120, 30))
        path.curve(to: p(27, 27), controlPoint1: p(78, 24), controlPoint2: p(48, 25))
        path.curve(to: p(4, 40), controlPoint1: p(13, 28), controlPoint2: p(7, 34))
        path.close()
        return path
    }

    private func rearWingPath(in rect: CGRect) -> NSBezierPath {
        let path = NSBezierPath()
        let sx = rect.width / 126
        let sy = rect.height / 78

        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: x * sx, y: y * sy)
        }

        path.move(to: p(33, 39))
        path.line(to: p(20, 70))
        path.curve(to: p(54, 45), controlPoint1: p(30, 66), controlPoint2: p(43, 53))
        path.line(to: p(42, 37))
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

        path.move(to: p(55, 43))
        path.line(to: p(39, 75))
        path.curve(to: p(83, 52), controlPoint1: p(51, 72), controlPoint2: p(67, 62))
        path.line(to: p(67, 40))
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

        path.move(to: p(22, 35))
        path.line(to: p(4, 52))
        path.curve(to: p(42, 39), controlPoint1: p(14, 50), controlPoint2: p(31, 44))
        path.close()
        return path
    }

    private func windowPath(in rect: CGRect) -> NSBezierPath {
        let path = NSBezierPath()
        let sx = rect.width / 126
        let sy = rect.height / 78

        [91, 102, 113].forEach { x in
            let oval = NSBezierPath(ovalIn: CGRect(x: CGFloat(x) * sx, y: 39 * sy, width: 4.5 * sx, height: 4.5 * sy))
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
