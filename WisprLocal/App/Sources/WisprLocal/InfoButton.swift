import SwiftUI
import WisprLocalCore

/// ⓘ next to a non-obvious setting: a popover with 2–4 plain sentences. All copy lives in
/// `InfoTopic` (WisprLocalCore/Support/HelpContent.swift), never inline here.
struct InfoButton: View {
    let topic: InfoTopic
    /// Preview harness only: render with the popover already open.
    var initiallyOpen = false
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: "info.circle")
                .font(Theme.Typo.chip.weight(.regular))
                .foregroundStyle(open ? Theme.accent : .secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("About \(topic.title)")
        .accessibilityLabel("More about \(topic.title)")
        .popover(isPresented: $open, arrowEdge: .bottom) { InfoPopoverContent(topic: topic) }
        .onAppear { if initiallyOpen { open = true } }
    }
}

struct InfoPopoverContent: View {
    let topic: InfoTopic
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(topic.title).font(Theme.Typo.bodyEmphasis)
            ForEach(topic.sentences, id: \.self) { s in
                Text(s).font(Theme.Typo.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Theme.Space.m)
        .frame(width: 320, alignment: .leading)
    }
}
