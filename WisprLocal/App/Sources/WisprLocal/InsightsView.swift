import AppKit
import SwiftUI
import WisprLocalCore

/// Insights › Your usage: speed, cleanup, words, where you dictate, and your streak. Everything
/// is computed on this Mac from History (`InsightsCalculator`, cached and incremental).
struct InsightsView: View {
    let model: AppModel

    var body: some View {
        let i = model.insights
        Page(title: "Insights", subtitle: "How you use your voice, worked out on this Mac from your History.") {
            tabs
            if i.totalDictations == 0 { emptyBanner }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: Theme.Space.m) {
                    SpeedTile(insights: i).frame(minWidth: 276, maxWidth: .infinity)
                    WordsTile(insights: i).frame(minWidth: 276, maxWidth: .infinity)
                }
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    SpeedTile(insights: i)
                    WordsTile(insights: i)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            CleanupTile(insights: i)
            WhereTile(insights: i, initiallyExpanded: model.live == nil ? model.sample.expandedCategory : nil)
            StreakTile(insights: i, now: model.now)
            OnThisMacFooter(model: model)
        }
    }

    /// One tab today; the bar leaves room for more without pretending there are any.
    private var tabs: some View {
        HStack(spacing: Theme.Space.l) {
            VStack(spacing: 7) {
                Text("Your usage").font(Theme.Typo.section)
                Capsule().fill(Theme.accent).frame(height: 2)
            }
            .fixedSize()
            Spacer()
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 1) }
    }

    private var emptyBanner: some View {
        HStack(spacing: Theme.Space.m) {
            Orb(size: 40, time: 1.2)
            VStack(alignment: .leading, spacing: 3) {
                Text("Your insights fill in as you dictate").font(Theme.Typo.bodyEmphasis)
                Text("Hold 🌐 in any app and speak. Speed, cleanup and your streak appear here after the first few dictations.")
                    .font(Theme.Typo.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .card()
    }
}

// MARK: - Tile chrome

/// The Insights card: an eyebrow label with an icon, then content. Fills its row's height.
struct InsightTile<Content: View>: View {
    let title: String
    let symbol: String
    var trailing: AnyView? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(Theme.Typo.symbol.weight(.semibold)).foregroundStyle(Theme.accent)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.well, style: .continuous).fill(Theme.accentSoft))
                Text(title.uppercased()).font(Theme.Typo.groupHeader).kerning(0.8).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let trailing { trailing }
            }
            content
        }
        .padding(Theme.Space.ml)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.cardBorder))
        .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
    }
}

/// Large rounded numeral with an optional unit.
struct BigNumber: View {
    let value: String
    var unit: String?
    var font: Font = Theme.Typo.heroNumber
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(value).font(font).monospacedDigit()
                .contentTransition(.numericText()).lineLimit(1).minimumScaleFactor(0.6)
            if let unit { Text(unit).font(Theme.Typo.numberUnit).foregroundStyle(.secondary) }
        }
    }
}

// MARK: - Speed

struct SpeedTile: View {
    let insights: Insights
    static let maxWPM = 220.0

