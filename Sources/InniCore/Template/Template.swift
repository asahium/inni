import Foundation

/// Anki's card template language: `{{Field}}`, `{{#Field}}…{{/Field}}`, `{{^Field}}…{{/Field}}`,
/// filters (`{{text:hint:Field}}`) and `{{=<% %>=}}` delimiter changes.
public struct Template {
    indirect enum Node {
        case text(String)
        case replacement(key: String, filters: [String])
        case conditional(key: String, children: [Node])
        case negated(key: String, children: [Node])
    }

    let nodes: [Node]

    public static func parse(_ source: String) -> Template {
        var tokens = tokenize(source)[...]
        return Template(nodes: build(&tokens, closing: nil))
    }

    // MARK: Parsing

    private enum Token { case text(String), open(String), negOpen(String), close(String), replace(String) }

    private static func tokenize(_ s: String) -> [Token] {
        var out: [Token] = []
        var open = "{{", close = "}}"
        var rest = Substring(s)
        while !rest.isEmpty {
            guard let start = rest.range(of: open) else {
                out.append(.text(String(rest)))
                break
            }
            if start.lowerBound > rest.startIndex { out.append(.text(String(rest[..<start.lowerBound]))) }
            let afterOpen = rest[start.upperBound...]
            guard let end = afterOpen.range(of: close) else {
                out.append(.text(String(rest[start.lowerBound...])))
                break
            }
            let inner = afterOpen[..<end.lowerBound].trimmingCharacters(in: .whitespaces)
            rest = afterOpen[end.upperBound...]
            if inner.hasPrefix("="), inner.hasSuffix("="), inner.count > 2 {
                let parts = inner.dropFirst().dropLast().split(separator: " ")
                if parts.count == 2 {
                    open = String(parts[0])
                    close = String(parts[1])
                }
                continue
            }
            if inner.hasPrefix("#") { out.append(.open(inner.dropFirst().trimmingCharacters(in: .whitespaces))) }
            else if inner.hasPrefix("^") { out.append(.negOpen(inner.dropFirst().trimmingCharacters(in: .whitespaces))) }
            else if inner.hasPrefix("/") { out.append(.close(inner.dropFirst().trimmingCharacters(in: .whitespaces))) }
            else if inner.hasPrefix("!") { continue }
            else { out.append(.replace(inner)) }
        }
        return out
    }

    private static func build(_ tokens: inout ArraySlice<Token>, closing: String?) -> [Node] {
        var nodes: [Node] = []
        while let t = tokens.popFirst() {
            switch t {
            case .text(let s): nodes.append(.text(s))
            case .replace(let s):
                var parts = s.components(separatedBy: ":")
                let key = parts.removeLast().trimmingCharacters(in: .whitespaces)
                nodes.append(.replacement(key: key, filters: parts.map { $0.trimmingCharacters(in: .whitespaces) }))
            case .open(let k): nodes.append(.conditional(key: k, children: build(&tokens, closing: k)))
            case .negOpen(let k): nodes.append(.negated(key: k, children: build(&tokens, closing: k)))
            case .close(let k):
                if k == closing { return nodes }
                nodes.append(.text("{{/\(k)}}"))
            }
        }
        return nodes
    }

    // MARK: Introspection

    /// Anki's rule for whether a template produces a card: some referenced field (after conditionals) is non-empty.
    public func rendersWith(_ nonempty: Set<String>) -> Bool { !Template.isEmpty(nodes, nonempty) }

    private static func isEmpty(_ nodes: [Node], _ nonempty: Set<String>) -> Bool {
        for n in nodes {
            switch n {
            case .text: continue
            case .replacement(let key, _): if nonempty.contains(key) { return false }
            case .conditional(let key, let children):
                if nonempty.contains(key), !isEmpty(children, nonempty) { return false }
            case .negated(_, let children):
                if !isEmpty(children, nonempty) { return false }
            }
        }
        return true
    }

    /// Fields used with the `cloze:` filter.
    public func clozeFields() -> [String] {
        var out: [String] = []
        func walk(_ nodes: [Node]) {
            for n in nodes {
                switch n {
                case .replacement(let key, let filters): if filters.contains("cloze") { out.append(key) }
                case .conditional(_, let c), .negated(_, let c): walk(c)
                case .text: break
                }
            }
        }
        walk(nodes)
        return out
    }

