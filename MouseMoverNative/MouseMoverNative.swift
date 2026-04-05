//
//  MouseMoverNative.swift
//  deceiverMe
//
//  Native macOS menu bar app: configurable cursor drift, sessions, and optional idle-sleep prevention.
//

import Cocoa
import CoreGraphics
import ApplicationServices
import Carbon
import UserNotifications
import IOKit.pwr_mgt

enum MovementDirection: Int {
    case right = 0
    case left = 1
    case up = 2
    case down = 3
    case circular = 4
}

// MARK: - Session scheduling

/// How the current session should end (active elapsed time vs wall clock vs never).
enum SessionEndMode: Equatable {
    case indefinite
    case duration(TimeInterval)
    case until(Date)
}

enum PrefsSessionKind: Int {
    case indefinite = 0
    case duration = 1
    case untilClock = 2
}

// MARK: - Visual language (distinct from stock “utility panel” apps)

private enum DMTheme {
    /// Left rail + accents — deep blue-violet (not system gray cards).
    static let rail = NSColor(calibratedHue: 0.62, saturation: 0.22, brightness: 0.20, alpha: 1)
    static let accent = NSColor(calibratedHue: 0.08, saturation: 0.55, brightness: 0.92, alpha: 1)
    static let accentMuted = NSColor(calibratedHue: 0.08, saturation: 0.35, brightness: 0.55, alpha: 1)
    static let ink = NSColor.labelColor
    static let whisper = NSColor.secondaryLabelColor

    static func badgeIdle() -> NSColor { NSColor(calibratedWhite: 0.45, alpha: 0.18) }
    static func badgeLive() -> NSColor { NSColor(calibratedHue: 0.38, saturation: 0.45, brightness: 0.42, alpha: 0.25) }
    static func badgeHold() -> NSColor { NSColor(calibratedHue: 0.12, saturation: 0.40, brightness: 0.85, alpha: 0.22) }
}

// MARK: - Carbon hotkey callback (C ABI)

