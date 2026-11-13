// สร้างไอคอนแอป MacPTTT → Resources/AppIcon.icns
// รัน: swift Tools/make-icon.swift   (ต้องมี iconutil ซึ่งมากับ macOS)
// ดีไซน์: พื้นไล่สี indigo → teal, ฟองคำพูดสีขาว ข้างในมีคลื่นเสียง (พูด) ต่อด้วยบรรทัดข้อความ (เป็นตัวอักษร)

import AppKit

func drawIcon(size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        let s = size / 1024
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
            NSRect(x: x * s, y: y * s, width: w * s, height: h * s)
        }

        // พื้นหลัง: สี่เหลี่ยมมุมมนแบบไอคอน macOS (824×824 กลาง canvas 1024)
        let bg = NSBezierPath(roundedRect: r(100, 100, 824, 824), xRadius: 185 * s, yRadius: 185 * s)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
        shadow.shadowBlurRadius = 24 * s
        shadow.set()
        NSColor.black.setFill()
        bg.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(colors: [NSColor(srgbRed: 0.36, green: 0.33, blue: 0.96, alpha: 1),
                            NSColor(srgbRed: 0.09, green: 0.71, blue: 0.79, alpha: 1)])!
            .draw(in: bg, angle: -50)

        // ฟองคำพูดสีขาว พร้อมหางด้านล่างซ้าย
        let bubble = NSBezierPath(roundedRect: r(196, 330, 632, 440), xRadius: 120 * s, yRadius: 120 * s)
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: 300 * s, y: 350 * s))
        tail.line(to: NSPoint(x: 250 * s, y: 225 * s))
        tail.line(to: NSPoint(x: 420 * s, y: 340 * s))
        tail.close()
        bubble.append(tail)
        NSGraphicsContext.saveGraphicsState()
        let bs = NSShadow()
        bs.shadowColor = NSColor.black.withAlphaComponent(0.18)
        bs.shadowOffset = NSSize(width: 0, height: -8 * s)
        bs.shadowBlurRadius = 18 * s
        bs.set()
        NSColor.white.setFill()
        bubble.fill()
        NSGraphicsContext.restoreGraphicsState()

        // คลื่นเสียง (ซ้าย)
        let ink = NSColor(srgbRed: 0.30, green: 0.32, blue: 0.90, alpha: 1)
        ink.setFill()
        let midY: CGFloat = 550
        let bars: [CGFloat] = [90, 190, 280, 170, 110]
        for (i, h) in bars.enumerated() {
            let x = 272 + CGFloat(i) * 52
            NSBezierPath(roundedRect: r(x, midY - h / 2, 32, h), xRadius: 16 * s, yRadius: 16 * s).fill()
        }

        // บรรทัดข้อความ (ขวา)
        NSColor(srgbRed: 0.09, green: 0.62, blue: 0.72, alpha: 1).setFill()
        let lines: [CGFloat] = [200, 170, 120]
        for (i, w) in lines.enumerated() {
            let y = midY + 70 - CGFloat(i) * 70 - 17
            NSBezierPath(roundedRect: r(560, y, w, 34), xRadius: 17 * s, yRadius: 17 * s).fill()
        }
        return true
    }
}

func png(_ image: NSImage, pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! png(drawIcon(size: CGFloat(px)), pixels: px).write(to: iconset.appendingPathComponent(name))
    }
}
let out = root.appendingPathComponent("Resources/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try! p.run()
p.waitUntilExit()
try! png(drawIcon(size: 1024), pixels: 1024).write(to: root.appendingPathComponent("Resources/AppIcon-1024.png"))
print(p.terminationStatus == 0 ? "Wrote \(out.path)" : "iconutil failed")
