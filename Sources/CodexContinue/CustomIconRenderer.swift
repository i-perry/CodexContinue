import AppKit
import SwiftUI

enum MenuBarIconStyle: String, CaseIterable, Identifiable {
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

    var id: String { rawValue }

    var label: String {
        switch self {
        case .base: return "Base"
        case .disabled: return "Paused"
        case .watching: return "Watching"
        case .active: return "Active Subagents"
        case .settling: return "Settling / Cooldown"
        case .userIdle: return "User Idle Guard"
        case .sending: return "Sending Continue"
        case .limit: return "Usage Limit Wait"
        case .completed: return "100% Completed"
        case .alert: return "Attention Needed"
        }
    }
}

extension MonitorPhase {
    var iconStyle: MenuBarIconStyle {
        switch self {
        case .disabled:
            return .disabled
        case .waitingForCodexApp, .waitingForPermission, .differentChatActive:
            return .alert
        case .watchingIdleNotArmed:
            return .watching
        case .armedSubagentsRunning:
            return .active
        case .settlingBeforeSend, .postSendCooldown:
            return .settling
        case .waitingForUserIdle:
            return .userIdle
        case .sendingContinue:
            return .sending
        case .pausedUsageLimit:
            return .limit
        case .stoppedCompleted:
            return .completed
        }
    }
}

enum CustomIconRenderer {
    private static var cache: [String: NSImage] = [:]

    /// Returns a crisp vector-drawn template `NSImage` for the macOS Menu Bar.
    static func menuBarImage(for style: MenuBarIconStyle, pointSize: CGFloat = 18, isTemplate: Bool = true) -> NSImage {
        let key = "\(style.rawValue)-\(Int(pointSize))-\(isTemplate)"
        if let cached = cache[key] {
            return cached
        }

        let image = NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            drawVectorGlyph(style: style, in: ctx, size: rect.size, tintColor: .black)
            return true
        }
        image.isTemplate = isTemplate
        cache[key] = image
        return image
    }

    /// Draws the custom CodexContinue orbital + forward-chevron glyph and status badge.
    static func drawVectorGlyph(
        style: MenuBarIconStyle,
        in ctx: CGContext,
        size: CGSize,
        tintColor: NSColor
    ) {
        ctx.saveGState()
        let s = min(size.width, size.height) / 36.0
        ctx.scaleBy(x: s, y: s)

        let primaryAlpha: CGFloat = (style == .disabled) ? 0.50 : 1.0
        let mainColor = tintColor.withAlphaComponent(primaryAlpha).cgColor
        let badgeColor = tintColor.cgColor

        let center = CGPoint(x: 16.5, y: 18.5)
        let radius: CGFloat = 11.5

        // 1. Orbital C-Ring
        let hasBadge = (style != .base)
        let endAngle: CGFloat = hasBadge ? (.pi * 1.72) : (.pi * 1.88)
        let startAngle: CGFloat = hasBadge ? (.pi * 0.12) : (.pi * 0.08)

        ctx.saveGState()
        ctx.setStrokeColor(mainColor)
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
            ctx.setFillColor(mainColor)
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
        ctx.setFillColor(mainColor)
        ctx.fillPath()
        ctx.restoreGState()

        // 4. Status Sub-Badge at bottom-right (centered at 28.5, 8.5)
        let bx: CGFloat = 28.5
        let by: CGFloat = 8.5

        ctx.saveGState()
        ctx.setStrokeColor(badgeColor)
        ctx.setFillColor(badgeColor)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        switch style {
        case .base:
            break

        case .disabled:
            ctx.setLineWidth(2.2)
            ctx.move(to: CGPoint(x: bx - 2.3, y: by - 3.2))
            ctx.addLine(to: CGPoint(x: bx - 2.3, y: by + 3.2))
            ctx.move(to: CGPoint(x: bx + 2.3, y: by - 3.2))
            ctx.addLine(to: CGPoint(x: bx + 2.3, y: by + 3.2))
            ctx.strokePath()

        case .watching:
            ctx.setLineWidth(1.9)
            ctx.strokeEllipse(in: CGRect(x: bx - 4.5, y: by - 4.5, width: 9.0, height: 9.0))
            ctx.fillEllipse(in: CGRect(x: bx - 1.5, y: by - 1.5, width: 3.0, height: 3.0))

        case .active:
            ctx.fillEllipse(in: CGRect(x: bx - 3.2, y: by - 3.2, width: 6.4, height: 6.4))
            ctx.setLineWidth(1.6)
            ctx.strokeEllipse(in: CGRect(x: bx - 5.4, y: by - 5.4, width: 10.8, height: 10.8))

        case .settling:
            ctx.setLineWidth(2.0)
            ctx.addArc(center: CGPoint(x: bx, y: by), radius: 4.8, startAngle: -.pi * 0.3, endAngle: .pi * 1.4, clockwise: false)
            ctx.strokePath()
            ctx.move(to: CGPoint(x: bx, y: by))
            ctx.addLine(to: CGPoint(x: bx + 2.5, y: by + 2.2))
            ctx.strokePath()

        case .userIdle:
            for dx in [-3.6, 0.0, 3.6] {
                ctx.fillEllipse(in: CGRect(x: bx + dx - 1.3, y: by - 1.3, width: 2.6, height: 2.6))
            }

        case .sending:
            ctx.setLineWidth(2.2)
            ctx.move(to: CGPoint(x: bx, y: by - 4.5))
            ctx.addLine(to: CGPoint(x: bx, y: by + 4.5))
            ctx.move(to: CGPoint(x: bx - 3.5, y: by + 1.2))
            ctx.addLine(to: CGPoint(x: bx, y: by + 4.8))
            ctx.addLine(to: CGPoint(x: bx + 3.5, y: by + 1.2))
            ctx.strokePath()

        case .limit:
            ctx.setLineWidth(1.9)
            ctx.strokeEllipse(in: CGRect(x: bx - 4.8, y: by - 4.8, width: 9.6, height: 9.6))
            ctx.move(to: CGPoint(x: bx, y: by + 2.8))
            ctx.addLine(to: CGPoint(x: bx, y: by))
            ctx.addLine(to: CGPoint(x: bx + 2.4, y: by - 1.2))
            ctx.strokePath()

        case .completed:
            ctx.setLineWidth(2.4)
            ctx.move(to: CGPoint(x: bx - 4.2, y: by - 0.2))
            ctx.addLine(to: CGPoint(x: bx - 1.0, y: by - 3.4))
            ctx.addLine(to: CGPoint(x: bx + 4.6, y: by + 3.4))
            ctx.strokePath()

        case .alert:
            ctx.setLineWidth(2.5)
            ctx.move(to: CGPoint(x: bx, y: by + 4.4))
            ctx.addLine(to: CGPoint(x: bx, y: by - 0.6))
            ctx.strokePath()
            ctx.fillEllipse(in: CGRect(x: bx - 1.4, y: by - 4.4, width: 2.8, height: 2.8))
        }

        ctx.restoreGState()
        ctx.restoreGState()
    }
}
