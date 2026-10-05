import AppKit
import AVFoundation
import CoreAudio
import SwiftUI
import WisprLocalCore

struct SettingsView: View {
    @Bindable var model: AppModel
    var stylesExpanded = false
    var styleStore: StyleSettingsStore? = nil
    var rows: (([String]) -> Void)? = nil
    var measure: ((CGFloat, CGFloat) -> Void)? = nil

    var body: some View {
        Page(title: "Settings", subtitle: "Changes apply straight away.", trailing: AnyView(ReadyChip(model: model)),
             content: { tabContent }, pinnedHeader: AnyView(header), measure: measure)
        .onPreferenceChange(SettingsRowTitles.self) { rows?($0.filter { $0 != "Apple Intelligence" }) }
        .onAppear { followRequest() }
        .onChange(of: model.settingsRequest) { _, _ in followRequest() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if !model.setupIssues.isEmpty { SetupBanner(model: model) }
            Picker("Settings tab", selection: $model.settingsTab) {
                ForEach(SettingsSection.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
        }
    }

    @ViewBuilder var tabContent: some View {
        switch model.settingsTab {
        case .general: GeneralSettings(model: model)
        case .microphone: MicrophoneSettings(model: model)
        case .writing: WritingSettingsSection(model: model, store: styleStore ?? model.live?.styles ?? WritingSettingsSection.previewStore, expanded: stylesExpanded)
        case .privacy: PrivacySettings(model: model)
        case .remote: RemoteSection(preview: model.live == nil, expanded: stylesExpanded)
        }
    }

    private func followRequest() {
        if case .tab(let tab) = model.settingsRequest { model.settingsTab = tab }
        // Setup is already visible above every tab.
        model.settingsRequest = nil
    }
}

struct ReadyChip: View {
    let model: AppModel
    private var attention: Bool { model.setupIssues.contains(where: { $0.hasAction }) }
    private var preparing: Bool { !attention && !model.setupIssues.isEmpty }
    @State private var open = false
    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: Theme.Space.xs) {
                if preparing { ProgressView().controlSize(.small) }
                else { Image(systemName: attention ? "exclamationmark.circle" : "checkmark") }
                Text(attention ? "Needs attention" : preparing ? "Preparing…" : "Ready")
            }.font(Theme.Typo.chip).foregroundStyle(attention ? Theme.warning : preparing ? Color.secondary : Theme.positive)
                .padding(Theme.Space.xs).background(Capsule().fill(Theme.card))
        }
        .buttonStyle(.plain).help("Permissions and 🌐 key status")
        .popover(isPresented: $open) { ReadyPopoverContent(model: model) }
    }
}

struct ReadyPopoverContent: View {
    let model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack { Text("Permissions").font(Theme.Typo.bodyEmphasis); InfoButton(topic: .permissions) }
            ForEach(Permission.allCases, id: \.self) { p in
                StatusLabel(ok: model.isGranted(p), text: p.title)
            }
            HStack {
                StatusLabel(ok: model.hotkeyActive, text: model.hotkeyActive ? "🌐 key active" : "🌐 key not active")
                InfoButton(topic: .shortcut)
            }
            Text("Lost-key detection: " + LostKeyCopy.line(model.live?.hotkey.pollStatus ?? .armed))
                .font(Theme.Typo.caption).foregroundStyle(.secondary)
        }.padding(Theme.Space.m).frame(width: 320, alignment: .leading)
    }
}

