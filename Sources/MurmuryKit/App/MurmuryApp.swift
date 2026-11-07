import AppKit
import Carbon.HIToolbox
import ObjectiveC
import SwiftUI

public enum Launcher {
    @MainActor public static func renderIconIfRequested(from arguments: [String]) throws -> Bool {
        guard let destination = try AppIconRenderer.destination(from: arguments) else { return false }
        try AppIconRenderer.render(to: destination, requireMetal: arguments.contains("--require-metal"))
        if let flag = arguments.first(where: { $0.hasPrefix("--render-icns=") }) {
            let path = String(flag.dropFirst("--render-icns=".count))
            guard !path.isEmpty else { throw CocoaError(.fileWriteInvalidFileName) }
            try AppIconRenderer.writeICNS(from: destination, to: URL(fileURLWithPath: path))
        }
        return true
    }
    @MainActor public static func run() {
        // Single-window app: never restore a "no windows" session, or a relaunch after closing
        // the window shows nothing and the app looks broken.
        UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])
        MurmuryApp.main()
    }
    /// Evidence tools that run instead of the app: `--dump-scene=<scn>` (prints the asset tree) and
    /// `--render-hero-stills=<dir>` (renders and measures the heroes; `--asset=<scn>`, `--hero-debug-eyes`,
    /// `--only=<name part>`), `--render-bud-views=<dir>` (one bud on white at `--yaws=<deg,...>`, for
    /// comparing against product photography). Returns an exit code, or nil for a normal launch.
    @MainActor public static func runToolIfRequested(from arguments: [String]) throws -> Int32? {
        func value(_ flag: String) -> String? {
            arguments.first { $0.hasPrefix(flag + "=") }.map { String($0.dropFirst(flag.count + 1)) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        if let pid = value("--sheet-probe-pid").flatMap({ pid_t($0) }), let out = value("--sheet-probe-out") {
            try SheetProbe.run(pid: pid, out: out, plan: value("--sheet-probe-plan") ?? "")
            return 0
        }
        if let pid = value("--ax-dump-pid").flatMap({ pid_t($0) }), let out = value("--ax-dump-out") {
            try AXDump.write(pid: pid, to: out, note: value("--ax-dump-note") ?? "")
            return 0
        }
        if let path = value("--icon-previews-of"), let out = value("--icon-previews-to") {
            try AppIconRenderer.previews(of: path, to: URL(fileURLWithPath: out, isDirectory: true))
            return 0
        }
        if let scene = value("--dump-scene") {
            print(try HeroStills.dumpScene(at: URL(fileURLWithPath: scene)), terminator: "")
            return 0
        }
        if arguments.contains("--hero-timing") {
            print(HeroStills.timing(assetURL: value("--asset").map { URL(fileURLWithPath: $0) }))
            return 0
        }
        if let style = value("--head-style").flatMap(HeadTreatment.Style.init(rawValue:)) { HeadTreatment.style = style }
        if let eyes = value("--eyes").flatMap(HeadTreatment.Eyes.init(rawValue:)) { HeadTreatment.eyes = eyes }
        if let directory = value("--render-bud-views") {
            return try HeroStills.renderBudViews(to: URL(fileURLWithPath: directory, isDirectory: true),
                                                 yaws: (value("--yaws") ?? "-11,70,200").split(separator: ",").compactMap { Double($0) })
        }
        if let directory = value("--render-hero-stills") {
            let asset = value("--asset").map { URL(fileURLWithPath: $0) }
                ?? Bundle.main.url(forResource: "head", withExtension: "scn", subdirectory: "Models")
            return try HeroStills.render(to: URL(fileURLWithPath: directory, isDirectory: true), assetURL: asset,
                                         debugEyes: arguments.contains("--hero-debug-eyes"), only: value("--only"))
        }
        return nil
    }
}

struct MurmuryApp: App {
    @State private var model = AppModel(store: AppModel.store(for: CommandLine.arguments))

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        if let appearance = AppModel.launchOptions(from: CommandLine.arguments).appearance {
            NSApplication.shared.appearance = NSAppearance(named: appearance)
        }
        // Mesh the earbud housing off the main thread while the window opens; the first scene that
        // needs it waits only for whatever is left.
        Task.detached(priority: .userInitiated) { _ = Buds3Pro.housingNet }
    }

    var body: some Scene {
        WindowGroup("Murmury") {
            ContentView()
                .environment(model)
                .background(MainWindowMarker())
                // The hidden title bar adds its 32-point safe area: the whole window's minimum is 1120x740.
                .frame(minWidth: 1120, minHeight: 740 - 32)
                .onAppear {
                    SpaceKeyMonitor.shared.install(model: model)
                    HeadMouseHotKey.shared.install(model: model)
                    DwellRing.shared.install(model: model)
                    model.chime = { NSSound(named: NSSound.Name($0.soundName))?.play() }
                    model.applyLaunchArguments(CommandLine.arguments)
                    let options = AppModel.launchOptions(from: CommandLine.arguments)
                    if let size = options.windowSize { MainWindowMarker.resize(to: size) }
                    if let path = options.axDumpPath { AXDump.schedule(path: path) }
                    // Evidence only (`--switch-appearance-after=<seconds>`): flips the app's appearance
                    // once, as a system appearance change would, to check the head re-renders cleanly.
                    if let delay = CommandLine.arguments.first(where: { $0.hasPrefix("--switch-appearance-after=") })
                        .flatMap({ Double($0.dropFirst("--switch-appearance-after=".count)) }) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                            NSApp.appearance = NSAppearance(named: dark ? .aqua : .darkAqua)
                        }
                    }
                    if let out = CommandLine.arguments.first(where: { $0.hasPrefix("--sheet-probe=") })?.dropFirst("--sheet-probe=".count) {
                        let plan = CommandLine.arguments.first { $0.hasPrefix("--sheet-probe-plan=") }?.dropFirst("--sheet-probe-plan=".count)
                        SheetProbe.schedule(out: String(out), plan: plan.map(String.init) ?? "")
                    }
                    // `--background`: open behind the front app (screenshots without stealing focus).
                    if !CommandLine.arguments.contains("--background") { NSApp.activate(ignoringOtherApps: true) }
                }
        }
        .defaultSize(width: AppModel.launchOptions(from: CommandLine.arguments).windowSize?.width ?? 1120,
                     height: AppModel.launchOptions(from: CommandLine.arguments).windowSize?.height ?? 740)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button(model.capture.ownership == .toggled ? "Stop recording take" : "Start recording take") {
                    let window = NSApp.keyWindow
                    guard model.screen == .train,
                          shouldCaptureSpace(isMainWindowKey: window?.identifier == MainWindowMarker.identifier && window?.isKeyWindow == true,
                                             firstResponderIsText: false, modifiers: [],
                                             sheetOrSettingsOpen: window?.attachedSheet != nil || NSApp.modalWindow != nil, screen: model.screen) else { return }
                    model.capture.toggle()
                }
                .keyboardShortcut("r")  // the everyday action gets the short shortcut
                .disabled(model.screen != .train || !model.capture.canRecord)
                Button("Signals…") { model.detailSheet = .signals }.keyboardShortcut("1", modifiers: [.option, .command])
                Button("Dataset…") { model.detailSheet = .dataset }.keyboardShortcut("2", modifiers: [.option, .command])
                Button("Evaluation…") { model.detailSheet = .evaluation }.keyboardShortcut("3", modifiers: [.option, .command])
                Button("Detections…") { model.detailSheet = .detections }.keyboardShortcut("4", modifiers: [.option, .command])
                Button("Commands…") { model.detailSheet = .commands }.keyboardShortcut("/", modifiers: .command)
                Divider()
                Button(model.recordingURL == nil ? "Record Session" : "Stop Recording Session") { model.toggleRecording() }
                    .keyboardShortcut("r", modifiers: [.option, .command])
                Button(model.isDemo ? "Stop Demo" : "Try Demo") { model.isDemo ? model.stopDemo() : model.startDemo() }
            }
            CommandGroup(replacing: .help) {
                Button("Murmury Help") { model.detailSheet = .help }.keyboardShortcut("?", modifiers: .command)
            }
        }

        Settings { SettingsView().environment(model) }

        // The symbol follows the state (paused, scrolling, voice lost), visible over any app.
        MenuBarExtra("Murmury head mouse: " + model.controlCopy.chip, systemImage: model.controlCopy.symbol,
                     isInserted: Binding(get: { model.headMouse.isEnabled }, set: { _ in })) {
            HeadMouseMenu().environment(model)
        }.menuBarExtraStyle(.window)
    }
}

