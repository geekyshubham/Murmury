import Foundation

enum MouseCommand: String, Equatable, Sendable, CaseIterable {
    case leftClick, rightClick, doubleClick
    case scrollUp, scrollDown, scrollLeft, scrollRight, scrollMode, pointerMode
    case pause, resume
    /// Press and hold the left button (moves become drags); `drop` releases it.
    case drag, drop

    var title: String {
        switch self {
        case .leftClick: "Left click"
        case .rightClick: "Right click"
        case .doubleClick: "Double click"
        case .scrollUp: "Scroll up"
        case .scrollDown: "Scroll down"
        case .scrollLeft: "Scroll left"
        case .scrollRight: "Scroll right"
        case .scrollMode: "Scroll mode"
        case .pointerMode: "Pointer mode"
        case .pause: "Pause"
        case .resume: "Resume"
        case .drag: "Drag"
        case .drop: "Drop"
        }
    }

    var symbol: String {
        switch self {
        case .leftClick: "cursorarrow.click"
        case .rightClick: "contextualmenu.and.cursorarrow"
        case .doubleClick: "cursorarrow.click.2"
        case .scrollUp: "arrow.up.circle"
        case .scrollDown: "arrow.down.circle"
        case .scrollLeft: "arrow.left.circle"
        case .scrollRight: "arrow.right.circle"
        case .scrollMode: "arrow.up.and.down.circle"
        case .pointerMode: "cursorarrow"
        case .pause: "pause.circle"
        case .resume: "play.circle"
        case .drag: "hand.draw"
        case .drop: "hand.raised"
        }
    }
}

/// Finds mouse commands in a live speech transcript.
///
/// The recognizer delivers a growing transcript that it keeps revising, so the parser counts
/// command occurrences in each snapshot and reports only the ones beyond what it already
/// reported. Revisions of ordinary words therefore never re-fire a click.
struct VoiceCommandParser {
    static let phrases: [(words: [String], command: MouseCommand)] = [
        (["left", "click"], .leftClick),
        (["right", "click"], .rightClick),
        (["double", "click"], .doubleClick),
        (["click"], .leftClick),
        (["scroll", "up"], .scrollUp),
        (["scroll", "down"], .scrollDown),
        (["scroll", "left"], .scrollLeft),
        (["scroll", "right"], .scrollRight),
        (["scroll", "mode"], .scrollMode),
        (["start", "scrolling"], .scrollMode),
        (["stop", "scrolling"], .pointerMode),
        (["pointer", "mode"], .pointerMode),
        (["mouse", "off"], .pause),
        (["pause", "mouse"], .pause),
        (["stop", "mouse"], .pause),
        (["mouse", "on"], .resume),
        (["resume", "mouse"], .resume),
        (["start", "mouse"], .resume),
        (["start", "drag"], .drag),
        (["drag"], .drag),
        (["drop"], .drop),
        (["let", "go"], .drop),
    ]

    /// Spellings the recognizer produces for the command words.
    static let aliases: [String: String] = [
        "clique": "click", "klick": "click", "clic": "click",
        "scrawl": "scroll",
        "write": "right", "rite": "right", "wright": "right",
        "rightclick": "right click", "leftclick": "left click", "doubleclick": "double click",
    ]

    /// Words the recognizer should favour.
    static let vocabulary = ["click", "left click", "right click", "double click", "scroll up", "scroll down",
                             "scroll left", "scroll right", "scroll mode", "stop scrolling", "mouse off", "mouse on", "drag", "drop"]

    private var reported = 0

    mutating func commands(in transcript: String) -> [MouseCommand] {
        let found = Self.parse(transcript)
        if found.isEmpty, transcript.allSatisfy(\.isWhitespace) { reported = 0 }
        guard found.count > reported else { return [] }
        defer { reported = found.count }
        return Array(found[reported...])
    }

    static func parse(_ text: String) -> [MouseCommand] {
        let tokens = tokenize(text)
        var out: [MouseCommand] = []
        var i = 0
        while i < tokens.count {
            if let match = phrases.first(where: { tokens[i...].starts(with: $0.words) }) {
                out.append(match.command)
                i += match.words.count
            } else {
                i += 1
            }
        }
        return out
    }

    /// The commands in `tokens` if they are nothing but command phrases (and `fillers`); nil when
    /// any other word is there, i.e. the command words were part of a sentence.
    static func commandsAlone(_ tokens: [String], fillers: Set<String> = []) -> [MouseCommand]? {
        var out: [MouseCommand] = []
        var i = 0
        while i < tokens.count {
            if let match = phrases.first(where: { tokens[i...].starts(with: $0.words) }) {
                out.append(match.command); i += match.words.count
            } else if fillers.contains(tokens[i]) {
                i += 1
            } else {
                return nil
            }
        }
        return out
    }

    /// A trained motion label triggers a command only when the whole label is one command phrase.
    static func command(forLabel label: String) -> MouseCommand? {
        let tokens = tokenize(label)
        return phrases.first { $0.words == tokens }?.command
    }

    static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && $0 != "'" }
            .flatMap { (aliases[String($0)] ?? String($0)).split(separator: " ").map(String.init) }
    }
}

/// Detects speech from the microphone level so the pointer can hold still while you talk:
/// saying "click" moves your jaw, and with it the buds.
struct VoiceActivity {
    /// How far above the noise floor counts as speech (0…1 level ≈ -60…0 dBFS, so 0.15 ≈ 9 dB).
    var margin: Float = 0.15
    var hangover: TimeInterval = 0.4
    /// Fraction of the gap the floor closes per level update when the level is above it.
    var rise: Float = 0.005
    private(set) var floor: Float?
    private var lastSpeech: TimeInterval?

    mutating func update(level: Float, at t: TimeInterval) -> Bool {
        let f = floor ?? level
        floor = level < f ? level : f + (level - f) * rise
        if level > f + margin { lastSpeech = t }
        return isSpeaking(at: t)
    }

    func isSpeaking(at t: TimeInterval) -> Bool {
        guard let lastSpeech else { return false }
        return t >= lastSpeech && t - lastSpeech <= hangover
    }
}
