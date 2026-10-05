import AppKit
import SwiftUI
import WisprLocalCore

extension HistoryEntry {
    /// Refused or failed attempts the lists show as a muted row (no text: SEC-2). Silence and
    /// "nothing left after cleanup" are noise and stay hidden.
    var showsAsOutcomeRow: Bool {
        switch outcome {
        case .inserted, .noSpeech, .emptyAfterCleanup: false
        case .blockedByConflict, .blockedBySecureInput, .focusChanged, .transcriptionTimedOut, .insertFailed,
             .transcriptionFailed, .blockedByRemoteSecureInput, .noTextRecognised, .cancelled: true
        }
    }

    /// One plain line for a muted outcome row. Never contains dictated text.
    var outcomeRowText: String {
        switch outcome {
        case .inserted: "Inserted"
        case .noSpeech: "No speech heard"
        case .emptyAfterCleanup: "Nothing left to insert"
        case .noTextRecognised: "Didn't catch that — the mic heard you, but no words came out"
        case .blockedBySecureInput: "Not inserted — a password field was focused"
        case .blockedByRemoteSecureInput: "Not inserted — a password field was focused on the other Mac"
        case .blockedByConflict: "Not inserted — Wispr Flow was running"
        case .focusChanged: "Not inserted — you switched apps while speaking"
        case .insertFailed: "Not inserted — the app didn't accept the text"
        case .transcriptionTimedOut, .transcriptionFailed: "Not transcribed — the speech model didn't finish"
        case .cancelled: note == Self.microphoneInterruptedNote ? Self.microphoneInterruptedNote : "Cancelled — nothing was inserted"
        }
    }

    var outcomeRowSymbol: String {
        switch outcome {
        case .blockedBySecureInput, .blockedByRemoteSecureInput: "lock"
        case .blockedByConflict: "pause.circle"
        case .focusChanged: "arrow.uturn.backward"
        case .noTextRecognised: "waveform.badge.exclamationmark"
        case .cancelled: "xmark.circle"
        default: "exclamationmark.circle"
        }
    }
}

/// Groups newest-first entries into Today / Yesterday / weekday-date sections.
enum DayGrouping {
    static func groups(_ items: [HistoryEntry], now: Date, calendar cal: Calendar = .autoupdatingCurrent) -> [(title: String, entries: [HistoryEntry])] {
        var out: [(title: String, entries: [HistoryEntry])] = []
        var titles: [Date: String] = [:]
        for e in items {
            let day = cal.startOfDay(for: e.timestamp)
            let t = titles[day] ?? title(e.timestamp, now: now, cal: cal)
            titles[day] = t
            if out.last?.title == t { out[out.count - 1].entries.append(e) } else { out.append((t, [e])) }
        }
        return out
    }

    static func title(_ d: Date, now: Date, cal: Calendar) -> String {
        if cal.isDate(d, inSameDayAs: now) { return "Today" }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(d, inSameDayAs: y) { return "Yesterday" }
        return d.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }
}

/// A day's rows in one card, under a small-caps day header.
struct DaySection<Row: View>: View {
    let title: String
    let entries: [HistoryEntry]
    @ViewBuilder let row: (HistoryEntry) -> Row

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(title.uppercased()).font(Theme.Typo.groupHeader).kerning(0.8)
                .foregroundStyle(.secondary).padding(.leading, Theme.Space.xxs)
            VStack(spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { i, e in
                    row(e)
                    if i < entries.count - 1 {
                        Rectangle().fill(Theme.separator).frame(height: 1).padding(.leading, DictationRow.textInset)
                    }
                }
            }
            .card(padding: 0)
        }
    }
}

/// One History / Home row: a time column, the text, and a fixed trailing action area that appears
/// on hover or keyboard focus (▷ play when a clip exists, copy, ••• with details, add to dictionary
/// and delete). Refused or failed attempts render as a muted outcome line with no text (SEC-2).
///
/// Layout (see `HistoryRowLayout`): the text column and the actions are siblings in one HStack, so
/// the text can never run under the buttons. Row text is NOT selectable — a selectable Text is an
/// AppKit text view whose I-beam cursor rect and hit-testing beat any SwiftUI layer drawn over it.
/// Selection lives in the details sheet. A click anywhere off the buttons opens the details.
struct DictationRow: View, @MainActor Equatable {
    static let timeWidth: CGFloat = 64
    static let textInset: CGFloat = Theme.Space.m + timeWidth + Theme.Space.s

