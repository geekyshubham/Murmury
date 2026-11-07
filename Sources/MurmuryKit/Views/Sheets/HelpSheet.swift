import SwiftUI

/// Task-focused help: what to do, in the order people need it, in the product's own words.
struct HelpSheet: View {
    struct Topic: Identifiable {
        var id: String { title }
        var symbol: String
        var title: String
        var steps: [String]
    }
    static let topics: [Topic] = [
        Topic(symbol: "airpodspro", title: "Get started", steps: [
            "Pair your Galaxy Buds3 Pro in System Settings › Bluetooth",
            "Open Buds and choose Connect (⌘K)",
            "Open Control and choose Start (⇧⌘M). Allow Accessibility so Murmury can click for you.",
            "To start without touching anything, turn on Settings › Pointer › Start when buds connect",
        ]),
        Topic(symbol: "cursorarrow.motionlines", title: "Point and click", steps: [
            "Turn your head: the pointer follows. Small movements are ignored, so it stays put while you read.",
            "Murmur “click”, “right click” or “double click”. Say “scroll mode” to scroll with your head and “pointer mode” to point again.",
            "See every phrase in Commands (⌘/)",
        ]),
        Topic(symbol: "cursorarrow.click", title: "Click without voice", steps: [
            "Turn on Settings › Pointer › Click by holding the pointer still. A ring by the pointer fills, then it clicks; move away to click again.",
            "Set the hold time there (0.6 to 3 seconds). The palette (top right; drag it anywhere) picks Left, Right or Double for the next dwell click; dwell on it to choose.",
            "To drag, dwell on Drag, then hold still where the drag starts; move, and hold still again to drop. By voice: “drag”, then “drop”.",
            "Or teach a gesture named “click”, “right click” or “double click” and turn on gesture commands",
        ]),
        Topic(symbol: "keyboard", title: "Type without hands", steps: [
            "Murmur your text with macOS Dictation (System Settings › Keyboard › Dictation)",
            "Or turn on the Accessibility Keyboard (System Settings › Accessibility › Keyboard) and type on it with dwell or “click”",
        ]),
        Topic(symbol: "stop.circle", title: "Stop at any time", steps: [
            "Say “mouse off” (and “mouse on” to resume), press ⇧⌘M, or use the menu-bar item",
            "Without voice, nod twice to pause the pointer, and twice again to resume (when Settings › Pointer › Nodding › Nod twice to pause is on; otherwise use the menu-bar item)",
            "If voice stops, the pointer pauses and a sound plays. Nod twice to retry voice; nod twice again to go on with dwell or gesture clicks.",
            "Nods too small or too slow to count? Set the nod depth and pace in Settings › Pointer › Nodding",
        ]),
        Topic(symbol: "scope", title: "Make it fit you", steps: [
            "If up and down or left and right are reversed, calibrate with your camera (Control › More › Calibrate with camera): it watches your face while you turn and nod, then the buds work alone",
            "Pointer speed, smoothing and steadiness are in Settings › Pointer (⌘,)",
        ]),
        Topic(symbol: "record.circle", title: "Teach your own gestures", steps: [
            "In Teach, name a gesture, then click Record (or hold Space) and do it. Record about 15 takes per gesture, plus some “nothing”.",
            "In Model, choose Train. “Accuracy on new takes” tells you how well it recognizes takes it hasn't seen.",
            "In Detect, learn stillness once (stay still for 2 seconds), then your gestures appear as you move",
        ]),
        Topic(symbol: "lock.shield", title: "Privacy", steps: [
            "Everything runs on this Mac: speech recognition, your gestures and the model. Nothing is uploaded.",
            "The camera is used once, only to calibrate how the buds sit on your head",
        ]),
    ]
    var body: some View {
        DetailSheet(title: "Murmury Help", hue: .control) {
            ForEach(Self.topics) { topic in
                VStack(alignment: .leading, spacing: 10) {
                    Label(topic.title, systemImage: topic.symbol)
                        .font(TypeStyle.sectionTitle).accessibilityAddTraits(.isHeader)
                    ForEach(Array(topic.steps.enumerated()), id: \.offset) { _, step in
                        Text(step).font(TypeStyle.body).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