/// ⇧⌘M toggles the head mouse from anywhere. A system hot key (Carbon `RegisterEventHotKey`)
/// takes the keystroke, so the app in front never also receives it, and needs no permission.
/// If another app already owns ⇧⌘M, key monitors take over (the global one cannot swallow keys).
@MainActor
final class HeadMouseHotKey {
    static let shared = HeadMouseHotKey()
    private weak var model: AppModel?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var local: Any?
    private var global: Any?
    private(set) var usesSystemHotKey = false

    static func matches(keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags) -> Bool {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        return flags == [.shift, .command] && (keyCode == 46 || characters?.lowercased() == "m")
    }
    func install(model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        if registerSystemHotKey() { usesSystemHotKey = true; return }
        let toggle: (NSEvent) -> Bool = { [weak self] event in
            guard Self.matches(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers, modifiers: event.modifierFlags),
                  !event.isARepeat else { return false }
            self?.fire()
            return true
        }
        local = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in toggle(event) ? nil : event }
        global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in _ = toggle(event) }
    }
    fileprivate func fire() {
        guard let model else { return }
        Task { @MainActor in await model.setHeadMouse(!model.showsMouseOn) }
    }
    private func registerSystemHotKey() -> Bool {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<HeadMouseHotKey>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { hotKey.fire() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { return false }
        let id = EventHotKeyID(signature: OSType(0x4D524D59), id: 1)  // 'MRMY'
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_M), UInt32(cmdKey | shiftKey), id, GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr, let handler { RemoveEventHandler(handler); self.handler = nil }
        return status == noErr
    }
}

