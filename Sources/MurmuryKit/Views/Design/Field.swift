import SwiftUI

struct FieldModel {
    struct Light {
        var color: RGB
        var opacity: Double
        var center: UnitPoint
        var radius: Double
    }
    struct Layers {
        var top: RGB
        var bottom: RGB
        var lights: [Light]
    }
    static func layers(hue: Hue, dark: Bool, time: Double = 0, size: CGSize? = nil, origin: CGPoint = .zero) -> Layers {
        let drift = 0.03 * sin(time * 2 * .pi / 18)
        if dark {
            let x = size.map { (origin.x + ($0.width - origin.x) * (0.27 + drift)) / $0.width } ?? (0.27 + drift)
            return Layers(top: hue.worldTopRGB, bottom: hue.worldBottomRGB, lights: [
                // One luminous, soft glow behind the hero, plus a faint brand-violet bloom top-left.
                // Broad on purpose in dark: a tighter bloom would drop the world under the owner's
                // brightness floor (median luminance 0.06); light mode carries the directional key.
                Light(color: hue.glowRGB, opacity: 0.50, center: UnitPoint(x: x, y: 0.40 + drift), radius: 0.40),
                Light(color: RGB(0x6D45D9), opacity: 0.12, center: UnitPoint(x: 0.04, y: 0.02), radius: 0.5),
                // Depth: a deeper, more saturated light pooling bottom-right, so the world isn't one flat violet.
                Light(color: hue.bRGB.limitedLuminance(0.09), opacity: 0.24, center: UnitPoint(x: 0.92 - drift, y: 0.98), radius: 0.55),
                // Tonal depth: the copy column sits in a quieter, deeper pool, so the hero's light is
                // concentrated and the text reads calmer (and with more contrast).
                Light(color: hue.worldTopRGB.limitedLuminance(0.035), opacity: 0.41, center: UnitPoint(x: 0.84, y: 0.52), radius: 0.5),
            ])
        }
        // In page coordinates, as in dark: both appearances light the same place relative to the hero.
        func pageX(_ f: Double) -> Double { size.map { (origin.x + ($0.width - origin.x) * f) / $0.width } ?? f }
        return Layers(top: RGB(0xF8F5FE), bottom: RGB(0xEEE8FA), lights: [
            Light(color: dark ? hue.bRGB : hue.aRGB, opacity: dark ? 0.46 : 0.26,
                  // Follows the hero (centre near (0.27, 0.40)), lit from the upper left like the studio key,
                  // and tight enough that the copy column stays clear of colour haze.
                  center: UnitPoint(x: pageX(0.25 + drift), y: 0.36 + drift), radius: 0.50),
            // A faint second light low in the field; in light mode it stays slight, so the bust's base
            // ends on its contact shadow rather than a pastel apron.
            Light(color: dark ? hue.aRGB : hue.bRGB, opacity: dark ? 0.16 : 0.07,
                  center: UnitPoint(x: pageX(0.18 - drift), y: 0.96 + drift), radius: 0.50),
            Light(color: RGB(dark ? 0x5C1FB3 : 0xC9B8F5), opacity: dark ? 0.30 : 0.35,
                  center: UnitPoint(x: 0.02, y: 0.02), radius: 0.45),
        ])
    }
    static func sample(at point: CGPoint, size: CGSize, hue: Hue, dark: Bool, time: Double = 0, origin: CGPoint = .zero, pointer: CGPoint? = nil, increasedContrast: Bool = false, reduceMotion: Bool = false) -> RGB {
        let model = layers(hue: hue, dark: dark, time: time, size: size, origin: origin)
        var result = model.top.mixed(with: model.bottom, fraction: point.y / size.height)
        for light in model.lights {
            let distance = hypot(point.x - light.center.x * size.width, point.y - light.center.y * size.height)
            let attenuation = max(0, 1 - distance / (light.radius * max(size.width, size.height)))
            result = light.color.over(result, opacity: light.opacity * attenuation)
        }
        if let pointer {
            result = PointerLightSpec.sample(over: result, at: point, pointer: pointer, size: size, hue: hue, dark: dark,
                                             increasedContrast: increasedContrast, reduceMotion: reduceMotion)
        }
        return result
    }
}

/// Rendering and numerical sampling share every layer, centre and opacity.
struct Aura: View {
    var hue: Hue
    var sampleTime: Double? = nil
    var pageOrigin: CGFloat = 0
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        #if DEBUG
        let _ = BodyCounters.record("Aura")
        #endif
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || sampleTime != nil)) { context in
            GeometryReader { geometry in
                let time = sampleTime ?? (reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 18))
                let layers = FieldModel.layers(hue: hue, dark: scheme == .dark, time: time, size: geometry.size, origin: CGPoint(x: pageOrigin, y: 0))
                ZStack {
                    LinearGradient(colors: [layers.top.color, layers.bottom.color], startPoint: .top, endPoint: .bottom)
                    ForEach(layers.lights.indices, id: \.self) { i in
                        let light = layers.lights[i]
                        RadialGradient(colors: [light.color.color.opacity(light.opacity), light.color.color.opacity(0)],
                                       center: light.center, startRadius: 0, endRadius: light.radius * max(geometry.size.width, geometry.size.height))
                    }
                }
            }
        }
        .animation(Motion.section(reduceMotion), value: hue)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
