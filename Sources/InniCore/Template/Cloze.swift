import Foundation

/// `{{c1::answer::hint}}` deletions, including nested ones and `{{c1,2::…}}`.
public enum Cloze {
    indirect enum Node {
        case text(String)
        case cloze(ords: [Int], children: [Node], hint: String?)
    }

    static func parse(_ s: String) -> [Node] {
        // Each open cloze collects its children; "::" at its own level starts the hint.
        struct Frame { var ords: [Int]; var children: [Node] = []; var hint: String?; var inHint = false }
        var stack: [Frame] = []
        var top: [Node] = []
        var buf = ""
        let chars = Array(s.unicodeScalars)
        var i = 0

        func flush() {
            guard !buf.isEmpty else { return }
            if stack.isEmpty { top.append(.text(buf)) }
            else if stack[stack.count - 1].inHint { stack[stack.count - 1].hint! += buf }
            else { stack[stack.count - 1].children.append(.text(buf)) }
            buf = ""
        }

        func at(_ k: Int, _ lit: String) -> Bool {
            let u = Array(lit.unicodeScalars)
            guard k + u.count <= chars.count else { return false }
            for j in u.indices where chars[k + j] != u[j] { return false }
            return true
        }

        while i < chars.count {
            if at(i, "{{c") {
                var j = i + 3
                var digits = ""
                while j < chars.count, CharacterSet(charactersIn: "0123456789,").contains(chars[j]) {
                    digits.unicodeScalars.append(chars[j])
                    j += 1
                }
                let ords = digits.split(separator: ",").compactMap { Int($0) }
                if !ords.isEmpty, at(j, "::") {
                    flush()
                    stack.append(Frame(ords: ords))
                    i = j + 2
                    continue
                }
            }
            if !stack.isEmpty {
                if at(i, "}}") {
                    flush()
                    let f = stack.removeLast()
                    let node = Node.cloze(ords: f.ords, children: f.children, hint: f.hint)
                    if stack.isEmpty { top.append(node) }
                    else if stack[stack.count - 1].inHint { stack[stack.count - 1].hint! += Cloze.plain([node]) }
                    else { stack[stack.count - 1].children.append(node) }
                    i += 2
                    continue
                }
                if at(i, "::"), !stack[stack.count - 1].inHint {
                    flush()
                    stack[stack.count - 1].inHint = true
                    stack[stack.count - 1].hint = ""
                    i += 2
                    continue
                }
            }
            buf.unicodeScalars.append(chars[i])
            i += 1
        }
        flush()
        // Unclosed clozes stay literal text.
        while let f = stack.popLast() {
            var text = "{{c\(f.ords.map(String.init).joined(separator: ","))::" + plain(f.children)
            if let h = f.hint { text += "::" + h }
            if stack.isEmpty { top.append(.text(text)) } else { stack[stack.count - 1].children.append(.text(text)) }
        }
        return top
    }

    static func plain(_ nodes: [Node]) -> String {
        nodes.map { n in
            switch n {
            case .text(let s): return s
            case .cloze(_, let c, _): return plain(c)
            }
        }.joined()
    }

    public static func ordinals(in s: String) -> Set<Int> {
        var out = Set<Int>()
        func walk(_ nodes: [Node]) {
            for case .cloze(let ords, let c, _) in nodes {
                out.formUnion(ords)
                walk(c)
            }
        }
        walk(parse(s))
        return out
    }

    /// Renders one side of cloze card `ordinal` the way Anki's reviewer HTML looks.
    public static func render(_ s: String, ordinal: Int, question: Bool) -> String {
        guard s.contains("{{c") else { return s }
        return render(parse(s), ordinal, question)
    }

    private static func render(_ nodes: [Node], _ ord: Int, _ question: Bool) -> String {
        var out = ""
        for n in nodes {
            switch n {
            case .text(let t): out += t
            case .cloze(let ords, let children, let hint):
                let ordAttr = ords.map(String.init).joined(separator: ",")
                if ords.contains(ord) {
                    if question {
                        let answer = HTML.escape(render(children, ord, false))
                        let shown = hint.map { "[\($0)]" } ?? "[...]"
                        out += "<span class=\"cloze\" data-cloze=\"\(answer)\" data-ordinal=\"\(ordAttr)\">\(shown)</span>"
                    } else {
                        out += "<span class=\"cloze\" data-ordinal=\"\(ordAttr)\">\(render(children, ord, false))</span>"
                    }
                } else {
                    out += "<span class=\"cloze-inactive\" data-ordinal=\"\(ordAttr)\">\(render(children, ord, question))</span>"
                }
            }
        }
        return out
    }

    /// Text of the active deletions, for `cloze-only` and typing the answer.
    public static func activeText(_ s: String, ordinal: Int) -> String {
        var parts: [String] = []
        func walk(_ nodes: [Node]) {
            for case .cloze(let ords, let c, _) in nodes {
                if ords.contains(ordinal) { parts.append(plain(c)) } else { walk(c) }
            }
        }
        walk(parse(s))
        return parts.joined(separator: ", ")
    }
}
