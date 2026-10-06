# Changelog

All notable changes to WisprLocal are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## 1.0.0 — source code only

- History, Home and search stay fast as history grows: newest entries load first, older days page in as you scroll, and new dictations update the screens without re-reading the file.

First version of WisprLocal, a native push-to-talk dictation app with local speech recognition, cleanup, learning and history for macOS 26 on Apple Silicon. Published as source code only; there is no prebuilt download.

- Complete the recording guide in Help and Getting Started: hold/release, double-tap, Done/single-tap finish, cancellation and text recovery. Extend the Welcome Tour with separate hands-free practice and a finish/cancel/recover page; expand Help's setup, spelling, microphone, privacy and troubleshooting guidance.

- Add an explicit double-tap shortcut for starting hands-free recording to Help's Handy shortcuts list, including how to finish.

- Label triple-tap explicitly as cancellation in Help, Settings and the README; double-tap remains the hands-free recording gesture.

- Remove the recurring “Pasted · paste again” HUD reminder after dictation. Keep the re-paste shortcut and the warning when a paste is verified not to have landed.

- Simplify the menu to Open Dashboard, Settings, Noisy Room Mode with its language subtitle, Help and Quit; remove Pause entirely and keep Copy on Home/History and Hide in the pill’s right-click menu. Make hands-free Done accept the first click under a stationary cursor, bound implausible hotkey timestamps without changing normal gestures, and make the live spike's model path configurable.

### Fixed (pre-release review, 2026-10-04)

- The recording pill's waveform now adapts per dictation to quiet microphones, so it moves with noise reduction off too. Display gain uses a 1.5-second minimum noise floor and persistent speech peaks, adds at most 18 dB without attenuation, and ignores isolated clicks (display only; transcription is unchanged).
- Adaptive clipboard restore is now active; it was pinned to 400 ms.
- A copy you make between dictations is never lost.
- Secure input, the frontmost app and Wispr Flow are re-checked right before every paste.
- Esc stops remote typing and the delayed remote paste at once.
- A failed insertion copies the text to the clipboard and becomes the re-paste text.
- The word-for-word guard keeps $, %, +, −, =, <, >, # and math symbols.
- The Receiver no longer crashes on an extreme timestamp.
- No receiver becomes the default until you choose one.
- Permission loss is detected within 10–20 s, with event-tap recovery.
- Retention pruning cannot lose a new dictation.
- Malformed recordings cannot crash the app.
- URL fields are never read.
- The installed app ignores the models-directory override.
- Both apps use the hardened runtime; the main app carries the audio-input entitlement.
- One VERSION file supplies the app version.
- A model file manifest defines and verifies what ships.
- A CI workflow runs the build, tests and privacy checks.
- Settings now has five tabs and a setup banner.
- Public wording now accurately describes privacy, controls and limits.
- A microphone interruption stops recording and processes the audio captured so far.

### Dependencies and test audio

- Credit FluidAudio explicitly in About, Credits, the FAQ and documentation; record each bundled model's pinned revision and conversion history. Correct the FAQ's Silero licence to MIT.
- Remove the rejected Phonon-2 variant from the app, replay tool and model downloader. Historical experiments remain under Spikes.
- Verify each assembled app and receiver before signing: retained FluidAudio code and notices, supported model attribution, and exclusion of the unused native engine, LuxTTS data and test resources.
- Disable FluidAudio's unused native text-normalization engine in the app and audio benchmarks, and exclude its notice from app and receiver packages. Speech recognition and VAD continue to use FluidAudio.
- Replace the Apple system-voice test recording with eSpeak NG formant speech, with a reproducible generator and recorded provenance.

### Layout and hands-free recording fixes

