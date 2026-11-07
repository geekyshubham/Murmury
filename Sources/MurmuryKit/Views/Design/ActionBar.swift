import SwiftUI

/// A measured action block, placed below the visible composition.
struct ActionBar<Action: View>: View {
    var hint: String? = nil
    @ViewBuilder var action: Action
    var body: some View {
        VStack(spacing: Space.unit) {
            action
            if let hint { Text(hint).font(TypeStyle.caption).foregroundStyle(Ink.secondary) }
        }
        .frame(maxWidth: .infinity)
        .frame(height: PageLayout.actionHeight, alignment: .top)
        .accessibilitySortPriority(1)
    }
}

struct OrbButton: View {
    var title: String
    var hue: Hue
    var active = false
    var disabledReason: String? = nil
    var caption: String? = nil
    var action: () -> Void
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        VStack(spacing: Space.unit) {
            Button(action: action) { Text(title) }
                .buttonStyle(OrbStyle(hue: hue, active: active))
            if !enabled {
                Text(disabledReason ?? "Unavailable right now").font(TypeStyle.caption).foregroundStyle(Ink.secondary)
                    .multilineTextAlignment(.center).lineLimit(2).accessibilityHidden(true)
            } else if let caption {
                Text(caption).font(TypeStyle.caption).foregroundStyle(Ink.secondary).lineLimit(2).multilineTextAlignment(.center).accessibilityHidden(true)
            }
        }
        .accessibilityHint(!enabled ? (disabledReason ?? "Unavailable right now") : (caption ?? ""))
    }
}

