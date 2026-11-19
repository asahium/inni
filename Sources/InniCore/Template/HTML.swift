import Foundation

public enum HTML {
    private static let tag = try! NSRegularExpression(pattern: "<[^>]*>", options: [.dotMatchesLineSeparators])
    private static let comment = try! NSRegularExpression(pattern: "<!--.*?-->", options: [.dotMatchesLineSeparators])
    private static let styleScript = try! NSRegularExpression(pattern: "<(style|script)\\b[^>]*>.*?</\\1>",
                                                              options: [.dotMatchesLineSeparators, .caseInsensitive])
    private static let img = try! NSRegularExpression(pattern: "<img[^>]*src=[\"']?([^\"'>\\s]+)[\"']?[^>]*>", options: [.caseInsensitive])
    private static let emptyField = try! NSRegularExpression(pattern: "^(?:[\\s\\u200b]|</?(?:br|div)\\s?/?>)*$", options: [.caseInsensitive])

    /// Plain text of an HTML fragment. With `keepMediaNames`, images become their file names (Anki's sort field rule).
    public static func strip(_ html: String, keepMediaNames: Bool = false) -> String {
        guard html.contains("<") || html.contains("&") else { return html }
        var s = html
        if s.contains("<") {
            if keepMediaNames { s = replace(img, in: s, with: " $1 ") }
            s = replace(comment, in: s, with: "")
            s = replace(styleScript, in: s, with: "")
            s = replace(tag, in: s, with: "")
        }
        return decodeEntities(s).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Anki treats a field holding only whitespace, `<br>` and `<div>` as empty.
    public static func isEmptyField(_ s: String) -> Bool {
        s.isEmpty || emptyField.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    static func replace(_ re: NSRegularExpression, in s: String, with t: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: t)
    }

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "ndash": "–", "mdash": "—",
        "hellip": "…", "laquo": "«", "raquo": "»", "copy": "©", "reg": "®", "deg": "°", "times": "×", "divide": "÷",
        "rarr": "→", "larr": "←", "harr": "↔", "uarr": "↑", "darr": "↓", "middot": "·", "bull": "•", "shy": "",
    ]

    public static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        out.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") {
                let name = s[s.index(after: i)..<semi]
                var rep: String?
                if name.hasPrefix("#x") || name.hasPrefix("#X") {
                    rep = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else if name.hasPrefix("#") {
                    rep = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else {
                    rep = named[String(name)]
                }
                if let rep {
                    out += rep
                    i = s.index(after: semi)
                    continue
                }
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }

    public static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(c)
            }
        }
        return out
    }

    private static let soundTag = try! NSRegularExpression(pattern: "\\[sound:(.+?)\\]")
    private static let mediaRef = try! NSRegularExpression(
        pattern: "(?i)<(?:img|audio|video|source)\\b[^>]*?\\bsrc\\s*=\\s*(?:\"([^\"]+)\"|'([^']+)'|([^\\s>]+))")

    /// Media file names referenced by a field (images, `[sound:]` tags, audio/video sources).
    public static func mediaReferences(_ s: String) -> [String] {
        var out: [String] = []
        let r = NSRange(s.startIndex..., in: s)
        for m in soundTag.matches(in: s, range: r) { if let x = Range(m.range(at: 1), in: s) { out.append(String(s[x])) } }
        for m in mediaRef.matches(in: s, range: r) {
            for g in 1...3 {
                if let x = Range(m.range(at: g), in: s) {
                    let name = decodeEntities(String(s[x]))
                    if !name.contains("://"), !name.hasPrefix("data:") { out.append(name.removingPercentEncoding ?? name) }
                }
            }
        }
        return out
    }
}
