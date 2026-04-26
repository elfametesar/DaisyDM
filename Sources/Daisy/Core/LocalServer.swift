import Foundation
import Network
import AppKit

struct DownloadPayload: Decodable {
    let url: String
    let filename: String?
    let cookies: String?
    let referer: String?
    let ua: String?
    let youtubeQuality: String?
    let forceHLS: Bool?
    let forceDASH: Bool?
    let forceDirectDownload: Bool?
    let browser: String?
    let ytPoToken: String?
    let ytPoTokenVisitor: String?
    /// IDM-style: when the popup picks a YouTube quality whose googlevideo
    /// URLs the browser already requested (and we captured via webRequest),
    /// these fields carry the resolved URL pair so the Swift side can skip
    /// the InnerTube extractor entirely and go straight to aria2c + ffmpeg.
    let ytVideoUrl: String?
    let ytAudioUrl: String?
    let ytVideoMime: String?
    let ytAudioMime: String?
    let ytHeight: Int?
    let ytTitle: String?
    let headers: [String: String]? // <--- Correctly maps to the background.js payload
    let responseHeaders: [String: String]?
    let extraHeadersFlat: String?

    var mergedHeaders: [String: String] {
        var merged = headers ?? [:]
        if let ref = referer, !ref.isEmpty  { merged["referer"]    = merged["referer"]    ?? ref }
        if let agent = ua, !agent.isEmpty   { merged["user-agent"] = merged["user-agent"] ?? agent }
        return merged
    }

    init(url: String, filename: String?, cookies: String?, referer: String?,
         ua: String?, youtubeQuality: String?, forceHLS: Bool?, forceDASH: Bool?, forceDirectDownload: Bool?, browser: String?,
         headers: [String: String]? = nil,
         responseHeaders: [String: String]? = nil,
         extraHeadersFlat: String? = nil,
         ytPoToken: String? = nil,
         ytPoTokenVisitor: String? = nil,
         ytVideoUrl: String? = nil,
         ytAudioUrl: String? = nil,
         ytVideoMime: String? = nil,
         ytAudioMime: String? = nil,
         ytHeight: Int? = nil,
         ytTitle: String? = nil) {
        self.url             = url
        self.filename        = filename
        self.cookies         = cookies
        self.referer         = referer
        self.ua              = ua
        self.youtubeQuality  = youtubeQuality
        self.forceHLS        = forceHLS
        self.forceDASH       = forceDASH
        self.forceDirectDownload = forceDirectDownload
        self.browser         = browser
        self.headers         = headers
        self.responseHeaders = responseHeaders
        self.extraHeadersFlat = extraHeadersFlat
        self.ytPoToken       = ytPoToken
        self.ytPoTokenVisitor = ytPoTokenVisitor
        self.ytVideoUrl      = ytVideoUrl
        self.ytAudioUrl      = ytAudioUrl
        self.ytVideoMime     = ytVideoMime
        self.ytAudioMime     = ytAudioMime
        self.ytHeight        = ytHeight
        self.ytTitle         = ytTitle
    }

    enum CodingKeys: String, CodingKey {
        case url, filename, cookies, referer, ua
        case youtubeQuality, forceHLS, forceDASH, forceDirectDownload, browser
        case headers, responseHeaders, extraHeadersFlat
        case ytPoToken, ytPoTokenVisitor
        case ytVideoUrl, ytAudioUrl, ytVideoMime, ytAudioMime, ytHeight, ytTitle
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url      = try c.decode(String.self, forKey: .url)
        filename = try c.decodeIfPresent(String.self, forKey: .filename)
        cookies  = try c.decodeIfPresent(String.self, forKey: .cookies)
        referer  = try c.decodeIfPresent(String.self, forKey: .referer)
        ua       = try c.decodeIfPresent(String.self, forKey: .ua)
        browser  = try c.decodeIfPresent(String.self, forKey: .browser)
        forceHLS = try c.decodeIfPresent(Bool.self,   forKey: .forceHLS)
        forceDASH = try c.decodeIfPresent(Bool.self, forKey: .forceDASH)
        forceDirectDownload = try c.decodeIfPresent(Bool.self, forKey: .forceDirectDownload)
        extraHeadersFlat = try c.decodeIfPresent(String.self, forKey: .extraHeadersFlat)
        ytPoToken = try c.decodeIfPresent(String.self, forKey: .ytPoToken)
        ytPoTokenVisitor = try c.decodeIfPresent(String.self, forKey: .ytPoTokenVisitor)
        ytVideoUrl  = try c.decodeIfPresent(String.self, forKey: .ytVideoUrl)
        ytAudioUrl  = try c.decodeIfPresent(String.self, forKey: .ytAudioUrl)
        ytVideoMime = try c.decodeIfPresent(String.self, forKey: .ytVideoMime)
        ytAudioMime = try c.decodeIfPresent(String.self, forKey: .ytAudioMime)
        ytHeight    = try c.decodeIfPresent(Int.self,    forKey: .ytHeight)
        ytTitle     = try c.decodeIfPresent(String.self, forKey: .ytTitle)
        // Browsers sometimes hand us header values that are numbers (e.g.
        // X-YouTube-Page-CL is an int) or bools, but our struct stores them
        // as String. Decode loosely and stringify so a single non-string
        // value doesn't blow up the entire payload decode.
        headers          = try Self.decodeLooseHeaders(c, key: .headers)
        responseHeaders  = try Self.decodeLooseHeaders(c, key: .responseHeaders)