- Dictation details scroll within a bounded sheet, with Done always visible. Long transcripts, model comparisons and metadata no longer overlap.
- Home and Insights stack crowded panels in narrower windows. History tags wrap, activity charts scroll within their card, and long dictionary words and correction chips stay within their container.
- Globe double-taps ignore the extra Globe event emitted immediately after a quick release on recent Apple keyboards, instead of cancelling as if the user had started typing. Hardware timestamps are converted from their actual clock units; queued events during microphone startup still retain their physical press and release times.
- Hands-free recording shows a red dot, waveform, elapsed time and a Done button. Done stops and inserts the dictation without changing the focused app; tapping Globe again still works.

### Controlling a dictation (Esc and triple-tap in Help; mouse, sounds and Shift-to-send in Settings › General)

- **Esc cancels** a dictation while it's recording or being processed. The mic stops, nothing is typed, and the pill says "Cancelled". Over 30 seconds the first Esc asks "Press Esc again to discard 42 s". Esc is taken only while a WisprLocal dictation is active; otherwise it reaches your app untouched. History records the attempt as cancelled, with no text and no audio. Cancel reaches every step, including a slow AI-formatting pass.
- **Triple-tap 🌐 cancels hands-free**: the first tap still stops at once, the second holds the text back for a moment, the third cancels. Only quick taps count: a press you hold right after stopping starts a new dictation as usual (the warm mic's 300 ms pre-roll covers the wait), so the triple-tap window never blocks you.
- **A mouse button as push-to-talk**: middle button, button 4 or button 5, with the same hold and double-tap gestures as 🌐. Only the chosen button is taken over, through a separate event tap that exists only while one is chosen.
- **Start and stop sounds** (off by default): a soft tone generated in code. It is never transcribed; the sound's moment is cut from the capture, including from the warm mic's pre-roll.
- **Hold Shift as you let go to press Return** after the paste, to send a chat message. Never in remote mode or while macOS secure input is on (password fields), and not after a paste that was seen to fail.

### Writing (Settings › Writing)

- **Per-app styles** (on by default): Formal for email, documents, browsers and other apps; Casual (no full stop on a one-line message) for chats and AI tools; Code (no auto-capital, no full stop, identifiers untouched) for editors and terminals; Very casual (lowercase start, no full stop) if you want it. Each kind of app shows a live example, and any app can get its own style. Styles change only the first capital and the final full stop, for English only and never on snippets; a property test checks that no word is ever added, removed or changed.
- **Fix “actually” corrections** (off by default): a time, number or amount, weekday, month or single name restated straight after "actually", "no", "sorry", "I mean", "make that" or "or rather" replaces the value before it ("at 2, actually 3" → "at 3"). Anything less clear is typed verbatim. The pill shows "Corrected" with **Undo** for 8 seconds: Undo sends the app's own ⌘Z and pastes the words as spoken (pasted text only, same app, through the usual safety gates; if you've switched apps the original goes to the clipboard). After Shift-to-send there is no Undo, since the message has gone. History records the style and that a correction was made.

### Dictionary & learning (Settings › Writing)

- **Learns words from your corrections** (Suggest by default, Add automatically or Off). After a paste into a readable text field, WisprLocal watches that field for up to 15 seconds. Retype one inserted word, or a 2–3 word phrase, as a sound-alike spelling ("kuber netties" → "Kubernetes") and the pill asks "Always write “kuber netties” as “Kubernetes”?" with **Add** and **Not now**. Words you delete from the dictionary are never suggested again unless you add them back yourself. Undoing a quick correction is never mistaken for one of yours.
- **Fix a Word…** in History (row menu and details): pick the word(s) it got wrong and type the spelling. The way to teach it in apps whose text macOS can't read.
- **Dictionary words bias spelling**: a close-sounding word or phrase snaps to a dictionary term when it is the only strong match (always on, English only).
- **Names and terms from the text around your cursor** (opt-in): at recording start WisprLocal reads the text near the caret, the window title and Mail/Outlook To/From names, and snaps sound-alike words to the names and identifiers it finds ("Sean" → "Shaun"; `getUserById` in code apps). Kept in memory for that dictation only; History records a count, never text.

