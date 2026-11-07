import SwiftUI

private struct PageSizeKey: EnvironmentKey { static let defaultValue = CGSize(width: 888, height: 740) }
extension EnvironmentValues {
    /// The page area right of the sidebar, title bar area included.
    var pageSize: CGSize {
        get { self[PageSizeKey.self] }
        set { self[PageSizeKey.self] = newValue }
    }
}

private struct PageActionKey: EnvironmentKey { static let defaultValue = AnyView(EmptyView()) }
private struct PageStopKey: EnvironmentKey { static let defaultValue: (() -> Void)? = nil }
private extension EnvironmentValues {
    var pageAction: AnyView {
        get { self[PageActionKey.self] }
        set { self[PageActionKey.self] = newValue }
    }
    var pageStop: (() -> Void)? {
        get { self[PageStopKey.self] }
        set { self[PageStopKey.self] = newValue }
    }
}

/// The header measures visual, copy and action in one native Layout pass.
struct Page<Content: View, Action: View>: View {
    var stopAction: (() -> Void)? = nil
    @ViewBuilder var content: Content
    @ViewBuilder var action: Action
    var body: some View {
        #if DEBUG
        let _ = BodyCounters.record("Page")
        #endif
        GeometryReader { geometry in
            content
                .environment(\.pageSize, geometry.size)
                .environment(\.pageAction, AnyView(ActionBar { action.entrance(delay: 0.4, offset: 0, scale: 0.88) }))
                .environment(\.pageStop, stopAction)
        }
        .buttonStyle(.quiet)
    }
}

struct Feature: Identifiable {
    var id: String { title }
    var symbol: String
    var title: String
    var detail: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    /// The button's name for VoiceOver when its visible title is ambiguous ("Turn on").
    var actionSpokenTitle: String? = nil
}

enum BenefitMetrics {
    static let tile: CGFloat = 40, minHeight: CGFloat = 56, spacing: CGFloat = Space.md
}

struct BenefitRow<Trailing: View>: View {
    var feature: Feature
    var hue: Hue
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: BenefitMetrics.spacing) {
            GlyphTile(symbol: feature.symbol, hue: hue, size: BenefitMetrics.tile)
            VStack(alignment: .leading, spacing: 2) {
                Text(feature.title).font(TypeStyle.rowTitle).foregroundStyle(Ink.primary)
                if let detail = feature.detail {
                    Text(detail).font(TypeStyle.rowDetail).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            // Title and detail read as one line; the row's button stays its own stop.
            .accessibilityElement(children: .combine)
            if let title = feature.actionTitle, let action = feature.action {
                Spacer(minLength: Space.unit)
                Button(title, action: action).accessibilityLabel(feature.actionSpokenTitle ?? title)
            }
            trailing
        }
        .frame(minHeight: BenefitMetrics.minHeight)
        .accessibilityElement(children: .contain)
    }
}

/// Places the visual and the copy column as one unit (see `PageLayout.composition`).
private struct HeroComposition: Layout {
    var page: CGSize
    var kind: HeroMask.Kind
    private func composition(_ subviews: Subviews) -> PageLayout.Composition {
        // The hero keeps its width in every state, so the copy column never jumps sideways when a
        // notice appears; taller copy uses the unit's full height and scrolls only beyond it.
        let base = PageLayout.composition(in: page, kind: kind)
        let natural = subviews[1].sizeThatFits(ProposedViewSize(width: base.copy.width, height: nil)).height
        return PageLayout.composition(in: page, copyHeight: natural, kind: kind)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { page }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let c = composition(subviews)
        #if DEBUG
        let natural = subviews[1].sizeThatFits(ProposedViewSize(width: c.copy.width, height: nil)).height
        PageFitLog.record(page: page, natural: natural, region: c.region.height, composition: c)
        #endif
        for (index, rect) in [c.visual, c.copy, c.action, CGRect(x: 0, y: 0, width: page.width, height: c.action.minY - 12)].enumerated() {
            guard index < subviews.count else { continue }
            subviews[index].place(at: CGPoint(x: bounds.minX + rect.minX, y: bounds.minY + rect.minY),
                                 proposal: ProposedViewSize(width: rect.width, height: rect.height))
        }
    }
}

#if DEBUG
/// Copy-column measurements for the page-fit probe.
@MainActor enum PageFitLog {
    static var entries: [(page: CGSize, natural: CGFloat, region: CGFloat, composition: PageLayout.Composition)] = []
    nonisolated static func record(page: CGSize, natural: CGFloat, region: CGFloat, composition: PageLayout.Composition) {
        MainActor.assumeIsolated { entries.append((page, natural, region, composition)) }
    }
}
#endif

