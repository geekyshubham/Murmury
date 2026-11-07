import SwiftUI

/// The native controls remain responsible for keyboard and accessibility semantics.
private struct FieldFocus: ViewModifier {
    var radius: CGFloat
    @Environment(\.isFocused) private var focused
    @State private var id = UUID()
    func body(content: Content) -> some View {
        content.focusEffectDisabled()
            // Space capture leaves focused controls alone (see SpaceKeyMonitor).
            .onChange(of: focused) { _, isFocused in FocusRegistry.shared.update(id, focused: isFocused) }
            .onDisappear { FocusRegistry.shared.remove(id) }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(focused ? Ink.focus : .clear, lineWidth: 2.5)
                    .padding(-3).allowsHitTesting(false).accessibilityHidden(true)
            }
    }
}
extension View {
    func fieldFocus(radius: CGFloat = Radius.control) -> some View { modifier(FieldFocus(radius: radius)) }
}

struct GlowToggleStyle: ToggleStyle {
    var hue: Hue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: Space.sm) {
                configuration.label.foregroundStyle(enabled ? Ink.primary : Ink.tertiary)
                Spacer(minLength: Space.unit)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(configuration.isOn ? AnyShapeStyle(hue.actionRGB.color) : AnyShapeStyle(Ink.panel))
                    Capsule().strokeBorder(Ink.glassStroke, lineWidth: Radius.hairlineWidth)
                    Circle().fill(Ink.porcelain).frame(width: 22, height: 22).padding(2)
                }
                .frame(width: 44, height: 26)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(ToggleButtonStyle())
        .animation(Motion.spring(reduceMotion), value: configuration.isOn)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch)
        }
    }
    private struct ToggleButtonStyle: ButtonStyle {
        @Environment(\.isEnabled) private var enabled
        func makeBody(configuration: Configuration) -> some View {
            configuration.label.fieldFocus().hoverLift(shape: RoundedRectangle(cornerRadius: Radius.control), pressed: configuration.isPressed)
        }
    }
}

enum SegmentSelection {
    static func nextIndex(current: Int, count: Int, forward: Bool) -> Int? {
        guard count > 0 else { return nil }
        return min(count - 1, max(0, current + (forward ? 1 : -1)))
    }
}

struct CapsuleSegmented<Value: Hashable>: View {
    var label: String
    var values: [Value]
    @Binding var selection: Value
    var hue: Hue
    var title: (Value) -> String
    @Namespace private var highlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(values, id: \.self) { value in
                Button { selection = value } label: {
                    Text(title(value)).font(TypeStyle.button)
                        .foregroundStyle(selection == value ? Ink.porcelain : Ink.primary)
                        .frame(minWidth: 72, minHeight: 36)
                        .padding(.horizontal, Space.unit)
                        .background {
                            if selection == value {
                                if reduceMotion { Capsule().fill(hue.actionRGB.color).frame(height: 28).transition(.opacity) }
                                else { Capsule().fill(hue.actionRGB.color).frame(height: 28).matchedGeometryEffect(id: "segment", in: highlight) }
                            }
                        }
                }
                .buttonStyle(SegmentButtonStyle())
                .accessibilityAddTraits(selection == value ? .isSelected : [])
            }
        }
        .padding(.horizontal, Space.xxs)
        .background { Capsule().fill(Ink.panel).frame(height: 36) }
        .overlay(Capsule().strokeBorder(Ink.glassStroke, lineWidth: Radius.hairlineWidth).frame(height: 36))
        .animation(Motion.spring(reduceMotion), value: selection)
        .accessibilityElement(children: .contain).accessibilityLabel(label)
        .onMoveCommand { direction in
            guard let current = values.firstIndex(of: selection) else { return }
            switch direction {
            case .left, .up: if let i = SegmentSelection.nextIndex(current: current, count: values.count, forward: false) { selection = values[i] }
            case .right, .down: if let i = SegmentSelection.nextIndex(current: current, count: values.count, forward: true) { selection = values[i] }
            default: break
            }
        }
    }
    private struct SegmentButtonStyle: ButtonStyle {
        @Environment(\.isEnabled) private var enabled
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .frame(minHeight: 44).contentShape(Capsule()).fieldFocus(radius: 24)
                .hoverLift(shape: Capsule(), pressed: configuration.isPressed)
        }
    }
}

