#if DEBUG
import AppKit
import SwiftUI
import WisprLocalCore

/// DEBUG-only harness (`WisprLocal --hud-preview <dir>`): drives the real HUDAnimator with a
/// synthetic voice spectrum on a simulated clock and renders frames offscreen with ImageRenderer.
/// No window is shown. Material is simulated (ImageRenderer cannot sample the desktop).
@MainActor
enum HUDPreview {
    static let fps = 120.0

    struct Shot { var label: String; var frame: HUDFrame }

    static func run(outputDirectory dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // 1. Choreography sequence: enter → speak → processing morph → exit.
        let start = Date()
        let seqTimes: [(Double, String)] = [
            (0.000, "enter 0 ms"), (0.025, "enter 25 ms"), (0.050, "enter 50 ms"), (0.085, "enter 85 ms"),
            (0.130, "enter 130 ms"), (0.200, "enter 200 ms"), (0.320, "enter 320 ms"),
            (0.600, "speaking"), (0.730, "speaking (peak)"), (0.900, "speaking"),
            (1.100, "processing +40 ms"), (1.180, "processing +120 ms"), (1.420, "processing +360 ms"),
            (1.560, "exit +40 ms"), (1.620, "exit +100 ms"), (1.680, "exit +160 ms"), (1.730, "exit +210 ms"),
        ]
        let seq = simulate(times: seqTimes.map(\.0), reduceMotion: false) { t in
            t < 1.06 ? .recording(handsFree: false) : (t < 1.52 ? .processing : nil)
        }
        let shots = zip(seqTimes, seq).map { Shot(label: $0.1, frame: $1) }
        for (i, s) in shots.enumerated() { write(single(s, dark: true), to: dir.appendingPathComponent(String(format: "seq-%02d.png", i))) }
        write(sheet(shots, dark: true, columns: 3), to: dir.appendingPathComponent("sequence-sheet.png"))

        // 2. Every state, settled, on light and dark desktops.
        let notices: [(String, HUDNotice)] = [
            ("focus changed", HUDController.chipNotice(PipelineNotice.focusChanged)),
            ("secure input", HUDController.chipNotice(PipelineNotice.secureInput)),
            ("too quick", HUDController.chipNotice(PipelineNotice.quickRepressDropped)),
            ("preparing", HUDNotice(symbol: "hourglass", tint: .info, text: "Preparing speech model…", elapsedSince: start.addingTimeInterval(-12))),
            ("wispr flow", HUDNotice(symbol: "exclamationmark.triangle.fill", tint: .warning, text: WisprFlowCopy.holdingOff, buttons: [.quitWisprFlow, .useWisprLocalAnyway, .wisprFlowDifferentShortcut])),
            ("model failed", HUDNotice(symbol: "xmark.octagon.fill", tint: .error, text: "Speech model failed: Core ML compile error", buttons: [.retryModel])),
            ("relaunch", HUDNotice(symbol: "arrow.clockwise.circle.fill", tint: .info, text: "Permissions updated — Relaunch WisprLocal", buttons: [.relaunch])),
            ("stale permission", HUDNotice(symbol: "exclamationmark.triangle.fill", tint: .warning, text: "Stale permission — re-add WisprLocal", buttons: [.permissionHelp, .relaunch])),
        ]
        var states: [(String, HUDState, Double)] = [
            ("starting (cold mic)", .starting(handsFree: false), -1),
            ("hands-free starting (cold mic)", .starting(handsFree: true), -1),
            ("recording", .recording(handsFree: false), 0.73),
            ("recording (silence)", .recording(handsFree: false), -1),
            ("hands-free", .recording(handsFree: true), 1.04),
            ("processing", .processing, 0.9),
        ]
        states += notices.map { ($0.0, .notice($0.1), 0.9) }
        var stateShots: [Shot] = []
        for (label, st, at) in states {
            let silent = at < 0
            let f = simulate(times: [silent ? 0.9 : at], reduceMotion: false, silent: silent) { _ in st }[0]
            stateShots.append(Shot(label: label, frame: f))
        }
        let rm = simulate(times: [0.9], reduceMotion: true) { _ in .processing }[0]
        stateShots.append(Shot(label: "processing (Reduce Motion)", frame: rm))
        for (i, s) in stateShots.enumerated() {
            let name = s.label.replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
            write(single(s, dark: true), to: dir.appendingPathComponent(String(format: "state-%02d-%@.png", i, name)))
        }
        write(sheet(stateShots, dark: true, columns: 2), to: dir.appendingPathComponent("states-dark.png"))
        write(sheet(stateShots, dark: false, columns: 2), to: dir.appendingPathComponent("states-light.png"))

        // 3. Every transient chip, through the app's own text → notice path (`HUDController.chipNotice`)
        //    and timing rule (`HUDChipPolicy`), so the shots and chips.txt show what the app shows.
        let chipTexts: [(String, String)] = [
            ("cancelled", PipelineNotice.cancelled),
            ("press esc again", PipelineNotice.escapeAgain(seconds: 42)),
            ("recording stops in", PipelineNotice.recordingStopsIn(9)),
            ("always write as", SmartDictionaryCopy.suggestion(Correction(misheard: "kuber netties", correct: "Kubernetes"))),
            ("added to dictionary", SmartDictionaryCopy.added("Kubernetes")),
            ("corrected undo", PipelineNotice.corrected),
            ("corrected copy original", PipelineNotice.correctedCopyOnly),
            ("original copied", PipelineNotice.originalCopied),
            ("undo not safe", PipelineNotice.undoNotSafe),
            ("already typed not sent", PipelineNotice.alreadyTypedNotSent),
            ("indicator hidden", ChipCopy.indicatorHidden),
            ("didnt catch that", PipelineNotice.didntCatchThat),
            ("didnt catch that headset", PipelineNotice.didntCatchThatUseHeadset),
            ("paste not confirmed", PipelineNotice.pasteNotConfirmed),
            ("mic cutting out tip", PipelineNotice.micCuttingOut),
        ]
        var chipShots: [Shot] = []
        var chipReport = "chip | priority | buttons | seconds\n"
        for (label, text) in chipTexts {
            let f = simulate(times: [0.9], reduceMotion: false) { _ in .notice(HUDController.chipNotice(text)) }[0]
            chipShots.append(Shot(label: label, frame: f))
            let c = HUDChipPolicy.chip(text)
            chipReport += "\(text) | \(c.priority) | \(c.actions.map(\.title).joined(separator: " · ")) | \(Int(c.seconds)) s\n"
        }
        for (i, s) in chipShots.enumerated() {
            write(single(s, dark: true), to: dir.appendingPathComponent(String(format: "chip-%02d-%@.png", i, s.label.replacingOccurrences(of: " ", with: "-"))))
        }
        write(sheet(chipShots, dark: true, columns: 2), to: dir.appendingPathComponent("chips-dark.png"))
        write(sheet(chipShots, dark: false, columns: 2), to: dir.appendingPathComponent("chips-light.png"))
        try? chipReport.write(to: dir.appendingPathComponent("chips.txt"), atomically: true, encoding: .utf8)

        // 4. Frame-time budget (CPU): animator step + offscreen render of one frame.
        let anim = HUDAnimator()
        let n = 20_000
        let t0 = CACurrentMediaTime()
        for i in 0..<n {
            let t = Double(i) / fps
            _ = anim.step(t: t, target: .recording(handsFree: false), bands: syntheticBands(t), reduceMotion: false)
        }
        let stepUS = (CACurrentMediaTime() - t0) / Double(n) * 1e6
        let r0 = CACurrentMediaTime()
        let renders = 60
        for i in 0..<renders { _ = render(single(Shot(label: "", frame: seq[7 + i % 3]), dark: true, labelled: false), scale: 2) }
        let renderMS = (CACurrentMediaTime() - r0) / Double(renders) * 1e3
        let report = String(format: "animator.step: %.2f µs/frame\noffscreen render (CPU, 2x, incl. PNG-free rasterise): %.2f ms/frame\nbudget @120 Hz: 8.33 ms\n", stepUS, renderMS)
        try? report.write(to: dir.appendingPathComponent("timing.txt"), atomically: true, encoding: .utf8)
        print(report, terminator: "")
        print("HUD preview written to \(dir.path)")
    }

