import Foundation

/// Converts task descriptions into an `AttributedString` with tappable links
/// for inline markdown links (`[label](url)`), bare URLs, and phone numbers.
/// Other markdown syntax (`*`, `_`, backticks, etc.) is left untouched.
public enum DescriptionLinks {
    public static func linkified(_ text: String) -> AttributedString {
        guard !text.isEmpty else { return AttributedString() }

        // Matches `[label](destination)` where `label` does not contain brackets or
        // newlines and `destination` allows one level of balanced parentheses.
        let markdownLinkPattern = #/\[([^\[\]\n]+)\]\(((?:[^\s\n()]|\([^\s\n()]*\))+)\)/#
        let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
                | NSTextCheckingResult.CheckingType.phoneNumber.rawValue
        )

        var result = AttributedString()
        var plainStart = text.startIndex

        for match in text.matches(of: markdownLinkPattern) {
            let label = String(match.output.1)
            let rawURL = String(match.output.2)
            guard let url = validLinkURL(rawURL) else { continue }

            if plainStart < match.range.lowerBound {
                result.append(detectLinks(in: String(text[plainStart..<match.range.lowerBound]), using: detector))
            }
            var linkRun = AttributedString(label)
            linkRun.link = url
            result.append(linkRun)
            plainStart = match.range.upperBound
        }

        if plainStart < text.endIndex {
            result.append(detectLinks(in: String(text[plainStart..<text.endIndex]), using: detector))
        }

        return result
    }

    private static func validLinkURL(_ raw: String) -> URL? {
        guard let url = parseURL(raw),
              let scheme = url.scheme?.lowercased(),
              !scheme.isEmpty else { return nil }
        switch scheme {
        case "http", "https":
            guard let host = url.host(), !host.isEmpty else { return nil }
            return url
        case "tel", "mailto", "maps":
            guard raw.count > scheme.count + 1 else { return nil }
            return url
        default:
            return nil
        }
    }

    /// Parses a URL string while encoding non-ASCII / invalid characters without
    /// double-encoding already valid `%XX` escape sequences (which `URL(string:)`
    /// does when a URL mixes `%20` with unencoded CJK characters).
    private static func parseURL(_ raw: String) -> URL? {
        if let url = URL(string: raw, encodingInvalidCharacters: false) {
            return url
        }
        let bytes = Array(raw.utf8)
        var encoded = ""
        encoded.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == UInt8(ascii: "%"),
               i + 2 < bytes.count,
               isASCIIHexDigit(bytes[i + 1]),
               isASCIIHexDigit(bytes[i + 2]) {
                encoded.append(Character(UnicodeScalar(b)))
                encoded.append(Character(UnicodeScalar(bytes[i + 1])))
                encoded.append(Character(UnicodeScalar(bytes[i + 2])))
                i += 3
            } else if isRFC3986Allowed(b) {
                encoded.append(Character(UnicodeScalar(b)))
                i += 1
            } else {
                encoded.append(String(format: "%%%02X", b))
                i += 1
            }
        }
        return URL(string: encoded, encodingInvalidCharacters: false)
    }

    private static func isASCIIHexDigit(_ b: UInt8) -> Bool {
        (b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9"))
            || (b >= UInt8(ascii: "A") && b <= UInt8(ascii: "F"))
            || (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "f"))
    }

    private static func isRFC3986Allowed(_ b: UInt8) -> Bool {
        if (b >= UInt8(ascii: "A") && b <= UInt8(ascii: "Z"))
            || (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "z"))
            || (b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9")) {
            return true
        }
        switch b {
        case UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"),
             UInt8(ascii: ":"), UInt8(ascii: "/"), UInt8(ascii: "?"), UInt8(ascii: "#"),
             UInt8(ascii: "["), UInt8(ascii: "]"), UInt8(ascii: "@"),
             UInt8(ascii: "!"), UInt8(ascii: "$"), UInt8(ascii: "&"), UInt8(ascii: "'"),
             UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "*"), UInt8(ascii: "+"),
             UInt8(ascii: ","), UInt8(ascii: ";"), UInt8(ascii: "="):
            return true
        default:
            return false
        }
    }

    private static func detectLinks(in segment: String, using detector: NSDataDetector?) -> AttributedString {
        var attributed = AttributedString(segment)
        guard let detector, !segment.isEmpty else { return attributed }

        let nsRange = NSRange(segment.startIndex..., in: segment)
        for match in detector.matches(in: segment, options: [], range: nsRange) {
            guard let stringRange = Range(match.range, in: segment),
                  let attrRange = Range(stringRange, in: attributed) else { continue }

            switch match.resultType {
            case .link:
                if let url = match.url {
                    attributed[attrRange].link = url
                }
            case .phoneNumber:
                if let phone = match.phoneNumber {
                    // NSDataDetector reports an extension as "main;ext"; dial the main number,
                    // then the extension after a pause (",") instead of gluing the digits together.
                    let parts = phone.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
                    let digitsOnly = { (s: Substring) in s.filter { $0.isASCII && $0.isNumber } }
                    let digits = digitsOnly(parts[0])
                    let ext = parts.count > 1 ? digitsOnly(parts[1]) : ""
                    // Keep a leading "+" so international numbers dial correctly.
                    let prefix = phone.trimmingCharacters(in: .whitespaces).hasPrefix("+") ? "+" : ""
                    let target = ext.isEmpty ? "\(prefix)\(digits)" : "\(prefix)\(digits),\(ext)"
                    if !digits.isEmpty, let url = URL(string: "tel:\(target)") {
                        attributed[attrRange].link = url
                    }
                }
            default:
                break
            }
        }
        return attributed
    }
}
