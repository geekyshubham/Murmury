import SwiftUI

/// A contrast-preserving tinted undercoat keeps the specified white/hue overlays luminous.
enum SidebarSurface {
    static func sample(over field: RGB, hue: Hue, dark: Bool) -> RGB {
        guard dark else { return RGB(0xFFFFFF).over(field, opacity: 0.45) }
        let base = undercoat(hue).over(field, opacity: 0.70)  // a deeper sidebar in dark: three tones, sidebar < copy < hero
        let white = RGB(0xFFFFFF).over(base, opacity: 0.06)
        let tint = hue.aRGB.over(white, opacity: 0.06)
        return hue.worldBottomRGB.over(tint, opacity: 0.18)
    }
    static func undercoat(_ hue: Hue) -> RGB { hue.worldTopRGB.limitedLuminance(0.025) }
    static func selection(hue: Hue, dark: Bool) -> RGB {
        guard dark else { return RGB(0xFFFFFF, alpha: 0.78) }
        // Lifted, not recessed: a little white over the sidebar's own colour, so the selected row
        // reads raised; its label still clears 7:1.
        return RGB(0xFFFFFF).over(sample(over: hue.worldTopRGB, hue: hue, dark: true), opacity: 0.10)
    }
    static func opaque(hue: Hue) -> RGB { sample(over: hue.worldTopRGB, hue: hue, dark: true) }
    static func edge(over field: RGB, hue: Hue, fraction: Double) -> RGB {
        field.mixed(with: sample(over: field, hue: hue, dark: true), fraction: 1 - fraction)
    }
}

struct SidebarSurfaceView: View {
    var hue: Hue
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        if reduceTransparency { (scheme == .dark ? SidebarSurface.opaque(hue: hue).color : Color.white) }
        else if scheme == .dark {
            ZStack {
                SidebarSurface.undercoat(hue).color.opacity(0.65)
                Color.white.opacity(0.06)
                hue.a.opacity(0.06)
                hue.worldBottomRGB.color.opacity(0.18)
            }
        } else { Color.white.opacity(0.45) }
    }
}
struct SidebarEdgeView: View {
    var hue: Hue
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        if scheme == .dark {
            ZStack {
                LinearGradient(colors: [SidebarSurface.undercoat(hue).color.opacity(0.65), .clear], startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.white.opacity(0.06), .clear], startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [hue.a.opacity(0.06), .clear], startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [hue.worldBottomRGB.color.opacity(0.18), .clear], startPoint: .leading, endPoint: .trailing)
            }
        }
    }
}
