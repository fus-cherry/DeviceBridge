import Foundation

public struct Redactor: Sendable {
    public init() {}

    public func redact(_ text: String, secrets: [String] = []) -> String {
        var result = text

        for secret in secrets
            .filter({ !$0.isEmpty })
            .sorted(by: { $0.count > $1.count }) {
            result = result.replacingOccurrences(of: secret, with: "<redacted>")
        }

        result = replacingMatches(
            in: result,
            pattern: #"(?i)\b(?:https?|wss?)://(?:127\.0\.0\.1|localhost):[0-9]+/[^\s]+"#,
            template: "<redacted-vm-uri>"
        )
        result = replacingMatches(
            in: result,
            pattern: #"(?m)^(clipboardText=).*$"#,
            template: "$1<redacted>"
        )
        return result
    }

    private func replacingMatches(
        in text: String,
        pattern: String,
        template: String
    ) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: template
        )
    }
}
