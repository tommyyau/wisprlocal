import SwiftUI
import WisprLocalCore

/// The play slot of a History row: play/stop with a progress ring when a clip exists for the
/// entry's id; otherwise a subtle, disabled waveform whose tooltip says how to get recordings.
struct PlayControl: View {
    let model: AppModel
    let entry: HistoryEntry
    var size: CGFloat = 26

    struct RowState {
        var isPlaying: Bool
        var isDictating: Bool
        var hasClip: Bool
    }
    var rowState: RowState? = nil
    var isPlaying: Bool { rowState?.isPlaying ?? model.playback.isPlaying(entry.id) }
    private var playbackState: HistoryPlayback {
        if let rowState { return HistoryPlayback.of(entry, clipIDs: rowState.hasClip ? [entry.id] : []) }
        return model.playbackState(entry)
    }

    var body: some View {
        switch playbackState {
        case .playable:
            Button { model.togglePlayback(entry) } label: {
                ZStack {
                    Circle().fill(Theme.accentSoft).frame(width: size - 4, height: size - 4)
                    if isPlaying {
                        TimelineView(.animation(minimumInterval: 1.0 / 20)) { _ in
                            ProgressRing(progress: model.playback.progress, diameter: size - 4)
                        }
                    }
                    Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                        .font(Theme.Typo.micro)
                        .foregroundStyle(Theme.accent)
                        .offset(x: isPlaying ? 0 : 0.5)
                }
                .frame(width: size, height: size)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .pointerStyle(.link)
            .disabled(rowState?.isDictating ?? model.isDictating)
            .help(isPlaying ? "Stop" : "Play recording")
            .accessibilityLabel(isPlaying ? "Stop recording playback" : "Play recording")
        case .noClip:
            unavailable(HistoryPlayback.noClipHelp(recordingOn: model.settings.keepDebugRecordings))
        case .outcomeOnly:
            unavailable(entry.outcome.mayKeepDebugAudio ? HistoryPlayback.noClipHelp(recordingOn: model.settings.keepDebugRecordings)
                                                        : "No recording is kept when a dictation is blocked for safety")
        }
    }

    private func unavailable(_ help: String) -> some View {
        Image(systemName: "waveform")
            .font(Theme.Typo.symbol.weight(.regular))
            .foregroundStyle(.tertiary)
            .frame(width: size, height: size)
            .contentShape(Rectangle())
            .help(help)
            .accessibilityLabel("No recording. \(help)")
    }
}

struct ProgressRing: View {
    let progress: Double
    var diameter: CGFloat = 22
    var body: some View {
        ZStack {
            Circle().stroke(Theme.accent.opacity(0.18), lineWidth: 2)
            Circle().trim(from: 0, to: progress)
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: diameter, height: diameter)
    }
}

/// Word-level diff highlight: words cleanup removed are struck through; words it added are mint.
enum DiffText {
    static func heard(_ raw: String, against final: String) -> AttributedString {
        build(WordDiff.pairs(raw, final), side: .a)
    }

    static func inserted(_ final: String, against raw: String) -> AttributedString {
        build(WordDiff.pairs(raw, final), side: .b)
    }

    private enum Side { case a, b }

    private static func build(_ ops: [WordDiff.Pair], side: Side) -> AttributedString {
        var out = AttributedString()
        func add(_ w: String, _ style: (inout AttributedString) -> Void = { _ in }) {
            if !out.characters.isEmpty { out.append(AttributedString(" ")) }
            var s = AttributedString(w)
            style(&s)
            out.append(s)
        }
        for op in ops {
            switch (op, side) {
            case (.same(let a, let b), _): add(side == .a ? a : b)
            case (.onlyA(let w), .a):
                add(w) { $0.strikethroughStyle = .single; $0.foregroundColor = .secondary }
            case (.onlyB(let w), .b):
                add(w) { $0.foregroundColor = Theme.accent; $0.backgroundColor = Theme.accentSoft }
            default: break
            }
        }
        return out.characters.isEmpty ? AttributedString("—") : out
    }
}

/// History › Show Details: what was heard vs what was typed, playback, metadata, and
/// "Re-transcribe with the other model".
struct HistoryDetailView: View {
    let model: AppModel
    let entry: HistoryEntry
    var done: () -> Void = {}
    @State private var fixing = false

