import SwiftUI
import WisprLocalCore

/// Accessibility / Input Monitoring status with exact steps, deep links and Relaunch.
/// Shown in onboarding and Settings; hidden when everything is healthy.
struct PermissionHealthView: View {
    let controller: AppController

    var body: some View {
        let health = controller.permissions.health
        if !health.isReady {
            VStack(alignment: .leading, spacing: 8) {
                Label(health.headline, systemImage: symbol(health))
                    .font(.headline)
                    .foregroundStyle(health == .stalePermission ? .orange : .primary)
                ForEach(Array(health.instructions.enumerated()), id: \.offset) { i, step in
                    Text("\(i + 1). \(step)").font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    ForEach(settingsTargets(health)) { p in
                        Button("Open \(p.title) Settings") { p.openSettings() }
                    }
                    Spacer()
                    if health.offersRelaunch {
                        Button("Relaunch WisprLocal") { controller.relaunch() }.keyboardShortcut(.defaultAction)
                    }
                }
                Text("Checked every 2 seconds until everything is granted, then every 10 seconds. A toggle that shows ON while the Globe key does nothing means macOS is holding the grant for an older build: remove WisprLocal with − and add it again.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func settingsTargets(_ h: PermissionHealth) -> [Permission] {
        if case .missing(let ps) = h { return ps }
        return Permission.tapPermissions
    }

    private func symbol(_ h: PermissionHealth) -> String {
        switch h {
        case .missing: "hand.raised.fill"
        case .needsRelaunch: "arrow.clockwise.circle.fill"
        case .stalePermission: "exclamationmark.triangle.fill"
        case .ready: "checkmark.circle.fill"
        }
    }
}
