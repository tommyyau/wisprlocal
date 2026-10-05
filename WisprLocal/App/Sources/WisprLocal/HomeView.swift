import SwiftUI
import WisprLocalCore

struct HomeView: View {
    let model: AppModel
    var animate = true
    @State private var adding: HistoryEntry?
    @State private var detail: HistoryEntry?
    /// Rows shown on Home before "See all".
    static let recentLimit = 6

    var body: some View {
        let stats = model.stats
        let timeline = model.timeline
        Page(title: greeting(stats), subtitle: subtitle(stats)) {
            HomeHero(model: model, animate: animate)
            if model.gettingStartedVisible { GettingStartedStack(model: model) }
            if !timeline.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: Theme.Space.m) {
                        recent(Array(timeline.prefix(Self.recentLimit)))
                            .frame(minWidth: 400, maxWidth: .infinity, alignment: .topLeading)
                        HomeStatsPanel(model: model, insights: model.insights)
                            .frame(width: 200)
                    }
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        recent(Array(timeline.prefix(Self.recentLimit)))
                        HomeStatsPanel(model: model, insights: model.insights)
                    }
                }
            } else if !model.gettingStartedVisible { tryIt }
        }
        .sheet(item: Binding(get: { adding.map(IdentifiedEntry.init) }, set: { adding = $0?.entry })) { item in
            AddToDictionarySheet(store: model.dictionary, entry: item.entry) { adding = nil }
        }
        .sheet(item: $detail) { e in
            HistoryDetailView(model: model, entry: e) { detail = nil }
        }
    }

    private func greeting(_ s: HistoryStats) -> String {
        let base = s.totalDictations > 0 ? "Welcome back" : "Welcome"
        return model.greetingName.map { "\(base), \($0)" } ?? base
    }

    private func subtitle(_ s: HistoryStats) -> String {
        if s.totalDictations == 0 { return "Speech recognition and cleanup run on this Mac. Remote Macs sends finished text to a Mac you pair; audio stays here." }
        if s.dictationsToday == 0 { return "Nothing dictated yet today. Hold 🌐 whenever typing feels slow." }
        return "You've dictated \(s.dictationsToday) \(s.dictationsToday == 1 ? "time" : "times") today."
    }

    // MARK: recent

    private func recent(_ items: [HistoryEntry]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            ForEach(DayGrouping.groups(items, now: model.now), id: \.title) { g in
                DaySection(title: g.title, entries: g.entries) { e in
                    DictationRow(model: model, entry: e, isDictating: model.clipIDs.contains(e.id) && model.isDictating,
                                 isPlaying: model.playback.isPlaying(e.id), hasClip: model.clipIDs.contains(e.id),
                                 previewHovered: model.previewHoverID == e.id, lineLimit: 3, addWord: { adding = e }, showDetails: { detail = e }).equatable()
                }
            }
            Button { model.section = .history } label: {
                HStack(spacing: 4) {
                    Text("All history")
                    Image(systemName: "arrow.right").font(Theme.Typo.micro)
                }
                .font(Theme.Typo.chip).foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain).padding(.leading, Theme.Space.xxs)
        }
    }

    private var tryIt: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: "sparkles").font(Theme.Typo.icon).foregroundStyle(Theme.accent)
                .frame(width: 44, height: 44).background(Circle().fill(Theme.accentSoft))
            VStack(alignment: .leading, spacing: 3) {
                Text("Try it now").font(Theme.Typo.bodyEmphasis)
                Text("Click into any text box, hold 🌐, say “Hello from WisprLocal”, then let go. Your dictations will show up here.")
                    .font(Theme.Typo.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("How it works") { model.section = .help }.buttonStyle(BrandButtonStyle(prominent: false))
        }
        .card()
    }
}

