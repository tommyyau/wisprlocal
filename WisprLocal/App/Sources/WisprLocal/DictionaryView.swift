import SwiftUI
import WisprLocalCore

/// Words + replacements. Saves as you go (empty rows are kept on screen but not written).
struct DictionaryView: View {
    let store: DictionaryStore
    /// Smart dictionary (nil in previews): the "Words learned" stat.
    var smart: SmartDictionaryController?
    /// Preview harness only (no smart dictionary): the "Words learned" count to draw.
    var previewLearned = 0
    @State private var dict: UserDictionary
    @State private var newTerm = ""
    @State private var error: String?

    init(store: DictionaryStore, smart: SmartDictionaryController? = nil, previewLearned: Int = 0) {
        self.store = store
        self.smart = smart
        self.previewLearned = previewLearned
        _dict = State(initialValue: store.dictionary)
    }

    var body: some View {
        Page(title: "Dictionary",
             subtitle: "Teach WisprLocal the names, jargon and spellings you use, so it gets them right the first time.",
             trailing: (smart?.learnedCount(in: dict) ?? previewLearned) > 0 ? AnyView(Text("\(smart?.learnedCount(in: dict) ?? previewLearned) learned from your corrections")
                .font(Theme.Typo.caption).foregroundStyle(.secondary)) : nil, info: .dictionary) {
            if let e = store.loadError ?? error {
                Label(e, systemImage: "exclamationmark.triangle.fill").font(Theme.Typo.caption).foregroundStyle(Theme.danger)
            }
            words
            replacements
        }
        .onAppear { dict = store.dictionary }
        .onChange(of: dict) { old, new in save(from: old, to: new) }
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ExplainerHeader(symbol: "textformat.abc", title: "Words",
                            text: "Spellings to keep exactly as written: product names, people, acronyms.",
                            example: ("Say “we deploy on kubernetes”", "We deploy on Kubernetes"))
            HStack(spacing: 8) {
                TextField("Add a word or name", text: $newTerm)
                    .textFieldStyle(.plain).padding(.horizontal, Theme.Space.snug).frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).fill(Theme.inset))
                    .onSubmit(addTerm)
                Button("Add", action: addTerm).buttonStyle(BrandButtonStyle())
                    .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if dict.vocabulary.isEmpty {
                Text("No words yet. Tip: in History, use ••• › Add Word to Dictionary on anything it misheard.")
                    .font(Theme.Typo.caption).foregroundStyle(.secondary)
            } else {
                ChipFlow(items: dict.vocabulary) { t in dict.vocabulary.removeAll { $0 == t } }
            }
        }
        .card()
    }

    private var replacements: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ExplainerHeader(symbol: "arrow.left.arrow.right", title: "Replacements",
                            text: "When WisprLocal hears one thing, write another. Great for words it keeps mishearing.",
                            example: ("Hears “cooper netties”", "Writes “Kubernetes”"))
            if !dict.replacements.isEmpty {
                HStack {
                    Text("WHEN IT HEARS").frame(maxWidth: .infinity, alignment: .leading)
                    Text("WRITE").frame(maxWidth: .infinity, alignment: .leading).padding(.leading, Theme.Space.l)
                    Text("MATCH CASE").frame(width: 76)
                    Spacer().frame(width: 22)
                }
                .font(Theme.Typo.eyebrow).foregroundStyle(.secondary)
            }
            ForEach($dict.replacements) { $rule in
                HStack(spacing: 8) {
                    field("heard", $rule.from)
                    Image(systemName: "arrow.right").font(Theme.Typo.symbol.weight(.semibold)).foregroundStyle(.tertiary)
                    field("written", $rule.to)
                    Toggle("Match case", isOn: Binding(get: { !rule.caseInsensitive }, set: { rule.caseInsensitive = !$0 }))
                        .toggleStyle(BrandSwitchStyle(small: true)).labelsHidden().frame(width: 76)
                        .environment(\.settingRowTitle, "Match case for \(rule.from)")
                        .help("Only match when the capitalisation is exactly the same")
                    Button { dict.replacements.removeAll { $0.id == rule.id } } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain).frame(width: 22).help("Remove")
                }
            }
            Button {
                dict.replacements.append(ReplacementRule(from: "", to: ""))
            } label: { Label("Add replacement", systemImage: "plus") }
            .buttonStyle(BrandButtonStyle(prominent: false))
        }
        .card()
    }

    private func field(_ placeholder: String, _ text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain).padding(.horizontal, Theme.Space.snug).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).fill(Theme.inset))
    }

    private func addTerm() {
        if dict.addTerm(newTerm) { newTerm = "" }
    }

    private func save(from old: UserDictionary, to new: UserDictionary) {
        let save = store.enqueueEditorChanges(from: old, to: new)
        Task {
            do { try await save.value; error = nil } catch { self.error = error.localizedDescription }
        }
    }
}

/// Spoken shortcuts: an atmospheric empty state, then a searchable, sortable list.
struct SnippetsView: View {
    let store: DictionaryStore
    @State private var dict: UserDictionary
    @State private var error: String?
    @State private var query = ""
    @State private var sort: SnippetSort = .newest

