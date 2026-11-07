import AppKit
import SwiftUI

struct RGB: Equatable {
    var r: Double
    var g: Double
    var b: Double
    var alpha: Double = 1
    init(_ hex: UInt32, alpha: Double = 1) {
        r = Double((hex >> 16) & 255) / 255; g = Double((hex >> 8) & 255) / 255; b = Double(hex & 255) / 255
        self.alpha = alpha
    }
    init(r: Double, g: Double, b: Double, alpha: Double = 1) { self.r = r; self.g = g; self.b = b; self.alpha = alpha }
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: alpha) }
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: alpha) }
    var saturation: Double {
        let top = max(r, g, b)
        return top == 0 ? 0 : (top - min(r, g, b)) / top
    }
    /// Preserve the hue and layer opacity while reserving contrast for text/status and pointer light.
    func limitedLuminance(_ ceiling: Double) -> RGB {
        guard luminance > ceiling else { return self }
        var low = 0.0, high = 1.0
        for _ in 0..<24 {
            let f = (low + high) / 2
            let c = RGB(r: r * f, g: g * f, b: b * f)
            if c.luminance > ceiling { high = f } else { low = f }
        }
        return RGB(r: r * low, g: g * low, b: b * low, alpha: alpha)
    }
    var luminance: Double {
        func linear(_ x: Double) -> Double { x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }
    func over(_ background: RGB, opacity: Double = 1) -> RGB {
        let a = alpha * opacity
        return RGB(r: r * a + background.r * (1 - a), g: g * a + background.g * (1 - a), b: b * a + background.b * (1 - a))
    }
    func mixed(with other: RGB, fraction: Double) -> RGB {
        let f = min(1, max(0, fraction))
        return RGB(r: r + (other.r - r) * f, g: g + (other.g - g) * f, b: b + (other.b - b) * f)
    }
}

func contrast(_ a: RGB, _ b: RGB) -> Double {
    (max(a.luminance, b.luminance) + 0.05) / (min(a.luminance, b.luminance) + 0.05)
}

struct Palette {
    var primary: RGB
    var secondary: RGB
    var tertiary: RGB
    var disabledText: RGB
    var hairline: RGB
    var glass: RGB
    var glassStroke: RGB
    var live: RGB
    var warn: RGB
    var danger: RGB
    var focus: RGB
    var night: RGB
    var sidebar: RGB

    static let dark = Palette(primary: RGB(0xFFFFFF), secondary: RGB(0xE4DEFB), tertiary: RGB(0xD4CCF2), disabledText: RGB(0xB3AADB),
                              hairline: RGB(0xFFFFFF, alpha: 0.12), glass: RGB(0xFFFFFF, alpha: 0.10), glassStroke: RGB(0xFFFFFF, alpha: 0.14),
                              live: RGB(0x5FE38A), warn: RGB(0xFFC067), danger: RGB(0xFFB3BB), focus: RGB(0xFFFFFF), night: RGB(0x3A1A7A), sidebar: RGB(0, alpha: 0.20))
    static let light = Palette(primary: RGB(0x1A1430), secondary: RGB(0x3D355E), tertiary: RGB(0x574F7A), disabledText: RGB(0x7A7398),
                               hairline: RGB(0x5B3AD0, alpha: 0.12), glass: RGB(0xFFFFFF, alpha: 0.62), glassStroke: RGB(0x5B3AD0, alpha: 0.14),
                               live: RGB(0x0F7A3D), warn: RGB(0x9A5200), danger: RGB(0xB3132B), focus: RGB(0x3A1FB0), night: RGB(0xEEE8FA), sidebar: RGB(0xFFFFFF, alpha: 0.45))
    static func resolve(dark: Bool, increasedContrast: Bool, reducedTransparency: Bool) -> Palette {
        var p = dark ? Self.dark : .light
        // Increase Contrast restores outlines.
        if increasedContrast { p.secondary = p.primary; p.tertiary = p.primary; p.glassStroke = RGB(dark ? 0xFFFFFF : 0x1A1430, alpha: 0.35) }
        if reducedTransparency { p.glass = RGB(dark ? 0x3A1A7A : 0xFFFFFF) }
        return p
    }
}

