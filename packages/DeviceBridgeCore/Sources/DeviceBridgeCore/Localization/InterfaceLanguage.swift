import Foundation

public enum InterfaceLanguage: String, CaseIterable, Sendable {
    case system
    case chinese = "zh-Hans"
    case english = "en"

    public init(storedValue: String) { self = Self(rawValue: storedValue) ?? .system }

    public func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> Self {
        guard self == .system else { return self }
        return preferredLanguages.first?.lowercased().hasPrefix("zh") == true ? .chinese : .english
    }

    public var locale: Locale { Locale(identifier: resolved().rawValue) }

    /// Presentation-only lookup. Never pass device payloads or identifiers here.
    public func text(_ key: String) -> String {
        resolved() == .chinese ? (Self.chineseCatalog[key] ?? key) : key
    }

    static let chineseCatalog: [String: String] = {
        guard let url = Bundle.module.url(forResource: "zh-Hans", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return catalog
    }()
}

/// Keeps asynchronous feedback language-neutral until the current view renders it.
public struct InterfaceMessage: Sendable, Equatable, ExpressibleByStringLiteral {
    public let key: String
    public let arguments: [String]
    public init(_ key: String, arguments: [String] = []) { self.key = key; self.arguments = arguments }
    public init(stringLiteral value: String) { self.init(value) }

    public func render(in language: InterfaceLanguage) -> String {
        let template = language.text(key)
        // Replace only placeholders in the template, never placeholders inside argument data.
        let regex = try! NSRegularExpression(pattern: "\\{([0-9]+)\\}")
        let source = template as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: template, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            if let index = Int(source.substring(with: match.range(at: 1))), arguments.indices.contains(index) {
                result += arguments[index]
            } else {
                result += source.substring(with: match.range)
            }
            cursor = NSMaxRange(match.range)
        }
        return result + source.substring(from: cursor)
    }
}