    enum SnippetSort: String, CaseIterable, Identifiable {
        case newest = "Newest first", oldest = "Oldest first", alphabetical = "A to Z"
        var id: String { rawValue }
    }

    init(store: DictionaryStore) {
        self.store = store
        _dict = State(initialValue: store.dictionary)
    }

    var body: some View {
        Page(title: "Snippets",
             subtitle: "Say a short phrase, get a whole block of text.",
             trailing: dict.snippets.isEmpty ? nil : AnyView(Button(action: add) {
                 Label("Add snippet", systemImage: "plus")
             }.buttonStyle(BrandButtonStyle())),
             info: .snippets) {
            if let e = store.loadError ?? error {
                Label(e, systemImage: "exclamationmark.triangle.fill").font(Theme.Typo.caption).foregroundStyle(Theme.danger)
            }
            if dict.snippets.isEmpty {
                SnippetsHero(add: add)
                tip
            } else {
                toolbar
                let shown = visibleIndices
                if shown.isEmpty {
                    Text("No snippets match “\(query)”.").font(Theme.Typo.body).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, Theme.Space.xl).card()
                }
                ForEach(shown, id: \.self) { i in editor($dict.snippets[i]) }
                tip
            }
        }
        .onAppear { dict = store.dictionary }
        .onChange(of: dict) { old, new in
            let save = store.enqueueEditorChanges(from: old, to: new)
            Task {
                do { try await save.value; error = nil } catch { self.error = error.localizedDescription }
            }
        }
    }

    private func add() {
        query = ""
        dict.snippets.append(Snippet(trigger: "", expansion: ""))
        if sort == .oldest { sort = .newest }
    }

    /// Indices into `dict.snippets`, filtered and sorted. A new, still-empty snippet always shows first.
    private var visibleIndices: [Int] {
        let q = query.trimmingCharacters(in: .whitespaces)
        var idx = Array(dict.snippets.indices)
        if !q.isEmpty {
            idx = idx.filter { dict.snippets[$0].trigger.localizedCaseInsensitiveContains(q)
                || dict.snippets[$0].expansion.localizedCaseInsensitiveContains(q) || dict.snippets[$0].trigger.isEmpty }
        }
        switch sort {
        case .newest: idx.reverse()
        case .oldest: break
        case .alphabetical:
            idx.sort { a, b in
                let ta = dict.snippets[a].trigger, tb = dict.snippets[b].trigger
                if ta.isEmpty != tb.isEmpty { return ta.isEmpty }
                return ta.localizedCaseInsensitiveCompare(tb) == .orderedAscending
            }
        }
        return idx
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search snippets", text: $query).textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain)
                }
            }
            .font(Theme.Typo.body)
            .padding(.horizontal, Theme.Space.s).frame(height: 34)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous).strokeBorder(Theme.cardBorder))
            Menu {
                Picker("Sort", selection: $sort) {
                    ForEach(SnippetSort.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.arrow.down").font(Theme.Typo.symbol.weight(.semibold))
                    Text(sort.rawValue)
                }
                .font(Theme.Typo.chip)
                .padding(.horizontal, Theme.Space.s).frame(height: 34)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous).strokeBorder(Theme.cardBorder))
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Sort snippets")
            Text("\(dict.snippets.count) \(dict.snippets.count == 1 ? "snippet" : "snippets")")
                .font(Theme.Typo.caption).foregroundStyle(.secondary).fixedSize()
        }
    }

    private var tip: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lightbulb").foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text("Say the trigger on its own").font(Theme.Typo.bodyEmphasis)
                Text("Hold 🌐 and say just “my email” (or “insert my email”). Snippets never fire in the middle of a sentence, so you can still say those words normally.")
                    .font(Theme.Typo.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Theme.Space.xxs)
    }

    private func editor(_ sn: Binding<Snippet>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "waveform").foregroundStyle(Theme.accent).font(Theme.Typo.chip.weight(.semibold))
                Text("WHEN YOU SAY").font(Theme.Typo.eyebrow).foregroundStyle(.secondary)
                TextField("e.g. my email", text: sn.trigger)
                    .textFieldStyle(.plain).font(Theme.Typo.bodyEmphasis)
                    .padding(.horizontal, Theme.Space.snug).frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).fill(Theme.inset))
                Button { let id = sn.wrappedValue.id; dict.snippets.removeAll { $0.id == id } } label: {
                    Image(systemName: "trash").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain).help("Delete snippet")
            }
            Text("TYPE THIS").font(Theme.Typo.eyebrow).foregroundStyle(.secondary)
            TextEditor(text: sn.expansion)
                .font(Theme.Typo.body).scrollContentBackground(.hidden)
                .padding(Theme.Space.tight).frame(minHeight: 54, maxHeight: 120)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).fill(Theme.inset))
        }
        .card()
    }
}

