import Foundation

// Invite codes carry a Game Center playerGroup in 8 Crockford base32
// characters (7 value + 1 check). The same code goes in a share-sheet
// deeplink and can be typed by hand.

public enum InviteCode {

    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    private static let valueLength = 7

    /// Prefix byte on raw app frames so they never reach the NetMessage decoder.
    public static let rawFrameMarker: UInt8 = 0xB7

    public static func encode(group: Int) -> String? {
        guard group > 0, group <= Int(Int32.max) else { return nil }
        var n = group
        var chars: [Character] = []
        for _ in 0..<valueLength {
            chars.append(alphabet[n % 32])
            n /= 32
        }
        chars.reverse()
        chars.append(alphabet[checksum(chars)])
        return String(chars)
    }

    /// Accepts any case, hyphens, spaces and the usual O/I/L look-alikes.
    public static func decode(_ text: String) -> Int? {
        let cleaned = text.uppercased().filter { $0 != "-" && !$0.isWhitespace }.map { c -> Character in
            switch c {
            case "O": return "0"
            case "I", "L": return "1"
            default: return c
            }
        }
        guard cleaned.count == valueLength + 1 else { return nil }
        var value = 0
        var digits: [Character] = []
        for c in cleaned.prefix(valueLength) {
            guard let i = alphabet.firstIndex(of: c) else { return nil }
            value = value * 32 + i
            digits.append(c)
        }
        guard let last = cleaned.last, alphabet.firstIndex(of: last) == checksum(digits) else { return nil }
        guard value > 0, value <= Int(Int32.max) else { return nil }
        return value
    }

    /// "ABCD-EFGH" for display.
    public static func display(_ code: String) -> String {
        guard code.count == valueLength + 1 else { return code }
        return code.prefix(4) + "-" + code.suffix(4)
    }

    private static func checksum(_ chars: [Character]) -> Int {
        var sum = 0
        for (i, c) in chars.enumerated() {
            sum += (alphabet.firstIndex(of: c) ?? 0) * (i + 1)
        }
        return sum % 32
    }

    // MARK: Deeplink

    /// `scheme://join?code=XXXXXXXX`
    public static func url(scheme: String, code: String) -> URL? {
        var c = URLComponents()
        c.scheme = scheme
        c.host = "join"
        c.queryItems = [URLQueryItem(name: "code", value: code)]
        return c.url
    }

    /// Group from a `scheme://join?code=...` link, nil for any other URL.
    public static func group(from url: URL, scheme: String) -> Int? {
        guard url.scheme?.lowercased() == scheme.lowercased(), url.host?.lowercased() == "join",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let code = items.first(where: { $0.name == "code" })?.value else { return nil }
        return decode(code)
    }
}