    /// Field names referenced anywhere in the template.
    public func referencedFields() -> Set<String> {
        var out = Set<String>()
        func walk(_ nodes: [Node]) {
            for n in nodes {
                switch n {
                case .replacement(let key, _): out.insert(key)
                case .conditional(let k, let c), .negated(let k, let c): out.insert(k); walk(c)
                case .text: break
                }
            }
        }
        walk(nodes)
        return out
    }

    // MARK: Rendering

    public struct Context {
        public var fields: [String: String]
        /// 1-based cloze number for this card.
        public var cardOrdinal: Int
        public var question: Bool
        public var frontSide: String?

        public init(fields: [String: String], cardOrdinal: Int, question: Bool, frontSide: String? = nil) {
            self.fields = fields
            self.cardOrdinal = cardOrdinal
            self.question = question
            self.frontSide = frontSide
        }
    }

    public func render(_ ctx: Context) -> String {
        var out = ""
        Template.render(nodes, ctx, into: &out)
        return out
    }

    private static func render(_ nodes: [Node], _ ctx: Context, into out: inout String) {
        for n in nodes {
            switch n {
            case .text(let s): out += s
            case .replacement(let key, let filters): out += replacement(key, filters, ctx)
            case .conditional(let key, let children):
                if let v = value(key, ctx), !HTML.isEmptyField(v) { render(children, ctx, into: &out) }
            case .negated(let key, let children):
                if (value(key, ctx).map { HTML.isEmptyField($0) }) ?? true { render(children, ctx, into: &out) }
            }
        }
    }

    private static func value(_ key: String, _ ctx: Context) -> String? {
        if key == "FrontSide" { return ctx.frontSide ?? "" }
        return ctx.fields[key]
    }

    private static func replacement(_ key: String, _ filters: [String], _ ctx: Context) -> String {
        if key == "FrontSide" && filters.isEmpty { return ctx.frontSide ?? "" }
        if filters.first == "type" {
            // Placeholder that the card renderer swaps for an input box or the comparison.
            return "[[type:\(filters.dropFirst().map { $0 + ":" }.joined())\(key)]]"
        }
        guard var text = ctx.fields[key] else {
            if key.isEmpty, filters.isEmpty { return "{{}}" }
            return "<div class=\"inni-error\">{unknown field \(HTML.escape(key))}</div>"
        }
        for f in filters.reversed() { text = apply(f, to: text, key: key, ctx) }
        return text
    }

    private static func apply(_ filter: String, to text: String, key: String, _ ctx: Context) -> String {
        if filter.hasPrefix("tts ") {
            var args = filter.dropFirst(4).split(separator: " ").map(String.init)
            if let lang = args.first, !lang.contains("=") { args[0] = "lang=\(lang)" }
            return "[anki:tts \(args.joined(separator: " "))]\(text)[/anki:tts]"
        }
        switch filter {
        case "text": return HTML.strip(text)
        case "cloze": return Cloze.render(text, ordinal: ctx.cardOrdinal, question: ctx.question)
        case "cloze-only": return Cloze.activeText(text, ordinal: ctx.cardOrdinal)
        case "hint": return hint(text, key: key)
        case "furigana": return Furigana.ruby(text)
        case "kana": return Furigana.kana(text)
        case "kanji": return Furigana.kanji(text)
        default: return text
        }
    }

    private static func hint(_ text: String, key: String) -> String {
        guard !HTML.isEmptyField(text) else { return "" }
        let id = "hint\(abs(text.hashValue % 1_000_000))"
        return """
        <a class="hint" href="#" onclick="this.style.display='none';document.getElementById('\(id)').style.display='block';return false;" \
        draggable="false">\(HTML.escape(key))</a><div id="\(id)" class="hint" style="display: none">\(text)</div>
        """
    }
}

enum Furigana {
    private static let re = try! NSRegularExpression(pattern: " ?([^ >]+?)\\[(.+?)\\]")

    static func ruby(_ s: String) -> String {
        HTML.replace(re, in: s, with: "<ruby><rb>$1</rb><rt>$2</rt></ruby>")
    }

    static func kana(_ s: String) -> String { HTML.replace(re, in: s, with: "$2") }
    static func kanji(_ s: String) -> String { HTML.replace(re, in: s, with: "$1") }
}
