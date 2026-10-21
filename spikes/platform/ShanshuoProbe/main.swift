// ShanshuoProbe — FEAT-001 T002 one-off platform probe. Not product code.
// Build: spikes/platform/ShanshuoProbe/build.sh   Checklist: spikes/platform/CHECKLIST.md
import AppKit
import ApplicationServices
import AVFoundation
import Carbon

// MARK: - Log (JSON lines; never records field contents, only lengths and flags)

final class ProbeLog {
    static let shared = ProbeLog()
    let url: URL
    let build: String
    var onLine: ((String) -> Void)?
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        build = info["ProbeBuildID"] as? String ?? "dev"
        let path = info["ProbeLogPath"] as? String
            ?? NSHomeDirectory() + "/Library/Logs/ShanshuoProbe/probe-log.jsonl"
        url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
    }

    func event(_ kind: String, _ fields: [String: Any] = [:]) {
        var row = fields
        row["t"] = iso.string(from: Date())
        row["kind"] = kind
        row["build"] = build
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8)!)
            try? h.close()
        }
        let short = fields.keys.sorted().map { "\($0)=\(fields[$0]!)" }.joined(separator: " ")
        let text = "\(iso.string(from: Date()).suffix(13)) \(kind) \(short)"
        DispatchQueue.main.async { self.onLine?(text) }
    }
}

let log = ProbeLog.shared

// MARK: - Small helpers

func nowMs() -> Double { CACurrentMediaTime() * 1000 }

func frontApp() -> NSRunningApplication? { NSWorkspace.shared.frontmostApplication }

func frontBundle() -> String { frontApp()?.bundleIdentifier ?? "?" }

func secureInputOn() -> Bool { IsSecureEventInputEnabled() }

func micStatus() -> String {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: return "authorized"
    case .denied: return "denied"
    case .restricted: return "restricted"
    case .notDetermined: return "not_determined"
    @unknown default: return "unknown"
    }
}

enum HoldKey: Int { case fn = 0, rightOption = 1, carbonCombo = 2 }

enum InsertMethod: Int { case auto = 0, ax = 1, paste = 2, unicode = 3, copyOnly = 4
    var name: String { ["auto", "ax", "paste", "unicode", "copy_only"][rawValue] }
}

// MARK: - Event tap (needs Accessibility only; Input Monitoring is never requested)

final class KeyTap {
    var port: CFMachPort?
    var source: CFRunLoopSource?
    var fnDown = false
    var rOptDown = false
    var onHold: ((HoldKey, Bool) -> Void)?
    var swallowEsc: (() -> Bool)?
    var onEsc: ((Bool) -> Void)?

    var installed: Bool { port != nil }
    var enabled: Bool { port.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    func install() -> Bool {
        if port != nil { return true }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let p = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: CGEventMask(mask), callback: { _, type, event, refcon in
            let tap = Unmanaged<KeyTap>.fromOpaque(refcon!).takeUnretainedValue()
            return tap.handle(type, event)
        }, userInfo: me) else {
            log.event("tap_install", ["ok": false, "ax_trusted": AXIsProcessTrusted()])
            return false
        }
        port = p
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, p, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: p, enable: true)
        log.event("tap_install", ["ok": true, "enabled": CGEvent.tapIsEnabled(tap: p)])
        return true
    }

    func remove() {
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        if let p = port { CFMachPortInvalidate(p) }
        port = nil; source = nil
        log.event("tap_removed")
    }

    func healthCheck() {
        guard let p = port, !CGEvent.tapIsEnabled(tap: p) else { return }
        CGEvent.tapEnable(tap: p, enable: true)
        log.event("tap_reenabled_by_health_check", ["enabled_now": CGEvent.tapIsEnabled(tap: p)])
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let p = port { CGEvent.tapEnable(tap: p, enable: true) }
            log.event("tap_disabled", ["reason": type == .tapDisabledByTimeout ? "timeout" : "user_input"])
            return Unmanaged.passUnretained(event)
        }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        if type == .flagsChanged {
            if code == Int64(kVK_Function) {
                let down = flags.contains(.maskSecondaryFn)
                if down != fnDown {
                    fnDown = down
                    log.event("key", ["key": "fn", "down": down, "secure_input": secureInputOn(), "front": frontBundle()])
                    onHold?(.fn, down)
                }
            } else if code == Int64(kVK_RightOption) {
                let down = flags.rawValue & 0x40 != 0  // NX_DEVICERALTKEYMASK
                if down != rOptDown {
                    rOptDown = down
                    log.event("key", ["key": "right_option", "down": down, "secure_input": secureInputOn(), "front": frontBundle()])
                    onHold?(.rightOption, down)
                }
            }
            return Unmanaged.passUnretained(event)
        }
        if code == Int64(kVK_Escape) && type == .keyDown {
            let swallow = swallowEsc?() ?? false
            log.event("key", ["key": "esc", "down": true, "swallowed": swallow, "secure_input": secureInputOn(), "front": frontBundle()])
            onEsc?(swallow)
            return swallow ? nil : Unmanaged.passUnretained(event)
        }
        if code == Int64(kVK_Space) && flags.contains(.maskControl) && flags.contains(.maskShift) {
            log.event("key", ["key": "ctrl_shift_space_seen_by_tap", "down": type == .keyDown,
                              "autorepeat": event.getIntegerValueField(.keyboardEventAutorepeat) != 0])
        }
        return Unmanaged.passUnretained(event)
    }
}