    var body: some View {
        let app = AppIdentity.lookup(entry.frontmostApp)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: app.icon).resizable().frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.outcome.retainsContent ? "Dictation" : entry.outcomeLabel).font(Theme.Typo.title)
                    Text("\(app.name) · \(entry.timestamp.formatted(date: .abbreviated, time: .shortened))")
                        .font(Theme.Typo.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if entry.outcome.retainsContent {
                    Button("Fix a Word…") { fixing = true }
                        .help("Teach WisprLocal a word it got wrong in this dictation")
                }
                Button("Done", action: done).keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.top, Theme.Space.l)
            .padding(.bottom, Theme.Space.s)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    if entry.outcome.retainsContent {
                        playbackBar
                        columns
                        retranscribeRow
                    } else {
                        outcomeOnly
                        if model.playbackState(entry) == .playable {
                            // Failed / empty dictations can replay their retained audio.
                            playbackBar
                            retranscribeRow
                            if case .done(let v, let text) = model.retranscriptionState(for: entry) {
                                column("\(v.shortName) (re-transcribed)", AttributedString(text.isEmpty ? "— (no words)" : text))
                            }
                        }
                    }
                    metadata
                }
                .padding(Theme.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollContentBackground(.hidden)
        }
        .frame(width: 760)
        // Keep Done visible while the content scrolls, even for a multi-minute dictation.
        .frame(minHeight: 300, idealHeight: entry.outcome.retainsContent ? 600 : 360, maxHeight: 640)
        .background(Theme.windowBackground)
        .onDisappear {
            if model.retranscription.entryID == entry.id { model.retranscription.cancel() }
        }
        .sheet(isPresented: $fixing) { FixWordSheet(model: model, entry: entry) { fixing = false } }
    }

    // MARK: playback

    @ViewBuilder private var playbackBar: some View {
        let state = model.playbackState(entry)
        HStack(spacing: 10) {
            PlayControl(model: model, entry: entry, size: 30)
            if state == .playable {
                let playing = model.playback.isPlaying(entry.id)
                TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !playing)) { _ in
                    let p = playing ? model.playback.progress : 0
                    HStack(spacing: 10) {
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.accent.opacity(0.15))
                                Capsule().fill(Theme.mintGradient).frame(width: max(4, g.size.width * p))
                            }
                        }
                        .frame(height: 4)
                        Text(clipTime(p)).font(Theme.Typo.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
            } else {
                Text(HistoryPlayback.noClipHelp(recordingOn: model.settings.keepDebugRecordings) + ".")
                    .font(Theme.Typo.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            InfoButton(topic: .playback)
        }
        .padding(.horizontal, Theme.Space.s).padding(.vertical, Theme.Space.xs).frame(minHeight: 44)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).strokeBorder(Theme.cardBorder))
    }

    private func clipTime(_ progress: Double) -> String {
        let total = entry.speechDuration > 0 ? entry.speechDuration : entry.audioDuration
        return "\(Format.clip(total * progress)) / \(Format.clip(total))"
    }

    // MARK: text

    private var columns: some View {
        let state = model.retranscriptionState(for: entry)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: Theme.Space.s) {
                column("Heard (raw)", DiffText.heard(entry.raw, against: entry.final))
                column("Inserted (final)", DiffText.inserted(entry.final, against: entry.raw))
                if case .done(let v, let text) = state {
                    column("\(v.shortName) (re-transcribed)", DiffText.inserted(text, against: entry.raw))
                }
            }
            FlowLayout(spacing: 14) {
                legend(AttributedString("struck through"), strike: true,
                       text: entry.backtrackApplied == true ? "removed by cleanup or your correction" : "removed by cleanup")
                legend(AttributedString("mint"), strike: false, text: "added")
            }
        }
    }

    private func column(_ title: String, _ text: AttributedString) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(Theme.Typo.eyebrow).kerning(0.8).foregroundStyle(.secondary)
            Text(text).font(Theme.Typo.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(Theme.Space.s)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).strokeBorder(Theme.cardBorder))
    }

    private func legend(_ sample: AttributedString, strike: Bool, text: String) -> some View {
        var s = sample
        if strike { s.strikethroughStyle = .single; s.foregroundColor = .secondary } else {
            s.foregroundColor = Theme.accent; s.backgroundColor = Theme.accentSoft
        }
        return Text("\(Text(s)) \(text)").font(Theme.Typo.caption).foregroundStyle(.secondary)
    }

    // MARK: re-transcribe

    @ViewBuilder private var retranscribeRow: some View {
        let variant = model.otherVariant(for: entry)
        let state = model.retranscriptionState(for: entry)
        let hasClip = model.playbackState(entry) == .playable
        let busy: Bool = { switch state { case .preparing, .transcribing: return true; default: return false } }()
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Button("Re-transcribe with \(variant.shortName)") { model.retranscribe(entry) }
                .buttonStyle(BrandButtonStyle(prominent: false))
                .disabled(!hasClip || busy || model.isDictating || !model.retranscription.canStart)
            Group {
                switch state {
                case .preparing(let v):
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Preparing \(v.shortName)… The first load can take about 10 seconds.")
                    }
                case .transcribing(let v):
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Transcribing with \(v.shortName)…")
                    }
                case .done:
                    Text("Shown here only; History is unchanged and the model has been released.")
                case .failed(let m):
                    Text(m).foregroundStyle(Theme.danger)
                case .idle:
                    if model.isDictating { Text("Unavailable while you're dictating.") }
                    else if !hasClip { Text("Needs a recording of this dictation.") }
                    else { Text("Loads the other model just for this, then releases it. Nothing is saved.") }
                }
            }
            .font(Theme.Typo.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: outcome-only (SEC-2)

    private var outcomeOnlyText: String {
        let kept = model.playbackState(entry) == .playable
        let base = kept ? "Nothing was typed, so no words were kept. The recording is kept so you can hear what the mic captured."
                        : "Nothing was typed, so no words and no recording were kept for this dictation."
        return entry.whyExplanation ?? base
    }

    private var outcomeOnly: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield").font(Theme.Typo.lead).foregroundStyle(Theme.accent)
                .frame(width: 28, height: 28).background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).fill(Theme.accentSoft))
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.outcomeLabel).font(Theme.Typo.bodyEmphasis)
                Text(outcomeOnlyText)
                    .font(Theme.Typo.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Theme.Space.s).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).strokeBorder(Theme.cardBorder))
    }

    // MARK: metadata

    private var metadata: some View {
        let app = AppIdentity.lookup(entry.frontmostApp)
        var rows: [(String, String)] = [
            ("Engine", entry.engineLabel),
            ("Voice processing", entry.voiceProcessingLabel),
            ("Mic audio", entry.micAudioLabel),
            ("Duration", durationText),
            ("App", app.name),
        ]
        if entry.outcome.retainsContent {
            rows += [("Cleanup", entry.cleanupLabel), ("Join", entry.joinLabel)]
            if let style = entry.style.flatMap(WritingStyle.init(rawValue:)) { rows.append(("Style", style.title)) }
            if entry.backtrackApplied == true { rows.append(("Correction", "Kept the value you restated")) }
        } else {
            rows += [("Outcome", entry.outcomeLabel),
                     ("Recording", model.playbackState(entry) == .playable ? "Kept" : "None kept")]
        }
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                         alignment: .leading, spacing: Theme.Space.s) {
            ForEach(rows.indices, id: \.self) { i in
                meta(rows[i])
            }
        }
        .padding(Theme.Space.s).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).fill(Theme.inset))
    }

    private var durationText: String {
        let speech = entry.speechDuration, audio = entry.audioDuration
        if speech > 0, audio > 0 { return String(format: "%.1f s speech (%.1f s captured)", speech, audio) }
        return String(format: "%.1f s", max(speech, audio))
    }

    @ViewBuilder private func meta(_ r: (String, String)) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            Text(r.0).font(Theme.Typo.caption).foregroundStyle(.secondary)
            Text(r.1).font(Theme.Typo.body).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
