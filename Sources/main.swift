// ThaiPTT — Push-to-talk dictation สำหรับ macOS ด้วย Speech framework
// กดปุ่มที่ตั้งไว้ค้าง (ค่าเริ่มต้น ⌥ Option ขวา) → พูด → ปล่อย → ข้อความถูกวางที่ตำแหน่งเคอร์เซอร์
// ไม่มีเสียง feedback ตอนเริ่ม/จบ · ขณะพูดแสดงคลื่นเสียงด้านล่างกลางจอ

import Cocoa
import Speech
import AVFoundation
import ApplicationServices
import Carbon.HIToolbox

// MARK: - Config

enum Config {
    /// รอผลลัพธ์สุดท้ายหลังปล่อยปุ่มนานสุดกี่วินาที (ต่อหนึ่งรอบการถอดความ)
    static let finalResultTimeout: TimeInterval = 2.0
    /// โหมดอัตโนมัติ: ถ้าภาษาแรกได้ confidence ≥ ค่านี้ ใช้ผลนั้นทันทีโดยไม่ลองภาษาอื่น
    static let autoAcceptConfidence = 0.6
    /// คืนค่า clipboard เดิมหลังวางข้อความ (วินาที)
    static let restoreClipboardDelay: TimeInterval = 0.6
    /// เติมเครื่องหมายวรรคตอนอัตโนมัติ (macOS 13+)
    static let addsPunctuation = true
}

// MARK: - Settings (เก็บใน UserDefaults)

struct Hotkey {
    let id: String
    let title: String
    let keyCode: UInt16
    /// device-dependent modifier bit — แยกซ้าย/ขวาได้ ไม่สับสนเมื่อกดอีกข้างค้างอยู่
    let mask: UInt

    static let all: [Hotkey] = [
        Hotkey(id: "rightOption",  title: "Right Option ⌥",  keyCode: 61, mask: 0x40),
        Hotkey(id: "leftOption",   title: "Left Option ⌥",   keyCode: 58, mask: 0x20),
        Hotkey(id: "rightCommand", title: "Right Command ⌘", keyCode: 54, mask: 0x10),
        Hotkey(id: "rightControl", title: "Right Control ⌃", keyCode: 62, mask: 0x2000),
        Hotkey(id: "rightShift",   title: "Right Shift ⇧",   keyCode: 60, mask: 0x04),
        Hotkey(id: "fn",           title: "Fn / Globe 🌐",   keyCode: 63,
               mask: NSEvent.ModifierFlags.function.rawValue),
    ]
    static let `default` = all[0]
}

enum LanguageMode: String, CaseIterable {
    case auto
    case thai = "th-TH"
    case english = "en-US"

    var title: String {
        switch self {
        case .auto: return "Automatic (Thai / English)"
        case .thai: return "Thai"
        case .english: return "English (US)"
        }
    }

    static let autoCandidates = [LanguageMode.thai.rawValue, LanguageMode.english.rawValue]

    static func name(of localeID: String) -> String {
        LanguageMode(rawValue: localeID)?.title ?? localeID
    }
}

enum Settings {
    private static let d = UserDefaults.standard

    static var hotkey: Hotkey {
        get { Hotkey.all.first { $0.id == d.string(forKey: "hotkey") } ?? .default }
        set { d.set(newValue.id, forKey: "hotkey") }
    }

    static var language: LanguageMode {
        get { LanguageMode(rawValue: d.string(forKey: "language") ?? "") ?? .auto }
        set { d.set(newValue.rawValue, forKey: "language") }
    }

    /// ภาษาที่ตรวจพบล่าสุดในโหมดอัตโนมัติ — ใช้เป็นภาษาแรกในครั้งถัดไป
    static var lastDetected: String? {
        get { d.string(forKey: "lastDetected") }
        set { d.set(newValue, forKey: "lastDetected") }
    }

    /// รายการภาษาที่จะลอง เรียงตามลำดับ
    static var candidates: [String] {
        switch language {
        case .auto:
            let first = lastDetected.flatMap { LanguageMode.autoCandidates.contains($0) ? $0 : nil }
                ?? LanguageMode.thai.rawValue
            return [first] + LanguageMode.autoCandidates.filter { $0 != first }
        case let fixed:
            return [fixed.rawValue]
        }
    }
}

