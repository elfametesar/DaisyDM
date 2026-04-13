// MARK: - LocalServer.swift
import Foundation
import Network
import AppKit

struct DownloadPayload: Decodable {
    let url: String
    let filename: String?
    let cookies: String?
    let referer: String?
    let ua: String?
}

class LocalServer {
    static let shared = LocalServer()
    private var listener: NWListener?
    private let portRange = 6840...6850

    func start(port: Int = 6840) {
        guard port <= portRange.upperBound else {
            print("❌ Failed to find open port for Daisy Local Server.")
            return
        }

        do {
            let nwPort = NWEndpoint.Port(integerLiteral: NWEndpoint.Port.IntegerLiteralType(port))
            listener = try NWListener(using: .tcp, on: nwPort)

            listener?.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    print("🚀 Daisy Local Server listening on port \(port)")
                case .failed:
                    self?.listener?.cancel()
                    self?.start(port: port + 1)
                default:
                    break
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

            // Define \r\n\r\n natively in Data to avoid String.Index completely
            let separator = Data([13, 10, 13, 10])

            if let range = newData.range(of: separator) {
                // Use pure Int boundaries for slicing
                let headerData = newData.subdata(in: 0..<range.lowerBound)
                let headers = String(data: headerData, encoding: .utf8) ?? ""

                // 1. Instant Ping Response for extension port scanning
                if headers.hasPrefix("GET /ping") {
                    let res = "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\nOK"
                    connection.send(content: res.data(using: .utf8)!, completion: .contentProcessed { _ in connection.cancel() })
                    return
                }

                // 2. Parse Content-Length
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

                // 3. Keep buffering if the massive Base64 payload hasn't finished arriving
                if currentBodyLength < expectedLength {
                    self.receiveData(on: connection, accumulatedData: newData)
                    return
                }

                // 4. Extract exactly the JSON body using Int ranges
                let bodyData = newData.subdata(in: bodyStartIndex..<(bodyStartIndex + expectedLength))
                
                let resHeaders = "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: POST, OPTIONS, GET\r\nAccess-Control-Allow-Headers: Content-Type, X-Filename\r\nConnection: close\r\n\r\n"

                if headers.hasPrefix("OPTIONS") {
                    connection.send(content: resHeaders.data(using: .utf8)!, completion: .contentProcessed { _ in connection.cancel() })
                    return
                }

                if headers.hasPrefix("POST /torrent") {
                    // Binary torrent file upload — extract filename from header
                    var filename = "download.torrent"
                    for line in headers.components(separatedBy: "\r\n") {
                        let lower = line.lowercased()
                        if lower.hasPrefix("x-filename:") {
                            let v = line.dropFirst("x-filename:".count).trimmingCharacters(in: .whitespaces)
                            if !v.isEmpty { filename = v }
                        }
                    }
                    
                    let dest = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
                    var finalURL = dest.appendingPathComponent(filename)
                    
                    // Prevent overwriting existing files
                    var i = 1
                    let base = finalURL.deletingPathExtension().lastPathComponent
                    let ext = finalURL.pathExtension
                    while FileManager.default.fileExists(atPath: finalURL.path) {
                        let name = ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"
                        finalURL = dest.appendingPathComponent(name)
                        i += 1
                    }

                    if (try? bodyData.write(to: finalURL)) != nil {
                        DispatchQueue.main.async {
                            // Just save it as a completed file download in the UI, do not fetch torrent contents
                            let item = DownloadItem(url: URL(string: "data:blank")!, filename: finalURL.lastPathComponent, destination: dest)
                            item.status = .completed
                            item.totalBytes = Int64(bodyData.count)
                            item.downloadedBytes = Int64(bodyData.count)
                            item.dateCompleted = Date()
                            item.destinationURL = finalURL
                            
                            DownloadEngine.shared.items.insert(item, at: 0)
                            DownloadEngine.shared.persist()
                            NSApp.activate(ignoringOtherApps: true)
                        }
                    }
                    connection.send(content: resHeaders.data(using: .utf8)!, completion: .contentProcessed { _ in connection.cancel() })
                    return
                }

                if headers.hasPrefix("POST") {
                    if let payload = try? JSONDecoder().decode(DownloadPayload.self, from: bodyData) {
                        DispatchQueue.main.async { self.showConfirmation(for: payload) }
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
        guard let url = URL(string: payload.url) else { return }
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(
            name: .confirmDownload,
            object: nil,
            userInfo: [
                "url":      url,
                "filename": payload.filename ?? "",
                "cookies":  payload.cookies  ?? "",
                "referer":  payload.referer  ?? "",
                "ua":       payload.ua       ?? ""
            ]
        )
    }
}
