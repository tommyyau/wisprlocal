import Combine
import SwiftUI
import WisprLocalCore

/// Home, for new users (until 3 dictations, or re-opened from Help): hello, a live
/// self-test, recording controls, a quick tour and noise reduction. Hide it any time.
struct GettingStartedStack: View {
    @Bindable var model: AppModel

    var body: some View {
        let done = min(model.stats.totalDictations, AppModel.gettingStartedGoal)
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .firstTextBaseline) {
                Text("Getting started").font(Theme.Typo.title)
                HStack(spacing: 4) {
                    ForEach(0..<AppModel.gettingStartedGoal, id: \.self) { i in
                        Capsule().fill(i < done ? Theme.accent : Color.secondary.opacity(0.22)).frame(width: 16, height: 5)
                    }
                }
                .padding(.leading, Theme.Space.tight)
                Text("\(done) of \(AppModel.gettingStartedGoal) dictations").font(Theme.Typo.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Hide") { withAnimation(.snappy) { model.hideGettingStarted() } }
                    .buttonStyle(.plain).font(Theme.Typo.caption.weight(.medium)).foregroundStyle(.secondary)
                    .help("You can bring this back from Help")
            }
            SelfTestCard(model: model)
            RecordingBasicsCard(model: model)
            HStack(alignment: .top, spacing: Theme.Space.s) {
                TourCard(model: model)
                NoiseCard(model: model)
            }
        }
    }
}

// MARK: - Self-test

struct SelfTestCard: View {
    @Bindable var model: AppModel
    @State private var text = ""
    private let poll = Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()

    enum CheckState { case waiting, ok, failed }
    struct Check: Identifiable {
        let id: String
        let title: String
        let state: CheckState
        var hint: String?
    }