// MARK: - Speech recognition

struct Transcript {
    let localeID: String
    let text: String
    let confidence: Double
}

/// การถอดความหนึ่งรอบ ด้วยหนึ่งภาษา
final class RecognitionPass {
    let localeID: String
    let request = SFSpeechAudioBufferRecognitionRequest()
    private let recognizer: SFSpeechRecognizer
    private var task: SFSpeechRecognitionTask?
    private var latest: Transcript
    private var isDone = false
    private var waiter: ((Transcript) -> Void)?

    init?(localeID: String) {
        guard let r = SFSpeechRecognizer(locale: Locale(identifier: localeID)), r.isAvailable else { return nil }
        self.localeID = localeID
        recognizer = r
        latest = Transcript(localeID: localeID, text: "", confidence: 0)

        request.shouldReportPartialResults = true
        if r.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true // ใช้โมเดลบนเครื่อง ไม่ส่งเสียงออกไป
        }
        if #available(macOS 13.0, *) { request.addsPunctuation = Config.addsPunctuation }

        task = r.recognitionTask(with: request) { [weak self] result, error in
            let transcript = result.map { res -> Transcript in
                let segs = res.bestTranscription.segments
                let conf = segs.isEmpty ? 0 : segs.map { Double($0.confidence) }.reduce(0, +) / Double(segs.count)
                return Transcript(localeID: localeID, text: res.bestTranscription.formattedString, confidence: conf)
            }
            let finished = (result?.isFinal ?? false) || error != nil
            if let error { NSLog("ThaiPTT [\(localeID)]: \(error.localizedDescription)") }
            DispatchQueue.main.async {
                guard let self else { return }
                if let transcript { self.latest = transcript }
                if finished { self.isDone = true; self.fire() }
            }
        }
    }

    /// ปิดรับเสียง แล้วรอผลสุดท้าย (หรือ timeout)
    func finish(timeout: TimeInterval, then: @escaping (Transcript) -> Void) {
        request.endAudio()
        waiter = then
        if isDone { fire(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.fire() }
    }

    func cancel() {
        waiter = nil
        task?.cancel()
        task = nil
    }

    private func fire() {
        guard let w = waiter else { return }
        waiter = nil
        task?.cancel()
        task = nil
        w(latest)
    }
}

/// เก็บเสียงที่อัดไว้ (thread-safe) เพื่อถอดซ้ำด้วยภาษาอื่นในโหมดอัตโนมัติ
final class BufferRecorder {
    private let lock = NSLock()
    private var buffers: [AVAudioPCMBuffer] = []

    func reset() { lock.lock(); buffers.removeAll(); lock.unlock() }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let copy = buffer.copy() as? AVAudioPCMBuffer else { return }
        lock.lock(); buffers.append(copy); lock.unlock()
    }

    func take() -> [AVAudioPCMBuffer] {
        lock.lock(); defer { lock.unlock() }
        let b = buffers
        buffers = []
        return b
    }
}

final class Dictator {
    enum State { case idle, recording, finishing }

    private(set) var state: State = .idle
    /// ระดับเสียง 0…1 หลายค่าต่อ buffer (เรียกบน main thread)
    var onLevels: (([Float]) -> Void)?

    private let engine = AVAudioEngine()
    private let recorder = BufferRecorder()
    private var pass: RecognitionPass?
    private var candidates: [String] = []
    private var session = 0

