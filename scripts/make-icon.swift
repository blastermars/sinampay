// Draws the Sinampay app icon: a sampayan against a Manila Bay sunset,
// strung with fiesta banderitas, holding a screenshot and a copied note
// with bright plastic sipit.
// Usage: swift scripts/make-icon.swift out.png
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "icon.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

func shadow(_ alpha: CGFloat, blur: CGFloat, y: CGFloat) {
    let s = NSShadow()
    s.shadowColor = color(40, 16, 30, alpha)
    s.shadowBlurRadius = blur
    s.shadowOffset = NSSize(width: 0, height: y)
    s.set()
}

let blue = color(0, 56, 168), red = color(206, 17, 38), yellow = color(252, 209, 22)
let green = color(30, 160, 95), pink = color(236, 72, 140), orange = color(250, 130, 30)
let banderitas = [red, yellow, blue, pink, green, orange]

// Body, following the macOS icon grid: 824pt square, 100pt margin.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

ctx.saveGState()
shadow(0.30, blur: 26, y: -12)
color(250, 170, 120).setFill()
shape.fill()
ctx.restoreGState()

ctx.saveGState()
shape.addClip()

// Manila Bay at golden hour: deep blue up high, warming to orange at the water.
NSGradient(colors: [color(40, 70, 170), color(150, 80, 170), color(245, 110, 110), color(255, 170, 80)],
           atLocations: [0, 0.38, 0.72, 1], colorSpace: .sRGB)!
    .draw(in: body, angle: -90)

// The sun, low and big, with a soft halo.
let sunCenter = NSPoint(x: 512, y: 300)
NSGradient(colors: [color(255, 230, 150, 0.75), color(255, 200, 120, 0)])!
    .draw(fromCenter: sunCenter, radius: 0, toCenter: sunCenter, radius: 330, options: [])
color(255, 222, 120).setFill()
NSBezierPath(ovalIn: NSRect(x: sunCenter.x - 140, y: sunCenter.y - 140, width: 280, height: 280)).fill()

// The bay: calm water with a few streaks of reflected light.
let water = NSRect(x: body.minX, y: body.minY, width: body.width, height: 230)
NSGradient(colors: [color(70, 60, 150), color(200, 90, 120)])!.draw(in: water, angle: 90)
color(255, 214, 140, 0.8).setFill()
for (i, w) in [CGFloat(220), 160, 110, 70].enumerated() {
    let y = water.maxY - 26 - CGFloat(i) * 34
    NSBezierPath(roundedRect: NSRect(x: 512 - w / 2, y: y, width: w, height: 9), xRadius: 4.5, yRadius: 4.5).fill()
}

// Soft light from the top.
NSGradient(colors: [color(255, 255, 255, 0.22), color(255, 255, 255, 0)])!
    .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)

// The line
let left = NSPoint(x: 60, y: 760), right = NSPoint(x: 964, y: 760)
let control = NSPoint(x: 512, y: 650)
func lineY(_ x: CGFloat) -> CGFloat {
    let t = (x - left.x) / (right.x - left.x)
    return (1 - t) * (1 - t) * left.y + 2 * (1 - t) * t * control.y + t * t * right.y
}
func linePath() -> NSBezierPath {
    let p = NSBezierPath()
    p.move(to: left)
    p.curve(to: right,
            controlPoint1: NSPoint(x: left.x + (control.x - left.x) * 2 / 3, y: left.y + (control.y - left.y) * 2 / 3),
            controlPoint2: NSPoint(x: right.x + (control.x - right.x) * 2 / 3, y: right.y + (control.y - right.y) * 2 / 3))
    return p
}

// Banderitas strung along the line, behind the cards.
for i in 0..<13 {
    let x = 120 + CGFloat(i) * 66
    let y = lineY(x)
    ctx.saveGState()
    ctx.translateBy(x: x, y: y)
    ctx.rotate(by: CGFloat((i * 37) % 11 - 5) * 0.9 * .pi / 180)
    let flag = NSBezierPath()
    flag.move(to: NSPoint(x: -24, y: 0))
    flag.line(to: NSPoint(x: 24, y: 0))
    flag.line(to: NSPoint(x: 0, y: -56))
    flag.close()
    shadow(0.25, blur: 6, y: -3)
    banderitas[i % banderitas.count].setFill()
    flag.fill()
    ctx.restoreGState()
}

ctx.saveGState()
shadow(0.30, blur: 8, y: -5)
let line = linePath()
line.lineWidth = 9
color(250, 240, 230).setStroke()
line.stroke()
ctx.restoreGState()

