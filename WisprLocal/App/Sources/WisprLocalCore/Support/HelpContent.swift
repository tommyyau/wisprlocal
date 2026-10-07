import Foundation

/// The ONE source of the app's explanatory copy: the ⓘ popovers (`InfoTopic`) and the FAQ
/// (`FAQ.items`). The readme's "FAQ" section carries the same questions and answers;
/// `HelpContentTests` fails if they drift apart. Every number here comes from
/// WisprLocal/Spikes/S1b-models/RESULTS.md or WisprLocal/docs/TEST_REPORT.md. Tone: DESIGN.md
/// "Voice and tone" (short, warm, plain English, second person, no selling).
public enum InfoTopic: String, CaseIterable, Sendable, Identifiable {
    case speechModel, noiseReduction, micMode, micTest, micReady, aiFormatting, dictionary, snippets, debugRecordings,
         shortcut, wisprFlowShortcut, indicator, remoteMacs, permissions, playback, controls, styles, backtrack,
         learnCorrections, contextNames

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .speechModel: return "Speech model"
        case .noiseReduction: return "Noise reduction"
        case .micMode: return "Mic Mode"
        case .micTest: return "Check your microphone"
        case .micReady: return "Microphone readiness"
        case .aiFormatting: return "Formatting"
        case .dictionary: return "Dictionary"
        case .snippets: return "Snippets"
        case .debugRecordings: return "Recordings on this Mac"
        case .shortcut: return "The 🌐 shortcut"
        case .wisprFlowShortcut: return WisprFlowCopy.differentShortcut
        case .indicator: return "The recording pill"
        case .remoteMacs: return "Remote Macs (Beta)"
        case .permissions: return "Permissions"
        case .playback: return "Replaying dictations"
        case .controls: return "Cancel, mouse button and Return"
        case .styles: return "Styles"
        case .backtrack: return "Fix “actually” corrections"
        case .learnCorrections: return "Learn words from my corrections"
        case .contextNames: return "Names and terms near your cursor"
        }
    }

    /// 2–4 plain sentences.
    public var sentences: [String] {
        switch self {
        case .speechModel: return [
            "English (Parakeet v2) is the standard model: tuned for English and the fastest.",
            "Noisy room / other languages (Parakeet Ultra) is better at ignoring other voices, like a TV or people talking nearby, and can transcribe 25 European languages. Those languages are supported by the model, not yet tested by us.",
            "Ultra occasionally guesses the wrong language on very short phrases. Only the model you pick is loaded. Preparing a speech model for the first time — on first launch, after each macOS update, or the first time you switch to the other model — took 7–12 s in the latest measurement and 18–23 s in the original spike; after that it loads in well under a second.",
        ]
        case .noiseReduction: return [
            "This is Apple's voice processing at the microphone, off by default: it suppresses steady noise like fans and hum and evens out your level, and macOS then shows a Mic Mode control.",
            "It can cut out quiet speech in very loud places — try Test… in the Microphone row first.",
            "Competing voices are a different problem. For a TV or people talking, turn on Noisy room / other languages (Parakeet Ultra) under Speech model.",
            "Speaker focus, which would follow only your voice, is planned but not built yet.",
        ]
        case .micMode: return [
            "Mic Mode is a macOS setting for apps that use voice processing, as WisprLocal does while Noise reduction is on.",
            "Standard lightly reduces noise. Voice Isolation keeps your voice and blocks as much other sound as it can. Wide Spectrum keeps everything around you.",
            "In very loud places, noise reduction can cut out quiet speech. If WisprLocal says your mic audio is cutting out, choose Standard, or turn Noise reduction off.",
        ]
        case .micTest: return [
            "Records three seconds with your current settings and tells you, in plain words, whether the level is good and whether the audio cuts out.",
            "If Noise reduction is on, it records again with it off and shows both side by side.",
            "The test recordings stay in memory and are gone when you close the window.",
        ]
        case .micReady: return [
            "Starting the microphone takes about a fifth of a second, and anything said in that moment is lost, often your first word. While Noise reduction is on, readiness is off and the mic stops after dictation so other audio isn't turned down. With Noise reduction off, the readiness modes below keep the mic ready. Bluetooth mics stay closed while idle so AirPods keep music quality. With Noise reduction off, the mic stays open after dictation for the readiness window (60 seconds by default), keeping AirPods in headset mode with lower music quality. Once it closes, the next dictation is a cold start and may take a little longer while AirPods switch modes. Using the built-in Mac mic avoids this switch.",
            "With Ready for 60 s after dictating selected, the mic keeps running for 60 seconds after each dictation, so the next one keeps its first word in almost every case; a cold start can still clip it. macOS shows the orange mic dot while it's ready, and when the menu shows “Mic Ready · 0:42”, counting down, choose Stop to stop it.",
            "With Always on selected, the mic stays on whenever WisprLocal runs. The orange mic dot stays on the whole time. Keeping the mic running costs about 10 % of one CPU core (mostly macOS's audio service).",
            "Warm audio is held in memory only. When a dictation starts, the last ~0.3 s is prepended and becomes part of that dictation and its recording if recordings are on. Unused warm audio is never saved or sent. It's cleared when the 60 seconds end, and the mic stops at once if you lock the screen, the Mac sleeps, you switch users, macOS secure input is enabled, WisprLocal is holding off for Wispr Flow or you quit. The same rules apply to Always on.",
        ]
        case .aiFormatting: return [
            "Every dictation gets quick rule-based cleanup: filler words like “um” go, spacing is fixed and sentences are capitalised. History shows this as “rules”.",
            "AI formatting adds Apple Intelligence on this Mac for punctuation (up to 1.5 s). Spoken list cues use it even when AI formatting is off. A guard checks every result, and if the model changes your words, your own words are typed instead, so History still says “rules”.",
            "When text is confidently recognised as another language and has at least three words, it is typed as heard, with dictionary replacements. Short or uncertain text gets English cleanup.",
        ]
        case .dictionary: return [
            "Words are spellings to keep exactly as written, like names and product terms. A close-sounding word that isn't an English word is pulled to its spelling when it can only mean that one word.",
            "Replacements fix what the speech model keeps getting wrong: “cooper netties” becomes “Kubernetes”. They're applied to every dictation, in any language.",
            "Everything here stays in a small file on this Mac.",
        ]
        case .snippets: return [
            "Say a trigger phrase on its own and the whole snippet is typed instead.",
            "The trigger has to be the entire dictation, so saying it inside a sentence won't fire it.",
        ]
        case .debugRecordings: return [
            "On by default. Recordings stay on this Mac: only the last 20 are kept; delivered dictations include audio and a small file with what was heard.",
            "They let you replay a dictation in History and compare Heard vs Inserted. When a dictation is blocked by macOS secure input, blocked while WisprLocal is holding off for Wispr Flow, or cancelled, no text or audio is kept; History shows only the time, the outcome and the app. After an app switch or a failed paste, the text is not saved in History or recordings; the text is copied to the clipboard so you can paste it, and kept in memory until you quit for ⌃⌥⌘V. Failed dictations may keep audio if Keep last 20 recordings is on, but never text; fields that do not enable secure input are not detected.",
            "Delete them anytime in Settings › Privacy, or turn this off to stop new ones.",
        ]
        case .shortcut: return [
            "Hold 🌐, speak and let go: best for a sentence or two.",
            "Double-tap 🌐 for hands-free. The recording pill shows a red dot, elapsed time and Done. Click Done or tap 🌐 once to finish; recording stops automatically after 10 minutes.",
            "A single short tap is discarded, and 🌐 pressed with another key (like 🌐 + arrow) is left alone, so your usual shortcuts keep working.",
            "Changed your mind? Press Esc while dictating, or triple-tap 🌐 in hands-free, and nothing is typed.",
        ]
        case .wisprFlowShortcut: return [
            "Turn this on if you've moved Wispr Flow off the 🌐 key.",
            "WisprLocal will then work normally even while Wispr Flow is running.",
        ]
        case .indicator: return [
            "The pill shows that WisprLocal is listening or working. Put it wherever it won't cover the line you're typing on.",
            "It appears on the screen you're working on. While it's showing, hold ⌥ Option and drag it for a custom spot.",
        ]
        case .remoteMacs: return [
            "Beta: built and tested in software, not yet verified end to end on two real Macs.",
            "Install the WisprLocal Receiver on the Mac you control with Screen Sharing and pair it here. Your words travel over your Tailscale network and are pasted there exactly.",
            "Without a receiver, WisprLocal types into the Screen Sharing window character by character, so keep it in front until it finishes.",
        ]
        case .permissions: return [
            "Microphone hears you while 🌐 or the chosen mouse button is held, during double-tap hands-free until Done, a tap or 10 minutes, during the three-second mic test, and while Microphone readiness (Settings › Microphone) keeps it ready or Always on runs. Input Monitoring notices the 🌐 key in any app. Accessibility types the words where your cursor is.",
            "macOS ties each grant to the app's signature. A rebuilt or reinstalled copy can look like a new app, so a switch may show ON but not work; WisprLocal spots this and tells you how to fix it.",
        ]
        case .playback: return [
            "Recordings stay on this Mac (only while ‘Keep last 20 recordings’ is on, the default).",
            "The last 20 are kept; delete them anytime in Settings › Privacy.",
        ]
        case .controls: return [
            "Esc cancels a dictation while it's recording or being processed; nothing is typed, and History notes it was cancelled. Over 30 seconds, WisprLocal asks you to press Esc again so a long take isn't lost by accident. In hands-free, three quick taps of 🌐 cancel too.",
            "A mouse button can work like 🌐: hold it to talk, or double-tap it for hands-free. Only the button you pick is taken over.",
            "Hold Shift as you let go and WisprLocal presses Return once the text is pasted, to send a chat message. It never does this in remote mode or while macOS secure input is enabled. Fields that do not enable secure input are not detected.",
        ]
        case .styles: return [
            "Each kind of app gets a style: Formal for email and documents, Casual for chats and AI tools, Code for editors and terminals.",
            "A style only changes the first capital and the final full stop, never your words, and only for English.",
            "Pick a different style for one app if it doesn't fit its kind. Very casual (lowercase, no full stop) is there if you want it.",
        ]
        case .backtrack: return [
            "When you restate a time, number, day, month or name straight after “actually”, “no”, “sorry”, “I mean”, “make that” or “or rather”, only the second one is typed: “at 2, actually 3” becomes “at 3”.",
            "Anything less clear is typed exactly as you said it. The pill shows “Corrected” with Undo for 8 seconds, or “Corrected · can't undo here” with Copy original when undo is unavailable. History shows what was left out.",
        ]
        case .learnCorrections: return [
            "After a dictation is pasted, WisprLocal watches that same text field for up to 15 seconds. If you retype something it misheard, say “kuber netties” as “Kubernetes”, it asks “Always write “kuber netties” as “Kubernetes”?”. Add puts “Kubernetes” in your Words and adds a Replacement that rewrites “kuber netties” in every future dictation.",
            "It reads only the text around what it typed. Never read: address bars and fields with macOS secure input enabled. The Never read list is editable; password managers and Keychain Access are defaults you can remove. Exclusions also skip banking apps by macOS app category, which does not recognise every banking website. What it sees stays in memory only. Apps that hide their text from macOS (many chat and code apps) can't be watched; use Fix a Word… in History instead.",
            "It never offers to rewrite an ordinary English word, a weekday, a month or a number, so changing “Tuesday” to “Thursday” is not taken for a mishearing. Words and fixes you delete from the dictionary are never suggested or used again unless you add them back yourself.",
        ]
        case .contextNames: return [
            "When a dictation starts, WisprLocal reads up to 2,000 characters on each side of your cursor, the window title, and in Mail or Outlook the To and From names. It picks out names and terms (capitalised words, CamelCase, snake_case, @handles) to spell sound-alikes right: “Sean” becomes “Shaun” if Shaun is in the thread.",
            "Never read: address bars and fields with macOS secure input enabled. The Never read list is editable; password managers and Keychain Access are defaults you can remove. Exclusions also skip banking apps by macOS app category, which does not recognise every banking website.",
            "What it reads stays in memory for that one dictation and is never saved or sent. History only counts how many words it corrected.",
        ]
        }
    }
}