private func carbonHotKeyCallback(
    nextHandler: EventHandlerCallRef?,
    theEvent: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData = userData else { return OSStatus(eventNotHandledErr) }
    let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        theEvent,
        UInt32(kEventParamDirectObject),
        UInt32(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr, hotKeyID.id == 1 else { return OSStatus(eventNotHandledErr) }
    DispatchQueue.main.async {
        delegate.handleGlobalHotkey()
    }
    return noErr
}

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    // Menu bar
    var statusItem: NSStatusItem!
    var menu: NSMenu!
    var statusMenuItem: NSMenuItem!
    var elapsedTimeMenuItem: NSMenuItem!
    var remainingTimeMenuItem: NSMenuItem!
    var iterationMenuItem: NSMenuItem!
    var progressMenuItem: NSMenuItem!
    var pauseMenuItem: NSMenuItem!
    var stopMenuItem: NSMenuItem!
    var showWindowMenuItem: NSMenuItem!
    var preferencesMenuItem: NSMenuItem!
    var quitMenuItem: NSMenuItem!

    // Desktop window
    var window: NSWindow!
    var statusLabel: NSTextField!
    var remainingTimeLabel: NSTextField!
    var iterationLabel: NSTextField!
    var progressBar: NSProgressIndicator!
    var startButton: NSButton!
    var pauseButton: NSButton!
    var stopButton: NSButton!
    var preferencesButton: NSButton!
    var statusDot: NSView!
    var heroTimeLabel: NSTextField!
    var railView: NSView!
    var badgeLabel: NSTextField!

    // Configuration window
    var configWindow: NSWindow!
    var pixelTextField: NSTextField!
    var directionPopUp: NSPopUpButton!
    var intervalTextField: NSTextField!
    var durationTextField: NSTextField!
    var sessionModePopUp: NSPopUpButton!
    var untilDatePicker: NSDatePicker!
    var untilLabel: NSTextField!
    var notifyCheckBox: NSButton!
    var keepAwakeCheckBox: NSButton!
    var hotkeyCaptureButton: NSButton!
    var hotkeySummaryLabel: NSTextField!
    var saveButton: NSButton!

    // State
    var isRunning = false
    var isPaused = false
    var startTime: Date?
    var pausedTime: TimeInterval = 0
    var pauseStartTime: Date?
    var updateTimer: Timer?
    var mouseMoveTimer: Timer?
    var iteration = 0
    var circularAngle: Double = 0.0

    /// End mode for the active session (set when starting).
    var activeSessionEnd: SessionEndMode = .duration(8 * 60 * 60)

    // Configuration (movement + default session)
    var pixelMove: CGFloat = 5.0
    var direction: MovementDirection = .right
    var moveInterval: TimeInterval = 10.0
    /// Default max duration when session kind is duration (seconds).
    var totalDuration: TimeInterval = 8 * 60 * 60
    var prefsSessionKind: PrefsSessionKind = .duration
    var sessionUntilDate: Date = Calendar.current.date(byAdding: .hour, value: 2, to: Date()) ?? Date().addingTimeInterval(7200)
    var notifyOnSessionEnd = true
    var preventIdleSleepWhileRunning = false

    /// Carbon virtual key code and Carbon modifier flags (cmdKey | shiftKey | ...).
    var hotkeyKeyCode: UInt32 = UInt32(kVK_Space)
    var hotkeyCarbonModifiers: UInt32 = UInt32(cmdKey | shiftKey)

    // Hotkey + power
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerRef: EventHandlerRef?
    private var idleSleepAssertionID: IOPMAssertionID = 0
    private var isRecordingHotkey = false
    private var hotkeyLocalMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        loadPreferences()
        if #available(macOS 10.14, *) {
            UNUserNotificationCenter.current().delegate = self
            requestNotificationPermissionIfNeeded()
        }
        setupMenuBar()
        setupMenu()
        setupDesktopWindow()
        setupConfigurationWindow()
        installCarbonHotKey()
        updateMenu()
        updateDesktopWindow()

        updateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateMenu()
            self?.updateDesktopWindow()
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
    }

    func applicationWillTerminate(_ notification: Notification) {
        releaseIdleSleepAssertion()
        unregisterCarbonHotKey()
        stopMovement(notify: false, reason: nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - URL scheme (deceiverme://)

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            handleDeepLink(url)
        }
    }

    private func handleDeepLink(_ url: URL) {
        guard url.scheme?.lowercased() == "deceiverme" else { return }
        let host = (url.host ?? "").lowercased()
        let path = url.path.lowercased()
        let command = host.isEmpty ? String(path.drop(while: { $0 == "/" })) : host

        var durationSeconds: TimeInterval?
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let q = components.queryItems {
            if let d = q.first(where: { $0.name == "duration" })?.value,
               let v = TimeInterval(d), v > 0 {
                durationSeconds = v
            }
            if let u = q.first(where: { $0.name == "until" })?.value,
               let ts = TimeInterval(u) {
                let until = Date(timeIntervalSince1970: ts)
                DispatchQueue.main.async { self.applyURLStart(until: until) }
                return
            }
        }

        DispatchQueue.main.async {
            switch command {
            case "start":
                if let s = durationSeconds {
                    self.startMovement(preset: .duration(s))
                } else {
                    self.startMovement(preset: nil)
                }
            case "stop":
                self.stopMovement(notify: false, reason: nil)
            case "pause", "toggle":
                if !self.isRunning {
                    self.startMovement(preset: nil)
                } else {
                    self.pauseMovement()
                }
            default:
                break
            }
        }
    }

    private func applyURLStart(until: Date) {
        startMovement(preset: .until(until))
    }

    // MARK: - Menu bar

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            if #available(macOS 11.0, *) {
                button.image = createMenuBarIcon()
            } else {
                button.title = "🎯"
            }
            button.image?.isTemplate = true
            button.toolTip = "deceiverMe"
        }
    }

    /// Drift rings — template image; reads as “motion,” not a stock cursor or play glyph.
    func createMenuBarIcon() -> NSImage? {
        let s: CGFloat = 18
        let image = NSImage(size: NSSize(width: s, height: s))
        image.lockFocus()
        NSColor.black.setStroke()
        let lw: CGFloat = 1.35
        for i in 0..<3 {
            let inset = CGFloat(i) * 2.8 + 1.5
            let r = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
            let oval = NSBezierPath(ovalIn: r)
            oval.lineWidth = lw
            oval.stroke()
        }
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    func setupMenu() {
        menu = NSMenu()

        statusMenuItem = NSMenuItem(title: "State — Idle", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        elapsedTimeMenuItem = NSMenuItem(title: "Clock: 00:00:00", action: nil, keyEquivalent: "")
        elapsedTimeMenuItem.isEnabled = false
        menu.addItem(elapsedTimeMenuItem)

        remainingTimeMenuItem = NSMenuItem(title: "Horizon: —", action: nil, keyEquivalent: "")
        remainingTimeMenuItem.isEnabled = false
        menu.addItem(remainingTimeMenuItem)

        iterationMenuItem = NSMenuItem(title: "Ticks: 0", action: nil, keyEquivalent: "")
        iterationMenuItem.isEnabled = false
        menu.addItem(iterationMenuItem)

        progressMenuItem = NSMenuItem(title: "Carry: 0%", action: nil, keyEquivalent: "")
        progressMenuItem.isEnabled = false
        menu.addItem(progressMenuItem)

        menu.addItem(NSMenuItem.separator())

        let beginMenu = NSMenu(title: "Begin drift")
        beginMenu.addItem(menuItem(title: "From saved recipe", action: #selector(startWithPreferences), tag: 0))
        beginMenu.addItem(NSMenuItem.separator())
        beginMenu.addItem(menuItem(title: "Open horizon (no end)", action: #selector(startIndefinite), tag: 0))
        beginMenu.addItem(menuItem(title: "One hour arc", action: #selector(startOneHour), tag: 0))
        beginMenu.addItem(menuItem(title: "Quarter-day arc", action: #selector(startFourHours), tag: 0))
        beginMenu.addItem(menuItem(title: "Full-day arc", action: #selector(startEightHours), tag: 0))
        let beginItem = NSMenuItem(title: "Begin drift", action: nil, keyEquivalent: "")
        beginItem.submenu = beginMenu
        menu.addItem(beginItem)

        pauseMenuItem = NSMenuItem(title: "Hold", action: #selector(pauseMovement), keyEquivalent: "")
        pauseMenuItem.target = self
        pauseMenuItem.isEnabled = false
        menu.addItem(pauseMenuItem)

        stopMenuItem = NSMenuItem(title: "Finish drift", action: #selector(stopMovementFromMenu), keyEquivalent: "")
        stopMenuItem.target = self
        stopMenuItem.isEnabled = false
        menu.addItem(stopMenuItem)

        menu.addItem(NSMenuItem.separator())

        showWindowMenuItem = NSMenuItem(title: "Open studio", action: #selector(showWindow), keyEquivalent: "w")
        showWindowMenuItem.target = self
        menu.addItem(showWindowMenuItem)

        preferencesMenuItem = NSMenuItem(title: "Tune drift…", action: #selector(showPreferences), keyEquivalent: ",")
        preferencesMenuItem.target = self
        menu.addItem(preferencesMenuItem)

        menu.addItem(NSMenuItem.separator())

        quitMenuItem = NSMenuItem(title: "Quit deceiverMe", action: #selector(quitApp), keyEquivalent: "q")
        quitMenuItem.target = self
        menu.addItem(quitMenuItem)

        statusItem.menu = menu
    }

    private func menuItem(title: String, action: Selector, tag: Int) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.tag = tag
        return item
    }

    @objc func startWithPreferences() {
        startMovement(preset: nil)
    }

    @objc func startIndefinite() {
        startMovement(preset: .indefinite)
    }

    @objc func startOneHour() {
        startMovement(preset: .duration(3600))
    }

    @objc func startFourHours() {
        startMovement(preset: .duration(4 * 3600))
    }

    @objc func startEightHours() {
        startMovement(preset: .duration(8 * 3600))
    }

    @objc func stopMovementFromMenu() {
        stopMovement(notify: false, reason: nil)
    }

    // MARK: - Desktop + preferences UI

    func setupDesktopWindow() {
        let windowRect = NSRect(x: 0, y: 0, width: 560, height: 456)
        window = NSWindow(
            contentRect: windowRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Studio — deceiverMe"
        window.center()
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor.windowBackgroundColor

        let cv = window.contentView!
        let pad: CGFloat = 20
        let railW: CGFloat = 52
        let mainX = railW + 16

        railView = NSView(frame: NSRect(x: 0, y: 0, width: railW, height: cv.bounds.height))
        railView.autoresizingMask = [.height, .maxXMargin]
        railView.wantsLayer = true
        railView.layer?.backgroundColor = DMTheme.rail.cgColor
        cv.addSubview(railView)

        var y = cv.bounds.height - pad - 22

        badgeLabel = NSTextField(labelWithString: "IDLE")
        badgeLabel.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        badgeLabel.alignment = .center
        badgeLabel.frame = NSRect(x: cv.bounds.width - pad - 76, y: y, width: 76, height: 22)
        badgeLabel.autoresizingMask = [.minYMargin, .minXMargin]
        badgeLabel.wantsLayer = true
        badgeLabel.layer?.cornerRadius = 11
        badgeLabel.layer?.backgroundColor = DMTheme.badgeIdle().cgColor
        badgeLabel.isBordered = false
        badgeLabel.drawsBackground = false
        badgeLabel.textColor = DMTheme.ink
        cv.addSubview(badgeLabel)

        y -= 8
        let wordmark = NSTextField(labelWithString: "deceiverMe")
        wordmark.font = NSFont.systemFont(ofSize: 26, weight: .thin)
        wordmark.frame = NSRect(x: mainX, y: y - 30, width: 280, height: 32)
        wordmark.autoresizingMask = [.minYMargin, .width]
        cv.addSubview(wordmark)

        y -= 42
        let tagline = NSTextField(wrappingLabelWithString:
            "Quiet cursor choreography — for demos, long sessions, and Macs that won’t stay lucid.")
        tagline.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        tagline.textColor = DMTheme.whisper
        tagline.frame = NSRect(x: mainX, y: y - 40, width: cv.bounds.width - mainX - pad, height: 40)
        tagline.autoresizingMask = [.minYMargin, .width]
        cv.addSubview(tagline)

        y -= 52
        heroTimeLabel = NSTextField(labelWithString: "00:00:00")
        if #available(macOS 10.15, *) {
            heroTimeLabel.font = NSFont.monospacedSystemFont(ofSize: 44, weight: .light)
        } else {
            heroTimeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 44, weight: .light)
        }
        heroTimeLabel.textColor = DMTheme.accent
        heroTimeLabel.frame = NSRect(x: mainX, y: y - 52, width: cv.bounds.width - mainX - pad, height: 54)
        heroTimeLabel.autoresizingMask = [.minYMargin, .width]
        cv.addSubview(heroTimeLabel)

        y -= 64
        let heroCaption = NSTextField(labelWithString: "elapsed on this drift")
        heroCaption.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        heroCaption.textColor = DMTheme.accentMuted
        heroCaption.frame = NSRect(x: mainX, y: y - 16, width: 240, height: 16)
        heroCaption.autoresizingMask = [.minYMargin, .width]
        cv.addSubview(heroCaption)

        y -= 28
        let statusCard = NSView(frame: NSRect(x: mainX, y: y - 132, width: cv.bounds.width - mainX - pad, height: 132))
        statusCard.autoresizingMask = [.minYMargin, .width]
        statusCard.wantsLayer = true
        statusCard.layer?.cornerRadius = 14
        statusCard.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        statusCard.layer?.borderWidth = 1
        if #available(macOS 10.14, *) {
            statusCard.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        } else {
            statusCard.layer?.borderColor = NSColor.lightGray.cgColor
        }
        cv.addSubview(statusCard)

        var cardY = statusCard.bounds.height - 14
        let statusContainer = NSView(frame: NSRect(x: 14, y: cardY - 28, width: statusCard.bounds.width - 28, height: 26))
        statusCard.addSubview(statusContainer)

        statusDot = NSView(frame: NSRect(x: 0, y: 6, width: 10, height: 10))
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 5
        statusDot.layer?.backgroundColor = NSColor.systemRed.cgColor
        statusContainer.addSubview(statusDot)

        statusLabel = NSTextField(labelWithString: "Idle")
        statusLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        statusLabel.textColor = .systemRed
        statusLabel.frame = NSRect(x: 18, y: 2, width: 160, height: 22)
        statusContainer.addSubview(statusLabel)

        cardY -= 40
        let gridW = statusCard.bounds.width - 28
        let statsGrid = NSView(frame: NSRect(x: 14, y: cardY - 86, width: gridW, height: 86))
        statusCard.addSubview(statsGrid)

        let colW = (gridW - 12) / 3
        let remainingContainer = createStatBox(title: "Horizon", value: "—", frame: NSRect(x: 0, y: 52, width: colW, height: 52))
        statsGrid.addSubview(remainingContainer)
        remainingTimeLabel = (remainingContainer.subviews[1] as? NSTextField) ?? NSTextField()

        let iterationContainer = createStatBox(title: "Ticks", value: "0", frame: NSRect(x: colW + 6, y: 52, width: colW, height: 52))
        statsGrid.addSubview(iterationContainer)
        iterationLabel = (iterationContainer.subviews[1] as? NSTextField) ?? NSTextField()

        let progressContainer = NSView(frame: NSRect(x: 2 * colW + 12, y: 52, width: colW, height: 52))
        statsGrid.addSubview(progressContainer)

        let progressTitle = NSTextField(labelWithString: "Carry-through")
        progressTitle.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        progressTitle.textColor = DMTheme.whisper
        progressTitle.frame = NSRect(x: 0, y: 34, width: colW, height: 14)
        progressContainer.addSubview(progressTitle)

        progressBar = NSProgressIndicator(frame: NSRect(x: 0, y: 8, width: colW, height: 18))
        progressBar.style = .bar
        progressBar.minValue = 0
        progressBar.maxValue = 100
        progressBar.doubleValue = 0
        progressBar.controlSize = .small
        progressContainer.addSubview(progressBar)

        y -= 148
        let buttonContainer = NSView(frame: NSRect(x: mainX, y: y - 44, width: cv.bounds.width - mainX - pad, height: 44))
        buttonContainer.autoresizingMask = [.minYMargin, .width]
        cv.addSubview(buttonContainer)

        startButton = createModernButton(title: "Begin", action: #selector(startWithPreferences), frame: NSRect(x: 0, y: 4, width: 112, height: 36))
        buttonContainer.addSubview(startButton)

        pauseButton = createModernButton(title: "Hold", action: #selector(pauseMovement), frame: NSRect(x: 124, y: 4, width: 96, height: 36))
        pauseButton.isEnabled = false
        buttonContainer.addSubview(pauseButton)

        stopButton = createModernButton(title: "Finish", action: #selector(stopMovementFromMenu), frame: NSRect(x: 230, y: 4, width: 96, height: 36))
        stopButton.isEnabled = false
        buttonContainer.addSubview(stopButton)

        preferencesButton = createModernButton(title: "Tune drift…", action: #selector(showPreferences), frame: NSRect(x: 336, y: 4, width: 124, height: 36))
        buttonContainer.addSubview(preferencesButton)
    }

    func createStatBox(title: String, value: String, frame: NSRect) -> NSView {
        let container = NSView(frame: frame)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.frame = NSRect(x: 0, y: frame.height - 20, width: frame.width, height: 16)
        container.addSubview(titleLabel)

        let valueLabel = NSTextField(labelWithString: value)
        if #available(macOS 10.15, *) {
            valueLabel.font = NSFont.monospacedSystemFont(ofSize: 18, weight: .semibold)
        } else {
            valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 18, weight: .semibold)
        }
        valueLabel.frame = NSRect(x: 0, y: 4, width: frame.width, height: 24)
        container.addSubview(valueLabel)

        return container
    }

    func createModernButton(title: String, action: Selector, frame: NSRect) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.frame = frame
        button.bezelStyle = .rounded
        button.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        button.wantsLayer = true
        button.layer?.cornerRadius = 8
        return button
    }

    func setupConfigurationWindow() {
        let windowRect = NSRect(x: 0, y: 0, width: 440, height: 520)
        configWindow = NSWindow(
            contentRect: windowRect,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        configWindow.title = "Tune drift — deceiverMe"
        configWindow.center()
        configWindow.isReleasedWhenClosed = false

        let contentView = configWindow.contentView!
        let padding: CGFloat = 24
        var yPosition = contentView.bounds.height - padding - 30

        let titleLabel = NSTextField(labelWithString: "Motion recipe")
        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        titleLabel.frame = NSRect(x: padding, y: yPosition, width: 320, height: 22)
        contentView.addSubview(titleLabel)
        yPosition -= 36

        pixelTextField = createConfigField(label: "Stride (pixels):", value: String(Int(pixelMove)), y: &yPosition, contentView: contentView, padding: padding)
        directionPopUp = createConfigPopUp(
            label: "Bearing:",
            items: ["Drift right", "Drift left", "Drift up", "Drift down", "Orbit"],
            selected: direction.rawValue,
            y: &yPosition,
            contentView: contentView,
            padding: padding
        )
        intervalTextField = createConfigField(label: "Cadence (seconds):", value: String(Int(moveInterval)), y: &yPosition, contentView: contentView, padding: padding)

        let sessionLabel = NSTextField(labelWithString: "Default horizon:")
        sessionLabel.frame = NSRect(x: padding, y: yPosition, width: 180, height: 20)
        contentView.addSubview(sessionLabel)
        sessionModePopUp = NSPopUpButton(frame: NSRect(x: 200, y: yPosition - 4, width: 220, height: 24))
        sessionModePopUp.addItems(withTitles: ["Open end", "Timed arc (hours below)", "Land at date & time"])
        sessionModePopUp.selectItem(at: prefsSessionKind.rawValue)
        sessionModePopUp.target = self
        sessionModePopUp.action = #selector(sessionModeChanged)
        contentView.addSubview(sessionModePopUp)
        yPosition -= 40

        durationTextField = createConfigField(label: "Arc length (hours):", value: String(Int(totalDuration / 3600)), y: &yPosition, contentView: contentView, padding: padding)

        untilLabel = NSTextField(labelWithString: "Land at:")
        untilLabel.frame = NSRect(x: padding, y: yPosition, width: 180, height: 20)
        contentView.addSubview(untilLabel)
        untilDatePicker = NSDatePicker(frame: NSRect(x: 200, y: yPosition - 4, width: 220, height: 24))
        untilDatePicker.datePickerStyle = .textFieldAndStepper
        untilDatePicker.datePickerElements = [.yearMonthDay, .hourMinute]
        untilDatePicker.dateValue = sessionUntilDate
        contentView.addSubview(untilDatePicker)
        yPosition -= 40

        notifyCheckBox = NSButton(checkboxWithTitle: "Ping when this drift lands", target: nil, action: nil)
        notifyCheckBox.frame = NSRect(x: padding, y: yPosition, width: 360, height: 20)
        notifyCheckBox.state = notifyOnSessionEnd ? .on : .off
        contentView.addSubview(notifyCheckBox)
        yPosition -= 28

        keepAwakeCheckBox = NSButton(checkboxWithTitle: "Keep Mac awake while drifting (no idle sleep)", target: nil, action: nil)
        keepAwakeCheckBox.frame = NSRect(x: padding, y: yPosition, width: 360, height: 20)
        keepAwakeCheckBox.state = preventIdleSleepWhileRunning ? .on : .off
        contentView.addSubview(keepAwakeCheckBox)
        yPosition -= 32

        let hkLabel = NSTextField(labelWithString: "Global shortcut:")
        hkLabel.frame = NSRect(x: padding, y: yPosition, width: 100, height: 20)
        contentView.addSubview(hkLabel)
        hotkeySummaryLabel = NSTextField(labelWithString: hotkeySummaryString())
        hotkeySummaryLabel.frame = NSRect(x: 200, y: yPosition, width: 220, height: 20)
        hotkeySummaryLabel.textColor = .secondaryLabelColor
        contentView.addSubview(hotkeySummaryLabel)
        yPosition -= 28

        hotkeyCaptureButton = NSButton(title: "Record shortcut…", target: self, action: #selector(beginHotkeyCapture))
        hotkeyCaptureButton.frame = NSRect(x: 200, y: yPosition, width: 220, height: 28)
        hotkeyCaptureButton.bezelStyle = .rounded
        contentView.addSubview(hotkeyCaptureButton)
        yPosition -= 44

        saveButton = createModernButton(title: "Save recipe", action: #selector(savePreferences), frame: NSRect(x: padding, y: yPosition, width: 120, height: 32))
        contentView.addSubview(saveButton)

        let cancelButton = createModernButton(title: "Close", action: #selector(closePreferences), frame: NSRect(x: 152, y: yPosition, width: 100, height: 32))
        contentView.addSubview(cancelButton)

        sessionModeChanged()
    }

    @objc func sessionModeChanged() {
        let kind = PrefsSessionKind(rawValue: sessionModePopUp.indexOfSelectedItem) ?? .duration
        durationTextField.isEnabled = (kind == .duration)
        untilLabel.isHidden = (kind != .untilClock)
        untilDatePicker.isHidden = (kind != .untilClock)
    }

    func createConfigField(label: String, value: String, y: inout CGFloat, contentView: NSView, padding: CGFloat) -> NSTextField {
        let labelField = NSTextField(labelWithString: label)
        labelField.frame = NSRect(x: padding, y: y, width: 180, height: 20)
        contentView.addSubview(labelField)

        let textField = NSTextField(frame: NSRect(x: 200, y: y - 2, width: 120, height: 24))
        textField.stringValue = value
        textField.formatter = NumberFormatter()
        textField.wantsLayer = true
        textField.layer?.cornerRadius = 6
        contentView.addSubview(textField)

        y -= 40
        return textField
    }

    func createConfigPopUp(label: String, items: [String], selected: Int, y: inout CGFloat, contentView: NSView, padding: CGFloat) -> NSPopUpButton {
        let labelField = NSTextField(labelWithString: label)
        labelField.frame = NSRect(x: padding, y: y, width: 180, height: 20)
        contentView.addSubview(labelField)

        let popUp = NSPopUpButton(frame: NSRect(x: 200, y: y - 4, width: 230, height: 24))
        popUp.addItems(withTitles: items)
        popUp.selectItem(at: selected)
        popUp.wantsLayer = true
        popUp.layer?.cornerRadius = 6
        contentView.addSubview(popUp)

        y -= 40
        return popUp
    }

    private func hotkeySummaryString() -> String {
        let mods = carbonModifiersToString(hotkeyCarbonModifiers)
        let key = virtualKeyToString(hotkeyKeyCode)
        return "\(mods)\(key)"
    }

    private func carbonModifiersToString(_ m: UInt32) -> String {
        var parts: [String] = []
        if m & UInt32(controlKey) != 0 { parts.append("⌃") }
        if m & UInt32(optionKey) != 0 { parts.append("⌥") }
        if m & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if m & UInt32(cmdKey) != 0 { parts.append("⌘") }
        return parts.joined()
    }

    private func virtualKeyToString(_ code: UInt32) -> String {
        switch Int(code) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Escape: return "⎋"
        default:
            if code >= 0 && code < 128 {
                return "Key \(code)"
            }
            return "Key \(code)"
        }
    }

    @objc func beginHotkeyCapture() {
        guard !isRecordingHotkey else { return }
        isRecordingHotkey = true
        hotkeyCaptureButton.title = "Listening… (Esc to cancel)"
        configWindow.makeKeyAndOrderFront(nil)

        hotkeyLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self = self, self.isRecordingHotkey else { return event }
            if event.type == .keyDown {
                if event.keyCode == UInt16(kVK_Escape) {
                    self.endHotkeyCapture(cancelled: true)
                    return nil
                }
                let mods = event.modifierFlags.carbonModifiers
                if mods == 0 {
                    return event
                }
                self.hotkeyCarbonModifiers = mods
                self.hotkeyKeyCode = UInt32(event.keyCode)
                self.endHotkeyCapture(cancelled: false)
                return nil
            }
            return event
        }
    }

    private func endHotkeyCapture(cancelled: Bool) {
        isRecordingHotkey = false
        hotkeyCaptureButton.title = "Record shortcut…"
        if let mon = hotkeyLocalMonitor {
            NSEvent.removeMonitor(mon)
            hotkeyLocalMonitor = nil
        }
        if !cancelled {
            hotkeySummaryLabel.stringValue = hotkeySummaryString()
            installCarbonHotKey()
        }
    }

    // MARK: - Carbon hotkey

    func handleGlobalHotkey() {
        if !isRunning {
            startMovement(preset: nil)
        } else {
            pauseMovement()
        }
    }

    private func installCarbonHotKey() {
        unregisterCarbonHotKey()

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handler: EventHandlerUPP = carbonHotKeyCallback
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType, selfPtr, &hotKeyHandlerRef)
        guard installStatus == noErr else { return }

        let hotKeyID = EventHotKeyID(signature: OSType(0x4443_564D), id: 1)
        let status = RegisterEventHotKey(hotkeyKeyCode, hotkeyCarbonModifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            RemoveEventHandler(hotKeyHandlerRef)
            hotKeyHandlerRef = nil
        }
    }

    private func unregisterCarbonHotKey() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let h = hotKeyHandlerRef {
            RemoveEventHandler(h)
            hotKeyHandlerRef = nil
        }
    }

    // MARK: - Notifications

    @available(macOS 10.14, *)
    private func requestNotificationPermissionIfNeeded() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    private func postSessionEndedNotification(reason: String) {
        guard notifyOnSessionEnd else { return }
        if #available(macOS 10.14, *) {
            let content = UNMutableNotificationContent()
            content.title = "Drift landed"
            content.subtitle = "deceiverMe"
            content.body = reason
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
        }
    }

    @available(macOS 10.14, *)
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if #available(macOS 11.0, *) {
            completionHandler([.banner, .sound])
        } else {
            completionHandler([.alert, .sound])
        }
    }

    // MARK: - Idle sleep assertion

    private func updateIdleSleepAssertion() {
        let want = preventIdleSleepWhileRunning && isRunning && !isPaused
        if want {
            if idleSleepAssertionID == 0 {
                var id: IOPMAssertionID = 0
                let reason = "deceiverMe active session" as CFString
                let result = IOPMAssertionCreateWithName(
                    kIOPMAssertionTypeNoIdleSleep as CFString,
                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                    reason,
                    &id
                )
                if result == kIOReturnSuccess {
                    idleSleepAssertionID = id
                }
            }
        } else {
            releaseIdleSleepAssertion()
        }
    }

    private func releaseIdleSleepAssertion() {
        if idleSleepAssertionID != 0 {
            IOPMAssertionRelease(idleSleepAssertionID)
            idleSleepAssertionID = 0
        }
    }

    // MARK: - Session resolution

    private func defaultSessionEndFromPrefs() -> SessionEndMode {
        switch prefsSessionKind {
        case .indefinite:
            return .indefinite
        case .duration:
            return .duration(max(60, totalDuration))
        case .untilClock:
            return .until(sessionUntilDate)
        }
    }

    private func remainingDescription(elapsedActive: TimeInterval) -> (text: String, progressMax: TimeInterval?, progressValue: TimeInterval) {
        switch activeSessionEnd {
        case .indefinite:
            return ("∞", nil, 0)
        case .duration(let cap):
            let left = max(0, cap - elapsedActive)
            return (formatTime(left), cap, min(cap, elapsedActive))
        case .until(let end):
            let left = end.timeIntervalSinceNow
            if left <= 0 {
                return ("00:00:00", nil, 0)
            }
            let start = startTime ?? Date()
            let total = max(1, end.timeIntervalSince(start))
            let done = min(total, total - left)
            return (formatTime(left), total, done)
        }
    }

    private func shouldAutoStop(elapsedActive: TimeInterval) -> Bool {
        if isPaused { return false }
        switch activeSessionEnd {
        case .indefinite:
            return false
        case .duration(let cap):
            return elapsedActive >= cap
        case .until(let end):
            return Date() >= end
        }
    }

    // MARK: - Actions

    @objc func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showPreferences() {
        pixelTextField.stringValue = String(Int(pixelMove))
        directionPopUp.selectItem(at: direction.rawValue)
        intervalTextField.stringValue = String(Int(moveInterval))
        durationTextField.stringValue = String(Int(totalDuration / 3600))
        sessionModePopUp.selectItem(at: prefsSessionKind.rawValue)
        untilDatePicker.dateValue = sessionUntilDate
        notifyCheckBox.state = notifyOnSessionEnd ? .on : .off
        keepAwakeCheckBox.state = preventIdleSleepWhileRunning ? .on : .off
        hotkeySummaryLabel.stringValue = hotkeySummaryString()
        sessionModeChanged()

        configWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func closePreferences() {
        configWindow.orderOut(nil)
    }

    @objc func savePreferences() {
        guard !isRunning else {
            let alert = NSAlert()
            alert.messageText = "Cannot Change Settings"
            alert.informativeText = "Stop the session before changing settings."
            alert.alertStyle = .warning
            alert.runModal()
            return
        }

        if let pixels = Double(pixelTextField.stringValue), pixels > 0 {
            pixelMove = CGFloat(pixels)
        }

        if let interval = Double(intervalTextField.stringValue), interval > 0 {
            moveInterval = interval
        }

        if let hours = Double(durationTextField.stringValue), hours > 0 {
            totalDuration = hours * 3600
        }

        direction = MovementDirection(rawValue: directionPopUp.indexOfSelectedItem) ?? .right
        prefsSessionKind = PrefsSessionKind(rawValue: sessionModePopUp.indexOfSelectedItem) ?? .duration
        sessionUntilDate = untilDatePicker.dateValue
        notifyOnSessionEnd = (notifyCheckBox.state == .on)
        preventIdleSleepWhileRunning = (keepAwakeCheckBox.state == .on)

        savePreferencesToDefaults()
        installCarbonHotKey()
        closePreferences()

        updateMenu()
        updateDesktopWindow()
    }

    func startMovement(preset: SessionEndMode?) {
        guard !isRunning else { return }

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let accessEnabled = AXIsProcessTrustedWithOptions(options as CFDictionary)

        if !accessEnabled {
            let alert = NSAlert()
            alert.messageText = "Accessibility Permission Required"
            alert.informativeText = "Grant Accessibility in System Settings → Privacy & Security → Accessibility, then restart the app."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")

            if alert.runModal() == .alertFirstButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
            return
        }

        activeSessionEnd = preset ?? defaultSessionEndFromPrefs()

        isRunning = true
        isPaused = false

        if pausedTime > 0 {
            startTime = Date().addingTimeInterval(-pausedTime)
            pausedTime = 0
        } else {
            startTime = Date()
        }

        pauseStartTime = nil
        iteration = 0
        circularAngle = 0.0

        updateIdleSleepAssertion()
        updateMenu()
        updateDesktopWindow()

        mouseMoveTimer = Timer.scheduledTimer(withTimeInterval: moveInterval, repeats: true) { [weak self] _ in
            self?.moveMouse()
        }

        moveMouse()
    }

    @objc func pauseMovement() {
        guard isRunning else { return }

        if isPaused {
            isPaused = false
            if let pauseStart = pauseStartTime {
                pausedTime += Date().timeIntervalSince(pauseStart)
                pauseStartTime = nil
            }

            mouseMoveTimer = Timer.scheduledTimer(withTimeInterval: moveInterval, repeats: true) { [weak self] _ in
                self?.moveMouse()
            }
        } else {
            isPaused = true
            pauseStartTime = Date()
            mouseMoveTimer?.invalidate()
            mouseMoveTimer = nil
        }

        updateIdleSleepAssertion()
        updateMenu()
        updateDesktopWindow()
    }

    func stopMovement(notify: Bool, reason: String?) {
        guard isRunning else { return }

        let endedByTimer = notify
        isRunning = false
        isPaused = false
        mouseMoveTimer?.invalidate()
        mouseMoveTimer = nil

        if let start = startTime {
            let elapsed = Date().timeIntervalSince(start) - pausedTime
            let hours = elapsed / 3600
            print("[deceiverMe] Stopped after \(iteration) iterations, \(String(format: "%.2f", hours)) h active")
        }

        startTime = nil
        pausedTime = 0
        pauseStartTime = nil

        releaseIdleSleepAssertion()

        if endedByTimer, let r = reason {
            postSessionEndedNotification(reason: r)
        }

        updateMenu()
        updateDesktopWindow()
    }

    @objc func quitApp() {
        stopMovement(notify: false, reason: nil)
        NSApplication.shared.terminate(nil)
    }

    func moveMouse() {
        guard isRunning && !isPaused else { return }

        let currentLocation = NSEvent.mouseLocation
        if let screen = NSScreen.main {
            let screenHeight = screen.frame.height
            let screenWidth = screen.frame.width
            let cgLocation = CGPoint(x: currentLocation.x, y: screenHeight - currentLocation.y)

            var newLocation = cgLocation

            switch direction {
            case .right:
                newLocation.x += pixelMove
            case .left:
                newLocation.x -= pixelMove
            case .up:
                newLocation.y += pixelMove
            case .down:
                newLocation.y -= pixelMove
            case .circular:
                circularAngle += Double.pi / 18.0
                if circularAngle >= 2 * Double.pi {
                    circularAngle -= 2 * Double.pi
                }
                let radius = pixelMove * 2.0
                newLocation.x += CGFloat(cos(circularAngle)) * radius
                newLocation.y += CGFloat(sin(circularAngle)) * radius
            }

            let margin: CGFloat = 50.0
            newLocation.x = max(margin, min(screenWidth - margin, newLocation.x))
            newLocation.y = max(margin, min(screenHeight - margin, newLocation.y))

            if let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: newLocation, mouseButton: .left) {
                moveEvent.post(tap: .cghidEventTap)
                iteration += 1

                DispatchQueue.main.async { [weak self] in
                    self?.updateMenu()
                    self?.updateDesktopWindow()
                }
            }
        }
    }

    private func activeElapsed() -> TimeInterval {
        guard let start = startTime else { return 0 }
        if isPaused {
            return (pauseStartTime ?? Date()).timeIntervalSince(start) - pausedTime
        }
        return Date().timeIntervalSince(start) - pausedTime
    }

    func updateMenu() {
        let elapsed = activeElapsed()

        guard isRunning, startTime != nil else {
            statusMenuItem.title = "State — Idle"
            elapsedTimeMenuItem.title = "Clock: 00:00:00"
            let preview = remainingPreviewWhenStopped()
            remainingTimeMenuItem.title = "Horizon: \(preview)"
            iterationMenuItem.title = "Ticks: 0"
            progressMenuItem.title = "Carry: 0%"

            pauseMenuItem.isEnabled = false
            stopMenuItem.isEnabled = false

            if let button = statusItem.button {
                button.image = createMenuBarIcon()
                button.title = ""
            }
            return
        }

        let (remText, progMax, progVal) = remainingDescription(elapsedActive: elapsed)
        let elapsedString = formatTime(elapsed)
        let progressPercent: Double
        if let maxV = progMax, maxV > 0 {
            progressPercent = min(100, (progVal / maxV) * 100)
        } else {
            progressPercent = 0
        }

        if shouldAutoStop(elapsedActive: elapsed) {
            stopMovement(notify: true, reason: "Horizon reached — timer or wall clock.")
            return
        }

        if let button = statusItem.button {
            button.image = createMenuBarIcon()
            if isPaused {
                statusMenuItem.title = "State — On hold"
                button.title = " \(elapsedString) · hold"
            } else {
                statusMenuItem.title = "State — Live"
                button.title = " \(elapsedString)"
            }
        }

        elapsedTimeMenuItem.title = "Clock: \(elapsedString)"
        remainingTimeMenuItem.title = "Horizon: \(remText)"
        iterationMenuItem.title = "Ticks: \(iteration)"
        progressMenuItem.title = activeSessionEnd == .indefinite ? "Carry: —" : String(format: "Carry: %.1f%%", progressPercent)

        pauseMenuItem.isEnabled = true
        pauseMenuItem.title = isPaused ? "Continue" : "Hold"
        stopMenuItem.isEnabled = true
    }

    private func remainingPreviewWhenStopped() -> String {
        switch defaultSessionEndFromPrefs() {
        case .indefinite:
            return "∞"
        case .duration(let t):
            return formatTime(t)
        case .until(let d):
            let f = DateFormatter()
            f.timeStyle = .short
            f.dateStyle = .short
            return f.string(from: d)
        }
    }

    func updateDesktopWindow() {
        let elapsed = activeElapsed()

        guard isRunning, startTime != nil else {
            statusLabel.stringValue = "Idle"
            statusLabel.textColor = .systemRed
            statusDot.layer?.backgroundColor = NSColor.systemRed.cgColor
            badgeLabel.stringValue = "IDLE"
            badgeLabel.layer?.backgroundColor = DMTheme.badgeIdle().cgColor
            heroTimeLabel.stringValue = "00:00:00"
            remainingTimeLabel.stringValue = remainingPreviewWhenStopped()
            iterationLabel.stringValue = "0"
            progressBar.doubleValue = 0
            progressBar.isIndeterminate = false
            progressBar.stopAnimation(nil)

            startButton.isEnabled = true
            pauseButton.isEnabled = false
            stopButton.isEnabled = false
            pauseButton.title = "Hold"
            return
        }

        let (remText, progMax, progVal) = remainingDescription(elapsedActive: elapsed)
        let progressPercent: Double
        if let maxV = progMax, maxV > 0 {
            progressPercent = min(100, (progVal / maxV) * 100)
        } else {
            progressPercent = 0
        }

        if activeSessionEnd == .indefinite {
            progressBar.isIndeterminate = true
            progressBar.startAnimation(nil)
        } else {
            progressBar.isIndeterminate = false
            progressBar.stopAnimation(nil)
            progressBar.doubleValue = progressPercent
        }

        if isPaused {
            statusLabel.stringValue = "On hold"
            statusLabel.textColor = .systemOrange
            statusDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
            badgeLabel.stringValue = "HOLD"
            badgeLabel.layer?.backgroundColor = DMTheme.badgeHold().cgColor
            pauseButton.title = "Continue"
        } else {
            statusLabel.stringValue = "Live"
            statusLabel.textColor = .systemGreen
            statusDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
            badgeLabel.stringValue = "LIVE"
            badgeLabel.layer?.backgroundColor = DMTheme.badgeLive().cgColor
            pauseButton.title = "Hold"
        }

        heroTimeLabel.stringValue = formatTime(elapsed)
        remainingTimeLabel.stringValue = remText
        iterationLabel.stringValue = "\(iteration)"

        startButton.isEnabled = false
        pauseButton.isEnabled = true
        stopButton.isEnabled = true
    }

    func formatTime(_ timeInterval: TimeInterval) -> String {
        let ti = max(0, Int(timeInterval))
        let hours = ti / 3600
        let minutes = (ti % 3600) / 60
        let seconds = ti % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    // MARK: - Preferences persistence

    func loadPreferences() {
        let d = UserDefaults.standard
        pixelMove = CGFloat(d.double(forKey: "pixelMove") > 0 ? d.double(forKey: "pixelMove") : 5.0)
        direction = MovementDirection(rawValue: d.integer(forKey: "direction")) ?? .right
        moveInterval = d.double(forKey: "moveInterval") > 0 ? d.double(forKey: "moveInterval") : 10.0
        totalDuration = d.double(forKey: "totalDuration") > 0 ? d.double(forKey: "totalDuration") : 8 * 60 * 60

        if d.object(forKey: "prefsSessionKind") != nil {
            prefsSessionKind = PrefsSessionKind(rawValue: d.integer(forKey: "prefsSessionKind")) ?? .duration
        }
        if d.double(forKey: "sessionUntilEpoch") > 0 {
            sessionUntilDate = Date(timeIntervalSince1970: d.double(forKey: "sessionUntilEpoch"))
        }
        notifyOnSessionEnd = d.object(forKey: "notifyOnSessionEnd") == nil ? true : d.bool(forKey: "notifyOnSessionEnd")
        preventIdleSleepWhileRunning = d.bool(forKey: "preventIdleSleepWhileRunning")
        if d.object(forKey: "hotkeyKeyCode") != nil {
            hotkeyKeyCode = UInt32(d.integer(forKey: "hotkeyKeyCode"))
        }
        if d.object(forKey: "hotkeyCarbonModifiers") != nil {
            hotkeyCarbonModifiers = UInt32(d.integer(forKey: "hotkeyCarbonModifiers"))
        }
    }

    func savePreferencesToDefaults() {
        let d = UserDefaults.standard
        d.set(pixelMove, forKey: "pixelMove")
        d.set(direction.rawValue, forKey: "direction")
        d.set(moveInterval, forKey: "moveInterval")
        d.set(totalDuration, forKey: "totalDuration")
        d.set(prefsSessionKind.rawValue, forKey: "prefsSessionKind")
        d.set(sessionUntilDate.timeIntervalSince1970, forKey: "sessionUntilEpoch")
        d.set(notifyOnSessionEnd, forKey: "notifyOnSessionEnd")
        d.set(preventIdleSleepWhileRunning, forKey: "preventIdleSleepWhileRunning")
        d.set(Int(hotkeyKeyCode), forKey: "hotkeyKeyCode")
        d.set(Int(hotkeyCarbonModifiers), forKey: "hotkeyCarbonModifiers")
        d.synchronize()
    }
}

// MARK: - NSEventModifierFlags → Carbon

private extension NSEvent.ModifierFlags {
    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if contains(.control) { m |= UInt32(controlKey) }
        if contains(.option) { m |= UInt32(optionKey) }
        if contains(.shift) { m |= UInt32(shiftKey) }
        if contains(.command) { m |= UInt32(cmdKey) }
        return m
    }
}

// Main entry point
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
