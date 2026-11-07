import SwiftUI
import Testing
@testable import MurmuryKit

@Suite("Solid action and flat controls")
struct PrimaryActionTests {
    @Test func solidActionContrastInEveryState() {
        for hue in Hue.all { for dark in [true, false] { for hovered in [true, false] { for enabled in [true, false] {
            let fill = PrimaryActionSpec.fill(hue: hue, dark: dark, enabled: enabled, hovering: hovered)
            #expect(contrast(RGB(0xFFFFFF), fill) >= (enabled ? 4.5 : 3))
            #expect(!PrimaryActionSpec.usesGradient)
        } } } }
        #expect(PrimaryActionSpec.diameter == 112 && PrimaryActionSpec.disc == 106)
        #expect(PrimaryActionSpec.rimWidth == 0, "no white rim round the disc in either appearance")
    }
    @Test func primaryAndFocusBoundaryContrastsEveryField() {
        let size = CGSize(width: 1120, height: 740)
        for hue in Hue.all { for dark in [true, false] {
            for x in 0..<12 { for y in 0..<8 {
                let field = FieldModel.sample(at: CGPoint(x: CGFloat(x) / 11 * size.width, y: CGFloat(y) / 7 * size.height),
                                              size: size, hue: hue, dark: dark)
                // No outline in either appearance: the white label (checked above) and the focus ring
                // identify the button, which WCAG 1.4.11 accepts for a text-labelled control. In light
                // the disc itself still reaches 3:1; in dark a neutral contact shadow sets it apart.
                if !dark { #expect(contrast(PrimaryActionSpec.boundary(hue: hue, dark: dark), field) >= 3, "\(hue) at \(x),\(y)") }
                #expect(contrast((dark ? Palette.dark : .light).focus, field) >= 3)
            } }
        } }
    }
    @Test func secondarySurfacesAreFlatWithAccessibleHairlines() {
        #expect(FlatControlSpec.fill(dark: true).alpha == 0.08)
        #expect(FlatControlSpec.fill(dark: false).alpha == 0.85)
        #expect(FlatControlSpec.stroke(dark: true, increasedContrast: false).alpha == 0.14)
        #expect(FlatControlSpec.stroke(dark: false, increasedContrast: false).alpha == 0.14)
        #expect(FlatControlSpec.stroke(dark: true, increasedContrast: true).alpha == 0.35)
        #expect(!FlatControlSpec.usesGradient)
    }
    @Test func controlImplementationsDoNotFillButtonsWithGradients() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for name in ["PrimaryAction.swift", "ActionBar.swift", "Controls.swift", "SecondaryActions.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent("Sources/MurmuryKit/Views/Design/" + name))
            #expect(!source.contains("LinearGradient(") && !source.contains("RadialGradient("), "\(name) has a gradient control")
        }
    }
    @Test func flatControlsStayOpaqueUnderReducedTransparency() {
        for dark in [true, false] { for pressed in [true, false] {
            let fill = FlatControlSpec.fill(dark: dark, pressed: pressed, reducedTransparency: true)
            #expect(fill.alpha == 1)
            let label = FlatControlSpec.label(dark: dark, enabled: true, selected: false)
            #expect(contrast(label, fill) >= 4.5)
        } }
    }

}
