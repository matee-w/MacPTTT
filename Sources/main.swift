// MacPTTT (Mac Push Talk to Text) — Push-to-talk dictation สำหรับ macOS ด้วย Speech framework
// กดปุ่มที่ตั้งไว้ค้าง (ค่าเริ่มต้น ⌥ Option ขวา) → พูด → ปล่อย → ข้อความถูกวางที่ตำแหน่งเคอร์เซอร์
// ไม่มีเสียง feedback ตอนเริ่ม/จบ · ขณะพูดแสดงคลื่นเสียงด้านล่างกลางจอ

import Cocoa
import Speech
import AVFoundation
import ApplicationServices
import Carbon.HIToolbox
import ServiceManagement

// MARK: - Config

enum Config {
    /// รอผลลัพธ์สุดท้ายหลังปล่อยปุ่มนานสุดกี่วินาที (ต่อหนึ่งรอบการถอดความ)
    static let finalResultTimeout: TimeInterval = 2.0
    /// โหมดอัตโนมัติ: ถ้าภาษาแรกได้ confidence ≥ ค่านี้ ใช้ผลนั้นทันทีโดยไม่ลองภาษาอื่น
    static let autoAcceptConfidence = 0.6
    /// คืนค่า clipboard เดิมหลังวางข้อความ (วินาที)
    static let restoreClipboardDelay: TimeInterval = 0.6
    /// กดปุ่มอื่นร่วมภายในช่วงนี้ (เช่น ⌥+คีย์ลัด) = ยกเลิก ไม่ใช่การพูด · แสดงคลื่นเสียงหลังกดค้างเกินนี้
    static let overlayDelay: TimeInterval = 0.15
}

// MARK: - Settings (เก็บใน UserDefaults)

struct Hotkey {
    let id: String
    let title: String
    let keyCode: UInt16
    /// device-dependent modifier bit — แยกซ้าย/ขวาได้ ไม่สับสนเมื่อกดอีกข้างค้างอยู่
    let mask: UInt

    /// ปุ่มฝั่งซ้าย (กดด้วยมือซ้ายได้สะดวก)
    static let left: [Hotkey] = [
        Hotkey(id: "leftOption",   title: "Left Option ⌥",   keyCode: 58, mask: 0x20),
        Hotkey(id: "leftControl",  title: "Left Control ⌃",  keyCode: 59, mask: 0x01),
        Hotkey(id: "leftCommand",  title: "Left Command ⌘",  keyCode: 55, mask: 0x08),
        Hotkey(id: "leftShift",    title: "Left Shift ⇧",    keyCode: 56, mask: 0x02),
        Hotkey(id: "fn",           title: "Fn / Globe 🌐",   keyCode: 63,
               mask: NSEvent.ModifierFlags.function.rawValue),
    ]
    static let right: [Hotkey] = [
        Hotkey(id: "rightOption",  title: "Right Option ⌥",  keyCode: 61, mask: 0x40),
        Hotkey(id: "rightCommand", title: "Right Command ⌘", keyCode: 54, mask: 0x10),
        Hotkey(id: "rightControl", title: "Right Control ⌃", keyCode: 62, mask: 0x2000),
        Hotkey(id: "rightShift",   title: "Right Shift ⇧",   keyCode: 60, mask: 0x04),
    ]
    static let all = left + right
    static let `default` = left[0]
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

    /// พิมพ์ข้อความทีละคำขณะพูด (ปิด = วางทั้งหมดตอนปล่อยปุ่ม)
    static var typeWhileSpeaking: Bool {
        get { d.object(forKey: "typeWhileSpeaking") as? Bool ?? true }
        set { d.set(newValue, forKey: "typeWhileSpeaking") }
    }

    /// ให้ Speech เติมเครื่องหมายวรรคตอนเอง (macOS 13+)
    static var autoPunctuation: Bool {
        get { d.object(forKey: "autoPunctuation") as? Bool ?? true }
        set { d.set(newValue, forKey: "autoPunctuation") }
    }

    /// แปลงคำสั่งเสียงภาษาไทย เช่น "ขึ้นบรรทัด", "ไม้ยมก" เป็นสัญลักษณ์
    static var voiceCommands: Bool {
        get { d.object(forKey: "voiceCommands") as? Bool ?? true }
        set { d.set(newValue, forKey: "voiceCommands") }
    }

