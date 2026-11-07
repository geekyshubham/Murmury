import SwiftUI

// MARK: World

/// Murmury's world: a lit field per section (light, or deep violet in dark), flat glyph tiles,
/// regular display type and one flat round button for each screen's main action.
struct Hue: Equatable {
    var aRGB: RGB
    var bRGB: RGB
    var orbRGB: RGB
    var a: Color { aRGB.color }
    var b: Color { bRGB.color }
    var orbBase: Color { orbRGB.color }
    static let control = Hue(aRGB: RGB(0x9E5CFF), bRGB: RGB(0xDB1A9E), orbRGB: RGB(0x7A1FA8))
    static let buds = Hue(aRGB: RGB(0x4D9EFF), bRGB: RGB(0x1A47E6), orbRGB: RGB(0x1F4FD8))
    static let motion = Hue(aRGB: RGB(0x42DBDB), bRGB: RGB(0x4D42EB), orbRGB: RGB(0x1E6E9E))
    static let teach = Hue(aRGB: RGB(0xFF8566), bRGB: RGB(0xDB247A), orbRGB: RGB(0xC2185B))
    static let model = Hue(aRGB: RGB(0x8594FF), bRGB: RGB(0x802EEB), orbRGB: RGB(0x6A2BD9))
    static let detect = Hue(aRGB: RGB(0x6BEB8F), bRGB: RGB(0x0F8F9E), orbRGB: RGB(0x0B7A6E))
    static let all: [Hue] = [.control, .buds, .motion, .teach, .model, .detect]
    /// One dark brand world, tinted per section (ui-ux-pro-max `color-dark-mode`: tonal, desaturated
    /// variants, not full-hue floods): deep indigo-violet, tinted 20% toward the section's hue.
    /// Section identity comes from the hero glow, the glyph tiles and the action colour.
    /// Mid-deep and softly saturated: never near-black (luminance ≥ 0.04, the user's "too dark"
    /// feedback), never a loud flood (white copy keeps 7:1).
    static let worldTop = RGB(0x442D96), worldBottom = RGB(0x5336B2)
    var worldTopRGB: RGB { Hue.worldTop.mixed(with: bRGB.limitedLuminance(0.05), fraction: 0.2) }
    var worldBottomRGB: RGB { Hue.worldBottom.mixed(with: bRGB.limitedLuminance(0.08), fraction: 0.2) }
    /// The hero glow: the section's hue pulled toward brand violet and softened.
    var glowRGB: RGB { aRGB.mixed(with: RGB(0x8B6CF6), fraction: 0.25).limitedLuminance(0.28) }
    var actionRGB: RGB {
        if self == .control { return RGB(0xB01E9C) }
        if self == .buds { return RGB(0x1F5BE0) }
        if self == .motion { return RGB(0x136F9E) }
        return orbRGB
    }
    // Flat compatibility alias for the protected calibration view; no gradient is constructed.
    var gradient: Color { actionRGB.color }
}

enum Motion {
    /// The one motion grammar: every move in the app uses this spring.
    static let spring = Animation.spring(response: 0.45, dampingFraction: 0.82)
    static func spring(_ reduce: Bool) -> Animation { reduce ? .easeOut(duration: 0.12) : spring }
    /// Moving between sections: the page crossfade and the world's colour settle together.
    static func section(_ reduce: Bool) -> Animation { reduce ? .easeOut(duration: 0.2) : .easeInOut(duration: 0.45) }
    /// Hover and press feedback on controls.
    static let hover = Animation.easeOut(duration: 0.15)
    static let press = Animation.easeOut(duration: 0.12)
}

// MARK: Glyph tile

/// The app's icon tile: an illustration, not a control, so it is flat and tinted rather than a
/// solid raised chip that would read as a small button beside the real primary action.
struct GlyphTile: View {
    var symbol: String
    var hue: Hue
    var size: CGFloat = 32
    @Environment(\.colorScheme) private var scheme