    var body: some View {
        let wpm = insights.averageWPM
        InsightTile(title: "Speaking speed", symbol: "speedometer") {
            VStack(spacing: 10) {
                SpeedGauge(value: Double(wpm), maxValue: Self.maxWPM, benchmark: Insights.typingWPM)
                    .frame(maxWidth: 236).frame(height: 136)
                    .overlay(alignment: .bottom) {
                        VStack(spacing: 0) {
                            Text(wpm > 0 ? "\(wpm)" : "—").font(Theme.Typo.heroNumber).monospacedDigit()
                            Text("words per minute").font(Theme.Typo.statLabel).foregroundStyle(.secondary)
                        }
                    }
                Text(caption).font(Theme.Typo.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(wpm > 0 ? "Speaking speed \(wpm) words per minute. \(caption)" : caption)
    }

    private var caption: String {
        let x = insights.timesFasterThanTyping
        guard x > 0 else { return "Dictate a few sentences to see your speed." }
        if x < 1.1 { return "About as fast as typing (≈ \(Int(Insights.typingWPM)) wpm)." }
        return "≈ \(x.formatted(.number.precision(.fractionLength(1))))× faster than typing at \(Int(Insights.typingWPM)) wpm"
    }
}

/// A 180° gauge: a soft track, a mint value arc, and a tick marking the typing benchmark.
struct SpeedGauge: View {
    let value: Double
    let maxValue: Double
    let benchmark: Double
    var lineWidth: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let r = min(w / 2, h) - lineWidth / 2 - 2
            let c = CGPoint(x: w / 2, y: r + lineWidth / 2 + 2)
            let f = max(0, min(1, value / maxValue))
            let b = max(0, min(1, benchmark / maxValue))
            ZStack {
                ArcShape(center: c, radius: r, from: 0, to: 1)
                    .stroke(Theme.inset, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                if f > 0 {
                    ArcShape(center: c, radius: r, from: 0, to: f)
                        .stroke(AngularGradient(colors: [Theme.mintDeep.opacity(0.75), Theme.mint, Theme.accent],
                                                center: UnitPoint(x: c.x / w, y: c.y / h),
                                                startAngle: .degrees(180), endAngle: .degrees(360)),
                                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .shadow(color: Theme.mint.opacity(0.35), radius: 6)
                }
                // Typing benchmark tick + label.
                let a = Angle.degrees(180 + 180 * b).radians
                let inner = r - lineWidth / 2 - 3, outer = r + lineWidth / 2 + 3
                Path { p in
                    p.move(to: CGPoint(x: c.x + cos(a) * inner, y: c.y + sin(a) * inner))
                    p.addLine(to: CGPoint(x: c.x + cos(a) * outer, y: c.y + sin(a) * outer))
                }
                .stroke(Color.primary.opacity(0.55), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                Text("typing")
                    .font(Theme.Typo.axis.weight(.semibold)).foregroundStyle(.secondary)
                    .position(x: c.x + cos(a) * (inner - 22), y: c.y + sin(a) * (inner - 14))
                Text("0").font(Theme.Typo.axis).foregroundStyle(.tertiary)
                    .position(x: c.x - r, y: c.y + lineWidth / 2 + 10)
                Text("\(Int(maxValue))").font(Theme.Typo.axis).foregroundStyle(.tertiary)
                    .position(x: c.x + r, y: c.y + lineWidth / 2 + 10)
            }
        }
        .accessibilityHidden(true)
    }
}

/// An arc of the top semicircle, `from`/`to` in 0…1 (left → right).
struct ArcShape: Shape {
    let center: CGPoint
    let radius: CGFloat
    let from: Double
    let to: Double
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addArc(center: center, radius: radius, startAngle: .degrees(180 + 180 * from), endAngle: .degrees(180 + 180 * to),
                 clockwise: false)
        return p
    }
}

// MARK: - Words

struct WordsTile: View {
    let insights: Insights

    var body: some View {
        InsightTile(title: "Words dictated", symbol: "text.word.spacing", trailing: chip) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                BigNumber(value: Format.number(insights.totalWords))
                VStack(spacing: 0) {
                    row("This month", Format.number(insights.wordsThisMonth))
                    row("Dictations", Format.number(insights.totalDictations))
                    row("Estimated time saved (vs 40 wpm typing)", insights.timeSaved > 0 ? Format.duration(insights.timeSaved) : "—", last: true)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var chip: AnyView? {
        guard let c = insights.monthChange else { return nil }
        let up = c >= 0
        let pct = Int((abs(c) * 100).rounded())
        return AnyView(
            HStack(spacing: 3) {
                Image(systemName: up ? "arrow.up.right" : "arrow.down.right").font(Theme.Typo.micro)
                Text("\(up ? "+" : "−")\(pct)% this month")
            }
            .font(Theme.Typo.figureCaption.weight(.semibold))
            .foregroundStyle(up ? Theme.accent : Color.secondary)
            .padding(.horizontal, Theme.Space.xs).frame(height: 22)
            .background(Capsule().fill(up ? Theme.accentSoft : Theme.inset))
            .help("Compared with the same point last month (\(Format.number(insights.wordsLastMonthToDate)) words by this day).")
        )
    }

    private func row(_ label: String, _ value: String, last: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label).foregroundStyle(.secondary)
                Spacer()
                Text(value).font(Theme.Typo.figure).monospacedDigit()
            }
            .font(Theme.Typo.body)
            .padding(.vertical, Theme.Space.xs)
            if !last { Rectangle().fill(Theme.separator).frame(height: 1) }
        }
    }
}

// MARK: - Cleanup

struct CleanupTile: View {
    let insights: Insights

    var body: some View {
        let c = insights.cleanup
        InsightTile(title: "Cleanup", symbol: "wand.and.sparkles") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .topLeading)],
                      alignment: .leading, spacing: Theme.Space.m) {
                VStack(alignment: .leading, spacing: 2) {
                    BigNumber(value: Format.number(c.total))
                    Text(c.total == 1 ? "edit made for you" : "edits made for you").font(Theme.Typo.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                part("Fillers removed", "“um”, “uh”, “you know”", c.fillers, c.total)
                part("Dictionary fixes", "your words, spelled right", c.dictionary, c.total)
                part("Formatting", "punctuation, capitals, lists", c.formatting, c.total)
            }
        }
        .help("Counted by comparing what was heard with what was typed, for every delivered dictation.")
    }

