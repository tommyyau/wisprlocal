# Remote Macs (Beta): dictating over Screen Sharing

> **Beta.** Remote Macs is built, unit-tested and tested over a loopback connection on one Mac,
> but it has **not yet been tested end to end on two real Macs** over Screen Sharing and
> Tailscale. Expect rough edges, and please report them.

You dictate on this Mac (the **sender**, running WisprLocal) into an app on another Mac that
you're viewing with macOS Screen Sharing over Tailscale (the **remote**).

## Why it needs special handling

When the frontmost app is a remote viewer, the normal local path breaks. Screen Sharing syncs
the clipboard late, so Cmd-V pastes whatever was on the remote's clipboard before. Accessibility
insertion also lands in the local viewer window, not in the remote app.

Remote viewers are detected by bundle ID. The defaults are Screen Sharing, Jump Desktop, RealVNC,
Microsoft Windows App, RustDesk and Parsec. You can edit the list in **Settings › Remote Macs**.

## How text gets there

1. **Receiver (best).** WisprLocal Receiver runs on the remote Mac. The sender picks a paired
   receiver whose name or address appears in the viewer's window title, or else the
   **default receiver**. If that receiver accepts the connection within **300 ms**, the text goes
   over Tailscale and the receiver pastes it on the remote Mac (pasteboard + Cmd-V, with the
   previous clipboard restored). Emoji, £, — and any other characters all work.
2. **Typing fallback.** This runs when none is paired, or on a failure before transmission (`.unreachable`). Every failure after handing text to the connection, including a send error, is `.unconfirmed` and never falls back. You can
   choose the method in Settings › Remote Macs:
   - **Unicode typing**, the default for now. Each character goes as its own CGEvent with a
     Unicode string.
   - **Keycode typing.** Real keycodes and modifiers for your layout. Characters your layout
     can't type fall back to Unicode, one character at a time.
   - **Clipboard + delay.** Sets the local clipboard, waits 1500 ms by default so Screen
     Sharing can sync it, then sends Cmd-V.

   Typing sends one character every 4 ms. Newlines are typed as **Shift+Return**, because a bare
   Return sends the message in chat apps. Typing stops as soon as the frontmost app or window
   changes.

**When the receiver answers, its answer is final.** If it refuses — above all because **a
password field is focused on the remote Mac** — WisprLocal does *not* type the text through
Screen Sharing instead. You see "Remote Mac has a password field focused — not inserted", and
the text reached the receiver but was not inserted and is not kept. The receiver relies on macOS secure input; fields that do not enable it are not detected. Failures other than secure-input refusal may keep audio, never text. Only failures before transmission (`.unreachable`) may fall back to local typing. Send errors are `.unconfirmed` and never fall back.

## Setup

**Prerequisites.** Tailscale running and logged in to the same tailnet on both Macs, and Screen
Sharing from this Mac to the remote already working.

1. **Build the receiver.** There is no prebuilt download. On the Mac where you built WisprLocal,
   run `cd WisprLocal/App && scripts/build_receiver.sh`, which produces
   `build.noindex/WisprLocalReceiver.app`. Copy that app into `/Applications` on the **remote**
   Mac (for example by dragging it into the Screen Sharing window, or with AirDrop).
2. **Open it once, if macOS blocks it.** An app copied by AirDrop or a browser download is tagged
   as quarantined, so the first double-click may be blocked because the app isn't notarised.
   If so, click **Done**, open System Settings › Privacy & Security, scroll to **Security**, click
   **Open Anyway** next to WisprLocal Receiver, and confirm. (On macOS 15 and later, Control-click ›
   Open no longer bypasses this.) A copy made another way, such as `rsync` or `scp`, or built on
   that Mac itself, isn't quarantined and opens straight away.
3. **Grant Accessibility on the remote.** The receiver asks for it on first launch. Go to System
   Settings → Privacy & Security → Accessibility and switch on **WisprLocal Receiver**. The menu
   item "Grant Accessibility…" opens that pane.