    /// เริ่มอัดเสียงและถอดความ คืนค่า false ถ้าเริ่มไม่ได้
    func start() -> Bool {
        guard state == .idle else { return false }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else { return false } // ไม่มีไมค์หรือยังไม่ได้รับอนุญาต

        candidates = Settings.candidates
        guard let first = candidates.first, let live = RecognitionPass(localeID: first) else { return false }
        pass = live
        session += 1

        let req = live.request
        let rec = recorder
        let keepAudio = candidates.count > 1
        rec.reset()

        let tap: AVAudioNodeTapBlock = { [weak self] buffer, _ in
            req.append(buffer)
            if keepAudio { rec.append(buffer) }
            let levels = Dictator.levels(of: buffer)
            DispatchQueue.main.async { self?.onLevels?(levels) }
        }
        // ขนาด buffer ที่รองรับคือ 100–400 ms
        let bufferSize = AVAudioFrameCount(format.sampleRate * 0.1)

        input.removeTap(onBus: 0)
        if #available(macOS 27.0, *) {
            // API ใหม่ (NS_REFINED_FOR_SWIFT) ถูก import เป็น throws โดยช่อง error เป็น ()
            do {
                try input.__installTap(onBus: 0, bufferSize: bufferSize, format: format,
                                       error: (), block: tap)
            } catch {
                NSLog("ThaiPTT: installTap failed: \(error)")
                cleanupFailedStart()
                return false
            }
        } else {
            input.installTap(onBus: 0, bufferSize: bufferSize, format: format, block: tap)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            NSLog("ThaiPTT: audio engine start failed: \(error)")
            cleanupFailedStart()
            return false
        }

        state = .recording
        return true
    }

    /// หยุดอัด แล้วเรียก completion พร้อมข้อความสุดท้าย
    func stop(completion: @escaping (String) -> Void) {
        guard state == .recording, let live = pass else { return }
        state = .finishing
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)

        let s = session
        live.finish(timeout: Config.finalResultTimeout) { [weak self] first in
            guard let self, s == self.session else { return }
            let others = Array(self.candidates.dropFirst())
            if others.isEmpty || first.confidence >= Config.autoAcceptConfidence {
                self.done(first, completion)
            } else {
                self.tryOthers(others, best: first, audio: self.recorder.take(), session: s, completion)
            }
        }
    }

    /// โหมดอัตโนมัติ: ถอดเสียงที่อัดไว้ด้วยภาษาถัดไป แล้วเลือกผลที่ confidence สูงกว่า
    /// (Speech บนเครื่องรันหลายภาษาพร้อมกันไม่ได้ — จะมีแค่ task เดียวที่ได้ผล จึงต้องทำทีละรอบ)
    private func tryOthers(_ ids: [String], best: Transcript, audio: [AVAudioPCMBuffer],
                           session s: Int, _ completion: @escaping (String) -> Void) {
        guard let id = ids.first else { done(best, completion); return }
        let rest = Array(ids.dropFirst())
        guard let next = RecognitionPass(localeID: id) else {
            tryOthers(rest, best: best, audio: audio, session: s, completion)
            return
        }
        pass = next
        for b in audio { next.request.append(b) }
        next.finish(timeout: Config.finalResultTimeout * 2) { [weak self] t in
            guard let self, s == self.session else { return }
            let better = (best.text.isEmpty || (!t.text.isEmpty && t.confidence > best.confidence)) ? t : best
            NSLog("ThaiPTT auto: \(best.localeID)=\(best.confidence) \(t.localeID)=\(t.confidence) → \(better.localeID)")
            self.tryOthers(rest, best: better, audio: audio, session: s, completion)
        }
    }

    private func done(_ t: Transcript, _ completion: (String) -> Void) {
        pass = nil
        state = .idle
        if Settings.language == .auto, !t.text.isEmpty { Settings.lastDetected = t.localeID }
        completion(t.text)
    }

    private func cleanupFailedStart() {
        pass?.cancel()
        pass = nil
        recorder.reset()
    }

    /// แบ่ง buffer เป็นช่วงย่อย ~25 ms แล้วคำนวณระดับเสียง (RMS → dB → 0…1)
    static func levels(of buffer: AVAudioPCMBuffer) -> [Float] {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return [0] }
        let n = Int(buffer.frameLength)
        let chunk = max(1, Int(buffer.format.sampleRate * 0.025))
        var out: [Float] = []
        var i = 0
        while i < n {
            let end = min(n, i + chunk)
            var sum: Float = 0
            for j in i..<end { sum += data[j] * data[j] }
            let rms = (sum / Float(end - i)).squareRoot()
            let db = 20 * log10(max(rms, 1e-7))
            out.append(max(0, min(1, (db + 55) / 45))) // -55 dB … -10 dB
            i = end
        }
        return out
    }
}