/// Home's right-hand column: the three numbers people check, large, linking to Insights.
struct HomeStatsPanel: View {
    let model: AppModel
    let insights: Insights

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            stat("Total words", Format.number(insights.totalWords), nil)
            divider
            stat("Average speed", insights.averageWPM > 0 ? "\(insights.averageWPM)" : "—", insights.averageWPM > 0 ? "wpm" : nil)
            divider
            stat("Current streak", "\(insights.currentStreak)", insights.currentStreak == 1 ? "day" : "days")
            Button { model.section = .insights } label: {
                HStack(spacing: 4) {
                    Text("See insights")
                    Image(systemName: "arrow.right").font(Theme.Typo.micro)
                }
                .font(Theme.Typo.chip).foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, Theme.Space.m)
            Label("Audio never leaves this Mac", systemImage: "lock.fill")
                .font(Theme.Typo.footnote).foregroundStyle(.tertiary)
                .labelStyle(.titleAndIcon)
                .padding(.top, Theme.Space.snug)
        }
        .padding(Theme.Space.m)  // the standard card inset; ml wraps the privacy footnote
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.cardBorder))
        .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
        .padding(.top, Theme.Space.l)
    }

    private var divider: some View { Rectangle().fill(Theme.separator).frame(height: 1).padding(.vertical, Theme.Space.ms) }

    private func stat(_ label: String, _ value: String, _ unit: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased()).font(Theme.Typo.groupHeader).kerning(0.8).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value).font(Theme.Typo.bigNumber).monospacedDigit()
                    .contentTransition(.numericText())
                    .lineLimit(1).minimumScaleFactor(0.6)
                if let unit { Text(unit).font(Theme.Typo.numberUnit).foregroundStyle(.secondary) }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Copy with a brief "Copied" confirmation.
struct CopyButton: View {
    let text: String
    var size: CGFloat = 26
    @State private var copied = false
    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task { try? await Task.sleep(for: .seconds(1.4)); copied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(Theme.Typo.chip)
                .foregroundStyle(copied ? Theme.positive : .secondary)
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .pointerStyle(.link)
        .help(copied ? "Copied" : "Copy text")
        .accessibilityLabel("Copy text")
    }
}

private struct HomeHero: View {
    let model: AppModel
    var animate: Bool
    private var waveTime: Double? { animate ? nil : 2.1 }
    var body: some View {
        let r = model.readiness
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous).fill(Theme.heroGradient)
            // Decorative wave across the hero's lower edge.
            WaveMotif(bars: 46, barWidth: 4, gap: 8, maxHeight: 64, intensity: 0.75, time: waveTime)
                .edgeFade()
                .opacity(0.22)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .offset(y: 26)
                .clipped()
            HStack(alignment: .center, spacing: Theme.Space.l) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("PUSH TO TALK").font(Theme.Typo.eyebrow).kerning(1).foregroundStyle(Theme.mint.opacity(0.9))
                    HStack(spacing: 10) {
                        Text("Hold").font(Theme.Typo.display)
                        KeyCap(size: 38).environment(\.colorScheme, .dark)
                        Text("and speak.").font(Theme.Typo.display)
                    }
                    .foregroundStyle(.white)
                    Text("Let go and your words land wherever the cursor is: email, Slack, your editor. Double-tap for hands-free.")
                        .font(Theme.Typo.body).foregroundStyle(.white.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 400, alignment: .leading)
                    HStack(spacing: 6) {
                        Circle().fill(r.ok ? Theme.mint : Theme.onDarkWarning).frame(width: 7, height: 7)
                            .shadow(color: (r.ok ? Theme.mint : Theme.onDarkWarning).opacity(0.8), radius: 4)
                        Text(r.text).font(Theme.Typo.chip).foregroundStyle(.white.opacity(0.88))
                        if model.setupIssues.contains(where: { $0.hasAction }) {
                            Button("Fix") { model.settingsRequest = .setup; model.section = .settings }
                                .buttonStyle(BrandButtonStyle()).controlSize(.small)
                        }
                    }
                    .padding(.top, Theme.Space.xxs)
                }
                Spacer(minLength: 0)
                Orb(size: 132, time: waveTime)
                    .padding(.trailing, Theme.Space.xs)
            }
            .padding(Theme.Space.xl)
        }
        .frame(minHeight: 220)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .shadow(color: Theme.indigo.opacity(0.25), radius: 16, y: 8)
    }

}