    /// A section-tinted backing (12% light, 18% dark) with the glyph in the action colour (light) or
    /// white (dark). No shadow, no gradient, no rim.
    var body: some View {
        let dark = scheme == .dark
        let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        glyph
            .foregroundStyle(dark ? Ink.porcelain : hue.actionRGB.color)
            .frame(width: size, height: size)
            .background(shape.fill(hue.actionRGB.color.opacity(dark ? 0.18 : 0.12)))
            .accessibilityHidden(true)
    }
    @ViewBuilder private var glyph: some View {
        if symbol == RollGlyph.symbol {
            let box = size * 0.5
            RollGlyph().stroke(style: StrokeStyle(lineWidth: 1.75 * box / 20, lineCap: .round, lineJoin: .round)).frame(width: box, height: box)
        } else {
            Image(systemName: symbol).font(.system(size: size * 0.46, weight: .medium))
        }
    }
}

/// Rolling the head sideways: a tilted head axis between two curved arrows turning the same way.
/// (No SF Symbol says "roll"; a U-turn arrow reads as going back.)
struct RollGlyph: Shape {
    static let symbol = "murmury.roll"
    func path(in r: CGRect) -> Path {
        let side = min(r.width, r.height)
        func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: r.midX + (x - 0.5) * side, y: r.midY + (y - 0.5) * side) }
        var p = Path()
        // The head's axis, tilted, through the gaps at the top and bottom of the turn.
        p.move(to: pt(0.4, 0.06)); p.addLine(to: pt(0.6, 0.94))
        let c = pt(0.5, 0.5), radius = 0.42 * side
        // Two arcs turning the same way round the axis, each ending in an arrowhead.
        for (start, end) in [(118.0, 232.0), (-62.0, 52.0)] {
            let s = start * .pi / 180
            p.move(to: CGPoint(x: c.x + radius * cos(s), y: c.y + radius * sin(s)))
            p.addArc(center: c, radius: radius, startAngle: .degrees(start), endAngle: .degrees(end), clockwise: false)
            let a = end * .pi / 180, tip = CGPoint(x: c.x + radius * cos(a), y: c.y + radius * sin(a))
            let travel = atan2(cos(a), -sin(a)), head = 0.26 * side
            for spread in [-0.55, 0.55] {
                p.move(to: tip)
                p.addLine(to: CGPoint(x: tip.x - head * cos(travel + spread), y: tip.y - head * sin(travel + spread)))
            }
        }
        return p
    }
}

// MARK: Panels

/// Content surface on the lit field. Translucent so the section's light reads through it.
struct Panel<Content: View>: View {
    var title: String?
    var subtitle: String?
    var symbol: String?
    var hue: Hue?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            if let title {
                HStack(spacing: Space.sm) {
                    if let symbol, let hue { GlyphTile(symbol: symbol, hue: hue, size: 28) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(TypeStyle.rowTitle).foregroundStyle(Ink.primary)
                        if let subtitle { Text(subtitle).font(TypeStyle.body).foregroundStyle(Ink.secondary) }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }
            content
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}

/// State in a fixed cell: a dot and words, same place on every screen.
struct StateChip: View {
    var text: String
    var color: Color
    /// Something is running (streaming, recording, training): a still ring around the dot.
    /// Nothing pulses; the words carry the change.
    var active = false
    var body: some View {
        HStack(spacing: Space.unit) {
            Circle().fill(color).frame(width: 8, height: 8)
                .overlay(Circle().strokeBorder(color.opacity(active ? 0.75 : 0), lineWidth: 1.5).padding(-3.5))
                .frame(width: 8, height: 8).accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(TypeStyle.chip).foregroundStyle(Ink.primary)
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Ink.panel, in: Capsule()).overlay(Capsule().strokeBorder(Ink.glassStroke, lineWidth: Radius.hairlineWidth))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status: " + text)
        .accessibilityAddTraits([.isStaticText, .updatesFrequently])
    }
}

// MARK: Small parts

/// A labelled slider row for settings panels.
struct SliderRow: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double
    var format: String
    var help: String
    var tint: Color

    var body: some View {
        HStack(spacing: 14) {
            Text(title).font(TypeStyle.body).foregroundStyle(Ink.primary).frame(width: 150, alignment: .leading)
            FieldSlider(title: title, value: $value, range: range, step: step, tint: tint)
            Text(String(format: format, value)).font(TypeStyle.caption.monospacedDigit()).foregroundStyle(Ink.secondary)
                .frame(width: 70, alignment: .trailing)
        }
        .help(help)
    }
}

