import Foundation

/// A card's question and answer as HTML fragments, with the audio they reference.
public struct RenderedCard: Sendable {
    public var question: String
    public var answer: String
    public var css: String
    /// 1-based template number, for the `cardN` body class.
    public var cardNumber: Int
    public var questionAudio: [Audio]
    public var answerAudio: [Audio]
    /// Expected answer when the card has a `{{type:}}` field.
    public var typeAnswer: TypeAnswer?

    public enum Audio: Equatable, Sendable {
        case file(String)
        case tts(text: String, lang: String)
    }

    public struct TypeAnswer: Sendable {
        public var expected: String
        public var ignoreDiacritics: Bool
        public var fontName: String
        public var fontSize: Int
    }

    /// The answer with the typed text compared against the expected one.
    public func answer(typed: String) -> String {
        guard let t = typeAnswer else { return answer }
        let cmp = TypeAnswerDiff.html(expected: t.expected, typed: typed, ignoreDiacritics: t.ignoreDiacritics)
        return answer.replacingOccurrences(of: CardRenderer.typeMarker, with: cmp)
    }
}

public enum CardRenderer {
    static let typeMarker = "<!--inni-typeans-->"
    private static let typeRe = try! NSRegularExpression(pattern: "\\[\\[type:(.+?)\\]\\]")
    private static let soundRe = try! NSRegularExpression(pattern: "\\[sound:(.+?)\\]")
    private static let ttsRe = try! NSRegularExpression(pattern: "\\[anki:tts([^\\]]*)\\](.*?)\\[/anki:tts\\]", options: [.dotMatchesLineSeparators])

    /// `notetype` overrides the stored one, for previewing unsaved template edits.
    public static func render(_ card: Card, note: Note, in col: Collection, browser: Bool = false, notetype: Notetype? = nil) -> RenderedCard {
        guard let nt = notetype ?? col.notetypes[note.notetypeID] else {
            return RenderedCard(question: "<div class=inni-error>Missing note type</div>", answer: "", css: "", cardNumber: 1,
                                questionAudio: [], answerAudio: [], typeAnswer: nil)
        }
        let tIdx = nt.isCloze ? 0 : min(card.ord, max(0, nt.templates.count - 1))
        guard tIdx < nt.templates.count else {
            return RenderedCard(question: "<div class=inni-error>No card template</div>", answer: "", css: nt.css, cardNumber: 1,
                                questionAudio: [], answerAudio: [], typeAnswer: nil)
        }
        let tmpl = nt.templates[tIdx]
        var fields: [String: String] = [:]
        for (i, f) in nt.fields.enumerated() { fields[f.name] = i < note.fields.count ? note.fields[i] : "" }
        let deck = col.decks[card.deckID] ?? col.decks[card.homeDeckID]
        fields["Tags"] = note.tags.joined(separator: " ")
        fields["Type"] = nt.name
        fields["Deck"] = deck?.name ?? ""
        fields["Subdeck"] = deck?.leafName ?? ""
        fields["Card"] = tmpl.name
        fields["CardFlag"] = card.flag == 0 ? "" : "flag\(card.flag)"

        let ordinal = card.ord + 1
        let qSource = browser && !tmpl.browserFront.isEmpty ? tmpl.browserFront : tmpl.front
        let aSource = browser && !tmpl.browserBack.isEmpty ? tmpl.browserBack : tmpl.back
        var q = Template.parse(qSource).render(.init(fields: fields, cardOrdinal: ordinal, question: true))
        var a = Template.parse(aSource).render(.init(fields: fields, cardOrdinal: ordinal, question: false, frontSide: q))

        var typeAnswer: RenderedCard.TypeAnswer?
        if let m = typeRe.firstMatch(in: q, range: NSRange(q.startIndex..., in: q)), let r = Range(m.range(at: 1), in: q) {
            var spec = String(q[r]).components(separatedBy: ":")
            let name = spec.removeLast()
            if let i = nt.fieldIndex(name) {
                let raw = i < note.fields.count ? note.fields[i] : ""
                let expected = spec.contains("cloze") ? Cloze.activeText(raw, ordinal: ordinal) : raw
                let field = nt.fields[i]
                typeAnswer = .init(expected: HTML.strip(expected), ignoreDiacritics: spec.contains("nc"),
                                   fontName: field.fontName.isEmpty ? "Arial" : field.fontName, fontSize: field.fontSize > 0 ? field.fontSize : 20)
            }
        }
        let input: String
        if let t = typeAnswer {
            input = "<center><input type=\"text\" id=\"typeans\" autocapitalize=\"off\" autocorrect=\"off\" spellcheck=\"false\" "
                + "onkeypress=\"inni.typeKey(event)\" style=\"font-family: '\(HTML.escape(t.fontName))'; font-size: \(t.fontSize)px;\"></center>"
        } else {
            input = ""
        }
        q = HTML.replace(typeRe, in: q, with: NSRegularExpression.escapedTemplate(for: input))
        // The answer's FrontSide copy loses its input box; the last marker becomes the comparison.
        if typeAnswer != nil {
            let matches = typeRe.matches(in: a, range: NSRange(a.startIndex..., in: a))
            for (k, m) in matches.enumerated().reversed() {
                guard let r = Range(m.range, in: a) else { continue }
                a.replaceSubrange(r, with: k == matches.count - 1 ? typeMarker : "")
            }
        } else {
            a = HTML.replace(typeRe, in: a, with: "")
        }

        let (qHTML, qAudio) = audio(q, side: "q")
        let (aHTML, aAudio) = audio(a, side: "a")
        return RenderedCard(question: qHTML, answer: aHTML, css: nt.css, cardNumber: nt.isCloze ? ordinal : tIdx + 1,
                            questionAudio: qAudio, answerAudio: aAudio, typeAnswer: typeAnswer)
    }