// MARK: - Waveform overlay (ด้านล่างกลางจอ)

final class WaveformView: NSView {
    static let barCount = 36
    private(set) var levels = [Float](repeating: 0, count: WaveformView.barCount)

    func reset() { levels = [Float](repeating: 0, count: Self.barCount); needsDisplay = true }

    func push(_ level: Float) {
        levels.removeFirst()
        levels.append(level)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let n = CGFloat(levels.count)
        let slot = bounds.width / n
        let barW = max(2, slot * 0.55)
        let midY = bounds.midY
        NSColor.white.withAlphaComponent(0.9).setFill()
        for (i, l) in levels.enumerated() {
            let h = max(3, CGFloat(l) * bounds.height)
            let x = CGFloat(i) * slot + (slot - barW) / 2
            let r = NSRect(x: x, y: midY - h / 2, width: barW, height: h)
            NSBezierPath(roundedRect: r, xRadius: barW / 2, yRadius: barW / 2).fill()
        }
    }
}

final class WaveformOverlay {
    private let panel: NSPanel
    private let wave: WaveformView
    private var queue: [Float] = []
    private var timer: Timer?
    private let size = NSSize(width: 240, height: 48)

    init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        let radius = size.height / 2
        bg.maskImage = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }

        wave = WaveformView(frame: bg.bounds.insetBy(dx: 20, dy: 10))
        wave.autoresizingMask = [.width, .height]
        bg.addSubview(wave)
        panel.contentView = bg
    }

    /// จอที่ active = จอที่มีเมาส์อยู่
    private var activeScreen: NSScreen? {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main
    }

    func show() {
        guard let screen = activeScreen else { return }
        let vf = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.minY + 40))
        queue.removeAll()
        wave.reset()
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        // ระดับเสียงมาเป็นชุดทุก 100 ms — ปล่อยทีละค่าทุก 25 ms ให้คลื่นเลื่อนลื่น
        timer?.invalidate()
        let t = Timer(timeInterval: 0.025, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.queue.count > 8 { self.queue.removeFirst(self.queue.count - 8) }
            if !self.queue.isEmpty { self.wave.push(self.queue.removeFirst()) }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func push(_ levels: [Float]) { queue.append(contentsOf: levels) }

    func hide() {
        timer?.invalidate()
        timer = nil
        panel.orderOut(nil)
    }
}

// MARK: - Text insertion (วางผ่าน clipboard แล้วคืนค่าเดิม)

enum Inserter {
    static func insert(_ text: String) {
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general

        // เก็บ clipboard เดิม
        let saved: [NSPasteboardItem] = (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }

        pb.clearContents()
        pb.setString(text, forType: .string)
        let ourChange = pb.changeCount

        // ส่ง ⌘V
        let src = CGEventSource(stateID: .combinedSessionState)
        let v = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        // คืนค่า clipboard เดิม (ถ้าไม่มีใครเปลี่ยนในระหว่างนั้น)
        DispatchQueue.main.asyncAfter(deadline: .now() + Config.restoreClipboardDelay) {
            guard pb.changeCount == ourChange else { return }
            pb.clearContents()
            if !saved.isEmpty { pb.writeObjects(saved) }
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let dictator = Dictator()
    private let overlay = WaveformOverlay()
    private var keyIsDown = false
    private var monitors: [Any] = []

    private let hintItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let statusMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let hotkeyMenu = NSMenu()
    private let languageMenu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setIcon("mic")
        dictator.onLevels = { [weak self] in self?.overlay.push($0) }
        buildMenu()
        requestPermissions()
        installHotkey()
        updateStatus()
    }

    func menuWillOpen(_ menu: NSMenu) { updateStatus() }

    // MARK: Menu

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(hintItem)
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

        for hk in Hotkey.all {
            let item = NSMenuItem(title: hk.title, action: #selector(selectHotkey(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = hk.id
            hotkeyMenu.addItem(item)
        }
        let hotkeyItem = NSMenuItem(title: "Push-to-Talk Key", action: nil, keyEquivalent: "")
        hotkeyItem.submenu = hotkeyMenu
        menu.addItem(hotkeyItem)

        for mode in LanguageMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            languageMenu.addItem(item)
            if mode == .auto { languageMenu.addItem(.separator()) }
        }
        let languageItem = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)
        menu.addItem(.separator())

