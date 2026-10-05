import SwiftUI
import WisprLocalCore

/// Settings › General, below the 🌐 rows: mouse-button trigger, start/stop sounds
/// and Shift-on-release auto-send. Esc/triple-tap are in Help; lost-key detection is in the Ready popover.
struct ControlsRows: View {
    let model: AppModel

    /// Preview harness (`--ui-preview`): defaults in a throwaway suite, never the user's.
    static let previewSettings = ConvenienceSettings(defaults: UserDefaults(suiteName: "wisprlocal-ui-preview-conveniences") ?? .standard)

    private var settings: ConvenienceSettings { model.live?.convenienceSettings ?? Self.previewSettings }
    private var actions: Conveniences? { model.live?.conveniences }

    var body: some View {
        let s = settings
        SettingRow(title: "Mouse button",
                   why: "Works like 🌐: hold to talk, double-tap for hands-free.", info: .controls) {
            ChoiceMenu(selection: s.mouseTrigger, options: MouseTrigger.allCases, title: \.title, symbol: "computermouse", label: "Mouse button") { t in
                if let actions { actions.setMouseTrigger(t) } else { s.mouseTrigger = t }
            }
        }
        SettingRow(title: "Start and stop sounds",
                   why: "A soft tone when the mic starts and stops. Never transcribed.") {
            Toggle("", isOn: Binding(get: { s.feedbackSounds },
                                     set: { on in if let actions { actions.setFeedbackSounds(on) } else { s.feedbackSounds = on } }))
                .toggleStyle(BrandSwitchStyle()).labelsHidden()
        }
        SettingRow(title: "Shift while releasing 🌐 presses Return",
                   why: "Sends the message after the paste. Never in remote mode or password fields.",
                   divider: true, keepsControlInline: true) {
            Toggle("", isOn: Binding(get: { s.shiftReturnAutoSend },
                                     set: { on in if let actions { actions.setShiftReturn(on) } else { s.shiftReturnAutoSend = on } }))
                .toggleStyle(BrandSwitchStyle()).labelsHidden()
        }
    }
}

/// Settings › Privacy: how long History (and its recordings) is kept.
struct HistoryRetentionRow: View {
    let model: AppModel
    /// A shorter period that would delete dictations right away, waiting for "Delete" (U3).
    @State private var pending: (retention: HistoryRetention, question: String)?

    var body: some View {
        let s = model.live?.convenienceSettings ?? ControlsRows.previewSettings
        let actions = model.live?.conveniences
        SettingRow(title: "Keep history",
                   why: "Older dictations and their recordings are deleted.") {
            ChoiceMenu(selection: s.historyRetention, options: HistoryRetention.allCases, title: \.title, symbol: "clock.arrow.circlepath", label: "Keep history") { r in
                guard let actions else { s.historyRetention = r; return }
                Task {
                    if let q = await actions.retentionConfirmation(for: r) { pending = (r, q) }
                    else { actions.setHistoryRetention(r) }
                }
            }
        }
        .alert(pending?.question ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("Delete", role: .destructive) {
                if let p = pending { actions?.setHistoryRetention(p.retention) }
                pending = nil
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text(HistoryRetention.deleteConfirmationDetail)
        }
    }
}

/// A key named in a settings row ("esc"): a small inset key, not a control.
struct KeyHint: View {
    let text: String
    var body: some View {
        Text(text).font(Theme.Typo.caption.weight(.medium)).foregroundStyle(.secondary)
            .padding(.horizontal, Theme.Space.xs).frame(height: 22)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.tiny, style: .continuous).fill(Theme.inset))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.tiny, style: .continuous).strokeBorder(Theme.cardBorder))
            .accessibilityLabel("Key: \(text)")
    }
}

/// A compact pick-one field: the same inset well as the microphone picker, with a menu of
/// options and a checkmark on the current one (DESIGN.md › Components › Choice menu). Every
/// pick-one setting uses it (mouse button, Keep history, styles, learning).
struct ChoiceMenu<Option: Hashable & Identifiable>: View {
    let selection: Option
    let options: [Option]
    let title: KeyPath<Option, String>
    var symbol: String?
    var label: String = ""
    var width: CGFloat = 180
    let choose: (Option) -> Void
    @Environment(\.settingRowTitle) private var rowTitle

    var body: some View {
        Menu {
            ForEach(options) { o in
                Button {
                    choose(o)
                } label: {
                    if o == selection { Label(o[keyPath: title], systemImage: "checkmark") } else { Text(o[keyPath: title]) }
                }
            }
        } label: {
            HStack(spacing: Theme.Space.xs) {
                if let symbol {
                    Image(systemName: symbol).font(Theme.Typo.symbol).foregroundStyle(Theme.accent)
                }
                Text(selection[keyPath: title]).font(Theme.Typo.body).lineLimit(1)
                Spacer(minLength: Theme.Space.xxs)
                Image(systemName: "chevron.up.chevron.down").font(Theme.Typo.chevron).foregroundStyle(.secondary)
            }
            .padding(.horizontal, Theme.Space.snug).frame(width: width, height: 28)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).fill(Theme.inset))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).strokeBorder(Theme.cardBorder))
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel(label.isEmpty ? rowTitle : label)
        .accessibilityValue(selection[keyPath: title])
    }
}
