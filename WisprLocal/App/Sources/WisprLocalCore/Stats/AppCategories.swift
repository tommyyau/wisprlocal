import Foundation

/// Where a dictation landed, by the kind of app that was frontmost (Insights › "Where you dictate").
public enum AppCategory: String, CaseIterable, Sendable, Codable {
    case ai, code, messages, email, docs, browser, other

    public var title: String {
        switch self {
        case .ai: "AI tools"
        case .code: "Code"
        case .messages: "Messages"
        case .email: "Email"
        case .docs: "Docs & notes"
        case .browser: "Browser"
        case .other: "Other"
        }
    }

    /// SF Symbol for the category.
    public var symbol: String {
        switch self {
        case .ai: "sparkles"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .messages: "bubble.left.and.bubble.right"
        case .email: "envelope"
        case .docs: "doc.text"
        case .browser: "globe"
        case .other: "square.grid.2x2"
        }
    }
}

/// Bundle ID → category. A small, editable table: add an app by adding one line below. Exact IDs
/// win over prefixes; anything unknown is `.other`. Callers may pass `overrides` on top.
public enum AppCategoryMap {
    public static let exact: [String: AppCategory] = [
        // AI tools
        "com.anthropic.claudefordesktop": .ai,
        "com.openai.chat": .ai,
        "com.openai.codex": .ai,
        "ai.perplexity.mac": .ai,
        "com.google.GeminiMacOS": .ai,
        "com.todesktop.230313mzl4w4u92": .ai,     // Cursor (chat-first editor)
        "com.exafunction.windsurf": .ai,
        // Code
        "com.apple.dt.Xcode": .code,
        "com.microsoft.VSCode": .code,
        "com.microsoft.VSCodeInsiders": .code,
        "com.apple.Terminal": .code,
        "com.googlecode.iterm2": .code,
        "dev.warp.Warp-Stable": .code,
        "com.mitchellh.ghostty": .code,
        "dev.zed.Zed": .code,
        "com.sublimetext.4": .code,
        "com.github.GitHubClient": .code,
        // Messages
        "com.tinyspeck.slackmacgap": .messages,
        "com.apple.MobileSMS": .messages,
        "net.whatsapp.WhatsApp": .messages,
        "desktop.WhatsApp": .messages,
        "com.microsoft.teams2": .messages,
        "com.microsoft.teams": .messages,
        "ru.keepcoder.Telegram": .messages,
        "com.hnc.Discord": .messages,
        "org.whispersystems.signal-desktop": .messages,
        // Email
        "com.apple.mail": .email,
        "com.microsoft.Outlook": .email,
        "com.readdle.smartemail-Mac": .email,
        "com.superhuman.electron": .email,
        // Docs & notes
        "com.apple.Notes": .docs,
        "com.apple.iWork.Pages": .docs,
        "com.apple.iWork.Keynote": .docs,
        "com.microsoft.Word": .docs,
        "com.microsoft.Powerpoint": .docs,
        "com.apple.TextEdit": .docs,
        "notion.id": .docs,
        "md.obsidian": .docs,
        "net.shinyfrog.bear": .docs,
        "com.apple.reminders": .docs,
        // Browsers
        "com.apple.Safari": .browser,
        "com.google.Chrome": .browser,
        "org.mozilla.firefox": .browser,
        "company.thebrowser.Browser": .browser,
        "com.microsoft.edgemac": .browser,
        "com.brave.Browser": .browser,
        "com.operasoftware.Opera": .browser,
        "app.zen-browser.zen": .browser,
    ]

    /// Families of apps that share a prefix (JetBrains IDEs, browser channels).
    public static let prefixes: [(String, AppCategory)] = [
        ("com.jetbrains.", .code),
        ("com.google.Chrome.", .browser),
        ("com.apple.SafariTechnologyPreview", .browser),
    ]

    public static func category(for bundleID: String?, overrides: [String: AppCategory] = [:]) -> AppCategory {
        guard let id = bundleID, !id.isEmpty else { return .other }
        if let c = overrides[id] ?? exact[id] { return c }
        for (p, c) in prefixes where id.hasPrefix(p) { return c }
        return .other
    }
}
