import SwiftUI
import WisprLocalCore

/// Settings › Remote Macs (Beta). Self-contained: reads/writes `RemoteConfigStore.shared` and
/// `PairedReceiverStore.shared` directly, so it can be dropped into any settings layout:
///     RemoteSettingsView()
/// Pairing keys go to the Keychain; nothing here displays or logs a key.
struct RemoteSettingsView: View {
    @State private var config: RemoteConfigStore
    @State private var store: PairedReceiverStore

    init(config: RemoteConfigStore = .shared, store: PairedReceiverStore = .shared, expanded: Bool = false) {
        _config = State(initialValue: config)
        _store = State(initialValue: store)
        _viewersExpanded = State(initialValue: expanded)
    }
    @State private var viewersExpanded = false
    @State private var code = ""
    @State private var pairError: String?
    @State private var reach: [UUID: Reachability] = [:]
    @State private var newBundleID = ""
    @State private var confirmUnpair: PairedReceiver?

    enum Reachability: Equatable {
        case checking, reachable, unreachable(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            receiversBox
            pairBox
            fallbackBox
            SettingsDisclosureRow(title: "Advanced: remote viewer apps",
                                  caption: "Apps WisprLocal treats as a window onto another Mac.", expanded: $viewersExpanded) {
                viewersBox
            }.card(padding: 0)
        }
        .task { await checkAll() }
        .confirmationDialog("Unpair \(confirmUnpair?.displayName ?? "")?",
                            isPresented: Binding(get: { confirmUnpair != nil }, set: { if !$0 { confirmUnpair = nil } })) {
            Button("Unpair", role: .destructive) {
                if let r = confirmUnpair { unpair(r) }
                confirmUnpair = nil
            }
        } message: {
            Text("Its key is removed from this Mac's Keychain. Pair again with the receiver's code to undo.")
        }
    }

    // MARK: paired receivers

    private var receiversBox: some View {
        RemoteCard {
            VStack(alignment: .leading, spacing: 10) {
                if store.receivers.isEmpty {
                    Text("No receivers paired. Without one, dictation into Screen Sharing is typed using the fallback below.")
                        .foregroundStyle(.secondary).font(Theme.Typo.body)
                } else {
                    ForEach(store.receivers) { r in receiverRow(r) }
                }
                if !store.receivers.isEmpty {
                    Picker("Default receiver", selection: Binding(
                            get: { config.config.defaultReceiverID },
                            set: { config.config.defaultReceiverID = $0 })) {
                            Text("None (match window title only)").tag(UUID?.none)
                            ForEach(store.receivers) { r in Text(r.displayName).tag(UUID?.some(r.id)) }
                        }
                        .preference(key: SettingsRowTitles.self, value: ["Default receiver"])
                        Text("Used when a remote window's title matches no receiver. Leave None to type locally instead.")
                            .font(Theme.Typo.caption).foregroundStyle(.secondary)
                    Button("Check Reachability") { Task { await checkAll() } }.buttonStyle(BrandButtonStyle(prominent: false))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
        } label: { RemoteCardTitle(title: "Paired receivers", symbol: "display.2") }
    }

    private func receiverRow(_ r: PairedReceiver) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(r.displayName).font(.body.weight(.medium))
                Text("\(r.host):\(String(r.port))  ·  fingerprint \(r.fingerprint)")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            reachBadge(reach[r.id])
            Button("Unpair") { confirmUnpair = r }
        }
    }

    @ViewBuilder private func reachBadge(_ s: Reachability?) -> some View {
        switch s {
        case .checking: ProgressView().controlSize(.small)
        case .reachable: Label("Reachable", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.positive).font(Theme.Typo.caption)
        case .unreachable(let why): Label(why, systemImage: "xmark.circle.fill").foregroundStyle(Theme.warning).font(Theme.Typo.caption)
        case nil: EmptyView()
        }
    }

    // MARK: pairing

    private var preview: Result<PairingInfo, Error>? {
        let t = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return Result { try PairingCode.decode(t) }
    }