struct SetupBanner: View {
    let model: AppModel
    @Environment(\.settingsViewportHeight) private var viewportHeight
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            ForEach(model.setupIssues) { issue in
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    HStack(spacing: Theme.Space.xs) {
                        if issue == .modelPreparing { ProgressView().controlSize(.small) }
                        else { Image(systemName: "exclamationmark.circle").foregroundStyle(Theme.warning) }
                        Text(issue.text).font(Theme.Typo.caption)
                        Spacer(minLength: 0)
                        actions(issue)
                    }
                    if issue == .stalePermission {
                        DisclosureGroup("How to renew permissions") {
                            ForEach(model.health.instructions, id: \.self) { Text($0).font(Theme.Typo.caption) }
                        }.font(Theme.Typo.caption)
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .modifier(SetupBannerScroll(maxHeight: viewportHeight * 0.4))
        .card(padding: Theme.Space.s)
    }
    @ViewBuilder private func actions(_ issue: SetupIssue) -> some View {
        switch issue {
        case .permission(let p):
            Button("Allow…") { model.request(p) }.buttonStyle(BrandButtonStyle()).controlSize(.small)
            Button("Open Settings") { model.openSettings(p) }
        case .needsRelaunch, .stalePermission: Button("Relaunch") { model.relaunch() }
        case .globeInactive: Button("Fix…") { model.refreshSystemState() }
        case .globeAction: Button("Open Keyboard Settings") { model.openKeyboardSettings() }
        case .wisprFlow:
            Button("Quit Wispr Flow") { model.quitWisprFlow() }
            Button(WisprFlowCopy.useAnywayMenuTitle) { model.useWisprLocalAnyway() }
            Button(WisprFlowCopy.differentShortcutButton) { model.setWisprFlowUsesDifferentShortcut(true) }
        case .modelFailed: Button("Retry") { model.retryModel() }
        case .modelPreparing: EmptyView()
        }
    }
}

struct GeneralSettings: View {
    let model: AppModel
    private var flowInstalled: Bool {
        model.live == nil ? false : NSWorkspace.shared.urlForApplication(withBundleIdentifier: WisprFlowMatcher.bundleID) != nil
    }
    var body: some View {
        SettingsGroup(section: .general) {
            SettingRow(title: "Keep macOS from also reacting to 🌐", why: "Stops the emoji picker or input switching popping up while you dictate.") {
                Toggle("", isOn: Binding(get: { model.settings.consumeGlobeKey }, set: { model.setConsumeGlobe($0) }))
                    .toggleStyle(BrandSwitchStyle()).labelsHidden()
            }
            if flowInstalled {
                SettingRow(title: WisprFlowCopy.differentShortcut,
                           why: "Off: while Wispr Flow is running, WisprLocal holds off and leaves 🌐 to it.", info: .wisprFlowShortcut) {
                    Toggle("", isOn: Binding(get: { model.settings.wisprFlowUsesDifferentShortcut }, set: { model.setWisprFlowUsesDifferentShortcut($0) }))
                        .toggleStyle(BrandSwitchStyle()).labelsHidden()
                }
            }
            ControlsRows(model: model)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack {
                    Text("Recording pill position").font(Theme.Typo.bodyEmphasis)
                    InfoButton(topic: .indicator)
                    Spacer()
                    Button("Adjust Position…") { model.adjustHUDPosition() }.controlSize(.small)
                }
                Text("While the pill is showing, hold ⌥ Option and drag it.").font(Theme.Typo.caption).foregroundStyle(.secondary)
                HStack(spacing: Theme.Space.xs) {
                    ForEach([HUDPreset.topLeft, .topCenter, .topRight, .bottomLeft, .bottomCenter, .bottomRight]) { p in
                        PresetTile(preset: p, selected: !model.hudHasCustom && p == model.hudPreset) { model.setHUDPreset(p) }
                    }
                }
                if model.hudHasCustom { StatusLabel(ok: true, text: "Custom position on this display") }
            }.padding(Theme.Space.m)
                .preference(key: SettingsRowTitles.self, value: ["Recording pill position"])
        }
    }
}

