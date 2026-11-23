// Draws the app icon (a knight on a dark rounded square) to the PNG path given.
import AppKit

let out = CommandLine.arguments[1]
let size: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let inset: CGFloat = 100   // Apple's icon grid leaves a margin around the squircle
let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let shape = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(calibratedRed: 0.20, green: 0.19, blue: 0.17, alpha: 1),
           ending: NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.08, alpha: 1))!
    .draw(in: shape, angle: -90)

let para = NSMutableParagraphStyle()
para.alignment = .center
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 600),
    .foregroundColor: NSColor.white,
    .paragraphStyle: para,
]
let knight = NSAttributedString(string: "♞", attributes: attrs)
let h = knight.size().height
knight.draw(in: NSRect(x: rect.minX, y: rect.midY - h / 2 + 10, width: rect.width, height: h))

// Small amber dot: the clock tint.
NSColor(calibratedRed: 1, green: 0.69, blue: 0.13, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: rect.maxX - 230, y: rect.maxY - 230, width: 110, height: 110)).fill()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
