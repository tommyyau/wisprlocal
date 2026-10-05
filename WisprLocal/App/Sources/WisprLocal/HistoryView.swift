import SwiftUI
import WisprLocalCore

struct HistoryView: View {
    let model: AppModel
    @State private var query = ""
    @State private var paging = false
    @State private var searchHasMore = false
    @State private var confirmClear = false
    @State private var adding: HistoryEntry?
    @State private var showRaw: Set<UUID> = []
    @State private var detail: HistoryEntry?
    @State private var fixing: HistoryEntry?

    var body: some View {
        let groups = query.trimmingCharacters(in: .whitespaces).isEmpty ? model.historyGroups.map { (title: $0.title, entries: $0.entries) } : DayGrouping.groups(model.historySearchPage.entries, now: model.now)
        Page(title: "History",
             subtitle: "Every dictation, kept only on this Mac. Replay it, copy it again, or teach WisprLocal a word it got wrong.",
             trailing: AnyView(clearButton)) {
            if !model.historyRemovalFailures.isEmpty {
                HStack {
                    Text("Couldn't remove \(model.historyRemovalFailures.count) \(model.historyRemovalFailures.count == 1 ? "dictation" : "dictations") from disk")
                    Button("Retry") { model.retryHistoryRemoval() }
                }.font(Theme.Typo.caption).foregroundStyle(Theme.danger)
            }
            if HistoryPlayback.showsRecordingsOffBanner(recordingOn: model.settings.keepDebugRecordings) {
                RecordingsOffBanner(settings: model.settings).padding(.bottom, Theme.Space.l)
            }
            searchField.padding(.bottom, Theme.Space.l)
            if model.timeline.isEmpty {
                empty(symbol: "clock", title: "No dictations yet",
                      text: "Hold 🌐 in any app and speak. Everything you dictate appears here, newest first.")
            } else if groups.isEmpty {
                empty(symbol: "magnifyingglass", title: "No matches", text: "Nothing you've dictated contains “\(query)”.")
            } else {
                ForEach(HistoryRows(groups: groups)) { item in
                    if let title = item.title {
                        Text(title.uppercased()).font(Theme.Typo.groupHeader).kerning(0.8)
                            .foregroundStyle(.secondary).padding(.leading, Theme.Space.xxs).padding(.bottom, Theme.Space.xs)
                    } else if let e = item.entry {
                        HistoryCardSlice(first: item.first, last: item.last) {
                            DictationRow(model: model, entry: e, isDictating: model.clipIDs.contains(e.id) && model.isDictating,
                                         isPlaying: model.playback.isPlaying(e.id), hasClip: model.clipIDs.contains(e.id),
                                         previewHovered: model.previewHoverID == e.id, showRaw: showRaw.contains(e.id),
                                         toggleRaw: { toggle(e) }, addWord: { adding = e }, showDetails: { if model.canOpenHistory(e.id) { detail = e } },
                                         fixWord: { fixing = e }).equatable()
                        }
                        .onAppear { if item.last && item.lastGroup { loadNextPage() } }
                    }
                }
            }
        }.historyLazy()
        .task(id: "\(query)-\(model.historyRevision)") {
            guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            let result = await model.searchHistory(query: query)
            guard !Task.isCancelled else { return }
            searchHasMore = result.hasMore
        }
        .confirmationDialog("Clear all history?", isPresented: $confirmClear) {
            Button("Clear All History", role: .destructive) { model.clearHistory() }
        } message: {
            Text("This permanently removes every dictation from this Mac. Your dictionary and snippets stay.")
        }
        .sheet(item: Binding(get: { adding.map(IdentifiedEntry.init) }, set: { adding = $0?.entry })) { item in
            AddToDictionarySheet(store: model.dictionary, entry: item.entry) { adding = nil }
        }
        .sheet(item: $detail) { e in
            HistoryDetailView(model: model, entry: e) { detail = nil }
        }
        .sheet(item: Binding(get: { fixing.map(IdentifiedEntry.init) }, set: { fixing = $0?.entry })) { item in
            FixWordSheet(model: model, entry: item.entry) { fixing = nil }
        }
        .onAppear(perform: openRequestedDetail)
        .onChange(of: model.historyDetailRequest) { openRequestedDetail() }
        .onChange(of: model.historyRevision) {
            if let e = detail, !model.canOpenHistory(e.id) { detail = nil }
            if let e = adding, !model.canOpenHistory(e.id) { adding = nil }
            if let e = fixing, !model.canOpenHistory(e.id) { fixing = nil }
            openRequestedDetail()
        }
    }

