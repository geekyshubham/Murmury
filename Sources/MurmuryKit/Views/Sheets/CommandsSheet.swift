import SwiftUI

struct CommandsSheet: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        DetailSheet(title: "Murmur a command", hue: .control) {
            Text(model.transcriber.isRunning ? (model.transcriber.isOnDevice ? "Speech recognition is running on this Mac" : "Using the system speech service") : "Enable the microphone in Voice settings to use spoken commands").font(TypeStyle.body)
            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: Space.md) {
                row("“click”, “left click”", .leftClick)
                row("“right click”", .rightClick)
                row("“double click”", .doubleClick)
                row("“scroll up / down / left / right”", .scrollDown, "Scroll one step")
                row("“scroll mode”, “start scrolling”", .scrollMode, "Head movement scrolls")
                row("“stop scrolling”, “pointer mode”", .pointerMode, "Head movement points")
                row("“drag” … “drop” (or “let go”)", .drag, "Hold the button, move, release")
                row("“mouse off” / “mouse on”", .pause, "Pause or resume")
            }.font(TypeStyle.body)
        }
    }
    private func row(_ phrase: String, _ command: MouseCommand, _ title: String? = nil) -> some View {
        GridRow {
            Text(phrase).fontWeight(.semibold)
            Label(title ?? command.title, systemImage: command.symbol).foregroundStyle(Ink.secondary)
        }
    }
}