// MARK: - Carbon hot keys (no permission needed)

final class CarbonKeys {
    private var combo: EventHotKeyRef?
    private var escRefs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    var onCombo: ((Bool) -> Void)?
    var onEsc: (() -> Void)?
    private let sig = OSType(0x5353_5042)  // 'SSPB'

    func start() {
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let me = Unmanaged.passUnretained(self).toOpaque()
        let st = InstallEventHandler(GetApplicationEventTarget(), { _, event, user in
            let keys = Unmanaged<CarbonKeys>.fromOpaque(user!).takeUnretainedValue()
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            if id.id == 1 { keys.onCombo?(pressed) } else if pressed { keys.onEsc?() }
            return noErr
        }, 2, &specs, me, &handler)
        let rc = RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | shiftKey), EventHotKeyID(signature: sig, id: 1),
                                     GetApplicationEventTarget(), 0, &combo)
        log.event("carbon_register", ["handler_status": Int(st), "combo_status": Int(rc), "combo": "ctrl+shift+space"])
    }

    /// ED-004 copy-only mode: grab Esc only while recording/processing. The user is still holding ctrl+shift,
    /// so register both plain Esc and ctrl+shift+Esc.
    func grabEsc(_ on: Bool) {
        if on, escRefs.isEmpty {
            for (i, mods) in [0, controlKey | shiftKey].enumerated() {
                var ref: EventHotKeyRef?
                let rc = RegisterEventHotKey(UInt32(kVK_Escape), UInt32(mods), EventHotKeyID(signature: sig, id: UInt32(10 + i)),
                                             GetApplicationEventTarget(), 0, &ref)
                if let ref { escRefs.append(ref) }
                log.event("carbon_esc_register", ["mods": mods, "status": Int(rc)])
            }
        } else if !on {
            escRefs.forEach { UnregisterEventHotKey($0) }
            escRefs.removeAll()
        }
    }
}

// MARK: - Accessibility helpers

