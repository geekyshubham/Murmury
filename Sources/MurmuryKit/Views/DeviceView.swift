import SwiftUI

struct DeviceView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    private let hue = Hue.buds
    var body: some View {
        let buds = model.buds
        let p = model.sourcePresentation
        Page {
            PageHeader(hue: hue, title: buds.deviceName ?? "Galaxy Buds3 Pro", subtitle: subtitle,
                       chip: StateChip(text: p.chipText, color: p.tone.color, active: buds.isBusy),
                       // Before connecting, one row says what connecting reads, not two "Connect to read" rows.
                       features: (buds.state == .connected || buds.state == .streaming
                                  ? [Feature(symbol: "battery.75percent", title: "Battery", detail: p.batteryText),
                                     Feature(symbol: "ear", title: "Wear", detail: p.wearText)]
                                  : [Feature(symbol: "battery.75percent", title: "Battery and fit", detail: "Shown once connected")]) + [
                                  Feature(symbol: "gyroscope", title: "Head tracking", detail: p.trackingText)], notices: notices,
                       secondary: SecondaryAction(title: "Advanced") { model.settingsTab = .buds; openSettings() },
                       more: [MoreItem(title: "Bluetooth Settings…", symbol: "gearshape") {
                                  if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") { NSWorkspace.shared.open(url) }
                              },
                              MoreItem(title: "Buds settings…", symbol: "slider.horizontal.3") { model.settingsTab = .buds; openSettings() }]) {
                BudsAvatar(presentation: p)
            } extra: {
                StepsView(step: p.hardwareStep).padding(.vertical, 6)
            }
        } action: { orb }
    }
    private var notices: [StatusNotice] {
        if case .failed(let why) = model.buds.state { return [StatusNotice(tone: .danger, text: why, actionTitle: "Try again", action: { model.connectMotionSource() })] }
        if let banner = model.sourcePresentation.demoBanner { return [StatusNotice(tone: .info, text: banner, actionTitle: "Stop demo", action: { model.stopDemo() })] }
        return []
    }
    private var subtitle: String {
        switch model.buds.state {
        case .disconnected: "Pair in Bluetooth settings, then connect"
        case .searching, .connecting: "Keep your buds near this Mac"
        case .connected: "Ready to stream your head movement"
        case .streaming: "Your head movement, live on this Mac"
        case .failed: "Disconnect from your phone, then try again"
        }
    }
    @ViewBuilder private var orb: some View {
        switch model.buds.state {
        case .disconnected, .failed: OrbButton(title: "Connect", hue: hue, caption: "⌘K to connect") { model.connectMotionSource() }.keyboardShortcut("k")
        case .searching, .connecting: OrbButton(title: "Cancel", hue: hue, active: true, caption: "⌘K to cancel") { model.disconnectMotionSource() }.keyboardShortcut("k")
        case .connected: OrbButton(title: "Stream", hue: hue, caption: "⌘K to stream") { model.startMotionStream() }.keyboardShortcut("k")
        case .streaming: OrbButton(title: "Stop", hue: hue, active: true, caption: "⌘K to stop") { model.stopMotionStream() }.keyboardShortcut("k")
        }
    }
}

/// Pair → Connect → Stream, with the current step lit. A plain strip, no container.
private struct StepsView: View {
    var step: Int
    private let titles = ["Pair", "Connect", "Stream"]
    /// Lit steps: a deep blue disc with a white numeral in light; a light blue disc with a navy
    /// numeral in dark, so the disc itself holds 3:1 on the deep field.
    static let disc = Ink.scheme("stepDisc", light: Hue.buds.actionRGB, dark: RGB(0x7FB8FF))
    static let numeral = Ink.scheme("stepNumeral", light: RGB(0xFFFFFF), dark: RGB(0x0B1E5B))

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(titles.enumerated()), id: \.offset) { i, title in
                let n = i + 1
                HStack(spacing: 6) {
                    Image(systemName: n < step ? "checkmark.circle.fill" : "\(n).circle\(n == step ? ".fill" : "")")
                        .font(.system(size: 17, weight: .medium))
                        // Filled steps draw the numeral in white on the blue disc, not cut out to the field.
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(n <= step ? Self.numeral : Ink.tertiary, n <= step ? Self.disc : Ink.tertiary)
                    Text(title).foregroundStyle(n == step ? Ink.primary : Ink.secondary)
                }
                .font(TypeStyle.body.weight(n == step ? .semibold : .regular))
                if n < titles.count { Capsule().fill(n < step ? Hue.buds.a.opacity(0.6) : Ink.hairline).frame(width: 18, height: 2) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step) of 3: \(titles[min(step, 3) - 1])")
        .accessibilityAddTraits(.isStaticText)
    }
}