enum Ink {
    static func dynamic(_ name: String, _ value: @escaping (Palette) -> RGB) -> Color {
        Color(nsColor: NSColor(name: NSColor.Name("Murmury.\(name)"), dynamicProvider: { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let options = NSWorkspace.shared
            return value(Palette.resolve(dark: dark, increasedContrast: options.accessibilityDisplayShouldIncreaseContrast,
                                         reducedTransparency: options.accessibilityDisplayShouldReduceTransparency)).nsColor
        }))
    }
    static let primary = dynamic("primary", { $0.primary })
    static let secondary = dynamic("secondary", { $0.secondary })
    static let tertiary = dynamic("tertiary", { $0.tertiary })
    static let disabledText = dynamic("disabledText", { $0.disabledText })
    static let hairline = dynamic("hairline", { $0.hairline })
    static let panel = dynamic("glass", { $0.glass })
    static let glassStroke = dynamic("glassStroke", { $0.glassStroke })
    static let live = dynamic("live", { $0.live })
    static let warn = dynamic("warn", { $0.warn })
    static let danger = dynamic("danger", { $0.danger })
    static let focus = dynamic("focus", { $0.focus })
    static let night = dynamic("night", { $0.night })
    static let sidebar = dynamic("sidebar", { $0.sidebar })
    /// A colour with one value per appearance, for marks that must hold 3:1 on both.
    static func scheme(_ name: String, light: RGB, dark: RGB) -> Color {
        Color(nsColor: NSColor(name: NSColor.Name("Murmury.\(name)"), dynamicProvider: { appearance in
            (appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light).nsColor
        }))
    }
    /// The demo status dot: brand violet, lighter in dark so it holds 3:1 on the sidebar.
    static let demo = scheme("demo", light: RGB(0x8A4DF0), dark: RGB(0xD2BCFF))
    // Fixed lighting, reserved for art and labels on hue fills.
    static let porcelain = Color.white
    static let shade = Color.black
}

/// The action follows the union of visible art and measured copy; fading frames may overlap it.
enum PageLayout {
    static let sidebar: CGFloat = 232
    static let gutter: CGFloat = 40
    static let titlebarInset: CGFloat = 44
    static let bottomMargin: CGFloat = 24
    static let actionHeight: CGFloat = 140 // 112 face + 8 gap + 20 caption; replaces fixed 148 reserve.
    static let actionGap: CGFloat = 28
    static let glowApron: CGFloat = 20
    static let gap: CGFloat = 40
    static let visualAspect: CGFloat = 1.40

    struct Composition: Equatable {
        var region: CGRect
        var unit: CGRect
        var visual: CGRect
        var visibleArt: CGRect
        var copy: CGRect
        var action: CGRect
        var stack: CGRect { unit.union(action) }
    }

    /// The unit's height on tall windows: the copy gets all the room a 740 pt window allows, and
    /// larger windows centre a unit of this height instead of spreading title and action apart.
    static let unitCap: CGFloat = 520

    /// One grid for every screen and state: the title sits on the same line and the primary action
    /// at the same point everywhere (a head-pointer user never has to re-aim). The unit's height
    /// comes from the tallest hero and a shared copy reserve, not from each screen's copy; copy is
    /// top-aligned (notices grow downward) and the art keeps its visible bottom on the unit's bottom.
    static func composition(in size: CGSize, copyHeight: CGFloat? = nil, kind: HeroMask.Kind = .head, maxVisualWidth: CGFloat = 480) -> Composition {
        let inner = min(1120, max(0, size.width - 2 * gutter))
        let maxUnitHeight = max(0, size.height - titlebarInset - bottomMargin - actionGap - actionHeight)
        let mask = HeroMask.visibleBounds(kind: kind)
        let gridMask = HeroMask.Kind.allCases.map { HeroMask.visibleBounds(kind: $0).height }.max() ?? mask.height
        let desiredWidth = min(maxVisualWidth, max(340, (inner - gap) * 0.5))
        let visualWidth = max(340, min(desiredWidth, maxUnitHeight / (visualAspect * gridMask)))
        let visualHeight = visualAspect * visualWidth
        let copyWidth = min(520, max(360, inner - visualWidth - gap))
        let artHeight = mask.height * visualHeight
        let unitHeight = min(maxUnitHeight, max(gridMask * visualHeight, unitCap))
        let copyHeight = min(unitHeight, copyHeight ?? artHeight)
        let unitWidth = visualWidth + gap + copyWidth
        let stackHeight = unitHeight + actionGap + actionHeight
        let top = titlebarInset + (size.height - titlebarInset - bottomMargin - stackHeight) / 2
        let unit = CGRect(x: (size.width - unitWidth) / 2, y: top, width: unitWidth, height: unitHeight)
        let visual = CGRect(x: unit.minX, y: unit.maxY - mask.maxY * visualHeight, width: visualWidth, height: visualHeight)
        let art = CGRect(x: visual.minX + mask.minX * visualWidth, y: visual.minY + mask.minY * visualHeight,
                         width: mask.width * visualWidth, height: artHeight)
        let copy = CGRect(x: visual.maxX + gap, y: unit.minY, width: copyWidth, height: copyHeight)
        let action = CGRect(x: unit.midX - unitWidth / 2, y: unit.maxY + actionGap, width: unitWidth, height: actionHeight)
        let region = CGRect(x: unit.minX, y: titlebarInset, width: unitWidth, height: maxUnitHeight)
        return Composition(region: region, unit: unit, visual: visual, visibleArt: art, copy: copy, action: action)
    }
    static func copyRect(in size: CGSize) -> CGRect { composition(in: size).copy }
    static func copySamplePoints(in size: CGSize) -> [CGPoint] {
        let rect = copyRect(in: size)
        return (0..<4).flatMap { x in (0..<3).map { y in
            CGPoint(x: rect.minX + CGFloat(x) / 3 * rect.width, y: rect.minY + CGFloat(y) / 2 * rect.height)
        } }
    }
}

