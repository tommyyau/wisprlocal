import Combine
import SwiftUI
import WisprLocalCore

/// The single main window: sidebar + one page per section.
struct MainWindowView: View {
    @Bindable var model: AppModel
    var animate = true
    /// `--ui-preview` only: a drawn sidebar (offscreen capture can't sample the Liquid Glass one).
    var simulatedSidebar = false
    var helpTab: HelpView.Tab = .howTo
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if simulatedSidebar {
                HStack(spacing: 0) {
                    Sidebar(model: model, simulated: true).frame(width: 214)
                        .background(Theme.sidebarSimulated)
                    Rectangle().fill(Theme.cardBorder).frame(width: 0.5)
                    detail.frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.windowBackground)
                }
            } else {
                splitView
            }
        }
        .tint(Theme.accent)
        .onAppear { model.refreshDevices(); model.refreshSystemState() }
        .onReceive(timer) { _ in if model.live != nil { model.refreshSystemState() } }
        .onChange(of: model.live?.settings.historyDirectory) { model.observeHistory() }
    }

    private var splitView: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 214, max: 260)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.windowBackground)
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder private var detail: some View {
        switch model.section {
        case .home: HomeView(model: model, animate: animate)
        case .insights: InsightsView(model: model)
        case .history: HistoryView(model: model)
        case .dictionary: DictionaryView(store: model.dictionary, smart: model.live?.smart, previewLearned: model.sample.learnedWords)
        case .snippets: SnippetsView(store: model.dictionary)
        case .settings: SettingsView(model: model)
        case .help: HelpView(model: model, tab: helpTab, expandAll: !animate)
        }
    }
}

struct Sidebar: View {
    @Bindable var model: AppModel
    var simulated = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Orb(size: 28, time: 1.2)
                Text("WisprLocal").font(Theme.Typo.wordmark)
            }
            .padding(.horizontal, Theme.Space.ml).padding(.top, Theme.Space.xs).padding(.bottom, Theme.Space.ms)

            if simulated {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach([MainSection.home, .insights, .history, .dictionary, .snippets]) { simulatedRow($0) }
                    Spacer().frame(height: 14)
                    ForEach([MainSection.settings, .help]) { simulatedRow($0) }
                    Spacer()
                }
                .padding(.horizontal, Theme.Space.snug)
            } else {
                List(selection: Binding(get: { model.section }, set: { if let s = $0 { model.section = s } })) {
                    Section {
                        ForEach([MainSection.home, .insights, .history, .dictionary, .snippets]) { row($0) }
                    }
                    Section {
                        ForEach([MainSection.settings, .help]) { row($0) }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }

            statusFooter
        }
    }

    private func row(_ s: MainSection) -> some View {
        Label {
            HStack {
                Text(s.title)
                Spacer()
                if s == .settings, model.setupIssues.contains(where: { $0.hasAction }) {
                    Circle().fill(Theme.warning).frame(width: 7, height: 7).accessibilityLabel("Needs attention")
                } else if s == .settings, model.setupIssues.contains(.modelPreparing) {
                    ProgressView().controlSize(.small).accessibilityLabel("Preparing the speech model")
                }
            }
        } icon: { Image(systemName: s.symbol) }
        .tag(s)
    }

    private func simulatedRow(_ s: MainSection) -> some View {
        let on = model.section == s
        return HStack(spacing: 8) {
            Image(systemName: s.symbol).font(Theme.Typo.body).foregroundStyle(on ? Theme.accent : .secondary).frame(width: 20)
            Text(s.title).font(Theme.Typo.body.weight(on ? .semibold : .regular))
            Spacer()
            if s == .settings, model.setupIssues.contains(where: { $0.hasAction }) {
                Circle().fill(Theme.warning).frame(width: 7, height: 7)
            } else if s == .settings, model.setupIssues.contains(.modelPreparing) {
                ProgressView().controlSize(.small).accessibilityLabel("Preparing the speech model")
            }
        }
        .padding(.horizontal, Theme.Space.xs).frame(height: 30)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).fill(on ? Theme.accentSoft : .clear))
    }

    private var statusFooter: some View {
        let r = model.readiness
        return Button {
            model.section = r.ok ? .home : .settings
            if !r.ok { model.settingsRequest = .setup }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                if !r.ok && !model.setupIssues.contains(where: { $0.hasAction }) {
                    ProgressView().controlSize(.small)
                } else {
                    Circle().fill(r.ok ? Theme.positive : Theme.warning).frame(width: 7, height: 7)
                        .padding(.top, Theme.Space.xxs)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.ok ? "Ready" : model.setupIssues.contains(where: { $0.hasAction }) ? "Needs attention" : "Preparing…")
                        .font(Theme.Typo.chip.weight(.semibold))
                    Text(r.ok ? "Hold 🌐 to dictate" : model.setupIssues.contains(where: { $0.hasAction }) ? "Open Settings to fix" : "Preparing the speech model")
                        .font(Theme.Typo.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(Theme.Space.snug)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous).fill(.quaternary.opacity(0.5)))
        }
        .buttonStyle(.plain)
        .padding(Theme.Space.s)
    }
}
