import SwiftUI

struct SignalsSheet: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        DetailSheet(title: "Motion signals", hue: .motion) {
            SignalPlot(title: "Angular velocity (rad/s)", samples: model.history, channels: SignalPlot.velocity)
            SignalPlot(title: "Angular acceleration (rad/s²)", samples: model.history, channels: SignalPlot.acceleration, minScale: 1)
            if model.latest?.hasIMU == true {
                SignalPlot(title: "Accelerometer (m/s²)", samples: model.history, channels: SignalPlot.budAccel, minScale: 0.2)
                SignalPlot(title: "Gyroscope (rad/s)", samples: model.history, channels: SignalPlot.budGyro)
            }
            SignalPlot(title: "Quaternion", samples: model.history, channels: SignalPlot.quaternion, minScale: 1, height: 70)
            Text("Motion energy").font(TypeStyle.rowTitle)
            EnergyMeter(energy: model.segmenter.energy, threshold: model.segmenter.threshold, capturing: model.segmenter.isCapturing)
            if !model.hasMotion { Text("Connect a motion source or try the demo to see signals").font(TypeStyle.body) }
        }
    }
}
