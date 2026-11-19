import AVFoundation
import InniCore
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Serves `inni-media://m/<file>` from the collection's media folder.
final class MediaSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "inni-media"
    static let base = URL(string: "\(scheme)://m/")!
    var folder: URL?

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let folder else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let name = url.path.removingPercentEncoding.map { String($0.drop { $0 == "/" }) } ?? ""
        let file = folder.appendingPathComponent(name)
        guard MediaFiles.isSafeName(name), let data = try? Data(contentsOf: file, options: .mappedIfSafe) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": mime, "Content-Length": "\(data.count)", "Cache-Control": "no-cache"])!
        task.didReceive(resp)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// Plays card audio natively: files with AVAudioPlayer, TTS with the system voices.
@MainActor
final class AudioPlayer: NSObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    static let shared = AudioPlayer()
    private var player: AVAudioPlayer?
    private let synth = AVSpeechSynthesizer()
    private var queue: [RenderedCard.Audio] = []
    var folder: URL?

    override init() {
        super.init()
        synth.delegate = self
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.duckOthers])
        #endif
    }

    func play(_ list: [RenderedCard.Audio]) {
        stop()
        queue = list
        next()
    }

    func stop() {
        queue = []
        player?.stop()
        player = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
    }

    private func next() {
        guard !queue.isEmpty else { return }
        switch queue.removeFirst() {
        case .file(let name):
            guard let folder, MediaFiles.isSafeName(name),
                  let p = try? AVAudioPlayer(contentsOf: folder.appendingPathComponent(name)) else { return next() }
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(true)
            #endif
            p.delegate = self
            player = p
            if !p.play() { next() }
        case .tts(let text, let lang):
            let u = AVSpeechUtterance(string: text)
            if !lang.isEmpty { u.voice = AVSpeechSynthesisVoice(language: lang) }
            synth.speak(u)
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.next() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.next() }
    }
}

/// The single web view every card is drawn in, reused to keep one WebContent process.
@MainActor
final class CardWeb: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    static let shared = CardWeb()
    let webView: WKWebView
    let media = MediaSchemeHandler()
    var onMessage: (([String: Any]) -> Void)?

    override init() {
        let conf = WKWebViewConfiguration()
        conf.setURLSchemeHandler(media, forURLScheme: MediaSchemeHandler.scheme)
        conf.mediaTypesRequiringUserActionForPlayback = []
        conf.websiteDataStore = .nonPersistent()
        #if os(iOS)
        conf.allowsInlineMediaPlayback = true
        conf.dataDetectorTypes = []
        #endif
        let ucc = WKUserContentController()
        conf.userContentController = ucc
        webView = WKWebView(frame: .zero, configuration: conf)
        super.init()
        ucc.add(self, name: "inni")
        webView.navigationDelegate = self
        #if os(macOS)
        webView.setValue(false, forKey: "drawsBackground")
        #else
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        #endif
    }

    func load(_ html: String, folder: URL) {
        media.folder = folder
        webView.loadHTMLString(html, baseURL: MediaSchemeHandler.base)
    }

    func typed() async -> String {
        (try? await webView.evaluateJavaScript("inni.typed()") as? String) ?? ""
    }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Any] { onMessage?(body) }
    }

    /// Links open in the browser instead of replacing the card.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard action.navigationType == .linkActivated, let url = action.request.url else { return .allow }
        if url.scheme == "http" || url.scheme == "https" {
            #if os(macOS)
            NSWorkspace.shared.open(url)
            #else
            await UIApplication.shared.open(url)
            #endif
        }
        return .cancel
    }
}

#if os(macOS)
struct CardWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { CardWeb.shared.webView }
    func updateNSView(_ v: WKWebView, context: Context) {}
}
#else
struct CardWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { CardWeb.shared.webView }
    func updateUIView(_ v: WKWebView, context: Context) {}
}
#endif

enum Platform {
    static var css: String {
        #if os(macOS)
        "mac"
        #else
        "ios mobile"
        #endif
    }
}

/// A separate web view for previews (browser, template editor) so the reviewer's page stays put.
struct PreviewWebView {
    var html: String
    var folder: URL?

    final class Coordinator {
        let media = MediaSchemeHandler()
        var last = ""
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func make(_ c: Coordinator) -> WKWebView {
        let conf = WKWebViewConfiguration()
        conf.setURLSchemeHandler(c.media, forURLScheme: MediaSchemeHandler.scheme)
        conf.websiteDataStore = .nonPersistent()
        let v = WKWebView(frame: .zero, configuration: conf)
        #if os(macOS)
        v.setValue(false, forKey: "drawsBackground")
        #else
        v.isOpaque = false
        v.backgroundColor = .clear
        #endif
        return v
    }

    func update(_ v: WKWebView, _ c: Coordinator) {
        guard html != c.last else { return }
        c.last = html
        c.media.folder = folder
        v.loadHTMLString(html, baseURL: MediaSchemeHandler.base)
    }
}

#if os(macOS)
extension PreviewWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { make(context.coordinator) }
    func updateNSView(_ v: WKWebView, context: Context) { update(v, context.coordinator) }
}
#else
extension PreviewWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { make(context.coordinator) }
    func updateUIView(_ v: WKWebView, context: Context) { update(v, context.coordinator) }
}
#endif