    /// ตั้งค่าเปิดเมื่อ login แล้วหรือยัง (ทำครั้งแรกครั้งเดียว ต่อจากนั้นตามที่ผู้ใช้เลือก)
    static var didSetUpLoginItem: Bool {
        get { d.bool(forKey: "didSetUpLoginItem") }
        set { d.set(newValue, forKey: "didSetUpLoginItem") }
    }

    /// รายการภาษาที่จะลอง เรียงตามลำดับ — เฉพาะภาษาที่มีโมเดลบนเครื่อง (ทำงานแบบ offline เท่านั้น)
    static var candidates: [String] {
        switch language {
        case .auto:
            let available = LanguageMode.autoCandidates.filter(OnDevice.isAvailable)
            let first = lastDetected.flatMap { available.contains($0) ? $0 : nil } ?? available.first
            guard let first else { return [] }
            return [first] + available.filter { $0 != first }
        case let fixed:
            return OnDevice.isAvailable(fixed.rawValue) ? [fixed.rawValue] : []
        }
    }
}

/// ใช้เฉพาะโมเดลบนเครื่อง — ไม่ส่งเสียงออกไปที่เซิร์ฟเวอร์ และไม่ต้องต่อเน็ต
enum OnDevice {
    static func isAvailable(_ localeID: String) -> Bool {
        SFSpeechRecognizer(locale: Locale(identifier: localeID))?.supportsOnDeviceRecognition ?? false
    }

    /// ภาษาที่เลือกไว้แต่ยังไม่มีโมเดลบนเครื่อง
    static var missing: [String] {
        let wanted = Settings.language == .auto ? LanguageMode.autoCandidates : [Settings.language.rawValue]
        return wanted.filter { !isAvailable($0) }
    }
}

// MARK: - Voice commands (เครื่องหมายวรรคตอนด้วยเสียง)

/// คำสั่งเสียงภาษาไทย — ภาษาอังกฤษ Speech แปลงให้เองอยู่แล้ว ("comma", "new line", "question mark" ฯลฯ)
/// คำที่เลือกคือคำที่ทดสอบแล้วว่าตัวถอดความไทยบนเครื่องส่งออกมาเป็นข้อความ
/// ("เว้นวรรค" และ "บรรทัดใหม่" ถูกตัวถอดความกลืนหายไปเอง จึงใช้ไม่ได้)
enum VoiceCommands {
    static let table: [(phrase: String, symbol: String, label: String)] = [
        ("ย่อหน้าใหม่", "\n\n", "new paragraph"),
        ("ขึ้นบรรทัดใหม่", "\n", "new line"),
        ("ขึ้นบรรทัด", "\n", "new line"),
        ("วรรคตอน", "วรรคตอน", ""),          // คำปกติ — กันไม่ให้ "วรรค" ข้างในถูกแปลง
        ("วรรค", " ", "space"),
        ("ไม้ยมก", "ๆ", "ๆ"),
        ("ไปยาลน้อย", "ฯ", "ฯ"),
        ("ไปยานน้อย", "ฯ", ""),               // ตัวถอดความมักได้ยินเป็นแบบนี้
        ("จุลภาค", ",", ","),
        ("มหัพภาค", ".", "."),
        ("เครื่องหมายจุด", ".", "."),
        ("เครื่องหมายคำถาม", "?", "?"),
        ("เครื่องหมายตกใจ", "!", "!"),
        ("เปิดวงเล็บ", "(", "("),
        ("ปิดวงเล็บ", ")", ")"),
        ("เปิดอัญประกาศ", "\u{201C}", "\u{201C}"),
        ("ปิดอัญประกาศ", "\u{201D}", "\u{201D}"),
    ].sorted { $0.phrase.count > $1.phrase.count }

    /// สัญลักษณ์ที่ไม่ควรมีช่องว่างข้างหน้า / ข้างหลัง
    private static let noSpaceBefore: Set<Character> = [",", ".", "?", "!", ")", "\u{201D}", "ๆ", "ฯ", "\n"]
    private static let noSpaceAfter: Set<Character> = ["(", "\u{201C}", "\n"]
    private static let spaceAfter: Set<Character> = [",", ".", "?", "!", ")", "\u{201D}"]

