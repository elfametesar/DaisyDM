import Foundation

extension DownloadEngine {
    
    func fetchMetadata(url: URL, userAgent: String?, cookies: String?) async -> (size: Int64, filename: String?) {
        let ua = (userAgent != nil && !userAgent!.isEmpty) ? userAgent! : "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        request.timeoutInterval = 10
        request.setValue(ua, forHTTPHeaderField: "User-Agent")
        if let c = cookies, !c.isEmpty { request.setValue(c, forHTTPHeaderField: "Cookie") }
        
        var size: Int64 = 0
        var filename: String? = nil
        
        func extract(from response: URLResponse?) {
            guard let httpResp = response as? HTTPURLResponse else { return }
            if let cr = httpResp.value(forHTTPHeaderField: "Content-Range"),
               let totalStr = cr.components(separatedBy: "/").last, let len = Int64(totalStr) {
                size = len
            } else if let lenStr = httpResp.value(forHTTPHeaderField: "Content-Length"), let len = Int64(lenStr) {
                size = len
            }
            if let cd = httpResp.value(forHTTPHeaderField: "Content-Disposition") {
                if let r = cd.range(of: "filename*=", options: .caseInsensitive) {
                    var raw = String(cd[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if let q = raw.range(of: "''") { raw = String(raw[q.upperBound...]) }
                    filename = (raw.removingPercentEncoding ?? raw).components(separatedBy: ";").first?.trimmingCharacters(in: .init(charactersIn: "\"' \r\n"))
                } else if let r = cd.range(of: "filename=", options: .caseInsensitive) {
                    filename = String(cd[r.upperBound...]).trimmingCharacters(in: .init(charactersIn: "\"' \r\n")).components(separatedBy: ";").first?.trimmingCharacters(in: .init(charactersIn: "\"' \r\n"))
                }
            }
        }
        
        do { let (_, response) = try await URLSession.shared.data(for: request); extract(from: response) } catch {}
        if size == 0 {
            request.httpMethod = "HEAD"; request.setValue(nil, forHTTPHeaderField: "Range")
            do { let (_, response) = try await URLSession.shared.data(for: request); extract(from: response) } catch {}
        }
        return (size, filename)
    }

    func resolveFuckingFast(_ url: URL) async -> URL? {
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        guard let (data, resp) = try? await URLSession.shared.data(for: request),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else { return nil }
        
        guard let dlRange = html.range(of: "fuckingfast.co/dl/") else { return nil }
        let before = html[html.startIndex..<dlRange.lowerBound]
        guard let quoteStart = before.lastIndex(where: { $0 == "'" || $0 == "\"" }) else { return nil }
        let quoteChar = html[quoteStart]
        let urlStart = html.index(after: quoteStart)
        guard let quoteEnd = html[urlStart...].firstIndex(of: quoteChar) else { return nil }
        let urlString = String(html[urlStart..<quoteEnd])
        return URL(string: urlString)
    }

    func suggestFilename(from url: URL) -> String {
        if url.scheme == "data" { return "attachment_\(Int(Date().timeIntervalSince1970))" }
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        c?.query = nil
        let last = (c?.url ?? url).lastPathComponent
        let dec = last.removingPercentEncoding ?? last
        return (!dec.isEmpty && dec != "/") ? dec : "download_\(Int(Date().timeIntervalSince1970))"
    }

    func suggestMagnetName(from url: URL) -> String {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let dn = comps.queryItems?.first(where: { $0.name == "dn" })?.value else {
            return "Torrent_\(Int(Date().timeIntervalSince1970))"
        }
        return dn.removingPercentEncoding ?? dn
    }

    func uniqueURL(_ url: URL) -> URL {
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

    func writeDataURL(_ item: DownloadItem) async {
        let dataURL = item.url.absoluteString
        guard let commaIdx = dataURL.firstIndex(of: ",") else {
            await MainActor.run { item.status = .failed; item.error = "Invalid data URL — missing comma separator."; item.speed = 0; persist(); scheduleNext() }
            return
        }

        let header  = String(dataURL[dataURL.index(after: dataURL.startIndex)..<commaIdx])
        let body    = String(dataURL[dataURL.index(after: commaIdx)...])
        let isBase64 = header.contains("base64")
        let mime    = header.split(separator: ";").first.map(String.init) ?? ""

        guard let data = isBase64 ? Data(base64Encoded: body, options: .ignoreUnknownCharacters) : body.removingPercentEncoding?.data(using: .utf8) else {
            await MainActor.run { item.status = .failed; item.error = "Failed to decode attachment data."; item.speed = 0; persist(); scheduleNext() }
            return
        }

        let dest = await MainActor.run { item.destinationURL.deletingLastPathComponent() }
        var fn   = await MainActor.run { item.filename }
        if fn.isEmpty || fn == "download" || fn.starts(with: "download_") || fn.starts(with: "attachment_") { fn = "attachment\(mimeToExt(mime))" }
        let finalDest = uniqueURL(dest.appendingPathComponent(fn))

        do { try data.write(to: finalDest) }
        catch {
            await MainActor.run { item.status = .failed; item.error = "Failed to write file: \(error.localizedDescription)"; item.speed = 0; persist(); scheduleNext() }
            return
        }

        await MainActor.run {
            item.filename = fn; item.destinationURL = finalDest
            if fn.lowercased().hasSuffix(".torrent") {
                let downloadAsFile = UserDefaults.standard.bool(forKey: "downloadTorrentsAsFiles")
                if downloadAsFile {
                    item.totalBytes = Int64(data.count); item.downloadedBytes = Int64(data.count)
                    item.status = .completed; item.dateCompleted = Date(); item.speed = 0
                    self.notifyCompletion(for: item); persist(); scheduleNext()
                } else {
                    item.url = finalDest; item.type = .torrent; item.status = .queued
                    item.downloadedBytes = 0; item.totalBytes = 0; item.speed = 0
                    persist(); scheduleNext()
                }
            } else {
                item.totalBytes = Int64(data.count); item.downloadedBytes = Int64(data.count)
                item.status = .completed; item.dateCompleted = Date(); item.speed = 0
                self.notifyCompletion(for: item); persist(); scheduleNext()
            }
        }
    }

    func mimeToExt(_ mime: String) -> String {
        switch mime {
        case "video/mp4": return ".mp4"; case "video/webm": return ".webm"; case "audio/mpeg": return ".mp3"; case "audio/mp4": return ".m4a"
        case "application/zip": return ".zip"; case "application/pdf": return ".pdf"; case "image/jpeg": return ".jpg"; case "image/png": return ".png"
        case "image/gif": return ".gif"; case "application/octet-stream": return ".bin"; default: return ""
        }
    }

    nonisolated func parseAriaSize(_ str: String) -> Int64 {
        let s = str.uppercased().trimmingCharacters(in: .whitespaces)
        var multiplier: Double = 1; var numStr = s
        if s.hasSuffix("KIB") { multiplier = 1024; numStr = String(s.dropLast(3)) }
        else if s.hasSuffix("KB") { multiplier = 1000; numStr = String(s.dropLast(2)) }
        else if s.hasSuffix("MIB") { multiplier = 1024 * 1024; numStr = String(s.dropLast(3)) }
        else if s.hasSuffix("MB") { multiplier = 1000 * 1000; numStr = String(s.dropLast(2)) }
        else if s.hasSuffix("GIB") { multiplier = 1024 * 1024 * 1024; numStr = String(s.dropLast(3)) }
        else if s.hasSuffix("GB") { multiplier = 1000 * 1000 * 1000; numStr = String(s.dropLast(2)) }
        else if s.hasSuffix("TIB") { multiplier = 1024 * 1024 * 1024 * 1024; numStr = String(s.dropLast(3)) }
        else if s.hasSuffix("TB") { multiplier = 1000 * 1000 * 1000 * 1000; numStr = String(s.dropLast(2)) }
        else if s.hasSuffix("B") { multiplier = 1; numStr = String(s.dropLast(1)) }
        if let val = Double(numStr) { return Int64(val * multiplier) }
        return 0
    }

    func aria2HumanError(exitCode: Int32) -> String {
        switch exitCode {
        case 2:  return "Connection timed out."
        case 3:  return "HTTP 404 Not Found — the resource was not found."
        case 6:  return "Network problem — connection reset or dropped."
        case 8:  return "Server does not support resume."
        case 9:  return "Not enough disk space."
        case 11: return "File is already being downloaded."
        case 13: return "File already exists."
        case 16, 17, 18: return "File I/O error — could not write to disk."
        case 19: return "Name resolution failed — check your internet connection or the URL host."
        case 22: return "HTTP Error — the server rejected the request (e.g., 403 Forbidden or 500 Error)."
        case 23: return "Too many redirects."
        case 24: return "HTTP 401 Unauthorized — authentication failed."
        default: return "Download failed (aria2 error \(exitCode))."
        }
    }

    func curlHumanError(exitCode: Int32, stderr: String, stdout: String) -> String {
        let httpStatus: Int? = stdout.components(separatedBy: "\n").compactMap { Int($0.split(separator: " ").first ?? "") }.last
        if let status = httpStatus, status >= 400 {
            switch status {
            case 400: return "HTTP 400 Bad Request."
            case 401: return "HTTP 401 Unauthorized — login required. Add cookies in Download Properties."
            case 403: return "HTTP 403 Forbidden — access denied. The URL may require authentication or has expired."
            case 404: return "HTTP 404 Not Found — the file no longer exists at this URL."
            case 407: return "HTTP 407 Proxy Authentication Required."
            case 408: return "HTTP 408 Request Timeout."
            case 410: return "HTTP 410 Gone — the file has been permanently removed."
            case 429: return "HTTP 429 Too Many Requests — rate limited, wait and retry."
            case 500: return "HTTP 500 Internal Server Error."
            case 502: return "HTTP 502 Bad Gateway."
            case 503: return "HTTP 503 Service Unavailable."
            default:  return "HTTP \(status) error."
            }
        }
        switch exitCode {
        case 6:  return "Could not resolve host — check your internet connection."
        case 7:  return "Failed to connect to server."
        case 18: return "Partial download — connection was interrupted."
        case 23: return "Failed to write to disk — check available space."
        case 28: return "Connection timed out."
        case 33: return "Server does not support range requests (resume)."
        case 35: return "SSL/TLS handshake failed."
        case 47: return "Too many redirects."
        case 52: return "Server returned no data."
        case 56: return "Network connection was reset."
        default: let detail = stderr.isEmpty ? "" : "\n\n\(stderr)"; return "Download failed (curl error \(exitCode)).\(detail)"
        }
    }
}
