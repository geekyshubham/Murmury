import SwiftUI

enum DetailDestination: String, CaseIterable, Identifiable {
    case signals, dataset, evaluation, detections, commands, help
    var id: Self { self }
    var title: String { rawValue.capitalized }
}
/// A sheet: title, scrolling body, and (for workflows) a fixed footer holding the sheet's actions,
/// so Cancel and the primary action stay in one place whatever state the body is in.
struct DetailSheet<Content: View, Footer: View>: View {
    var title: String
    var hue: Hue
    var showClose = true
    var onClose: (() -> Void)? = nil
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(title).font(TypeStyle.sheetTitle).foregroundStyle(Ink.primary).accessibilityAddTraits(.isHeader)
                Spacer()
                if showClose { Button("Done") { onClose?(); dismiss() }.keyboardShortcut(.cancelAction) }
            }
            // Title, body and footer share one left edge: the body adds only vertical room for focus rings.
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) { content }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, Space.xxs)
            }
            if Footer.self != EmptyView.self { footer.controlSize(.large) }
        }
        .padding(Space.gutter)
        .frame(minWidth: 720, idealWidth: 760, minHeight: 560, idealHeight: 600)
        .background(Ink.night)
        .environment(\.fieldHue, hue)
        .foregroundStyle(Ink.primary).buttonStyle(.quiet)
    }
}

/// A workflow sheet's footer in fixed slots: Cancel at the left, then a secondary and a primary
/// action at the right, each the same size in every state, so no target moves when the state
/// changes (a head pointer aims once). Empty slots keep their room and take no clicks.
struct SheetFooter<Cancel: View, Secondary: View, Primary: View>: View {
    static var height: CGFloat { 44 }
    static var cancelWidth: CGFloat { 88 }
    static var actionWidth: CGFloat { 136 }
    @ViewBuilder var cancel: Cancel
    @ViewBuilder var secondary: Secondary
    @ViewBuilder var primary: Primary
    var body: some View {
        HStack(spacing: Space.sm) {
            cancel.frame(width: Self.cancelWidth, alignment: .leading)
            Spacer(minLength: 0)
            secondary.frame(width: Self.actionWidth, alignment: .trailing)
            primary.frame(width: Self.actionWidth, alignment: .trailing)
        }
        .frame(height: Self.height)
    }
}
/// A footer button that fills its slot, so its bounds and centre are the same whatever its title.
struct SlotButton: View {
    var title: String
    var action: () -> Void
    init(_ title: String, action: @escaping () -> Void) { self.title = title; self.action = action }
    var body: some View {
        Button(action: action) { Text(title).lineLimit(1).minimumScaleFactor(0.9).frame(maxWidth: .infinity) }
    }
}

extension DetailSheet where Footer == EmptyView {
    init(title: String, hue: Hue, showClose: Bool = true, onClose: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, hue: hue, showClose: showClose, onClose: onClose, content: content, footer: { EmptyView() })
    }
}

struct DetailLink: View {
    var destination: DetailDestination
    var title: String? = nil
    @Environment(AppModel.self) private var model
    var body: some View { Button(title ?? destination.title + "…") { model.detailSheet = destination } }
}

struct DetailDestinationView: View {
    var destination: DetailDestination
    var body: some View {
        switch destination {
        case .signals: SignalsSheet()
        case .dataset: DatasetSheet()
        case .evaluation: EvaluationSheet()
        case .detections: DetectionsSheet()
        case .commands: CommandsSheet()
        case .help: HelpSheet()
        }
    }
}