struct PresetTile: View {
    let preset: HUDPreset
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.Radius.well, style: .continuous).fill(Theme.inset)
                    // menu bar
                    VStack { Rectangle().fill(Theme.separator).frame(height: 4); Spacer() }
                    Capsule().fill(selected ? AnyShapeStyle(Theme.mintGradient) : AnyShapeStyle(Color.secondary.opacity(0.45)))
                        .frame(width: 22, height: 7)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
                        .padding(.horizontal, Theme.Space.xs).padding(.top, Theme.Space.snug).padding(.bottom, Theme.Space.xs)
                }
                .frame(height: 32)
                Text(preset.title).font(Theme.Typo.caption.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.accent : .secondary)
                    .frame(height: 28, alignment: .top)
            }
            .frame(maxWidth: .infinity).frame(height: 70)
            .padding(Theme.Space.xs)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous).fill(selected ? Theme.accentSoft : .clear))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                .strokeBorder(selected ? Theme.accent.opacity(0.7) : Theme.cardBorder, lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(preset.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var alignment: Alignment {
        switch preset {
        case .topLeft: .topLeading
        case .topCenter: .top
        case .topRight: .topTrailing
        case .bottomLeft: .bottomLeading
        case .bottomCenter: .bottom
        case .bottomRight: .bottomTrailing
        }
    }
}

struct MicrophoneSettings: View {
    let model: AppModel
    @State private var testing = false
    var body: some View {
        SettingsGroup(section: .microphone) {
            SettingRow(title: "Microphone", why: "Same as your Mac's Sound input.", info: .micTest) {
                HStack(spacing: Theme.Space.xs) {
                    MicPicker(model: model)
                    Button("Test…") { testing = true }.controlSize(.small).fixedSize()
                        .disabled(testing || model.live?.micTestRunning == true)
                }
            }
            SettingRow(title: "Noise reduction",
                       why: MicAudioDiagnostics.warning(model.diagnostics) ?? "Suppresses fans and hum. Can cut quiet speech in very loud rooms.",
                       info: .noiseReduction, captionWarning: MicAudioDiagnostics.warning(model.diagnostics) != nil) {
                Toggle("", isOn: Binding(get: { model.settings.voiceProcessingEnabled }, set: { model.setVoiceProcessing($0) }))
                    .toggleStyle(BrandSwitchStyle()).labelsHidden()
            }
            if model.settings.voiceProcessingEnabled {
                SettingRow(title: "↳ Mic Mode", why: "macOS Voice Isolation or Wide Spectrum.", info: .micMode) {
                    Button { AVCaptureDevice.showSystemUserInterface(.microphoneModes) } label: {
                        Text("\(MicMode.current ?? "Standard") · Change…")
                    }.controlSize(.small)
                }
            }
            SettingRow(title: "Microphone readiness", why: model.micReadiness.caption, info: .micReady) {
                ChoiceMenu(selection: model.micReadiness, options: MicReadiness.allCases, title: \.title,
                           label: "Microphone readiness", width: 250, choose: model.setMicReadiness)
            }
            SpeechModelRow(model: model)
        }
        .sheet(isPresented: $testing) { MicCheckSheet(model: model) { testing = false } }
    }
}

struct SpeechModelRow: View {
    let model: AppModel
    var body: some View {
        SettingRow(title: "Speech model", why: model.noisyRoom
                   ? "Better with voices nearby; knows 25 European languages. Short phrases can switch language."
                   : "Tuned for English; the default.", divider: false, info: .speechModel) {
            VStack(alignment: .trailing, spacing: Theme.Space.xxs) {
                ChoiceMenu(selection: model.settings.activeASRVariant, options: ASRModelVariant.allCases,
                           title: \.modeName, label: "Speech model", width: 390) { model.setNoisyRoom($0 == .parakeetUltra) }
                if case .preparing = model.modelState { Text("Loading…").font(Theme.Typo.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

struct PrivacySettings: View {
    @Bindable var model: AppModel
    @State private var count = 0
    @State private var confirmDelete = false
    /// The app's one store (its Delete All notifies History, whose play buttons disappear).
    private var store: DebugRecordingStore { model.live?.recordings ?? Self.previewStore }
    private static let previewStore = DebugRecordingStore()

    var body: some View {
        let s = model.settings
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("What stays on this Mac").font(Theme.Typo.bodyEmphasis)
                Text("Speech recognition, formatting, learning and history run on this Mac and never use the network. One exception you set up yourself: Remote Macs sends finished text to a Mac you've paired, over your Tailscale network. Audio never leaves this Mac. Caret text is read for spacing in memory only. When a dictation is blocked by macOS secure input, blocked while WisprLocal is holding off for Wispr Flow, or cancelled, no text or audio is kept; History shows only the time, the outcome and the app. After an app switch or a failed paste, the text is not saved in History or recordings; the text is copied to the clipboard so you can paste it, and kept in memory until you quit for ⌃⌥⌘V. Failed dictations (no speech heard, transcription failed, the app refused the text) keep audio if Keep last 20 recordings is on, but never text.")
                    .font(Theme.Typo.caption).foregroundStyle(.secondary)
            }.card()
            SettingsGroup(section: .privacy) {
                HistoryRetentionRow(model: model)
                SettingRow(title: AppSettings.keepRecordingsLabel,
                           why: "On by default. Failed dictations keep audio if Keep last 20 recordings is on, never text; secure input, holding off for Wispr Flow, cancellation and switched apps keep neither.", info: .debugRecordings) {
                    HStack(spacing: Theme.Space.xs) {
                        Text("\(count) saved").font(Theme.Typo.caption).foregroundStyle(.secondary)
                        Toggle("", isOn: Binding(get: { s.keepDebugRecordings }, set: { s.keepDebugRecordings = $0 }))
                            .toggleStyle(BrandSwitchStyle()).labelsHidden()
                        Menu {
                            Button("Show in Finder") {
                                guard model.live != nil else { return }
                                try? AppPaths.ensureDirectory(store.directory)
                                NSWorkspace.shared.activateFileViewerSelecting([store.directory])
                            }
                            Button("Delete All…", role: .destructive) { confirmDelete = true }.disabled(count == 0)
                        } label: { Image(systemName: "ellipsis") }
                        .menuIndicator(.hidden).accessibilityLabel("Recording options").help("Recording options")
                    }
                }
                SettingRow(title: "History folder", why: (model.live == nil ? "~/Library/Application Support/WisprLocal" : s.historyDirectory.path(percentEncoded: false)) + ". If you choose a cloud-synced folder, your history syncs with it.") {
                    Menu {
                        Button("Show in Finder") { if model.live != nil { NSWorkspace.shared.open(s.historyDirectory) } }
                        Button("Change…") { chooseHistoryFolder() }
                    } label: { Image(systemName: "ellipsis") }
                    .menuIndicator(.hidden).accessibilityLabel("History folder options").help("History folder options")
                }
                SettingRow(title: "Greet me by name on Home", why: "Uses the first name on your Mac account.", divider: false) {
                    Toggle("", isOn: Binding(get: { s.greetByName }, set: { s.greetByName = $0 }))
                        .toggleStyle(BrandSwitchStyle()).labelsHidden()
                }
            }
        }
        .onAppear { count = model.live != nil ? store.recordings().count : model.sample.debugRecordingCount }
        .confirmationDialog("Delete all troubleshooting recordings?", isPresented: $confirmDelete) {
            Button("Delete All", role: .destructive) { store.deleteAll(); count = store.recordings().count }
        }
    }

    private func chooseHistoryFolder() {
        guard let live = model.live else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { live.setHistoryDirectory(url); model.observeHistory() }
    }
}

/// Microphone menu styled as a field (brand look, not a stock popup).
struct MicPicker: View {
    let model: AppModel
    var body: some View {
        let current = model.devices.first { $0.id == model.defaultDevice }
        Menu {
            ForEach(model.devices) { d in
                Button {
                    model.selectDevice(d.id)
                } label: {
                    if d.id == model.defaultDevice { Label(d.name, systemImage: "checkmark") } else { Text(d.name) }
                }
            }
            Divider()
            Button("Refresh List") { model.refreshDevices() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: current?.isBuiltIn == false ? "headphones" : "laptopcomputer")
                    .font(Theme.Typo.symbol).foregroundStyle(Theme.accent)
                Text(current?.name ?? "System default").font(Theme.Typo.body).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(Theme.Typo.chevron).foregroundStyle(.secondary)
            }
            .padding(.horizontal, Theme.Space.snug).frame(width: 230, height: 28)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).fill(Theme.inset))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).strokeBorder(Theme.cardBorder))
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("Microphone: \(current?.name ?? "System default")")
    }
}

struct RemoteSection: View {
    var preview = false
    var expanded = false
    private static let previewDefaults: UserDefaults = {
        let suite = "wisprlocal-ui-preview-remote"
        UserDefaults().removePersistentDomain(forName: suite)
        return UserDefaults(suiteName: suite)!
    }()
    private static let previewConfig = RemoteConfigStore(defaults: previewDefaults)
    private static let previewReceivers = PairedReceiverStore(defaults: previewDefaults, secrets: InMemorySecretStore())
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            // REL-1: not yet tested end to end on two real Macs.
            SettingsGroupHeader(title: SettingsSection.remote.title, symbol: SettingsSection.remote.symbol, badge: "Beta", info: .remoteMacs)
            Text("Beta: built and tested in software, not yet verified end to end on two real Macs. Dictating into a Mac you're controlling with Screen Sharing? Pair it here.")
                .font(Theme.Typo.caption).foregroundStyle(.secondary).padding(.horizontal, Theme.Space.xxs)
            if preview { RemoteSettingsView(config: Self.previewConfig, store: Self.previewReceivers, expanded: expanded) }
            else { RemoteSettingsView() }
        }
    }
}