/// Hold Space anywhere in the window (outside text fields) to capture a segment.
@MainActor
final class SpaceKeyMonitor {
    static let shared = SpaceKeyMonitor()
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?

    func install(model: AppModel) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak model] event in
            guard event.keyCode == 49, let model else { return event }
            let window = NSApp.keyWindow
            let responder = ResponderKind.classify(responder: window?.firstResponder, window: window)
            let allowed = shouldCaptureSpace(isMainWindowKey: window?.identifier == MainWindowMarker.identifier && window?.isKeyWindow == true,
                                             firstResponderIsText: responder == .text,
                                             modifiers: event.modifierFlags,
                                             sheetOrSettingsOpen: window?.attachedSheet != nil || NSApp.modalWindow != nil,
                                             screen: model.screen,
                                             controlHasFocus: responder == .control || FocusRegistry.shared.hasFocus)
            if event.type == .keyUp {
                let owned = model.capture.ownership == .held(source: .space)
                model.capture.release(.space)
                return owned ? nil : event
            }
            guard allowed else { return event }
            if !event.isARepeat { model.capture.press(.space) }
            return nil
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak model] _ in
            MainActor.assumeIsolated { model?.capture.release(.space) }
        }
    }
}

/// Identifies content windows explicitly; a Settings or detail window may also become AppKit's main window.
private struct MainWindowMarker: NSViewRepresentable {
    static let identifier = NSUserInterfaceItemIdentifier("Murmury.main")
    /// `--window-size`: an exact window frame for evidence, top-left on the visible screen. It may
    /// extend past the bottom of a smaller display; the capture script checks the result.
    @MainActor static func resize(to size: NSSize) {
        DispatchQueue.main.async { apply(size) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { apply(size) }
    }
    @MainActor private static func apply(_ size: NSSize) {
        guard let window = NSApp.windows.first(where: { $0.identifier == identifier }),
              let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        allowFramesLargerThanScreen(window)
        window.setFrame(NSRect(x: visible.minX, y: visible.maxY - size.height, width: size.width, height: size.height), display: true)
    }
    /// Evidence launches only: AppKit keeps a titled window within the visible screen height. With
    /// `--window-size`, the window's class leaves frames as set, so 1600x1000 fits a smaller display.
    @MainActor private static func allowFramesLargerThanScreen(_ window: NSWindow) {
        guard let base = object_getClass(window) else { return }
        let selector = #selector(NSWindow.constrainFrameRect(_:to:))
        guard let method = class_getInstanceMethod(base, selector) else { return }
        let keep: @convention(block) (NSWindow, NSRect, NSScreen?) -> NSRect = { _, rect, _ in rect }
        class_replaceMethod(base, selector, imp_implementationWithBlock(keep), method_getTypeEncoding(method))
    }
    func makeNSView(context: Context) -> NSView { Marker() }
    func updateNSView(_ view: NSView, context: Context) {}
    private final class Marker: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.identifier = MainWindowMarker.identifier
        }
    }
}