    static func apply(_ text: String) -> String {
        guard Settings.voiceCommands else { return text }
        var out = ""
        var i = text.startIndex
        scan: while i < text.endIndex {
            for c in table where text[i...].hasPrefix(c.phrase) {
                if c.phrase != c.symbol, let first = c.symbol.first {
                    if noSpaceBefore.contains(first) { while out.last == " " { out.removeLast() } }
                    out += c.symbol
                    i = text.index(i, offsetBy: c.phrase.count)
                    if noSpaceAfter.contains(c.symbol.last!) || c.symbol == " " {
                        while i < text.endIndex, text[i] == " " { i = text.index(after: i) }
                    } else if spaceAfter.contains(first), i < text.endIndex,
                              !text[i].isWhitespace, !noSpaceBefore.contains(text[i]) {
                        out += " " // "เล่นกัน, แล้ว"
                    }
                } else {
                    out += c.phrase
                    i = text.index(i, offsetBy: c.phrase.count)
                }
                continue scan
            }
            out.append(text[i])
            i = text.index(after: i)
        }
        return out
    }

    /// จำนวนตัวอักษรท้ายข้อความที่อาจเป็นต้นคำสั่งที่ยังพูดไม่จบ (เช่น "เปิดวง") — ยังไม่ควรพิมพ์
    static func pendingSuffix(_ text: String) -> Int {
        guard Settings.voiceCommands else { return 0 }
        var best = 0
        for c in table where c.phrase != c.symbol {
            let p = Array(c.phrase)
            for len in stride(from: p.count - 1, through: 3, by: -1) where len > best {
                if text.hasSuffix(String(p[0..<len])) { best = len; break }
            }
        }
        return best
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
    private var isDone = false
    private var waiter: ((Transcript) -> Void)?
    /// partial result: (ข้อความทั้งหมด, ตำแหน่งท้ายคำที่ "นิ่ง" แล้ว [นับเป็น Character])
    var onPartial: ((String, [Int]) -> Void)?

    // Speech บนเครื่องเริ่มประโยคใหม่หลังเงียบ ~1.5 วิ — ผลหลังจากนั้น (รวมผลสุดท้าย) มีแค่ประโยคใหม่
    // จึงต้องสะสมประโยคที่จบแล้วไว้เอง
    private var closedText = ""            // ประโยคที่จบแล้ว ต่อกันด้วยช่องว่าง
    private var closedConfidences: [Float] = []
    private var openText = ""              // ประโยคปัจจุบัน
    private var openConfidences: [Float] = []
    private var openBoundaries: [Int] = []
    /// partial ล่าสุดมี timestamp (ระบบปิดประโยคแล้ว) — ยืนยันเมื่อผลถัดไปไม่ได้ต่อจากข้อความเดิม
    private var pendingClose = false

    /// ผลรวมทุกประโยค
    var transcript: Transcript {
        let all = (closedConfidences + openConfidences).filter { $0 > 0 }
        let conf = all.isEmpty ? 0 : Double(all.reduce(0, +)) / Double(all.count)
        return Transcript(localeID: localeID, text: RecognitionPass.join(closedText, openText), confidence: conf)
    }

    private struct Update {
        let text: String
        let boundaries: [Int]
        let confidences: [Float]
        let hasTimestamps: Bool
    }

    init?(localeID: String) {
        // ใช้เฉพาะโมเดลบนเครื่อง: ไม่ต้องต่อเน็ต และเสียงไม่ถูกส่งออกไป — ไม่มีโมเดล = ไม่ทำงาน (ไม่ fallback ไปเซิร์ฟเวอร์)
        guard let r = SFSpeechRecognizer(locale: Locale(identifier: localeID)),
              r.supportsOnDeviceRecognition else { return nil }
        self.localeID = localeID
        recognizer = r

        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        if #available(macOS 13.0, *) { request.addsPunctuation = Settings.autoPunctuation }

        task = r.recognitionTask(with: request) { [weak self] result, error in
            let update = result.map { res -> Update in
                let t = res.bestTranscription
                return Update(text: t.formattedString,
                              boundaries: RecognitionPass.wordBoundaries(t),
                              confidences: t.segments.map(\.confidence),
                              hasTimestamps: t.segments.contains { $0.duration > 0 })
            }
            let finished = (result?.isFinal ?? false) || error != nil
            if let error { NSLog("MacPTTT [\(localeID)]: \(error.localizedDescription)") }
            DispatchQueue.main.async {
                guard let self else { return }
                if let update, !self.isDone {
                    self.apply(update)
                    if self.waiter == nil { self.reportPartial() }
                }
                if finished { self.isDone = true; self.fire() }
            }
        }
    }

    private func apply(_ u: Update) {
        if u.text.isEmpty { return }
        if pendingClose && !u.text.hasPrefix(openText) {
            // ประโยคเดิมจบไปแล้ว นี่คือประโยคใหม่
            closedText = RecognitionPass.join(closedText, openText)
            closedConfidences += openConfidences
        }
        openText = u.text
        openConfidences = u.confidences
        openBoundaries = u.boundaries
        pendingClose = u.hasTimestamps
    }

    private func reportPartial() {
        guard let onPartial else { return }
        var boundaries: [Int] = []
        var offset = 0
        if !closedText.isEmpty {
            boundaries.append(closedText.count)
            offset = closedText.count + (openText.isEmpty ? 0 : 1)
            if !openText.isEmpty { boundaries.append(offset) }
        }
        boundaries += openBoundaries.map { $0 + offset }
        onPartial(RecognitionPass.join(closedText, openText), boundaries)
    }

    static func join(_ a: String, _ b: String) -> String {
        a.isEmpty ? b : b.isEmpty ? a : a + " " + b
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

    static func wordBoundaries(_ t: SFTranscription) -> [Int] {
        let s = t.formattedString as NSString
        return t.segments.dropLast().map { seg in
            let end = min(s.length, seg.substringRange.location + seg.substringRange.length)
            return s.substring(to: end).count
        }
    }

    private func fire() {
        guard let w = waiter else { return }
        waiter = nil
        task?.cancel()
        task = nil
        w(transcript)
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
    /// partial result ของการถอดสด (เรียกบน main thread)
    var onPartial: ((String, [Int]) -> Void)?

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
        live.onPartial = { [weak self] in self?.onPartial?($0, $1) }

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
                NSLog("MacPTTT: installTap failed: \(error)")
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
            NSLog("MacPTTT: audio engine start failed: \(error)")
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
            // confidence = 0 แปลว่าไม่รู้ (ได้ผลจาก timeout ไม่ใช่ผลสุดท้าย) — เปลี่ยนภาษาเฉพาะเมื่ออีกภาษามั่นใจสูงจริง
            let wins = !t.text.isEmpty && t.confidence > best.confidence
                && (best.confidence > 0 || t.confidence >= Config.autoAcceptConfidence)
            let better = (best.text.isEmpty || wins) ? t : best
            NSLog("MacPTTT auto: \(best.localeID)=\(best.confidence) \(t.localeID)=\(t.confidence) → \(better.localeID)")
            self.tryOthers(rest, best: better, audio: audio, session: s, completion)
        }
    }

    private func done(_ t: Transcript, _ completion: (String) -> Void) {
        pass = nil
        state = .idle
        if Settings.language == .auto, !t.text.isEmpty { Settings.lastDetected = t.localeID }
        completion(t.text)
    }

    /// ยกเลิกการอัดโดยไม่ส่งข้อความ (เช่น ปุ่มที่กดค้างเป็นส่วนหนึ่งของคีย์ลัด)
    func cancel() {
        guard state == .recording else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        session += 1
        cleanupFailedStart()
        state = .idle
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

// MARK: - Live typing (พิมพ์ขณะพูด)

protocol TextOutput {
    func type(_ text: String)
    func deleteBackward(_ count: Int)
}

/// พิมพ์เฉพาะส่วนที่ "นิ่งแล้ว" ของ partial result:
/// ต้องตรงกับ partial ครั้งก่อน และตัดที่ขอบคำโดยเว้นคำสุดท้าย (ซึ่งยังมักถูกแก้)
/// ถ้าหยุดพูดนานพอ จะพิมพ์คำสุดท้ายด้วย · ตอนจบเทียบกับผลสุดท้ายแล้วแก้เฉพาะส่วนที่ต่าง
final class LiveTyper {
    static let pauseCommitDelay: TimeInterval = 0.8

    private let output: TextOutput
    private(set) var typed = ""
    private var previous = ""
    private var pauseWork: DispatchWorkItem?

    init(output: TextOutput) { self.output = output }

    func update(text: String, boundaries: [Int]) {
        defer { previous = text }
        pauseWork?.cancel()
        let agree = LiveTyper.commonPrefixCount(previous, text)
        if let cut = boundaries.last(where: { $0 <= agree }), cut > 0 {
            var stable = String(text.prefix(cut))
            // ท้ายข้อความอาจเป็นคำสั่งเสียงที่ยังพูดไม่จบ (เช่น "เปิดวง…") — รอก่อน
            stable.removeLast(VoiceCommands.pendingSuffix(stable))
            commit(VoiceCommands.apply(stable))
        }
        let work = DispatchWorkItem { [weak self] in self?.commit(VoiceCommands.apply(text)) }
        pauseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + LiveTyper.pauseCommitDelay, execute: work)
    }

    /// แก้ส่วนท้ายระหว่างพูดได้ไม่เกินกี่ตัวอักษร (เช่น "ขึ้น" → "ขึ้นบรรทัด" = ขึ้นบรรทัดใหม่)
    static let maxLiveCorrection = 12

    /// พิมพ์ส่วนที่เพิ่ม — ถ้าท้ายที่พิมพ์ไปแล้วไม่ตรง (สั้นๆ) ลบแล้วพิมพ์ใหม่ ไม่ต้องรอปล่อยปุ่ม
    private func commit(_ stable: String) {
        let keep = LiveTyper.commonPrefixCount(typed, stable)
        guard stable.count > keep else { return }
        let wrong = typed.count - keep
        if wrong > 0 {
            guard wrong <= LiveTyper.maxLiveCorrection else { return } // ต่างมาก — รอผลสุดท้าย
            output.deleteBackward(String(typed.dropFirst(keep)).unicodeScalars.count)
        }
        output.type(String(stable.dropFirst(keep)))
        typed = stable
    }

    func finish(_ final: String) {
        pauseWork?.cancel()
        pauseWork = nil
        // ผลสุดท้ายว่าง (เช่น error/timeout) — เก็บสิ่งที่พิมพ์ไว้ ไม่ลบทิ้ง
        guard !final.isEmpty else { return }
        let keep = LiveTyper.commonPrefixCount(typed, final)
        // Backspace ใน macOS (และเบราว์เซอร์) ลบภาษาไทยทีละ Unicode scalar — สระ/วรรณยุกต์ทีละตัว
        // จึงต้องนับเป็น scalar ไม่ใช่ Character
        let extra = String(typed.dropFirst(keep)).unicodeScalars.count
        if extra > 0 { output.deleteBackward(extra) }
        let rest = String(final.dropFirst(keep))
        if !rest.isEmpty { output.type(rest) }
        typed = final
    }

    func cancel() { pauseWork?.cancel(); pauseWork = nil }

    static func commonPrefixCount(_ a: String, _ b: String) -> Int {
        var n = 0
        for (x, y) in zip(a, b) { guard x == y else { break }; n += 1 }
        return n
    }
}

/// ติดป้ายให้ keyboard event ที่แอปสร้างเอง เพื่อไม่ให้ตัวตรวจ "กดปุ่มอื่นระหว่างพูด" นับรวม
enum SyntheticEvent {
    private static let marker: Int64 = 0x4D50_5454 // "MPTT"
    static func mark(_ e: CGEvent?) { e?.setIntegerValueField(.eventSourceUserData, value: marker) }
    static func isOurs(_ e: NSEvent) -> Bool { e.cgEvent?.getIntegerValueField(.eventSourceUserData) == marker }
}

/// พิมพ์ด้วย keyboard event แบบ Unicode (ไม่ผ่าน clipboard, ไม่ขึ้นกับ layout ที่ใช้อยู่)
struct KeyboardOutput: TextOutput {
    private let source = CGEventSource(stateID: .privateState)

    func type(_ text: String) {
        var chunk: [UniChar] = []
        func flush() {
            guard !chunk.isEmpty else { return }
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                e.flags = [] // กันไม่ให้ปุ่ม modifier ที่กดค้าง (เช่น ⌥) ไปเปลี่ยนตัวอักษร
                e.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                SyntheticEvent.mark(e)
                e.post(tap: .cghidEventTap)
            }
            chunk.removeAll()
        }
        for ch in text { // ไม่ตัดกลาง Character
            let u = Array(String(ch).utf16)
            if chunk.count + u.count > 16 { flush() }
            chunk += u
        }
        flush()
    }

    func deleteBackward(_ count: Int) {
        for _ in 0..<count {
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: down)
                e?.flags = []
                SyntheticEvent.mark(e)
                e?.post(tap: .cghidEventTap)
            }
        }
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
        SyntheticEvent.mark(down)
        SyntheticEvent.mark(up)
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

// MARK: - Menu bar icon (ฟองคำพูด: คลื่นเสียง → บรรทัดข้อความ เหมือนไอคอนแอป)

enum MenuBarIcon {
    case idle, listening, processing, unavailable