struct FieldTextFieldStyle: TextFieldStyle {
    /// A visible label inside the field's leading edge, so the field never relies on its placeholder.
    var label: String? = nil
    func _body(configuration: TextField<Self._Label>) -> some View {
        HStack(spacing: 10) {
            if let label { Text(label).font(TypeStyle.body.weight(.semibold)).foregroundStyle(Ink.secondary).accessibilityHidden(true) }
            configuration.textFieldStyle(.plain).font(TypeStyle.body).foregroundStyle(Ink.primary)
        }
            .padding(.horizontal, Space.md).frame(height: 44)
            .background(Ink.panel, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            // An input's edge has to be found before it is read: 1 pt at 3:1 or more, not the hairline.
            .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Ink.tertiary.opacity(0.8), lineWidth: 1))
            .fieldFocus()
    }
}

/// A lit glass capsule: soft top highlight, gentle depth, no outline (Increase Contrast adds one).
struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(TypeStyle.button)
            .foregroundStyle(enabled ? Ink.primary : Ink.tertiary)
            .padding(.horizontal, 18).frame(minWidth: 44, minHeight: 40)
            .background { FlatCapsule(pressed: configuration.isPressed && enabled, hovering: hovering && enabled) }
            .fieldFocus(radius: 24)
            .hoverLift(shape: Capsule(), pressed: configuration.isPressed)
            .frame(minHeight: 44).contentShape(Capsule())
            .onHover { hovering = $0 }
            .animation(Motion.hover, value: hovering)
    }
}
extension ButtonStyle where Self == QuietButtonStyle {
    static var quiet: QuietButtonStyle { QuietButtonStyle() }
}

/// A sheet's one primary action: the round action's solid fill on a capsule, white label, no rim.
struct SolidButtonStyle: ButtonStyle {
    var hue: Hue
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        let fill = PrimaryActionSpec.fill(hue: hue, dark: scheme == .dark, enabled: enabled, hovering: hovering && enabled)
        configuration.label.font(TypeStyle.button.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 20).frame(minWidth: 44, minHeight: 40)
            .background(Capsule().fill(fill.color).shadow(color: .black.opacity(enabled ? 0.18 : 0), radius: 6, y: 3))
            .fieldFocus(radius: 24)
            .hoverLift(shape: Capsule(), pressed: configuration.isPressed)
            .frame(minHeight: 44).contentShape(Capsule())
            .onHover { hovering = $0 }
            .animation(Motion.hover, value: hovering)
    }
}

enum FlatControlSpec {
    static let usesGradient = false
    static func label(dark: Bool, enabled: Bool, selected: Bool) -> RGB {
        let palette = dark ? Palette.dark : .light
        return selected ? RGB(0xFFFFFF) : (enabled ? palette.primary : palette.tertiary)
    }
    static func fill(dark: Bool, pressed: Bool = false, hovering: Bool = false, reducedTransparency: Bool = false) -> RGB {
        // Dark capsules stay close to their surface so white labels keep 4.5:1 on lit notices too.
        let fill = RGB(0xFFFFFF, alpha: min(1, (dark ? 0.08 : 0.85) + (pressed ? 0.10 : (hovering ? 0.06 : 0))))
        return reducedTransparency ? fill.over(dark ? Palette.dark.night : RGB(0xFFFFFF)) : fill
    }
    static func stroke(dark: Bool, increasedContrast: Bool) -> RGB {
        // Light strokes take the brand violet, not grey ink, so they read as part of the lilac world.
        increasedContrast ? RGB(dark ? 0xFFFFFF : 0x1A1430, alpha: 0.35) : RGB(dark ? 0xFFFFFF : 0x5B3AD0, alpha: dark ? 0.14 : 0.14)
    }
}

/// Flat shared surface; state changes affect only solid color and a hairline.
struct FlatCapsule: View {
    var pressed = false
    var hovering = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        Capsule().fill(FlatControlSpec.fill(dark: scheme == .dark, pressed: pressed, hovering: hovering, reducedTransparency: reduceTransparency).color)
            .overlay(Capsule().strokeBorder(FlatControlSpec.stroke(dark: scheme == .dark, increasedContrast: contrast == .increased).color, lineWidth: 0.5))
            .background {
                if scheme == .dark, pressed || hovering {
                    Capsule().fill(Ink.night.opacity(pressed ? 0.55 : 0.25))
                }
            }
    }
}

