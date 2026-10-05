import AppKit
import SwiftUI

/// AppKit-managed windows (an LSUIElement app has no regular window scenes). The app becomes
/// `.regular` while a window is open so text fields get keyboard focus, then returns to
/// `.accessory`.
///
/// Windows: the single main window (sidebar: Home, History, Dictionary, Snippets, Settings,
/// Help), the first-run onboarding, and a standard About panel (Credits is a sheet of it).
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    static let shared = WindowManager()
    private var windows: [String: NSWindow] = [:]
    private var liveModel: AppModel?

    func model(for controller: AppController) -> AppModel {
        if let m = liveModel { return m }
        let m = AppModel(controller: controller)
        liveModel = m
        return m
    }

    func showMain(controller: AppController, section: MainSection? = nil, helpTab: HelpView.Tab? = nil) {
        let model = model(for: controller)
        if let section { model.section = section }
        if let helpTab { model.helpTabRequest = helpTab }
        show(id: "main", title: "WisprLocal", size: NSSize(width: 1000, height: 700), minSize: NSSize(width: 820, height: 560),
             style: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]) {
            MainWindowView(model: model)
        }
    }

    /// Kept for existing call sites: Settings lives in the main window.
    func showSettings(controller: AppController) { showMain(controller: controller, section: .settings) }

    func showAbout(credits: Bool = false) {
        show(id: "about", title: "About WisprLocal", size: NSSize(width: 320, height: 380), minSize: nil,
             style: [.titled, .closable, .fullSizeContentView], transparentTitlebar: true) { AboutView(showCredits: credits) }
    }

    /// Menu › Help › Credits…: the About panel with its Credits sheet already open.
    func showCredits() {
        close("about")
        showAbout(credits: true)
    }

    func showOnboarding(controller: AppController) {
        let model = model(for: controller)
        show(id: "onboarding", title: "Welcome to WisprLocal", size: NSSize(width: 680, height: 580), minSize: nil,
             style: [.titled, .closable, .fullSizeContentView], transparentTitlebar: true) {
            OnboardingView(model: model) { [weak self] in
                self?.close("onboarding")
                self?.showMain(controller: controller, section: .home)
            }
        }
    }

    private func show<V: View>(id: String, title: String, size: NSSize, minSize: NSSize?,
                               style: NSWindow.StyleMask, transparentTitlebar: Bool = false,
                               @ViewBuilder content: () -> V) {
        let window: NSWindow
        if let w = windows[id] { window = w } else {
            window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
            window.title = title
            window.isReleasedWhenClosed = false
            if transparentTitlebar {
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                window.isMovableByWindowBackground = true
            }
            window.contentViewController = NSHostingController(rootView: content())
            window.setContentSize(size)
            if let minSize { window.contentMinSize = minSize }
            window.delegate = self
            window.center()
            if id == "main" { window.setFrameAutosaveName("WisprLocalMain") }
            windows[id] = window
        }
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func close(_ id: String) { windows[id]?.close() }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        if let key = windows.first(where: { $0.value === w })?.key {
            windows[key] = nil
            // History playback (and a re-transcription) never outlive the main window.
            if key == "main" { liveModel?.stopPlayback(); liveModel?.retranscription.cancel() }
        }
        if windows.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }
}
