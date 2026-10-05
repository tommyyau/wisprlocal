import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import KeyMap

let defaultText = "Hello World, it's 10:45! Email: a.b@x.com (test) £5 — café"

struct Opts {
    var delay = 5.0
    var text = defaultText
    var intervalMs = 5.0
    var syncMs = 0.0
    var explicitModifiers = false
    var session = false
}

func usage() -> Never {
    print("""
    usage: keytest <unicode|keycode|paste|all> [--delay S] [--text STR] [--interval-ms N]
                   [--sync-ms N] [--explicit-modifiers] [--tap hid|session]
    """)
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first, ["unicode", "keycode", "paste", "all"].contains(cmd) else { usage() }
args.removeFirst()
var o = Opts()
var i = 0
func next() -> String { i += 1; guard i < args.count else { usage() }; return args[i] }
while i < args.count {
    switch args[i] {
    case "--delay": o.delay = Double(next()) ?? 5
    case "--text": o.text = next()
    case "--interval-ms": o.intervalMs = Double(next()) ?? 5
    case "--sync-ms": o.syncMs = Double(next()) ?? 0
    case "--explicit-modifiers": o.explicitModifiers = true
    case "--tap": o.session = (next() == "session")
    default: usage()
    }
    i += 1
}

let tap: CGEventTapLocation = o.session ? .cgSessionEventTap : .cghidEventTap
let source = CGEventSource(stateID: .hidSystemState)

func sleepMs(_ ms: Double) { if ms > 0 { usleep(UInt32(ms * 1000)) } }

func post(_ e: CGEvent?) { e?.post(tap: tap) }

func checkTrust() {
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    if !AXIsProcessTrustedWithOptions(opts) {
        print("""
        NOT TRUSTED for Accessibility. Grant it to the app running this tool (Terminal/iTerm/your IDE):
          System Settings > Privacy & Security > Accessibility > enable your terminal app, then
          fully quit and relaunch the terminal and re-run. Events posted now would be silently dropped.
        """)
        exit(1)
    }
}

// MARK: methods

func typeUnicode(_ text: String) {
    for ch in text {
        let utf16 = Array(String(ch).utf16)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        down?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        up?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        post(down); post(up)
        sleepMs(o.intervalMs)
    }
}

func modKeyCodes(_ f: CGEventFlags) -> [CGKeyCode] {
    var r: [CGKeyCode] = []
    if f.contains(.maskShift) { r.append(56) }
    if f.contains(.maskAlternate) { r.append(58) }
    if f.contains(.maskCommand) { r.append(55) }
    return r
}

func pressKey(_ code: CGKeyCode, flags: CGEventFlags) {
    var cur: CGEventFlags = []
    let mods = modKeyCodes(flags)
    if o.explicitModifiers {
        for m in mods {
            cur.formUnion(m == 56 ? .maskShift : m == 58 ? .maskAlternate : .maskCommand)
            let e = CGEvent(keyboardEventSource: source, virtualKey: m, keyDown: true)
            e?.flags = cur
            post(e)
            sleepMs(o.intervalMs)
        }
    }
    let d = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
    let u = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
    d?.flags = flags; u?.flags = flags
    post(d); sleepMs(o.intervalMs); post(u)
    if o.explicitModifiers {
        for m in mods.reversed() {
            cur.subtract(m == 56 ? .maskShift : m == 58 ? .maskAlternate : .maskCommand)
            let e = CGEvent(keyboardEventSource: source, virtualKey: m, keyDown: false)
            e?.flags = cur
            post(e)
            sleepMs(o.intervalMs)
        }
    }
    sleepMs(o.intervalMs)
}

func typeKeycode(_ text: String) {
    let map = KeyMapBuilder.buildCurrent()
    if map.isEmpty { print("keycode: no keyboard layout data available"); return }
    var unmappable: [Character] = []
    for ch in text {
        guard let s = map[ch] else { unmappable.append(ch); continue }
        pressKey(s.keyCode, flags: s.flags)
    }
    if unmappable.isEmpty { print("keycode: all characters mapped") }
    else { print("keycode: UNMAPPABLE characters (skipped): \(unmappable.map { String($0) }.joined(separator: " "))") }
}

func pasteText(_ text: String, syncMs: Double) {
    let pb = NSPasteboard.general
    let saved: [[(NSPasteboard.PasteboardType, Data)]] = (pb.pasteboardItems ?? []).map { item in
        item.types.compactMap { t in item.data(forType: t).map { (t, $0) } }
    }
    pb.clearContents()
    pb.setString(text, forType: .string)
    sleepMs(syncMs)
    let d = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
    let u = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
    d?.flags = .maskCommand; u?.flags = .maskCommand
    if o.explicitModifiers {
        let m = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: true); m?.flags = .maskCommand
        post(m); sleepMs(o.intervalMs)
    }
    post(d); sleepMs(o.intervalMs); post(u)
    if o.explicitModifiers {
        sleepMs(o.intervalMs)
        post(CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: false))
    }
    sleepMs(500)
    pb.clearContents()
    for item in saved {
        let n = NSPasteboardItem()
        for (t, data) in item { n.setData(data, forType: t) }
        pb.writeObjects([n])
    }
}

func returnKey() { pressKey(36, flags: []) ; sleepMs(100) }

func label(_ s: String) { typeUnicodeLabel(s) }
func typeUnicodeLabel(_ s: String) { typeUnicode(s) }

func countdown() {
    print("Focus the target window now. Starting in \(o.delay)s ...")
    var t = o.delay
    while t > 0 { print("  \(Int(ceil(t)))"); sleep(1); t -= 1 }
}

checkTrust()
print("tap: \(o.session ? "session" : "hid"), interval \(o.intervalMs)ms, explicit-modifiers \(o.explicitModifiers)")
countdown()

switch cmd {
case "unicode":
    typeUnicode("unicode: "); typeUnicode(o.text)
case "keycode":
    typeUnicode("keycode: "); typeKeycode(o.text)
case "paste":
    typeUnicode("paste(sync \(Int(o.syncMs))ms): "); pasteText(o.text, syncMs: o.syncMs)
case "all":
    typeUnicode("unicode: "); typeUnicode(o.text); returnKey()
    typeUnicode("keycode: "); typeKeycode(o.text); returnKey()
    for s in [0.0, 1000, 2500] {
        typeUnicode("paste(sync \(Int(s))ms): "); pasteText(o.text, syncMs: s); returnKey()
    }
default: usage()
}
print("done")