    private func part(_ title: String, _ detail: String, _ n: Int, _ total: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Theme.Typo.caption.weight(.medium)).foregroundStyle(.secondary)
            Text(Format.number(n)).font(Theme.Typo.statValue).monospacedDigit()
            Bar(fraction: total > 0 ? Double(n) / Double(total) : 0, height: 5)
            Text(detail).font(Theme.Typo.caption).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A thin horizontal meter on an inset track.
struct Bar: View {
    let fraction: Double
    var height: CGFloat = 8
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.inset)
                if fraction > 0 {
                    Capsule().fill(Theme.accent.opacity(0.85))
                        .frame(width: max(height, g.size.width * fraction))
                }
            }
        }
        .frame(height: height)
    }
}

// MARK: - Where you dictate

struct WhereTile: View {
    let insights: Insights
    @State private var expanded: AppCategory?

    init(insights: Insights, initiallyExpanded: AppCategory? = nil) {
        self.insights = insights
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        InsightTile(title: "Where you dictate", symbol: "square.grid.2x2",
                    trailing: insights.appsUsed > 0 ? AnyView(appsUsed) : nil) {
            if insights.categories.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("The apps you dictate into will show up here, grouped into AI tools, code, messages, email, docs and browser.")
                        .font(Theme.Typo.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    ForEach([AppCategory.ai, .messages, .email], id: \.self) { c in placeholderRow(c) }
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(insights.categories) { u in categoryRow(u) }
                }
            }
        }
    }

    private var appsUsed: some View {
        HStack(spacing: 4) {
            Text("Apps used").foregroundStyle(.secondary)
            Text("\(insights.appsUsed)").fontWeight(.semibold).monospacedDigit()
        }
        .font(Theme.Typo.figureCaption)
    }

    private func categoryRow(_ u: CategoryUsage) -> some View {
        let open = expanded == u.category
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy) { expanded = open ? nil : u.category }
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: u.category.symbol).font(Theme.Typo.symbol).foregroundStyle(.secondary)
                            .frame(width: 16)
                        Text(u.category.title).font(Theme.Typo.bodyEmphasis)
                        Image(systemName: "chevron.right").font(Theme.Typo.micro).foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(open ? 90 : 0))
                        Spacer()
                        Text("\(Int((u.fraction * 100).rounded()))%").font(Theme.Typo.figure)
                            .monospacedDigit()
                        Text(Format.number(u.dictations)).font(Theme.Typo.figureCaption).monospacedDigit()
                            .foregroundStyle(.tertiary).frame(minWidth: 30, alignment: .trailing)
                    }
                    Bar(fraction: u.fraction, height: 6).padding(.leading, Theme.Space.l)
                }
                .padding(.vertical, Theme.Space.tight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .accessibilityLabel("\(u.category.title), \(Int((u.fraction * 100).rounded())) percent, \(u.dictations) dictations")
            .accessibilityHint(open ? "Hide top apps" : "Show top apps")
            if open {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(u.topApps) { a in appRow(a) }
                }
                .padding(.leading, Theme.Space.l).padding(.bottom, Theme.Space.tight)
                .transition(.opacity)
            }
        }
    }

    private func appRow(_ a: AppUsage) -> some View {
        let app = AppIdentity.lookup(a.bundleID)
        return HStack(spacing: 8) {
            Image(nsImage: app.icon).resizable().frame(width: 18, height: 18)
            Text(app.name).font(Theme.Typo.body)
            Spacer()
            Text("\(Format.number(a.dictations)) · \(Format.number(a.words)) words")
                .font(Theme.Typo.figureCaption).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.horizontal, Theme.Space.snug).padding(.vertical, Theme.Space.tight)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).fill(Theme.inset.opacity(0.7)))
    }

    private func placeholderRow(_ c: AppCategory) -> some View {
        HStack(spacing: 8) {
            Image(systemName: c.symbol).font(Theme.Typo.symbol.weight(.regular)).foregroundStyle(.tertiary).frame(width: 16)
            Text(c.title).font(Theme.Typo.body).foregroundStyle(.tertiary).frame(width: 96, alignment: .leading)
            Bar(fraction: 0, height: 6)
        }
        .padding(.vertical, Theme.Space.xxs)
    }
}

