import SwiftUI
import WisprLocalCore

/// "How to use": the gestures, voice commands and what to do when text doesn't appear.
struct HelpView: View {
    let model: AppModel
    enum Tab: String, CaseIterable { case howTo = "How to use", why = "FAQ" }
    @State private var tab: Tab
    var expandAll = false

    init(model: AppModel, tab: Tab = .howTo, expandAll: Bool = false) {
        self.model = model
        _tab = State(initialValue: model.helpTabRequest ?? tab)
        self.expandAll = expandAll
    }

    var body: some View {
        Page(title: tab == .howTo ? "How to use" : "Help & FAQ",
             subtitle: tab == .howTo ? "Start, finish, cancel and get the most out of your dictation."
                                     : "Straight answers about privacy, accuracy and how it was built.",
             trailing: AnyView(HStack(spacing: 8) {
                 Button("Show Getting Started") { model.reopenGettingStarted() }.buttonStyle(BrandButtonStyle(prominent: false))
                 Button("Welcome Tour") { model.showOnboarding() }.buttonStyle(BrandButtonStyle(prominent: false))
             })) {
            TabSwitcher(selection: $tab)
            if tab == .howTo { howTo } else { FAQView(expandAll: expandAll) }
        }
        .onChange(of: model.helpTabRequest) { _, t in if let t { tab = t; model.helpTabRequest = nil } }
    }

