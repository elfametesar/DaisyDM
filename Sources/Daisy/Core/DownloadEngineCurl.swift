import Foundation

extension DownloadEngine {
    
    func runCurl(_ item: DownloadItem) async {
        await MainActor.run { item._managesOwnSpeed = false }
        let tempDir = await MainActor.run { item.tempDirURL }
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        await MainActor.run {
            if !item.isPrepared {
                let policy = UserDefaults.standard.string(forKey: "fileCollisionBehavior") ?? "rename"
                if policy == "replace" { try? FileManager.default.removeItem(at: item.destinationURL) }
                else { item.destinationURL = uniqueURL(item.destinationURL) }
                FileManager.default.createFile(atPath: item.destinationURL.path, contents: nil)
                item.isPrepared = true; persist()
            }
        }

        let destFile        = await MainActor.run { item.destinationURL.path }
        let url             = await MainActor.run { item.url }
        let cookies         = await MainActor.run { item.cookies }
        let userAgent       = await MainActor.run { item.userAgent }
        let referer         = await MainActor.run { item.referer }
        let extraHeaders    = await MainActor.run { item.headers }
        let speedLimit      = await MainActor.run { item.speedLimit }
        let downloadedBytes = await MainActor.run { item.downloadedBytes }

        let headersFile = tempDir.appendingPathComponent("headers.txt").path
        let proc = Process(); proc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")

        var args: [String] = [
            "--location-trusted", "--silent", "--show-error", "--compressed",
            "--write-out", "\n%{http_code} %{size_download}\n", "--output", destFile, "--dump-header", headersFile
        ]

        if downloadedBytes > 0 { args.append(contentsOf: ["-C", "-"]) }
        if speedLimit > 0 { args.append(contentsOf: ["--limit-rate", "\(speedLimit)K"]) }
        
        if let cookies = cookies, !cookies.isEmpty {
            if cookies.hasPrefix("# Netscape") {
                let cookieFile = tempDir.appendingPathComponent("cookies.txt")
                try? cookies.write(to: cookieFile, atomically: true, encoding: .utf8)
                args.append(contentsOf: ["--cookie", cookieFile.path])
            } else { args.append(contentsOf: ["--cookie", cookies]) }
        }
        
        if let ref = referer, !ref.isEmpty { args.append(contentsOf: ["--referer", ref]) }
        let host = url.host ?? ""
        args.append(contentsOf: ["--header", "Origin: https://\(host)"])

        let isMedia = isMediaFileURL(url)
        if isMedia {
            args.append(contentsOf: ["--header", "Sec-Fetch-Dest: video"])
            args.append(contentsOf: ["--header", "Sec-Fetch-Mode: no-cors"])
        } else {
            args.append(contentsOf: ["--header", "Sec-Fetch-Dest: document"])
            args.append(contentsOf: ["--header", "Sec-Fetch-Mode: navigate"])
            args.append(contentsOf: ["--header", "Sec-Fetch-User: ?1"])
        }
        
        let ua = (userAgent != nil && !userAgent!.isEmpty) ? userAgent! : "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        args.append(contentsOf: ["--user-agent", ua])
        args.append(contentsOf: [
            "--header", "Sec-Ch-Ua: \"Google Chrome\";v=\"131\", \"Chromium\";v=\"131\", \"Not_A Brand\";v=\"24\"",
            "--header", "Sec-Ch-Ua-Mobile: ?0", "--header", "Sec-Ch-Ua-Platform: \"macOS\"",
            "--header", "Accept: */*",
            "--header", "Accept-Language: en-US,en;q=0.9"
        ])

        // Extension'dan gelen tüm başlıkları enjekte et
        let skipKeys: Set<String> = [
            "referer", "origin", "user-agent", "accept", "accept-language",
            "accept-encoding", "sec-fetch-site", "sec-fetch-dest", "sec-fetch-mode",
            "sec-fetch-user", "sec-ch-ua", "sec-ch-ua-mobile", "sec-ch-ua-platform",
            "cookie", "host", "content-length", "connection", "upgrade-insecure-requests"
        ]

        if let headers = extraHeaders {
            for (key, value) in headers {
                if !skipKeys.contains(key.lowercased()) {
                    args.append(contentsOf: ["--header", "\(key): \(value)"])
                }
            }
        }

        args.append(url.absoluteString)
        proc.arguments = args

        let stderrPipe = Pipe(); let stdoutPipe = Pipe(); proc.standardError = stderrPipe; proc.standardOutput = stdoutPipe

        let pollTask = Task { [weak item] in
            guard let item else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if let vals = try? URL(fileURLWithPath: destFile).resourceValues(forKeys: [.fileSizeKey]) {
                    let sz = Int64(vals.fileSize ?? 0)
                    await MainActor.run { item.downloadedBytes = sz; if item.totalBytes > 0 && sz > item.totalBytes { item.totalBytes = sz } }
                }
                
                if let headersStr = try? String(contentsOfFile: headersFile, encoding: .utf8) {
                    let lines = headersStr.components(separatedBy: .newlines)
                    let currentTotal = await MainActor.run { item.totalBytes }
                    if currentTotal <= 0 {
                        var foundTotal: Int64 = 0; var isPartial = false
                        for line in lines {
                            let l = line.lowercased()
                            if l.hasPrefix("http/") && l.contains(" 206") { isPartial = true }
                            if l.hasPrefix("content-length:") && !isPartial {
                                foundTotal = Int64(l.dropFirst(15).trimmingCharacters(in: .whitespaces)) ?? 0
                            } else if l.hasPrefix("content-range:") {
                                if let totalStr = l.components(separatedBy: "/").last, let t = Int64(totalStr.trimmingCharacters(in: .whitespaces)) { foundTotal = t }
                            }
                        }
                        if foundTotal > 0 { await MainActor.run { item.totalBytes = foundTotal } }
                    }

                    let needsFilename = await MainActor.run { item.filename == "download" || item.filename.starts(with: "download_") || item.filename.starts(with: "attachment_") }
                    if needsFilename {
                        for line in lines {
                            guard line.lowercased().hasPrefix("content-disposition:") else { continue }
                            var fn = ""
                            if let r = line.range(of: "filename*=", options: .caseInsensitive) {
                                var raw = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                                if let q = raw.range(of: "''") { raw = String(raw[q.upperBound...]) }
                                fn = (raw.removingPercentEncoding ?? raw).components(separatedBy: ";").first?.trimmingCharacters(in: .init(charactersIn: "\"' \r\n")) ?? ""
                            } else if let r = line.range(of: "filename=", options: .caseInsensitive) {
                                fn = String(line[r.upperBound...]).trimmingCharacters(in: .init(charactersIn: "\"' \r\n")).components(separatedBy: ";").first?.trimmingCharacters(in: .init(charactersIn: "\"' \r\n")) ?? ""
                            }
                            if !fn.isEmpty {
                                await MainActor.run {
                                    let dir = item.destinationURL.deletingLastPathComponent(); let newDest = self.uniqueURL(dir.appendingPathComponent(fn))
                                    item.filename = fn; item.destinationURL = newDest
                                }
                                break
                            }
                        }
                    }
                }
            }
        }