/// The Snippets empty state: indigo glass, an orb glow, the wave, and three examples.
struct SnippetsHero: View {
    let add: () -> Void
    static let examples: [(String, String)] = [
        ("my email", "name@example.com"),
        ("my address", "1 Example Street, Springfield"),
        ("standup", "Yesterday: … Today: … Blockers: …"),
    ]

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous).fill(Theme.heroGradient)
            // Orb glow, top right.
            Circle().fill(RadialGradient(colors: [Theme.violetGlow.opacity(0.55), .clear], center: .center, startRadius: 0, endRadius: 190))
                .frame(width: 380, height: 380).offset(x: 260, y: -150).blur(radius: 10)
            Circle().fill(RadialGradient(colors: [Theme.mint.opacity(0.10), .clear], center: .center, startRadius: 0, endRadius: 150))
                .frame(width: 300, height: 300).offset(x: -280, y: 170)
            WaveMotif(bars: 52, barWidth: 3.5, gap: 8, maxHeight: 70, intensity: 0.8, time: 3.2)
                .edgeFade().opacity(0.14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .offset(y: 30)
            VStack(spacing: 16) {
                Orb(size: 64, time: 1.6).padding(.bottom, Theme.Space.xxs)
                Text("Say it once. Paste it forever.")
                    .font(Theme.Typo.heroHeadline)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Text("Save text you use often, then say a short phrase to drop it in.")
                    .font(Theme.Typo.lead).foregroundStyle(.white.opacity(0.72))
                    .multilineTextAlignment(.center)
                VStack(spacing: 8) {
                    ForEach(Self.examples, id: \.0) { ex in chip(ex.0, ex.1) }
                }
                .padding(.top, Theme.Space.tight)
                Button(action: add) { Label("Add snippet", systemImage: "plus") }
                    .buttonStyle(BrandButtonStyle())
                    .padding(.top, Theme.Space.xs)
            }
            .padding(.vertical, Theme.Space.xxl).padding(.horizontal, Theme.Space.xl)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .shadow(color: Theme.indigo.opacity(0.25), radius: 16, y: 8)
        .environment(\.colorScheme, .dark)
    }

    private func chip(_ trigger: String, _ expansion: String) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "waveform").font(Theme.Typo.micro).foregroundStyle(Theme.mint)
                Text("“\(trigger)”").font(Theme.Typo.chip.weight(.semibold))
            }
            .foregroundStyle(.white)
            Image(systemName: "arrow.right").font(Theme.Typo.micro).foregroundStyle(.white.opacity(0.4))
            Text(expansion).font(Theme.Typo.chip.weight(.regular)).foregroundStyle(.white.opacity(0.78)).lineLimit(1)
        }
        .padding(.horizontal, Theme.Space.ms).frame(height: 32)
        .background(Capsule().fill(.white.opacity(0.07)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
    }
}

struct ExplainerHeader: View {
    let symbol: String
    let title: String
    let text: String
    var example: (String, String)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(Theme.Typo.symbolLarge).foregroundStyle(Theme.accent)
                .frame(width: 30, height: 30).background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).fill(Theme.accentSoft))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.Typo.title)
                Text(text).font(Theme.Typo.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let example {
                    HStack(spacing: 6) {
                        Text(example.0).foregroundStyle(.secondary)
                        Image(systemName: "arrow.right").font(Theme.Typo.micro).foregroundStyle(.tertiary)
                        Text(example.1).foregroundStyle(Theme.accent).fontWeight(.medium)
                    }
                    .font(Theme.Typo.caption)
                    .padding(.horizontal, Theme.Space.xs).padding(.vertical, Theme.Space.xxs)
                    .background(Capsule().fill(Theme.inset))
                    .padding(.top, Theme.Space.xxs)
                }
            }
        }
    }
}

struct ChipFlow: View {
    let items: [String]
    let remove: (String) -> Void
    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { t in
                HStack(spacing: 5) {
                    Text(t).font(Theme.Typo.bodyEmphasis).fixedSize(horizontal: false, vertical: true)
                    Button { remove(t) } label: { Image(systemName: "xmark").font(Theme.Typo.micro).foregroundStyle(.secondary) }
                        .buttonStyle(.plain).help("Remove \(t)")
                }
                .padding(.leading, Theme.Space.snug).padding(.trailing, Theme.Space.xs)
                .padding(.vertical, Theme.Space.xxs).frame(minHeight: 26)
                // A rounded rectangle, not a `Capsule`: a capsule's hairline renders with flat,
                // clipped-looking ends at this height (same fix as the Fix a Word sheet).
                .background(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous).fill(Theme.accentSoft))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous).strokeBorder(Theme.accent.opacity(0.18)))
            }
        }
        .padding(Theme.Space.xxs)  // room for the chips' hairlines at the edges
    }
}

/// Wrapping row layout (chips).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, width: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(ProposedViewSize(width: maxW, height: nil))
            if x > 0, x + sz.width > maxW { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing; rowH = max(rowH, sz.height); width = max(width, x - spacing)
        }
        return CGSize(width: proposal.width ?? width, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            if x > bounds.minX, x + sz.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
    }
}
