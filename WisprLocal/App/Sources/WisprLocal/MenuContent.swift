import SwiftUI
import WisprLocalCore

/// Menu bar menu, rendered from `MenuModel.entries` (the DEBUG preview mocks the same entries):
/// an attention row only when something isn't normal, Open Dashboard, Settings, the Noisy Room
/// checkmark with its subtitle, Help, Quit. Everything else lives in Settings.
struct MenuContent: View {
    let controller: AppController

    var body: some View {
        let entries = MenuModel.entries(controller.menuSnapshot, noisyRoom: controller.settings.noisyRoomMode)
        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
            item(entry)
        }
    }

    @ViewBuilder private func item(_ entry: MenuEntry) -> some View {
        switch entry {
        case .attention(let a):
            if let action = a.action {
                Button(a.label) { perform(action) }
            } else {
                Button(a.label) {}.disabled(true)
            }
        case .noisyRoom:
            Toggle(isOn: Binding(get: { controller.settings.noisyRoomMode },
                                 set: { controller.setNoisyRoom($0) })) {
                Text(entry.title)
                Text(MenuModel.noisyRoomSubtitle)
            }
        case .openApp:
            Button(entry.title) { WindowManager.shared.showMain(controller: controller, section: .home) }
        case .settings:
            Button(entry.title) { WindowManager.shared.showMain(controller: controller, section: .settings) }
                .keyboardShortcut(",")
        case .help(let items):
            Menu(entry.title) {
                ForEach(items, id: \.self) { h in Button(h.title) { help(h) } }
            }
        case .quit:
            Button(entry.title) { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        case .separator:
            Divider()
        }
    }

    private func perform(_ action: MenuAttention.Action) {
        switch action {
        case .openSetup:
            WindowManager.shared.model(for: controller).settingsRequest = .setup
            WindowManager.shared.showMain(controller: controller, section: .settings)
        case .useAnyway: controller.useWisprLocalAnyway()
        case .retryModel: controller.retryModelPreparation()
        case .stopMic: controller.warmMic.stopNow()
        case .showIndicator: controller.conveniences.showIndicator()
        }
    }

    private func help(_ h: MenuEntry.HelpItem) {
        switch h {
        case .helpAndFAQ: WindowManager.shared.showMain(controller: controller, section: .help, helpTab: .why)
        case .gettingStarted:
            WindowManager.shared.showMain(controller: controller, section: .home)
            WindowManager.shared.model(for: controller).reopenGettingStarted()
        case .credits: WindowManager.shared.showCredits()
        case .about: WindowManager.shared.showAbout()
        }
    }
}