    @ViewBuilder private var howTo: some View {
            HStack(alignment: .top, spacing: Theme.Space.s) {
                gestureCard(keys: 1, title: "Hold to talk",
                            text: "Hold 🌐 / fn while you speak. Release it to finish and type your words.")
                gestureCard(keys: 2, title: "Double-tap for hands-free",
                            text: "Tap 🌐 twice quickly, let go and speak. Click Done on the pill, or tap 🌐 once more, to finish.")
            }

            HelpSection(title: "Before you record", symbol: "checkmark.circle") {
                command("Choose where to type", "Click into a text field in the app you want to use. Keep it selected while you speak.")
                command("Permissions and model", "Check the Ready chip at the top of Settings (click it for the permission ticks). Wait for the speech model to be ready; after granting permissions, relaunch if asked.")
                command("Find the Globe / fn key", "Use 🌐 / fn at the bottom-left of your Mac keyboard. In System Settings › Keyboard, set “Press 🌐 key to” to Do Nothing. Change macOS's own Dictation shortcut if it also uses a Globe double-tap.", last: true)
            }

            HelpSection(title: "Handy shortcuts", symbol: "command") {
                command("Hold 🌐 to record", "Press and hold 🌐 / fn while you speak. Release it to finish and type the dictation at your cursor.")
                command("Double-tap 🌐 to start hands-free recording", "Tap 🌐 twice quickly, let go and speak without holding it down. The recording pill keeps counting until you finish.")
                command("Done or one tap to finish", "While recording hands-free, click Done on the pill or tap 🌐 once to finish and type the dictation. Letting go after the initial double-tap keeps recording.")
                command("Esc", "Cancels while recording or processing, before text is pasted. Over 30 seconds, press Esc twice. It can't remove text that's already been typed.")
                command("Triple-tap 🌐 to cancel", "While recording hands-free, tap 🌐 three times quickly to discard the current dictation. Nothing is typed.")
                command("One tap while idle", "A single quick tap while you're not recording is discarded. Use a hold or a double-tap to record.")
                command("Hold Shift as you let go", "Presses Return after the paste, to send a chat message. Never in remote mode or while macOS secure input is on (password fields). Turn it off in Settings › General.")
                command("A mouse button", "Choose Mouse button (Settings › General). Hold and release it to dictate, or double-tap for hands-free and press once more to finish.")
                command("Start and stop sounds", "Turn on Start and stop sounds in Settings › General for a tone when the mic starts and stops. These sounds aren't transcribed.")
                command("Right-click the pill", "Hides the indicator for an hour. Dictation keeps working; Undo on the notice, “Indicator Hidden — Show” in the menu bar brings it back.", last: true)
            }

            HelpSection(title: "Say it, and it's done", symbol: "text.bubble") {
                command("“scratch that”", "In English, say it as a separate sentence to remove everything you said before it in the current dictation. It doesn't undo text from an earlier dictation.")
                command("“new line” / “new paragraph”", "In English, say either command on its own or as a separate sentence: new line inserts a line break; new paragraph inserts a blank line.")
                command("A snippet trigger", "Create a trigger and its text in Snippets. Say the trigger on its own, like “my calendar link”, to type the whole snippet.", last: true)
            }

            HelpSection(title: "Improve a transcription", symbol: "text.badge.checkmark") {
                command("Dictionary", "Add names, jargon and spellings in Dictionary so future dictations can use them.")
                command("Fix a Word…", "In History, open a dictation's row menu or details and choose Fix a Word… to teach a spelling. If learning is on, correcting a word in a readable text field can also offer Add on the pill.")
                command("Writing preferences", "Settings › Writing controls punctuation and per-app styles. Fix “actually” corrections is optional; when a correction notice offers Undo, use it to restore the words as spoken.")
                command("Listen and compare", "Open a dictation in History to compare Heard (raw) with Inserted (final). When a recording was kept, play it or re-transcribe it with the other Parakeet model; this comparison leaves History unchanged.", last: true)
            }

            HelpSection(title: "If the text doesn't appear", symbol: "wrench.and.screwdriver") {
                command("Check the menu bar icon", "A dot means something needs attention; a slash means it's holding off for Wispr Flow. Click it: the top line of the menu says what, with the fix.")
                command("Check permissions", "Check the Ready chip at the top of Settings (click it for the permission ticks). After turning one on, macOS may ask you to relaunch WisprLocal.")
                command("Clicked away while talking?", "At insertion time, WisprLocal checks that the frontmost app (process and bundle) is still the one you started in. If it changed, the text is copied to the clipboard instead. Changes of window or field within the same app are not detected.")
                command("Paste the last dictation again", "Focus a text field and press \(PasteAgainShortcut.display) (Control–Option–Command–V) to repeat the most recent dictation's text from this session, including one copied after an app switch or a failed paste. Home and History also have Copy buttons.")
                command("Password fields", "WisprLocal relies on macOS secure input: when it is enabled, nothing is inserted; no text or audio is kept; History shows only the time, the outcome and the app. Fields that do not enable that signal are not detected. Cancelled dictations keep no words or audio.")
                command("No sound or missed words?", "Check the selected input in Settings › Microphone. Speak closer to the mic. Try turning Noise reduction off if soft speech is missed or your headset already processes the sound.", last: true)
            }

            HelpSection(title: "Good to know", symbol: "sparkles") {
                command("Recording limits", "Hold-to-talk finishes automatically at 5 minutes; hands-free finishes at 10 minutes. The pill counts down during the last 15 seconds, then the dictation is processed and typed.")
                command("Move the recording pill", "Choose its position in Settings › General. Its position is remembered for each display, so you can keep it away from the text you're writing.")
                command("Noisy Room Mode", "Off uses English Parakeet v2. Turn it on in the menu bar or Settings › Microphone for Parakeet Ultra, which also understands 25 European languages. Wait for the model switch to finish before recording.")
                command("Orange mic dot", "With Microphone readiness (Settings › Microphone) set to Ready for 60 s after dictating, macOS can show the mic dot for 60 seconds after you finish. Click the “Mic Ready” countdown in the menu bar to stop it now. Configure this in Settings › Microphone.")
                command("History and recordings", "Delivered text is kept in History. Settings › Privacy controls retention and whether to keep the last 20 recordings locally (on by default); turn recordings off in Settings › Privacy. Failed dictations may keep audio, never text.")
                command("Screen Sharing (Beta)", "Pair your other Mac with WisprLocal Receiver in Settings › Remote Macs. Without the receiver, WisprLocal types into the Screen Sharing window; keep it in front until it finishes.")
                command("Wispr Flow installed too?", "Wispr Flow gets priority. While it's running, WisprLocal stays out of the way completely: 🌐 goes to Wispr Flow, and WisprLocal's mic stays off. Quit Wispr Flow and WisprLocal works again on its own. Moved Wispr Flow off 🌐? Turn on “Wispr Flow uses a different shortcut” in Settings › General.")
                command("Offline dictation", "Speech recognition, cleanup, learning and history run on this Mac without network access. The only network feature is Remote Macs (Beta): finished text, never audio, is sent to a Mac you pair over your Tailscale network, authenticated with HMAC. Without pairing, WisprLocal types locally into a Screen Sharing window; WisprLocal uses no network for that fallback.", last: true)
            }
    }