/// Click to start and click again to save (a spoken click works too); or hold while you move.
struct RecordOrb: View {
    var hue: Hue
    var capture: CaptureController
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    @State private var pressing = false
    @State private var hovering = false
    @State private var focusID = UUID()
    @GestureState private var gestureDown = false
    static func caption(ownership: CaptureController.Ownership, autoCapturing: Bool, secondsLeft: Int) -> String {
        switch ownership {
        case .none: return autoCapturing ? "Auto-capturing" : "Click, say “click”, ⌘R or hold Space"
        case .held: return "Recording · release to save"
        case .toggled: return "Recording · click or say “click” to save · \(secondsLeft) s left"
        }
    }
    var body: some View {
        TimelineView(.periodic(from: .now, by: capture.ownership == .none ? 3600 : 0.25)) { context in
            let elapsed = capture.startedAt.map { max(0, ProcessInfo.processInfo.systemUptime - $0) } ?? 0
            let fraction = min(1, elapsed / Segmenter.maxHoldSeconds)
            let left = max(0, Int((Segmenter.maxHoldSeconds - elapsed).rounded(.up)))
            VStack(spacing: Space.unit) {
                // A clicked take is saved by the next click, so the button says so; a held take saves on release.
                OrbFace(title: capture.ownership == .toggled ? "Save" : (capture.segmenter.isCapturing ? "Recording" : "Record"), hue: hue,
                        active: capture.segmenter.isCapturing, pressed: capture.ownership != .none, enabled: enabled, hovering: enabled && (hovering || focused))
                    .overlay {
                        if capture.ownership != .none {
                            // Time left in the take: a static full ring under Reduce Motion; the caption counts down.
                            // Drawn on the disc's own edge, inside it: one ring, not one more ring around it.
                            Circle().trim(from: 0, to: reduceMotion ? 1 : 1 - fraction)
                                .stroke(Ink.porcelain.opacity(0.92), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                .rotationEffect(.degrees(-90)).padding((PrimaryActionSpec.diameter - PrimaryActionSpec.disc) / 2 + 5)
                                .animation(reduceMotion ? nil : .linear(duration: 0.25), value: fraction)
                                .accessibilityHidden(true)
                        }
                    }
                    .hoverLift(shape: Circle(), hue: hue, lift: 2)
                    .onHover { hovering = $0 }
                    .contentShape(Circle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .updating($gestureDown) { _, down, _ in down = true }
                        .onChanged { _ in
                            guard !pressing else { return }
                            pressing = true
                            if enabled { capture.pointerDown() }
                        }
                        .onEnded { _ in
                            guard pressing else { return }
                            pressing = false
                            capture.pointerUp()
                        })
                    .onChange(of: gestureDown) { _, down in
                        if !down, pressing { pressing = false; capture.pointerCancel() }
                    }
                    .focusable().focused($focused).focusEffectDisabled()
                    .onChange(of: focused) { _, isFocused in FocusRegistry.shared.update(focusID, focused: isFocused) }
                    .overlay(Circle().strokeBorder(focused ? Ink.focus : .clear, lineWidth: 2.5).padding(-12))
                    .onKeyPress(.return) { if enabled { capture.toggle() }; return .handled }
                    .onKeyPress(.space) { if enabled { capture.toggle() }; return .handled }
                    .accessibilityElement()
                    .accessibilityLabel(capture.ownership == .none ? "Record" : (capture.ownership == .toggled ? "Save take" : "Recording"))
                    .accessibilityValue(capture.ownership == .toggled ? "\(left) seconds left" : "")
                    .accessibilityHint(capture.disabledReason ?? (capture.ownership == .none ? "Records one take of up to \(Int(Segmenter.maxHoldSeconds)) seconds" : "Saves the take"))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { if enabled { capture.toggle() } }
                Text(enabled ? Self.caption(ownership: capture.ownership, autoCapturing: capture.segmenter.isCapturing, secondsLeft: left)
                             : (capture.disabledReason ?? "Recording unavailable"))
                    .font(TypeStyle.caption).monospacedDigit().foregroundStyle(Ink.secondary)
                    .accessibilityHidden(true)
            }
        }
        .onDisappear {
            capture.release(.pointer)
            FocusRegistry.shared.remove(focusID)
        }
    }
}

/// During a clicked (toggled) take: the whole content area is a stop target, so a spoken click
/// saves the take even after the pointer drifted off the orb. Hidden from accessibility (the orb
/// exposes Stop) and never takes keyboard focus.
struct StopTarget: View {
    var action: () -> Void
    var body: some View {
        // The instruction lives in the record button's caption ("click or say “click” to save"), so
        // nothing floats over the page's links.
        Rectangle().fill(Color.clear).contentShape(Rectangle())
            .onTapGesture(perform: action)
            .accessibilityHidden(true)
    }
}

private struct OrbStyle: ButtonStyle {
    var hue: Hue
    var active: Bool
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    @Environment(\.isFocused) private var focused
    func makeBody(configuration: Configuration) -> some View {
        OrbFace(hue: hue, active: active, pressed: configuration.isPressed, enabled: enabled, label: configuration.label, hovering: enabled && (hovering || focused))
            .contentShape(Circle())
            .onHover { hovering = $0 }
            .fieldFocus(radius: OrbMetrics.diameter / 2 + 6)
            .hoverLift(shape: Circle(), hue: hue, lift: 2)
    }
}

/// Compatibility metrics for the existing action/record APIs. The solid face has no radial glow.
enum OrbMetrics {
    static let diameter: CGFloat = 112
    static let glowFrame: CGFloat = 224
    static let glowRadius: CGFloat = 76
    static let orbCentreFromBarTop: CGFloat = 62
    static func deep(_ hue: Hue) -> RGB { hue.orbRGB.mixed(with: RGB(0x000000), fraction: 0.18) }
}

/// Record and action callers share one flat face.
struct OrbFace<Label: View>: View {
    var hue: Hue
    var active: Bool
    var pressed: Bool
    var enabled: Bool
    var label: Label
    var hovering = false
    var sampleTime: Double? = nil
    var body: some View {
        PrimaryActionFace(hue: hue, active: active, pressed: pressed, enabled: enabled, label: label, hovering: hovering, sampleTime: sampleTime)
    }
}
extension OrbFace where Label == Text {
    init(title: String, hue: Hue, active: Bool, pressed: Bool, enabled: Bool, hovering: Bool = false) {
        self.init(hue: hue, active: active, pressed: pressed, enabled: enabled, label: Text(title), hovering: hovering)
    }
}
