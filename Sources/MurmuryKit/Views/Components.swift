import SwiftUI

/// Plot channel colours: blue, orange and lilac stay distinguishable for colour-blind users, and
/// every series is also named in its legend.
enum Theme {
    static let axisX = Ink.dynamic("axisX", { $0.night == Palette.dark.night ? RGB(0x73B8FF) : RGB(0x1F6FD1) })
    static let axisY = Ink.dynamic("axisY", { $0.night == Palette.dark.night ? RGB(0xFFB35C) : RGB(0xB5580A) })
    static let axisZ = Ink.dynamic("axisZ", { $0.night == Palette.dark.night ? RGB(0xD694FF) : RGB(0x8E3FD6) })
    static let axisW = Ink.tertiary
}

extension BudsService.State {
    var color: Color {
        switch self {
        case .streaming: Ink.live
        case .connected: Hue.buds.a
        case .searching, .connecting: Ink.warn
        case .failed: Ink.danger
        case .disconnected: Ink.tertiary
        }
    }
}

/// Multi-channel line plot drawn with Canvas so it keeps up at sensor rate.
/// Adapted from Subvox (MIT, Joe Blau).
struct SignalPlot: View {
    struct Channel {
        var name: String
        var color: Color
        var value: (MotionSample) -> Double
    }

    var title: String
    var samples: [MotionSample]
    var channels: [Channel]
    var minScale: Double = 0.05
    var height: CGFloat = 96
    /// How the scale reads: a rate in rad/s shows as whole °/s; other signals stay unitless.
    var degreesPerSecond = false
    private func scaleText(_ v: Double) -> String {
        degreesPerSecond ? String(format: "%.0f°/s", v * 180 / .pi) : String(format: "%.2f", v)
    }

    /// One plain series for the overview: how fast the head is turning, whatever the axis.
    static func speed(_ color: Color) -> [Channel] {
        [Channel(name: "Head speed", color: color) { sample in
            let r = sample.turnRate
            return (r[0] * r[0] + r[1] * r[1] + r[2] * r[2]).squareRoot()
        }]
    }
    static let velocity = [
        Channel(name: "ωx", color: Theme.axisX) { $0.wx },
        Channel(name: "ωy", color: Theme.axisY) { $0.wy },
        Channel(name: "ωz", color: Theme.axisZ) { $0.wz },
    ]
    static let acceleration = [
        Channel(name: "αx", color: Theme.axisX) { $0.alx },
        Channel(name: "αy", color: Theme.axisY) { $0.aly },
        Channel(name: "αz", color: Theme.axisZ) { $0.alz },
    ]
    static let budAccel = [
        Channel(name: "ax", color: Theme.axisX) { $0.ax },
        Channel(name: "ay", color: Theme.axisY) { $0.ay },
        Channel(name: "az", color: Theme.axisZ) { $0.az },
    ]
    static let budGyro = [
        Channel(name: "gx", color: Theme.axisX) { $0.gx },
        Channel(name: "gy", color: Theme.axisY) { $0.gy },
        Channel(name: "gz", color: Theme.axisZ) { $0.gz },
    ]
    static let quaternion = [
        Channel(name: "x", color: Theme.axisX) { $0.qx },
        Channel(name: "y", color: Theme.axisY) { $0.qy },
        Channel(name: "z", color: Theme.axisZ) { $0.qz },
        Channel(name: "w", color: Theme.axisW) { $0.qw },
    ]

