import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var model = model
        ZStack {
            Aura(hue: model.screen.hue, pageOrigin: PageLayout.sidebar)
            PointerLightView(hue: model.screen.hue).accessibilityHidden(true)
            HStack(spacing: 0) {
                // VoiceOver meets the navigation before the page, as it reads on screen.
                Sidebar().accessibilityElement(children: .contain).accessibilitySortPriority(2)
                ZStack {
                    page
                        .id(model.screen)
                        .transition(.opacity)
                }
                .accessibilityElement(children: .contain).accessibilitySortPriority(1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(Motion.section(reduceMotion), value: model.screen)
            }
        }
        .overlay {
            if let name = model.evidenceSurface { EvidenceSurface(name: name).environment(model) }
        }
        .ignoresSafeArea()
        .environment(\.fieldHue, model.screen.hue)
        .tint(model.screen.hue.a)
        .toggleStyle(GlowToggleStyle(hue: model.screen.hue))
        .navigationTitle(model.screen.title)
        .sheet(item: $model.detailSheet) { destination in DetailDestinationView(destination: destination).environment(model) }
        .onChange(of: model.buds.state) { model.reconcileMotionSource() }
        // Back from System Settings: re-read permissions; never starts the pointer by itself.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.headMouse.refreshTrust()
            model.recheckVoice()
        }
    }

    @ViewBuilder private var page: some View {
        switch model.screen {
        case .mouse: MouseView()
        case .device: DeviceView()
        case .sensors: SensorsView()
        case .train: TrainView()
        case .model: ModelView()
        case .live: LiveView()
        }
    }
}

private struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openSettings) private var openSettings
    @Namespace private var selection

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    BrandMark(size: 32)
                    Text("Murmury").font(TypeStyle.brand).foregroundStyle(Ink.primary)
                }
                .accessibilityElement(children: .ignore).accessibilityLabel("Murmury")
                .accessibilityAddTraits(.isHeader)
                Spacer(minLength: Space.xxs)
                // Help in plain sight, not only behind "…" and the menu bar.
                Button { model.detailSheet = .help } label: {
                    Image(systemName: "questionmark.circle").font(.system(size: 18, weight: .regular))
                }
                .buttonStyle(IconButtonStyle())
                .accessibilityLabel("Murmury Help")
                .help("Help (⌘?)")
            }
            .padding(.leading, Space.md).padding(.trailing, Space.unit)
            .padding(.top, 48)
            .padding(.bottom, 20)

            ForEach(Array(AppModel.Screen.allCases.enumerated()), id: \.element) { index, screen in
                item(screen, shortcut: KeyEquivalent(Character("\(index + 1)")))
            }

            Spacer()

            // Footer: one status (a menu) and Settings.
            HStack(alignment: .center, spacing: Space.unit) {
                SidebarStatusPill()
                Button { model.settingsTab = .pointer; openSettings() } label: {
                    Image(systemName: "gearshape").font(.system(size: 18, weight: .regular))
                }
                .buttonStyle(IconButtonStyle())
                .accessibilityLabel("Settings")
                .help("Settings (⌘,)")
            }
            .padding(.horizontal, Space.md)  // one 16-point sidebar edge: brand, selection and footer
            .padding(.bottom, Space.md)
        }
        .frame(width: PageLayout.sidebar)
        .background { SidebarSurfaceView(hue: model.screen.hue) }
        .overlay(alignment: .trailing) {
            SidebarEdgeView(hue: model.screen.hue).frame(width: 24).offset(x: 24)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
        // In dark the sidebar and copy are close in tone: a hairline gives the sidebar its edge.
        .overlay(alignment: .trailing) {
            if scheme == .dark { Rectangle().fill(Color.white.opacity(0.10)).frame(width: 1).accessibilityHidden(true) }
        }
    }

    private func item(_ screen: AppModel.Screen, shortcut: KeyEquivalent) -> some View {
        let selected = model.screen == screen
        return Button {
            withAnimation(Motion.spring(reduceMotion)) { model.screen = screen }
        } label: {
            HStack(spacing: 14) {
                // Quiet chrome: a line glyph in the label's colour, one fixed column.
                Image(systemName: screen.symbol).font(.system(size: 17, weight: .regular))
                    .foregroundStyle(selected ? Ink.primary : Ink.secondary)
                    .frame(width: 24, height: 24).accessibilityHidden(true)
                Text(screen.title)
                    .font(TypeStyle.sidebarItem(selected: selected))
                    .foregroundStyle(selected ? Ink.primary : Ink.secondary)
                Spacer()
            }
            .padding(.horizontal, 10).frame(height: 48)
            .background {
                if selected {
                    // The one selection surface: no outline in dark, a lifted white card in light.
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .fill(SidebarSurface.selection(hue: model.screen.hue, dark: scheme == .dark).color)
                        .shadow(color: Ink.shade.opacity(scheme == .dark ? 0.18 : 0.06), radius: 8, y: 2)
                        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(scheme == .dark ? .white.opacity(0.12) : Ink.glassStroke, lineWidth: Radius.hairlineWidth))
                        .modifier(SidebarSelection(namespace: selection, reduceMotion: reduceMotion))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle(selected: selected, showsSelection: false))
        .padding(.horizontal, Space.unit)  // with the row style's 8-point inset: the 16-point sidebar edge
        .keyboardShortcut(shortcut, modifiers: .command)
        .help("\(screen.title) (⌘\(String(shortcut.character)))")
        .accessibilityLabel("\(screen.title), \(String(shortcut.character)) of 6")
        .accessibilityValue(selected ? "Current page" : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The sidebar's single status: what's driving the head (session, demo, hardware), as a menu.
private struct SidebarStatusPill: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var hovering = false
    var body: some View {
        let status = SidebarStatus.evaluate(isDemo: model.isDemo, hasMotion: model.hasMotion, recordingSession: model.recordingURL != nil,
                                            presentation: model.sourcePresentation)
        let parts = status.text.components(separatedBy: " · ")
        Menu {
            ForEach(status.items, id: \.title) { item in
                Button { perform(item) } label: { Label(item.title, systemImage: item.symbol) }
            }
        } label: {
            HStack(spacing: 10) {
                Circle().fill(status.tone.color).frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 1) {
                    Text(parts.first ?? status.text).font(TypeStyle.chip).foregroundStyle(Ink.primary)
                    if parts.count > 1 {
                        Text(parts.dropFirst().joined(separator: " · ")).font(TypeStyle.caption).foregroundStyle(Ink.secondary)
                    }
                }
                .lineLimit(1).minimumScaleFactor(0.85)
                Spacer(minLength: 2)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: TypeStyle.Size.caption, weight: .semibold)).foregroundStyle(Ink.secondary)
            }
            .padding(.horizontal, Space.sm).padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .background { RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(FlatControlSpec.fill(dark: scheme == .dark, reducedTransparency: reduceTransparency).color)
                .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Ink.glassStroke, lineWidth: Radius.hairlineWidth))
                .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(Ink.primary.opacity(hovering ? 0.05 : 0))) }
            .contentShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            // One element for VoiceOver, not one per piece of the label.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Motion source: \(status.text)")
        }
        // A button-style menu keeps the custom label (borderless menus draw only text).
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fieldFocus(radius: 16)
        .hoverLift(shape: RoundedRectangle(cornerRadius: Radius.control), hue: model.screen.hue)
        .onHover { hovering = $0 }
        .accessibilityLabel("Status: \(status.text)")
        .accessibilityHint("Opens buds, demo and session recording actions")
    }
    private func perform(_ item: SidebarStatus.Item) {
        switch item {
        case .openBuds: model.screen = .device
        case .tryDemo: model.startDemo()
        case .stopDemo: model.stopDemo()
        case .recordSession, .stopSession: model.toggleRecording()
        }
    }
}

/// A 44x44 round glass button for a single symbol.
struct IconButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(enabled ? Ink.primary : Ink.tertiary)
            .frame(width: 44, height: 44)
            .background { Circle().fill(FlatControlSpec.fill(dark: scheme == .dark, reducedTransparency: reduceTransparency).color)
                .overlay(Circle().strokeBorder(Ink.glassStroke, lineWidth: 0.5)).overlay(Circle().fill(Ink.primary.opacity(configuration.isPressed ? 0.10 : (hovering ? 0.05 : 0)))) }
            .contentShape(Circle())
            .fieldFocus(radius: 22)
            .hoverLift(shape: Circle(), pressed: configuration.isPressed)
            .onHover { hovering = $0 }
    }
}

/// The buds' connection state, always in the same place.
struct BudsChip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let p = model.sourcePresentation
        StateChip(text: model.isDemo ? "Demo · not real buds" : p.chipText, color: p.tone.color,
                  active: model.hasMotion)
    }
}

extension BudsPresentation.Tone {
    var color: Color {
        switch self {
        case .live: Ink.live
        case .quiet: Ink.tertiary
        case .busy: Ink.warn
        case .danger: Ink.danger
        case .demo: Ink.demo
        }
    }
}

private struct SidebarSelection: ViewModifier {
    var namespace: Namespace.ID
    var reduceMotion: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if reduceMotion { content.transition(.opacity) }
        else { content.matchedGeometryEffect(id: "selection", in: namespace) }
    }
}