struct ChipStyle: ButtonStyle {
    var selected: Bool
    var hue: Hue
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(TypeStyle.chip)
            .foregroundStyle(selected ? Ink.porcelain : (enabled ? Ink.primary : Ink.tertiary))
            .padding(.horizontal, 14).frame(minWidth: 44, minHeight: 40)
            .background {
                if selected {
                    Capsule().fill(hue.actionRGB.color)
                        .overlay(Capsule().strokeBorder(Ink.glassStroke, lineWidth: 0.5))
                } else {
                    FlatCapsule(pressed: configuration.isPressed && enabled, hovering: hovering && enabled)
                }
            }
            .fieldFocus(radius: 24).hoverLift(shape: Capsule(), hue: hue, pressed: configuration.isPressed).frame(minHeight: 44).contentShape(Capsule())
            .onHover { hovering = $0 }
    }
}

/// A list row. `showsSelection: false` leaves the selected surface to the caller (the sidebar draws one card).
struct RowButtonStyle: ButtonStyle {
    var selected = false
    var showsSelection = true
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        let fill = (showsSelection && selected) || ((hovering || configuration.isPressed) && !selected)
        configuration.label.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, Space.unit)
            .foregroundStyle(enabled ? Ink.primary : Ink.tertiary)
            .background(Ink.primary.opacity(fill ? (configuration.isPressed ? 0.08 : 0.05) : 0), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .contentShape(Rectangle()).fieldFocus()
            .hoverLift(shape: RoundedRectangle(cornerRadius: Radius.control), pressed: configuration.isPressed)
            .onHover { hovering = $0 }
    }
}

/// Drawn on the field, backed by a native Slider for keys, VoiceOver and value adjustment.
struct FieldSlider: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double
    var tint: Color
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        GeometryReader { geometry in
            let travel = max(0, geometry.size.width - 20)
            let fraction = min(1, max(0, (value - range.lowerBound) / (range.upperBound - range.lowerBound)))
            ZStack(alignment: .leading) {
                Capsule().fill(Ink.panel).frame(height: 6)
                Capsule().fill(enabled ? tint : Ink.disabledText).frame(width: 10 + travel * fraction, height: 6)
                Circle().fill(enabled ? Ink.primary : Ink.disabledText).frame(width: 20, height: 20).offset(x: travel * fraction)
                Slider(value: $value, in: range, step: step) { Text(title) }
                    .labelsHidden().frame(height: 44).contentShape(Rectangle()).opacity(0.001).allowsHitTesting(true).focused($focused).focusEffectDisabled()
            }
            .frame(height: 44)
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(focused ? Ink.focus : .clear, lineWidth: 2.5).padding(-3))
        }
        .frame(minWidth: 80, minHeight: 44, maxHeight: 44)
    }
}

struct FieldDisclosure<Label: View, Content: View>: View {
    @Binding var isExpanded: Bool
    @ViewBuilder var content: Content
    @ViewBuilder var label: Label
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: Space.unit) {
            Button { withAnimation(Motion.spring(reduceMotion)) { isExpanded.toggle() } } label: {
                HStack {
                    label
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down").accessibilityHidden(true)
                }
            }
            .buttonStyle(.quiet).accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            if isExpanded { content }
        }
    }
}
extension FieldDisclosure where Label == Text {
    init(_ title: String, isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self.init(isExpanded: isExpanded, content: content, label: { Text(title) })
    }
}

#if DEBUG
struct ControlsGallery: View {
    @State private var on = true
    @State private var name = "nod"
    @State private var choice = "Pointer"
    var body: some View {
        VStack(spacing: Space.md) {
            Toggle("Motion control", isOn: $on).toggleStyle(GlowToggleStyle(hue: .control))
            CapsuleSegmented(label: "Mode", values: ["Pointer", "Scroll"], selection: $choice, hue: .control, title: { $0 })
            TextField("Gesture name", text: $name).textFieldStyle(FieldTextFieldStyle())
            HStack {
                Button("Quiet action") {}.buttonStyle(.quiet)
                Button("Unavailable") {}.buttonStyle(.quiet).disabled(true)
                Button("Preset") {}.buttonStyle(ChipStyle(selected: true, hue: .teach))
            }
            Button("Dataset row") {}.buttonStyle(RowButtonStyle(selected: true))
        }
        .padding(Space.gutter).frame(width: 600).background { Aura(hue: .control, sampleTime: 0) }
    }
}
#endif