struct PageHeader<Visual: View, Extra: View>: View {
    var hue: Hue
    var title: String
    var subtitle: String
    var chip: StateChip
    var features: [Feature]
    var notices: [StatusNotice] = []
    var secondary: SecondaryAction? = nil
    var more: [MoreItem] = []
    @ViewBuilder var visual: Visual
    @ViewBuilder var extra: Extra
    @Environment(\.pageSize) private var page
    @Environment(\.pageAction) private var action
    @Environment(\.pageStop) private var stopAction
    var body: some View {
        #if DEBUG
        let _ = BodyCounters.record("PageHeader")
        #endif
        HeroComposition(page: page, kind: hue == .buds || hue == .model ? .product : .head) {
            visual.entrance(delay: 0, offset: 0, scale: 0.96).accessibilitySortPriority(0)
            ViewThatFits(in: .vertical) {
                copy.fixedSize(horizontal: false, vertical: true)
                ScrollView { copy }.scrollIndicators(.automatic)
            }
            action
            if let stopAction { StopTarget(action: stopAction) }
        }
    }
    private var copy: some View {
        VStack(alignment: .leading, spacing: Space.unit) {
            HStack(spacing: Space.sm) {
                chip
                Spacer(minLength: Space.unit)
                if !more.isEmpty { MoreMenu(items: more).accessibilitySortPriority(1.5) }
            }
            .frame(minHeight: 44)  // the same header height on every screen, menu or not
            .entrance(delay: 0.06).accessibilitySortPriority(8.5)  // status first, as it reads on screen
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(TypeStyle.display(width: page.width)).tracking(TypeStyle.displayTracking).foregroundStyle(Ink.primary)
                    .lineLimit(1).minimumScaleFactor(0.8).accessibilityAddTraits(.isHeader)
                    .accessibilitySortPriority(8).entrance(delay: 0.1)
                // One line when it fits; otherwise one sentence per line, never a break mid-phrase.
                ViewThatFits(in: .horizontal) {
                    Text(subtitle).fixedSize()
                    Text(TypeStyle.sentenceLines(subtitle)).fixedSize(horizontal: false, vertical: true)
                }
                .font(TypeStyle.subtitle).lineSpacing(TypeStyle.subtitleLineSpacing).foregroundStyle(Ink.secondary)
                .frame(maxWidth: TypeStyle.subtitleMeasure, alignment: .leading)  // a readable measure, ~40 characters
                    .accessibilitySortPriority(7).entrance(delay: 0.14)
            }
            .padding(.bottom, Space.xxs)
            StatusLine(notices: notices).accessibilitySortPriority(6)
            if !features.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(features.prefix(3).enumerated()), id: \.element.id) { index, feature in
                        BenefitRow(feature: feature, hue: hue) { EmptyView() }
                            .accessibilitySortPriority(5 - Double(index) / 10)
                            .entrance(delay: 0.18 + Double(index) * 0.05)
                    }
                }
            }
            extra.accessibilitySortPriority(3).entrance(delay: 0.3)
            if let secondary {
                SecondaryLink(title: secondary.title, action: secondary.action)
                    .accessibilitySortPriority(2).entrance(delay: 0.34)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
extension PageHeader where Extra == EmptyView {
    init(hue: Hue, title: String, subtitle: String, chip: StateChip, features: [Feature], notices: [StatusNotice] = [],
         secondary: SecondaryAction? = nil, more: [MoreItem] = [], @ViewBuilder visual: () -> Visual) {
        self.init(hue: hue, title: title, subtitle: subtitle, chip: chip, features: features, notices: notices,
                  secondary: secondary, more: more, visual: visual, extra: { EmptyView() })
    }
}

/// A quiet strip for live data under the rows: glass, no outline.
struct LiveStrip<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(.horizontal, Space.md).padding(.vertical, Space.sm)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .cardSurface()
            .accessibilityElement(children: .contain).accessibilitySortPriority(2)
    }
}

