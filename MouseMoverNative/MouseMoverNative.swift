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
import Darwin
import IOKit

struct SMCKeyData_t {
    struct KeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    static let kSMCHandleYPCEvent: UInt8 = 2
    static let kSMCGetKeyInfo: UInt8 = 9
    static let kSMCReadKey: UInt8 = 5

    static let dataType_flt: UInt32 = fourCC("flt ")
    static let dataType_sp78: UInt32 = fourCC("sp78")
    static let dataType_ui8: UInt32 = fourCC("ui8 ")
    static let dataType_ui16: UInt32 = fourCC("ui16")

    var key: UInt32 = 0
    var vers = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0))
    var pLimitData = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                      UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0))
    var keyInfo = KeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)

    static func fourCC(_ s: String) -> UInt32 {
        let c = Array(s.utf8)
        return UInt32(c[0]) << 24 | UInt32(c[1]) << 16 | UInt32(c[2]) << 8 | UInt32(c[3])
    }
}

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
    static let bg = NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.10, alpha: 1)
    static let surface = NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.16, alpha: 1)
    static let accent = NSColor(calibratedRed: 0.15, green: 0.82, blue: 0.75, alpha: 1)
    static let accentDim = NSColor(calibratedRed: 0.12, green: 0.50, blue: 0.46, alpha: 1)
    static let textPrimary = NSColor(calibratedWhite: 0.95, alpha: 1)
    static let textSecondary = NSColor(calibratedWhite: 0.50, alpha: 1)
    static let textTertiary = NSColor(calibratedWhite: 0.30, alpha: 1)
    static let danger = NSColor(calibratedRed: 0.95, green: 0.35, blue: 0.40, alpha: 1)
    static let success = NSColor(calibratedRed: 0.30, green: 0.80, blue: 0.55, alpha: 1)
    static let warning = NSColor(calibratedRed: 0.95, green: 0.70, blue: 0.25, alpha: 1)
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
    var menuCpuUsageItem: NSMenuItem!
    var menuRamItem: NSMenuItem!
    var menuNetItem: NSMenuItem!
    var menuCpuTempItem: NSMenuItem!
    var menuGpuTempItem: NSMenuItem!

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
    
    var badgeLabel: NSTextField!
    var progressTrack: NSView?
    var progressFill: NSView?

    // System monitoring
    var cpuTempLabel: NSTextField!
    var gpuTempLabel: NSTextField!
    var cpuUsageLabel: NSTextField!
    var ramLabel: NSTextField!
    var netDownLabel: NSTextField!
    var netUpLabel: NSTextField!
    var sysMonTimer: Timer?
    var prevBytesIn: UInt64 = 0
    var prevBytesOut: UInt64 = 0
    var smcConnection: io_connect_t = 0
    

    var bannerCycleTimer: Timer?
    var bannerCycleIndex: Int = 0
    var lastCpuTemp: String = "—"
    var lastGpuTemp: String = "—"
    var lastCpuUsage: String = "—"
    var lastRam: String = "—"
    var lastNetDown: String = "—"
    var lastNetUp: String = "—"

    static let appVersion = "1.1.0"

    // Update banner
    var updateBannerView: NSView?
    var updateBannerLabel: NSTextField?
    var latestRemoteVersion: String?
    var latestDownloadURL: String?

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
    /// When true, holds a ProcessInfo activity that disables idle display + system sleep while drifting.
    var preventIdleSleepWhileRunning = true

    /// Carbon virtual key code and Carbon modifier flags (cmdKey | shiftKey | ...).
    var hotkeyKeyCode: UInt32 = UInt32(kVK_Space)
    var hotkeyCarbonModifiers: UInt32 = UInt32(cmdKey | shiftKey)

    // Hotkey + power
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerRef: EventHandlerRef?
    /// Prevents display sleep and system sleep while a live session runs (when keep-awake is enabled).
    private var powerActivityToken: NSObjectProtocol?
    private var isRecordingHotkey = false
    private var hotkeyLocalMonitor: Any?

    func openSMCConnection() {
        let mainPort: mach_port_t = 0
        let service = IOServiceGetMatchingService(mainPort, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        let result = IOServiceOpen(service, mach_task_self_, 0, &smcConnection)
        IOObjectRelease(service)
        if result != kIOReturnSuccess { smcConnection = 0 }
    }

    func closeSMCConnection() {
        if smcConnection != 0 {
            IOServiceClose(smcConnection)
            smcConnection = 0
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        loadPreferences()
        openSMCConnection()
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

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateMenu()
            self?.updateDesktopWindow()
            self?.updateBannerTimer()
        }
        RunLoop.main.add(timer, forMode: .common)
        updateTimer = timer

        window.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)

        startBannerCycleTimer()
        checkForGitHubUpdate()

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(captureWindowSnapshots(_:)),
            name: NSNotification.Name("com.deceiverme.captureScreenshots"),
            object: nil
        )
    }

    @objc func captureWindowSnapshots(_ note: Notification) {
        let home = NSHomeDirectory()
        let projectDir = "\(home)/Documents/PersonalProject/simm/screenshots"
        let dir = (note.userInfo?["dir"] as? String) ?? projectDir
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        NSLog("captureWindowSnapshots triggered — saving to \(dir)")

        func save(_ win: NSWindow, name: String) {
            guard let view = win.contentView else {
                NSLog("  No contentView for \(name)")
                return
            }
            let bounds = view.bounds
            let pdfData = view.dataWithPDF(inside: bounds)
            guard let pdfImage = NSImage(data: pdfData) else {
                NSLog("  Could not create image from PDF for \(name)")
                return
            }
            let scale = win.backingScaleFactor
            let w = Int(bounds.width * scale)
            let h = Int(bounds.height * scale)

            let bitmapRep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: w, pixelsHigh: h,
                bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0
            )!
            bitmapRep.size = bounds.size

            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmapRep)
            pdfImage.draw(in: bounds)
            NSGraphicsContext.restoreGraphicsState()

            guard let data = bitmapRep.representation(using: .png, properties: [:]) else {
                NSLog("  No PNG data for \(name)")
                return
            }
            let path = "\(dir)/\(name).png"
            do {
                try data.write(to: URL(fileURLWithPath: path))
                NSLog("  Screenshot saved: \(path) (\(data.count) bytes)")
            } catch {
                NSLog("  Write failed: \(error)")
            }
        }

        window.makeKeyAndOrderFront(nil)
        configWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            save(window, name: "dashboard")
            save(configWindow, name: "settings")
            NSLog("All screenshots done")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        updateTimer?.invalidate()
        sysMonTimer?.invalidate()
        bannerCycleTimer?.invalidate()
        mouseMoveTimer?.invalidate()
        releaseIdleSleepAssertion()
        unregisterCarbonHotKey()
        closeSMCConnection()
        DistributedNotificationCenter.default().removeObserver(self)
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

        statusMenuItem = NSMenuItem(title: "Status — Idle", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        elapsedTimeMenuItem = NSMenuItem(title: "Elapsed: 00:00:00", action: nil, keyEquivalent: "")
        elapsedTimeMenuItem.isEnabled = false
        menu.addItem(elapsedTimeMenuItem)

        remainingTimeMenuItem = NSMenuItem(title: "Time left: —", action: nil, keyEquivalent: "")
        remainingTimeMenuItem.isEnabled = false
        menu.addItem(remainingTimeMenuItem)

        iterationMenuItem = NSMenuItem(title: "Moves: 0", action: nil, keyEquivalent: "")
        iterationMenuItem.isEnabled = false
        menu.addItem(iterationMenuItem)

        progressMenuItem = NSMenuItem(title: "Progress: 0%", action: nil, keyEquivalent: "")
        progressMenuItem.isEnabled = false
        menu.addItem(progressMenuItem)

        menu.addItem(NSMenuItem.separator())

        let beginMenu = NSMenu(title: "Start")
        beginMenu.addItem(menuItem(title: "Use saved settings", action: #selector(startWithPreferences), tag: 0))
        beginMenu.addItem(NSMenuItem.separator())
        beginMenu.addItem(menuItem(title: "Run forever", action: #selector(startIndefinite), tag: 0))
        beginMenu.addItem(menuItem(title: "1 hour", action: #selector(startOneHour), tag: 0))
        beginMenu.addItem(menuItem(title: "4 hours", action: #selector(startFourHours), tag: 0))
        beginMenu.addItem(menuItem(title: "8 hours", action: #selector(startEightHours), tag: 0))
        let beginItem = NSMenuItem(title: "Start", action: nil, keyEquivalent: "")
        beginItem.submenu = beginMenu
        menu.addItem(beginItem)

        pauseMenuItem = NSMenuItem(title: "Pause", action: #selector(pauseMovement), keyEquivalent: "")
        pauseMenuItem.target = self
        pauseMenuItem.isEnabled = false
        menu.addItem(pauseMenuItem)

        stopMenuItem = NSMenuItem(title: "Stop", action: #selector(stopMovementFromMenu), keyEquivalent: "")
        stopMenuItem.target = self
        stopMenuItem.isEnabled = false
        menu.addItem(stopMenuItem)

        menu.addItem(NSMenuItem.separator())

        menuCpuUsageItem = NSMenuItem(title: "CPU: —", action: nil, keyEquivalent: "")
        menuCpuUsageItem.isEnabled = false
        menu.addItem(menuCpuUsageItem)

        menuRamItem = NSMenuItem(title: "RAM: —", action: nil, keyEquivalent: "")
        menuRamItem.isEnabled = false
        menu.addItem(menuRamItem)

        menuNetItem = NSMenuItem(title: "Net: — down / — up", action: nil, keyEquivalent: "")
        menuNetItem.isEnabled = false
        menu.addItem(menuNetItem)

        menuCpuTempItem = NSMenuItem(title: "CPU Temp: —", action: nil, keyEquivalent: "")
        menuCpuTempItem.isEnabled = false
        menu.addItem(menuCpuTempItem)

        menuGpuTempItem = NSMenuItem(title: "GPU Temp: —", action: nil, keyEquivalent: "")
        menuGpuTempItem.isEnabled = false
        menu.addItem(menuGpuTempItem)

        menu.addItem(NSMenuItem.separator())

        showWindowMenuItem = NSMenuItem(title: "Dashboard", action: #selector(showWindow), keyEquivalent: "w")
        showWindowMenuItem.target = self
        menu.addItem(showWindowMenuItem)

        preferencesMenuItem = NSMenuItem(title: "Settings…", action: #selector(showPreferences), keyEquivalent: ",")
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
        let windowRect = NSRect(x: 0, y: 0, width: 460, height: 540)
        window = NSWindow(
            contentRect: windowRect,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "deceiverMe"
        window.center()
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = DMTheme.bg

        let cv = window.contentView!
        cv.wantsLayer = true
        cv.layer?.backgroundColor = DMTheme.bg.cgColor
        let pad: CGFloat = 32
        let contentW = cv.bounds.width - pad * 2

        var y = cv.bounds.height - pad

        // ── Logo + Wordmark + Status Indicator ──
        let logoSize: CGFloat = 22
        let logoView = NSImageView(frame: NSRect(x: pad, y: y - 23, width: logoSize, height: logoSize))
        logoView.image = createAppLogo(size: logoSize)
        cv.addSubview(logoView)

        let wordmark = NSTextField(labelWithString: "deceiverMe")
        wordmark.font = NSFont.systemFont(ofSize: 20, weight: .bold)
        wordmark.textColor = DMTheme.textPrimary
        wordmark.frame = NSRect(x: pad + logoSize + 8, y: y - 24, width: 160, height: 24)
        cv.addSubview(wordmark)

        let versionTag = NSTextField(labelWithString: "v\(AppDelegate.appVersion)")
        versionTag.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        versionTag.textColor = DMTheme.textTertiary
        versionTag.alignment = .left
        versionTag.frame = NSRect(x: pad + logoSize + 8, y: y - 38, width: 60, height: 14)
        cv.addSubview(versionTag)

        // Small status dot instead of the IDLE badge
        badgeLabel = NSTextField(labelWithString: "")
        badgeLabel.frame = NSRect(x: pad + logoSize + 170, y: y - 17, width: 8, height: 8)
        badgeLabel.wantsLayer = true
        badgeLabel.layer?.cornerRadius = 4
        badgeLabel.layer?.backgroundColor = DMTheme.danger.cgColor
        badgeLabel.isBordered = false
        badgeLabel.drawsBackground = false
        cv.addSubview(badgeLabel)

        // ── Update banner (hidden by default) ──
        y -= 6
        let bannerH: CGFloat = 36
        let banner = NSView(frame: NSRect(x: pad, y: y - bannerH, width: contentW, height: bannerH))
        banner.wantsLayer = true
        banner.layer?.cornerRadius = 8
        banner.layer?.backgroundColor = NSColor(red: 0.15, green: 0.55, blue: 1.0, alpha: 0.15).cgColor
        banner.layer?.borderColor = NSColor(red: 0.3, green: 0.6, blue: 1.0, alpha: 0.4).cgColor
        banner.layer?.borderWidth = 1

        let bannerLbl = NSTextField(labelWithString: "")
        bannerLbl.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        bannerLbl.textColor = NSColor(red: 0.4, green: 0.7, blue: 1.0, alpha: 1.0)
        bannerLbl.frame = NSRect(x: 10, y: 0, width: contentW - 90, height: bannerH)
        banner.addSubview(bannerLbl)

        let updateBtn = NSButton(title: "Update", target: self, action: #selector(openReleasePage))
        updateBtn.bezelStyle = .inline
        updateBtn.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        updateBtn.frame = NSRect(x: contentW - 74, y: 6, width: 64, height: 24)
        banner.addSubview(updateBtn)

        banner.isHidden = true
        cv.addSubview(banner)
        updateBannerView = banner
        updateBannerLabel = bannerLbl

        // ── Hero Time ──
        y -= 40
        heroTimeLabel = NSTextField(labelWithString: "00 : 00 : 00")
        if #available(macOS 10.15, *) {
            heroTimeLabel.font = NSFont.monospacedSystemFont(ofSize: 44, weight: .thin)
        } else {
            heroTimeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 44, weight: .thin)
        }
        heroTimeLabel.textColor = DMTheme.accent
        heroTimeLabel.alignment = .center
        heroTimeLabel.frame = NSRect(x: pad, y: y - 52, width: contentW, height: 54)
        cv.addSubview(heroTimeLabel)

        y -= 58
        let heroCaption = NSTextField(labelWithString: "elapsed")
        heroCaption.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        heroCaption.textColor = DMTheme.textTertiary
        heroCaption.alignment = .center
        heroCaption.frame = NSRect(x: pad, y: y - 14, width: contentW, height: 14)
        cv.addSubview(heroCaption)

        // ── Divider 1 ──
        y -= 26
        let div1 = NSView(frame: NSRect(x: pad, y: y, width: contentW, height: 1))
        div1.wantsLayer = true
        div1.layer?.backgroundColor = NSColor(calibratedWhite: 1.0, alpha: 0.06).cgColor
        cv.addSubview(div1)

        // ── Stats Row ──
        y -= 8
        let colW = contentW / 3
        let statsY = y - 46

        let remainBox = createStatBox(title: "Time Left", value: "120:00:00", frame: NSRect(x: pad, y: statsY, width: colW, height: 46))
        cv.addSubview(remainBox)
        remainingTimeLabel = (remainBox.subviews.count > 1 ? remainBox.subviews[1] as? NSTextField : nil) ?? NSTextField()

        let iterBox = createStatBox(title: "Moves", value: "0", frame: NSRect(x: pad + colW, y: statsY, width: colW, height: 46))
        cv.addSubview(iterBox)
        iterationLabel = (iterBox.subviews.count > 1 ? iterBox.subviews[1] as? NSTextField : nil) ?? NSTextField()

        let progBox = createStatBox(title: "Progress", value: "0%", frame: NSRect(x: pad + 2 * colW, y: statsY, width: colW, height: 46))
        cv.addSubview(progBox)

        // Custom progress track
        y = statsY - 10
        let trackH: CGFloat = 3
        let track = NSView(frame: NSRect(x: pad, y: y, width: contentW, height: trackH))
        track.wantsLayer = true
        track.layer?.cornerRadius = 1.5
        track.layer?.backgroundColor = DMTheme.accentDim.withAlphaComponent(0.25).cgColor
        cv.addSubview(track)
        progressTrack = track

        let fill = NSView(frame: NSRect(x: pad, y: y, width: 0, height: trackH))
        fill.wantsLayer = true
        fill.layer?.cornerRadius = 1.5
        fill.layer?.backgroundColor = DMTheme.accent.cgColor
        cv.addSubview(fill)
        progressFill = fill

        progressBar = NSProgressIndicator(frame: NSRect(x: pad, y: y - 4, width: contentW, height: 10))
        progressBar.style = .bar
        progressBar.minValue = 0
        progressBar.maxValue = 100
        progressBar.doubleValue = 0
        progressBar.controlSize = .small
        progressBar.isHidden = true
        cv.addSubview(progressBar)

        // ── Divider 2 ──
        y -= 14
        let div2 = NSView(frame: NSRect(x: pad, y: y, width: contentW, height: 1))
        div2.wantsLayer = true
        div2.layer?.backgroundColor = NSColor(calibratedWhite: 1.0, alpha: 0.06).cgColor
        cv.addSubview(div2)

        // ── System Monitor ──
        y -= 8
        let sysColW = contentW / 3
        let row1Y = y - 34
        let row2Y = row1Y - 38

        func makeSys(title: String, val: String, x: CGFloat, yy: CGFloat) -> NSTextField {
            let t = NSTextField(labelWithString: title)
            t.font = NSFont.systemFont(ofSize: 9, weight: .medium)
            t.textColor = DMTheme.textTertiary
            t.frame = NSRect(x: x, y: yy + 16, width: sysColW, height: 12)
            cv.addSubview(t)
            let v = NSTextField(labelWithString: val)
            if #available(macOS 10.15, *) {
                v.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
            } else {
                v.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
            }
            v.textColor = DMTheme.textPrimary
            v.frame = NSRect(x: x, y: yy, width: sysColW, height: 16)
            cv.addSubview(v)
            return v
        }

        cpuTempLabel = makeSys(title: "CPU Temp", val: "— °C", x: pad, yy: row1Y)
        gpuTempLabel = makeSys(title: "GPU Temp", val: "— °C", x: pad + sysColW, yy: row1Y)
        cpuUsageLabel = makeSys(title: "CPU %", val: "—%", x: pad + 2 * sysColW, yy: row1Y)
        ramLabel = makeSys(title: "RAM", val: "—%", x: pad, yy: row2Y)
        netDownLabel = makeSys(title: "Net Down", val: "— KB/s", x: pad + sysColW, yy: row2Y)
        netUpLabel = makeSys(title: "Net Up", val: "— KB/s", x: pad + 2 * sysColW, yy: row2Y)

        // ── Status ──
        y = row2Y - 20
        statusDot = NSView(frame: NSRect(x: pad, y: y, width: 7, height: 7))
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 3.5
        statusDot.layer?.backgroundColor = NSColor.systemRed.cgColor
        cv.addSubview(statusDot)

        statusLabel = NSTextField(labelWithString: "Idle")
        statusLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = DMTheme.danger
        statusLabel.frame = NSRect(x: pad + 14, y: y - 4, width: 100, height: 16)
        cv.addSubview(statusLabel)

        // ── Buttons ──
        y -= 28
        let btnH: CGFloat = 34
        let btnW: CGFloat = 90

        startButton = createModernButton(title: "Start", action: #selector(startWithPreferences), frame: NSRect(x: pad, y: y - btnH, width: btnW, height: btnH), primary: true)
        cv.addSubview(startButton)

        pauseButton = createModernButton(title: "Pause", action: #selector(pauseMovement), frame: NSRect(x: pad + btnW + 8, y: y - btnH, width: btnW, height: btnH))
        pauseButton.isEnabled = false
        pauseButton.alphaValue = 0.35
        cv.addSubview(pauseButton)

        stopButton = createModernButton(title: "Stop", action: #selector(stopMovementFromMenu), frame: NSRect(x: pad + 2 * (btnW + 8), y: y - btnH, width: btnW, height: btnH))
        stopButton.isEnabled = false
        stopButton.alphaValue = 0.35
        cv.addSubview(stopButton)

        preferencesButton = createModernButton(title: "Settings", action: #selector(showPreferences), frame: NSRect(x: cv.bounds.width - pad - btnW, y: y - btnH, width: btnW, height: btnH))
        cv.addSubview(preferencesButton)

        // ── Footer (centered, two lines) ──
        let footerW = cv.bounds.width

        let ghBtn = NSButton(title: "GitHub Repo", target: self, action: #selector(openGitHubRepo))
        ghBtn.isBordered = false
        ghBtn.font = NSFont.systemFont(ofSize: 9, weight: .medium)
        ghBtn.contentTintColor = DMTheme.accent
        ghBtn.alignment = .center
        ghBtn.frame = NSRect(x: 0, y: 22, width: footerW, height: 16)
        cv.addSubview(ghBtn)

        let builtByBtn = NSButton(title: "Built by mimran-khan", target: self, action: #selector(openAuthorPage))
        builtByBtn.isBordered = false
        builtByBtn.font = NSFont.systemFont(ofSize: 9, weight: .regular)
        builtByBtn.contentTintColor = DMTheme.textTertiary
        builtByBtn.alignment = .center
        builtByBtn.frame = NSRect(x: 0, y: 8, width: footerW, height: 14)
        cv.addSubview(builtByBtn)

        startSysMonTimer()
    }

    func createAppLogo(size: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()

        let s = size
        let arrow = NSBezierPath()
        // Cursor arrow shape
        arrow.move(to: NSPoint(x: s * 0.18, y: s * 0.90))
        arrow.line(to: NSPoint(x: s * 0.18, y: s * 0.12))
        arrow.line(to: NSPoint(x: s * 0.46, y: s * 0.34))
        arrow.line(to: NSPoint(x: s * 0.72, y: s * 0.15))
        arrow.line(to: NSPoint(x: s * 0.82, y: s * 0.32))
        arrow.line(to: NSPoint(x: s * 0.56, y: s * 0.50))
        arrow.line(to: NSPoint(x: s * 0.82, y: s * 0.56))
        arrow.close()

        DMTheme.accent.setFill()
        arrow.fill()

        // Subtle outline
        DMTheme.accent.withAlphaComponent(0.4).setStroke()
        arrow.lineWidth = 0.5
        arrow.stroke()

        img.unlockFocus()
        img.isTemplate = false
        return img
    }

    @objc func openGitHubRepo() {
        if let url = URL(string: "https://github.com/mimran-khan/deceiverme") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func openAuthorPage() {
        if let url = URL(string: "https://mimran-khan.github.io/") {
            NSWorkspace.shared.open(url)
        }
    }

    func startSysMonTimer() {
        sysMonTimer?.invalidate()
        let t = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.updateSysMonLabels()
        }
        t.tolerance = 1.0
        RunLoop.main.add(t, forMode: .common)
        sysMonTimer = t
        updateSysMonLabels()
    }

    func updateSysMonLabels() {
        // CPU usage via host_processor_info
        var numCPUsU: mach_msg_type_number_t = 0
        var cpuInfo: processor_info_array_t?
        var numCpuInfo: mach_msg_type_number_t = 0
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPUsU, &cpuInfo, &numCpuInfo)
        if result == KERN_SUCCESS, let cpuInfo = cpuInfo {
            var totalUser: Int32 = 0, totalSys: Int32 = 0, totalIdle: Int32 = 0
            for i in 0..<Int(numCPUsU) {
                let offset = Int(CPU_STATE_MAX) * i
                totalUser += cpuInfo[offset + Int(CPU_STATE_USER)] + cpuInfo[offset + Int(CPU_STATE_NICE)]
                totalSys += cpuInfo[offset + Int(CPU_STATE_SYSTEM)]
                totalIdle += cpuInfo[offset + Int(CPU_STATE_IDLE)]
            }
            let total = totalUser + totalSys + totalIdle
            let usage = total > 0 ? Double(totalUser + totalSys) / Double(total) * 100 : 0
            let cpuStr = String(format: "%.1f%%", usage)
            cpuUsageLabel.stringValue = cpuStr
            lastCpuUsage = cpuStr
            menuCpuUsageItem?.title = "CPU: \(cpuStr)"
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: cpuInfo), vm_size_t(numCpuInfo) * vm_size_t(MemoryLayout<Int32>.stride))
        }

        // RAM
        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let vmResult = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if vmResult == KERN_SUCCESS {
            let pageSize = UInt64(vm_kernel_page_size)
            let active = UInt64(vmStats.active_count) * pageSize
            let wired = UInt64(vmStats.wire_count) * pageSize
            let compressed = UInt64(vmStats.compressor_page_count) * pageSize
            let totalRam = ProcessInfo.processInfo.physicalMemory
            let used = active + wired + compressed
            let pct = totalRam > 0 ? Double(used) / Double(totalRam) * 100 : 0
            let ramStr = String(format: "%.0f%%", pct)
            ramLabel.stringValue = ramStr
            lastRam = ramStr
            menuRamItem?.title = "RAM: \(ramStr)"
        }

        // Network
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr {
            var totalIn: UInt64 = 0, totalOut: UInt64 = 0
            var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
            while let addr = ptr {
                if addr.pointee.ifa_addr.pointee.sa_family == UInt8(AF_LINK) {
                    let data = unsafeBitCast(addr.pointee.ifa_data, to: UnsafeMutablePointer<if_data>.self)
                    totalIn += UInt64(data.pointee.ifi_ibytes)
                    totalOut += UInt64(data.pointee.ifi_obytes)
                }
                ptr = addr.pointee.ifa_next
            }
            freeifaddrs(ifaddr)
            if prevBytesIn > 0 {
                let dIn = totalIn >= prevBytesIn ? totalIn - prevBytesIn : 0
                let dOut = totalOut >= prevBytesOut ? totalOut - prevBytesOut : 0
                let kbIn = Double(dIn) / 1024.0 / 3.0
                let kbOut = Double(dOut) / 1024.0 / 3.0
                let dnStr = String(format: "%.1f KB/s", kbIn)
                let upStr = String(format: "%.1f KB/s", kbOut)
                netDownLabel.stringValue = dnStr
                netUpLabel.stringValue = upStr
                lastNetDown = dnStr
                lastNetUp = upStr
                menuNetItem?.title = "Net: \(dnStr) down / \(upStr) up"
            }
            prevBytesIn = totalIn
            prevBytesOut = totalOut
        }

        updateTemperatures()
    }

    func updateTemperatures() {
        let temps = readSMCTemperatures()
        setTempDisplay(temps.cpu, temps.gpu)
    }

    private func readSMCTemperatures() -> (cpu: String, gpu: String) {
        if smcConnection == 0 {
            openSMCConnection()
        }
        guard smcConnection != 0 else { return ("N/A", "N/A") }

        let cpuKeys = ["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0T", "Tc0c", "TC0P", "Tc1c", "Tc0C"]
        let gpuKeys = ["Tg05", "Tg0D", "Tg0T", "Tg0P", "Tg0c", "TG0P"]

        var cpuTemp: Double = 0
        for key in cpuKeys {
            let val = smcReadKey(conn: smcConnection, key: key)
            if val > 10 && val < 120 {
                cpuTemp = max(cpuTemp, val)
            }
        }

        var gpuTemp: Double = 0
        for key in gpuKeys {
            let val = smcReadKey(conn: smcConnection, key: key)
            if val > 10 && val < 120 {
                gpuTemp = max(gpuTemp, val)
            }
        }

        let cpuStr = cpuTemp > 0 ? String(format: "%.0f°C", cpuTemp) : "—"
        let gpuStr = gpuTemp > 0 ? String(format: "%.0f°C", gpuTemp) : "—"
        return (cpuStr, gpuStr)
    }

    private func smcReadKey(conn: io_connect_t, key: String) -> Double {
        var inputStruct = SMCKeyData_t()
        var outputStruct = SMCKeyData_t()

        let chars = Array(key.utf8)
        guard chars.count == 4 else { return 0 }
        inputStruct.key = UInt32(chars[0]) << 24 | UInt32(chars[1]) << 16 | UInt32(chars[2]) << 8 | UInt32(chars[3])
        inputStruct.data8 = SMCKeyData_t.kSMCGetKeyInfo

        let structSize = MemoryLayout<SMCKeyData_t>.size
        var outputSize = structSize
        let infoResult = IOConnectCallStructMethod(conn, UInt32(SMCKeyData_t.kSMCHandleYPCEvent),
                                                    &inputStruct, structSize,
                                                    &outputStruct, &outputSize)
        guard infoResult == kIOReturnSuccess else { return 0 }

        let dataSize = outputStruct.keyInfo.dataSize
        let dataType = outputStruct.keyInfo.dataType

        inputStruct.keyInfo.dataSize = dataSize
        inputStruct.keyInfo.dataType = dataType
        inputStruct.data8 = SMCKeyData_t.kSMCReadKey

        outputSize = structSize
        let readResult = IOConnectCallStructMethod(conn, UInt32(SMCKeyData_t.kSMCHandleYPCEvent),
                                                    &inputStruct, structSize,
                                                    &outputStruct, &outputSize)
        guard readResult == kIOReturnSuccess else { return 0 }

        let bytes = outputStruct.bytes

        if dataType == SMCKeyData_t.dataType_flt {
            var value: Float = 0
            withUnsafeMutablePointer(to: &value) { ptr in
                ptr.withMemoryRebound(to: UInt8.self, capacity: 4) { bytePtr in
                    bytePtr[0] = bytes.0
                    bytePtr[1] = bytes.1
                    bytePtr[2] = bytes.2
                    bytePtr[3] = bytes.3
                }
            }
            return Double(value)
        }

        if dataType == SMCKeyData_t.dataType_sp78 {
            let raw = Int16(bytes.0) << 8 | Int16(bytes.1)
            let val = Double(raw) / 256.0
            return val
        }

        if dataType == SMCKeyData_t.dataType_ui8 || dataType == SMCKeyData_t.dataType_ui16 {
            return Double(bytes.0)
        }

        return 0
    }

    private func setTempDisplay(_ cpu: String, _ gpu: String) {
        let update = {
            self.cpuTempLabel.stringValue = cpu
            self.gpuTempLabel.stringValue = gpu
            self.lastCpuTemp = cpu
            self.lastGpuTemp = gpu
            self.menuCpuTempItem?.title = "CPU Temp: \(cpu)"
            self.menuGpuTempItem?.title = "GPU Temp: \(gpu)"
        }
        if Thread.isMainThread {
            update()
        } else {
            DispatchQueue.main.async(execute: update)
        }
    }

    // MARK: - Menu Bar Banner Cycling

    func refreshBannerNow() {
        guard let button = statusItem.button else { return }
        let elapsed = activeElapsed()
        let label: String
        if isRunning && startTime != nil {
            label = isPaused ? "Paused" : formatTime(elapsed)
        } else {
            label = "Idle"
        }
        button.image = createMenuBarIcon()
        button.title = " \(label)"
        bannerCycleIndex = 0
    }

    func updateBannerTimer() {
        guard bannerCycleIndex == 0, let button = statusItem.button else { return }
        let elapsed = activeElapsed()
        let label: String
        if isRunning && startTime != nil {
            label = isPaused ? "Paused" : formatTime(elapsed)
        } else {
            label = "Idle"
        }
        button.title = " \(label)"
    }

    func startBannerCycleTimer() {
        bannerCycleTimer?.invalidate()
        let t = Timer(timeInterval: 7.0, repeats: true) { [weak self] _ in
            self?.cycleBannerText()
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        bannerCycleTimer = t
    }

    func cycleBannerText() {
        guard let button = statusItem.button else { return }

        let elapsed = activeElapsed()
        let timerStr = isRunning && startTime != nil ? formatTime(elapsed) : "00:00:00"
        let labels = [
            timerStr,
            "CPU \(lastCpuTemp)",
            "GPU \(lastGpuTemp)",
            "CPU \(lastCpuUsage)",
            "RAM \(lastRam)",
            "\(lastNetDown) dn / \(lastNetUp) up"
        ]

        bannerCycleIndex = (bannerCycleIndex + 1) % labels.count

        button.image = createMenuBarIcon()
        button.title = " \(labels[bannerCycleIndex])"
    }

    // MARK: - Auto-Update from GitHub

    func checkForGitHubUpdate() {
        let urlStr = "https://api.github.com/repos/mimran-khan/deceiverme/releases/latest"
        guard let url = URL(string: urlStr) else { return }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.setValue("deceiverMe/\(AppDelegate.appVersion)", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self = self,
                  error == nil,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String else {
                DispatchQueue.main.async { self?.hideUpdateBanner() }
                return
            }

            let remoteVersion = tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))

            if self.isNewerVersion(remote: remoteVersion, local: AppDelegate.appVersion) {
                let htmlUrl = json["html_url"] as? String ?? "https://github.com/mimran-khan/deceiverme/releases"
                DispatchQueue.main.async {
                    self.latestRemoteVersion = remoteVersion
                    self.latestDownloadURL = htmlUrl
                    self.showUpdateBanner(version: remoteVersion)
                }
            } else {
                DispatchQueue.main.async { self.hideUpdateBanner() }
            }
        }.resume()
    }

    private func isNewerVersion(remote: String, local: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let l = local.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(r.count, l.count) {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv > lv { return true }
            if rv < lv { return false }
        }
        return false
    }

    private func showUpdateBanner(version: String) {
        updateBannerLabel?.stringValue = "  v\(version) available — update now"
        updateBannerView?.isHidden = false
    }

    private func hideUpdateBanner() {
        updateBannerView?.isHidden = true
    }

    @objc func openReleasePage() {
        let urlString = latestDownloadURL ?? "https://github.com/mimran-khan/deceiverme/releases"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    func createStatBox(title: String, value: String, frame: NSRect) -> NSView {
        let container = NSView(frame: frame)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 9, weight: .medium)
        titleLabel.textColor = DMTheme.textTertiary
        titleLabel.alignment = .center
        titleLabel.frame = NSRect(x: 2, y: frame.height - 14, width: frame.width - 4, height: 12)
        container.addSubview(titleLabel)

        let valueLabel = NSTextField(labelWithString: value)
        if #available(macOS 10.15, *) {
            valueLabel.font = NSFont.monospacedSystemFont(ofSize: 16, weight: .medium)
        } else {
            valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 16, weight: .medium)
        }
        valueLabel.textColor = DMTheme.textPrimary
        valueLabel.alignment = .center
        valueLabel.frame = NSRect(x: 2, y: 4, width: frame.width - 4, height: 22)
        container.addSubview(valueLabel)

        return container
    }

    func createModernButton(title: String, action: Selector, frame: NSRect, primary: Bool = false) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.frame = frame
        button.isBordered = false
        button.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        button.wantsLayer = true
        button.layer?.cornerRadius = frame.height / 2

        if primary {
            button.layer?.backgroundColor = DMTheme.accent.cgColor
            button.contentTintColor = NSColor(calibratedRed: 0.05, green: 0.05, blue: 0.08, alpha: 1)
        } else {
            button.layer?.backgroundColor = NSColor.clear.cgColor
            button.layer?.borderWidth = 1
            button.layer?.borderColor = DMTheme.textTertiary.cgColor
            button.contentTintColor = DMTheme.textSecondary
        }
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
        configWindow.title = "Settings — deceiverMe"
        configWindow.center()
        configWindow.isReleasedWhenClosed = false

        let contentView = configWindow.contentView!
        let padding: CGFloat = 24
        var yPosition = contentView.bounds.height - padding - 30

        let titleLabel = NSTextField(labelWithString: "Settings")
        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        titleLabel.frame = NSRect(x: padding, y: yPosition, width: 320, height: 22)
        contentView.addSubview(titleLabel)
        yPosition -= 36

        pixelTextField = createConfigField(label: "Move distance (pixels):", value: String(Int(pixelMove)), y: &yPosition, contentView: contentView, padding: padding)
        directionPopUp = createConfigPopUp(
            label: "Direction:",
            items: ["Move right", "Move left", "Move up", "Move down", "Circle"],
            selected: direction.rawValue,
            y: &yPosition,
            contentView: contentView,
            padding: padding
        )
        intervalTextField = createConfigField(label: "Interval (seconds):", value: String(Int(moveInterval)), y: &yPosition, contentView: contentView, padding: padding)

        let sessionLabel = NSTextField(labelWithString: "Session mode:")
        sessionLabel.frame = NSRect(x: padding, y: yPosition, width: 180, height: 20)
        contentView.addSubview(sessionLabel)
        sessionModePopUp = NSPopUpButton(frame: NSRect(x: 200, y: yPosition - 4, width: 220, height: 24))
        sessionModePopUp.addItems(withTitles: ["Run forever", "Fixed duration", "Stop at date & time"])
        sessionModePopUp.selectItem(at: prefsSessionKind.rawValue)
        sessionModePopUp.target = self
        sessionModePopUp.action = #selector(sessionModeChanged)
        contentView.addSubview(sessionModePopUp)
        yPosition -= 40

        durationTextField = createConfigField(label: "Duration (hours):", value: String(Int(totalDuration / 3600)), y: &yPosition, contentView: contentView, padding: padding)

        untilLabel = NSTextField(labelWithString: "Stop at:")
        untilLabel.frame = NSRect(x: padding, y: yPosition, width: 180, height: 20)
        contentView.addSubview(untilLabel)
        untilDatePicker = NSDatePicker(frame: NSRect(x: 200, y: yPosition - 4, width: 220, height: 24))
        untilDatePicker.datePickerStyle = .textFieldAndStepper
        untilDatePicker.datePickerElements = [.yearMonthDay, .hourMinute]
        untilDatePicker.dateValue = sessionUntilDate
        contentView.addSubview(untilDatePicker)
        yPosition -= 40

        notifyCheckBox = NSButton(checkboxWithTitle: "Notify when session ends", target: nil, action: nil)
        notifyCheckBox.frame = NSRect(x: padding, y: yPosition, width: 360, height: 20)
        notifyCheckBox.state = notifyOnSessionEnd ? .on : .off
        contentView.addSubview(notifyCheckBox)
        yPosition -= 28

        keepAwakeCheckBox = NSButton(
            checkboxWithTitle: "Keep display & system awake while running (stops dimming, sleep, and most auto-lock)",
            target: nil,
            action: nil
        )
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

        saveButton = createModernButton(title: "Save", action: #selector(savePreferences), frame: NSRect(x: padding, y: yPosition, width: 120, height: 32))
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
            content.title = "Session ended"
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

    // MARK: - Power / idle (display + system)

    /// Uses `ProcessInfo` activity so both **display** and **system** idle sleep are suppressed.
    /// Note: `kIOPMAssertionTypeNoIdleSleep` alone does **not** stop the display from sleeping; that
    /// often triggers lock/screensaver. Synthetic mouse events also may not count as user idle reset.
    private func updateIdleSleepAssertion() {
        let want = preventIdleSleepWhileRunning && isRunning && !isPaused
        if want {
            if powerActivityToken == nil {
                powerActivityToken = ProcessInfo.processInfo.beginActivity(
                    options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled],
                    reason: "deceiverMe active session"
                )
            }
        } else {
            releaseIdleSleepAssertion()
        }
    }

    private func releaseIdleSleepAssertion() {
        if let token = powerActivityToken {
            ProcessInfo.processInfo.endActivity(token)
            powerActivityToken = nil
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
        checkForGitHubUpdate()
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
        refreshBannerNow()

        let timer = Timer(timeInterval: moveInterval, repeats: true) { [weak self] _ in
            self?.moveMouse()
        }
        RunLoop.main.add(timer, forMode: .common)
        mouseMoveTimer = timer

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

            let timer = Timer(timeInterval: moveInterval, repeats: true) { [weak self] _ in
                self?.moveMouse()
            }
            RunLoop.main.add(timer, forMode: .common)
            mouseMoveTimer = timer
        } else {
            isPaused = true
            pauseStartTime = Date()
            mouseMoveTimer?.invalidate()
            mouseMoveTimer = nil
        }

        updateIdleSleepAssertion()
        updateMenu()
        updateDesktopWindow()
        refreshBannerNow()
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
        refreshBannerNow()
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
            statusMenuItem.title = "Status — Idle"
            elapsedTimeMenuItem.title = "Elapsed: 00:00:00"
            let preview = remainingPreviewWhenStopped()
            remainingTimeMenuItem.title = "Time left: \(preview)"
            iterationMenuItem.title = "Moves: 0"
            progressMenuItem.title = "Progress: 0%"

            pauseMenuItem.isEnabled = false
            stopMenuItem.isEnabled = false

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
            stopMovement(notify: true, reason: "Session ended — timer or scheduled stop.")
            return
        }

        if isPaused {
            statusMenuItem.title = "Status — Paused"
        } else {
            statusMenuItem.title = "Status — Running"
        }

        elapsedTimeMenuItem.title = "Elapsed: \(elapsedString)"
        remainingTimeMenuItem.title = "Time left: \(remText)"
        iterationMenuItem.title = "Moves: \(iteration)"
        progressMenuItem.title = activeSessionEnd == .indefinite ? "Progress: —" : String(format: "Progress: %.1f%%", progressPercent)

        pauseMenuItem.isEnabled = true
        pauseMenuItem.title = isPaused ? "Resume" : "Pause"
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
            statusLabel.textColor = DMTheme.danger
            statusDot.layer?.backgroundColor = DMTheme.danger.cgColor
            badgeLabel.layer?.backgroundColor = DMTheme.danger.cgColor
            heroTimeLabel.stringValue = "00 : 00 : 00"
            remainingTimeLabel.stringValue = remainingPreviewWhenStopped()
            iterationLabel.stringValue = "0"
            progressBar.isHidden = true
            progressFill?.frame.size.width = 0
            progressTrack?.isHidden = false

            startButton.isEnabled = true
            startButton.alphaValue = 1.0
            startButton.layer?.backgroundColor = DMTheme.accent.cgColor
            pauseButton.isEnabled = false
            pauseButton.alphaValue = 0.35
            stopButton.isEnabled = false
            stopButton.alphaValue = 0.35
            pauseButton.title = "Pause"
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
            progressBar.isHidden = false
            progressBar.isIndeterminate = true
            progressBar.startAnimation(nil)
            progressTrack?.isHidden = true
            progressFill?.isHidden = true
        } else {
            progressBar.isHidden = true
            progressTrack?.isHidden = false
            progressFill?.isHidden = false
            if let track = progressTrack {
                progressFill?.frame.size.width = track.frame.width * CGFloat(progressPercent / 100.0)
            }
        }

        if isPaused {
            statusLabel.stringValue = "Paused"
            statusLabel.textColor = DMTheme.warning
            statusDot.layer?.backgroundColor = DMTheme.warning.cgColor
            badgeLabel.layer?.backgroundColor = DMTheme.warning.cgColor
            pauseButton.title = "Resume"
        } else {
            statusLabel.stringValue = "Running"
            statusLabel.textColor = DMTheme.success
            statusDot.layer?.backgroundColor = DMTheme.success.cgColor
            badgeLabel.layer?.backgroundColor = DMTheme.success.cgColor
            pauseButton.title = "Pause"
        }

        heroTimeLabel.stringValue = formatTime(elapsed).replacingOccurrences(of: ":", with: " : ")
        remainingTimeLabel.stringValue = remText
        iterationLabel.stringValue = "\(iteration)"

        startButton.isEnabled = false
        startButton.alphaValue = 0.3
        startButton.layer?.backgroundColor = DMTheme.accent.withAlphaComponent(0.3).cgColor
        pauseButton.isEnabled = true
        pauseButton.alphaValue = 1.0
        pauseButton.contentTintColor = DMTheme.accent
        stopButton.isEnabled = true
        stopButton.alphaValue = 1.0
        stopButton.contentTintColor = DMTheme.danger
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
        // Default on: display-only IOPM assertions were insufficient; users expect drift to avoid lock.
        if d.object(forKey: "preventIdleSleepWhileRunning") != nil {
            preventIdleSleepWhileRunning = d.bool(forKey: "preventIdleSleepWhileRunning")
        } else {
            preventIdleSleepWhileRunning = true
        }
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