struct PermissionRow: View {
    let permission: Permission
    let granted: Bool
    var divider = true
    let grant: () -> Void
    let open: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(granted ? Theme.positive.opacity(0.14) : Theme.warning.opacity(0.14))
                    Image(systemName: granted ? "checkmark" : symbol)
                        .font(Theme.Typo.chip.weight(.bold))
                        .foregroundStyle(granted ? Theme.positive : Theme.warning)
                }
                .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(permission.title).font(Theme.Typo.bodyEmphasis)
                    Text(reason).font(Theme.Typo.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if granted {
                    Text("Allowed").font(Theme.Typo.caption.weight(.medium)).foregroundStyle(Theme.positive)
                } else {
                    Button("Allow…", action: grant).buttonStyle(BrandButtonStyle()).controlSize(.small)
                    Button("Open Settings", action: open).controlSize(.small)
                }
            }
            .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.snug)
            if divider { Rectangle().fill(Theme.separator).frame(height: 1).padding(.leading, Theme.Space.xxl + Theme.Space.xs) }  // text column: m + 28 pt icon + s
        }
    }

    private var symbol: String {
        switch permission {
        case .microphone: "mic"
        case .accessibility: "accessibility"
        case .inputMonitoring: "keyboard"
        }
    }

    private var reason: String {
        switch permission {
        case .microphone: "Used while you dictate, and between dictations while the mic is kept ready."
        case .accessibility: "To type the words into the app you're using."
        case .inputMonitoring: "To notice the 🌐 key from any app."
        }
    }
}
