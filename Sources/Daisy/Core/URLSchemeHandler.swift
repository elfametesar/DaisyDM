// MARK: - URLSchemeHandler.swift
import AppKit
import Foundation

public final class URLSchemeHandler {
    public static let scheme = "daisy"

    public static func handle(_ url: URL) {
        guard url.scheme == scheme else { return }

        if url.host == "open" {
            Task { @MainActor in NSApp.activate(ignoringOtherApps: true) }
            return
        }

        guard url.host == "download",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let urlParam = components.queryItems?.first(where: { $0.name == "url" })?.value
        else { return }

        let cookies   = components.queryItems?.first(where: { $0.name == "cookies"  })?.value
        let userAgent = components.queryItems?.first(where: { $0.name == "ua"       })?.value
        let referer   = components.queryItems?.first(where: { $0.name == "referer"  })?.value
        let filename  = components.queryItems?.first(where: { $0.name == "filename" })?.value

        Task { @MainActor in
            let engine = DownloadEngine.shared
            let dest   = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!

            // Support reading batch extension pushes via text/uri-list
            if urlParam.hasPrefix("data:text/uri-list") || urlParam.hasPrefix("data:text/plain") {
                if let data = extractData(from: urlParam), let text = String(data: data, encoding: .utf8) {
                    let urls = text.components(separatedBy: .whitespacesAndNewlines)
                        .filter { !$0.isEmpty }
                        .compactMap { URL(string: $0) }
                        .filter { $0.scheme?.hasPrefix("http") == true || $0.scheme == "magnet" }
                    
                    if !urls.isEmpty {
                        engine.addDownload(
                            urls: urls,
                            destination: dest,
                            connections: 16,
                            cookies: cookies,
                            userAgent: userAgent,
                            referer: referer,
                            filename: filename
                        )
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
                return
            }

            if urlParam.hasPrefix("data:") {
                handleDataURL(urlParam, filename: filename, destination: dest, engine: engine)
                NSApp.activate(ignoringOtherApps: true)
                return
            }

            guard let downloadURL = URL(string: urlParam) else { return }

            engine.addDownload(
                urls: [downloadURL],
                destination: dest,
                connections: 16,
                cookies: cookies,
                userAgent: userAgent,
                referer: referer,
                filename: filename
            )
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private static func extractData(from dataURL: String) -> Data? {
        guard let commaIdx = dataURL.firstIndex(of: ",") else { return nil }
        let header = String(dataURL[dataURL.index(after: dataURL.startIndex)..<commaIdx])
        let body   = String(dataURL[dataURL.index(after: commaIdx)...])
        
        if header.contains("base64") {
            return Data(base64Encoded: body, options: .ignoreUnknownCharacters)
        } else {
            return body.removingPercentEncoding?.data(using: .utf8)
        }
    }

    private static func handleDataURL(_ dataURL: String, filename: String?, destination: URL, engine: DownloadEngine) {
        guard let data = extractData(from: dataURL) else { return }
        
        guard let commaIdx = dataURL.firstIndex(of: ",") else { return }
        let header = String(dataURL[dataURL.index(after: dataURL.startIndex)..<commaIdx])
        let mime = header.split(separator: ";").first.map(String.init) ?? ""
        
        let fn = (filename?.isEmpty == false) ? filename! : "download\(mimeToExt(mime))"
        let finalDest = uniqueURL(destination.appendingPathComponent(fn))

        do {
            try data.write(to: finalDest)
            if finalDest.pathExtension.lowercased() == "torrent" {
                Task { @MainActor in
                    engine.addDownload(
                        urls: [finalDest],
                        destination: destination,
                        connections: 16,
                        cookies: nil,
                        userAgent: nil,
                        referer: nil,
                        filename: nil
                    )
                }
                return
            }
        } catch { return }

        // .torrent files saved from blob: URLs should be queued as torrent downloads, not marked complete
        let isTorrent = finalDest.pathExtension.lowercased() == "torrent"
        if isTorrent {
            Task { @MainActor in
                engine.addDownload(
                    urls: [finalDest],
                    destination: destination,
                    connections: 16,
                    cookies: nil,
                    userAgent: nil,
                    referer: nil,
                    filename: nil
                )
            }
            return
        }

        Task { @MainActor in
            let item = DownloadItem(url: URL(string: "data:blank")!, filename: fn, destination: destination)
            item.status = .completed
            item.totalBytes = Int64(data.count)
            item.downloadedBytes = Int64(data.count)
            item.dateCompleted = Date()
            item.destinationURL = finalDest
            engine.items.insert(item, at: 0)
            engine.persist()
        }
    }

    private static func mimeToExt(_ mime: String) -> String {
        switch mime {
        case "video/mp4": return ".mp4"
        case "video/webm": return ".webm"
        case "audio/mpeg": return ".mp3"
        case "audio/mp4": return ".m4a"
        case "application/zip": return ".zip"
        case "application/pdf": return ".pdf"
        case "image/jpeg": return ".jpg"
        case "image/png": return ".png"
        case "image/gif": return ".gif"
        case "application/octet-stream": return ".bin"
        default: return ""
        }
    }

    private static func uniqueURL(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let ext = url.pathExtension, base = url.deletingPathExtension().lastPathComponent
        let dir = url.deletingLastPathComponent()
        var i = 1
        while true {
            let name = ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"
            let u = dir.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: u.path) { return u }
            i += 1
        }
    }
}