/// The FAQ shown in Help › FAQ and, word for word, in readme.md ("## FAQ").
public enum FAQ {
    public struct Item: Identifiable, Sendable, Equatable {
        public let id: String
        public let question: String
        public let answer: [String]
    }

    /// Caveat that must accompany the TV-speech numbers wherever they appear.
    public static let tvCaveat = "Measured by feeding audio straight to the models, without the app's voice processing; real-world gaps may differ."

    public static let items: [Item] = [
        Item(id: "offline", question: "Does anything leave my Mac?", answer: [
            "Speech recognition, cleanup, learning and history run on this Mac without network access. The only network feature is Remote Macs (Beta): finished text, never audio, is sent to a Mac you pair over your Tailscale network, authenticated with HMAC. Without pairing, WisprLocal types locally into a Screen Sharing window; WisprLocal uses no network for that fallback.",
            "This is checked, not just promised: the tests (socket-dependent and opt-in tests are skipped) also run inside a macOS sandbox that blocks all network access, after first proving the block works. The only network feature is the optional Remote Macs beta, which sends text to your own paired Mac over Tailscale.",
        ]),
        Item(id: "model", question: "Which speech model should I use?", answer: [
            "Start with English (Parakeet v2), the default. On clean speech it matched or beat the alternative in our tests (6.1 % word error rate vs 6.6 %), and it was also better on long dictations and with music playing.",
            "Switch on Noisy room / other languages (Parakeet Ultra) if a TV or other people are often talking while you dictate. With TV speech at −6 dB behind the speaker, Ultra scored 7.6 % against 19.0 % for v2. " + tvCaveat,
            "There are two separate noise tools. Noise reduction (Apple voice processing, in Settings › Microphone, off by default) suppresses steady noise like fans and hum at the mic, but can cut out quiet speech in very loud places; try Check your microphone first. The Noisy room model handles competing voices and other languages. Speaker focus, which would follow only your voice, is planned but not built.",
            "Those tests used synthetic voices on a small set, so treat them as a guide. You can compare both models on your own voice: see How to compare models on your own voice in the test report in the project's GitHub repository.",
        ]),
        Item(id: "language", question: "Why did my English come out in another language?", answer: [
            "That can happen with Noisy room / other languages (Parakeet Ultra). It can transcribe 25 European languages (supported by the model, not yet tested by us), and on a very short phrase it occasionally picks the wrong one.",
            "English (Parakeet v2) only speaks English, so switching back avoids language switching. Text confidently recognised as another language with at least three words is typed as heard; short or uncertain text gets English cleanup.",
        ]),
        Item(id: "cleanup", question: "What does cleanup do, and why does History say “rules”?", answer: [
            "Every dictation gets quick rule-based cleanup: filler words like “um” go, “scratch that” removes everything you said before it in the current dictation, spacing is fixed and sentences are capitalised. That's what “rules” means in History.",
            "AI formatting (off by default) adds Apple Intelligence for punctuation (up to 1.5 s). Spoken list cues use it even when AI formatting is off. A guard checks every AI result; if the model changed your words, your own words are typed and History still says “rules”.",
            "Two final touches are rule-based too. Styles (Settings › Writing, on by default) only change the first capital and the final full stop to suit the app, so a chat gets no full stop and an email gets one. Fix “actually” corrections (off by default) types just the value you restated: “at 2, actually 3” becomes “at 3”, with Undo on the pill for 8 seconds, or “Corrected · can't undo here” with Copy original when undo is unavailable.",
            "When text is confidently recognised as another language and has at least three words, it is typed as heard, with dictionary replacements. Short or uncertain text gets English cleanup.",
        ]),
        Item(id: "permissions", question: "Why the permissions, and why might they reset?", answer: [
            "Microphone, to hear you while 🌐 or a chosen mouse button is held, during hands-free, during the three-second mic test and while the mic is kept ready. Input Monitoring, to notice the 🌐 key from any app. Accessibility, to type the words where your cursor is.",
            "macOS ties each grant to the app's code signature. A copy signed differently, such as an unsigned rebuild, counts as a new app, so System Settings can show WisprLocal as ON while the grant belongs to the old copy. WisprLocal spots this and shows a stale-permission fix.",
        ]),
        Item(id: "jargon", question: "How do I add names or jargon?", answer: [
            "Open Dictionary. Add Words for spellings to keep exactly, and Replacements for what the model keeps mishearing, such as “cooper netties” to “Kubernetes”. Words also pull close-sounding words that aren't English words to their spelling, so “kuber netties” becomes “Kubernetes” when it can only mean that one word; a real word such as “cloud” is never changed to “Claude”.",
            "Or let WisprLocal learn: when you fix something it misheard, it asks “Always write “kuber netties” as “Kubernetes”?”. Add puts the word in Words and adds that Replacement (Settings › Writing › Learn words from my corrections: Suggest, Add automatically or Off). In apps that hide their text, use Fix a Word… on the dictation in History. Words and fixes you delete from the dictionary are never suggested again unless you add them back yourself.",
            "Replacements run on every dictation, in any language, and have negligible cost.",
        ]),
        Item(id: "hardware", question: "What hardware do I need?", answer: [
            "A Mac with Apple Silicon running macOS 26 or later.",
            "All our measurements were made on an Apple M5 Pro. An M1 Pro has not been tested yet; its Neural Engine is slower, so expect dictation to take a little longer there.",
        ]),
        Item(id: "data", question: "Where's my data, and how do I delete it?", answer: [
            "History and your dictionary live in ~/Library/Application Support/WisprLocal, readable only by your user account. Only delivered dictations keep text. When a dictation is blocked by macOS secure input, blocked while WisprLocal is holding off for Wispr Flow, or cancelled, no text or audio is kept; History shows only the time, the outcome and the app. After an app switch or a failed paste, the text is not saved in History or recordings; the text is copied to the clipboard so you can paste it, and kept in memory until you quit for ⌃⌥⌘V. Failed dictations (no speech heard, transcription failed, the app refused the text) keep audio if Keep last 20 recordings is on, but never text. learning.json in the same folder, also readable only by your user account, lists learned words and deleted words and misheard forms. Deleted words are never suggested or used for spelling again unless you add them back yourself. It holds those words only, never dictated text.",
            "To space and capitalise new text, WisprLocal reads up to 64 characters before the cursor and up to 1,000 selected characters. Secure fields and apps excluded by the Never read list or banking/finance app category are skipped; address bars expose only one preceding character for spacing, never selected text. The editable list defaults to password managers and Keychain Access; app categories do not recognise every banking website. To offer Undo after a correction, and check it again when you choose Undo, WisprLocal re-reads the text it typed plus one preceding character, without the Never read list or app-category checks. If a range read fails, some apps only let it read the whole field, from which it keeps just the characters needed for spacing or Undo. These reads stay in memory only and are never saved. Names and terms near your cursor (off by default) reads the text near your cursor, the window title and, in Mail or Outlook, the To and From names, when each dictation starts. It uses the same app exclusions and never reads address bars or fields with macOS secure input enabled. The names it finds stay in memory for that one dictation and are never saved; History only counts how many words they corrected.",
            "Delete single entries or Clear All in History; that also deletes their recordings. To keep less, set Settings › Privacy › Keep history to 30 days, 7 days or 24 hours: older dictations and their recordings are then deleted at launch and every hour. Recordings are on by default: the last 20 dictations are kept as audio in the DebugRecordings folder there, so you can replay them and compare Heard vs Inserted in History. That includes failed dictations where nothing came out, so you can hear why. When a dictation is blocked by macOS secure input, blocked while WisprLocal is holding off for Wispr Flow, or cancelled, no text or audio is kept; History shows only the time, the outcome and the app. After an app switch or a failed paste, the text is not saved in History or recordings; the text is copied to the clipboard so you can paste it, and kept in memory until you quit for ⌃⌥⌘V. Failed dictations (no speech heard, transcription failed, the app refused the text) keep audio if Keep last 20 recordings is on, but never text. They never leave your Mac. Turn them off in Settings › Privacy › Keep last 20 recordings, or delete them all at once there.",
        ]),
        Item(id: "loud", question: "Why does dictation cut out or miss words in loud places?", answer: [
            "In very loud places (planes, trains), a headset mic close to your mouth works far better than the built-in mic. The laptop mic hears everyone nearby, and WisprLocal can type what the people next to you say; speaker focus, which would follow only your voice, is planned but not built.",
            "Noise reduction (Apple voice processing) can cut out quiet speech in very loud places. On a plane, 15 of 20 dictations with it on had speech silenced (typically 10 %, in gaps of up to half a second), so it is now off by default. If you turned it on and WisprLocal says your mic audio is cutting out, turn it off in Settings › Microphone, or set Mic Mode to Standard (Voice Isolation blocks even more).",
            "When the mic heard you but no words came out, WisprLocal says “Didn't catch that”. See why shows the numbers and lets you replay the recording. Check your microphone, in Settings › Microphone, tests your mic with your current settings; only when noise reduction is on does it repeat with it off and show both side by side.",
        ]),
        Item(id: "micdot", question: "Why is the orange mic dot on after I dictate?", answer: [
            "Starting the microphone takes about a fifth of a second, and macOS mutes that moment, so a quick follow-up dictation used to lose its first word. With Noise reduction off (the default), WisprLocal keeps the mic ready for 60 seconds after each dictation, and macOS shows the orange dot while it does. When the menu shows “Mic Ready · 0:42”, counting down, choose Stop to stop the mic now.",
            "Warm audio is held in memory only. When a dictation starts, the last ~0.3 s is prepended and becomes part of that dictation and its recording if recordings are on. Unused warm audio is never saved or sent. It's cleared when the 60 seconds end, and at once on screen lock, sleep, a user switch, secure input, WisprLocal holding off for Wispr Flow, or quit.",
            "Choose Off in Settings › Microphone › Microphone readiness. Or choose Always on there to keep the first word in almost every case; a cold start can still clip it, at the cost of the dot staying on. Noise reduction runs Apple voice processing only while recording and turns readiness off, including Always on; the readiness menu is disabled while Noise reduction is on.",
            "Bluetooth mics stay closed while idle so AirPods keep music quality. With Noise reduction off, the mic stays open after dictation for the readiness window (60 seconds by default), keeping AirPods in headset mode with lower music quality. Once it closes, the next dictation is a cold start and may take a little longer while AirPods switch modes. Using the built-in Mac mic avoids this switch.",
        ]),
        Item(id: "credits", question: "Who made the models?", answer: [
            "English (Parakeet v2) is NVIDIA's parakeet-tdt-0.6b-v2. Noisy room / other languages is Moondream's Parakeet Ultra, built on NVIDIA's parakeet-tdt-0.6b-v3. Silero VAD is by the Silero Team. FluidInference converted all three to Core ML; their FluidAudio library runs our speech recognition and speech detection.",
            "Both Parakeet models are CC-BY-4.0, Silero VAD is MIT, and FluidAudio is Apache-2.0. WisprLocal bundles the model files unmodified at pinned revisions. Full credits, sources, licences and conversion notes are in ACKNOWLEDGEMENTS.md and in the app under Help › Credits.",
        ]),
    ]
}