// MARK: - Streak heatmap

struct StreakTile: View {
    let insights: Insights
    let now: Date
    static let weeks = 26
    /// 0 = the 26 weeks ending this week; 1 = the 26 before that, …
    @State private var page = 0

    /// Sunday-first weeks, Sun–Sat rows.
    private var calendar: Calendar {
        var c = Calendar.current
        c.firstWeekday = 1
        return c
    }

    var body: some View {
        InsightTile(title: "Streak", symbol: "flame", trailing: AnyView(nav)) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xl) {
                    VStack(alignment: .leading, spacing: 2) {
                        BigNumber(value: "\(insights.currentStreak)", unit: insights.currentStreak == 1 ? "day" : "days")
                        Text("Current streak").font(Theme.Typo.caption).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        BigNumber(value: "\(insights.longestStreak)", unit: insights.longestStreak == 1 ? "day" : "days", font: Theme.Typo.statValue)
                        Text("Longest streak").font(Theme.Typo.caption).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        BigNumber(value: "\(insights.days.count)", font: Theme.Typo.statValue)
                        Text("Active days").font(Theme.Typo.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                ScrollView(.horizontal) {
                    Heatmap(insights: insights, weeks: grid, today: calendar.startOfDay(for: now), calendar: calendar)
                }
                .defaultScrollAnchor(.trailing)
                legend
            }
        }
    }

    /// Week start dates for the visible page, oldest first.
    private var grid: [Date] {
        let cal = calendar
        let thisWeek = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? cal.startOfDay(for: now)
        let last = cal.date(byAdding: .weekOfYear, value: -page * Self.weeks, to: thisWeek) ?? thisWeek
        return (0..<Self.weeks).reversed().compactMap { cal.date(byAdding: .weekOfYear, value: -$0, to: last) }
    }

