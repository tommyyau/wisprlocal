import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CryptoKit
import SystemConfiguration
import WisprLocalCore

/// WisprLocal Receiver — runs on the REMOTE Mac. Listens ONLY on this Mac's Tailscale 100.x
/// address on a `utun*` tunnel interface (`TailscaleInterface`, SEC-3), accepts HMAC-authenticated text from paired WisprLocal senders and pastes it at the
/// cursor (Core's `PasteInserter`: pasteboard + Cmd-V, previous clipboard restored).
/// Never logs or displays received text — only a count.
@MainActor
final class ReceiverApp: NSObject, NSApplicationDelegate {
    enum State: Equatable {
        case starting
        case noTailscale
        case listening(ip: String, port: UInt16, interface: String)
        case failed(String)
    }

    private var statusItem: NSStatusItem!
    private var state: State = .starting { didSet { rebuildMenu() } }
    private var key = Data()
    private var server: BridgeServer?
    private var boundIP: String?
    private var received = 0
    private var rejected = 0
    private var blockedSecure = 0
    private var retryTimer: Timer?
    private let paste = PasteInserter()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "keyboard.badge.ellipsis", accessibilityDescription: "WisprLocal Receiver")
        rebuildMenu()
        do { key = try ReceiverIdentity.loadOrCreateKey() } catch {
            state = .failed("Keychain unavailable (\(error.localizedDescription))"); return
        }
        if !AXIsProcessTrusted() { promptAccessibility() }
        Task { await startIfPossible() }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.watchdog() }
        }
    }

    // MARK: listener lifecycle

    private func startIfPossible() async {
        guard let addr = TailscaleInterface.ipv4Address() else {
            server?.stop(); server = nil; boundIP = nil
            state = .noTailscale
            return
        }
        let s = BridgeServer(bindHost: addr.ip, port: BridgeLimits.defaultPort, key: SymmetricKey(data: key), guardedDeliver: { [weak self] text, isCurrent in
            await self?.deliver(text, isCurrent: isCurrent) ?? .insertFailed
        })
        s.onReceipt = { [weak self] status in
            Task { @MainActor in self?.count(status) }
        }
        server?.stop()
        server = s  // key rotation must also stop a listener that is still starting
        do {
            let port = try await s.start()
            guard server === s else { return }
            boundIP = addr.ip
            state = .listening(ip: addr.ip, port: port, interface: addr.interface)
        } catch {
            guard server === s else { return }
            server = nil; boundIP = nil
            state = .failed(error.localizedDescription)
        }
    }

    /// Tailscale may start late, stop, or change address: follow it.
    private func watchdog() async {
        let ip = TailscaleInterface.ipv4Address()?.ip
        if ip != boundIP || server == nil {
            server?.stop(); server = nil; boundIP = nil
            await startIfPossible()
        } else {
            rebuildMenu()  // refresh Accessibility status
        }
    }

    /// SEC-4: refuses with `.secureInput` while a password field is focused on THIS Mac (the
    /// sender's own secure-input gate only sees its Screen Sharing window).
    private func deliver(_ text: String, isCurrent: @escaping @Sendable () -> Bool) async -> BridgeStatus {
        guard isCurrent() else { return .insertFailed }
        let paste = self.paste
        return await ReceiverDeliveryPolicy.deliver(text, secureInputActive: { IsSecureEventInputEnabled() },
                                                    accessibilityTrusted: { AXIsProcessTrusted() },
                                                    insert: { text in
                                                        try await paste.insert(text, prePostCheck: {
                                                            guard isCurrent() else { throw CancellationError() }
                                                        })
                                                    })
    }

    private func count(_ status: BridgeStatus) {
        switch status {
        case .ok: received += 1
        case .pong: break
        case .secureInput: blockedSecure += 1
        default: rejected += 1
        }
        rebuildMenu()
    }

    // MARK: pairing

    static func computerNames() -> [String] {
        var names: [String] = []
        if let n = SCDynamicStoreCopyComputerName(nil, nil) as String? { names.append(n) }
        if let h = SCDynamicStoreCopyLocalHostName(nil) as String? { names.append(h + ".local") }
        return names
    }

    private var pairingCode: String? {
        guard case .listening(let ip, let port, _) = state else { return nil }
        return PairingCode.encode(PairingInfo(names: Self.computerNames(), host: ip, port: port, key: key))
    }

    private var fingerprint: String { PairingCode.fingerprint(key: key) }

    @objc private func showPairingCode() {
        guard let code = pairingCode else { return }
        let alert = NSAlert()
        alert.messageText = "Pairing code"
        alert.informativeText = """
        Copy this code into WisprLocal on your other Mac (Settings → Remote Macs → Pair). It IS the \
        secret key: share it only over your own Screen Sharing session. A copied code is cleared \
        from the clipboard after 60 seconds.

        Fingerprint (check it matches on the other Mac): \(fingerprint)
        """
        let field = NSTextField(wrappingLabelWithString: code)
        field.isSelectable = true
        field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        field.preferredMaxLayoutWidth = 360
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 80)
        alert.accessoryView = field
        alert.addButton(withTitle: "Copy Code")
        alert.addButton(withTitle: "Close")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { copyPairingCode() }
    }

    @objc private func copyPairingCode() {
        guard let code = pairingCode else { return }
        // SEC-6: concealed + transient markers, auto-cleared after 60 s if still ours.
        SecretPasteboard.write(code)
    }

    @objc private func regenerateKey() {
        let alert = NSAlert()
        alert.messageText = "Generate a new key?"
        alert.informativeText = "Every Mac paired with this receiver will stop working until you pair it again."
        alert.addButton(withTitle: "Generate New Key")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { key = try ReceiverIdentity.regenerate() } catch { state = .failed("Keychain write failed"); return }
        server?.stop(); server = nil; boundIP = nil
        Task { await startIfPossible() }
    }

    // MARK: accessibility

    private func promptAccessibility() {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    @objc private func openAccessibilitySettings() {
        promptAccessibility()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: menu

    private func item(_ title: String, _ action: Selector? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = action == nil ? nil : self
        i.isEnabled = action != nil
        return i
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(item("WisprLocal Receiver"))
        switch state {
        case .starting: menu.addItem(item("Starting…"))
        case .noTailscale: menu.addItem(item("Tailscale not running — waiting"))
        case .listening(let ip, let port, let iface): menu.addItem(item("Listening on \(ip):\(port) via \(iface) (Tailscale only)"))
        case .failed(let why): menu.addItem(item("Not listening: \(why)"))
        }
        if AXIsProcessTrusted() {
            menu.addItem(item("Accessibility: granted"))
        } else {
            menu.addItem(item("Grant Accessibility (needed to paste)…", #selector(openAccessibilitySettings)))
        }
        menu.addItem(.separator())
        menu.addItem(item("Fingerprint: \(fingerprint)"))
        let show = item("Show Pairing Code…", #selector(showPairingCode))
        let copy = item("Copy Pairing Code", #selector(copyPairingCode))
        show.isEnabled = pairingCode != nil; copy.isEnabled = pairingCode != nil
        menu.addItem(show); menu.addItem(copy)
        menu.addItem(.separator())
        menu.addItem(item("Received: \(received)   Rejected: \(rejected)   Password field: \(blockedSecure)"))
        menu.addItem(.separator())
        menu.addItem(item("Generate New Key…", #selector(regenerateKey)))
        let quit = NSMenuItem(title: "Quit WisprLocal Receiver", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
    }
}

let app = NSApplication.shared
let delegate = ReceiverApp()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