enum AX {
    static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }

    static func string(_ el: AXUIElement, _ name: String) -> String? { attr(el, name) as? String }

    static func settable(_ el: AXUIElement, _ name: String) -> Bool {
        var b = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(el, name as CFString, &b) == .success && b.boolValue
    }

    /// Electron and Chromium only build their AX tree after AXManualAccessibility / AXEnhancedUserInterface is set.
    static func focused(enableManualAX: Bool = true) -> (AXUIElement?, [String: Any]) {
        var info: [String: Any] = [:]
        let sys = AXUIElementCreateSystemWide()
        if let v = attr(sys, kAXFocusedUIElementAttribute as String) {
            return ((v as! AXUIElement), info)
        }
        info["focused_initially_nil"] = true
        guard enableManualAX, let pid = frontApp()?.processIdentifier else { return (nil, info) }
        let app = AXUIElementCreateApplication(pid)
        info["set_manual_ax"] = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue).rawValue
        usleep(150_000)
        if let v = attr(sys, kAXFocusedUIElementAttribute as String) { return ((v as! AXUIElement), info) }
        if let v = attr(app, kAXFocusedUIElementAttribute as String) { info["via_app_element"] = true; return ((v as! AXUIElement), info) }
        return (nil, info)
    }

    static func describe(_ el: AXUIElement) -> [String: Any] {
        var d: [String: Any] = [:]
        d["role"] = string(el, kAXRoleAttribute as String) ?? "?"
        d["subrole"] = string(el, kAXSubroleAttribute as String) ?? ""
        d["value_readable"] = string(el, kAXValueAttribute as String) != nil
        d["value_len"] = string(el, kAXValueAttribute as String)?.count ?? -1
        d["selected_text_settable"] = settable(el, kAXSelectedTextAttribute as String)
        d["value_settable"] = settable(el, kAXValueAttribute as String)
        d["selected_range_readable"] = attr(el, kAXSelectedTextRangeAttribute as String) != nil
        var names: CFArray?
        AXUIElementCopyParameterizedAttributeNames(el, &names)
        d["string_for_range"] = ((names as? [String]) ?? []).contains(kAXStringForRangeParameterizedAttribute as String)
        return d
    }

    static func isSecureField(_ el: AXUIElement) -> Bool {
        string(el, kAXSubroleAttribute as String) == (kAXSecureTextFieldSubrole as String)
    }

    /// Text around the caret (for REQ-003 learning): read up to `radius` characters on each side via
    /// AXStringForRange. Returns only the length so the log never contains user text.
    static func contextLength(_ el: AXUIElement, radius: Int = 200) -> Int {
        guard let rv = attr(el, kAXSelectedTextRangeAttribute as String) else { return -1 }
        var r = CFRange()
        guard AXValueGetValue(rv as! AXValue, .cfRange, &r) else { return -1 }
        var q = CFRange(location: max(0, r.location - radius), length: radius * 2)
        if let total = attr(el, kAXNumberOfCharactersAttribute as String) as? Int {
            q.length = min(q.length, max(0, total - q.location))
        }
        guard let param = AXValueCreate(.cfRange, &q) else { return -1 }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXStringForRangeParameterizedAttribute as CFString, param, &out) == .success
        else { return -1 }
        return (out as? String)?.count ?? -1
    }
}

// MARK: - Pasteboard

final class LazyText: NSObject, NSPasteboardItemDataProvider {
    let text: String
    let createdMs = nowMs()
    var onRead: ((Double) -> Void)?
    init(_ text: String) { self.text = text }
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        item.setString(text, forType: type)
        onRead?(nowMs() - createdMs)
    }
    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {}
}

enum Clip {
    static let pb = NSPasteboard.general
    static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    static func accessBehavior() -> String {
        if #available(macOS 15.4, *) {
            switch pb.accessBehavior {
            case .default: return "default"
            case .ask: return "ask"
            case .alwaysAllow: return "always_allow"
            case .alwaysDeny: return "always_deny"
            @unknown default: return "unknown"
            }
        }
        return "n/a"
    }

    typealias Snapshot = [[(NSPasteboard.PasteboardType, Data)]]

    /// Full read of every item and type (this is what "restore the user's clipboard" requires).
    static func snapshot() -> (Snapshot, Double) {
        let t = nowMs()
        let snap: Snapshot = (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { ty in item.data(forType: ty).map { (ty, $0) } }
        }
        return (snap, nowMs() - t)
    }

    static func restore(_ snap: Snapshot) {
        pb.clearContents()
        let items: [NSPasteboardItem] = snap.map { pairs in
            let it = NSPasteboardItem()
            for (ty, d) in pairs { it.setData(d, forType: ty) }
            return it
        }
        if !items.isEmpty { pb.writeObjects(items) }
    }

    static func writeMarked(_ text: String, lazy: LazyText?, markers: Bool) {
        pb.clearContents()
        let it = NSPasteboardItem()
        if let lazy { it.setDataProvider(lazy, forTypes: [.string]) } else { it.setString(text, forType: .string) }
        if markers {
            it.setData(Data(), forType: transient)
            it.setData(Data(), forType: concealed)
        }
        pb.writeObjects([it])
    }
}

