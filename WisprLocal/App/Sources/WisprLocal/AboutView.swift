import SwiftUI
import WisprLocalCore

/// Standard About panel: icon, name, version, one line about open source, and Credits….
struct AboutView: View {
    @State private var showCredits: Bool

    init(showCredits: Bool = false) { _showCredits = State(initialValue: showCredits) }

    var body: some View {
        VStack(spacing: 0) {
            AppIconImage(size: 104).padding(.top, Theme.Space.xl)
            Text("WisprLocal").font(Theme.Typo.title.weight(.bold)).padding(.top, Theme.Space.snug)
            Text(versionLine).font(Theme.Typo.caption).foregroundStyle(.secondary).padding(.top, Theme.Space.hair)
            Text("Offline dictation for your Mac.").font(Theme.Typo.body).padding(.top, Theme.Space.ms)
            Text("Speech recognition powered by FluidAudio.").font(Theme.Typo.caption).foregroundStyle(.secondary).padding(.top, Theme.Space.hair)
            Button("Credits…") { showCredits = true }.padding(.top, Theme.Space.ms)
            Spacer(minLength: 12)
            Text("Independent app. Not affiliated with Wispr Flow.").font(Theme.Typo.footnote.weight(.regular)).foregroundStyle(.tertiary).padding(.bottom, Theme.Space.m)
        }
        .frame(width: 320, height: 380)
        .background(Theme.windowBackground)
        .sheet(isPresented: $showCredits) { CreditsView { showCredits = false } }
    }

    private var versionLine: String { AppVersion.display }
}

/// Credits sheet: ACKNOWLEDGEMENTS.md (incl. the CC-BY-4.0 model attribution) and every licence
/// shipped in Contents/Resources/Licenses, read from disk so it always matches what's bundled.
struct CreditsView: View {
    let close: () -> Void
    private let entries: [LicenseEntry] = LicenseCatalog.bundledLicensesURL.map(LicenseCatalog.entries(in:)) ?? []
    private let missing: [String] = {
        guard let m = LicenseCatalog.bundledModelsURL, let l = LicenseCatalog.bundledLicensesURL else { return [] }
        return LicenseCatalog.modelsMissingLicense(modelsDir: m, licensesDir: l)
    }()

    /// ACKNOWLEDGEMENTS.md (bundled by build_app.sh; repo copy in dev runs).
    static var acknowledgements: String? {
        if let s = LicenseCatalog.bundledLicensesURL.flatMap({ try? String(contentsOf: $0.appendingPathComponent("ACKNOWLEDGEMENTS.md"), encoding: .utf8) }) {
            return s
        }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("ACKNOWLEDGEMENTS.md")
        return try? String(contentsOf: repo, encoding: .utf8)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Credits").font(Theme.Typo.title)
            Text("FluidAudio by FluidInference powers speech recognition and speech detection. Models by NVIDIA, Moondream and the Silero Team, with Core ML conversions by FluidInference.")
                .font(Theme.Typo.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let ack = Self.acknowledgements {
                        CreditsMarkdown(blocks: MarkdownBlocks.parse(ack))
                    }
                    if !missing.isEmpty {
                        Label("Missing licence for bundled model(s): \(missing.joined(separator: ", "))", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.warning)
                    }
                    if !entries.isEmpty {
                        Text("Licences").font(Theme.Typo.bodyEmphasis)
                        ForEach(entries) { e in
                            DisclosureGroup(e.id) {
                                VStack(alignment: .leading, spacing: 8) {
                                    if let n = e.notice { Text(n).font(Theme.Typo.caption).textSelection(.enabled) }
                                    Text(e.license).font(Theme.Typo.mono).textSelection(.enabled)
                                    ForEach(e.extras.keys.sorted(), id: \.self) { k in
                                        DisclosureGroup(k) { Text(e.extras[k] ?? "").font(Theme.Typo.mono).textSelection(.enabled) }
                                    }
                                }
                            }
                        }
                    } else {
                        Text("Licence files are bundled in packaged builds (Contents/Resources/Licenses).")
                            .font(Theme.Typo.caption).foregroundStyle(.tertiary)
                    }
                }
                .padding(Theme.Space.s)
            }
            .background(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous).fill(Theme.inset))
            HStack { Spacer(); Button("Done", action: close).keyboardShortcut(.defaultAction) }
        }
        .padding(Theme.Space.ml)
        .frame(width: 560, height: 520)
        .background(Theme.windowBackground)
    }
}

/// Render blocks separately so headings, lists and tables retain their structure.
private struct CreditsMarkdown: View {
    let blocks: [MarkdownBlock]

    private func inline(_ text: String) -> Text {
        Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(blocks.indices, id: \.self) { index in
                switch blocks[index] {
                case .heading(let level, let text):
                    inline(text).font(level == 1 ? Theme.Typo.title : Theme.Typo.bodyEmphasis)
                        .accessibilityAddTraits(.isHeader)
                case .paragraph(let text):
                    inline(text).font(Theme.Typo.caption)
                case .code(let lines):
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(lines.indices, id: \.self) { line in
                            Text(lines[line].isEmpty ? " " : lines[line])
                        }
                    }.font(Theme.Typo.mono)
                case .bullets(let items):
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(items.indices, id: \.self) { row in
                            HStack(alignment: .top, spacing: 8) {
                                Text("•")
                                inline(items[row])
                            }
                        }
                    }.font(Theme.Typo.caption)
                case .table(let header, let rows):
                    Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 8) {
                        if !header.allSatisfy({ $0.isEmpty }) {
                            GridRow {
                                ForEach(header.indices, id: \.self) { column in
                                    inline(header[column]).fontWeight(.semibold)
                                }
                            }
                        }
                        ForEach(rows.indices, id: \.self) { row in
                            GridRow {
                                ForEach(rows[row].indices, id: \.self) { column in
                                    inline(rows[row][column])
                                }
                            }
                        }
                    }.font(Theme.Typo.caption)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
