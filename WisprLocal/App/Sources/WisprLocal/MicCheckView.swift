import AVFoundation
import SwiftUI
import WisprLocalCore

/// Settings › Microphone › "Check your microphone": `MicSelfTest` with the current settings, then
/// (voice processing on) again with it off, side by side. The recordings live in this view's
/// state only and are dropped when the sheet closes.
struct MicCheckSheet: View {
    let model: AppModel
    var done: () -> Void

    @State private var phase: MicSelfTest.Phase?
    @State private var results: [MicCheckResult] = []
    @State private var error: String?
    @State private var player: AVAudioPlayer?
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                Text("Check your microphone").font(Theme.Typo.title)
                Spacer()
                Button("Done") { close() }.keyboardShortcut(.cancelAction)
            }
            Text("Talk normally for three seconds when it says Recording, the way you'd dictate. "
                 + (model.settings.voiceProcessingEnabled ? "It then records again with Noise reduction off, to compare." : ""))
                .font(Theme.Typo.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            status
            if !results.isEmpty {
                HStack(alignment: .top, spacing: Theme.Space.s) {
                    ForEach(results) { r in card(r) }
                }
                if let c = MicSelfTest.comparison(results) {
                    Text(c).font(Theme.Typo.body).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Button(results.isEmpty ? "Start Test" : "Test Again") { start() }
                    .buttonStyle(BrandButtonStyle(prominent: true))
                    .disabled(isRunning || model.isDictating)
                if model.isDictating { Text("Unavailable while you're dictating.").font(Theme.Typo.caption).foregroundStyle(.secondary) }
            }
        }
        .padding(Theme.Space.l)
        .frame(width: 620, alignment: .leading)
        .background(Theme.windowBackground)
        .onDisappear { cleanup() }
    }

    private var isRunning: Bool { if case .recording = phase { return true } else { return false } }

    @ViewBuilder private var status: some View {
        if case .recording(let vp) = phase {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Recording… (Noise reduction \(vp ? "on" : "off"))").font(Theme.Typo.bodyEmphasis)
            }
        } else if let error {
            Text(error).foregroundStyle(Theme.danger).font(Theme.Typo.body)
        }
    }

    private func card(_ r: MicCheckResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(r.title.uppercased()).font(Theme.Typo.eyebrow).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Image(systemName: r.passed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(r.passed ? Theme.accent : Theme.danger)
                Text(r.passed ? "Pass" : "Problem").font(Theme.Typo.bodyEmphasis)
            }
            Text(r.verdict).font(Theme.Typo.body).fixedSize(horizontal: false, vertical: true)
            Text(r.details).font(Theme.Typo.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Play") { play(r) }.controlSize(.small).disabled(r.samples.isEmpty)
        }
        .padding(Theme.Space.s).frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).fill(Theme.card))
    }

    private func start() {
        guard let live = model.live, !isRunning else { return }
        player?.stop(); player = nil
        results = []; error = nil
        let vp = model.settings.voiceProcessingEnabled
        task = Task { @MainActor in
            live.beginMicTest()
            defer { live.endMicTest() }
            do {
                results = try await MicSelfTest.live().run(currentVoiceProcessing: vp) { phase = $0 }
            } catch {
                self.error = error.localizedDescription
                phase = nil
            }
        }
    }

    /// In memory only: the WAV bytes are built for the player and never written anywhere.
    private func play(_ r: MicCheckResult) {
        player?.stop()
        player = try? AVAudioPlayer(data: WAV.encode(r.samples, sampleRate: Int(AudioConstants.sampleRate)))
        player?.play()
    }

    private func cleanup() {
        task?.cancel(); task = nil
        player?.stop(); player = nil
        results = []  // the test recordings go with the sheet
    }

    private func close() { cleanup(); done() }
}
