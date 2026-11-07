import SwiftUI

/// The one text action a screen may show besides its orb.
struct SecondaryAction {
    var title: String
    var action: () -> Void
}

/// An item in a screen's More menu. Every action moved here keeps a menu-bar command or shortcut.
struct MoreItem: Identifiable {
    var id: String { title }
    var title: String
    var symbol: String
    var role: ButtonRole? = nil
    var action: () -> Void
}

/// 15-point text with a chevron, 44 points tall; only hover draws a fill.
struct SecondaryLink: View {
    var title: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                Image(systemName: "chevron.right").font(.system(size: TypeStyle.Size.caption, weight: .semibold)).accessibilityHidden(true)
            }
        }
        .buttonStyle(SecondaryLinkStyle())
    }
}

struct SecondaryLinkStyle: ButtonStyle {
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(TypeStyle.button)
            .foregroundStyle(enabled ? Ink.primary : Ink.tertiary)
            .padding(.horizontal, Space.sm).frame(minWidth: 44, minHeight: 44)
            .background {
                Capsule().fill(Ink.primary.opacity(configuration.isPressed && enabled ? 0.10 : (hovering && enabled ? 0.06 : 0)))
            }
            .contentShape(Capsule())
            .fieldFocus(radius: 24)
            .hoverLift(shape: Capsule(), pressed: configuration.isPressed)
            .onHover { hovering = $0 }
            .animation(Motion.hover, value: hovering)
            .padding(.leading, -12)
    }
}

/// A 44x44 icon-only menu for the rest of a screen's actions.
struct MoreMenu: View {
    var items: [MoreItem]
    @State private var hovering = false
    @Environment(AppModel.self) private var model
    var body: some View {
        Menu {
            ForEach(items) { item in
                Button(role: item.role, action: item.action) { Label(item.title, systemImage: item.symbol) }
            }
            Divider()
            // Help is one step away on every screen, not only in the menu bar.
            Button { model.detailSheet = .help } label: { Label("Murmury Help", systemImage: "questionmark.circle") }
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 20, weight: .regular))
                .foregroundStyle(Ink.primary)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Ink.primary.opacity(hovering ? 0.08 : 0)))
                .contentShape(Circle())
        }
        // A button-style menu keeps the custom label (borderless menus draw only text).
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 44, height: 44)
        .fieldFocus(radius: 22)
        .hoverLift(shape: Circle())
        .onHover { hovering = $0 }
        .accessibilityLabel("More actions")
        .help("Help and less common actions")
    }
}