    /// Swaps `[sound:]` and TTS tags for play buttons.
    static func audio(_ html: String, side: String) -> (String, [RenderedCard.Audio]) {
        var list: [RenderedCard.Audio] = []
        var out = html
        let ns = out as NSString
        var pieces: [(NSRange, String)] = []
        let all = (soundRe.matches(in: out, range: NSRange(location: 0, length: ns.length)).map { ($0, true) }
            + ttsRe.matches(in: out, range: NSRange(location: 0, length: ns.length)).map { ($0, false) })
            .sorted { $0.0.range.location < $1.0.range.location }
        for (m, isSound) in all {
            if isSound {
                list.append(.file(HTML.decodeEntities(ns.substring(with: m.range(at: 1)))))
            } else {
                let args = ns.substring(with: m.range(at: 1))
                let lang = args.split(separator: " ").first { $0.hasPrefix("lang=") }.map { String($0.dropFirst(5)) } ?? ""
                list.append(.tts(text: HTML.strip(ns.substring(with: m.range(at: 2))), lang: lang.replacingOccurrences(of: "_", with: "-")))
            }
            let i = list.count - 1
            pieces.append((m.range, "<a class=\"replay-button soundLink\" href=\"#\" onclick=\"inni.play('\(side)',\(i));return false;\">"
                + "<svg class=\"playImage\" viewBox=\"0 0 64 64\" version=\"1.1\"><circle cx=\"32\" cy=\"32\" r=\"29\"/>"
                + "<path d=\"M56.502,32.301l-37.502,20.101l0.329,-40.804l37.173,20.703Z\"/></svg></a>"
                + (isSound ? "" : "<span class=\"tts-text\" hidden>\(HTML.escape(ns.substring(with: m.range(at: 2))))</span>")))
        }
        for (r, rep) in pieces.reversed() { out = (out as NSString).replacingCharacters(in: r, with: rep) }
        return (out, list)
    }

    /// A full page around a question or answer fragment.
    public static func page(_ body: String, card: RenderedCard, night: Bool, platform: String, fontScale: Double = 1) -> String {
        let classes = "card card\(card.cardNumber)" + (night ? " nightMode night_mode" : "") + " \(platform)"
        return """
        <!doctype html>
        <html class="\(platform)\(night ? " night-mode" : "")">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
        <style>\(baseCSS(night: night, fontScale: fontScale))</style>
        <style>\(card.css)</style>
        </head>
        <body class="\(classes)">
        <div id="qa">\(body)</div>
        <script>\(script)</script>
        </body>
        </html>
        """
    }