### Indicator and notices

- **Hide the indicator for 1 hour** by right-clicking the pill (**Hide Indicator for 1 Hour**). A notice confirms it, with **Undo**; while hidden the menu's top line reads **Indicator Hidden — Show**. Dictation keeps working, and notices still show.
- **One notice system**: one notice at a time, in one order of importance (problems with your words or the mic, then Undo, then dictionary suggestions, then status), 8 seconds for a notice with a button and 3 seconds without. A notice interrupted by a more important one comes back afterwards; starting a new dictation clears them so the pill always shows the mic is on.

### Settings, history and privacy

- **Five Settings tabs**: General, Microphone, Writing, Privacy and Remote Macs, with a setup banner for missing permissions or models.
- **Keep history** (Settings › Privacy): forever (the default), 30 days, 7 days or 24 hours. Older entries and their recordings are removed at launch and every hour.
- False-positive safeguards for snapping: common English words are never rewritten ("their"/"there"), only a single strong candidate is used, phrases of common words snap only on an exact match and never to a context name, identifiers only in code apps, handles only after a spoken "at". Learning never turns a common-word swap into a rule.
- Nothing the smart dictionary reads is logged. The watcher never reads secure fields or requested text windows over 20,000 characters, and the context reader checks the switch, Secure Event Input and the excluded apps (password managers, Keychain Access, banking apps, any you add) before reading anything.

### For developers

- Environment variables are now `WISPRLOCAL_*` (`MODELS_DIR`, `REQUIRE_MODELS`, `PROFILE`, `FM_BENCH`, `LATENCY_BENCH`, `MODEL_SOURCES`); the old `WISPRLITE_*` names still work as fallbacks.
- `scripts/test_offline.sh` finds the model cache from a git worktree (via the main checkout).
- `ManualClock` is fully deterministic (`waitForSleepers`), which fixes the intermittent `holdCapCountsDownThenCommits` failure and the same race in other clock-driven tests.
- The dictation pipeline has one documented order (DESIGN.md › Dictation pipeline order), pinned by `PipelineOrderTests`. `DesignTokenLintTests` fails on hard-coded colours, font sizes, radii or paddings outside `Theme.swift`.


### Added