    var image: NSImage? {
        switch self {
        case .idle: return MenuBarIcon.bubble(filled: false)
        case .listening: return MenuBarIcon.bubble(filled: true)
        case .processing: return MenuBarIcon.symbol("ellipsis.bubble")
        case .unavailable: return MenuBarIcon.symbol("exclamationmark.bubble")
        }
    }

    private static func symbol(_ name: String) -> NSImage? {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "MacPTTT")
        img?.isTemplate = true
        return img
    }

    private static func bubble(filled: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let ctx = NSGraphicsContext.current!
            NSColor.black.setFill()
            // ฟอง + หาง
            let outer = NSBezierPath(roundedRect: NSRect(x: 1, y: 4.5, width: 16, height: 11.5), xRadius: 4, yRadius: 4)
            let tail = NSBezierPath()
            tail.move(to: NSPoint(x: 3.5, y: 5))
            tail.line(to: NSPoint(x: 2.5, y: 1.5))
            tail.line(to: NSPoint(x: 7.5, y: 5))
            tail.close()
            outer.append(tail)
            outer.fill()
            ctx.compositingOperation = .destinationOut
            if !filled {
                NSBezierPath(roundedRect: NSRect(x: 2.4, y: 5.9, width: 13.2, height: 8.7), xRadius: 2.8, yRadius: 2.8).fill()
                ctx.compositingOperation = .sourceOver
            }
            // คลื่นเสียง (ซ้าย) + บรรทัดข้อความ (ขวา): สีดำบนฟองโปร่ง / เจาะทะลุบนฟองทึบ
            let midY: CGFloat = 10.25
            for (i, h) in [CGFloat(2.6), 5.4, 3.6].enumerated() {
                let x = 4.2 + CGFloat(i) * 2.0
                NSBezierPath(roundedRect: NSRect(x: x, y: midY - h / 2, width: 1.25, height: h), xRadius: 0.6, yRadius: 0.6).fill()
            }
            for (i, w) in [CGFloat(4.2), 3.4, 2.4].enumerated() {
                let y = midY + 1.9 - CGFloat(i) * 1.9 - 0.6
                NSBezierPath(roundedRect: NSRect(x: 10.8, y: y, width: w, height: 1.2), xRadius: 0.6, yRadius: 0.6).fill()
            }
            ctx.compositingOperation = .sourceOver
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "MacPTTT"
        return img
    }
}