    let model: AppModel
    let entry: HistoryEntry
    var isDictating = false
    var isPlaying = false
    var hasClip = false
    var previewHovered = false
    var lineLimit: Int? = nil
    var showRaw = false
    var toggleRaw: (() -> Void)? = nil
    let addWord: () -> Void
    let showDetails: () -> Void
    /// History "Fix a Word…" (smart dictionary); nil hides it.
    var fixWord: (() -> Void)? = nil
    @State private var hover = false
    @FocusState private var focused: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.entry == rhs.entry && lhs.isDictating == rhs.isDictating && lhs.isPlaying == rhs.isPlaying &&
        lhs.hasClip == rhs.hasClip && lhs.previewHovered == rhs.previewHovered && lhs.lineLimit == rhs.lineLimit && lhs.showRaw == rhs.showRaw
    }

    private var hovered: Bool { hover || previewHovered }
    private var isOutcome: Bool { !entry.outcome.retainsContent }
    private var actionCount: Int { HistoryRowLayout.actionCount(retainsContent: !isOutcome) }
    private var actionsVisible: Bool { hovered || focused || isPlaying }

    var body: some View {
        let app = AppIdentity.lookup(entry.frontmostApp)
        HStack(alignment: .top, spacing: Theme.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Text(entry.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(Theme.Typo.chip).monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .frame(width: Self.timeWidth, alignment: .leading)
                VStack(alignment: .leading, spacing: 6) {
                    if isOutcome {
                        HStack(spacing: 6) {
                            Image(systemName: entry.outcomeRowSymbol).font(Theme.Typo.symbol)
                            Text(entry.outcomeRowText)
                        }
                        .font(Theme.Typo.body).foregroundStyle(.secondary)
                    } else {
                        Text(entry.final).font(Theme.Typo.body).lineSpacing(2)
                            .lineLimit(lineLimit)
                            .fixedSize(horizontal: false, vertical: true)
                        if showRaw { heard }
                    }
                    meta(app)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .layoutPriority(1)
            actions
                .frame(width: HistoryRowLayout.actionAreaWidth(buttons: actionCount), alignment: .trailing)
                .padding(.top, -Theme.Space.tight)   // centre the 28 pt targets on the first text line
        }
        .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.ms)
        .background(hovered || focused ? Theme.inset.opacity(0.55) : .clear)
        .contentShape(Rectangle())
        .pointerStyle(.link)
        .onHover { hover = $0 }
        .onTapGesture(perform: showDetails)
        .focusable(interactions: .activate)   // keyboard (Tab / Full Keyboard Access) only; a click opens details
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.return) { showDetails(); return .handled }
        .onKeyPress(.space) { showDetails(); return .handled }
        .contextMenu { menuItems }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens details")
        .accessibilityAction(.default, showDetails)
        .accessibilityActions { accessibilityItems }
    }

    private var accessibilityText: String {
        let time = entry.timestamp.formatted(date: .omitted, time: .shortened)
        let app = AppIdentity.lookup(entry.frontmostApp).name
        return "\(time), \(app): \(isOutcome ? entry.outcomeRowText : entry.final)"
    }

    @ViewBuilder private var accessibilityItems: some View {
        if !isOutcome {
            if hasClip, !isDictating {
                Button(isPlaying ? "Stop playback" : "Play recording") { model.togglePlayback(entry) }
            }
            Button("Copy text") { copy() }
            Button("Add to Dictionary", action: addWord)
            if let fixWord { Button("Fix a Word", action: fixWord) }
        }
        Button("Delete", role: .destructive) { model.delete(entry) }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.final, forType: .string)
    }

    private var heard: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("HEARD").font(Theme.Typo.eyebrow).foregroundStyle(.secondary)
            Text(entry.raw.isEmpty ? "—" : entry.raw).font(Theme.Typo.caption).foregroundStyle(.secondary)
        }
        .padding(Theme.Space.xs).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).fill(Theme.inset))
    }

    private func meta(_ app: (name: String, icon: NSImage)) -> some View {
        FlowLayout(spacing: 6) {
            HStack(spacing: 6) {
                Image(nsImage: app.icon).resizable().frame(width: 14, height: 14)
                Text(app.name).lineLimit(1).help(app.name)
            }
            if !isOutcome {
                Text(Format.clip(entry.speechDuration > 0 ? entry.speechDuration : entry.audioDuration))
                if let t = entry.snippetTrigger { Tag(text: "snippet: \(t)", tint: Theme.accent) }
                if !entry.raw.isEmpty, entry.raw != entry.final, entry.snippetTrigger == nil, !showRaw { Tag(text: "cleaned up") }
            }
        }
        .font(Theme.Typo.caption).foregroundStyle(.secondary)
    }

    private var actions: some View {
        let size = CGFloat(HistoryRowLayout.actionHitSize)
        return HStack(spacing: CGFloat(HistoryRowLayout.actionSpacing)) {
            // ▷ with a clip; without one, PlayControl's subtle disabled waveform (with a tooltip).
            if !isOutcome { PlayControl(model: model, entry: entry, size: size, rowState: .init(isPlaying: isPlaying, isDictating: isDictating, hasClip: hasClip)) }
            if !isOutcome { CopyButton(text: entry.final, size: size) }
            Menu { menuItems } label: {
                Color.clear.frame(width: size, height: size).contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .frame(width: size, height: size)
            .contentShape(Rectangle())
            .pointerStyle(.link)
            .help("More")
            .accessibilityLabel("More actions")
        }
        .padding(.horizontal, CGFloat(HistoryRowLayout.actionCapsuleInset))
        .background(Capsule(style: .continuous).fill(Theme.card))
        .overlay(Capsule(style: .continuous).strokeBorder(Theme.cardBorder))
        .overlay(alignment: .trailing) {
            // Draw the three dots directly: the native Menu symbol can defer drawing when
            // its row is materialised by a lazy stack.
            HStack(spacing: Theme.Space.hair) {
                ForEach(0..<3) { _ in
                    Circle().fill(.secondary).frame(width: Theme.Typo.menuDotDiameter, height: Theme.Typo.menuDotDiameter)
                }
            }
            .frame(width: size, height: size)
            .padding(.trailing, CGFloat(HistoryRowLayout.actionCapsuleInset)).allowsHitTesting(false).accessibilityHidden(true)
        }
        .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
        .opacity(actionsVisible ? 1 : 0)
        .allowsHitTesting(actionsVisible)
        .animation(.easeOut(duration: 0.12), value: actionsVisible)
    }

    @ViewBuilder private var menuItems: some View {
        Button("Show Details…", action: showDetails)
        if !isOutcome {
            Button("Copy") { copy() }
            if let toggleRaw { Button(showRaw ? "Hide What Was Heard" : "Show What Was Heard", action: toggleRaw) }
            Button("Add to Dictionary…", action: addWord)
            if let fixWord { Button("Fix a Word…", action: fixWord) }
        }
        Divider()
        Button("Delete", role: .destructive) { model.delete(entry) }
    }
}

