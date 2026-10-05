# Installing WisprLocal

> Building from source is the only way to install WisprLocal. There is no prebuilt download or release.

This is the detailed guide. The short version is in the [README](../../readme.md#build-from-source), which also covers Xcode setup and common build errors.

- [Requirements](#requirements)
- [1. Build and install](#1-build-and-install)
- [2. First launch](#2-first-launch)
- [3. Why permissions survive rebuilds](#3-why-permissions-survive-rebuilds)
- [4. Permissions](#4-permissions)
- [5. The Globe key](#5-the-globe-key)
- [Updating](#updating)
- [Troubleshooting](#troubleshooting)
- [Uninstall](#uninstall)

## Requirements

- macOS 26 or later
- A Mac with Apple Silicon (M1 or later)
- Xcode 26.6 or later (tested with 26.6 and 27; set up once; see the README)
- Approximately 5 GB of free disk space while building (about 1.1 GB for the finished app with both models; machine and build dependent)
- Internet for the first build only, to download Swift packages and the models; the build needs a few GB of disk
- Optional: Apple Intelligence turned on, for AI formatting only

The app version comes from `WisprLocal/App/VERSION`. Both apps are signed with the hardened runtime. A build signed with a different identity than before needs Microphone, Accessibility and Input Monitoring permissions granted again.

## 1. Build and install

From a Terminal, with Xcode set up as in the [README](../../readme.md#build-from-source):

```bash
git clone https://github.com/tommyyau/wisprlocal.git && cd wisprlocal/WisprLocal/App
scripts/fetch_models.sh            # one-time model download (build_app.sh also does this if skipped)
scripts/create_signing_identity.sh # recommended, once: keeps your privacy permissions across rebuilds
scripts/build_app.sh               # builds build.noindex/WisprLocal.app
scripts/install.sh                 # copies it to ~/Applications/WisprLocal.app
open ~/Applications/WisprLocal.app
```

The first `swift build` downloads the FluidAudio package from GitHub, plus a prebuilt NemoTextProcessing artifact that WisprLocal does not link. `scripts/fetch_models.sh` downloads the models from Hugging Face unless local copies are available. The app itself never uses the network for dictation.

To copy models from local folders first, set `WISPRLOCAL_MODEL_SOURCES="dir1:dir2"` before running `scripts/fetch_models.sh`. Each colon-separated source folder contains model subfolders such as `parakeet-ultra`.

Because you built the app on your own Mac, macOS doesn't quarantine it, so there is no Gatekeeper "Open Anyway" step.

## 2. First launch

Run WisprLocal from `~/Applications`. A setup window walks you through the permissions in [step 4](#4-permissions). Preparing a speech model for the first time — on first launch, after each macOS update, or the first time you switch to the other model — took 7–12 s in the latest measurement and 18–23 s in the original spike; after that it loads in well under a second.

The Welcome Tour then explains the Globe / fn key, lets you practise hold-to-talk and hands-free recording separately, and covers finishing, cancelling and recovering text. Reopen it with **Help › Welcome Tour** in the main window. **Help › How to use** contains the full reference, and Home's **Getting started** cards keep the recording controls beside the practice box.

## 3. Why permissions survive rebuilds

`scripts/create_signing_identity.sh` makes a certificate named "WisprLocal Local Signing" on your own Mac, and `build_app.sh` signs the app with it every time. Apple doesn't vouch for that certificate, but it is stable.

macOS records each privacy permission (Microphone, Accessibility, Input Monitoring) against the app's **designated requirement**, the rule a signature uses to say "this is still the same app". For an app signed with a certificate that isn't from Apple, `codesign` builds that rule from the bundle identifier (`com.tommyyau.wisprlocal`) plus a hash of the signing certificate. Apple's TN3127 explains that apps with matching designated requirements share access to privacy-protected resources ([TN3127: Inside Code Signing: Requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)). TN2206 adds that this stability "does not depend on the nature of the certificate authority used", and that self-signed identities work for it ([TN2206: macOS Code Signing In Depth](https://developer.apple.com/library/archive/technotes/tn2206/_index.html)).

In practice:

- **Rebuilds signed with the same identity keep your permissions.** You don't re-grant Microphone, Accessibility or Input Monitoring after updating.
- **Without the identity, the build is ad-hoc signed** (the build prints a boxed warning), and the permissions reset on every rebuild.
- You can see the requirement yourself: `codesign -d -r- ~/Applications/WisprLocal.app`.

## 4. Permissions

On first launch a setup window walks you through three permissions. Each one has a button that opens the right System Settings pane.

| Permission | Why | Where |
|---|---|---|
| **Microphone** | To hear you while 🌐 or a chosen mouse button is held, during hands-free, the three-second mic test and mic-ready capture | macOS asks with a dialog. Click Allow |
| **Input Monitoring** | To notice the 🌐 key from any app | System Settings › Privacy & Security › Input Monitoring › turn on WisprLocal |
| **Accessibility** | To type the words where your cursor is | System Settings › Privacy & Security › Accessibility › turn on WisprLocal |

After turning on Input Monitoring or Accessibility, macOS may need WisprLocal to restart. The app checks every 2 seconds until everything is granted, then every 10 seconds, and offers a **Relaunch** button when it does. Use the Ready chip at the top of Settings (click it for the permission ticks).

## 5. The Globe key

WisprLocal uses the 🌐 key (labelled **fn** or **🌐 fn** on most Mac keyboards).

Click into the text field you want to use first, and keep it selected while you speak.

- **Hold** 🌐 / fn while you speak, then **release** to finish and type (up to 5 minutes).
- **Double-tap** 🌐 quickly, let go and speak hands-free; click **Done** on the recording pill or tap 🌐 once more to finish and type (up to 10 minutes).
- **Esc** cancels while recording or processing, before text is pasted; after 30 seconds, press Esc twice. Cancelling can't remove text that's already been typed.
- **Triple-tap** 🌐 while recording hands-free also cancels. It doesn't start a recording.
- **One quick tap while idle** is discarded; use a hold or a double-tap to record.
- **⌃⌥⌘V** (Control-Option-Command-V) repeats the most recent dictation's text from this session, including after an app switch or a failed paste. Home and History also have Copy buttons.

macOS has its own uses for the Globe key. If pressing it also opens the emoji picker or switches input source, change it in **System Settings › Keyboard › "Press 🌐 key to"** and choose **Do Nothing**. If you use macOS's own Dictation with a Globe shortcut ("Press 🌐 twice"), change that shortcut in **System Settings › Keyboard › Dictation** so the two don't both start.

## Updating

From `WisprLocal/App`:

```bash
git pull && scripts/build_app.sh && scripts/install.sh
```

`install.sh` quits the running copy and replaces it. Your dictionary, history and settings are kept, and your privacy permissions carry over as long as you build with the same signing identity.

## Troubleshooting

### Nothing happens when I hold 🌐

Work down this list:

1. **Look at the menu bar icon.** A badge means something needs attention; click it to see what.
2. Check the Ready chip at the top of Settings (click it for the permission ticks). If one is missing, use its button to open System Settings.
3. **Is the model still preparing?** Preparing a speech model for the first time — on first launch, after each macOS update, or the first time you switch to the other model — took 7–12 s in the latest measurement and 18–23 s in the original spike; after that it loads in well under a second. Dictation waits until it's ready (the HUD says "Speech model still preparing…").
4. **Is Wispr Flow running?** Both apps listen to 🌐, so WisprLocal holds off while Wispr Flow is open. Quit one of them.
5. **Is the Globe key doing something else?** See [The Globe key](#5-the-globe-key).
6. **Are you in a password field?** WisprLocal relies on macOS secure input: when enabled, nothing is inserted; no text or audio is kept; History shows only the time, the outcome and the app. Fields that do not enable it are not detected.
7. **Did you switch apps while talking?** At insertion, WisprLocal checks the frontmost process and bundle against the app you started in. A changed app sends the text to the clipboard instead; press ⌘V where you want it. Changes of window or field inside the same app are not detected. Only delivered dictations keep text in History.
8. Still nothing: try a **permission reset** (below).

### Permissions show ON but don't work (permission reset)

System Settings can show WisprLocal as ON when the grant belongs to an older copy of the app. WisprLocal spots this and shows a *stale permission* hint. To fix it:

1. Quit WisprLocal.
2. In **System Settings › Privacy & Security › Accessibility**, select WisprLocal and click **−** to remove it. Do the same in **Input Monitoring**.
3. Open WisprLocal and grant both again (or click **+** and add `~/Applications/WisprLocal.app`).

For a clean slate, reset all of WisprLocal's privacy grants from Terminal, then reopen the app and grant them again:

```bash
tccutil reset All com.tommyyau.wisprlocal
```

### "Mic Mode" appears in Control Center

That's expected when **Noise reduction (Apple voice processing)** is on (Settings › Microphone; off by default since 2026-10-03). It suppresses steady noise like fans and hum at the mic; for a TV or people talking, use the Noisy room speech model instead. It uses Apple's voice processing, and macOS shows a Mic Mode control in Control Center whenever an app uses it. Turn noise reduction off if you'd rather not see it.

### The text didn't appear (or the old clipboard was pasted)

WisprLocal pastes with ⌘V and then puts your own clipboard back. Some apps — especially Electron apps such as the Codex and Claude desktop apps, Slack or VS Code — read the clipboard late when they are busy, so the clipboard is now held for at least 1.5 s, longer for long text and about twice as long in Electron apps, and never restored over anything you copied meanwhile. Where macOS lets WisprLocal see the text field, it checks that the paste landed and pastes once more if the field didn't change. Where it can't check (Electron apps), the HUD closes quietly after processing. A warning still appears if verification finds that the field stayed unchanged after retrying.

**⌃⌥⌘V** (Control-Option-Command-V) pastes your last dictation again into whatever is focused, through the same password-field and Wispr Flow checks. Home and History also have Copy buttons. History records, without any words, whether each paste was verified, retried, and how long the clipboard was held.

### Audio cuts out, or "Didn't catch that" in a loud place

In very loud places (planes, trains), a **headset mic close to your mouth** works far better than the built-in mic, which also picks up the people next to you.

WisprLocal measures every dictation for audio that went *digitally* silent (a real room never does that at a laptop mic, so something upstream gated it). A dictation counts as cutting out when more than 5 % is digitally silenced or a silent run exceeds 250 ms. The HUD says "Mic cutting out — try turning off noise reduction" at most once per session when the newest dictation is cutting out and either two of the last three are cutting out, or this one is severe (more than 25 % silenced or a gap over 600 ms). The tip waits if another notice is shown and is never shown on a safety refusal. On a plane with the built-in mic we measured 15 of 20 dictations over the limit (median 10 % silenced, gaps up to 481 ms) with Noise reduction on; the cause is Apple voice processing's noise suppression, not WisprLocal's capture path (the capture tests prove our stages never insert silence). Noise reduction is therefore **off by default** (an explicit choice you made earlier is kept). Fixes, in order:

1. **Test…** next to the microphone in **Settings › Microphone** records 3 s with your current settings and says, in plain words, whether the level is good and whether the audio cuts out. If Noise reduction is on, it repeats with it off and shows both side by side. The test recordings stay in memory and are gone when you close the window.
2. Turn **Noise reduction** off, or click **`<mode>` · Change…** and choose **Standard** (Voice Isolation suppresses more).
3. Use a headset mic.

From the source folder you can run the same check in Terminal (quit WisprLocal first so the mic is free): `swift run WisprLocalReplay --mic-check` (add `--vp off` to test only with noise reduction off). `swift run WisprLocalReplay --gating` prints the numbers for every saved recording (no words).

When the mic heard you but no words came out, the HUD says **"Didn't catch that — try again"**; **See why** opens the entry in History, where you can replay the recording and see the mic numbers. **Check your microphone** also says whether your recent dictations cut out ("Cutting out on 2 of the last 3"), and the Ready chip popover at the top of Settings shows whether lost-🌐-release detection works on this Mac.

### The wrong microphone is used

Pick the mic in **Settings › Microphone**. It's the same as your Mac's Sound input.

### English came out in another language, or a TV / other voices got typed

These are the two speech models' trade-offs. **English (Parakeet v2)**, the default, is English only, but other voices in the room can get transcribed. **Noisy room / other languages (Parakeet Ultra)** is better at ignoring a TV or people talking and knows 25 European languages, but occasionally guesses the wrong language on very short phrases. Switch in the menu bar (**Noisy Room Mode**) or Settings › Microphone. Non-English text is typed as heard, without cleanup.

### How to compare models on your own voice

1. Make sure **Settings › Privacy › "Keep last 20 recordings (on this Mac)"** is on (it is by default).
2. Use WisprLocal normally for a day.
3. From the source folder `WisprLocal/App`, run `swift run -c release WisprLocalReplay --compare-all`. It re-transcribes every saved clip offline with both models and prints them side by side, with the differences highlighted, then a summary (identical / different, non-English detections, empty outputs and average latency per model, split by voice processing on/off).
4. Turn the recordings off again, or delete them in Settings › Privacy.

### Words are misrecognised

Add the word to **Dictionary** (as a term, or as a replacement for the mishearing). To report a misrecognition, use a clip kept by **Settings › Privacy › "Keep last 20 recordings (on this Mac)"**. Recordings are on by default, only the last 20 are kept, and they never leave your Mac; only attach one to an issue if you're happy to share that audio.

You can change the History folder in Settings › Privacy › History folder. If you choose a cloud-synced folder, your history syncs with it.

## Uninstall

1. Quit WisprLocal (menu bar icon › Quit).
2. Delete `~/Applications/WisprLocal.app`.
3. Delete your data, if you want it gone:

```bash
rm -rf ~/Library/Application\ Support/WisprLocal        # dictionary, history, troubleshooting recordings
rm -rf ~/Library/Caches/com.tommyyau.wisprlocal         # caches, incl. the compiled Neural Engine model, if present
defaults delete com.tommyyau.wisprlocal 2>/dev/null     # settings
tccutil reset All com.tommyyau.wisprlocal               # privacy permissions
```

Older pre-release builds were called WisprLite. If you used one, you can also delete `~/Library/Application Support/WisprLite`.

4. If you installed the receiver on another Mac, quit it, delete `WisprLocalReceiver.app` (wherever you copied it), and run `tccutil reset All com.tommyyau.wisprlocal.receiver` there.