    static func baseCSS(night: Bool, fontScale: Double) -> String {
        """
        html { -webkit-text-size-adjust: none; zoom: \(fontScale); }
        body { margin: 20px; overflow-wrap: break-word; }
        body.nightMode { background-color: #2E3440; color: #ECEFF4; }
        .nightMode.card { background-color: #2E3440 !important; color: #ECEFF4 !important; }
        img { max-width: 100%; height: auto; }
        hr#answer { border: none; border-top: 1px solid \(night ? "#4C566A" : "#ccc"); }
        .replay-button { display: inline-block; text-decoration: none; vertical-align: middle; margin: 0 4px; }
        .replay-button svg { width: 40px; height: 40px; }
        .replay-button svg circle { fill: \(night ? "#4C566A" : "#e0e0e0"); stroke: none; }
        .replay-button svg path { fill: \(night ? "#ECEFF4" : "#333"); }
        #typeans { width: 100%; box-sizing: border-box; padding: 6px; border-radius: 6px;
                   border: 1px solid \(night ? "#4C566A" : "#bbb"); background: \(night ? "#3B4252" : "#fff"); color: inherit; }
        code#typeans { display: inline-block; font-family: ui-monospace, Menlo, monospace; }
        .typeGood { background-color: #A3BE8C; color: #2E3440; }
        .typeBad { background-color: #BF616A; color: #ECEFF4; }
        .typeMissed { background-color: #D8DEE9; color: #2E3440; }
        .inni-error { color: #BF616A; }
        .cloze-inactive { }
        """
    }

    static let script = """
        (function () {
          function post(msg) { try { window.webkit.messageHandlers.inni.postMessage(msg); } catch (e) {} }
          window.inni = {
            play: function (side, i) { post({ action: 'play', side: side, index: i }); },
            typed: function () { const e = document.getElementById('typeans'); return e && e.value !== undefined ? e.value : ''; },
            typeKey: function (e) { if (e.key === 'Enter') { e.preventDefault(); post({ action: 'showAnswer' }); } },
          };
          window.pycmd = function (cmd) { post({ action: 'pycmd', cmd: cmd }); };
          window.addEventListener('load', function () {
            const t = document.getElementById('typeans');
            if (t && t.tagName === 'INPUT') t.focus();
          });
        })();
        """
}

/// Character diff for typed answers, styled like Anki's.
enum TypeAnswerDiff {
    static func html(expected: String, typed: String, ignoreDiacritics: Bool) -> String {
        let exp = expected.trimmingCharacters(in: .whitespacesAndNewlines)
        let got = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !got.isEmpty else { return "<code id=\"typeans\">\(HTML.escape(exp))</code>" }
        func norm(_ s: String) -> [Character] {
            Array(ignoreDiacritics ? s.folding(options: .diacriticInsensitive, locale: nil) : s)
        }
        let a = norm(got), b = norm(exp)
        let ga = Array(got), gb = Array(exp)
        guard a.count == ga.count, b.count == gb.count else {
            return "<code id=\"typeans\">\(HTML.escape(exp))</code>"
        }
        if a == b { return "<code id=\"typeans\"><span class=\"typeGood\">\(HTML.escape(got))</span></code>" }
        // LCS table
        var dp = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var typedOut = "", expectedOut = ""
        var i = 0, j = 0
        func span(_ cls: String, _ c: Character) -> String { "<span class=\"\(cls)\">\(HTML.escape(String(c)))</span>" }
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                typedOut += span("typeGood", ga[i])
                expectedOut += span("typeGood", gb[j])
                i += 1
                j += 1
            } else if j < b.count, i == a.count || dp[i][j + 1] >= dp[i + 1][j] {
                typedOut += span("typeMissed", "-")
                expectedOut += span("typeMissed", gb[j])
                j += 1
            } else {
                typedOut += span("typeBad", ga[i])
                i += 1
            }
        }
        return "<code id=\"typeans\">\(typedOut)<br><span id=\"typearrow\">&darr;</span><br>\(expectedOut)</code>"
    }
}