    var body: some View {
        let t0 = samples.first?.t ?? 0, t1 = max(samples.last?.t ?? 1, t0 + 1e-3)
        let peak = channels.flatMap { c in samples.map { abs(c.value($0)) } }.max() ?? 0
        let scale = max(minScale, peak)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Space.sm) {
                Text(title).font(TypeStyle.chartTitle).foregroundStyle(Ink.primary)
                // One series is named by the title; a legend only when there are several.
                ForEach(channels.count > 1 ? channels : [], id: \.name) { c in
                    HStack(spacing: Space.xxs) {
                        RoundedRectangle(cornerRadius: 1).fill(c.color).frame(width: 12, height: 3)
                        Text(c.name)
                    }
                    .font(TypeStyle.axis).foregroundStyle(Ink.secondary)
                }
                Spacer()
                Text(degreesPerSecond ? "Peak " + scaleText(peak) : "±" + scaleText(scale)).font(TypeStyle.caption.monospacedDigit()).foregroundStyle(Ink.tertiary)
            }
            Canvas { ctx, size in
                // A speed is never negative: its zero is the floor and it uses the full height. Signed
                // channels keep a centred zero.
                let base = degreesPerSecond ? size.height - 2 : size.height / 2
                let reach = degreesPerSecond ? size.height - 4 : size.height / 2 - 2
                var axis = Path()
                axis.move(to: CGPoint(x: 0, y: base)); axis.addLine(to: CGPoint(x: size.width, y: base))
                ctx.stroke(axis, with: .color(Ink.hairline), lineWidth: 0.5)
                for c in channels {
                    var path = Path()
                    for (i, s) in samples.enumerated() {
                        let p = CGPoint(x: (s.t - t0) / (t1 - t0) * size.width, y: base - c.value(s) / scale * reach)
                        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                    }
                    ctx.stroke(path, with: .color(c.color), lineWidth: 1.5)
                }
            }
            .frame(height: height)
            .background(Ink.panel, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            if degreesPerSecond && !samples.isEmpty {
                // The trace's time extent: how far back it reaches, and the live edge.
                HStack {
                    Text("\(Int((t1 - t0).rounded())) s ago")
                    Spacer()
                    Text("Now")
                }
                .font(TypeStyle.axis.monospacedDigit()).foregroundStyle(Ink.tertiary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isImage)
        .accessibilityLabel(title + " chart")
        .accessibilityValue(samples.isEmpty ? "No data" : "Peak \(scaleText(peak)) over the last \(Int((t1 - t0).rounded())) seconds")
    }
}

/// Motion energy against the auto-capture threshold.
struct EnergyMeter: View {
    var energy: Double
    var threshold: Double?
    var capturing: Bool

    var body: some View {
        let top = max((threshold ?? 0.5) * 2, energy, 0.1)
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Ink.panel)
                Capsule().fill(capturing ? Ink.danger : Color.accentColor)
                    .frame(width: max(6, g.size.width * min(1, energy / top)))
                if let threshold {
                    Rectangle().fill(Ink.primary).frame(width: 2)
                        .offset(x: g.size.width * min(1, threshold / top))
                }
            }
        }
        .frame(height: 8)
        .accessibilityElement()
        .accessibilityLabel("Motion energy")
        .accessibilityValue(threshold.map { energy > $0 ? "Above trigger threshold" : "Below trigger threshold" } ?? String(format: "%.2f", energy))
    }
}

struct FeatureToggles: View {
    @Binding var set: FeatureSet
    /// Takes recorded without raw IMU (demo motion); they are left out while the IMU channels are on.
    var takesWithoutIMU: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Orientation change", isOn: bind(.orientation))
            Toggle("Angular velocity", isOn: bind(.velocity))
            Toggle("Angular acceleration", isOn: bind(.acceleration))
            // Always available: Galaxy Buds3 Pro send raw accelerometer and gyro in every motion packet.
            Toggle("Bud accelerometer + gyro", isOn: bind(.imu))
            if set.contains(.imu), takesWithoutIMU > 0 {
                Text("\(takesWithoutIMU) \(takesWithoutIMU == 1 ? "take has" : "takes have") no raw sensor data (recorded from demo motion), so \(takesWithoutIMU == 1 ? "it is" : "they are") left out while this is on")
                    .font(TypeStyle.caption).foregroundStyle(Ink.secondary)
            }
        }
        .font(TypeStyle.body)
        .foregroundStyle(Ink.primary)
    }

    private func bind(_ f: FeatureSet) -> Binding<Bool> {
        Binding(get: { set.contains(f) }, set: { if $0 { set.insert(f) } else { set.remove(f) } })
    }
}