/// Accessibility-first scale: nothing below 13 points except chart axes.
enum TypeStyle {
    enum Size {
        static let display: CGFloat = 44, displayWide: CGFloat = 52, subtitle: CGFloat = 19
        static let rowTitle: CGFloat = 17, rowDetail: CGFloat = 14, body: CGFloat = 15, caption: CGFloat = 13
        static let axis: CGFloat = 11, chip: CGFloat = 13, button: CGFloat = 15, orbLabel: CGFloat = 18
        static let sidebarItem: CGFloat = 15, brand: CGFloat = 19, transcript: CGFloat = 24
        static let sheetTitle: CGFloat = 28, reading: CGFloat = 24, instruction: CGFloat = 22, stat: CGFloat = 28
    }
    static let displayTracking: CGFloat = -0.6
    static let subtitleLineSpacing: CGFloat = 4
    /// Scales smoothly from 44 pt at the minimum window to 52 pt on wide ones, no step.
    static func displaySize(width: CGFloat) -> CGFloat {
        let t = min(1, max(0, (width - 888) / (1368 - 888)))
        return (Size.display + (Size.displayWide - Size.display) * t).rounded()
    }
    static let subtitleMeasure: CGFloat = 440
    /// One anchor per screen, as CleanMyMac sets it: a large regular-weight title over medium rows.
    static func display(width: CGFloat) -> Font { .system(size: displaySize(width: width), weight: .regular) }
    static let subtitle = Font.system(size: Size.subtitle)
    /// Rows step down by weight as well as size: medium, not semibold, so the title leads.
    static let rowTitle = Font.system(size: Size.rowTitle, weight: .medium)
    static let rowDetail = Font.system(size: Size.rowDetail).monospacedDigit()
    static let body = Font.system(size: Size.body)
    static let caption = Font.system(size: Size.caption)
    static let axis = Font.system(size: Size.axis)
    static let chip = Font.system(size: Size.chip, weight: .medium)
    static let button = Font.system(size: Size.button, weight: .medium)
    static let orbLabel = Font.system(size: Size.orbLabel, weight: .semibold)
    static func sidebarItem(selected: Bool) -> Font { .system(size: Size.sidebarItem, weight: selected ? .semibold : .medium) }
    static let brand = Font.system(size: Size.brand, weight: .semibold)
    static let stat = Font.system(size: Size.stat, weight: .light).monospacedDigit()
    /// A state in a sheet or card (ready, working, done, warning, failed): body size, medium weight.
    static let status = Font.system(size: Size.body, weight: .medium)
    /// What to do right now, in a guided routine ("Look up, then back").
    static let instruction = Font.system(size: Size.instruction, weight: .medium)
    /// Text read aloud from the screen: larger and regular, for reading at arm's length.
    static let reading = Font.system(size: Size.reading)
    /// Recognised content; an empty transcript uses `body` instead.
    static let transcript = Font.system(size: Size.transcript, weight: .light)
    static let sheetTitle = Font.system(size: Size.sheetTitle, weight: .light)
    static let sectionTitle = Font.system(size: Size.rowTitle, weight: .semibold)
    static let chartTitle = Font.system(size: Size.caption, weight: .semibold)
    static let codeCaption = Font.system(size: Size.caption, design: .monospaced)

    /// A short multi-sentence line set one sentence per line, for when it can't fit on one line:
    /// it breaks between sentences instead of mid-phrase.
    static func sentenceLines(_ text: String) -> String {
        text.replacingOccurrences(of: ". ", with: ".\n")
    }
}

enum Space {
    static let xxs: CGFloat = 4, unit: CGFloat = 8, sm: CGFloat = 12, md: CGFloat = 16
    static let lg: CGFloat = 24, gutter: CGFloat = 32, xl: CGFloat = 40
}
/// Three radii: controls 12, cards 20, and 28 for a card that holds capsule buttons (20 + its 8 pt inset, so
/// the corners nest). Every surface stroke is one 0.5 pt `hairlineWidth`.
enum Radius { static let card: CGFloat = 20, control: CGFloat = 12, sheet: CGFloat = 24, notice: CGFloat = 28
    static let hairlineWidth: CGFloat = 0.5 }