    private func loadNextPage() {
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        guard (searching ? searchHasMore : model.historyHasMore), !paging else { return }
        paging = true
        Task {
            if searching {
                let result = await model.searchHistory(query: query, more: true)
                searchHasMore = result.hasMore
            } else { await model.historyPage(more: true) }
            paging = false
        }
    }

    /// HUD "See why": show that entry's details once it is in the list.
    private func openRequestedDetail() {
        guard let id = model.historyDetailRequest, model.canOpenHistory(id) else { return }
        guard let e = model.entries.last(where: { $0.id == id }) else { return }
        model.historyDetailRequest = nil
        detail = e
    }

    private func toggle(_ e: HistoryEntry) {
        if showRaw.contains(e.id) { showRaw.remove(e.id) } else { showRaw.insert(e.id) }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search your dictations", text: $query).textFieldStyle(.plain)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain)
            }
        }
        .font(Theme.Typo.body)
        .padding(.horizontal, Theme.Space.s).frame(height: 34)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous).strokeBorder(Theme.cardBorder))
    }

    private var clearButton: some View {
        Button("Clear All…", role: .destructive) { confirmClear = true }
            .buttonStyle(BrandButtonStyle(prominent: false))
            .disabled(model.timeline.isEmpty)
    }

    private func empty(symbol: String, title: String, text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(Theme.Typo.iconLarge).foregroundStyle(Theme.accent)
                .frame(width: 56, height: 56).background(Circle().fill(Theme.accentSoft))
            Text(title).font(Theme.Typo.title)
            Text(text).font(Theme.Typo.body).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity).padding(.vertical, Theme.Space.xxl)
        .card()
    }
}

struct IdentifiedEntry: Identifiable {
    let entry: HistoryEntry
    var id: UUID { entry.id }
}

/// From a History row: keep a spelling, or also fix what was heard.
struct AddToDictionarySheet: View {
    let store: DictionaryStore
    let entry: HistoryEntry
    let done: () -> Void
    @State private var term = ""
    @State private var heard = ""
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add to Dictionary").font(Theme.Typo.title)
            Text(entry.final).font(Theme.Typo.caption).foregroundStyle(.secondary).lineLimit(3)
                .padding(Theme.Space.snug).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).fill(Theme.inset))
            VStack(alignment: .leading, spacing: 4) {
                Text("Correct spelling").font(Theme.Typo.bodyEmphasis)
                TextField("e.g. Kubernetes", text: $term).textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("What it heard instead (optional)").font(Theme.Typo.bodyEmphasis)
                TextField("e.g. cooper netties", text: $heard).textFieldStyle(.roundedBorder)
                Text("Fill this in and WisprLocal will also swap the misheard words for your spelling.")
                    .font(Theme.Typo.caption).foregroundStyle(.secondary)
            }
            if let m = message { Text(m).font(Theme.Typo.caption).foregroundStyle(Theme.danger) }
            HStack {
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button(trimmed(heard).isEmpty ? "Add Word" : "Add Word & Fix") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed(term).isEmpty)
            }
        }
        .padding(Theme.Space.l)
        .frame(width: 440)
    }

    private func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces) }

    func apply() {
        let old = store.dictionary
        var d = old
        d.addTerm(term)
        if !trimmed(heard).isEmpty { d.addReplacement(from: heard, to: term) }
        let save = store.enqueueEditorChanges(from: old, to: d)
        Task {
            do { try await save.value; done() } catch { message = error.localizedDescription }
        }
    }
}

/// Slim banner while recordings are OFF: replay needs them. The toggle turns them back on.
struct RecordingsOffBanner: View {
    let settings: AppSettings
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.slash").font(Theme.Typo.chip).foregroundStyle(.secondary)
            Text(HistoryPlayback.recordingsOffBannerText).font(Theme.Typo.caption.weight(.medium))
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(get: { settings.keepDebugRecordings }, set: { settings.keepDebugRecordings = $0 }))
                .toggleStyle(BrandSwitchStyle(small: true)).labelsHidden()
                .accessibilityLabel(AppSettings.keepRecordingsLabel)
        }
        .padding(.horizontal, Theme.Space.s).frame(height: 36)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous).fill(Theme.accentSoft.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous).strokeBorder(Theme.accent.opacity(0.18)))
    }
}

private extension Page {
    func historyLazy() -> Self { var page = self; page.lazy = true; return page }
}