// MARK: - Synthetic keys

enum Keys {
    static func post(_ code: Int, flags: CGEventFlags = []) {
        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(code), keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
    }

    static func typeUnicode(_ text: String) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            let chunk = Array(units[i ..< min(i + 20, units.count)])
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)
                chunk.withUnsafeBufferPointer { e?.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
                e?.flags = []
                e?.post(tap: .cghidEventTap)
            }
            i += 20
            usleep(2_000)
        }
    }
}

// MARK: - Recording capsule (ED-007)

final class Capsule {
    private let panel: NSPanel
    private var label: NSTextField?
    private var baseText = ""
    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 40),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        let box = NSView(frame: panel.contentView!.bounds)
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.92).cgColor
        box.layer?.cornerRadius = 20
        let dot = NSView(frame: NSRect(x: 16, y: 14, width: 12, height: 12))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 6
        let label = NSTextField(labelWithString: "闪说 · 正在录音（探测）")
        label.textColor = .white
        label.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        label.frame = NSRect(x: 38, y: 10, width: 250, height: 20)
        box.addSubview(dot)
        box.addSubview(label)
        panel.contentView = box
        self.label = label
    }

    /// Peak level 0...1 shown as a bar so the user can see capture is live.
    func setLevel(_ peak: Float) {
        let n = min(8, Int((peak * 12).rounded(.up)))
        label?.stringValue = baseText + " " + String(repeating: "▮", count: n) + String(repeating: "▯", count: 8 - n)
    }

    /// Screen of the frontmost app's focused window (AX); falls back to the screen under the mouse.
    private func targetScreen() -> (NSScreen, String) {
        if let pid = frontApp()?.processIdentifier {
            let app = AXUIElementCreateApplication(pid)
            if let w = AX.attr(app, kAXFocusedWindowAttribute as String),
               let pv = AX.attr(w as! AXUIElement, kAXPositionAttribute as String) {
                var p = CGPoint.zero
                AXValueGetValue(pv as! AXValue, .cgPoint, &p)
                let primaryH = NSScreen.screens.first?.frame.height ?? 0
                let flipped = NSPoint(x: p.x + 20, y: primaryH - p.y - 20)
                if let s = NSScreen.screens.first(where: { $0.frame.contains(flipped) }) { return (s, "focused_window") }
            }
        }
        let m = NSEvent.mouseLocation
        return (NSScreen.screens.first(where: { $0.frame.contains(m) }) ?? NSScreen.main!, "mouse")
    }

    func show(since keyMs: Double, text: String = "闪说 · 正在录音（探测）") {
        baseText = text
        label?.stringValue = text
        let (screen, how) = targetScreen()
        let f = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2, y: f.minY + 60))
        panel.orderFrontRegardless()
        panel.display()
        log.event("capsule_shown", ["ms_since_key": Int(nowMs() - keyMs), "screen": NSScreen.screens.firstIndex(of: screen) ?? -1,
                                    "screens": NSScreen.screens.count, "by": how, "front": frontBundle(),
                                    "visible": panel.isVisible, "on_active_space": panel.isOnActiveSpace])
    }

    func hide() { panel.orderOut(nil) }
}

// MARK: - Microphone (real capture; only level and duration are computed, audio is never stored)

final class Mic {
    private let engine = AVAudioEngine()
    private var startMs = 0.0
    private var firstBufferMs: Double?
    private var frames: Int = 0
    private var peak: Float = 0
    private var rate: Double = 0
    private(set) var running = false
    var onLevel: ((Float) -> Void)?

