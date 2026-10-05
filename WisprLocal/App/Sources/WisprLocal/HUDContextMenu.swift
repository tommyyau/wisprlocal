import AppKit
import WisprLocalCore

/// The pill's right-click menu ("Hide Indicator for 1 Hour"). The HUD window is click-through,
/// so it accepts mouse events only while the pointer is over the pill itself (`pillRect`):
/// everything around the pill keeps passing clicks to the app underneath.
@MainActor
enum HUDContextMenu {
    static let hideIndicatorTitle = "Hide Indicator for 1 Hour"

    /// The pill's frame in screen coordinates, for a window at `windowFrame` showing `state`.
    static func pillRect(windowFrame: CGRect, state: HUDState, alignment: HUDAlignment) -> CGRect {
        let size = HUDAnimator.targetSize(for: state)
        let W = HUDController.windowSize.width, inset = HUDController.sideInset
        let x: CGFloat = switch alignment {
        case .center: W / 2
        case .leading: inset + size.width / 2
        case .trailing: W - inset - size.width / 2
        }
        return CGRect(x: windowFrame.minX + x - size.width / 2,
                      y: windowFrame.minY + HUDController.pillCentreFromBottom - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// Retained while the menu is open (NSMenuItem holds its target weakly).
    private static var target: MenuTarget?

    static func show(with event: NSEvent, in view: NSView, hide: @escaping @MainActor () -> Void) {
        let menu = NSMenu()
        let t = MenuTarget(action: hide)
        target = t
        let item = NSMenuItem(title: hideIndicatorTitle, action: #selector(MenuTarget.run), keyEquivalent: "")
        item.target = t
        menu.addItem(item)
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    @MainActor private final class MenuTarget: NSObject {
        let action: @MainActor () -> Void
        init(action: @escaping @MainActor () -> Void) { self.action = action }
        @objc func run() { action() }
    }
}
