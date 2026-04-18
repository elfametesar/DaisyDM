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
    let browser: String?
    
    // Explicit memberwise initializer for manual creation
    init(url: String, filename: String?, cookies: String?, referer: String?, ua: String?, youtubeQuality: String?, forceHLS: Bool?, browser: String?) {
        self.url = url
        self.filename = filename
        self.cookies = cookies
        self.referer = referer
        self.ua = ua
        self.youtubeQuality = youtubeQuality
        self.forceHLS = forceHLS
        self.browser = browser
    }
    
    enum CodingKeys: String, CodingKey {
        case url, filename, cookies, referer, ua, youtubeQuality, forceHLS, browser
    }
    
    // Flexible decoder to handle String or Int from Extension JS
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decode(String.self, forKey: .url)
        filename = try container.decodeIfPresent(String.self, forKey: .filename)
        cookies = try container.decodeIfPresent(String.self, forKey: .cookies)
        referer = try container.decodeIfPresent(String.self, forKey: .referer)
        ua = try container.decodeIfPresent(String.self, forKey: .ua)
        
        // Handle youtubeQuality as String, Int, or Null
        if let qInt = try? container.decodeIfPresent(Int.self, forKey: .youtubeQuality) {
            youtubeQuality = String(qInt)
        } else if let qStr = try? container.decodeIfPresent(String.self, forKey: .youtubeQuality) {
            youtubeQuality = qStr
        } else {
            youtubeQuality = nil
        }
        
        forceHLS = try container.decodeIfPresent(Bool.self, forKey: .forceHLS)
        browser = try container.decodeIfPresent(String.self, forKey: .browser)
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
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            var newData = accumulatedData
            if let data = data { newData.append(data) }

            let separator = Data([13, 10, 13, 10])

            if let range = newData.range(of: separator) {
                let headerData = newData.subdata(in: 0..<range.lowerBound)
                let headers = String(data: headerData, encoding: .utf8) ?? ""

                if headers.hasPrefix("GET /ping") {
                    let res = "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\nOK"
                    connection.send(content: res.data(using: .utf8)!, completion: .contentProcessed { _ in connection.cancel() })
                    return
                }

                var expectedLength = 0
                for line in headers.components(separatedBy: "\r\n") {
                    let lower = line.lowercased()
                    if lower.hasPrefix("content-length:") {
                        let valStr = lower.replacingOccurrences(of: "content-length:", with: "").trimmingCharacters(in: .whitespaces)
                        expectedLength = Int(valStr) ?? 0
                    }
                }

                let bodyStartIndex = range.upperBound
                let currentBodyLength = newData.count - bodyStartIndex

                if currentBodyLength < expectedLength {
                    self.receiveData(on: connection, accumulatedData: newData)
                    return
                }

                let bodyData = newData.subdata(in: bodyStartIndex..<(bodyStartIndex + expectedLength))
                let resHeaders = "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: POST, OPTIONS, GET\r\nAccess-Control-Allow-Headers: Content-Type, X-Filename\r\nConnection: close\r\n\r\n"

                if headers.hasPrefix("OPTIONS") {
                    connection.send(content: resHeaders.data(using: .utf8)!, completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
                
                if headers.hasPrefix("POST /setenabled") {
                    if let body = String(data: bodyData, encoding: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
                       let enabled = json["enabled"] as? Bool {
                        DispatchQueue.main.async {
                            SafariInterceptor.shared.isEnabled = enabled
                            print("🔧 SafariInterceptor.isEnabled = \(enabled)")
                        }
                    }
                    connection.send(content: resHeaders.data(using: .utf8)!, completion: .contentProcessed { _ in connection.cancel() })
                    return
                }

                if headers.hasPrefix("POST") {
                    do {
                        let payload = try JSONDecoder().decode(DownloadPayload.self, from: bodyData)
                        
                        var sanitizedUrl = payload.url
                        if sanitizedUrl.contains("application/x-bittorrent") {
                            sanitizedUrl = sanitizedUrl.replacingOccurrences(of: "application/x-bittorrent", with: "application/octet-stream")
                        }
                        
                        let sanitizedPayload = DownloadPayload(
                            url: sanitizedUrl,
                            filename: payload.filename,
                            cookies: payload.cookies,
                            referer: payload.referer,
                            ua: payload.ua,
                            youtubeQuality: payload.youtubeQuality,
                            forceHLS: payload.forceHLS,
                            browser: payload.browser
                        )
                        
                        DispatchQueue.main.async {
                            self.showConfirmation(for: sanitizedPayload)
                        }
                    } catch {
                        print("❌ Failed to decode payload: \(error)")
                    }
                    connection.send(content: resHeaders.data(using: .utf8)!, completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
            }

            if !isComplete && error == nil {
                self.receiveData(on: connection, accumulatedData: newData)
            } else {
                connection.cancel()
            }
        }
    }

    private func showConfirmation(for payload: DownloadPayload) {
        guard let url = URL(string: payload.url) ?? URL(string: payload.url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "") else {
            return
        }
        
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(
            name: .confirmDownload,
            object: nil,
            userInfo: [
                "url":            url,
                "filename":       payload.filename ?? "",
                "cookies":        payload.cookies  ?? "",
                "referer":        payload.referer  ?? "",
                "ua":             payload.ua       ?? "",
                "youtubeQuality": payload.youtubeQuality ?? "",
                "forceHLS":       payload.forceHLS ?? false,
                "browser":        payload.browser  ?? ""
            ]
        )
    }
}