        if let qInt = try? c.decodeIfPresent(Int.self, forKey: .youtubeQuality) {
            youtubeQuality = String(qInt)
        } else {
            youtubeQuality = try c.decodeIfPresent(String.self, forKey: .youtubeQuality)
        }
    }

    /// Decodes a `[String: String]` map but tolerates individual values that
    /// arrive as JSON numbers, booleans, or null. Anything that isn't already
    /// a string gets stringified; null keys are dropped. Returns nil when the
    /// outer field is missing entirely.
    private static func decodeLooseHeaders(
        _ container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws -> [String: String]? {
        guard container.contains(key),
              try !container.decodeNil(forKey: key) else { return nil }
        let nested = try container.nestedContainer(keyedBy: AnyStringKey.self, forKey: key)
        var out: [String: String] = [:]
        for k in nested.allKeys {
            if let s = try? nested.decode(String.self, forKey: k) {
                out[k.stringValue] = s
            } else if let i = try? nested.decode(Int64.self, forKey: k) {
                out[k.stringValue] = String(i)
            } else if let d = try? nested.decode(Double.self, forKey: k) {
                out[k.stringValue] = String(d)
            } else if let b = try? nested.decode(Bool.self, forKey: k) {
                out[k.stringValue] = String(b)
            }
            // Other shapes (arrays, objects, null) are intentionally dropped.
        }
        return out.isEmpty ? nil : out
    }

    private struct AnyStringKey: CodingKey {
        var stringValue: String
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { return nil }
    }
}

class LocalServer {
    static let shared = LocalServer()
    private var listener: NWListener?
    private let portRange = 6840...6850

    func start(port: Int = 6840) {
        guard port <= portRange.upperBound else { return }
        do {
            let nwPort = NWEndpoint.Port(integerLiteral: NWEndpoint.Port.IntegerLiteralType(port))
            listener = try NWListener(using: .tcp, on: nwPort)
            listener?.stateUpdateHandler = { [weak self] state in
                if case .ready = state {
                    print("🚀 Daisy Local Server listening on port \(port)")
                } else if case .failed = state {
                    self?.listener?.cancel()
                    self?.start(port: port + 1)
                }
            }
            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            listener?.start(queue: .main)
        } catch {
            start(port: port + 1)
        }
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)
        receiveData(on: connection, accumulatedData: Data())
    }

    private func receiveData(on connection: NWConnection, accumulatedData: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4 * 1024 * 1024) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            var newData = accumulatedData
            if let data = data { newData.append(data) }

            let separator = Data([13, 10, 13, 10])

            guard let range = newData.range(of: separator) else {
                if !isComplete && error == nil {
                    self.receiveData(on: connection, accumulatedData: newData)
                } else {
                    connection.cancel()
                }
                return
            }

            let headerData = newData.subdata(in: 0..<range.lowerBound)
            let headers    = String(data: headerData, encoding: .utf8) ?? ""

            if headers.hasPrefix("GET /ping") {
                let res = "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\nOK"
                connection.send(content: res.data(using: .utf8)!, completion: .contentProcessed { _ in connection.cancel() })
                return
            }

            var expectedLength = 0
            for line in headers.components(separatedBy: "\r\n") {
                let lower = line.lowercased()
                if lower.hasPrefix("content-length:") {
                    expectedLength = Int(lower.replacingOccurrences(of: "content-length:", with: "").trimmingCharacters(in: .whitespaces)) ?? 0
                }
            }

            let bodyStartIndex    = range.upperBound
            let currentBodyLength = newData.count - bodyStartIndex

            if currentBodyLength < expectedLength {
                self.receiveData(on: connection, accumulatedData: newData)
                return
            }