/// Each visible row draws its slice of the day card, including the original one-point
/// divider. Shadows are masked to the exterior so adjacent rows never cast on one another.
struct HistoryCardSlice<Row: View>: View {
    let first: Bool
    let last: Bool
    @ViewBuilder let row: Row

    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: first ? Theme.Radius.card : 0,
            bottomLeadingRadius: last ? Theme.Radius.card : 0, bottomTrailingRadius: last ? Theme.Radius.card : 0,
            topTrailingRadius: first ? Theme.Radius.card : 0, style: .continuous)
        VStack(spacing: 0) {
            row
            if !last { Rectangle().fill(Theme.separator).frame(height: 1).padding(.leading, DictationRow.textInset) }
        }
        .background(shape.fill(Theme.card))
        .overlay {
            shape.strokeBorder(Theme.cardBorder)
                .mask(HStack(spacing: 0) {
                    Color.black.frame(width: 1)
                    VStack(spacing: 0) {
                        if !first { Color.clear.frame(height: 1) }
                        Color.black
                        if !last { Color.clear.frame(height: 1) }
                    }
                    Color.black.frame(width: 1)
                })
        }
        .clipShape(shape)
        .background {
            shape.fill(Theme.card)
                .padding(.top, first ? 0 : -Theme.Space.l).padding(.bottom, last ? 0 : -Theme.Space.l)
                .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
                .mask(Rectangle().padding(.horizontal, -Theme.Space.s).padding(.top, first ? -Theme.Space.s : 0).padding(.bottom, last ? -Theme.Space.s : 0))
        }
        .padding(.bottom, last ? Theme.Space.l : 0)
    }
}
