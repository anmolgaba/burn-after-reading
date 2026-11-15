import SwiftUI

/// Postage stamp and postmark shared by the envelope and the letter, drawn in vector.
enum PostalMarks {
    static let red = Color(red: 0.78, green: 0.20, blue: 0.16)
    static let blue = Color(red: 0.20, green: 0.32, blue: 0.68)
    static let city = "BENGALURU"
    static let date = "14.11.26"

    /// Stamp tilted slightly, overlapped by a postmark down and to its left.
    /// `size` is the stamp's width; the group extends about 0.55 × size to the left of `stampCenter`.
    static func drawCorner(in context: GraphicsContext, stampCenter: CGPoint, size: CGFloat) {
        var stamp = context
        stamp.translateBy(x: stampCenter.x, y: stampCenter.y)
        stamp.rotate(by: .degrees(6))
        drawStamp(in: stamp, rect: CGRect(x: -size / 2, y: -size * 0.6, width: size, height: size * 1.2))

        drawPostmark(in: context,
                     center: CGPoint(x: stampCenter.x - size * 0.55, y: stampCenter.y + size * 0.32),
                     radius: size * 0.42)
    }

    static func drawStamp(in context: GraphicsContext, rect: CGRect) {
        let bite = max(1.1, rect.width / 22)
        let spacing = bite * 2.6
        var paper = Path(rect)
        // Perforation bites around all four sides.
        var bites = Path()
        for x in stride(from: rect.minX + spacing / 2, through: rect.maxX, by: spacing) {
            bites.addEllipse(in: CGRect(x: x - bite, y: rect.minY - bite, width: bite * 2, height: bite * 2))
            bites.addEllipse(in: CGRect(x: x - bite, y: rect.maxY - bite, width: bite * 2, height: bite * 2))
        }
        for y in stride(from: rect.minY + spacing / 2, through: rect.maxY, by: spacing) {
            bites.addEllipse(in: CGRect(x: rect.minX - bite, y: y - bite, width: bite * 2, height: bite * 2))
            bites.addEllipse(in: CGRect(x: rect.maxX - bite, y: y - bite, width: bite * 2, height: bite * 2))
        }
        paper = paper.subtracting(bites)

        var shadowed = context
        shadowed.addFilter(.shadow(color: .black.opacity(0.12), radius: 0.8, x: 0, y: 0.6))
        shadowed.fill(paper, with: .color(Color(red: 0.99, green: 0.98, blue: 0.96)))

        let panel = rect.insetBy(dx: rect.width * 0.16, dy: rect.width * 0.16)
        context.fill(Path(panel), with: .color(Color(red: 0.96, green: 0.92, blue: 0.84)))
        context.stroke(Path(panel), with: .color(red.opacity(0.55)), lineWidth: max(0.4, rect.width / 90))

        let mapRect = panel.insetBy(dx: panel.width * 0.12, dy: panel.height * 0.08)
        let map = indiaOutline(in: mapRect)
        context.fill(map, with: .color(red.opacity(0.9)))
        // Slightly misregistered blue plate, like cheap two-colour printing.
        var offset = context
        offset.translateBy(x: rect.width * 0.025, y: -rect.width * 0.015)
        offset.stroke(map, with: .color(blue.opacity(0.8)), lineWidth: max(0.5, rect.width / 45))
    }

    /// A `clockFace` postmark leaves its centre blank, its outer ring faint and drops the cancel lines,
    /// so `PostmarkClock` can ink the countdown over it.
    static func drawPostmark(in context: GraphicsContext, center: CGPoint, radius: CGFloat, clockFace: Bool = false) {
        var mark = context
        mark.blendMode = .multiply
        mark.drawLayer { ink in
            let line = max(0.5, radius / 18)
            let outer = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            ink.stroke(Path(ellipseIn: outer), with: .color(blue.opacity(clockFace ? 0.18 : 0.8)), lineWidth: line)
            ink.stroke(Path(ellipseIn: outer.insetBy(dx: radius * 0.42, dy: radius * 0.42)),
                       with: .color(blue.opacity(0.7)), lineWidth: line * 0.8)

            // City name around the upper arc.
            let letters = Array(city)
            let textRadius = radius * 0.79
            let sweep = Double.pi * 0.85
            let fontSize = radius * 0.2
            for (index, letter) in letters.enumerated() {
                let t = letters.count == 1 ? 0.5 : Double(index) / Double(letters.count - 1)
                let angle = -Double.pi / 2 - sweep / 2 + sweep * t
                var glyph = ink
                glyph.translateBy(x: center.x + textRadius * cos(angle), y: center.y + textRadius * sin(angle))
                glyph.rotate(by: .radians(angle + .pi / 2))
                glyph.draw(Text(String(letter))
                    .font(.system(size: fontSize, weight: .semibold, design: .serif))
                    .foregroundColor(blue.opacity(0.85)), at: .zero)
            }

            if !clockFace {
                ink.draw(Text(date)
                    .font(.system(size: radius * 0.15, weight: .semibold, design: .monospaced))
                    .foregroundColor(red.opacity(0.85)), at: center)
            }

            // Wavy cancellation lines trailing to the right (not on the clock face, which stands alone).
            for row in 0..<(clockFace ? 0 : 3) {
                let y = center.y - radius * 0.32 + CGFloat(row) * radius * 0.32
                var wave = Path()
                let start = center.x + radius * 1.05
                wave.move(to: CGPoint(x: start, y: y))
                for step in 1...24 {
                    let x = start + CGFloat(step) * radius * 0.07
                    wave.addLine(to: CGPoint(x: x, y: y + sin(CGFloat(step) * 0.75) * radius * 0.06))
                }
                ink.stroke(wave, with: .color(blue.opacity(0.6)), lineWidth: line * 0.85)
            }

            ink.blendMode = .destinationOut
            var wear = Path()
            let area = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 3.8, height: radius * 2)
            for index in 0..<260 {
                let x = area.minX + StableRandom.unit(index, salt: 13) * area.width
                let y = area.minY + StableRandom.unit(index, salt: 29) * area.height
                let r = 0.2 + pow(StableRandom.unit(index, salt: 47), 3) * radius * 0.06
                wear.addEllipse(in: CGRect(x: x, y: y, width: r * 2.2, height: r))
            }
            ink.fill(wear, with: .color(.white))
        }
    }

    private static func indiaOutline(in rect: CGRect) -> Path {
        let points: [(CGFloat, CGFloat)] = [
            (0.30, 0.00), (0.42, 0.02), (0.45, 0.10), (0.40, 0.16), (0.48, 0.22), (0.62, 0.28),
            (0.72, 0.30), (0.80, 0.26), (0.92, 0.27), (1.00, 0.33), (0.94, 0.40), (0.86, 0.38),
            (0.80, 0.44), (0.72, 0.48), (0.66, 0.56), (0.58, 0.66), (0.52, 0.78), (0.47, 0.92),
            (0.43, 1.00), (0.38, 0.90), (0.34, 0.76), (0.30, 0.62), (0.26, 0.52), (0.18, 0.50),
            (0.08, 0.44), (0.00, 0.40), (0.10, 0.34), (0.18, 0.30), (0.22, 0.20), (0.26, 0.10)
        ]
        var path = Path()
        for (index, point) in points.enumerated() {
            let p = CGPoint(x: rect.minX + point.0 * rect.width, y: rect.minY + point.1 * rect.height)
            if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        return path
    }

}
