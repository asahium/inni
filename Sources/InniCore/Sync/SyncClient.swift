import Foundation

/// Credentials for AnkiWeb or a self-hosted sync server.
public struct SyncAuth: Codable, Equatable, Sendable {
    public var hostKey: String
    /// nil means AnkiWeb. Kept after the server redirects us to another shard.
    public var endpoint: URL?

    public init(hostKey: String, endpoint: URL? = nil) {
        self.hostKey = hostKey
        self.endpoint = endpoint
    }
}

public enum SyncError: Error, LocalizedError, Equatable {
    case authFailed
    case serverMessage(String)
    case clockIncorrect
    /// The collections diverged in a way only a one-way (full) sync can fix.
    case fullSyncRequired(uploadOK: Bool, downloadOK: Bool)
    case sanityCheckFailed
    case resyncRequired(String)
    case http(Int, String)
    case uploadTooLarge(String)

    public var errorDescription: String? {
        switch self {
        case .authFailed: return "AnkiWeb rejected the username or password."
        case .serverMessage(let m): return m
        case .clockIncorrect: return "Your device clock is off by more than 5 minutes. Fix the date and time, then sync again."
        case .fullSyncRequired: return "The collection needs a one-way sync."
        case .sanityCheckFailed: return "Sync found a mismatch with the server. The next sync will be one-way."
        case .resyncRequired(let m): return "Sync needs a one-way sync: \(m)"
        case .http(let code, let body): return "Sync server error \(code)\(body.isEmpty ? "" : ": \(body)")"
        case .uploadTooLarge(let m): return "The collection is too large to upload (\(m))."
        }
    }

    /// Timeouts and dropped connections, including requests iOS cut off while the app was in the background.
    public static func isNetwork(_ error: Error) -> Bool {
        guard let e = error as? URLError else { return false }
        let codes: [URLError.Code] = [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
                                      .cannotFindHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff]
        return codes.contains(e.code)
    }
}

/// One sync session against an endpoint: zstd-compressed JSON over POST with the `anki-sync` header.
final class SyncHTTP: @unchecked Sendable {
    static let ankiWeb = URL(string: "https://sync.ankiweb.net/")!
    static let protocolVersion = 11

    var endpoint: URL
    let hostKey: String
    let sessionKey: String

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 60 * 60
        cfg.httpShouldSetCookies = false
        return URLSession(configuration: cfg)
    }()

    /// The protocol wants the new endpoint remembered, so redirects go back to the caller.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
    private static let noRedirects = NoRedirects()

    /// AnkiWeb rejects `sync/meta` with a 400 unless these match the format of a released Anki build.
    static let ankiVersion = "26.09.4", ankiBuildHash = "c06370ff"

    static var platform: String {
        #if os(iOS)
        "ios"
        #else
        "macos"
        #endif
    }

    static var clientVersion: String { "\(ankiVersion),\(ankiBuildHash),\(platform)" }

    static var longClientVersion: String { "anki,\(ankiVersion) (\(ankiBuildHash)),\(platform)" }

    init(auth: SyncAuth) {
        endpoint = auth.endpoint ?? SyncHTTP.ankiWeb
        hostKey = auth.hostKey
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        var n = UInt32.random(in: .min ... .max), s = ""
        repeat { s.append(alphabet[Int(n % 62)]); n /= 62 } while n > 0
        sessionKey = s
    }

    struct Redirect: Error { let location: URL }

    /// Returns the decompressed response body.
    func post(_ path: String, _ body: Data) async throws -> Data {
        guard let url = URL(string: path, relativeTo: endpoint) else { throw SyncError.http(0, "bad endpoint") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let header: [String: Any] = ["v": SyncHTTP.protocolVersion, "k": hostKey, "c": SyncHTTP.clientVersion, "s": sessionKey]
        req.setValue(String(decoding: try Schema11.encode(header), as: UTF8.self), forHTTPHeaderField: "anki-sync")
        req.httpBody = Zstd.frame(body)
        let (data, response) = try await Self.session.data(for: req, delegate: Self.noRedirects)
        guard let http = response as? HTTPURLResponse else { throw SyncError.http(0, "no response") }
        switch http.statusCode {
        case 200:
            return Zstd.isCompressed(data) ? try Zstd.decompress(data) : data
        case 403:
            throw SyncError.authFailed
        case 301, 302, 307, 308:
            guard let loc = http.value(forHTTPHeaderField: "Location"), let to = URL(string: loc, relativeTo: url) else {
                throw SyncError.http(http.statusCode, "redirect without location")
            }
            throw Redirect(location: to.absoluteURL)
        default:
            let text = String(decoding: Zstd.isCompressed(data) ? ((try? Zstd.decompress(data)) ?? data) : data, as: UTF8.self)
            let detail = text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)
            throw SyncError.http(http.statusCode, detail.isEmpty ? path : "\(path): \(detail)")
        }
    }

    func json(_ path: String, _ body: Any) async throws -> Any {
        let data = try await post(path, try Schema11.encode(body))
        if data.isEmpty { return NSNull() }
        return try Schema11.decode(data)
    }
}

public enum AnkiWeb {
    /// Exchanges a username and password for a host key.
    public static func login(username: String, password: String, endpoint: URL? = nil) async throws -> SyncAuth {
        let http = SyncHTTP(auth: SyncAuth(hostKey: "", endpoint: endpoint))
        let reply = try await http.json("sync/hostKey", ["u": username, "p": password])
        guard let key = (reply as? JSONObject)?["key"] as? String else { throw SyncError.authFailed }
        return SyncAuth(hostKey: key, endpoint: endpoint)
    }
}