    /// Steps a fresh animator at `fps` and returns the frames at the requested times.
    static func simulate(times: [Double], reduceMotion: Bool, silent: Bool = false,
                         target: (Double) -> HUDState?) -> [HUDFrame] {
        let anim = HUDAnimator()
        var out: [HUDFrame] = []
        var t = 0.0
        var idx = 0
        let sorted = times
        while idx < sorted.count {
            let f = anim.step(t: t, target: target(t), bands: silent ? quietBands(t) : syntheticBands(t), reduceMotion: reduceMotion)
            while idx < sorted.count, t + 1e-9 >= sorted[idx] { out.append(f); idx += 1 }
            t += 1 / fps
        }
        return out
    }

    /// Voice-like spectrum: syllable envelope × a wandering formant pair (+ a little hiss).
    static func syntheticBands(_ t: Double) -> [Float] {
        let env = (0.25 + 0.75 * pow(0.5 + 0.5 * sin(2 * .pi * 3.1 * t + 0.4), 0.7)) * (0.72 + 0.28 * sin(2 * .pi * 0.6 * t))
        let c = 3.2 + 1.5 * sin(2 * .pi * 1.05 * t)
        return (0..<SpectrumBands.count).map { i in
            let d = Double(i)
            let v = 0.95 * exp(-pow(d - c, 2) / 3.2) + 0.45 * exp(-pow(d - (c + 3.4), 2) / 1.6)
            let hiss = 0.04 * (0.5 + 0.5 * sin(37 * t + d * 1.7))
            return Float(min(1, env * v + hiss))
        }
    }

