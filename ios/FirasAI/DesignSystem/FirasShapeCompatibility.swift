import SwiftUI

/// Static shape erasure also available to the iOS 15 glass materials.
struct FirasAnyShape: Shape {
    private let draw: (CGRect) -> Path
    init<S: Shape>(_ shape: S) { draw = shape.path(in:) }
    func path(in rect: CGRect) -> Path { draw(rect) }
}

struct FirasUnevenRoundedRectangle: Shape {
    var topLeadingRadius: CGFloat = 0
    var bottomLeadingRadius: CGFloat = 0
    var bottomTrailingRadius: CGFloat = 0
    var topTrailingRadius: CGFloat = 0
    var style: RoundedCornerStyle = .continuous

    func path(in rect: CGRect) -> Path {
        if #available(iOS 17, *), !FirasCompatibility.forceLegacyUI {
            return UnevenRoundedRectangle(topLeadingRadius: topLeadingRadius,
                bottomLeadingRadius: bottomLeadingRadius, bottomTrailingRadius: bottomTrailingRadius,
                topTrailingRadius: topTrailingRadius, style: style).path(in: rect)
        }
        let limit = max(0, min(rect.width, rect.height) / 2)
        let tl = min(limit, max(0, topLeadingRadius)), tr = min(limit, max(0, topTrailingRadius))
        let bl = min(limit, max(0, bottomLeadingRadius)), br = min(limit, max(0, bottomTrailingRadius))
        let k: CGFloat = 0.5522847498
        let x = rect.minX, y = rect.minY, r = rect.maxX, b = rect.maxY
        var p = Path()
        p.move(to: CGPoint(x: x + tl, y: y))
        p.addLine(to: CGPoint(x: r - tr, y: y))
        p.addCurve(to: CGPoint(x: r, y: y + tr), control1: CGPoint(x: r - tr + tr*k, y: y), control2: CGPoint(x: r, y: y + tr - tr*k))
        p.addLine(to: CGPoint(x: r, y: b - br))
        p.addCurve(to: CGPoint(x: r - br, y: b), control1: CGPoint(x: r, y: b - br + br*k), control2: CGPoint(x: r - br + br*k, y: b))
        p.addLine(to: CGPoint(x: x + bl, y: b))
        p.addCurve(to: CGPoint(x: x, y: b - bl), control1: CGPoint(x: x + bl - bl*k, y: b), control2: CGPoint(x: x, y: b - bl + bl*k))
        p.addLine(to: CGPoint(x: x, y: y + tl))
        p.addCurve(to: CGPoint(x: x + tl, y: y), control1: CGPoint(x: x, y: y + tl - tl*k), control2: CGPoint(x: x + tl - tl*k, y: y))
        p.closeSubpath()
        return p
    }
}
