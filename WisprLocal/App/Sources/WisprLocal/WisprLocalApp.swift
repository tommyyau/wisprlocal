import AppKit
import SwiftUI
import WisprLocalCore

@main
struct WisprLocalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        #if DEBUG
        // Hidden dev harness: render HUD states/sequence to PNGs and exit (no windows shown).
        if let i = CommandLine.arguments.firstIndex(of: "--hud-preview") {
            let args = CommandLine.arguments
            let dir = i + 1 < args.count ? args[i + 1] : NSTemporaryDirectory() + "wisprlocal-hud"
            MainActor.assumeIsolated { HUDPreview.run(outputDirectory: URL(fileURLWithPath: dir)) }
            exit(0)
        }
        #endif
        // STRUCTURAL: the one place offline mode is switched on — before any FluidAudio use.
        // Every model loader asserts it (OfflinePolicy.requireOffline) and refuses otherwise.
        OfflinePolicy.enableOfflineMode()
        // Rename WisprLite → WisprLocal: carry over dictionary + history (old folder untouched).
        // Must run before AppController reads settings/paths.
        let copied = AppPaths.migrateLegacyData()
        if !copied.isEmpty { Log.info("Migrated from WisprLite: \(copied.joined(separator: ", "))") }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: AppController.shared)
        } label: {
            MenuBarIcon(controller: AppController.shared)
        }
        .menuBarExtraStyle(.menu)
        .commands {
            // Standard About item → our About panel (Credits… lives inside it).
            CommandGroup(replacing: .appInfo) {
                Button("About WisprLocal") { WindowManager.shared.showAbout() }
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { WindowManager.shared.showSettings(controller: AppController.shared) }
                    .keyboardShortcut(",")
            }
            CommandGroup(replacing: .help) {
                Button("How to Use WisprLocal") { WindowManager.shared.showMain(controller: AppController.shared, section: .help) }
                Button("Welcome Tour…") { WindowManager.shared.showOnboarding(controller: AppController.shared) }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            #if DEBUG
            // Hidden dev harness: render every screen (light + dark, sample data) to PNGs and exit.
            // Runs before AppController.start(), so no hotkey, mic, model or permission work happens.
            if let i = CommandLine.arguments.firstIndex(of: "--ui-preview") {
                let args = CommandLine.arguments
                let dir = i + 1 < args.count ? args[i + 1] : NSTemporaryDirectory() + "wisprlocal-ui"
                let only = args.firstIndex(of: "--only").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
                UIPreview.run(outputDirectory: URL(fileURLWithPath: dir), only: only)
                exit(0)
            }
            #endif
            NSApp.setActivationPolicy(.accessory)
            AppController.shared.start()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        ClipboardRestore.restorePending()
        Task { @MainActor in
            // Finish a requested deletion before exit, including queued pipeline appends.
            do { try await AppController.shared.library.index.flush() }
            catch { Log.error("history flush failed during termination") }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppController.shared.stop()
            ClipboardRestore.restorePending()
        }
    }
}

struct MenuBarIcon: View {
    let controller: AppController
    var body: some View {
        Image(nsImage: MenuBarIconImage.image(controller.menuBarIconState))
    }
}

/// Template menu bar glyphs, one per `MenuBarIconState` (`MenuBarIcon`, `MenuBarIconWarm`,
/// `…Recording`, `…HoldingOff`, `…Alert`; png/@2x from Resources, drawn by
/// Resources/IconSource/make_icon_B.swift). A missing variant falls back to the idle glyph, and
/// a missing idle glyph to the SF Symbol `waveform`. Template rendering adapts to light/dark.
@MainActor
enum MenuBarIconImage {
    static let height: CGFloat = 16

    private static let base: NSImage = {
        if let img = bundled(MenuBarIconState.idle) { return img }
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let img = NSImage(systemSymbolName: "waveform", accessibilityDescription: "WisprLocal")?
            .withSymbolConfiguration(cfg) ?? NSImage()
        img.isTemplate = true
        return img
    }()

    private static var cache: [MenuBarIconState: NSImage] = [:]

    private static func bundled(_ state: MenuBarIconState) -> NSImage? {
        guard let img = Bundle.main.image(forResource: state.resourceName) else { return nil }
        let aspect = img.size.height > 0 ? img.size.width / img.size.height : 1
        img.size = NSSize(width: (height * aspect).rounded(), height: height)
        img.isTemplate = true
        img.accessibilityDescription = state.accessibilityDescription
        return img
    }

    static func image(_ state: MenuBarIconState) -> NSImage {
        if let img = cache[state] { return img }
        let img = bundled(state) ?? base
        cache[state] = img
        return img
    }
}
