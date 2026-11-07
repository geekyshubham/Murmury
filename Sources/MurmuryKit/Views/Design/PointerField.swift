import AppKit
import QuartzCore
import SwiftUI

struct PointerParallax {
    static let tau = 0.12
    private(set) var value = CGPoint.zero
    static func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x.isFinite ? min(1, max(-1, point.x)) : 0,
                y: point.y.isFinite ? min(1, max(-1, point.y)) : 0)
    }
    mutating func advance(target: CGPoint?, dt: Double, reduceMotion: Bool) -> CGPoint {
        if reduceMotion { value = .zero; return value }
        let target = target.map(Self.clamped) ?? .zero
        let amount = 1 - exp(-max(0, dt.isFinite ? dt : 0) / Self.tau)
        value.x += (target.x - value.x) * amount
        value.y += (target.y - value.y) * amount
        return value
    }
}

struct PointerState: Equatable {
    var point = CGPoint.zero // -1...1; positive y is up, independent of AppKit's view orientation.
    var inside = false
    var hasInfluence: Bool { inside || abs(point.x) + abs(point.y) > 0.001 }
}

/// Shared by native layers and renderer threads. Deliberately not Observable: cursor input never
/// invalidates SwiftUI page bodies, and never enters the motion/pointer-control pipeline.
final class PointerSignal: @unchecked Sendable {
    static let shared = PointerSignal()
    private let lock = NSLock()
    private var normalized: CGPoint?
    private var inside = false
    private var override: CGPoint?
    private var motion = PointerParallax()
    private var lastRead: Double?
    private var moves = 0
    var movementCount: Int { lock.withLock { moves } }
    func setOverride(_ point: CGPoint?) { lock.withLock { override = point } }
    func update(normalized point: CGPoint, inside: Bool, at time: Double) {
        lock.withLock {
            if normalized != point { moves += 1 }
            normalized = point; self.inside = inside
        }
    }
    func snapshot(at time: Double = CACurrentMediaTime(), reduceMotion: Bool = false) -> PointerState {
        lock.withLock {
            let dt = max(0, time - (lastRead ?? (time - 1.0 / 60)))
            lastRead = max(lastRead ?? time, time)
            if reduceMotion { _ = motion.advance(target: nil, dt: dt, reduceMotion: true); return PointerState() }
            func vector(_ p: CGPoint) -> CGPoint { PointerParallax.clamped(CGPoint(x: 2 * p.x - 1, y: 1 - 2 * p.y)) }
            if let override { return PointerState(point: vector(override), inside: true) }
            let point = motion.advance(target: inside ? normalized.map(vector) : nil, dt: dt, reduceMotion: false)
            return PointerState(point: point, inside: inside)
        }
    }
}

enum PointerLightSpec {
    static let diameter: CGFloat = 560
    static func color(hue: Hue, dark: Bool) -> RGB {
        // A saturated light within the tested luminance budget; alpha stays at the specified value.
        dark ? hue.aRGB.limitedLuminance(0.10) : hue.aRGB
    }
    static func opacity(pointer: CGPoint, size: CGSize, dark: Bool, increasedContrast: Bool = false) -> Double {
        let page = CGSize(width: max(1, size.width - PageLayout.sidebar), height: size.height)
        let copyLeft = PageLayout.sidebar + PageLayout.copyRect(in: page).minX
        let overCopy = pointer.x * size.width >= copyLeft
        return (dark ? 0.14 : 0.10) * (overCopy ? 0.5 : 1) * (increasedContrast ? 0.5 : 1)
    }
    static func sample(over base: RGB, at point: CGPoint, pointer: CGPoint, size: CGSize, hue: Hue, dark: Bool,
                       increasedContrast: Bool = false, reduceMotion: Bool = false) -> RGB {
        guard !reduceMotion else { return base }
        let pointer = CGPoint(x: min(1, max(0, pointer.x)), y: min(1, max(0, pointer.y)))
        let distance = hypot(point.x - pointer.x * size.width, point.y - pointer.y * size.height)
        let attenuation = max(0, 1 - distance / (diameter / 2))
        return color(hue: hue, dark: dark).over(base, opacity: opacity(pointer: pointer, size: size, dark: dark, increasedContrast: increasedContrast) * attenuation)
    }
}

