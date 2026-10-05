import SwiftUI
import WisprLocalCore

/// History › Fix a Word…: pick the word(s) WisprLocal got wrong, type the right spelling, and it
/// becomes a replacement plus a dictionary word. The way to teach WisprLocal in apps whose text
/// it can't watch (Slack, Claude, VS Code and other Electron apps).
struct FixWordSheet: View {
    let model: AppModel
    let entry: HistoryEntry
    let done: () -> Void
    @State private var selection: ClosedRange<Int>?
    @State private var correct = ""
    @State private var message: String?

    /// `initialSelection` / `initialCorrect`: the preview harness draws a word already picked.
    init(model: AppModel, entry: HistoryEntry, initialSelection: ClosedRange<Int>? = nil, initialCorrect: String = "",
         done: @escaping () -> Void) {
        self.model = model
        self.entry = entry
        self.done = done
        _selection = State(initialValue: initialSelection)
        _correct = State(initialValue: initialCorrect)
    }

    private var words: [String] { FixAWord.words(in: entry.final) }
    private var picked: String? { selection.flatMap { FixAWord.phrase(words, selection: $0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Fix a Word").font(Theme.Typo.title)
            Text("Click the word it got wrong. For a phrase like “kuber netties”, click the first word, then the last.")
                .font(Theme.Typo.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            // Keep the correction fields and actions visible even for a very long dictation.
            ScrollView {
                wordChips
            }
            .frame(height: Self.maxChipsHeight)
            .scrollBounceBehavior(.basedOnSize)
            VStack(alignment: .leading, spacing: 4) {
                Text(picked.map { "Write “\($0)” as" } ?? "Correct spelling").font(Theme.Typo.bodyEmphasis)
                    .lineLimit(3).help(picked ?? "Correct spelling")
                TextField("e.g. Kubernetes", text: $correct).textFieldStyle(.roundedBorder).onSubmit(apply)
                Text("WisprLocal adds the spelling to your Dictionary and swaps what it heard for it from now on.")
                    .font(Theme.Typo.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let m = message { Text(m).font(Theme.Typo.caption).foregroundStyle(Theme.danger) }
            HStack {
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button(Self.addTitle, action: apply)
                    .keyboardShortcut(.defaultAction)
                    .disabled(picked == nil || correct.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Theme.Space.l)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    static let addTitle = "Add to Dictionary"
    static let maxChipsHeight: CGFloat = 160

    /// The dictation's words as rounded chips: plain views with a tap action and button semantics.
    /// A rounded rectangle, not a `Capsule`: a capsule's hairline rendered with flat, clipped-looking
    /// ends at this size.
    private var wordChips: some View {
        FlowLayout(spacing: 6) {
            ForEach(Array(words.enumerated()), id: \.offset) { i, w in
                let on = selection?.contains(i) == true
                Text(w).font(Theme.Typo.bodyEmphasis).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.Space.snug).padding(.vertical, Theme.Space.xxs).frame(minHeight: 26)
                    .background {
                        RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous).fill(on ? Theme.accentSoft : Theme.inset)
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous).strokeBorder(on ? Theme.accent.opacity(0.18) : Theme.cardBorder))
                    }
                    .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
                    .onTapGesture { pick(i) }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                    .accessibilityAction { pick(i) }
            }
        }
        .padding(Theme.Space.xxs)  // room for the capsules' hairlines at the edges
    }

    /// First click picks a word; a second click on a nearby word extends to a phrase (≤ 3 words).
    private func pick(_ i: Int) {
        message = nil
        if let s = selection, s.count == 1, i != s.lowerBound, abs(i - s.lowerBound) < CorrectionDetector.maxWords {
            selection = min(i, s.lowerBound)...max(i, s.lowerBound)
        } else {
            selection = i...i
        }
    }

    private func apply() {
        guard let picked else { return }
        guard let smart = model.live?.smart else { done(); return }   // preview harness
        Task {
            do { try await smart.fixWord(misheard: picked, correct: correct); done() } catch { message = error.localizedDescription }
        }
    }
}
