/// The sidebar's single status pill and its menu, in priority order: a session recording, the demo,
/// the hardware, then nothing connected.
struct SidebarStatus: Equatable {
    enum Item: Equatable { case openBuds, tryDemo, stopDemo, recordSession, stopSession }
    var text: String
    var tone: BudsPresentation.Tone
    var items: [Item]

    static func evaluate(isDemo: Bool, hasMotion: Bool, recordingSession: Bool, presentation: BudsPresentation) -> Self {
        var items: [Item] = [.openBuds]
        if isDemo { items.append(.stopDemo) } else if !hasMotion { items.append(.tryDemo) }
        items.append(recordingSession ? .stopSession : .recordSession)
        if recordingSession { return Self(text: "Recording session", tone: .danger, items: items) }
        if isDemo { return Self(text: "Demo · not real buds", tone: .demo, items: items) }
        return Self(text: presentation.chipText, tone: presentation.tone, items: items)
    }
}

extension SidebarStatus.Item {
    var title: String {
        switch self {
        case .openBuds: "Open Buds"
        case .tryDemo: "Try demo"
        case .stopDemo: "Stop demo"
        case .recordSession: "Record session"
        case .stopSession: "Stop recording session"
        }
    }
    var symbol: String {
        switch self {
        case .openBuds: "earbuds"
        case .tryDemo: "play.fill"
        case .stopDemo: "stop.fill"
        case .recordSession: "record.circle"
        case .stopSession: "stop.circle.fill"
        }
    }
}