    func start(keyMs: Double) {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            log.event("mic_skipped", ["status": micStatus()])
            return
        }
        startMs = nowMs()
        firstBufferMs = nil
        frames = 0
        peak = 0
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        rate = fmt.sampleRate
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
            let n = Int(buf.frameLength)
            var p: Float = 0
            if let ch = buf.floatChannelData?[0] { for i in 0 ..< n { p = max(p, abs(ch[i])) } }
            DispatchQueue.main.async {
                guard let self, self.running else { return }
                if self.firstBufferMs == nil {
                    self.firstBufferMs = nowMs() - self.startMs
                    log.event("mic_first_buffer", ["ms_since_start": Int(self.firstBufferMs!), "ms_since_key": Int(nowMs() - keyMs)])
                }
                self.frames += n
                self.peak = max(self.peak, p)
                self.onLevel?(p)
            }
        }
        do {
            try engine.start()
            running = true
            log.event("mic_started", ["start_ms": Int(nowMs() - startMs), "ms_since_key": Int(nowMs() - keyMs),
                                      "sample_rate": Int(rate), "channels": Int(fmt.channelCount)])
        } catch {
            input.removeTap(onBus: 0)
            log.event("mic_start_failed", ["error": "\(error)"])
        }
    }

    func stop() -> [String: Any] {
        guard running else { return [:] }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        return ["captured_s": rate > 0 ? Double(frames) / rate : -1, "peak": Double(peak),
                "first_buffer_ms": firstBufferMs.map { Int($0) } ?? -1]
    }
}

// MARK: - App

final class Probe: NSObject, NSApplicationDelegate {
    let tap = KeyTap()
    let carbon = CarbonKeys()
    let capsule = Capsule()
    let mic = Mic()
    var window: NSWindow!
    var statusLabel: NSTextField!
    var logView: NSTextView!
    var holdPopup: NSPopUpButton!
    var methodPopup: NSPopUpButton!
    var escCheck: NSButton!
    var lastTrusted = false
    var lastSecure = false
    var holding = false
    var holdKey: HoldKey = .fn
    var holdStartMs = 0.0
    var blockedSecure = false
    var cancelled = false
    var attempt = 0
    var lastAttempt: [String: Any] = [:]
    var pendingLazy: LazyText?
    var lines: [String] = []