4. **Check that it's listening.** The menu-bar icon (keyboard) should say
   "Listening on 100.x.y.z:47655 via utunN (Tailscale only)". If it says **"Tailscale not
   running"**, start Tailscale; the receiver checks again every 10 s.
5. **Pair.** On the remote, choose **Copy Pairing Code** from the receiver menu. Screen Sharing's
   clipboard sync carries the code to this Mac. In WisprLocal › Settings › Remote Macs, paste the
   code. Check that the **fingerprint** shown, such as `1A2B-3C4D`, matches the one in the
   receiver's menu, then click **Pair**. No receiver is the default until you choose one in Settings › Remote Macs. The
   copied code is marked concealed/transient for clipboard managers, is cleared from the remote's
   clipboard after 60 s, and is cleared from this Mac's clipboard as soon as pairing succeeds.
6. **Test.**
   - In Settings › Remote Macs, the receiver should show **Reachable**. This is a request-authenticated
     ping (the reply is not signed; see Threat notes); nothing is typed.
   - Open TextEdit on the remote in the Screen Sharing window, hold 🌐 and dictate. Include
     `£5 — café 😀` and a two-line sentence. The receiver's "Received" count should go up.
   - Click into a password field on the remote and dictate: the text reaches the receiver but should not be inserted or kept, the HUD says
     the remote has a password field focused, and the receiver's "Password field" count goes up.
   - Quit the receiver and dictate again. This time the typing fallback types the text.
   - Switch windows mid-dictation. Typing should stop.

## What a leaked pairing code allows, and how to revoke it

The pairing code **is** the receiver's permanent key (plus its Tailscale address). Anyone who has
it, and can reach that address on your tailnet, can make the receiver paste **any text they
like** into whatever app is focused on the remote Mac — at any time, whether or not you have a
Screen Sharing session open. Text ending in a newline pasted into a focused Terminal can run a
command. The receiver's secure-input check refuses when macOS enables that signal; password fields that do not enable it are not detected,
but nothing else stops a key-holder.

- Treat the code like a password: move it only through your own Screen Sharing session, never
  paste it into chat, email, notes or an issue.
- **To revoke**, choose **Generate New Key…** in the receiver's menu. Every sender that was paired
  stops working immediately; pair your own Macs again. This is the only revocation.
- Also restrict who can reach the remote Mac in your Tailscale ACLs, and remove nodes you no
  longer own.

## Security model