struct PointerLightView: NSViewRepresentable {
    var hue: Hue
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    func makeNSView(context: Context) -> PointerLightNativeView { PointerLightNativeView() }
    func updateNSView(_ view: PointerLightNativeView, context: Context) {
        view.configure(hue: hue, dark: scheme == .dark, reduceMotion: reduceMotion, increasedContrast: contrast == .increased)
    }
}

final class PointerLightNativeView: NSView {
    let signal: PointerSignal
    private let light = CAGradientLayer()
    private var tracking: NSTrackingArea?
    private var link: CADisplayLink?
    private var tickTarget: TickTarget?
    private var preferences: NSObjectProtocol?
    private var hue = Hue.control
    private var dark = true
    private var reduceMotion = false
    private var increasedContrast = false
    private(set) var positionUpdateCount = 0
    override var isFlipped: Bool { true }
    init(signal: PointerSignal = .shared) {
        self.signal = signal
        super.init(frame: .zero)
        wantsLayer = true; layer?.masksToBounds = true
        light.type = .radial; light.startPoint = CGPoint(x: 0.5, y: 0.5); light.endPoint = CGPoint(x: 1, y: 1)  // radial radii come from both axes: (1, 0.5) gave a zero-height ellipse that tinted the whole square
        light.locations = [0, 1]
        light.bounds = CGRect(x: 0, y: 0, width: PointerLightSpec.diameter, height: PointerLightSpec.diameter)
        layer?.addSublayer(light)
        setAccessibilityElement(false)
        preferences = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                                                         object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                self.increasedContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
                self.updateLight(at: CACurrentMediaTime())
            }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        link?.invalidate()
        if let preferences { NSWorkspace.shared.notificationCenter.removeObserver(preferences) }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func configure(hue: Hue, dark: Bool, reduceMotion: Bool, increasedContrast: Bool) {
        self.hue = hue; self.dark = dark; self.reduceMotion = reduceMotion; self.increasedContrast = increasedContrast
        updateLight(at: CACurrentMediaTime())
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        tracking = area; addTrackingArea(area)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate(); link = nil
        guard let window else { tickTarget = nil; return }
        window.acceptsMouseMovedEvents = true
        let proxy = TickTarget(); proxy.owner = self; tickTarget = proxy
        let display = displayLink(target: proxy, selector: #selector(TickTarget.tick(_:)))
        display.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        display.add(to: .main, forMode: .common); link = display
    }
    @MainActor private final class TickTarget: NSObject {
        weak var owner: PointerLightNativeView?
        @objc func tick(_ sender: CADisplayLink) { owner?.pollScreenLocation(NSEvent.mouseLocation, at: CACurrentMediaTime()) }
    }
    /// Display-link polling observes warps and drags even when no mouseMoved event was posted.
    func pollScreenLocation(_ location: CGPoint, at time: Double) {
        guard let window, window.isVisible, !window.isMiniaturized, !isHiddenOrHasHiddenAncestor else { return }
        let local = convert(window.convertPoint(fromScreen: location), from: nil)
        process(local: local, inside: bounds.contains(local), at: time)
    }
    private func process(local: CGPoint, inside: Bool, at time: Double) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        process(normalized: CGPoint(x: local.x / bounds.width, y: local.y / bounds.height), inside: inside, at: time)
    }
    func process(normalized: CGPoint, inside: Bool, at time: Double) {
        signal.update(normalized: normalized, inside: inside, at: time)
        updateLight(at: time)
    }
    private func event(_ event: NSEvent, inside: Bool) { process(local: convert(event.locationInWindow, from: nil), inside: inside, at: CACurrentMediaTime()) }
    override func mouseMoved(with event: NSEvent) { self.event(event, inside: bounds.contains(convert(event.locationInWindow, from: nil))) }
    override func mouseEntered(with event: NSEvent) { self.event(event, inside: true) }
    override func mouseExited(with event: NSEvent) { self.event(event, inside: false) }
    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func rightMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func otherMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    func updateLight(at time: Double) {
        let state = signal.snapshot(at: time, reduceMotion: reduceMotion)
        let point = CGPoint(x: (state.point.x + 1) / 2, y: (1 - state.point.y) / 2)
        let strength = PointerLightSpec.opacity(pointer: point, size: bounds.size, dark: dark, increasedContrast: increasedContrast)
        let color = PointerLightSpec.color(hue: hue, dark: dark)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.35)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        light.isHidden = reduceMotion
        light.opacity = state.inside ? 1 : Float(min(1, (abs(state.point.x) + abs(state.point.y)) * 3))
        light.colors = [color.nsColor.withAlphaComponent(strength).cgColor, color.nsColor.withAlphaComponent(0).cgColor]
        light.position = CGPoint(x: point.x * bounds.width, y: point.y * bounds.height)
        CATransaction.commit()
        positionUpdateCount += 1
    }
}

