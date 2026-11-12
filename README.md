# ThaiPTT

Push-to-talk dictation บน macOS (ไทย / อังกฤษ) ใช้ Speech framework (`SFSpeechRecognizer`) ที่มากับระบบ ไม่มีเสียง feedback

## ใช้งาน
กดปุ่ม push-to-talk ค้างไว้ (ค่าเริ่มต้น **⌥ Option ขวา**) → พูด → ปล่อย → ข้อความถูกวางที่เคอร์เซอร์ในแอปที่ใช้อยู่
ขณะกดค้าง จะมีแถบคลื่นเสียงจากไมค์ขึ้นด้านล่างกลางจอที่เมาส์อยู่

ไอคอนบน menu bar: 🎙 พร้อม · 🎙(ทึบ) กำลังฟัง · ⋯ กำลังประมวลผล · 🎙/ เริ่มไม่ได้

## เมนู
- **Push-to-Talk Key** — Right Option / Left Option / Right Command / Right Control / Right Shift / Fn (Globe)
  ถ้าใช้ Fn ให้ตั้ง System Settings → Keyboard → "Press 🌐 key to" เป็น "Do Nothing"
- **Language**
  - **Automatic (Thai / English)** — ถอดสดด้วยภาษาที่ตรวจพบล่าสุด ถ้า confidence < 0.6 จะถอดเสียงเดิมซ้ำด้วยอีกภาษาแล้วเลือกผลที่ดีกว่า
    (Speech บนเครื่องรันสองภาษาพร้อมกันไม่ได้ จึงต้องทำทีละรอบ — เมื่อสลับภาษาจะช้าขึ้นเล็กน้อย)
  - **Thai** / **English (US)** — บังคับภาษาเดียว

## Build
```bash
xcode-select --install     # ถ้ายังไม่มี
./build.sh --install       # build + ติดตั้งลง /Applications + เปิดแอป
```

## สิทธิ์ที่ต้องให้ (ครั้งแรก)
1. Microphone และ Speech Recognition — จะมี dialog ถามเอง
2. Accessibility — System Settings → Privacy & Security → Accessibility → เปิด ThaiPTT
3. **ปิดแล้วเปิดแอปใหม่** หลังให้ Accessibility (global key monitor จะเริ่มทำงานหลังรีสตาร์ท)

> แอปเซ็นแบบ ad-hoc ทุกครั้งที่ build ใหม่ macOS จะมองเป็นแอปใหม่ ต้องลบ ThaiPTT ออกจากรายการ Accessibility แล้วเพิ่มใหม่

## On-device vs Apple servers
บรรทัดสถานะในเมนูบอกว่าใช้โมเดลบนเครื่อง ("On-device") หรือส่งเสียงไปเซิร์ฟเวอร์ Apple ("Apple servers")
ถ้าขึ้น Apple servers ลองเพิ่มภาษาใน System Settings → Keyboard → Dictation เพื่อให้ macOS ดาวน์โหลดโมเดล

## ปรับแต่ง (`Sources/main.swift` → `Config`)
- `autoAcceptConfidence` — เกณฑ์ที่โหมด Automatic ยอมรับภาษาแรกโดยไม่ลองภาษาอื่น
- `addsPunctuation` — เติมวรรคตอนอัตโนมัติ
- `finalResultTimeout` — เวลารอผลสุดท้ายหลังปล่อยปุ่ม
