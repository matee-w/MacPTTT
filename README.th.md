# MacPTTT — Mac Push Talk to Text

[English](README.md) · **ภาษาไทย**

Push-to-talk dictation บน menu bar ของ macOS รองรับภาษาไทยและอังกฤษ กดปุ่มค้างแล้วพูด ข้อความจะถูกพิมพ์ที่เคอร์เซอร์ในแอปที่ใช้อยู่ไปพร้อมกับที่พูด ใช้ Speech framework (`SFSpeechRecognizer`) ที่มากับระบบ ไม่มีเสียง feedback ตอนเริ่มหรือจบ

## ความสามารถ
- **Push-to-talk** เลือกปุ่มได้เอง (ค่าเริ่มต้นคือ Option ขวา)
- **พิมพ์ขณะพูด** ทีละคำ แล้วแก้ส่วนท้ายให้ตรงกับผลสุดท้ายเมื่อปล่อยปุ่ม
- **คลื่นเสียง** จากไมค์ขึ้นด้านล่างกลางจอขณะพูด
- **เลือกภาษาอัตโนมัติ** ระหว่างไทยกับอังกฤษ หรือบังคับภาษาเดียว
- **ถอดความบนเครื่อง** ถ้าเครื่องรองรับ เสียงจะไม่ถูกส่งออกไปนอกเครื่อง
- คืนค่า clipboard เดิมหลังวางข้อความ

## ติดตั้ง
1. ดาวน์โหลด **MacPTTT-x.y.dmg** จาก [Releases](https://github.com/matee-w/MacPTTT/releases/latest) เปิดไฟล์แล้วลาก **MacPTTT** ไปที่ Applications
2. แอปไม่ได้ notarize กับ Apple เปิดครั้งแรก macOS จะบล็อก ให้ไปที่ **System Settings → Privacy & Security** แล้วกด **Open Anyway** หรือรันคำสั่ง:
   ```bash
   xattr -dr com.apple.quarantine /Applications/MacPTTT.app
   ```
3. ให้สิทธิ์ตามหัวข้อถัดไป

ต้องใช้ macOS 13 ขึ้นไป รองรับทั้ง Apple Silicon และ Intel

## สิทธิ์ที่ต้องให้ (ครั้งแรก)
1. **Microphone** และ **Speech Recognition** — จะมี dialog ถาม ให้กด Allow
2. **Accessibility** — System Settings → Privacy & Security → Accessibility → เปิด MacPTTT (ใช้ฟังปุ่มขณะอยู่ในแอปอื่น และพิมพ์หรือวางข้อความ)
3. **ปิดแล้วเปิดแอปใหม่** หลังให้ Accessibility เพราะตัวดักปุ่มเริ่มทำงานตอนเปิดแอปเท่านั้น

บรรทัดที่สองในเมนูบอกสถานะ เช่น `On-device · Mic ✓ · Speech ✓ · Accessibility ✓`

## ใช้งาน
กดปุ่ม push-to-talk ค้างไว้ → พูด (คำจะขึ้นที่เคอร์เซอร์หลังพูดราวครึ่งวินาที) → ปล่อย

ไอคอนบน menu bar: 🎙 พร้อม · 🎙(ทึบ) กำลังฟัง · ⋯ กำลังประมวลผล · 🎙/ เริ่มไม่ได้

## เมนู
- **Push-to-Talk Key** — Right Option / Left Option / Right Command / Right Control / Right Shift / Fn (Globe)
  ถ้าใช้ Fn ให้ตั้ง System Settings → Keyboard → "Press 🌐 key to" เป็น "Do Nothing"
- **Language**
  - **Automatic (Thai / English)** — ถอดสดด้วยภาษาที่ตรวจพบล่าสุด ถ้า confidence < 0.6 จะถอดเสียงเดิมซ้ำด้วยอีกภาษาแล้วเลือกผลที่ confidence สูงกว่า
    (Speech บนเครื่องรันสองภาษาพร้อมกันไม่ได้ จึงต้องทำทีละรอบ เมื่อสลับภาษาจะช้าขึ้นเล็กน้อย)
  - **Thai** / **English (US)** — บังคับภาษาเดียว
- **Type While Speaking** (เปิดเป็นค่าเริ่มต้น) — พิมพ์คำที่ระบบถอดความไม่แก้แล้ว และพิมพ์คำสุดท้ายเมื่อหยุดพูดครู่หนึ่ง ตอนปล่อยปุ่มจะเทียบกับผลสุดท้ายแล้วแก้เฉพาะส่วนที่ต่าง ถ้าปิด จะวางข้อความทั้งหมดทีเดียวตอนปล่อยปุ่ม (ผ่าน clipboard)

## On-device vs Apple servers
บรรทัดสถานะในเมนูบอกว่าใช้โมเดลบนเครื่อง ("On-device") หรือส่งเสียงไปเซิร์ฟเวอร์ Apple ("Apple servers")
ถ้าขึ้น Apple servers ให้เพิ่มภาษาใน System Settings → Keyboard → Dictation เพื่อให้ macOS ดาวน์โหลดโมเดล

## Build จากซอร์สโค้ด
ต้องมี Xcode หรือ Command Line Tools (`xcode-select --install`)

```bash
./build.sh             # build MacPTTT.app สำหรับเครื่องนี้
./build.sh --install   # build + ติดตั้งลง /Applications + เปิดแอป
./build.sh --dist      # build universal + สร้าง dist/MacPTTT-<version>.dmg
```

> แอปเซ็นแบบ ad-hoc ทุกครั้งที่ build ใหม่ macOS จะมองเป็นแอปใหม่ ต้องลบ MacPTTT ออกจากรายการ Accessibility แล้วเพิ่มใหม่

## ปรับแต่ง (`Sources/main.swift` → `Config`)
- `autoAcceptConfidence` — เกณฑ์ที่โหมด Automatic ยอมรับภาษาแรกโดยไม่ลองภาษาอื่น
- `addsPunctuation` — เติมวรรคตอนอัตโนมัติ
- `finalResultTimeout` — เวลารอผลสุดท้ายหลังปล่อยปุ่ม

## License
[MIT](LICENSE)
