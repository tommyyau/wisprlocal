import Combine
import SwiftUI
import WisprLocalCore

/// First-run tour (re-openable from Help / Settings › General): welcome → permissions →
/// Globe key → hold-to-talk practice → hands-free practice → finish/cancel → done.
struct OnboardingView: View {
    enum Step: Int, CaseIterable { case welcome, permissions, globe, tryIt, handsFree, controls, done }

    let model: AppModel
    let onDone: () -> Void
    var animate = true
    @State private var step: Step
    @State private var practice = ""
    @State private var stepStarted = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(model: AppModel, initialStep: Step = .welcome, animate: Bool = true, practiceText: String = "", onDone: @escaping () -> Void) {
        self.model = model
        self.onDone = onDone
        self.animate = animate
        _step = State(initialValue: initialStep)
        _practice = State(initialValue: practiceText)
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .welcome: welcome
                case .permissions: permissions
                case .globe: globe
                case .tryIt: tryIt
                case .handsFree: handsFree
                case .controls: controls
                case .done: done
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            footer
        }
        .frame(width: 680, height: 580)
        .background(Theme.windowBackground)
        .tint(Theme.accent)
        .onAppear { model.refreshSystemState() }
        .onReceive(timer) { _ in if model.live != nil { model.refreshSystemState() } }
    }

    // MARK: steps

    private var welcome: some View {
        VStack(spacing: 0) {
            ZStack {
                Rectangle().fill(Theme.heroGradient)
                WaveMotif(bars: 56, barWidth: 4, gap: 8, maxHeight: 80, intensity: 0.8, time: animate ? nil : 2.4)
                    .edgeFade()
                    .opacity(0.18)
                    .frame(maxHeight: .infinity, alignment: .bottom).offset(y: 30)
                VStack(spacing: 18) {
                    Orb(size: 124, time: animate ? nil : 2.4)
                    VStack(spacing: 6) {
                        Text("Speak. It types.").font(Theme.Typo.heroDisplay).foregroundStyle(.white)
                        Text("WisprLocal turns your voice into text in any app on your Mac.")
                            .font(Theme.Typo.lead).foregroundStyle(.white.opacity(0.75))
                    }
                }
                .padding(.top, Theme.Space.xl)
            }
            .frame(height: 330)
            .clipped()
            HStack(spacing: Theme.Space.m) {
                promise("lock.fill", "Private", "Runs on this Mac (Remote Macs, if you pair one, sends text to your other Mac). No account.")
                promise("bolt.fill", "Instant", "Text lands about as fast as you let go of the key.")
                promise("app.badge", "Everywhere", "Mail, Slack, Notes, your code editor. Anywhere you can type.")
            }
            .padding(.horizontal, Theme.Space.xl).padding(.top, Theme.Space.l)
            RecordingsDisclosure(settings: model.settings)
                .padding(.horizontal, Theme.Space.xl).padding(.top, Theme.Space.m)
            Spacer(minLength: 0)
        }
    }

    private func promise(_ symbol: String, _ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol).font(Theme.Typo.symbolLarge).foregroundStyle(Theme.accent)
                .frame(width: 28, height: 28).background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).fill(Theme.accentSoft))
            Text(title).font(Theme.Typo.bodyEmphasis)
            Text(text).font(Theme.Typo.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var permissions: some View {
        stepLayout(eyebrow: "STEP 1 OF 5", title: "Three quick permissions",
                   text: "macOS asks before any app can hear you or type for you. Turn each one on; the ticks go green by themselves.") {
            VStack(spacing: 0) {
                ForEach(Array(Permission.allCases.enumerated()), id: \.element) { i, p in
                    PermissionRow(permission: p, granted: model.isGranted(p), divider: i < 2,
                                  grant: { model.request(p) }, open: { model.openSettings(p) })
                }
            }
            .card(padding: 0)
            if model.health == .needsRelaunch || model.health == .stalePermission, let live = model.live {
                PermissionHealthView(controller: live).card()
            }
            modelStatus
        }
    }

    @ViewBuilder private var modelStatus: some View {
        HStack(spacing: 10) {
            switch model.modelState {
            case .preparing(let since):
                ProgressView().controlSize(.small)
                Text("Getting the speech model ready on your Mac. Usually under a minute the first time.")
                    .font(Theme.Typo.caption).foregroundStyle(.secondary)
                if let since { Text("\(max(0, Int(Date().timeIntervalSince(since)))) s").font(Theme.Typo.caption).monospacedDigit().foregroundStyle(.tertiary) }
            case .ready:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.positive)
                Text("Speech model ready. It runs on this Mac's Neural Engine.").font(Theme.Typo.caption).foregroundStyle(.secondary)
            case .failed(let m):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                Text("The speech model didn't start: \(m)").font(Theme.Typo.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Retry") { model.retryModel() }.controlSize(.small)
            }
        }
        .padding(.horizontal, Theme.Space.xxs)
    }

    private var globe: some View {
        let g = model.globeConflict
        let ok = g == .doNothing
        return stepLayout(eyebrow: "STEP 2 OF 5", title: "Your key is 🌐",
                          text: "WisprLocal listens to the Globe (fn) key at the bottom-left of your keyboard. Hold it to talk; double-tap for hands-free.") {
            HStack(spacing: Theme.Space.l) {
                VStack(spacing: 10) {
                    KeyCap(size: 84, pressed: false)
                    Text("Hold to talk").font(Theme.Typo.caption).foregroundStyle(.secondary)
                }
                VStack(spacing: 10) {
                    HStack(spacing: 6) { KeyCap(size: 52); KeyCap(size: 52) }.frame(height: 84)
                    Text("Double-tap: hands-free").font(Theme.Typo.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .card(padding: Theme.Space.l)
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(Theme.Typo.icon).foregroundStyle(ok ? Theme.positive : Theme.warning)
                VStack(alignment: .leading, spacing: 4) {
                    Text(ok ? "macOS is leaving 🌐 to WisprLocal" : "One setting so macOS doesn't react too")
                        .font(Theme.Typo.bodyEmphasis)
                    Text(ok ? "“Press 🌐 key to” is set to Do Nothing. Perfect."
                            : "In Keyboard settings, set “Press 🌐 key to” to Do Nothing. Otherwise the emoji picker or input switching can pop up while you talk.")
                        .font(Theme.Typo.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if !ok { Button("Open Keyboard Settings") { model.openKeyboardSettings() }.controlSize(.small) }
            }
            .card()
            if model.wisprFlowRunning {
                HStack {
                    StatusLabel(ok: false, text: "Wispr Flow is running, so WisprLocal is holding off.")
                    Spacer()
                    Button("Quit Wispr Flow") { model.quitWisprFlow() }.controlSize(.small)
                }
                .card()
            }
        }
    }

    private var tryIt: some View {
        practiceStep(handsFree: false)
    }

    private var handsFree: some View {
        practiceStep(handsFree: true)
    }

    private func practiceStep(handsFree: Bool) -> some View {
        let fresh = model.lastDictation.flatMap { $0.timestamp >= stepStarted || model.live == nil ? $0 : nil }
        return stepLayout(eyebrow: handsFree ? "STEP 4 OF 5" : "STEP 3 OF 5",
                          title: handsFree ? "Try hands-free recording" : "Try holding to talk",
                          text: handsFree
                          ? "Click in the box, tap 🌐 twice quickly, let go and speak. Click Done on the recording pill, or tap 🌐 once more, to finish and type."
                          : "Click in the box, hold 🌐 while you speak, then release it to finish and type. Try “This is my first dictation”.") {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $practice)
                    .font(Theme.Typo.lead).scrollContentBackground(.hidden)
                    .padding(Theme.Space.snug)
                if practice.isEmpty {
                    HStack(spacing: 6) {
                        Text(handsFree ? "Double-tap" : "Hold").foregroundStyle(.tertiary)
                        InlineKey()
                        Text("and speak…").foregroundStyle(.tertiary)
                    }
                    .font(Theme.Typo.lead).padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.snug).allowsHitTesting(false)
                }
            }
            .frame(height: 130)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(practice.isEmpty ? Theme.cardBorder : Theme.accent.opacity(0.6), lineWidth: practice.isEmpty ? 1 : 1.5))
            if let e = fresh {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "party.popper.fill").foregroundStyle(Theme.accent).font(Theme.Typo.icon)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(handsFree ? "Your hands-free dictation" : "Your hold-to-talk dictation").font(Theme.Typo.bodyEmphasis)
                        Text("“\(e.final)”").font(Theme.Typo.body).foregroundStyle(.secondary)
                        let words = HistoryStats.wordCount(e.final)
                        Text("\(words) words in \(Format.clip(e.speechDuration > 0 ? e.speechDuration : e.audioDuration)). Typed for you, on this Mac.")
                            .font(Theme.Typo.caption).foregroundStyle(.tertiary)
                    }
                }
                .card()
            } else {
                Text(model.readiness.ok ? "Waiting for your voice…" : model.readiness.text)
                    .font(Theme.Typo.caption).foregroundStyle(.secondary).padding(.horizontal, Theme.Space.xxs)
            }
            Text(handsFree
                 ? "The pill shows elapsed time and keeps recording after you let go. Esc or three quick 🌐 taps cancel instead of typing."
                 : "Keep the key held until you're finished. Esc cancels instead of typing. A single quick tap while idle is discarded.")
                .font(Theme.Typo.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var controls: some View {
        stepLayout(eyebrow: "STEP 5 OF 5", title: "Finish, cancel or recover",
                   text: "Finishing types your words. Cancelling before the paste discards the current dictation; it can't remove text that's already been typed.") {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                controlTip("Finish and type", "Release 🌐 for hold-to-talk. In hands-free, click Done on the pill or tap 🌐 once.")
                controlTip("Cancel", "Press Esc while recording or processing. Over 30 seconds, press Esc twice. While recording hands-free, three quick 🌐 taps also cancel.")
                controlTip("Recover dictation text", "Focus a text field and press \(PasteAgainShortcut.display) (Control–Option–Command–V) to repeat the most recent dictation's text from this session, including after an app switch or a failed paste. Home and History also have Copy buttons.")
            }
            .card()
            Text("Help has the full guide: mouse-button recording, Shift-to-send, voice commands, spelling corrections, microphone settings and privacy controls. Reopen this tour from Help at any time.")
                .font(Theme.Typo.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func controlTip(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            Text(title).font(Theme.Typo.bodyEmphasis)
            Text(text).font(Theme.Typo.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var done: some View {
        VStack(spacing: Theme.Space.l) {
            Orb(size: 96, time: animate ? nil : 1.7)
            VStack(spacing: 6) {
                Text("You're all set").font(Theme.Typo.display)
                Text("Hold 🌐 and release to finish, or double-tap for hands-free.\nThe full guide and this tour are always available in Help.")
                    .font(Theme.Typo.body).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: Theme.Space.s) {
                tip("“scratch that”", "Removes everything you said before it in the current dictation.")
                tip("“new line”", "Starts a new line. “New paragraph” too.")
                tip("Snippets", "Say a short trigger to type a whole block.")
            }
            .padding(.horizontal, Theme.Space.xl)
        }
        .padding(.top, Theme.Space.xl)
        .frame(maxHeight: .infinity, alignment: .center)
    }

    private func tip(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Theme.Typo.bodyEmphasis).foregroundStyle(Theme.accent)
            Text(text).font(Theme.Typo.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
        .card(padding: 12)
    }

    private func stepLayout<C: View>(eyebrow: String, title: String, text: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 6) {
                Text(eyebrow).font(Theme.Typo.eyebrow).kerning(1).foregroundStyle(Theme.accent)
                Text(title).font(Theme.Typo.display)
                Text(text).font(Theme.Typo.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, Theme.Space.xxs)
            content()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.xxl).padding(.top, Theme.Space.xxl)
    }

    // MARK: footer

    private var footer: some View {
        HStack {
            if step != .welcome && step != .done {
                Button("Back") { go(-1) }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Spacer()
            Button(primaryTitle) {
                if step == .done { model.completeOnboarding(); onDone() } else { go(1) }
            }
            .buttonStyle(BrandButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, Theme.Space.l).frame(height: 64)
        .overlay {
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { s in
                    Capsule().fill(s == step ? Theme.accent : Color.secondary.opacity(0.25))
                        .frame(width: s == step ? 18 : 6, height: 6)
                }
            }
            .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")
        }
        .background(Theme.card.opacity(0.6))
        .overlay(alignment: .top) { Rectangle().fill(Theme.separator).frame(height: 1) }
    }

    private var primaryTitle: String {
        switch step {
        case .welcome: "Get Started"
        case .permissions: model.allGranted ? "Continue" : "Continue Anyway"
        case .globe: "Continue"
        case .tryIt: "Try Hands-Free"
        case .handsFree: "Continue"
        case .controls: "Finish Tour"
        case .done: "Open WisprLocal"
        }
    }

    private func go(_ d: Int) {
        guard let next = Step(rawValue: step.rawValue + d) else { return }
        if next == .tryIt || next == .handsFree {
            stepStarted = Date()
            practice = ""
        }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { step = next }
    }
}

/// Welcome step: one line saying recordings are kept (last 20, on this Mac), with the toggle.
struct RecordingsDisclosure: View {
    let settings: AppSettings
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform").font(Theme.Typo.symbol.weight(.semibold)).foregroundStyle(Theme.accent)
            Text("Keeps your last \(DebugRecordingStore.defaultLimit) recordings on this Mac, so you can replay them. Never uploaded.")
                .font(Theme.Typo.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(get: { settings.keepDebugRecordings }, set: { settings.keepDebugRecordings = $0 }))
                .toggleStyle(BrandSwitchStyle(small: true)).labelsHidden()
                .accessibilityLabel(AppSettings.keepRecordingsLabel)
        }
        .padding(.horizontal, Theme.Space.s).padding(.vertical, Theme.Space.xs)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous).fill(Theme.inset))
    }
}
