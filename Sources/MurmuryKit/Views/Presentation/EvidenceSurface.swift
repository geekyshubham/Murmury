import SwiftUI

/// Capture-only presentations, with no permission or pointer side effects.
struct EvidenceSurface: View {
    @Environment(AppModel.self) private var model
    let name: String
    var body: some View {
        if name.hasPrefix("calibration") || name.hasPrefix("murmur") {
            // The sheet at its real size, over the dimmed app, as a sheet appears.
            ZStack {
                Color.black.opacity(0.3).ignoresSafeArea()
                Group { if name.hasPrefix("murmur") { MurmurEnrollmentView() } else { CameraCalibrationView() } }
                    .frame(width: 760, height: 600)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.sheet, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
            }
            .onAppear {
                guard let state = name.split(separator: "-", maxSplits: 1).dropFirst().first.map(String.init) else { return }
                if name.hasPrefix("murmur") { model.murmurEnrollment.stage(state) } else { model.cameraCalibration.stage(state) }
            }
        } else {
            Group {
                if name == "menu" { HeadMouseMenu() }
                else if name.hasPrefix("settings-") { SettingsView() }
                else if let destination = DetailDestination(rawValue: name) { DetailDestinationView(destination: destination) }
            }
            .shadow(radius: 20)
        }
    }
}