    /// Room noise just around the analyzer floor.
    static func quietBands(_ t: Double) -> [Float] {
        // Split into typed steps: Swift 6.3 can't type-check the one-line form in reasonable time.
        (0..<SpectrumBands.count).map { i -> Float in
            let phase: Double = 23 * t + Double(i) * 2.1
            let wobble: Double = 0.5 + 0.5 * sin(phase)
            return Float(0.03 + 0.03 * wobble)
        }
    }

    // MARK: rendering

    static func backdrop(dark: Bool) -> some View {
        ZStack {
            LinearGradient(colors: dark ? Theme.previewBackdropDark : Theme.previewBackdropLight,
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            // A "window" edge behind the HUD, to judge the border/shadow against content.
            RoundedRectangle(cornerRadius: Theme.Radius.tile)
                .fill(dark ? Color(white: 0.17) : Color.white)
                .frame(width: 300, height: 140)
                .offset(x: -260, y: -10)
        }
    }

    static func single(_ s: Shot, dark: Bool, labelled: Bool = true) -> AnyView {
        AnyView(
            ZStack(alignment: .topLeading) {
                backdrop(dark: dark)
                HUDFrameView(frame: s.frame, elapsedSeconds: s.frame.state?.isHandsFree == true ? 72 : 0)
                    .environment(\.hudSimulatedMaterial, true)
                if labelled && !s.label.isEmpty {
                    Text(s.label).font(Theme.Typo.mono.weight(.medium))
                        .foregroundStyle(dark ? Color.white.opacity(0.6) : Color.black.opacity(0.55))
                        .padding(Theme.Space.tight)
                }
            }
            .frame(width: HUDController.windowSize.width, height: HUDController.windowSize.height)
            .clipped()
        )
    }

    static func sheet(_ shots: [Shot], dark: Bool, columns: Int) -> AnyView {
        let rows = stride(from: 0, to: shots.count, by: columns).map { Array(shots[$0..<min(shots.count, $0 + columns)]) }
        return AnyView(
            VStack(spacing: 2) {
                ForEach(rows.indices, id: \.self) { r in
                    HStack(spacing: 2) {
                        ForEach(rows[r].indices, id: \.self) { c in single(rows[r][c], dark: dark) }
                        if rows[r].count < columns {
                            ForEach(0..<(columns - rows[r].count), id: \.self) { _ in
                                Color.black.frame(width: HUDController.windowSize.width, height: HUDController.windowSize.height)
                            }
                        }
                    }
                }
            }
            .background(Color.black)
        )
    }

    static func render(_ v: AnyView, scale: CGFloat) -> CGImage? {
        let r = ImageRenderer(content: v)
        r.scale = scale
        return r.cgImage
    }

    static func write(_ v: AnyView, to url: URL) {
        guard let cg = render(v, scale: 2) else { print("render failed: \(url.lastPathComponent)"); return }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }
}
#endif