// MARK: - Launch at login

enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("MacPTTT: login item \(enabled ? "register" : "unregister") failed: \(error)")
        }
    }

    /// เปิดเมื่อ login เป็นค่าเริ่มต้น — ตั้งให้ครั้งแรกที่เปิดจาก /Applications ครั้งเดียว ต่อจากนั้นตามที่ผู้ใช้เลือก
    static func setUpOnFirstLaunch() {
        guard !Settings.didSetUpLoginItem, Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        Settings.didSetUpLoginItem = true
        set(true)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let dictator = Dictator()
    private let overlay = WaveformOverlay()
    private var monitors: [Any] = []

    /// สถานะปุ่มที่กดค้าง
    private var keyIsDown = false
    private var pressedAt = Date.distantPast
    /// ถูกยกเลิกเพราะกดปุ่มอื่นร่วม — ไม่ต้องทำอะไรตอนปล่อย
    private var cancelled = false
    private var pressToken = 0
    private var typer: LiveTyper?

    private let hintItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let statusMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let modelItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let hotkeyMenu = NSMenu()
    private let languageMenu = NSMenu()
    private let punctuationMenu = NSMenu()
    private let liveItem = NSMenuItem(title: "Type While Speaking", action: nil, keyEquivalent: "")
    private let autoPunctItem = NSMenuItem(title: "Automatic Punctuation", action: nil, keyEquivalent: "")
    private let voiceCmdItem = NSMenuItem(title: "Thai Voice Commands", action: nil, keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Launch at Login", action: nil, keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setIcon(.idle)
        dictator.onLevels = { [weak self] in self?.overlay.push($0) }
        dictator.onPartial = { [weak self] in self?.typer?.update(text: $0, boundaries: $1) }
        buildMenu()
        LoginItem.setUpOnFirstLaunch()
        requestPermissions()
        installHotkey()
        updateStatus()
    }

    func menuWillOpen(_ menu: NSMenu) { updateStatus() }

    // MARK: Menu

    private func item(_ title: String, _ action: Selector, _ represented: Any? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        i.representedObject = represented
        return i
    }

    private func header(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) { return .sectionHeader(title: title) }
        return NSMenuItem(title: title, action: nil, keyEquivalent: "")
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(hintItem)
        menu.addItem(statusMenuItem)
        modelItem.target = self
        modelItem.action = #selector(openDictationSettings)
        menu.addItem(modelItem)
        menu.addItem(.separator())

        hotkeyMenu.addItem(header("Left Hand"))
        for hk in Hotkey.left { hotkeyMenu.addItem(item(hk.title, #selector(selectHotkey(_:)), hk.id)) }
        hotkeyMenu.addItem(.separator())
        hotkeyMenu.addItem(header("Right Hand"))
        for hk in Hotkey.right { hotkeyMenu.addItem(item(hk.title, #selector(selectHotkey(_:)), hk.id)) }
        let hotkeyItem = NSMenuItem(title: "Push-to-Talk Key", action: nil, keyEquivalent: "")
        hotkeyItem.submenu = hotkeyMenu
        menu.addItem(hotkeyItem)

        for mode in LanguageMode.allCases {
            languageMenu.addItem(item(mode.title, #selector(selectLanguage(_:)), mode.rawValue))
            if mode == .auto { languageMenu.addItem(.separator()) }
        }
        let languageItem = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)

        autoPunctItem.target = self
        autoPunctItem.action = #selector(toggleAutoPunctuation)
        voiceCmdItem.target = self
        voiceCmdItem.action = #selector(toggleVoiceCommands)
        punctuationMenu.addItem(autoPunctItem)
        punctuationMenu.addItem(voiceCmdItem)
        punctuationMenu.addItem(.separator())
        punctuationMenu.addItem(item("Show Voice Commands…", #selector(showVoiceCommands)))
        let punctItem = NSMenuItem(title: "Punctuation", action: nil, keyEquivalent: "")
        punctItem.submenu = punctuationMenu
        menu.addItem(punctItem)

        liveItem.target = self
        liveItem.action = #selector(toggleLiveTyping)
        menu.addItem(liveItem)
        menu.addItem(.separator())

        loginItem.target = self
        loginItem.action = #selector(toggleLogin)
        menu.addItem(loginItem)
        menu.addItem(item("Open Accessibility Settings…", #selector(openAccessibility)))
        menu.addItem(item("Open Microphone Settings…", #selector(openMicrophone)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit MacPTTT", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func toggleLiveTyping() { Settings.typeWhileSpeaking.toggle(); updateStatus() }
    @objc private func toggleAutoPunctuation() { Settings.autoPunctuation.toggle(); updateStatus() }
    @objc private func toggleVoiceCommands() { Settings.voiceCommands.toggle(); updateStatus() }

    @objc private func toggleLogin() {
        switch LoginItem.status {
        case .enabled: LoginItem.set(false)
        case .requiresApproval: SMAppService.openSystemSettingsLoginItems()
        default: LoginItem.set(true)
        }
        Settings.didSetUpLoginItem = true
        updateStatus()
    }

    @objc private func showVoiceCommands() {
        let thai = VoiceCommands.table.filter { !$0.label.isEmpty }
            .map { "\($0.phrase)  →  \($0.label)" }
            .joined(separator: "\n")
        let alert = NSAlert()
        alert.messageText = "Voice Commands"
        alert.informativeText = """
        Thai (say the word while dictating):
        \(thai)

        English is handled by macOS: say "comma", "period", "question mark", \
        "exclamation point", "colon", "semicolon", "open/close parenthesis", \
        "new line", "new paragraph".
        """
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
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

    // MARK: Permissions & status

    private func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { _ in
            DispatchQueue.main.async { self.updateStatus() }
        }
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            DispatchQueue.main.async { self.updateStatus() }
        }
        // ต้องมี Accessibility เพื่อฟังปุ่มแบบ global และพิมพ์/วางข้อความ
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    private func updateStatus() {
        let hk = Settings.hotkey
        let lang = Settings.language
        hintItem.title = "Hold \(hk.title) to dictate"

        for item in hotkeyMenu.items where item.representedObject != nil {
            item.state = (item.representedObject as? String) == hk.id ? .on : .off
        }
        for item in languageMenu.items { item.state = (item.representedObject as? String) == lang.rawValue ? .on : .off }
        if let autoItem = languageMenu.items.first(where: { ($0.representedObject as? String) == LanguageMode.auto.rawValue }) {
            autoItem.title = LanguageMode.auto.title
                + (Settings.lastDetected.map { " — last: \(LanguageMode.name(of: $0))" } ?? "")
        }
        liveItem.state = Settings.typeWhileSpeaking ? .on : .off
        autoPunctItem.state = Settings.autoPunctuation ? .on : .off
        voiceCmdItem.state = Settings.voiceCommands ? .on : .off

        switch LoginItem.status {
        case .enabled: loginItem.state = .on; loginItem.title = "Launch at Login"
        case .requiresApproval: loginItem.state = .mixed; loginItem.title = "Launch at Login (approve in Settings…)"
        default: loginItem.state = .off; loginItem.title = "Launch at Login"
        }

        let speechOK = SFSpeechRecognizer.authorizationStatus() == .authorized
        let micOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let axOK = AXIsProcessTrusted()
        func mark(_ b: Bool) -> String { b ? "✓" : "✗" }
        statusMenuItem.title = "Offline · Mic \(mark(micOK)) · Speech \(mark(speechOK)) · Accessibility \(mark(axOK))"

        let missing = OnDevice.missing
        modelItem.isHidden = missing.isEmpty
        modelItem.title = "⚠︎ No on-device model for \(missing.map(LanguageMode.name(of:)).joined(separator: ", ")) — Open Dictation Settings…"
        if dictator.state == .idle { setIcon(Settings.candidates.isEmpty ? .unavailable : .idle) }
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openMicrophone() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

    @objc private func openDictationSettings() {
        // Keyboard → Dictation: เพิ่มภาษาเพื่อให้ macOS ดาวน์โหลดโมเดลบนเครื่อง
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
    }

    // MARK: Hotkey

    private func installHotkey() {
        let flags: (NSEvent) -> Void = { [weak self] in self?.handleFlags($0) }
        let keys: (NSEvent) -> Void = { [weak self] e in
            if !SyntheticEvent.isOurs(e) { self?.otherKeyPressed() }
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { flags($0); return $0 }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: keys) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { keys($0); return $0 }) { monitors.append(m) }
    }

    private func handleFlags(_ e: NSEvent) {
        let hk = Settings.hotkey
        guard e.keyCode == hk.keyCode else {
            if keyIsDown { otherKeyPressed() } // กด modifier อื่นร่วม เช่น ⌥⇧
            return
        }
        let down = e.modifierFlags.rawValue & hk.mask != 0
        if down && !keyIsDown {
            keyIsDown = true
            begin()
        } else if !down && keyIsDown {
            keyIsDown = false
            end()
        }
    }

    /// กดปุ่มอื่นขณะกดปุ่มพูดค้าง = ใช้เป็นคีย์ลัด (เช่น ⌥←, ⌘C) → ยกเลิก
    /// ยกเลิกเฉพาะช่วงแรกและยังไม่ได้พิมพ์อะไร เพื่อไม่ให้การกดพลาดระหว่างพูดยาวทำให้ข้อความหาย
    private func otherKeyPressed() {
        guard keyIsDown, !cancelled, dictator.state == .recording,
              Date().timeIntervalSince(pressedAt) < 1.0, typer?.typed.isEmpty ?? true else { return }
        cancelled = true
        dictator.cancel()
        typer?.cancel()
        typer = nil
        overlay.hide()
        setIcon(.idle)
    }

    // MARK: Push-to-talk

    private func begin() {
        cancelled = false
        pressedAt = Date()
        pressToken += 1
        typer = Settings.typeWhileSpeaking ? LiveTyper(output: KeyboardOutput()) : nil
        if dictator.start() {
            // แสดงผลหลังกดค้างครู่หนึ่ง — ไม่กะพริบตอนใช้ปุ่มเป็นคีย์ลัด
            let token = pressToken
            DispatchQueue.main.asyncAfter(deadline: .now() + Config.overlayDelay) { [weak self] in
                guard let self, token == self.pressToken, self.keyIsDown, !self.cancelled,
                      self.dictator.state == .recording else { return }
                self.setIcon(.listening)
                self.overlay.show()
            }
        } else {
            typer = nil
            setIcon(.unavailable)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                if self?.dictator.state == .idle { self?.updateStatus() }
            }
        }
    }

    private func end() {
        overlay.hide()
        guard !cancelled, dictator.state == .recording else { return }
        setIcon(.processing)
        dictator.stop { [weak self] text in
            guard let self else { return }
            self.setIcon(.idle)
            self.updateStatus()
            let final = VoiceCommands.apply(text.trimmingCharacters(in: .whitespacesAndNewlines))
            if let typer = self.typer {
                // แก้ส่วนท้ายที่ต่างจากผลสุดท้าย (หรือแทนทั้งหมดถ้าโหมดอัตโนมัติเปลี่ยนภาษา)
                typer.finish(final)
                self.typer = nil
            } else {
                Inserter.insert(final)
            }
        }
    }

    private func setIcon(_ icon: MenuBarIcon) {
        statusItem.button?.image = icon.image
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // ไอคอนบน menu bar เท่านั้น ไม่มีใน Dock
app.run()