            let bodyData  = newData.subdata(in: bodyStartIndex..<(bodyStartIndex + expectedLength))
            let okHeaders = "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: POST, OPTIONS, GET\r\nAccess-Control-Allow-Headers: Content-Type, X-Filename\r\nConnection: close\r\n\r\n"

            if headers.hasPrefix("OPTIONS") {
                connection.send(content: okHeaders.data(using: .utf8)!, completion: .contentProcessed { _ in connection.cancel() })
                return
            }

            if headers.hasPrefix("POST") {
                do {
                    // FIX 4: Replaced 'let rawJSON = ' with '_'
                    let _ = String(data: bodyData, encoding: .utf8) ?? "Bozuk JSON Verisi"

                    let payload = try JSONDecoder().decode(DownloadPayload.self, from: bodyData)

                    var sanitizedUrl = payload.url
                    if sanitizedUrl.contains("application/x-bittorrent") {
                        sanitizedUrl = sanitizedUrl.replacingOccurrences(of: "application/x-bittorrent", with: "application/octet-stream")
                    }

                    let sanitizedPayload = DownloadPayload(
                        url:             sanitizedUrl,
                        filename:        payload.filename,
                        cookies:         payload.cookies,
                        referer:         payload.referer,
                        ua:              payload.ua,
                        youtubeQuality:  payload.youtubeQuality,
                        forceHLS:        payload.forceHLS,
                        forceDASH:       payload.forceDASH,
                        forceDirectDownload: payload.forceDirectDownload,
                        browser:         payload.browser,
                        headers:         payload.headers, // <--- Correctly passing it
                        responseHeaders: payload.responseHeaders,
                        extraHeadersFlat: payload.extraHeadersFlat,
                        ytPoToken:       payload.ytPoToken,
                        ytPoTokenVisitor: payload.ytPoTokenVisitor,
                        ytVideoUrl:      payload.ytVideoUrl,
                        ytAudioUrl:      payload.ytAudioUrl,
                        ytVideoMime:     payload.ytVideoMime,
                        ytAudioMime:     payload.ytAudioMime,
                        ytHeight:        payload.ytHeight,
                        ytTitle:         payload.ytTitle
                    )

                    DispatchQueue.main.async {
                        self.showConfirmation(for: sanitizedPayload)
                    }
                } catch {
                    print("❌ Failed to decode payload: \(error)")
                }
                connection.send(content: okHeaders.data(using: .utf8)!, completion: .contentProcessed { _ in connection.cancel() })
                return
            }

            if !isComplete && error == nil {
                self.receiveData(on: connection, accumulatedData: newData)
            } else {
                connection.cancel()
            }
        }
    }

    private func showConfirmation(for payload: DownloadPayload) {
            guard let url = URL(string: payload.url)
                ?? URL(string: payload.url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
            else { return }

            NSApp.activate(ignoringOtherApps: true)

            var finalHeaders = payload.mergedHeaders
            if finalHeaders.isEmpty, let flat = payload.extraHeadersFlat, !flat.isEmpty {
                let lines = flat.components(separatedBy: "\n")
                for line in lines {
                    let parts = line.components(separatedBy: ": ")
                    if parts.count == 2 {
                        finalHeaders[parts[0]] = parts[1]
                    }
                }
            }

            NotificationCenter.default.post(
                name: .confirmDownload,
                object: nil,
                userInfo: [
                    "url":              url,
                    "filename":         payload.filename        ?? "",
                    "cookies":          payload.cookies         ?? "",
                    "referer":          payload.referer         ?? "",
                    "ua":               payload.ua              ?? "",
                    "youtubeQuality":   payload.youtubeQuality  ?? "",
                    "forceHLS":         payload.forceHLS        ?? false,
                    "forceDASH":        payload.forceDASH       ?? false,
                    "forceDirectDownload": payload.forceDirectDownload ?? false,
                    "browser":          payload.browser         ?? "",
                    "headers":          finalHeaders,
                    "extraHeadersFlat": payload.extraHeadersFlat ?? "",
                    "ytPoToken":        payload.ytPoToken       ?? "",
                    "ytPoTokenVisitor": payload.ytPoTokenVisitor ?? "",
                    "ytVideoUrl":       payload.ytVideoUrl       ?? "",
                    "ytAudioUrl":       payload.ytAudioUrl       ?? "",
                    "ytVideoMime":      payload.ytVideoMime      ?? "",
                    "ytAudioMime":      payload.ytAudioMime      ?? "",
                    "ytHeight":         payload.ytHeight         ?? 0,
                    "ytTitle":          payload.ytTitle          ?? ""
                ]
            )
        }
}
