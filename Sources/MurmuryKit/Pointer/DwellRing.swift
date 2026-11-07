import AppKit
import QuartzCore
import SwiftUI

/// Feedback beside the pointer, over any app: a ring that fills while a dwell click builds, and a
/// short label for a moment after a command ("Heard: Right click"), so a hands-free user can tell
/// a mishearing from a pointer that is simply not listening. It never takes clicks.
@MainActor
final class DwellRing {
    static let shared = DwellRing()
    static let size: CGFloat = 36
    /// Below and right of the pointer's tip, clear of what it is about to click.
    static let offset = CGPoint(x: 16, y: -16)
    static let showFrom = 0.12
    static let labelSeconds = 1.6
    static let labelWidth: CGFloat = 220
    static func isVisible(_ progress: Double?) -> Bool { (progress ?? 0) >= showFrom }
    /// The words beside the pointer for a command; dwell clicks show the ring instead (except
    /// right and double, which say what happened).
    static func label(for command: MouseCommand, source: HeadMouse.CommandSource) -> String? {
        switch source {
        case .voice: "Heard: \(command.title)"
        case .gesture: "Gesture: \(command.title)"
        case .dwell: command == .leftClick ? nil : command.title
        case .other: nil
        }
    }

    private var panel: NSPanel?
    private let track = CAShapeLayer(), fill = CAShapeLayer()
    private let text = CATextLayer(), plate = CALayer()
    private var timer: Timer?
    private var shownCommandAt: Date?
    private var labelUntil: Date?
    private let palette = DwellPalette()

    func install(model: AppModel) {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self, weak model] _ in
            MainActor.assumeIsolated {
                guard let self, let model else { return }
                self.update(mouse: model.headMouse)
                self.palette.update(model: model)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func update(mouse: HeadMouse) {
        let now = Date()
        if let at = mouse.lastCommandAt, at != shownCommandAt {
            shownCommandAt = at
            if mouse.isEnabled, let command = mouse.lastCommand, let source = mouse.lastSource,
               let words = Self.label(for: command, source: source) {
                text.string = words
                labelUntil = now.addingTimeInterval(Self.labelSeconds)
            }
        }
        let progress = mouse.dwellProgress(at: ProcessInfo.processInfo.systemUptime)
        let ringShown = Self.isVisible(progress)
        let labelShown = mouse.isEnabled && (labelUntil.map { now < $0 } ?? false)
        guard ringShown || labelShown else {
            if panel?.isVisible == true { panel?.orderOut(nil) }
            return
        }
        let panel = self.panel ?? makePanel()
        let mouseAt = NSEvent.mouseLocation
        panel.setFrameOrigin(NSPoint(x: mouseAt.x + Self.offset.x, y: mouseAt.y + Self.offset.y - Self.size))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        track.isHidden = !ringShown; fill.isHidden = !ringShown
        fill.strokeEnd = progress ?? 0
        text.isHidden = !labelShown; plate.isHidden = !labelShown
        if labelShown {
            let width = min(Self.labelWidth - 8, (text.preferredFrameSize().width) + 20)
            plate.frame = CGRect(x: Self.size + 4, y: 6, width: width, height: Self.size - 12)
            text.frame = plate.frame.insetBy(dx: 10, dy: 4)
        }
        CATransaction.commit()
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func makePanel() -> NSPanel {
        let frame = NSRect(x: 0, y: 0, width: Self.size + 4 + Self.labelWidth, height: Self.size)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.ignoresMouseEvents = true; panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let view = NSView(frame: frame); view.wantsLayer = true
        // From 12 o'clock, clockwise: a dark track under a white fill reads on light and dark apps.
        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: Self.size / 2, y: Self.size / 2), radius: Self.size / 2 - 5,
                    startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        for (layer, color, width) in [(track, NSColor.black.withAlphaComponent(0.4), 6.0), (fill, NSColor.white, 3.5)] {
            layer.path = path; layer.fillColor = nil; layer.lineCap = .round
            layer.strokeColor = color.cgColor; layer.lineWidth = width
            view.layer?.addSublayer(layer)
        }
        fill.strokeEnd = 0
        // The label: white on a dark plate, legible over any app.
        plate.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        plate.cornerRadius = (Self.size - 12) / 2
        text.font = NSFont.systemFont(ofSize: 13, weight: .semibold); text.fontSize = 13
        text.foregroundColor = NSColor.white.cgColor; text.alignmentMode = .left
        text.contentsScale = NSScreen.main?.backingScaleFactor ?? 2; text.truncationMode = .end
        view.layer?.addSublayer(plate); view.layer?.addSublayer(text)
        panel.contentView = view
        self.panel = panel
        return panel
    }
}

/// The dwell click-type palette: Left, Right, Double, Drag. Its buttons are big dwell targets; dwelling
/// on one picks what the next dwell click does (right and double apply once). Shown while the head
/// mouse runs with dwell clicking on, at the top right of the main screen, without taking focus.
@MainActor
final class DwellPalette {
    private var panel: NSPanel?
    static let size = NSSize(width: 350, height: 76)
    static let frameName = "MurmuryDwellPalette"

    static func isShown(enabled: Bool, dwell: Bool, palette: Bool) -> Bool { enabled && dwell && palette }

    func update(model: AppModel) {
        let mouse = model.headMouse
        guard Self.isShown(enabled: mouse.isEnabled, dwell: mouse.dwellClicks, palette: mouse.dwellPalette) else {
            if panel?.isVisible == true { panel?.orderOut(nil) }
            return
        }
        let panel = self.panel ?? make(model: model)
        if !panel.isVisible {
            // Where the user last put it; top right the first time.
            if !panel.setFrameUsingName(Self.frameName), let screen = NSScreen.main?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: screen.maxX - Self.size.width - 16, y: screen.maxY - Self.size.height - 16))
            }
            panel.orderFrontRegardless()
        }
    }

    private func make(model: AppModel) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .statusBar; panel.becomesKeyOnlyIfNeeded = true; panel.hidesOnDeactivate = false
        // Movable (with a drag) so it never sits on top of a toolbar the user needs.
        panel.isMovableByWindowBackground = true
        panel.setFrameAutosaveName(Self.frameName)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.contentView = FirstMouseHostingView(rootView: DwellPaletteView().environment(model))
        panel.setAccessibilityLabel("Dwell click type")
        self.panel = panel
        return panel
    }
}

/// Takes the first click without activating Murmury, so a dwell click lands on the button.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct DwellPaletteView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let mouse = model.headMouse
        HStack(spacing: 6) {
            ForEach(HeadMouse.DwellAction.allCases, id: \.self) { action in
                let selected = mouse.dwellAction == action
                Button { mouse.dwellAction = action } label: {
                    VStack(spacing: 2) {
                        Image(systemName: action.command.symbol).font(.system(size: 18, weight: .medium))
                        Text(action == .drag && mouse.isDragging ? "Drop" : action.rawValue.capitalized).font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .frame(width: 80, height: 60)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(selected ? Hue.control.actionRGB.color : Color.primary.opacity(0.06)))
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(action == .drag ? (mouse.isDragging ? "Drop" : "Drag") : "\(action.rawValue.capitalized) click")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
    }
}