    var body: some View {
        let checks = Self.checks(model.selfTest)
        let allGood = checks.allSatisfy { $0.state == .ok }
        HStack(alignment: .top, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("👋").font(Theme.Typo.icon)
                    Text(allGood ? "You're dictating. Lovely." : "Say hello").font(Theme.Typo.title)
                }
                Text("Click the box, hold 🌐 / fn and say “Hello WisprLocal”.")
                    .font(Theme.Typo.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Release the key to finish and type your words.")
                    .font(Theme.Typo.caption).foregroundStyle(.secondary)
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $text)
                        .font(Theme.Typo.lead).scrollContentBackground(.hidden).padding(Theme.Space.xs)
                    if text.isEmpty {
                        Text("Your words will appear here…").font(Theme.Typo.lead).foregroundStyle(.tertiary)
                            .padding(.horizontal, Theme.Space.ms).padding(.vertical, Theme.Space.xs).allowsHitTesting(false)
                    }
                }
                .frame(height: 84)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous).fill(Theme.inset))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                    .strokeBorder(allGood ? Theme.accent.opacity(0.6) : Theme.cardBorder, lineWidth: allGood ? 1.5 : 1))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 12) {
                Text("LIVE CHECK").font(Theme.Typo.eyebrow).kerning(0.8).foregroundStyle(.secondary)
                ForEach(checks) { c in checkRow(c) }
                Button("Try again") { text = ""; model.restartSelfTest() }
                    .buttonStyle(.plain).font(Theme.Typo.caption.weight(.medium)).foregroundStyle(Theme.accent)
                    .opacity(model.selfTest.attempt == nil ? 0 : 1)
            }
            .frame(width: 250, alignment: .leading)
        }
        .card(padding: Theme.Space.l)
        .onReceive(poll) { _ in model.sampleSelfTest() }
        .onAppear { if model.live != nil { model.restartSelfTest() } }
        .onChange(of: model.selfTest.attempt) { _, a in
            if let a, HistoryStats.counts(a), text.isEmpty { text = a.final }
        }
    }

    private func checkRow(_ c: Check) -> some View {
        HStack(alignment: .top, spacing: 9) {
            ZStack {
                Circle().fill(color(c.state).opacity(c.state == .waiting ? 0.10 : 0.16))
                switch c.state {
                case .ok: Image(systemName: "checkmark").font(Theme.Typo.micro).foregroundStyle(Theme.positive)
                case .failed: Image(systemName: "exclamationmark").font(Theme.Typo.micro).foregroundStyle(Theme.warning)
                case .waiting: Circle().fill(Color.secondary.opacity(0.35)).frame(width: 5, height: 5)
                }
            }
            .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.title).font(Theme.Typo.bodyEmphasis).foregroundStyle(c.state == .waiting ? .secondary : .primary)
                if let h = c.hint {
                    Text(h).font(Theme.Typo.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func color(_ s: CheckState) -> Color {
        switch s { case .ok: Theme.positive; case .failed: Theme.warning; case .waiting: .secondary }
    }

    /// Pure mapping from what happened to three ticks with a fix-it hint on the first failure.
    static func checks(_ t: AppModel.SelfTest) -> [Check] {
        guard let a = t.attempt else {
            return [Check(id: "mic", title: "Microphone hears you", state: t.micHeard ? .ok : .waiting),
                    Check(id: "asr", title: "Words recognised", state: .waiting),
                    Check(id: "ins", title: "Text typed for you", state: .waiting)]
        }
        let heard = t.micHeard || a.recognisedWords
        let recognised = a.recognisedWords
        let mic = Check(id: "mic", title: "Microphone hears you", state: heard ? .ok : .failed,
                        hint: heard ? nil : "No sound reached WisprLocal. Check Settings › Microphone and the Microphone permission.")
        let asr = Check(id: "asr", title: "Words recognised", state: !heard ? .waiting : (recognised ? .ok : .failed),
                        hint: heard && !recognised ? "We heard sound but no words. Speak a little closer, or turn off noise reduction if your voice is soft." : nil)
        let inserted = a.outcome == .inserted
        let ins = Check(id: "ins", title: "Text typed for you", state: !recognised ? .waiting : (inserted ? .ok : .failed),
                        hint: recognised && !inserted ? insertHint(a.outcome) : nil)
        return [mic, asr, ins]
    }

    static func insertHint(_ o: HistoryEntry.Outcome) -> String {
        switch o {
        case .focusChanged: "The focus moved while you spoke, so it went to the clipboard instead. Keep this box selected and try again."
        case .blockedByConflict: "Wispr Flow is running and has priority, so WisprLocal held off. Quit it, or turn on “Wispr Flow uses a different shortcut” in Settings if you've moved it off 🌐."
        case .blockedBySecureInput: "A password field is active somewhere, which blocks typing. Close it and try again."
        case .insertFailed: "macOS didn't let WisprLocal type. Check that Accessibility is allowed (Settings shows Ready, or a banner asks for it)."
        case .blockedByRemoteSecureInput: "The remote Mac has a password field focused, so the text was not inserted. It reached the receiver and is not kept. Click into a normal text box there and try again."
        case .noTextRecognised: "The mic picked up sound but no words came out. In a loud place, try a headset mic, or turn off Noise reduction in Settings › Microphone."
        case .emptyAfterCleanup: "Only filler words were heard, so there was nothing to type. Try a full sentence."
        default: "Something interrupted it. Try again."
        }
    }
}

// MARK: - Recording controls

struct RecordingBasicsCard: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Start, finish and cancel").font(Theme.Typo.bodyEmphasis)
            instruction("Hold 🌐 to record", "Keep it held while you speak; release it to finish and type.")
            instruction("Double-tap 🌐 for hands-free", "Tap twice quickly, let go and speak. Click Done on the pill or tap 🌐 once to finish and type.")
            instruction("Esc or triple-tap to cancel", "Esc cancels recording or processing. Over 30 seconds, press Esc twice. In hands-free, three quick 🌐 taps also cancel; nothing is typed.")
            Text("One quick tap while idle is discarded. Click into the text field you want to use before recording.")
                .font(Theme.Typo.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.Space.m) {
                Button("Practise both recording modes") { model.showOnboarding() }
                Button("Open full Help") { model.helpTabRequest = .howTo; model.section = .help }
            }
            .buttonStyle(.plain).font(Theme.Typo.caption.weight(.medium)).foregroundStyle(Theme.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func instruction(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            Text(title).font(Theme.Typo.bodyEmphasis)
            Text(text).font(Theme.Typo.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Tour & noise

struct TourCard: View {
    let model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Look around").font(Theme.Typo.bodyEmphasis)
            VStack(spacing: 6) {
                stop(.history, "History", "Delivered dictations, ready to copy again.")
                stop(.dictionary, "Dictionary", "Teach it names and jargon.")
                stop(.snippets, "Snippets", "Say a phrase, get a whole block.")
                stop(.settings, "Indicator", "Move the pill off your text.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func stop(_ s: MainSection, _ title: String, _ text: String) -> some View {
        Button { model.section = s; if s == .settings { model.settingsRequest = .tab(.general) } } label: {
            HStack(spacing: 10) {
                Image(systemName: title == "Indicator" ? "capsule" : s.symbol).font(Theme.Typo.symbol.weight(.semibold)).foregroundStyle(Theme.accent)
                    .frame(width: 26, height: 26).background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).fill(Theme.accentSoft))
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(Theme.Typo.bodyEmphasis)
                    Text(text).font(Theme.Typo.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(Theme.Typo.micro).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct NoiseCard: View {
    let model: AppModel
    var body: some View {
        let on = model.settings.voiceProcessingEnabled
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Noise reduction").font(Theme.Typo.bodyEmphasis)
                Spacer()
                Toggle("Noise reduction", isOn: Binding(get: { on }, set: { model.setVoiceProcessing($0) }))
                    .toggleStyle(BrandSwitchStyle(small: true)).labelsHidden()
                    .environment(\.settingRowTitle, "Noise reduction")
            }
            Text("Suppresses steady noise like fans and hum. For a TV or people talking, use Noisy room.")
                .font(Theme.Typo.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "lightbulb").font(Theme.Typo.symbol.weight(.regular)).foregroundStyle(Theme.accent)
                Text("Turn it off if you use a pro mic or headset that already cleans up sound, or if quiet speech gets missed.")
                    .font(Theme.Typo.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(Theme.Space.xs)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).fill(Theme.inset))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}
