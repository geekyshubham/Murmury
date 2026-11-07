import SwiftUI

/// The one round primary action per screen: a solid disc with a soft neutral shadow and no ring in
/// either appearance. Its white label (4.5:1 on the fill) names it, and the focus ring reaches 3:1, so
/// the disc needs no outline (WCAG 1.4.11 asks none of a text-labelled button). Increase Contrast
/// adds one. Running is shown by the label and the status pill, not by motion; disabled loses the shadow.
enum PrimaryActionSpec {
    static let diameter: CGFloat = 112
    static let disc: CGFloat = 106
    /// No rim in either appearance; Increase Contrast draws a 2 pt outline instead.
    static let rimWidth: CGFloat = 0
    static let usesGradient = false
    static func fill(hue: Hue, dark: Bool, enabled: Bool, hovering: Bool) -> RGB {
        if !enabled { return hue.actionRGB.mixed(with: RGB(dark ? 0x8A84A3 : 0xB9B3CC), fraction: 0.55) }
        return hovering ? hue.actionRGB.mixed(with: RGB(0xFFFFFF), fraction: 0.06) : hue.actionRGB
    }
    /// The visible boundary against the field: the fill itself.
    static func boundary(hue: Hue, dark: Bool) -> RGB { hue.actionRGB }
}

struct PrimaryActionFace<Label: View>: View {
    var hue: Hue
    var active: Bool
    var pressed: Bool
    var enabled: Bool
    var label: Label
    var hovering = false
    var sampleTime: Double? = nil
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let dark = scheme == .dark
        let fill = PrimaryActionSpec.fill(hue: hue, dark: dark, enabled: enabled, hovering: hovering)
        ZStack {
            Circle().fill(fill.color)
                // A neutral shadow is the only depth: no coloured glow, no rim, nothing breathing. In
                // dark appearance a tighter contact shadow sets the disc off the glowing field.
                .shadow(color: .black.opacity(enabled && dark ? 0.18 : 0), radius: 3, y: 2)
                // Soft, like the studio light on the head: resting low, a modest lift on hover.
                .shadow(color: .black.opacity(enabled ? (dark ? 0.22 : 0.16) : 0), radius: hovering && enabled ? 12 : 10, y: dark ? 4 : 6)
                .overlay {
                    if contrast == .increased {
                        Circle().strokeBorder((dark ? Palette.dark : .light).primary.color, lineWidth: 2).padding(-2)
                    }
                }
                .frame(width: PrimaryActionSpec.disc, height: PrimaryActionSpec.disc)
            label.font(TypeStyle.orbLabel).foregroundStyle(.white)
                // A short verb phrase on one line; a longer one wraps to two lines, never truncates.
                .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.85).padding(.horizontal, 10)
        }
        .frame(width: PrimaryActionSpec.diameter, height: PrimaryActionSpec.diameter)
        .scaleEffect(pressed && !reduceMotion ? 0.97 : 1)
        .animation(Motion.hover, value: hovering)
        .animation(Motion.press, value: pressed)
    }
}
