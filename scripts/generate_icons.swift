import AppKit
import CoreGraphics
import Foundation

let fileManager = FileManager.default
let currentDir = URL(fileURLWithPath: fileManager.currentDirectoryPath)
let iconsetDir = currentDir.appendingPathComponent("BuildResources/AppIcon.iconset")
let menuBarDir = currentDir.appendingPathComponent("Resources/MenuBarIcons")

try? fileManager.removeItem(at: iconsetDir)
try fileManager.createDirectory(at: iconsetDir, withIntermediateDirectories: true)
try fileManager.createDirectory(at: menuBarDir, withIntermediateDirectories: true)

// MARK: - 1. Generate macOS AppIcon.iconset (16x16 to 1024x1024)

func drawAppIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)

    let scale = size / 1024.0
    ctx.scaleBy(x: scale, y: scale)

    // macOS Squircle Geometry (within 1024x1024 canvas, 100pt margin -> 824x824 squircle)
    let rect = CGRect(x: 88, y: 88, width: 848, height: 848)
    let cornerRadius: CGFloat = 190.0
    let squirclePath = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    // Drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -24), blur: 48, color: NSColor(calibratedWhite: 0, alpha: 0.45).cgColor)
    ctx.addPath(squirclePath)
    ctx.setFillColor(NSColor(calibratedRed: 0.06, green: 0.08, blue: 0.14, alpha: 1.0).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Clip to squircle
    ctx.saveGState()
    ctx.addPath(squirclePath)
    ctx.clip()

    // Deep midnight-indigo to teal-slate background gradient
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bgColors = [
        NSColor(calibratedRed: 0.05, green: 0.07, blue: 0.13, alpha: 1.0).cgColor,
        NSColor(calibratedRed: 0.08, green: 0.14, blue: 0.24, alpha: 1.0).cgColor,
        NSColor(calibratedRed: 0.06, green: 0.22, blue: 0.28, alpha: 1.0).cgColor
    ] as CFArray
    let locations: [CGFloat] = [0.0, 0.55, 1.0]
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: locations) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: 150, y: 900),
            end: CGPoint(x: 880, y: 120),
            options: []
        )
    }

    // Ambient radial glow in center
    let glowColors = [
        NSColor(calibratedRed: 0.10, green: 0.85, blue: 0.72, alpha: 0.28).cgColor,
        NSColor(calibratedRed: 0.10, green: 0.55, blue: 0.95, alpha: 0.0).cgColor
    ] as CFArray
    if let radial = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0.0, 1.0]) {
        ctx.drawRadialGradient(
            radial,
            startCenter: CGPoint(x: 512, y: 512),
            startRadius: 20,
            endCenter: CGPoint(x: 512, y: 512),
            endRadius: 370,
            options: []
        )
    }

    let center = CGPoint(x: 512, y: 512)
    let orbitRadius: CGFloat = 265

    // Outer dashed/segmented orbital track
    ctx.saveGState()
    ctx.setStrokeColor(NSColor(calibratedRed: 0.35, green: 0.88, blue: 0.85, alpha: 0.25).cgColor)
    ctx.setLineWidth(14)
    ctx.addArc(center: center, radius: orbitRadius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.strokePath()
    ctx.restoreGState()

    // Active glowing orbital arcs connecting the 3 subagent nodes
    let arcAngles: [(CGFloat, CGFloat)] = [
        (0.28, 1.82),
        (2.38, 3.90),
        (4.45, 5.95)
    ]
    ctx.saveGState()
    ctx.setLineCap(.round)
    ctx.setLineWidth(24)
    ctx.setStrokeColor(NSColor(calibratedRed: 0.18, green: 0.92, blue: 0.78, alpha: 0.92).cgColor)
    ctx.setShadow(offset: .zero, blur: 22, color: NSColor(calibratedRed: 0.15, green: 0.95, blue: 0.80, alpha: 0.65).cgColor)
    for (startA, endA) in arcAngles {
        ctx.addArc(center: center, radius: orbitRadius, startAngle: startA, endAngle: endA, clockwise: false)
        ctx.strokePath()
    }
    ctx.restoreGState()

    // 3 Subagent satellite nodes on the orbital ring (at 60°, 180°, 300°)
    let nodeAngles: [CGFloat] = [
        .pi / 3.0,
        .pi,
        5.0 * .pi / 3.0
    ]
    for angle in nodeAngles {
        let nx = center.x + cos(angle) * orbitRadius
        let ny = center.y + sin(angle) * orbitRadius
        let nodeCenter = CGPoint(x: nx, y: ny)

        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 18, color: NSColor(calibratedRed: 0.2, green: 0.95, blue: 0.82, alpha: 0.8).cgColor)
        ctx.setFillColor(NSColor(calibratedRed: 0.07, green: 0.13, blue: 0.22, alpha: 1.0).cgColor)
        ctx.fillEllipse(in: CGRect(x: nodeCenter.x - 36, y: nodeCenter.y - 36, width: 72, height: 72))

        ctx.setLineWidth(14)
        ctx.setStrokeColor(NSColor(calibratedRed: 0.35, green: 0.98, blue: 0.86, alpha: 1.0).cgColor)
        ctx.strokeEllipse(in: CGRect(x: nodeCenter.x - 32, y: nodeCenter.y - 32, width: 64, height: 64))

        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: CGRect(x: nodeCenter.x - 13, y: nodeCenter.y - 13, width: 26, height: 26))
        ctx.restoreGState()
    }

    // Center "Continue" Play-Forward Symbol (`▶|>` style double chevron / play glyph)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor(calibratedRed: 0.0, green: 0.0, blue: 0.0, alpha: 0.5).cgColor)

    // Primary Play Triangle
    let playPath = CGMutablePath()
    playPath.move(to: CGPoint(x: 420, y: 632))
    playPath.addLine(to: CGPoint(x: 615, y: 512))
    playPath.addLine(to: CGPoint(x: 420, y: 392))
    playPath.closeSubpath()

    ctx.addPath(playPath)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillPath()

    // Forward Continue Chevron Bar to the right
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(38)
    ctx.setStrokeColor(NSColor(calibratedRed: 0.28, green: 0.96, blue: 0.82, alpha: 1.0).cgColor)
    ctx.move(to: CGPoint(x: 618, y: 590))
    ctx.addLine(to: CGPoint(x: 690, y: 512))
    ctx.addLine(to: CGPoint(x: 618, y: 434))
    ctx.strokePath()
    ctx.restoreGState()

    // Inner glass border highlight around squircle
    ctx.addPath(squirclePath)
    ctx.setStrokeColor(NSColor(calibratedWhite: 1.0, alpha: 0.18).cgColor)
    ctx.setLineWidth(6)
    ctx.strokePath()

    ctx.restoreGState()
    image.unlockFocus()
    return image
}

