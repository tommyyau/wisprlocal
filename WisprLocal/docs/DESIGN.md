# WisprLocal design system

The single source of truth in code is `App/Sources/WisprLocal/Theme.swift`. This document matches it 1:1. If you change one, change the other in the same commit. The HUD's motion constants live in `HUD.swift` (`HUDAnimator`, `HUDBars`) and are listed here so the product reads as one system.

## Principles

1. **Calm.** The app gets out of the way. There is one accent colour, generous space, and nothing blinks unless it means something. Decoration (the wave) is slow and quiet.
2. **Private.** Speech recognition, cleanup, learning and history run on this Mac without network access. The only network feature is Remote Macs (Beta), which sends finished text, never audio, to a Mac you pair over Tailscale, authenticated with HMAC. Without pairing, WisprLocal types locally into a Screen Sharing window with no network use by WisprLocal.
3. **Instant.** Feedback is immediate: live ticks, switches that act at once, no Save buttons. Motion is fast to start and settles softly.

## Colour tokens

Brand colours are fixed. Semantic colours adapt between light and dark.

| Token | Light | Dark | Use |
|---|---|---|---|
| `indigoDeep` | #120D2E | same | deepest brand shade |
| `indigo` | #1B1440 | same | HUD glass tint (35 %) |
| `violet` | #3A2D7A | same | brand mid-tone |
| `violetGlow` | #6B5BD6 | same | glows on indigo |
| `mint` | #7CF5D4 | same | voice bars, accent on dark |
| `mintDeep` | #5BE3C0 | same | bottom of the mint gradient |
| `accent` | #0E9F80 | #7CF5D4 | links, icons, selection (mint is too light for text on white) |
| `accentSoft` | #0E9F80 at 12 % | #7CF5D4 at 14 % | icon wells, chips, selected tiles |
| `positive` | #1F9D55 | #4ADE80 | green ticks |
| `warning` | #C2410C | #FDBA74 | needs-attention states |
| `danger` | #C62828 | #FF8A80 | errors, destructive |
| `onDarkWarning` | #FDBA74 | same | warning tint on always-dark surfaces (hero, HUD) |
| `onDarkDanger` | #FF6B66 | same | error tint and hands-free dot on the HUD |
| `onMint` | #0D2B25 | same | text on the mint brand button |
| `windowBackground` | #F6F5FA | #16141F | page background |
| `card` | #FFFFFF | #211E2E | cards |
| `cardBorder` | black 7 % | white 8 % | card hairline |
| `inset` | #F1F0F6 | #2A2639 | fields and wells inside cards |
| `separator` | black 8 % | white 7 % | row dividers |
| `sidebarSimulated` | #ECEBF3 | #1D1A28 | preview harness only |
| `previewBackdropHUD` | #2B3245 → #3B2D44 | same | preview harness only (HUD positioning shot) |
| `previewBackdropLight` / `previewBackdropDark` | #DBE6F7 → #F7E6D6 | #1A1F2E → #38243D | preview harness only (HUD preview backdrop) |