struct StatusNotice {
    enum Tone: Int { case info, warn, danger }
    var tone: Tone
    var text: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var actionEnabled = true
    var secondaryTitle: String? = nil
    var secondaryAction: (() -> Void)? = nil
    static func highest(in notices: [Self]) -> Self? {
        notices.enumerated().max { a, b in
            a.element.tone == b.element.tone ? a.offset > b.offset : a.element.tone.rawValue < b.element.tone.rawValue
        }?.element
    }
}
struct StatusLine: View {
    /// The notice icon's column, so wrapped text and stacked buttons share one edge.
    static let iconColumn: CGFloat = 18
    var notices: [StatusNotice]
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        if let notice = StatusNotice.highest(in: notices) {
            let color = notice.tone == .danger ? Ink.danger : (notice.tone == .warn ? Ink.warn : Ink.secondary)
            let symbol = notice.tone == .danger ? "exclamationmark.octagon.fill" : (notice.tone == .warn ? "exclamationmark.triangle.fill" : "info.circle.fill")
            // Buttons sit beside the text when they fit, below it otherwise.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    message(notice, symbol: symbol, color: color)
                    Spacer(minLength: Space.unit)
                    actions(notice)
                }
                VStack(alignment: .leading, spacing: Space.unit) {
                    message(notice, symbol: symbol, color: color)
                    // Under the text, starting on the text's edge (icon column + gap), not the icon's.
                    actions(notice).padding(.leading, StatusLine.iconColumn + 10)
                }
            }
            .padding(.leading, Space.md).padding(.trailing, Space.unit).padding(.vertical, Space.unit).frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            // Tone as a soft tint of the whole card (no side stripe), with the shared hairline; the
            // radius nests the capsule buttons inside it (their 20 + the 8 pt inset).
            .background(Ink.panel, in: RoundedRectangle(cornerRadius: Radius.notice, style: .continuous))
            // Warnings and errors carry their tone across the card; stronger in dark, where the field is deep.
            .background(color.opacity(notice.tone == .info ? 0.0 : 0.10), in: RoundedRectangle(cornerRadius: Radius.notice, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.notice, style: .continuous)
                // Warnings and errors set themselves apart by a stronger edge (stronger in dark), not a
                // heavier fill that would cost the buttons inside their contrast.
                .strokeBorder(notice.tone == .info ? Ink.glassStroke : color.opacity(scheme == .dark ? 0.6 : 0.35), lineWidth: notice.tone == .info ? Radius.hairlineWidth : 1))
            .accessibilityElement(children: .contain).accessibilitySortPriority(6)
        }
    }
    private func message(_ notice: StatusNotice, symbol: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).font(.system(size: TypeStyle.Size.body, weight: .semibold)).foregroundStyle(color)
                .frame(width: StatusLine.iconColumn).accessibilityHidden(true)
            Text(notice.text).font(TypeStyle.status).foregroundStyle(Ink.primary).fixedSize(horizontal: false, vertical: true)
        }
    }
    @ViewBuilder private func noticeButtons(_ notice: StatusNotice) -> some View {
        if let title = notice.actionTitle, let action = notice.action {
            Button(title, action: action).disabled(!notice.actionEnabled)
        }
        if let title = notice.secondaryTitle, let action = notice.secondaryAction {
            Button(title, action: action).buttonStyle(SecondaryLinkStyle()).padding(.leading, Space.xxs)
        }
    }
    @ViewBuilder private func actions(_ notice: StatusNotice) -> some View {
        if notice.actionTitle != nil || notice.secondaryTitle != nil {
            // Side by side when they fit, stacked when not: the column never widens.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Space.xxs) { noticeButtons(notice) }.fixedSize()
                VStack(alignment: .leading, spacing: 6) { noticeButtons(notice) }
            }
        }
    }
}

/// The staggered entrance plays once, for the first screen of a session; after that, switching
/// screens (⌘1–6) shows the new one at once with a quick fade, so it never slows a power user down.
@MainActor enum EntranceGate {
    static var played = false
    static func markPlayed() {
        guard !played else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { played = true }
    }
}

private struct EntranceMotion: ViewModifier {
    var delay: Double
    var offset: CGFloat
    var scale: CGFloat
    @State private var appeared = false
    @State private var staged = !EntranceGate.played
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.opacity(appeared ? 1 : 0)
            .offset(y: appeared || reduceMotion || !staged ? 0 : offset)
            .scaleEffect(appeared || reduceMotion || !staged ? 1 : scale)
            .animation(reduceMotion || !staged ? Motion.spring(true) : Motion.spring.delay(delay), value: appeared)  // the one spring
            .onAppear { appeared = true; EntranceGate.markPlayed() }
            .onDisappear {
                var transaction = Transaction(); transaction.disablesAnimations = true
                withTransaction(transaction) { appeared = false }
            }
    }
}
extension View {
    func entrance(delay: Double, offset: CGFloat = 12, scale: CGFloat = 1) -> some View {
        modifier(EntranceMotion(delay: delay, offset: offset, scale: scale))
    }
}