    private var pairBox: some View {
        RemoteCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("On the remote Mac, open the WisprLocal Receiver menu → Copy Pairing Code, then paste it here.")
                    .font(Theme.Typo.body).foregroundStyle(.secondary)
                TextField("WL1-…", text: $code, axis: .vertical)
                    .font(.caption.monospaced())
                    .lineLimit(1...4)
                    .textFieldStyle(.plain).padding(.horizontal, Theme.Space.snug).padding(.vertical, Theme.Space.tight)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).fill(Theme.inset))
                switch preview {
                case .success(let info)?:
                    Text("\(info.names.first ?? info.host) at \(info.host):\(String(info.port)) — fingerprint **\(info.fingerprint)**. Check it matches the receiver's menu.")
                        .font(Theme.Typo.body)
                case .failure(let e)?:
                    Text(e.localizedDescription).font(Theme.Typo.body).foregroundStyle(Theme.danger)
                case nil:
                    EmptyView()
                }
                if let pairError { Text(pairError).font(Theme.Typo.body).foregroundStyle(Theme.danger) }
                Button("Pair") { pair() }.buttonStyle(BrandButtonStyle())
                    .disabled({ if case .success? = preview { return false }; return true }())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
        } label: { RemoteCardTitle(title: "Pair a receiver", symbol: "link") }
    }

    private func pair() {
        do {
            let r = try store.pair(code: code)
            SecretPasteboard.clearIfHolding(code)  // SEC-6: don't leave the key on the clipboard
            code = ""; pairError = nil
            Task { await check(r) }
        } catch {
            pairError = error.localizedDescription
        }
    }

    private func unpair(_ r: PairedReceiver) {
        store.unpair(r.id)
        reach[r.id] = nil
        if config.config.defaultReceiverID == r.id { config.config.defaultReceiverID = nil }
    }

    private func checkAll() async {
        await withTaskGroup(of: Void.self) { g in
            for r in store.receivers { g.addTask { await check(r) } }
        }
    }

    private func check(_ r: PairedReceiver) async {
        guard let key = store.key(for: r.id) else { reach[r.id] = .unreachable("Key missing — re-pair"); return }
        reach[r.id] = .checking
        switch await BridgeClient().ping(key: key, to: r.endpoint) {
        case .success: reach[r.id] = .reachable
        case .failure(let e):
            switch e {
            case .rejected(.badMAC): reach[r.id] = .unreachable("Key mismatch — re-pair")
            case .rejected(.stale): reach[r.id] = .unreachable("Clocks differ >30 s")
            default: reach[r.id] = .unreachable("Not reachable")
            }
        }
    }

    // MARK: fallback

    private var fallbackBox: some View {
        RemoteCard {
            VStack(alignment: .leading, spacing: 8) {
                Picker("When no receiver is reachable", selection: Binding(
                    get: { config.config.typingFallback }, set: { config.config.typingFallback = $0 })) {
                    ForEach(RemoteTypingFallback.allCases) { Text(fallbackTitle($0) + ($0 == RemoteConfig.defaultTypingFallback ? " (default)" : "")).tag($0) }
                }
                .preference(key: SettingsRowTitles.self, value: ["Typing fallback"])
                if config.config.typingFallback == .clipboardDelay {
                    Stepper("Wait \(config.config.clipboardDelayMs) ms before pasting",
                            value: Binding(get: { config.config.clipboardDelayMs },
                                           set: { config.config.clipboardDelayMs = $0 }),
                            in: 250...5000, step: 250)
                }
                Text(fallbackCaption)
                    .font(Theme.Typo.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
        } label: { RemoteCardTitle(title: "Typing fallback", symbol: "keyboard") }
    }

    private func fallbackTitle(_ value: RemoteTypingFallback) -> String {
        switch value {
        case .unicode: "Type characters"
        case .keycode: "Type keycodes"
        case .clipboardDelay: "Paste after a delay"
        }
    }
    private var fallbackCaption: String {
        switch config.config.typingFallback {
        case .unicode: "Types characters one at a time. Stops if you switch windows."
        case .keycode: "Types using your keyboard layout. Stops if you switch windows."
        case .clipboardDelay: "Waits for Screen Sharing to sync the clipboard, then pastes."
        }
    }

    // MARK: viewer apps

    private var viewersBox: some View {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(config.config.viewerBundleIDs, id: \.self) { id in
                    HStack {
                        Text(id).font(.callout.monospaced())
                        Spacer()
                        Button {
                            config.config.viewerBundleIDs.removeAll { $0 == id }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Bundle ID, e.g. com.example.viewer", text: $newBundleID)
                        .textFieldStyle(.plain).padding(.horizontal, Theme.Space.snug).padding(.vertical, Theme.Space.tight)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).fill(Theme.inset))
                    Button("Add") {
                        let id = newBundleID.trimmingCharacters(in: .whitespaces)
                        if !id.isEmpty, !config.config.viewerBundleIDs.contains(id) { config.config.viewerBundleIDs.append(id) }
                        newBundleID = ""
                    }
                    .disabled(newBundleID.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Button("Reset to Defaults") { config.config.viewerBundleIDs = RemoteConfig.defaultViewerBundleIDs }
                    .buttonStyle(.link)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
    }
}

/// Card container in the Settings style (title row + content), replacing stock GroupBox.
struct RemoteCard<Content: View, Title: View>: View {
    @ViewBuilder var content: Content
    @ViewBuilder var label: Title
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            label
            content
        }
        .card()
    }
}

struct RemoteCardTitle: View {
    let title: String
    let symbol: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(Theme.Typo.symbol.weight(.semibold)).foregroundStyle(Theme.accent)
                .frame(width: 24, height: 24).background(RoundedRectangle(cornerRadius: Theme.Radius.well, style: .continuous).fill(Theme.accentSoft))
            Text(title).font(Theme.Typo.bodyEmphasis)
        }
    }
}
