import Foundation

public enum CleanupLevel: String, Codable, CaseIterable, Sendable, Identifiable {
    case verbatim, light, medium
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

/// Ephemeral local hints. Never written to logs or History. All fields are untrusted data.
public struct CleanupContext: Sendable, Equatable {
    public var category: String?
    public var style: String?
    public var preceding: String?
    public var spellings: [String]
    public init(category: String? = nil, style: String? = nil, preceding: String? = nil, spellings: [String] = []) {
        self.category = category; self.style = style
        self.preceding = preceding.map { String($0.suffix(300)) }
        self.spellings = Array(spellings.prefix(50)).map { String($0.prefix(64)) }
    }
}