    private var hasOlder: Bool {
        guard let first = grid.first, let earliest = insights.days.keys.min() else { return false }
        return earliest < first
    }

    private var nav: some View {
        HStack(spacing: 2) {
            Text(rangeLabel).font(Theme.Typo.statLabel).foregroundStyle(.secondary).padding(.trailing, Theme.Space.tight)
            navButton("chevron.left", "Earlier", enabled: hasOlder) { page += 1 }
            navButton("chevron.right", "Later", enabled: page > 0) { page -= 1 }
        }
    }

    private var rangeLabel: String {
        guard let first = grid.first, let last = grid.last else { return "" }
        let end = min(calendar.date(byAdding: .day, value: 6, to: last) ?? last, now)
        let f = Date.FormatStyle.dateTime.month(.abbreviated).year()
        return "\(first.formatted(f)) – \(end.formatted(f))"
    }

    private func navButton(_ symbol: String, _ label: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(Theme.Typo.symbol.weight(.semibold))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Theme.inset))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.4))
        .disabled(!enabled)
        .help(label)
        .accessibilityLabel(label)
    }

    private var legend: some View {
        HStack(spacing: 5) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: Theme.Radius.tiny, style: .continuous).strokeBorder(Theme.accent, lineWidth: 1.5)
                    .frame(width: 11, height: 11)
                Text("Current streak")
            }
            Spacer()
            Text("Less")
            ForEach(0..<5) { l in
                RoundedRectangle(cornerRadius: Theme.Radius.tiny, style: .continuous).fill(Heatmap.color(level: l)).frame(width: 11, height: 11)
            }
            Text("More")
        }
        .font(Theme.Typo.caption).foregroundStyle(.secondary)
    }
}

/// Weeks as columns, Sun–Sat as rows, month labels on top. Days of the current streak are
/// outlined; future days are left blank.
struct Heatmap: View {
    let insights: Insights
    let weeks: [Date]
    let today: Date
    let calendar: Calendar
    static let gap: CGFloat = 4
    static let labelWidth: CGFloat = 28
    static let cell: CGFloat = 19

    static func color(level: Int) -> Color {
        switch level {
        case 0: Theme.inset
        case 1: Theme.accent.opacity(0.22)
        case 2: Theme.accent.opacity(0.42)
        case 3: Theme.accent.opacity(0.68)
        default: Theme.accent
        }
    }