// A card in a glass frame, hanging from a plastic sipit.
func hang(centerX: CGFloat, width: CGFloat, height: CGFloat, angle: CGFloat, sipit: NSColor, content: (NSRect) -> Void) {
    let top = lineY(centerX) + 34
    ctx.saveGState()
    ctx.translateBy(x: centerX, y: top)
    ctx.rotate(by: angle * .pi / 180)

    let radius: CGFloat = 64, inset: CGFloat = 18
    let frame = NSRect(x: -width / 2, y: -height, width: width, height: height)
    let framePath = NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius)

    ctx.saveGState()
    shadow(0.35, blur: 40, y: -22)
    color(255, 255, 255, 0.55).setFill()
    framePath.fill()
    ctx.restoreGState()
    NSGradient(colors: [color(255, 255, 255, 0.35), color(255, 255, 255, 0.08)])!
        .draw(in: framePath, angle: -90)

    let photoRect = frame.insetBy(dx: inset, dy: inset)
    let photoPath = NSBezierPath(roundedRect: photoRect, xRadius: radius - inset, yRadius: radius - inset)
    ctx.saveGState()
    photoPath.addClip()
    content(photoRect)
    ctx.restoreGState()

    ctx.saveGState()
    let ring = NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius)
    ring.append(NSBezierPath(roundedRect: frame.insetBy(dx: 4, dy: 4), xRadius: radius - 4, yRadius: radius - 4))
    ring.windingRule = .evenOdd
    ring.addClip()
    NSGradient(colors: [color(255, 255, 255, 0.95), color(255, 255, 255, 0.35)])!.draw(in: frame, angle: -90)
    ctx.restoreGState()

    // The sipit: glossy plastic with a steel spring across the middle.
    let clip = NSRect(x: -17, y: -58, width: 34, height: 92)
    let clipPath = NSBezierPath(roundedRect: clip, xRadius: 12, yRadius: 12)
    ctx.saveGState()
    shadow(0.4, blur: 8, y: -5)
    sipit.setFill()
    clipPath.fill()
    ctx.restoreGState()
    func shade(_ c: NSColor, _ k: CGFloat) -> NSColor {
        let s = c.usingColorSpace(.sRGB)!
        return NSColor(srgbRed: min(1, s.redComponent * k), green: min(1, s.greenComponent * k),
                       blue: min(1, s.blueComponent * k), alpha: 1)
    }
    NSGradient(colors: [shade(sipit, 0.75), shade(sipit, 1.25), sipit, shade(sipit, 0.65)],
               atLocations: [0, 0.32, 0.62, 1], colorSpace: .sRGB)!
        .draw(in: clipPath, angle: 0)
    NSGradient(colors: [color(140, 140, 150), color(245, 245, 250), color(150, 150, 160)])!
        .draw(in: NSBezierPath(roundedRect: NSRect(x: -22, y: -30, width: 44, height: 11), xRadius: 3, yRadius: 3), angle: 0)
    color(40, 20, 20, 0.4).setFill()
    NSBezierPath(roundedRect: NSRect(x: -9, y: -6, width: 18, height: 5), xRadius: 2.5, yRadius: 2.5).fill()
    clipPath.lineWidth = 2
    color(255, 255, 255, 0.55).setStroke()
    clipPath.stroke()

    ctx.restoreGState()
}

// Left: a screenshot of a small app window.
hang(centerX: 330, width: 340, height: 380, angle: 3, sipit: blue) { r in
    color(248, 249, 252).setFill(); r.fill()
    let bar = NSRect(x: r.minX, y: r.maxY - 56, width: r.width, height: 56)
    color(232, 234, 240).setFill(); bar.fill()
    for (i, c) in [color(255, 95, 87), color(254, 188, 46), color(40, 200, 64)].enumerated() {
        c.setFill()
        NSBezierPath(ovalIn: NSRect(x: r.minX + 26 + CGFloat(i) * 30, y: bar.midY - 9, width: 18, height: 18)).fill()
    }
    red.setFill()
    NSBezierPath(roundedRect: NSRect(x: r.minX + 26, y: bar.minY - 70, width: r.width * 0.55, height: 26), xRadius: 8, yRadius: 8).fill()
    color(200, 204, 216).setFill()
    for i in 0..<5 {
        let w = r.width * [0.78, 0.66, 0.72, 0.5, 0.62][i]
        NSBezierPath(roundedRect: NSRect(x: r.minX + 26, y: bar.minY - 120 - CGFloat(i) * 38, width: w, height: 16), xRadius: 8, yRadius: 8).fill()
    }
}

// Right: a copied note, on warm paper with the fiesta stripe.
hang(centerX: 695, width: 300, height: 280, angle: -3, sipit: red) { r in
    color(255, 248, 232).setFill(); r.fill()
    let stripe = r.width / CGFloat(banderitas.count)
    for (i, c) in banderitas.enumerated() {
        c.setFill()
        NSRect(x: r.minX + CGFloat(i) * stripe, y: r.maxY - 22, width: stripe + 1, height: 22).fill()
    }
    color(120, 90, 70, 0.55).setFill()
    for i in 0..<4 {
        let w = r.width * [0.74, 0.6, 0.68, 0.42][i]
        NSBezierPath(roundedRect: NSRect(x: r.minX + 26, y: r.maxY - 74 - CGFloat(i) * 42, width: w, height: 18), xRadius: 9, yRadius: 9).fill()
    }
}
ctx.restoreGState()

// Top-lit rim on the icon body.
shape.lineWidth = 4
ctx.saveGState()
shape.addClip()
color(255, 255, 255, 0.35).setStroke()
shape.stroke()
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
