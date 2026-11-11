// Draws the app icon layers as 1024 px PNGs: swift scripts/draw-icon.swift <output-dir> [preview.png]
import AppKit

let size: CGFloat = 1024
let out = URL(fileURLWithPath: CommandLine.arguments[1])

func render(_ name: String, _ draw: (CGContext) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Top-left origin, like the design coordinates below.
    ctx.translateBy(x: 0, y: size); ctx.scaleBy(x: 1, y: -1)
    draw(ctx)
    let image = ctx.makeImage()!
    if !name.isEmpty {
        let rep = NSBitmapImageRep(cgImage: image)
        try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
    }
    return image
}
func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

// The pad seen from above: a dark belt between two rails, with slats.
let beltRect = CGRect(x: 322, y: 132, width: 380, height: 760)
let belt = render("belt.png") { ctx in
    let body = CGPath(roundedRect: beltRect, cornerWidth: 84, cornerHeight: 84, transform: nil)
    ctx.addPath(body); ctx.setFillColor(color(0x3A4048)); ctx.fillPath()
    let inner = beltRect.insetBy(dx: 30, dy: 44)
    ctx.addPath(CGPath(roundedRect: inner, cornerWidth: 56, cornerHeight: 56, transform: nil))
    ctx.setFillColor(color(0x23272D)); ctx.fillPath()
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: inner, cornerWidth: 56, cornerHeight: 56, transform: nil)); ctx.clip()
    ctx.setFillColor(color(0xFFFFFF, 0.07))
    var y = inner.minY + 26
    while y < inner.maxY { ctx.fill(CGRect(x: inner.minX, y: y, width: inner.width, height: 10)); y += 58 }
    ctx.restoreGState()
}

// Two shoe prints walking up the belt.
func shoePrint(_ ctx: CGContext, center: CGPoint, angle: CGFloat, mirror: Bool) {
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y); ctx.rotate(by: angle * .pi / 180)
    if mirror { ctx.scaleBy(x: -1, y: 1) }
    // Forefoot, slightly wider toward the big toe, then the heel.
    let fore = CGMutablePath()
    fore.move(to: CGPoint(x: 0, y: -150))
    fore.addCurve(to: CGPoint(x: 56, y: -40), control1: CGPoint(x: 48, y: -150), control2: CGPoint(x: 62, y: -96))
    fore.addCurve(to: CGPoint(x: 30, y: 26), control1: CGPoint(x: 52, y: -6), control2: CGPoint(x: 42, y: 16))
    fore.addCurve(to: CGPoint(x: -34, y: 22), control1: CGPoint(x: 10, y: 42), control2: CGPoint(x: -20, y: 40))
    fore.addCurve(to: CGPoint(x: -44, y: -70), control1: CGPoint(x: -50, y: 0), control2: CGPoint(x: -50, y: -40))
    fore.addCurve(to: CGPoint(x: 0, y: -150), control1: CGPoint(x: -38, y: -112), control2: CGPoint(x: -36, y: -150))
    fore.closeSubpath()
    ctx.addPath(fore)
    ctx.addEllipse(in: CGRect(x: -36, y: 50, width: 70, height: 96))
    ctx.setFillColor(color(0xFFFFFF)); ctx.fillPath()
    ctx.restoreGState()
}
let prints = render("prints.png") { ctx in
    shoePrint(ctx, center: CGPoint(x: 448, y: 640), angle: -6, mirror: true)
    shoePrint(ctx, center: CGPoint(x: 578, y: 392), angle: 6, mirror: false)
}

// Preview with the background and a squircle-ish mask, for review only.
if CommandLine.arguments.count > 2 {
    let preview = render("") { ctx in
        ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: size, height: size), cornerWidth: 230, cornerHeight: 230, transform: nil))
        ctx.clip()
        let gradient = CGGradient(colorsSpace: nil, colors: [color(0x5AD98A), color(0x17964B)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size), options: [])
        ctx.translateBy(x: 0, y: size); ctx.scaleBy(x: 1, y: -1)
        ctx.draw(belt, in: CGRect(x: 0, y: 0, width: size, height: size))
        ctx.draw(prints, in: CGRect(x: 0, y: 0, width: size, height: size))
    }
    let rep = NSBitmapImageRep(cgImage: preview)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
}