        let ax = NSMenuItem(title: "Open Accessibility Settings…", action: #selector(openAccessibility), keyEquivalent: "")
        ax.target = self
        menu.addItem(ax)
        let mic = NSMenuItem(title: "Open Microphone Settings…", action: #selector(openMicrophone), keyEquivalent: "")
        mic.target = self
        menu.addItem(mic)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit ThaiPTT", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func selectHotkey(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let hk = Hotkey.all.first(where: { $0.id == id }) else { return }
        if keyIsDown { keyIsDown = false; end() }
        Settings.hotkey = hk
        updateStatus()
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = LanguageMode(rawValue: raw) else { return }
        Settings.language = mode
        updateStatus()
    }

    // MARK: Permissions

    private func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { _ in
            DispatchQueue.main.async { self.updateStatus() }
        }
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            DispatchQueue.main.async { self.updateStatus() }
        }
        // ต้องมี Accessibility เพื่อฟังปุ่มแบบ global และส่ง ⌘V
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    private func updateStatus() {
        let hk = Settings.hotkey
        let lang = Settings.language
        hintItem.title = "Hold \(hk.title) to dictate"

        for item in hotkeyMenu.items { item.state = (item.representedObject as? String) == hk.id ? .on : .off }
        for item in languageMenu.items { item.state = (item.representedObject as? String) == lang.rawValue ? .on : .off }
        if let autoItem = languageMenu.items.first(where: { ($0.representedObject as? String) == LanguageMode.auto.rawValue }) {
            autoItem.title = LanguageMode.auto.title
                + (Settings.lastDetected.map { " — last: \(LanguageMode.name(of: $0))" } ?? "")
        }

        let speechOK = SFSpeechRecognizer.authorizationStatus() == .authorized
        let micOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let axOK = AXIsProcessTrusted()
        let onDevice = Settings.candidates.allSatisfy {
            SFSpeechRecognizer(locale: Locale(identifier: $0))?.supportsOnDeviceRecognition ?? false
        }
        func mark(_ b: Bool) -> String { b ? "✓" : "✗" }
        statusMenuItem.title = "\(onDevice ? "On-device" : "Apple servers") · Mic \(mark(micOK)) · Speech \(mark(speechOK)) · Accessibility \(mark(axOK))"
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openMicrophone() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

    // MARK: Hotkey

    private func installHotkey() {
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] e in
            self?.handleFlags(e)
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] e in
            self?.handleFlags(e)
            return e
        }) { monitors.append(l) }
    }

    private func handleFlags(_ e: NSEvent) {
        let hk = Settings.hotkey
        guard e.keyCode == hk.keyCode else { return }
        let down = e.modifierFlags.rawValue & hk.mask != 0
        if down && !keyIsDown {
            keyIsDown = true
            begin()
        } else if !down && keyIsDown {
            keyIsDown = false
            end()
        }
    }

    // MARK: Push-to-talk

    private func begin() {
        if dictator.start() {
            setIcon("mic.fill")
            overlay.show()
        } else {
            setIcon("mic.slash")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                if self?.dictator.state == .idle { self?.setIcon("mic") }
            }
        }
    }

    private func end() {
        overlay.hide()
        guard dictator.state == .recording else { return }
        setIcon("ellipsis.circle")
        dictator.stop { [weak self] text in
            self?.setIcon("mic")
            self?.updateStatus()
            Inserter.insert(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func setIcon(_ symbol: String) {
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "ThaiPTT")
        img?.isTemplate = true
        statusItem.button?.image = img
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // ไอคอนบน menu bar เท่านั้น ไม่มีใน Dock
app.run()