enum HeroPointerSpec {
    static func product(point: CGPoint, reduceMotion: Bool) -> (yaw: Double, pitch: Double) {
        let p = reduceMotion ? .zero : PointerParallax.clamped(point)
        return (7 * Double(p.x) * .pi / 180, 4.5 * Double(p.y) * .pi / 180)
    }
}

struct HoverLiftState: Equatable {
    var offset: CGFloat = 0
    var scale: CGFloat = 1
    var glow: Double = 0
    var fill: Double = 0
    static func make(hovered: Bool, focused: Bool, pressed: Bool, enabled: Bool, reduceMotion: Bool, lift: CGFloat = 1) -> Self {
        guard enabled else { return Self() }
        if reduceMotion { return Self(fill: hovered || focused || pressed ? 0.05 : 0) }
        if pressed { return Self(scale: 0.98) }
        return hovered || focused ? Self(offset: -lift, glow: 0.20) : Self()
    }
}
private struct FieldHueKey: EnvironmentKey { static let defaultValue = Hue.control }
extension EnvironmentValues {
    var fieldHue: Hue {
        get { self[FieldHueKey.self] }
        set { self[FieldHueKey.self] = newValue }
    }
}
private struct HoverLift<S: Shape>: ViewModifier {
    var shape: S
    var hue: Hue?
    @Environment(\.fieldHue) private var fieldHue
    var pressed: Bool
    var lift: CGFloat
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    func body(content: Content) -> some View {
        let state = HoverLiftState.make(hovered: hovered, focused: focused, pressed: pressed, enabled: enabled, reduceMotion: reduceMotion, lift: lift)
        let hue = hue ?? fieldHue
        content.overlay(shape.fill(hue.actionRGB.color.opacity(state.fill)).allowsHitTesting(false).accessibilityHidden(true))
            .offset(y: state.offset).scaleEffect(state.scale)
            .animation(reduceMotion ? nil : Motion.hover, value: state)
            .contentShape(shape)
            .onHover { hovered = $0 }
    }
}
extension View {
    func hoverLift<S: Shape>(shape: S, hue: Hue? = nil, pressed: Bool = false, lift: CGFloat = 1) -> some View {
        modifier(HoverLift(shape: shape, hue: hue, pressed: pressed, lift: lift))
    }
}

#if DEBUG
final class BodyCounters: @unchecked Sendable {
    static let shared = BodyCounters()
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    static func record(_ name: String) { shared.lock.withLock { shared.counts[name, default: 0] += 1 } }
    static func snapshot() -> [String: Int] { shared.lock.withLock { shared.counts } }
    static func reset() { shared.lock.withLock { shared.counts = [:] } }
}
#endif