    var selectedHold: HoldKey { HoldKey(rawValue: holdPopup.indexOfSelectedItem) ?? .fn }
    var selectedMethod: InsertMethod { InsertMethod(rawValue: methodPopup.indexOfSelectedItem) ?? .auto }
    var copyOnly: Bool { !AXIsProcessTrusted() }

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMenu()
        buildWindow()
        log.onLine = { [weak self] in self?.append($0) }
        lastTrusted = AXIsProcessTrusted()
        lastSecure = secureInputOn()
        log.event("launch", ["ax_trusted": lastTrusted, "mic": micStatus(), "secure_input": lastSecure,
                             "pb_access": Clip.accessBehavior(), "os": ProcessInfo.processInfo.operatingSystemVersionString,
                             "path": Bundle.main.bundlePath, "screens": NSScreen.screens.count])
        carbon.start()
        carbon.onCombo = { [weak self] down in self?.carbonCombo(down) }
        carbon.onEsc = { [weak self] in
            log.event("carbon_esc", ["holding": self?.holding ?? false])
            self?.cancel(by: "carbon_esc")
        }
        tap.onHold = { [weak self] key, down in
            guard let self, key == self.selectedHold else { return }
            down ? self.begin(key) : self.end(key)
        }
        tap.swallowEsc = { [weak self] in (self?.holding ?? false) && self?.escCheck.state == .on }
        tap.onEsc = { [weak self] swallowed in if swallowed { self?.cancel(by: "tap_esc") } }
        if lastTrusted { _ = tap.install() }
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.poll() }
        Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in self?.tap.healthCheck() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            log.event("front_app", ["bundle": app?.bundleIdentifier ?? "?", "name": app?.localizedName ?? ""])
        }
        poll()
    }

    // MARK: status

    func poll() {
        let trusted = AXIsProcessTrusted()
        if trusted != lastTrusted {
            lastTrusted = trusted
            log.event("ax_trust_changed", ["now": trusted])
            if trusted {
                let ok = tap.install()
                log.event("tap_after_grant_without_restart", ["ok": ok, "enabled": tap.enabled])
            } else {
                tap.remove()
                log.event("fallback_copy_only", ["hotkey": "ctrl+shift+space"])
            }
        }
        let secure = secureInputOn()
        if secure != lastSecure {
            lastSecure = secure
            log.event("secure_input_changed", ["now": secure, "front": frontBundle()])
        }
        statusLabel.stringValue = """
        build \(log.build)   辅助功能：\(trusted ? "已授权" : "未授权（仅复制模式，用 ⌃⇧Space）")   麦克风：\(micStatus())
        事件 tap：\(tap.installed ? (tap.enabled ? "已安装·启用" : "已安装·被禁用") : "未安装")   安全输入：\(secure ? "开" : "关")   剪贴板访问：\(Clip.accessBehavior())
        前台应用：\(frontApp()?.localizedName ?? "?")（\(frontBundle())）   日志：\(log.url.path)
        """
    }

    // MARK: hold-to-talk flow

    func carbonCombo(_ down: Bool) {
        log.event("carbon_combo", ["down": down, "ax_trusted": AXIsProcessTrusted(), "front": frontBundle(), "secure_input": secureInputOn()])
        guard selectedHold == .carbonCombo || copyOnly else { return }
        down ? begin(.carbonCombo) : end(.carbonCombo)
    }

    func begin(_ key: HoldKey) {
        guard !holding else { return }
        holding = true
        holdKey = key
        cancelled = false
        holdStartMs = nowMs()
        let focus = AXIsProcessTrusted() ? AX.focused(enableManualAX: false).0 : nil
        blockedSecure = secureInputOn() || (focus.map(AX.isSecureField) ?? false)
        if blockedSecure {
            log.event("hold_blocked_secure", ["key": "\(key)", "front": frontBundle(), "secure_input": secureInputOn()])
            return
        }
        capsule.show(since: holdStartMs, text: copyOnly ? "闪说 · 正在录音（仅复制）" : "闪说 · 正在录音（探测）")
        mic.onLevel = { [weak self] p in self?.capsule.setLevel(p) }
        mic.start(keyMs: holdStartMs)
        if copyOnly { carbon.grabEsc(true) }
        log.event("hold_begin", ["key": "\(key)", "front": frontBundle(), "mode": copyOnly ? "copy_only" : "direct"])
    }

    func end(_ key: HoldKey) {
        guard holding, key == holdKey else { return }
        holding = false
        capsule.hide()
        var row: [String: Any] = ["key": "\(key)", "held_ms": Int(nowMs() - holdStartMs), "cancelled": cancelled, "blocked_secure": blockedSecure]
        row.merge(mic.stop()) { a, _ in a }
        log.event("hold_end", row)
        if blockedSecure || cancelled { carbon.grabEsc(false); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            self.insertTest()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.carbon.grabEsc(false) }
        }
    }

    func cancel(by: String) {
        guard holding else { return }
        cancelled = true
        capsule.hide()
        var row: [String: Any] = ["by": by, "front": frontBundle()]
        row.merge(mic.stop()) { a, _ in a }
        log.event("cancelled", row)
    }

    // MARK: insertion test

    func insertTest() {
        attempt += 1
        let marker = "闪说测试\(attempt) Shanshuo✓"
        var row: [String: Any] = ["attempt": attempt, "front": frontBundle(), "front_name": frontApp()?.localizedName ?? "",
                                  "secure_input": secureInputOn(), "method_selected": selectedMethod.name,
                                  "mode": copyOnly ? "copy_only" : "direct"]
        if copyOnly || selectedMethod == .copyOnly {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(marker, forType: .string)
            row["result"] = "copied_to_clipboard"
            finish(row)
            return
        }
        let (focused, finfo) = AX.focused()
        row.merge(finfo) { a, _ in a }
        var used = selectedMethod
        let terminalApps = ["com.apple.Terminal", "com.googlecode.iterm2"]
        guard let el = focused else {
            row["focused"] = false
            if used == .auto || used == .ax { used = terminalApps.contains(frontBundle()) ? .unicode : .paste }
            row["method_used"] = used.name
            perform(used, marker, nil, &row)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.finish(row) }
            return
        }
        row["focused"] = true
        row.merge(AX.describe(el)) { a, _ in a }
        if AX.isSecureField(el) {
            row["result"] = "blocked_secure_field"
            finish(row)
            return
        }
        row["context_len_before"] = AX.contextLength(el)
        if used == .auto {
            if terminalApps.contains(frontBundle()) { used = .unicode }
            else { used = (row["selected_text_settable"] as? Bool == true) ? .ax : .paste }
        }
        row["method_used"] = used.name
        perform(used, marker, el, &row)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if let v = AX.string(el, kAXValueAttribute as String) {
                row["verified"] = v.contains(marker) ? "yes" : "no"
            } else {
                row["verified"] = "unreadable"
            }
            row["context_len_after"] = AX.contextLength(el)
            self.finish(row)
        }
    }

    func perform(_ m: InsertMethod, _ text: String, _ el: AXUIElement?, _ row: inout [String: Any]) {
        switch m {
        case .ax:
            guard let el else { row["ax_set_error"] = "no_element"; return }
            row["ax_set_error"] = AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, text as CFString).rawValue
        case .unicode:
            Keys.typeUnicode(text)
        default:
            pasteInsert(text, &row)
        }
    }

    func pasteInsert(_ text: String, _ row: inout [String: Any]) {
        let (snap, readMs) = Clip.snapshot()
        row["clipboard_items_read"] = snap.count
        row["clipboard_read_ms"] = Int(readMs)
        row["pb_access"] = Clip.accessBehavior()
        let n = attempt
        let lazy = LazyText(text)
        pendingLazy = lazy
        var restored = false
        var cmdVAt = 0.0
        let restore: (String) -> Void = { how in
            guard !restored else { return }
            restored = true
            Clip.restore(snap)
            log.event("clipboard_restored", ["attempt": n, "how": how, "items": snap.count])
        }
        lazy.onRead = { ms in
            log.event("paste_data_requested", ["attempt": n, "ms_since_write": Int(ms), "before_cmd_v": cmdVAt == 0,
                                               "ms_after_cmd_v": cmdVAt == 0 ? -1 : Int(nowMs() - cmdVAt)])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { restore("after_target_read") }
        }
        Clip.writeMarked(text, lazy: lazy, markers: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            cmdVAt = nowMs()
            Keys.post(kVK_ANSI_V, flags: .maskCommand)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if !restored { log.event("clipboard_restore_fallback", ["attempt": n]) }
            restore("fallback_1s")
        }
    }

    func finish(_ row: [String: Any]) {
        lastAttempt = row
        log.event("insert_attempt", row)
    }

    // MARK: buttons

    @objc func verdictOK() { verdict("visible_ok") }
    @objc func verdictMissing() { verdict("not_visible") }
    @objc func verdictWrong() { verdict("wrong_place_or_text") }
    func verdict(_ v: String) {
        log.event("manual_verdict", ["attempt": lastAttempt["attempt"] ?? -1, "front": lastAttempt["front"] ?? "?",
                                     "method_used": lastAttempt["method_used"] ?? lastAttempt["result"] ?? "?", "verdict": v])
    }

    @objc func requestAX() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        log.event("ax_prompt_requested", ["trusted_now": AXIsProcessTrustedWithOptions(opts)])
    }

    @objc func openAXOld() { openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility", "ax_old") }
    @objc func openAXNew() { openURL("x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility", "ax_new") }
    @objc func openMic() { openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone", "mic_old") }
    func openURL(_ s: String, _ name: String) {
        let ok = NSWorkspace.shared.open(URL(string: s)!)
        log.event("deeplink_opened", ["which": name, "ok": ok])
    }

    @objc func requestMic() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            log.event("mic_request_result", ["granted": granted, "status": micStatus()])
        }
    }

    @objc func readClipboard() {
        let (snap, ms) = Clip.snapshot()
        log.event("clipboard_read_test", ["items": snap.count, "types": snap.first?.count ?? 0, "ms": Int(ms),
                                          "pb_access": Clip.accessBehavior(), "front": frontBundle()])
    }

    @objc func writeTransient() {
        Clip.writeMarked("闪说剪贴板测试·带标记 \(Date())", lazy: nil, markers: true)
        log.event("clipboard_write_test", ["markers": true])
    }

    @objc func writePlain() {
        Clip.writeMarked("闪说剪贴板测试·无标记 \(Date())", lazy: nil, markers: false)
        log.event("clipboard_write_test", ["markers": false])
    }

    @objc func capsuleLater() {
        log.event("capsule_test_scheduled", ["delay_s": 3])
        let t = nowMs() + 3000
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.capsule.show(since: t) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { self.capsule.hide() }
    }

    @objc func revealLog() { NSWorkspace.shared.activateFileViewerSelecting([log.url]) }

    /// Writes <log dir>/done; the agent-side lock holder then lets bench/asr/run_terminal.sh start timing.
    @objc func allDone() {
        let done = log.url.deletingLastPathComponent().appendingPathComponent("done")
        FileManager.default.createFile(atPath: done.path, contents: Data(log.build.utf8))
        log.event("t002_done", ["done_file": done.path])
        let a = NSAlert()
        a.messageText = "已记录。延迟测试将在 1 分钟内开始"
        a.informativeText = "接下来约 15～25 分钟请尽量不要运行大型应用，轻度使用没有问题。终端显示“全部完成”后告诉 Manus 即可。"
        a.runModal()
    }

    // MARK: UI

    func append(_ line: String) {
        lines.append(line)
        if lines.count > 400 { lines.removeFirst(lines.count - 400) }
        logView.string = lines.joined(separator: "\n")
        logView.scrollToEndOfDocument(nil)
    }

    func button(_ title: String, _ sel: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: sel)
        b.bezelStyle = .rounded
        return b
    }

    func row(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.spacing = 8
        return s
    }

    func label(_ s: String, bold: Bool = false) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = bold ? .boldSystemFont(ofSize: 12) : .systemFont(ofSize: 12)
        return l
    }

    func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 640),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "闪说 · 平台能力探测（T002）"
        statusLabel = label("")
        statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        statusLabel.maximumNumberOfLines = 3

        holdPopup = NSPopUpButton()
        holdPopup.addItems(withTitles: ["按住 Fn", "按住右 Option", "按住 ⌃⇧Space（Carbon）"])
        methodPopup = NSPopUpButton()
        methodPopup.addItems(withTitles: ["插入：自动（AX 优先）", "插入：AX 直接写入", "插入：粘贴并恢复剪贴板", "插入：Unicode 输入", "插入：仅复制"])
        escCheck = NSButton(checkboxWithTitle: "按住期间拦截 Esc", target: nil, action: nil)
        escCheck.state = .on

        let rows: [NSView] = [
            statusLabel,
            label("1. 权限", bold: true),
            row([button("请求辅助功能（系统弹窗）", #selector(requestAX)), button("辅助功能设置（旧链接）", #selector(openAXOld)),
                 button("辅助功能设置（新链接）", #selector(openAXNew)), button("请求麦克风", #selector(requestMic)),
                 button("麦克风设置", #selector(openMic))]),
            label("2. 按住说话与插入：选择按键和插入方式，切到目标应用的输入框，按住 1 秒后松开", bold: true),
            row([holdPopup, methodPopup, escCheck]),
            row([label("上一次插入："), button("看到了 ✓", #selector(verdictOK)), button("没看到 ✗", #selector(verdictMissing)),
                 button("位置或内容不对", #selector(verdictWrong))]),
            label("3. 剪贴板与胶囊", bold: true),
            row([button("读取剪贴板（看是否弹提示）", #selector(readClipboard)), button("写入带 Transient 标记的文字", #selector(writeTransient)),
                 button("写入无标记文字（对照）", #selector(writePlain)), button("3 秒后显示胶囊 5 秒", #selector(capsuleLater))]),
            row([button("打开日志文件", #selector(revealLog)), button("全部测完 → 开始延迟测试", #selector(allDone))]),
        ]
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 8, right: 14)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        logView = NSTextView()
        logView.isEditable = false
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.autoresizingMask = [.width]
        scroll.documentView = logView

        let outer = NSStackView(views: [stack, scroll])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 4
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalTo: outer.widthAnchor, constant: -28).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        window.contentView = outer
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出探测", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = main
    }
}

let app = NSApplication.shared
let probe = Probe()
app.delegate = probe
app.setActivationPolicy(.regular)
app.run()