- **Tailscale only, enforced in code — by interface, not just by address.**
  - The sender connects only to IP *literals* in `100.64.0.0/10` or `fd7a:115c:a1e0::/48`
    (`AddressPolicy.tailnetOnly`, checked before any socket is created). Host names,
    IPv4-mapped IPv6 (`::ffff:100.64.0.1`) and non-canonical spellings are refused.
  - `100.64.0.0/10` is the shared (CGNAT) range, which ISPs, hotspots and other VPNs also use, so
    an address check alone is not enough. The **receiver** binds only to an address on an up,
    point-to-point `utun*` interface (Tailscale's tunnel), preferring the one that also carries a
    Tailscale `fd7a:115c:a1e0::/48` address, and won't start without one; a CGNAT address on `en0`
    is never used. It also drops any peer outside the tailnet ranges.
  - The **sender** checks, after connecting and before sending a byte, that the connection's path
    goes through a `utun*` interface, and never uses loopback. (Network.framework cannot express
    "utun only" as a parameter: `requiredInterfaceType = .other` is the no-op default, and
    prohibiting Wi-Fi/Ethernet would also block Tailscale running over them.)
  - **Residual risk:** the checks are by interface *name*. Another VPN that puts a tailnet-range
    address on its own `utun` would pass them. The HMAC key still has to match, and the text's
    confidentiality on such a path depends on that VPN.
  - Tests: `TailnetAddressTests`, `TailscaleInterfaceTests`, `BridgeRefusesNonTailnetTests`.
- **Authenticated messages.** Each message is length-prefixed JSON `{v:1, nonce, ts, text, mac}`,
  where `mac` = HMAC-SHA256(key, v‖nonce‖ts‖text). Each field is length-prefixed, so field
  boundaries can't be ambiguous. The receiver rejects:
  - a bad MAC (checked in constant time);
  - `|ts − now| > 30 s`;
  - a replayed nonce (it remembers the last 1000);
  - text over 20 KB (UTF-8 bytes);
  - frames over 256 KB, which it doesn't read.

  It replies with an ack status, which is never the text.
- **Password fields on the remote.** The sender's own secure-input check only sees this Mac,
  where the front app is Screen Sharing. So the receiver checks `IsSecureEventInputEnabled()` on
  the remote **before** touching its pasteboard and answers `secure_input`; the sender treats that
  (and every other receiver answer) as final and never types the text instead
  (`RemoteSecureInputTests`).
- **Keys.**
  - The receiver generates a 32-byte random key on first run. It's stored in the Keychain as a
    generic password with service `WisprLocal Receiver`. "Generate New Key…" rotates it, which
    unpairs every sender.
  - The sender stores each receiver's key in its own Keychain (service `WisprLocal Sender`).
    Only the name, address, port and fingerprint go into UserDefaults.
- **No logging of secrets or content.** Neither app logs or displays the key or the dictated
  text. The receiver shows only counts.
- **Offline guard.**
  - `OfflineGuardTests` fails if networking APIs appear anywhere except
    `WisprLocalCore/RemoteBridge/` and the `WisprLocalReceiver` target.
  - Even those two places may use only Network.framework: no URLSession, URLRequest, http(s)
    URLs, WebKit or processes.
  - `scripts/test_offline.sh` runs the tests (socket-dependent and opt-in tests are skipped) in a sandbox with no network access; `swift test` runs the socket-dependent tests outside that sandbox.
- **Threat notes.**
  - Anyone on your tailnet can reach the port, but without the key they can't get text inserted.
  - Tailscale (WireGuard) encrypts the traffic between the Macs. The bridge adds authentication
    and integrity, not its own encryption, and acknowledgements are not authenticated: whoever
    answers on the paired address and port receives the text. Keep your tailnet's membership and
    ACLs tight. (Authenticated encryption and signed acks are planned; see ROADMAP.md.)
  - The receiver pastes into whatever app is focused on the remote Mac, just as the remote
    keyboard would.

## For developers

**Building the receiver yourself.** `cd WisprLocal/App && scripts/build_receiver.sh` produces
`build.noindex/WisprLocalReceiver.app` (bundle ID `com.tommyyau.wisprlocal.receiver`), signed with
the same identity as WisprLocal.app, with FluidAudio's licence texts bundled. Create a stable
identity first with `scripts/create_signing_identity.sh`; otherwise the remote's Accessibility
grant resets on every rebuild.

**Default typing fallback.** The default is the one-line constant
`RemoteConfig.defaultTypingFallback`. It should be revisited once the S2 test
(`WisprLocal/Spikes/S2-keystrokes`) has been run on two real Macs.

**Files.**

- `App/Sources/WisprLocalCore/Remote/`: the strategy chain (`RemoteInserter`), typing fallbacks,
  `KeyStrokeMap` (UCKeyTranslate reverse map, ported from S2), `RemoteConfigStore`,
  `PairedReceiverStore`, `ReceiverMatcher` and the Keychain `SecretStore`.
- `App/Sources/WisprLocalCore/RemoteBridge/`: the protocol, HMAC and `ReceiverDeliveryPolicy`
  (`BridgeProtocol`), `BridgeClient`, `BridgeServer`, `TailnetAddress` / `AddressPolicy` /
  `TailscaleInterface`, `PairingCode`, `SecretPasteboard` and `ReceiverIdentity`. This is the
  only network code in Core.
- `App/Sources/WisprLocalReceiver/main.swift`: the menu-bar receiver app.
- `App/Sources/WisprLocal/RemoteSettingsView.swift`: Settings › Remote Macs.
- `App/scripts/build_receiver.sh` and `App/scripts/signing_common.sh` (shared with build_app.sh).