    var body: some View {
        let cell = Self.cell
        VStack(alignment: .leading, spacing: 6) {
            // Month labels: over the first week that contains a 1st (and the first column).
            ZStack(alignment: .topLeading) {
                ForEach(Array(weeks.enumerated()), id: \.offset) { i, w in
                    if let m = monthLabel(i, w) {
                        Text(m).font(Theme.Typo.footnote).foregroundStyle(.secondary)
                            .fixedSize()
                            .offset(x: Self.labelWidth + CGFloat(i) * (cell + Self.gap))
                    }
                }
            }
            .frame(height: 13, alignment: .topLeading)
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: Self.gap) {
                    ForEach(0..<7) { r in
                        Text(r == 1 ? "Mon" : r == 3 ? "Wed" : r == 5 ? "Fri" : "")
                            .font(Theme.Typo.axis).foregroundStyle(.tertiary)
                            .frame(width: Self.labelWidth, height: cell, alignment: .leading)
                    }
                }
                HStack(alignment: .top, spacing: Self.gap) {
                    ForEach(Array(weeks.enumerated()), id: \.offset) { _, w in
                        VStack(spacing: Self.gap) {
                            ForEach(0..<7) { r in dayCell(w, r, cell) }
                        }
                    }
                }
                .overlay(alignment: .topLeading) {
                    streakOutline(cell).stroke(Theme.accent, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                }
            }
        }
        .frame(width: Self.labelWidth + CGFloat(weeks.count) * cell + CGFloat(max(0, weeks.count - 1)) * Self.gap)
        .accessibilityElement()
        .accessibilityLabel("Activity over the last \(weeks.count) weeks. Current streak \(insights.currentStreak) days, longest \(insights.longestStreak).")
    }


    /// One outline around all of the current streak's days (cells unioned, so it reads as a shape).
    private func streakOutline(_ cell: CGFloat) -> Path {
        guard let start = insights.currentStreakStart else { return Path() }
        var shape = Path()
        let pad = Self.gap / 2 + 0.5
        for (col, w) in weeks.enumerated() {
            for r in 0..<7 {
                guard let d = calendar.date(byAdding: .day, value: r, to: w) else { continue }
                let day = calendar.startOfDay(for: d)
                guard day >= start, day <= today else { continue }
                let rect = CGRect(x: CGFloat(col) * (cell + Self.gap) - pad, y: CGFloat(r) * (cell + Self.gap) - pad,
                                  width: cell + 2 * pad, height: cell + 2 * pad)
                shape = shape.union(Path(rect))
            }
        }
        return shape
    }

    private func monthLabel(_ i: Int, _ weekStart: Date) -> String? {
        let f = Date.FormatStyle.dateTime.month(.abbreviated)
        if i == 0 {
            // Skip the first column's label when a new month starts within the next two weeks.
            if let next = calendar.date(byAdding: .day, value: 14, to: weekStart),
               calendar.component(.month, from: next) != calendar.component(.month, from: weekStart) { return nil }
            return weekStart.formatted(f)
        }
        for d in 0..<7 {
            guard let day = calendar.date(byAdding: .day, value: d, to: weekStart) else { continue }
            if calendar.component(.day, from: day) == 1 { return day.formatted(f) }
        }
        return nil
    }

    @ViewBuilder private func dayCell(_ weekStart: Date, _ row: Int, _ size: CGFloat) -> some View {
        let day = calendar.startOfDay(for: calendar.date(byAdding: .day, value: row, to: weekStart) ?? weekStart)
        let shape = RoundedRectangle(cornerRadius: max(2, size * 0.22), style: .continuous)
        if day > today {
            Color.clear.frame(width: size, height: size)
        } else {
            let words = insights.days[day]?.words ?? 0
            shape.fill(Self.color(level: insights.heatLevel(words: words)))
                .overlay { if day == today { shape.strokeBorder(Color.primary.opacity(0.35), lineWidth: 1) } }
                .frame(width: size, height: size)
                .help("\(day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())): \(words == 0 ? "no dictation" : "\(Format.number(words)) words")")
        }
    }
}

// MARK: - Footer

/// What makes WisprLocal different, said plainly: local audio, and replay with Heard vs Inserted.
struct OnThisMacFooter: View {
    let model: AppModel

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.heroGradient)
            WaveMotif(bars: 40, barWidth: 3, gap: 7, maxHeight: 44, intensity: 0.7, time: 2.4)
                .edgeFade().opacity(0.16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .offset(x: 40)
            HStack(alignment: .top, spacing: Theme.Space.l) {
                point("lock.shield", "Your audio never leaves this Mac",
                      "Speech recognition, cleanup and these numbers are all worked out locally. No account, no upload.")
                point("waveform.badge.magnifyingglass", "Replay and compare",
                      "With troubleshooting recordings on, replay any dictation and see Heard vs Inserted side by side, word for word.")
            }
            .padding(Theme.Space.ml)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .environment(\.colorScheme, .dark)
    }

    private func point(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(Theme.Typo.bodyEmphasis).foregroundStyle(Theme.mint)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).fill(Theme.mint.opacity(0.12)))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.Typo.bodyEmphasis).foregroundStyle(.white)
                Text(text).font(Theme.Typo.caption).foregroundStyle(.white.opacity(0.68)).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