- **Push-to-talk dictation**: hold 🌐 (Globe/fn) to talk, or double-tap for hands-free. Text is inserted at the cursor in the frontmost app, with the clipboard restored afterwards.
- **On-device speech recognition** on the Apple Neural Engine (Core ML, via FluidAudio 0.17.5), plus Silero VAD silence trimming. Two bundled models, only the active one loaded: **English (Parakeet v2)**, NVIDIA's Parakeet TDT 0.6B v2, the default; and **Noisy room / other languages (Parakeet Ultra)**, Moondream's Parakeet Ultra, a toggle in the menu bar and Settings › Microphone (off by default). Ultra is better with a TV or other people talking (synthetic TV -6 dB: 7.55 % vs 19.03 % WER; measured by feeding audio straight to the models, without the app's voice processing; real-world gaps may differ) and supports 25 European languages (not yet tested by us). Switching unloads the old model and prepares the new one in the background. Nothing is downloaded at runtime.
- **Warm microphone pre-roll**: starting the mic mutes its first ~0.2 s, so the mic now stays ready for 60 s after each dictation (Settings › Microphone, on by default) and a dictation inside that window keeps the 300 ms before you pressed 🌐. The menu bar shows "Mic Ready · 0:42 — Stop" while the orange dot is on; unused warm audio stays in memory; pre-roll becomes part of the dictation and its recording if recordings are on. The warm buffer is cleared on lock, sleep, user switch, password fields, holding off for Wispr Flow, or quit. **Always on** (off by default) keeps the mic on. From a cold mic the recording pill shows a dim dot until audio flows.
- **English-only cleanup**: when text has at least three words and is confidently recognised as another language, it is typed as heard plus dictionary replacements, with no filler, backtrack, "scratch that" or AI formatting. Short or uncertain text gets English cleanup.
- **In-app help**: ⓘ popovers next to every non-obvious setting, and **Help & FAQ** in the menu bar (the same FAQ is in the readme).
- History and troubleshooting recordings note whether Apple voice processing was on; `WisprLocalReplay --compare-all` compares both models on your own recordings.
- **Voice commands**: "scratch that", "new line", "new paragraph".
- **Snippets** triggered by a spoken phrase, and a **personal dictionary** with replacement rules (seeded with "Wispr Flow" and "Tailscale" fixes).
- **Optional AI formatting** with Apple's on-device Foundation Models, checked by a word-for-word guard (equal normalised word-token sequences plus case/layout checks) that falls back to a deterministic rule-based cleaner whenever the model would change your words. Off by default.
- **History** of dictations with per-entry delete and Clear All.
- **Noise reduction** (Apple voice processing) and microphone selection.
- **Recording indicator** with a live spectrum, movable per display.
- **Remote Macs (Beta)**: insertion into Screen Sharing, plus the separate **WisprLocal Receiver** app for authenticated delivery to a paired Mac over Tailscale. Built, unit- and loopback-tested; not yet tested end to end on two real Macs. See [REMOTE.md](WisprLocal/docs/REMOTE.md).
- **Wispr Flow conflict detection**: WisprLocal holds off while Wispr Flow is running, so nothing is typed twice.
- **Permission health checks**: the setup window, menu and indicator check Microphone, Accessibility and Input Monitoring every 2 seconds until everything is granted, then every 10 seconds, explain exactly what to toggle, offer Relaunch, and detect stale grants.
- **Troubleshooting recordings, on by default** (last 20, local only; turn off in Settings › Privacy) and an offline replay tool (`WisprLocalReplay`).
- **About WisprLocal › Credits…** (menu bar icon › Help) with every bundled licence.
- Install by building from source (`scripts/build_app.sh`, `scripts/install.sh`); no prebuilt download is offered. `scripts/make_release.sh` exists for maintainers and publishes nothing.

### Security and privacy

- Speech recognition, cleanup, learning and history use no network. Enforced by a source scan (`OfflineGuardTests`) and by running the tests (socket-dependent and opt-in tests are skipped) with the network denied (`scripts/test_offline.sh`). The opt-in remote bridge is the only networking code; it binds and connects only over Tailscale's `utun` interface.
- No dictated words in the system log (`LogHygieneTests`). Dictations refused by the focus, secure-input or Wispr Flow checks are kept in history without their words or audio. History, dictionary and recordings are owner-only (0600/0700).
- Remote: the receiver refuses while macOS secure input is enabled on the remote Mac; the text reached the receiver but is not inserted or kept, and the sender never types the text instead. The pairing code is concealed on the clipboard and cleared after use.
- Lost-key safety: if the 🌐 key-up is missed, WisprLocal notices the key is no longer held and stops. Recordings are capped at 5 min (hold) and 10 min (hands-free), with a 15 s countdown.
- Signed with a stable, self-signed "WisprLocal Local Signing" certificate that you create once with `scripts/create_signing_identity.sh`, so permissions survive rebuilds. See [INSTALL.md](WisprLocal/docs/INSTALL.md).

### Known limitations

- Accuracy figures in the [test report](WisprLocal/docs/TEST_REPORT.md) use synthetic voices on one machine (M5 Pro). Real-voice and M1-class results are not yet measured.
- Tested in English only (Ultra's other languages are supported by the model, not yet tested by us).
- Remote Macs is **Beta**: not yet tested end to end on two real Macs over Screen Sharing and Tailscale.
- Preparing a speech model for the first time — on first launch, after each macOS update, or the first time you switch to the other model — took 7–12 s in the latest measurement and 18–23 s in the original spike; after that it loads in well under a second.

### Removed

- The earlier Python CLI and cloud prototype are not part of this repository.