func savePNG(_ image: NSImage, to url: URL, pixelSize: Int) throws {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return }

    rep.size = NSSize(width: pixelSize, height: pixelSize)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
    NSGraphicsContext.restoreGraphicsState()

    guard let pngData = rep.representation(using: .png, properties: [:]) else { return }
    try pngData.write(to: url)
}

let iconSpecs: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

let masterAppIcon = drawAppIcon(size: 1024)
for (filename, px) in iconSpecs {
    try savePNG(masterAppIcon, to: iconsetDir.appendingPathComponent(filename), pixelSize: px)
}

// Also save a 512x512 preview for README
try savePNG(masterAppIcon, to: menuBarDir.appendingPathComponent("app-icon-preview.png"), pixelSize: 512)

// MARK: - 2. Generate Menu Bar Status Icon Pack (18pt @1x and 36px @2x)

enum MenuBarIconStyle: String, CaseIterable {
    case base = "menubar-base"
    case disabled = "menubar-disabled"
    case watching = "menubar-watching"
    case active = "menubar-active"
    case settling = "menubar-settling"
    case userIdle = "menubar-user-idle"
    case sending = "menubar-sending"
    case limit = "menubar-limit"
    case completed = "menubar-completed"
    case alert = "menubar-alert"
}

func drawMenuBarIcon(style: MenuBarIconStyle, pixelSize: Int) -> NSImage {
    let size = CGFloat(pixelSize)
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        img.unlockFocus()
        return img
    }

    let s = size / 36.0
    ctx.scaleBy(x: s, y: s)

    let primaryAlpha: CGFloat = (style == .disabled) ? 0.48 : 1.0
    let strokeColor = NSColor(calibratedWhite: 0.0, alpha: primaryAlpha).cgColor
    let center = CGPoint(x: 16.5, y: 18.5)
    let radius: CGFloat = 11.5

    // 1. Orbital C-Ring (open at bottom-right when badge is present, full segmented ring for base)
    let hasBadge = (style != .base)
    let endAngle: CGFloat = hasBadge ? (.pi * 1.72) : (.pi * 1.88)
    let startAngle: CGFloat = hasBadge ? (.pi * 0.12) : (.pi * 0.08)

    ctx.saveGState()
    ctx.setStrokeColor(strokeColor)
    ctx.setLineWidth(2.6)
    ctx.setLineCap(.round)
    ctx.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
    ctx.strokePath()
    ctx.restoreGState()

    // 2. Three Subagent Orbital Nodes at 65°, 165°, 255°
    let nodeAngles: [CGFloat] = [1.13, 2.88, 4.45]
    for (idx, a) in nodeAngles.enumerated() {
        let nx = center.x + cos(a) * radius
        let ny = center.y + sin(a) * radius
        let nr: CGFloat = (style == .active && idx == 0) ? 2.8 : 2.3
        ctx.saveGState()
        ctx.setFillColor(strokeColor)
        ctx.fillEllipse(in: CGRect(x: nx - nr, y: ny - nr, width: nr * 2, height: nr * 2))
        ctx.restoreGState()
    }

    // 3. Center "Continue" Play Triangle (`▶`)
    ctx.saveGState()
    let play = CGMutablePath()
    play.move(to: CGPoint(x: 13.5, y: 23.2))
    play.addLine(to: CGPoint(x: 21.8, y: 18.5))
    play.addLine(to: CGPoint(x: 13.5, y: 13.8))
    play.closeSubpath()
    ctx.addPath(play)
    ctx.setFillColor(strokeColor)
    ctx.fillPath()
    ctx.restoreGState()

    // 4. Status Sub-Badge at bottom-right (centered at 28.5, 8.5)
    let bx: CGFloat = 28.5
    let by: CGFloat = 8.5

    ctx.saveGState()
    ctx.setStrokeColor(NSColor.black.cgColor)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    switch style {
    case .base:
        break

    case .disabled:
        // Pause bars `||`
        ctx.setLineWidth(2.2)
        ctx.move(to: CGPoint(x: bx - 2.3, y: by - 3.2))
        ctx.addLine(to: CGPoint(x: bx - 2.3, y: by + 3.2))
        ctx.move(to: CGPoint(x: bx + 2.3, y: by - 3.2))
        ctx.addLine(to: CGPoint(x: bx + 2.3, y: by + 3.2))
        ctx.strokePath()

    case .watching:
        // Hollow target ring + center dot
        ctx.setLineWidth(1.9)
        ctx.strokeEllipse(in: CGRect(x: bx - 4.5, y: by - 4.5, width: 9.0, height: 9.0))
        ctx.fillEllipse(in: CGRect(x: bx - 1.5, y: by - 1.5, width: 3.0, height: 3.0))

    case .active:
        // Active pulsing double-ring node
        ctx.fillEllipse(in: CGRect(x: bx - 3.2, y: by - 3.2, width: 6.4, height: 6.4))
        ctx.setLineWidth(1.6)
        ctx.strokeEllipse(in: CGRect(x: bx - 5.4, y: by - 5.4, width: 10.8, height: 10.8))

    case .settling:
        // Countdown timer arc with clock hand
        ctx.setLineWidth(2.0)
        ctx.addArc(center: CGPoint(x: bx, y: by), radius: 4.8, startAngle: -.pi * 0.3, endAngle: .pi * 1.4, clockwise: false)
        ctx.strokePath()
        ctx.move(to: CGPoint(x: bx, y: by))
        ctx.addLine(to: CGPoint(x: bx + 2.5, y: by + 2.2))
        ctx.strokePath()

    case .userIdle:
        // Keyboard / ellipsis wait dots
        for dx in [-3.6, 0.0, 3.6] {
            ctx.fillEllipse(in: CGRect(x: bx + dx - 1.3, y: by - 1.3, width: 2.6, height: 2.6))
        }

    case .sending:
        // Upward send arrow `↑`
        ctx.setLineWidth(2.2)
        ctx.move(to: CGPoint(x: bx, y: by - 4.5))
        ctx.addLine(to: CGPoint(x: bx, y: by + 4.5))
        ctx.move(to: CGPoint(x: bx - 3.5, y: by + 1.2))
        ctx.addLine(to: CGPoint(x: bx, y: by + 4.8))
        ctx.addLine(to: CGPoint(x: bx + 3.5, y: by + 1.2))
        ctx.strokePath()

    case .limit:
        // Clock with lock/Wait hands
        ctx.setLineWidth(1.9)
        ctx.strokeEllipse(in: CGRect(x: bx - 4.8, y: by - 4.8, width: 9.6, height: 9.6))
        ctx.move(to: CGPoint(x: bx, y: by + 2.8))
        ctx.addLine(to: CGPoint(x: bx, y: by))
        ctx.addLine(to: CGPoint(x: bx + 2.4, y: by - 1.2))
        ctx.strokePath()

    case .completed:
        // Bold Checkmark `✓`
        ctx.setLineWidth(2.4)
        ctx.move(to: CGPoint(x: bx - 4.2, y: by - 0.2))
        ctx.addLine(to: CGPoint(x: bx - 1.0, y: by - 3.4))
        ctx.addLine(to: CGPoint(x: bx + 4.6, y: by + 3.4))
        ctx.strokePath()

    case .alert:
        // Exclamation mark `!`
        ctx.setLineWidth(2.5)
        ctx.move(to: CGPoint(x: bx, y: by + 4.4))
        ctx.addLine(to: CGPoint(x: bx, y: by - 0.6))
        ctx.strokePath()
        ctx.fillEllipse(in: CGRect(x: bx - 1.4, y: by - 4.4, width: 2.8, height: 2.8))
    }

    ctx.restoreGState()
    img.unlockFocus()
    return img
}

for style in MenuBarIconStyle.allCases {
    let img1x = drawMenuBarIcon(style: style, pixelSize: 18)
    let img2x = drawMenuBarIcon(style: style, pixelSize: 36)
    try savePNG(img1x, to: menuBarDir.appendingPathComponent("\(style.rawValue).png"), pixelSize: 18)
    try savePNG(img2x, to: menuBarDir.appendingPathComponent("\(style.rawValue)@2x.png"), pixelSize: 36)
}

print("Generated AppIcon.iconset and 10 Menu Bar status icons (1x & 2x) successfully!")