    private func gestureCard(keys: Int, title: String, text: String) -> some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            HStack(spacing: 4) { ForEach(0..<keys, id: \.self) { _ in KeyCap(size: 40) } }
                .frame(width: 88)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.Typo.bodyEmphasis)
                Text(text).font(Theme.Typo.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
        .card()
    }

    private func command(_ title: String, _ text: String, last: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
                Text(title).font(Theme.Typo.bodyEmphasis).frame(width: 210, alignment: .leading)
                Text(text).font(Theme.Typo.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s)
            if !last { Rectangle().fill(Theme.separator).frame(height: 1).padding(.leading, Theme.Space.m) }
        }
    }
}

struct HelpSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content
    var body: some View {
        SettingsGroup(title: title, symbol: symbol) { content }
    }
}

/// Brand segmented switch (two or three short options).
struct TabSwitcher<T: Hashable & RawRepresentable & CaseIterable>: View where T.RawValue == String, T.AllCases: RandomAccessCollection {
    @Binding var selection: T
    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(T.allCases), id: \.self) { t in
                let on = t == selection
                Button { withAnimation(.snappy(duration: 0.2)) { selection = t } } label: {
                    Text(t.rawValue).font(Theme.Typo.chip.weight(on ? .semibold : .medium))
                        .foregroundStyle(on ? .primary : .secondary)
                        .padding(.horizontal, Theme.Space.ms).frame(height: 28)
                        .background(Capsule().fill(on ? Theme.card : .clear).shadow(color: .black.opacity(on ? 0.08 : 0), radius: 2, y: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(Theme.Space.xxs)
        .background(Capsule().fill(Theme.inset))
        .overlay(Capsule().strokeBorder(Theme.cardBorder))
    }
}

/// The FAQ. Content: `FAQ.items` (WisprLocalCore/Support/HelpContent.swift), the same text as
/// the readme's FAQ (`HelpContentTests`). Numbers come from S1b RESULTS.md / TEST_REPORT.md.
struct FAQView: View {
    var expandAll = false
    @State private var open: Set<String> = ["offline", "model"]

    var body: some View {
        VStack(spacing: Theme.Space.xs) {
            ForEach(FAQ.items) { item in
                let isOpen = expandAll || open.contains(item.id)
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        withAnimation(.snappy(duration: 0.22)) {
                            if open.contains(item.id) { open.remove(item.id) } else { open.insert(item.id) }
                        }
                    } label: {
                        HStack {
                            Text(item.question).font(Theme.Typo.bodyEmphasis)
                            Spacer()
                            Image(systemName: "chevron.down").font(Theme.Typo.micro).foregroundStyle(.secondary)
                                .rotationEffect(.degrees(isOpen ? 0 : -90))
                        }
                        .padding(.horizontal, Theme.Space.m).frame(height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if isOpen {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(item.answer, id: \.self) { p in
                                Text(p).font(Theme.Typo.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.horizontal, Theme.Space.m).padding(.bottom, Theme.Space.ms)
                    }
                }
                .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.cardBorder))
            }
            Text("Figures from the project's own test report. Accuracy was measured with synthetic voices on small sets.")
                .font(Theme.Typo.caption).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading).padding(.top, Theme.Space.xxs)
        }
    }
}