Gradients:
- `heroGradient`: #241A5C → #1B1440 (55 %) → #0F2A3A, top-leading to bottom-trailing. Use it for hero areas only: the Home hero, the onboarding welcome, the Snippets empty state and the Insights footer.
- `mintGradient`: `mint` → `mintDeep`, top to bottom. Use it for bars, primary buttons and switches.
- `orbStops`: #2B2470 → #17123F → #0F3346, the drawn orb's glass from centre to rim.
- `keyCapLight` (#FFFFFF → #ECEBF2) and `keyCapDark` (#3B3750 → #2A2739): the `KeyCap` face, top to bottom.

## Type scale

SF Pro, with SF Pro Rounded for display text and numbers.

| Token | Spec | Use |
|---|---|---|
| `display` | 28 pt bold, rounded | page titles, the Home hero headline |
| `heroDisplay` | 32 pt bold, rounded | onboarding welcome headline |
| `heroHeadline` | 30 pt semibold, serif | editorial hero headline (Snippets empty state) |
| `title` | 20 pt semibold, rounded | card and section titles |
| `wordmark` | 15 pt semibold, rounded | the sidebar wordmark |
| `lead` | 14 pt | hero subtitles, practice text fields |
| `section` | 13 pt semibold | day headers, brand button label |
| `body` | 13 pt | body text, dictation text, sidebar items |
| `bodyEmphasis` | 13 pt medium | row titles |
| `chip` | 12 pt medium | the segmented tab bar, small pill labels, inline links |
| `caption` | 11.5 pt | "why" lines, metadata |
| `groupHeader` | 11 pt semibold, shown uppercased with +0.6–0.8 kerning | eyebrow above a card or tile |
| `eyebrow` | 10.5 pt semibold, small caps, +0.8–1 kerning | labels such as STEP 1 OF 3, table column heads |
| `footnote` | 10.5 pt medium | tags, footnotes, month labels |
| `heroNumber` | 40 pt semibold, rounded, monospaced digits | headline numerals: total words, speaking speed, current streak |
| `bigNumber` | 34 pt semibold, rounded, monospaced digits | Home stat numerals |
| `statValue` | 24 pt semibold, rounded, monospaced digits | secondary numerals inside tiles |
| `numberUnit` | 14 pt medium, rounded | unit beside a numeral ("days", "wpm") |
| `figure` | 13 pt semibold, rounded | inline numeric values in rows |
| `figureCaption` | 11.5 pt, rounded | small numeric captions and deltas |
| `statLabel` | 11.5 pt medium | stat labels |
| `axis` | 9.5 pt medium, rounded | chart axis labels |
| `badge` | 9.5 pt bold | tiny badges ("BETA", "NEW") |
| `keyCap` | 15 pt medium, rounded | key-cap legends |
| `keyCapLegend(size)` / `keyCapGlyph(size, labelled:)` | 0.22 × key, medium, rounded / 0.34 (0.42 unlabelled) × key | the legend and glyph on a `KeyCap`, proportional to its size |
| `iconLarge` | 26 pt | empty-state glyphs |
| `icon` | 18 pt | standalone status and feature icons |
| `symbolLarge` | 13 pt semibold | card-header and notice symbols |
| `symbol` | 11 pt medium | SF Symbols inline with text or inside a field |
| `chevron` | 9 pt semibold | up-down chevrons in pick-one fields |
| `micro` | 9 pt bold | tiny glyphs: inline arrows, × marks, play/stop, ticks |
| `mono` | 10.5 pt, monospaced | paths, keys, licence text |
| `hudText` | 13 pt medium (`hudTextSize`) | HUD notice text; `HUDNoticeMetrics` measures it with the same size |
| `hudButton` | 12 pt semibold (`hudButtonSize`) | HUD notice buttons and positioning glyph |

A `.weight(...)` modifier on a token is fine for one-off emphasis. Literal `.system(size:)` fonts are not allowed outside `Theme.swift` (`DesignTokenLintTests`).

## Spacing and radius

- Spacing (`Theme.Space`): hair 2, xxs 4, tight 6, xs 8, snug 10, s 12, ms 14, m 16, ml 20, l 24, xl 32, xxl 48. Paddings use these, never literals.
- Radius (`Theme.Radius`): tiny 4, well 6, small 8, tile 10, card 14, hero 20. Always use continuous corners.
- Content max width is 760 pt, centred, with 32 pt side padding.

## Materials

- **Window:** a solid `windowBackground`. The main window sidebar uses the system sidebar (Liquid Glass on macOS 26).
- **Cards:** solid `card` with a `cardBorder` hairline and a whisper of shadow (black 4 %, radius 6, y 2). Content sits on solid surfaces so it stays legible in both appearances.
- **HUD pill:** `.ultraThinMaterial`, then black 38 %, then `indigo` 35 %. On top: a white 8 % top sheen, a white 10 % 0.5 pt border, and a white 32 % → 0 % top highlight. Two shadows: black 30 % r12 y5 and black 18 % r2 y1.

## Motif: the orb and the wave

- **Orb:** a glass sphere. A radial gradient runs #2B2470 → #17123F → #0F3346, with a mint 35 % underglow at the bottom, a white sheen ellipse rotated −18°, and a white → mint rim. Inside are 7 mint bars. It appears in the sidebar (28 pt), the Home hero (132 pt), onboarding (124 / 96 pt) and wherever a brand moment is needed.
- **Wave (`WaveMotif`):** mint capsule bars. Height is a centre bell × (travelling sine + breathing sine). Opacity is 0.55 + 0.45 × level, plus a mint glow. As decoration it runs at 18–22 % opacity, fades out at both edges (`edgeFade`) and updates at 30 fps.
- **Reduce Motion:** the wave freezes on a still frame (t = 1.3) and the orb holds still. The HUD skips the dot-to-pill spring and fades instead.

### HUD motion (from `HUDAnimator`)

| Element | Spec |
|---|---|
| Enter | An 8 pt dot springs out to the pill. Bars stagger in 60 ms later |
| Pill spring | response 0.38 s, damping fraction 0.72 (k = (2π/0.38)², c = 2·0.72·(2π/0.38)): a small visible overshoot |
| Bar spring | stiffness 300, damping 18: fast attack, about 15 % overshoot |
| Exit | 220 ms total. Bars collapse to nubs over 0–100 ms, the pill contracts over 20–190 ms (ease in-out), and opacity fades over 110–220 ms |
| Pill size | 132 × 40 pt recording and processing, 300 × 48 hands-free, notices up to 600 pt wide |
| Bars | 4.5 pt wide, 5 pt gap, 6–30 pt tall (75 % of the pill), mint gradient, glow above level 0.35; FFT levels use noise-gated automatic display gain (0–18 dB) before the −50 to −10 dB mapping |
| Notice timing | chips without a button 3 s, chips with a button 8 s, no exceptions (`HUDChipPolicy`; see HUD chips) |
| Placement | presets with a 24 pt margin inside `visibleFrame`, bottom positions at least 110 pt above the screen bottom, snapping within 10 pt (`HUDPlacement`) |

Waveform display gain resets per dictation, including warm-mic starts. It targets a −28 dB tilted FFT peak, adds at most +18 dB, never boosts frames already at or above the −28 dB target, never attenuates, and retains the −50 to −10 dB display window. **No floor → no gain:** display gain is exactly 0 until the current floor window contains at least 200 ms of eligible frames. After reset or a callback whose RMS is below −90 dBFS (including exact zeros and stray ±1 int16 LSB blips), floor eligibility waits at least 150 ms from the first non-silent 1 ms region. Continuous 1 ms RMS regions are measured across callback boundaries from every incoming sample, including samples beyond the retained FFT window; a region below −90 dBFS restarts that timer. The entire 512-sample FFT window must follow the last silent region, so zero padding and blip-only regions cannot seed the floor. Timers use sample counts divided by the actual sample rate. The gain tracker steps through each delivered buffer in 320-sample (20 ms) sub-blocks, so 100 ms buffers behave like 20 ms ones; the bars are still drawn from the last 512-sample FFT window. The first eligible frame contributes only the portion of its hop after eligibility, and later eligible frames contribute their hop duration; the 200 ms total is clipped to the current 1.5 s window.

The noise floor is the minimum eligible finite per-frame band-peak loudness over the last 1.5 seconds, clamped to at least −78 dB; a step increase in steady noise can therefore show for up to 1.5 seconds. Silence does not lower the estimate, and existing valid frames age out in real time. Non-finite frames output zero and leave the FFT history and trackers unchanged. Speech must remain 10 dB above the estimated floor for both at least 60 ms and at least three consecutive frames to qualify; this margin keeps slowly swelling fan and traffic noise dark, trading some speech lift in louder rooms for stable pauses. The first 250 ms of qualified speech uses the original mapping. Initial peak adoption and upward attack use the minimum loudness across the most recent qualifying window meeting both limits. Single clicks do not raise the tracked peak, including during speech, although their own bars can saturate at 1. Sustained loud sounds lower gain within about 100 ms at normal tap hops; a 100 ms hop needs three frames (300 ms). Peak release is 3 dB/s during qualified speech. After initial floor establishment, peak adaptation can continue using remaining eligible history if the valid duration falls below 200 ms, but displayed gain stays exactly 0 until the current floor is established again. Gain applies only to qualified speech, keeping pauses ungained.

Floor eligibility and speech persistence share a fixed ring allocated at initialization with `ceil(1.5 × sampleRate / 64)` entries: exactly 375 entries at 16 kHz, supporting a smallest hop of 64 samples (4 ms) for the full 1.5 s window. Smaller hops safely shorten the retained window proportionally (for example, hop 32 retains 0.75 s at 16 kHz); indexing always wraps within the allocated capacity, with no per-buffer allocation. Ineligible frames retain speech-persistence timing but contribute nothing to the floor. The capture-start reset is handed to the audio thread and also clears the display FFT and startup history; it never changes recorded audio or voice processing.

UI springs elsewhere: page and step transitions use response 0.38 and damping 0.86. Switches use response 0.25 and damping 0.8. Small toggles use `.snappy`.

## Iconography

- SF Symbols only, at regular or medium weight, 11–13 pt inside a 22–30 pt `accentSoft` rounded well (radius 6–8).
- The 🌐 key is always drawn as a **key cap**, never as the words "global key" or "fn key". Inline in a sentence it uses `InlineKey`; standalone it uses `KeyCap`.
- App icons in History come from the real app (`NSWorkspace`). The menu bar uses a template image.

## Voice and tone

Short, warm, plain English. Write in the second person. Say what happens and why it matters. Be confident without selling.

| Do | Don't |
|---|---|
| "Hold 🌐, speak, let go." | "Utilise the push-to-talk modality." |
| "Needs Accessibility & Input Monitoring" plus **Fix…** | "Global key not set" |
| "Recognition, cleanup, learning and history stay on this Mac; Remote Macs sends text to a Mac you pair." | "Military-grade privacy!" |
| "Adds a moment after you let go." | "May incur latency." |
| "Only delivered dictations keep text in History." | "An error occurred." |
| Name other apps neutrally, only when needed ("Wispr Flow is running and also uses 🌐") | Compare or disparage |

Every setting has a one-line *why*. Every problem offers the action that fixes it.

Capitalisation and punctuation, one rule per surface:
- **Settings**: row titles in sentence case, buttons in Title Case. Section titles, row titles, *why* lines and footers are sentence case ("Check your microphone"). Every button in Settings and its sheets follows macOS and is Title Case, with small words (a, and, for, to…) lower case: "Open Keyboard Settings", "Adjust Position…", "`<mode>` · Change…", "Test…", "Choose App…", "Reset to Defaults" (`SettingsStructureTests` checks every literal button title).
- **Menus** (menu bar, the pill's right-click menu, row menus) are Title Case. The pill's right-click menu offers "Hide Indicator for 1 Hour"; the menu bar offers "Indicator Hidden — Show" while the indicator is hidden. An attention row is "Title — Action" ("Indicator Hidden — Show", "Speech Model Unavailable — Retry"); live data inside a title uses " · " ("Mic Ready · 0:42 — Stop").
- **HUD chips**: the text is sentence case and short; buttons are one or two words in sentence case from `HUDChipAction` ("Add", "Undo", "Not now", "See why"). When docs name a chip they write its text and its button: “Corrected” with **Undo**.
- **Ellipsis** only when a window, sheet or panel opens ("Fix a Word…", "Test…", "Adjust Position…", "Add App…"). A button that acts at once has none ("Open Keyboard Settings"); the pill’s right-click menu uses "Hide Indicator for 1 Hour".
- Pointing at a setting: write "Settings", the › separator, then the section's exact title, e.g. "Settings › Microphone" (`SettingsSection`; `SettingsStructureTests` fails on a stale one).

Defaults favour never losing words over polish: Noise reduction is OFF by default (2026-10-03, TEST_REPORT §3.11 — on a plane it silenced speech in 15 of 20 dictations), and its *why* carries the caveat "Can cut out quiet speech in very loud places — try Check your microphone first." ("Off by default" lives in its ⓘ, not the always-visible *why*.)

## Components

- **Card** (`.card()`): 16 pt padding, `card` fill, 14 pt radius, `cardBorder` hairline, soft shadow.
- **Insight tile** (`InsightTile`, Insights): a card with 20 pt padding. A 22 pt `accentSoft` icon well and a small-caps eyebrow label, an optional trailing chip, then content. Large numbers use `BigNumber` (24–44 pt semibold rounded, monospaced digits). Meters are thin `Bar` capsules (`accent` 85 % on `inset`).
- **Speed gauge** (`SpeedGauge`): a 180° arc, 0–220 wpm, 14 pt round-capped stroke on an `inset` track, the value arc mint → `accent`. One tick marks typing at 40 wpm; the caption says "≈ N× faster than typing". No percentile or ranking: WisprLocal has no population data and never invents any.
- **Streak heatmap** (`Heatmap`): 26 Sunday-first weeks as columns, Sun–Sat rows, 19 pt cells with 4 pt gaps and month labels on top. Five levels: `inset`, then `accent` at 22 / 42 / 68 / 100 % (quartiles of active days). The current streak gets one unioned `accent` outline; today a faint primary ring.
- **Home stats panel** (`HomeStatsPanel`): a 200 pt card beside Recent with total words, average wpm and current streak at 34 pt rounded, eyebrow labels, hairline dividers, and **See insights →**.
- **Dictation row** (`DictationRow`, Home and History): a 64 pt time column (12 pt rounded, tertiary), the text, then app icon, name and duration. Actions (▷ when a clip exists, copy, •••) float in a small `card` capsule at the top-right on hover. Refused or failed attempts show as a muted outcome line with a symbol and no text (SEC-2).
- **Snippets hero** (`SnippetsHero`): `heroGradient` with a violet orb glow, a 64 pt orb, a faint wave, a 30 pt serif headline, example chips (white 7 % capsules) and the primary brand button. It is the empty state; with snippets the page shows search, sort and the editors.
- **Key cap** (`KeyCap`): a square with radius 0.2 × size. A light gradient (white → #ECEBF2) or a dark one (#3B3750 → #2A2739), a 0.75 pt border, and a bottom "depth" shadow offset 0.05 × size. "fn" sits top-left, the globe bottom-right.
- **Permission row** (`PermissionRow`): a 28 pt status circle showing a tick (`positive`) or the permission's symbol (`warning`). Then the title and a plain reason, with "Allowed" on the trailing edge, or **Allow…** (brand button) plus Open Settings.
- **Setting row** (`SettingRow`): title (`bodyEmphasis`) and why (`caption`, secondary) on the left, control on the right, 12 pt vertical padding, an inset divider.
- **Brand button** (`BrandButtonStyle`): a 30 pt capsule. The primary is `mintGradient` with #0D2B25 text; the secondary is an `inset` fill with a border.
- **Brand switch** (`BrandSwitchStyle`): 38 × 22 (small: 30 × 18), with a mint track when on.
- **Play control** (`PlayControl`, History): a 26 pt slot. With a clip: a mint play glyph in an `accentSoft` circle; while playing, a stop glyph inside a 2 pt `accent` progress ring. Without a clip: a subtle `waveform` symbol in tertiary, disabled, with a tooltip that says how to get recordings.
- **Suggestion chip** (HUD, smart dictionary): the standard chip ("Always write “kuber netties” as “Kubernetes”?" with **Add** primary and **Not now** secondary; Add saves the Word AND the Replacement, which the chip says), `character.book.closed` symbol, info tint, 8 s. "Added “X” to your dictionary" (automatic mode) is a plain 3 s chip. The word is forgotten when the chip ends.
- **Word picker** (History › Fix a Word…): the dictation's words as 26 pt capsules in a `FlowLayout`; unpicked `inset` with a `cardBorder` hairline, picked `accentSoft` with an `accent` 18 % hairline (the Dictionary chip look). One click picks a word, a second nearby click extends it to a phrase of up to three.
- **Pill** (HUD): see Materials and HUD motion. In positioning mode a dark caption capsule with **Done** floats 54 pt above or below the pill. The pill is click-through except while the pointer is over the pill itself, so a right-click opens its menu (**Hide Indicator for 1 Hour**). Transient follow-ups (“Cancelled”, “Press Esc again to discard 42 s”, “Indicator hidden for 1 hour” with **Undo**) are ordinary HUD chips.
- **Choice menu** (`ChoiceMenu`, Settings): the ONLY pick-one field in Settings (mouse button, Keep history, styles, learning mode); a field for a `SettingRow`, styled exactly like the microphone picker: a 28 pt `inset` well with a `cardBorder` hairline, `Radius.small` corners, an optional 11 pt `accent` symbol, the current value in `body`, and an up-down chevron. The menu marks the current option with a checkmark.

## Dictation pipeline order

One fixed order, in `DictationPipeline.process` (header comment) and pinned by `PipelineOrderTests`:

1. **VAD** trim → 2. **ASR** (timeout, one retry) → 3. **language gate** (confidently non-English text skips 5–9; the user's replacements still apply).
4. **Dictionary replacements** → 5. **phonetic spelling snap** to dictionary terms, then the opt-in **context-name snap** (one `SpellingSnapper` pass, English only).
6. **Snippets** (whole utterance; a hit skips 7–9).
7. **Cleanup**: RuleCleaner + spoken numbers (default) *or* AI formatting (user setting, or auto on list cues). The dictionary is re-applied after the model.
8. **Backtrack** (opt-in) on the cleaned text → 9. **per-app style** (first capital, final full stop only).
10. **Gates** (Wispr Flow, secure input, focus) → 11. **smart join** → 12. **insert** → 13. **auto-send** (Shift at release) → 14. **learning watcher** and the **Corrected · Undo** offer.

Why replacements and snapping come before the RuleCleaner (not after): the rules format numbers *next to dictionary terms* ("GPT five" → "GPT 5") and the AI formatter's guard checks dictionary spellings, so both must see the corrected words. Why backtrack comes after cleanup: it matches restated values ("2, actually 3") in their final, digit-formatted form.

Interactions:
- **Esc / triple-tap cancel** is checked after 1, after 2, after 7 and right before 11: cancelling before insertion prevents insertion, auto-send, Undo and the watcher. Cancellation after a paste cannot remove text already typed. Context names read at recording start are dropped with it.
- **Undo** (backtrack) stops the learning watcher *before* posting ⌘Z, so putting the words back is never learned as a user correction.
- **Auto-send** after a backtrack withdraws the Undo offer and the watcher: the message has been sent, so ⌘Z would hit something else.

## HUD chips

Every transient message on the pill is a **chip**: one component (`HUDNotice` in `HUD.swift`), one placement (the pill), one rule set in code (`HUDChipPolicy` / `HUDChipQueue` in WisprLocalCore, pinned by `HUDChipTests`).

- **One at a time.** Priority, highest first: **alert** (something happened to your words or the mic: "Didn't catch that", focus changed, password field, paste not confirmed, model or transcription failures, the mic-cutting-out tip; amber tint) > **undo** (“Corrected” with **Undo**) > **suggestion** ("Always write “Y” as “X”?") > **info** (Cancelled, Press Esc again, Recording stops in N s, Indicator hidden). Persistent banners (Wispr Flow holding off, model failed, permissions) sit above all chips.
- **Timing**: 8 s with a button, 3 s without. No per-chip exceptions; Undo stays valid for 20 s so a chip that waited still works.
- **Collisions**: same or higher priority replaces the chip showing (same priority: the newest wins; a repeat of the same text just extends it). A lower chip waits; only the highest waiting chip is kept. An interrupted chip comes back with the time it had left (dropped if under 1.5 s); a chip that waited 10 s is stale and dropped.
- **A new recording clears every chip**, so the pill always shows that the mic is on (and the Undo offer ends).
- **Buttons**: one or two words, sentence case, from one list (`HUDChipAction`): See why, Settings, Undo, Add, Not now. Primary buttons are mint; **Not now** is the only secondary.

## Settings structure

`SettingsSection` drives five pinned tabs in this exact order: **General**, **Microphone**, **Writing**, **Privacy**, **Remote Macs**. Selection is remembered. General holds the Globe key action, mouse button, sounds, Shift-to-send and six pill positions. Microphone holds input and Test…, Noise reduction (with conditional Mic Mode), Microphone readiness and Speech model. Writing holds formatting, corrections, styles and dictionary learning. Privacy holds the on-device promise, retention, recordings, folder and greeting. Remote Macs has separate receiver, pairing and fallback cards.

The **Ready** chip beside the Settings title opens permission ticks, Globe status and the permissions and shortcut explanations. Actionable setup issues show attention; model preparation shows a spinner. A setup banner appears only while issues exist, above the tabs. It is capped at 40 % of the viewport and scrolls internally to leave room for tab content.

**Customise styles**, **Apps never read** and **Advanced: remote viewer apps** use the same disclosure row: semibold title and caption aligned with setting titles, a trailing chevron, consistently indented content and a divider. Single-card tabs omit redundant group headers; Remote retains card titles. Pick-one settings use `ChoiceMenu`, switches use `BrandSwitchStyle`, and rows use `SettingRow` with a short caption. Deep links select a tab or reveal setup; hiding the indicator lives in the pill's right-click menu.