        await MainActor.run { item._lastBytes = item.downloadedBytes; item._lastTickDate = Date(); item.processes.append(proc) }

        var didLaunch = false
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            proc.terminationHandler = { _ in cont.resume() }
            do { try proc.run(); didLaunch = true } catch { cont.resume() }
        }

        pollTask.cancel()

        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile(); let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrText = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stdoutText = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let isStillTracked = await MainActor.run {
            let tracked = item.processes.contains(where: { $0 === proc })
            item.processes.removeAll { $0 === proc }
            return tracked
        }
        let currentStatus = await MainActor.run { item.status }

        guard didLaunch else {
            if currentStatus == .downloading && isStillTracked {
                await MainActor.run { item.status = .failed; item.error = "Failed to launch curl."; item.speed = 0; item._lastTickDate = nil; persist(); scheduleNext() }
            }
            return
        }

        if proc.terminationStatus == 0 {
            let httpStatus: Int? = stdoutText.components(separatedBy: "\n").compactMap { Int($0.split(separator: " ").first ?? "") }.last
            if let status = httpStatus, status >= 400 {
                let errorMsg = curlHumanError(exitCode: proc.terminationStatus, stderr: stderrText, stdout: stdoutText)
                let r = await MainActor.run { item.retryCount }
                let maxRetries = UserDefaults.standard.object(forKey: "maxRetryCount") as? Int ?? 3
                if r < maxRetries && status != 401 && status != 403 && status != 404 {
                    await MainActor.run { item.retryCount += 1; item.status = .queued; item.speed = 0; item._lastTickDate = nil }
                    try? await Task.sleep(nanoseconds: 2_000_000_000); await MainActor.run { scheduleNext() }
                } else {
                    await MainActor.run { item.status = .failed; item.error = errorMsg; item.speed = 0; item._lastTickDate = nil; persist(); scheduleNext() }
                }
            } else {
                let finalDest = await MainActor.run { item.destinationURL }
                if finalDest.path != destFile && FileManager.default.fileExists(atPath: destFile) {
                    _ = try? FileManager.default.removeItem(at: finalDest); try? FileManager.default.moveItem(atPath: destFile, toPath: finalDest.path)
                }
                
                if let attr = try? FileManager.default.attributesOfItem(atPath: finalDest.path), let fileSize = attr[.size] as? NSNumber {
                    await MainActor.run { item.downloadedBytes = fileSize.int64Value; if item.totalBytes == 0 || item.totalBytes < fileSize.int64Value { item.totalBytes = fileSize.int64Value } }
                }
                
                await MainActor.run {
                    if let line = stdoutText.components(separatedBy: "\n").last(where: { !$0.isEmpty }) {
                        let parts = line.split(separator: " ")
                        if parts.count >= 2, let sz = Int64(parts[1]), sz > 0 {
                            if sz > item.downloadedBytes { item.downloadedBytes = sz }
                            if item.totalBytes == 0 { item.totalBytes = sz }
                        }
                    }
                    if item.totalBytes > 0 { item.downloadedBytes = item.totalBytes }
                    item.status = .completed; item.dateCompleted = Date(); item.speed = 0; item._lastTickDate = nil
                    self.notifyCompletion(for: item); persist(); scheduleNext()
                }
            }
        } else if currentStatus == .downloading && isStillTracked {
            let errorMsg = curlHumanError(exitCode: proc.terminationStatus, stderr: stderrText, stdout: stdoutText)
            let r = await MainActor.run { item.retryCount }
            let maxRetries = UserDefaults.standard.object(forKey: "maxRetryCount") as? Int ?? 3
            if r < maxRetries {
                await MainActor.run { item.retryCount += 1; item.status = .queued; item.speed = 0; item._lastTickDate = nil }
                try? await Task.sleep(nanoseconds: 2_000_000_000); await MainActor.run { scheduleNext() }
            } else {
                await MainActor.run { item.status = .failed; item.error = errorMsg; item.speed = 0; item._lastTickDate = nil; persist(); scheduleNext() }
            }
        }
    }


    nonisolated func isMediaFileURL(_ url: URL) -> Bool {
        let mediaExtensions: Set<String> = ["mp4","webm","mov","mkv","avi","flv","ts","m4v","m4a","mp3","aac","ogg","opus","m3u8","mpd"]
        let ext = url.pathExtension.lowercased()
        if mediaExtensions.contains(ext) { return true }
        let path = url.path.lowercased()
        return path.contains("/video/") || path.contains("/media/") || path.contains("/stream/")
            || path.contains("/hls/") || path.contains("videoid") || path.contains("/mp4")
    }
}
