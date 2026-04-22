import Foundation

extension DownloadEngine {
    
    func runAria2(_ item: DownloadItem, executable: String) async {
        await MainActor.run { item._managesOwnSpeed = true }
        
        let tempDir = await MainActor.run { item.tempDirURL }
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        if item.type == .torrent && item.subFiles.isEmpty {
            let files = await fetchTorrentInfo(item: item, executable: executable)
            await MainActor.run {
                if !files.isEmpty { item.subFiles = files; item.totalBytes = files.map { $0.totalBytes }.reduce(0, +) }
            }
            let stillEmpty = await MainActor.run { item.subFiles.isEmpty }
            if stillEmpty && item.url.isFileURL {
                await MainActor.run {
                    item.status = .failed; item.error = "Failed to parse .torrent file metadata."; item.speed = 0
                    persist(); scheduleNext()
                }
                return
            }
        }

        await MainActor.run {
            if !item.isPrepared {
                let policy = UserDefaults.standard.string(forKey: "fileCollisionBehavior") ?? "rename"
                if item.type != .torrent && item.type != .batch {
                    if policy == "replace" { try? FileManager.default.removeItem(at: item.destinationURL) }
                    else { item.destinationURL = uniqueURL(item.destinationURL) }
                    FileManager.default.createFile(atPath: item.destinationURL.path, contents: nil)
                } else if item.type == .batch {
                    item.destinationURL = uniqueURL(item.destinationURL)
                    try? FileManager.default.createDirectory(at: item.destinationURL, withIntermediateDirectories: true)
                }
                item.isPrepared = true; persist()
            }
        }

        let proc = Process(); proc.executableURL = URL(fileURLWithPath: executable)
        var didLaunch = false

        let destDir      = tempDir.path
        let fileName     = await MainActor.run { item.filename }
        let conns        = await MainActor.run { item.connectionCount }
        let type         = await MainActor.run { item.type }
        let url          = await MainActor.run { item.url }
        let speedLimit   = await MainActor.run { item.speedLimit }
        let cookies      = await MainActor.run { item.cookies }
        let userAgent    = await MainActor.run { item.userAgent }
        let referer      = await MainActor.run { item.referer }
        let extraHeaders = await MainActor.run { item.headers }

        var args = [
            "--dir=\(destDir)", "--continue=true", "--file-allocation=none",
            "--max-connection-per-server=\(conns)", "--split=\(conns)", "--min-split-size=1M",
            "--seed-time=0", "--auto-file-renaming=false", "--summary-interval=1", "--console-log-level=notice"
        ]

        if speedLimit > 0 { args.append("--max-overall-download-limit=\(speedLimit)K") }
        if type != .torrent && type != .batch { args.append("--out=\(fileName)") }
        
        let skipKeys: Set<String> = ["range", "connection", "accept-encoding", "host", "content-length"]
        var appliedKeys = Set<String>()

        if let headers = extraHeaders {
            for (key, value) in headers {
                let lowerKey = key.lowercased()
                if skipKeys.contains(lowerKey) { continue }
                if lowerKey == "cookie" { continue } // Handled below safely
                args.append("--header=\(key): \(value)")
                appliedKeys.insert(lowerKey)
            }
        }

        // Apply cookies
        if let cookies = cookies, !cookies.isEmpty {
            if cookies.hasPrefix("# Netscape") {
                let cookieFile = tempDir.appendingPathComponent("cookies.txt")
                try? cookies.write(to: cookieFile, atomically: true, encoding: .utf8)
                args.append("--load-cookies=\(cookieFile.path)")
            } else {
                args.append("--header=Cookie: \(cookies)")
            }
        } else if let headers = extraHeaders, let c = headers.first(where: { $0.key.lowercased() == "cookie" })?.value {
            args.append("--header=Cookie: \(c)")
        }

        // ONLY fallback to defaults if the Safari network stream didn't provide them
        if !appliedKeys.contains("referer"), let ref = referer, !ref.isEmpty {
            args.append("--referer=\(ref)")
        }
        
        if !appliedKeys.contains("user-agent") {
            let ua = (userAgent != nil && !userAgent!.isEmpty) ? userAgent! : "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
            args.append("--user-agent=\(ua)")
        }

        if !appliedKeys.contains("accept") { args.append("--header=Accept: */*") }
        if !appliedKeys.contains("accept-language") { args.append("--header=Accept-Language: en-US,en;q=0.9") }
        if !appliedKeys.contains("sec-ch-ua") {
            args.append("--header=Sec-Ch-Ua: \"Google Chrome\";v=\"131\", \"Chromium\";v=\"131\", \"Not_A Brand\";v=\"24\"")
            args.append("--header=Sec-Ch-Ua-Mobile: ?0")
            args.append("--header=Sec-Ch-Ua-Platform: \"macOS\"")
        }
        if !appliedKeys.contains("origin") {
            let hostStr = url.host ?? ""
            args.append("--header=Origin: https://\(hostStr)")
        }

        let isMedia = isMediaFileURL(url)
        if isMedia {
            if !appliedKeys.contains("sec-fetch-dest") { args.append("--header=Sec-Fetch-Dest: video") }
            if !appliedKeys.contains("sec-fetch-mode") { args.append("--header=Sec-Fetch-Mode: no-cors") }
        } else {
            if !appliedKeys.contains("sec-fetch-dest") { args.append("--header=Sec-Fetch-Dest: document") }
            if !appliedKeys.contains("sec-fetch-mode") { args.append("--header=Sec-Fetch-Mode: navigate") }
            if !appliedKeys.contains("sec-fetch-user") { args.append("--header=Sec-Fetch-User: ?1") }
            if !appliedKeys.contains("upgrade-insecure-requests") { args.append("--header=Upgrade-Insecure-Requests: 1") }
        }

        if type == .torrent {
            args += [
                "--enable-dht=true", "--bt-enable-lpd=true", "--enable-peer-exchange=true", "--bt-save-metadata=true",
                "--dht-listen-port=6881-6999",
                "--bt-tracker=udp://tracker.opentrackr.org:1337/announce,udp://open.stealth.si:80/announce,udp://tracker.torrent.eu.org:451/announce,udp://tracker.dler.org:6969/announce,udp://exodus.desync.com:6969/announce,udp://retracker.lanta-net.ru:2710/announce,udp://tracker.moeking.me:6969/announce,udp://tracker.pomf.se:80/announce,udp://tracker.publicbt.com:80/announce,udp://tracker.tiny-vps.com:6969/announce,udp://tracker.files.fm:6969/announce"
            ]
        }
        
        if type == .batch {
            let listPath = tempDir.appendingPathComponent("batch_list.txt")
            let (listContent, allFinished) = await MainActor.run {
                guard let urls = item.batchURLs else { return ("", false) }
                var active: [String] = []
                var fullyDownloadedCount = 0
                for (i, url) in urls.enumerated() {
                    if i < item.subFiles.count {
                        let f = item.subFiles[i]
                        let isFinished = f.totalBytes > 0 && f.downloadedBytes >= f.totalBytes
                        if isFinished {
                            fullyDownloadedCount += 1
                        } else if !f.isStopped {
                            active.append("\(url)\n  out=\(f.path)")
                        }
                    }
                }
                return (active.joined(separator: "\n"), fullyDownloadedCount == urls.count)
            }
            
            if allFinished {
                await MainActor.run {
                    item.status = .completed; item.dateCompleted = Date(); self.notifyCompletion(for: item)
                    persist(); scheduleNext()
                }
                return
            } else if listContent.isEmpty {
                await MainActor.run { stop(item, stopSubFiles: false) }
                return
            }
            
            try? listContent.write(to: listPath, atomically: true, encoding: .utf8)
            args.append("-i"); args.append(listPath.path)
            args.append("-j1")
        } else if type == .torrent {
            let activeIndices = await MainActor.run {
                item.subFiles.filter { !$0.isStopped && ($0.totalBytes == 0 || $0.downloadedBytes < $0.totalBytes) }.map { String($0.index) }.joined(separator: ",")
            }
            if !activeIndices.isEmpty {
                args.append("--select-file=\(activeIndices)")
            } else {
                let allFinished = await MainActor.run { !item.subFiles.isEmpty && item.subFiles.allSatisfy { $0.totalBytes > 0 && $0.downloadedBytes >= $0.totalBytes } }
                if allFinished {
                    await MainActor.run { item.status = .completed; item.dateCompleted = Date(); self.notifyCompletion(for: item); persist(); scheduleNext() }
                } else {
                    await MainActor.run { stop(item, stopSubFiles: false) }
                }
                return
            }
            args.append(url.isFileURL ? url.path : url.absoluteString)
        } else {
            args.append(url.isFileURL ? url.path : url.absoluteString)
        }

        proc.arguments = args
        let stdoutPipe = Pipe(); proc.standardOutput = stdoutPipe; proc.standardError = FileHandle.nullDevice
        
        let sizeSnifferTask = Task { [weak item] in
            guard let item else { return }
            
            let itemType = await MainActor.run { item.type }
            var currentBatchGID: String? = nil
            var activeBatchIndex: Int = 0
            
            if itemType == .batch {
                activeBatchIndex = await MainActor.run {
                    item.subFiles.firstIndex(where: { !$0.isStopped && ($0.totalBytes == 0 || $0.downloadedBytes < $0.totalBytes) }) ?? 0
                }
            }
            
            for try await line in stdoutPipe.fileHandleForReading.bytes.lines {
                if line.contains("Length: ") {
                    if let range = line.range(of: "Length: ") {
                        let sub = line[range.upperBound...]
                        let bytesStr = sub.prefix(while: { $0.isNumber })
                        if let bytes = Int64(bytesStr), bytes > 0 {
                            await MainActor.run { if item.type == .directLink && item.totalBytes == 0 { item.totalBytes = bytes } }
                        }
                    }
                }
                
                if line.contains("[#") && line.contains("DL:") {
                    var currentGID: String? = nil
                    if let gidRange = line.range(of: #"\[#([a-zA-Z0-9]+)"#, options: .regularExpression) {
                        currentGID = String(line[gidRange].dropFirst(2))
                    }

                    if itemType == .batch, let gid = currentGID {
                        if currentBatchGID == nil {
                            currentBatchGID = gid
                        } else if currentBatchGID != gid {
                            currentBatchGID = gid
                            await MainActor.run {
                                activeBatchIndex += 1
                                while activeBatchIndex < item.subFiles.count {
                                    let f = item.subFiles[activeBatchIndex]
                                    if f.isStopped || (f.totalBytes > 0 && f.downloadedBytes >= f.totalBytes) {
                                        activeBatchIndex += 1
                                    } else {
                                        break
                                    }
                                }
                            }
                        }
                    }

                    if let dlRange = line.range(of: "DL:"),
                       let endRange = line[dlRange.upperBound...].firstIndex(where: { $0 == " " || $0 == "]" }) {
                        let speedStr = String(line[dlRange.upperBound..<endRange])
                        let bytes = self.parseAriaSize(speedStr)
                        if bytes > 0 { await MainActor.run { item.speed = Double(bytes); item._lastTickDate = Date() } }
                    }

                    let sizePattern = #"([\d\.]+[A-Z]iB)/([\d\.]+[A-Z]iB)"#
                    if let range = line.range(of: sizePattern, options: .regularExpression) {
                        let parts = line[range].split(separator: "/")
                        if parts.count == 2 {
                            let downloaded = self.parseAriaSize(String(parts[0]))
                            let total      = self.parseAriaSize(String(parts[1]))
                            
                            let indexToUpdate = activeBatchIndex
                            await MainActor.run {
                                if itemType == .batch {
                                    var updated = item.subFiles
                                    if indexToUpdate < updated.count {
                                        if !updated[indexToUpdate].isStopped {
                                            var changed = false
                                            if downloaded >= 0 && updated[indexToUpdate].downloadedBytes != downloaded { updated[indexToUpdate].downloadedBytes = downloaded; changed = true }
                                            if total > 0 && updated[indexToUpdate].totalBytes != total { updated[indexToUpdate].totalBytes = total; changed = true }
                                            
                                            if changed {
                                                item.subFiles = updated
                                                item.downloadedBytes = updated.reduce(0) { $0 + $1.downloadedBytes }
                                                let newTotal = updated.reduce(0) { $0 + $1.totalBytes }
                                                if newTotal > 0 { item.totalBytes = newTotal }
                                                self.items = self.items // Trigger UI Refresh instantly
                                            }
                                        }
                                    }
                                } else if itemType == .torrent {
                                    var updated = item.subFiles
                                    var changed = false
                                    
                                    if updated.count == 1 {
                                        if downloaded >= 0 && updated[0].downloadedBytes != downloaded { updated[0].downloadedBytes = downloaded; changed = true }
                                        if total > 0 && updated[0].totalBytes != total { updated[0].totalBytes = total; changed = true }
                                    } else if updated.count > 1 {
                                        // Smart Delta Distribution for Multi-File Torrents
                                        let previousTotal = updated.reduce(0) { $0 + $1.downloadedBytes }
                                        let delta = downloaded - previousTotal
                                        
                                        if delta > 0 {
                                            var remainingDelta = delta
                                            for i in 0..<updated.count {
                                                // Only route newly downloaded bytes to active, uncompleted files
                                                if !updated[i].isStopped && updated[i].totalBytes > 0 && updated[i].downloadedBytes < updated[i].totalBytes {
                                                    let space = updated[i].totalBytes - updated[i].downloadedBytes
                                                    let take = min(remainingDelta, space)
                                                    updated[i].downloadedBytes += take
                                                    remainingDelta -= take
                                                    changed = true
                                                    if remainingDelta <= 0 { break }
                                                }
                                            }
                                        }
                                        if total > 0 && item.totalBytes != total { item.totalBytes = total; changed = true }
                                    }
                                    
                                    if changed {
                                        item.subFiles = updated
                                        item.downloadedBytes = updated.reduce(0) { $0 + $1.downloadedBytes }
                                        self.items = self.items // Trigger UI Refresh instantly
                                    }
                                } else {
                                    if downloaded > 0 { item.downloadedBytes = downloaded }
                                    if total > 0 && item.totalBytes == 0 { item.totalBytes = total }
                                }
                            }
                        }
                    }

                    // Strict, bulletproof regex for fetching ALL active file progressions in a multi-file torrent (if console width allows)
                    if itemType == .torrent {
                        let filePattern = #"\(\s*(\d+)\s*\)\s*([\d\.]+[A-Za-z]*)/([\d\.]+[A-Za-z]*)"#
                        if let regex = try? NSRegularExpression(pattern: filePattern) {
                            let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
                            let matches = regex.matches(in: line, range: nsRange)
                            
                            if !matches.isEmpty {
                                await MainActor.run {
                                    var updated = item.subFiles
                                    var changed = false
                                    
                                    for match in matches {
                                        if match.numberOfRanges == 4,
                                           let idxRange = Range(match.range(at: 1), in: line),
                                           let dlRange = Range(match.range(at: 2), in: line),
                                           let totRange = Range(match.range(at: 3), in: line) {
                                            
                                            if let idx = Int(String(line[idxRange])) {
                                                let dl = self.parseAriaSize(String(line[dlRange]))
                                                let tot = self.parseAriaSize(String(line[totRange]))
                                                
                                                if let i = updated.firstIndex(where: { $0.index == idx }) {
                                                    if !updated[i].isStopped {
                                                        if dl >= 0 && updated[i].downloadedBytes != dl { updated[i].downloadedBytes = dl; changed = true }
                                                        if tot > 0 && updated[i].totalBytes != tot { updated[i].totalBytes = tot; changed = true }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    if changed {
                                        item.subFiles = updated
                                        item.downloadedBytes = updated.reduce(0) { $0 + $1.downloadedBytes }
                                        self.items = self.items // Trigger UI Refresh instantly
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        await MainActor.run { item._lastBytes = item.downloadedBytes; item._lastTickDate = Date(); item.processes.append(proc) }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            proc.terminationHandler = { _ in cont.resume() }
            do { try proc.run(); didLaunch = true } catch { cont.resume() }
        }

        sizeSnifferTask.cancel()

        let isStillTracked = await MainActor.run {
            let tracked = item.processes.contains(where: { $0 === proc })
            item.processes.removeAll { $0 === proc }
            return tracked
        }

        let status = await MainActor.run { item.status }
        guard didLaunch else {
            if status == .downloading && isStillTracked {
                await MainActor.run { item.status = .failed; item.error = "Failed to launch download engine."; item.speed = 0; item._lastTickDate = nil; persist(); scheduleNext() }
            }
            return
        }

        if proc.terminationStatus == 0 {
            let destinationURL = await MainActor.run { item.destinationURL }
            if type == .directLink {
                let downloadedFile = tempDir.appendingPathComponent(fileName)
                _ = try? FileManager.default.removeItem(at: destinationURL)
                try? FileManager.default.moveItem(at: downloadedFile, to: destinationURL)
                if let attr = try? FileManager.default.attributesOfItem(atPath: destinationURL.path), let fileSize = attr[.size] as? NSNumber {
                    await MainActor.run { item.downloadedBytes = fileSize.int64Value; if item.totalBytes == 0 || item.totalBytes < fileSize.int64Value { item.totalBytes = fileSize.int64Value } }
                }
            } else {
                let destDirURL = type == .batch ? destinationURL : destinationURL.deletingLastPathComponent()
                let subFiles = await MainActor.run { item.subFiles }
                if subFiles.isEmpty && type == .torrent {
                    if let enumerator = FileManager.default.enumerator(at: tempDir, includingPropertiesForKeys: nil) {
                        let prefix = tempDir.path + "/"
                        let fileURLs = enumerator.allObjects.compactMap { $0 as? URL }
                        for fileURL in fileURLs {
                            guard fileURL.path.hasPrefix(prefix) else { continue }
                            if fileURL.pathExtension == "torrent" || fileURL.pathExtension == "aria2" { continue }
                            var isDir: ObjCBool = false
                            if FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir), isDir.boolValue { continue }
                            let relativePath = String(fileURL.path.dropFirst(prefix.count))
                            let dst = destDirURL.appendingPathComponent(relativePath)
                            try? FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                            _ = try? FileManager.default.removeItem(at: dst); try? FileManager.default.moveItem(at: fileURL, to: dst)
                        }
                    }
                } else {
                    for file in subFiles {
                        if file.isStopped { continue }
                        let src = tempDir.appendingPathComponent(file.path); let dst = destDirURL.appendingPathComponent(file.path)
                        try? FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                        _ = try? FileManager.default.removeItem(at: dst); try? FileManager.default.moveItem(at: src, to: dst)
                    }
                }
            }
            try? FileManager.default.removeItem(at: tempDir)
            
            await MainActor.run {
                if item.totalBytes == 0 { item.totalBytes = item.downloadedBytes }
                
                let isBatchOrTorrent = item.type == .torrent || item.type == .batch
                let hasIncompleteSubFiles = item.subFiles.contains(where: { $0.totalBytes == 0 || $0.downloadedBytes < $0.totalBytes })
                
                if isBatchOrTorrent && hasIncompleteSubFiles && !item.subFiles.isEmpty {
                    item.status = .stopped
                } else {
                    if item.totalBytes > 0 { item.downloadedBytes = item.totalBytes }
                    item.status = .completed; item.dateCompleted = Date(); self.notifyCompletion(for: item)
                }
                
                item.speed = 0; item._lastTickDate = nil; persist(); scheduleNext()
            }
        } else if status == .downloading && isStillTracked {
            let currentRetry = await MainActor.run { item.retryCount }
            let maxRetries = UserDefaults.standard.object(forKey: "maxRetryCount") as? Int ?? 3
            if currentRetry < maxRetries {
                await MainActor.run { item.retryCount += 1; item.status = .queued; item.speed = 0; item._lastTickDate = nil }
                try? await Task.sleep(nanoseconds: 2_000_000_000); await MainActor.run { scheduleNext() }
            } else {
                await MainActor.run { item.status = .failed; item.error = self.aria2HumanError(exitCode: proc.terminationStatus); item.speed = 0; item._lastTickDate = nil; persist(); scheduleNext() }
            }
        }
    }

    func fetchTorrentInfo(item: DownloadItem, executable: String) async -> [SubFile] {
        let tempDir = await MainActor.run { item.tempDirURL.path }
        let targetPath = item.url.isFileURL ? item.url.path : item.url.absoluteString
        
        return await withCheckedContinuation { (cont: CheckedContinuation<[SubFile], Never>) in
            let proc = Process(); proc.executableURL = URL(fileURLWithPath: executable)
            proc.arguments = [
                "--show-files", "--enable-dht=true", "--bt-enable-lpd=true", "--enable-peer-exchange=true", "--dht-listen-port=6881-6999",
                "--bt-tracker=udp://tracker.opentrackr.org:1337/announce,udp://open.stealth.si:80/announce",
                "--dir=\(tempDir)", targetPath
            ]
            let pipe = Pipe(); proc.standardOutput = pipe; proc.standardError = Pipe()
            let readTask = Task {
                var outputData = Data()
                do { if let data = try pipe.fileHandleForReading.readToEnd() { outputData = data } } catch {}
                return String(data: outputData, encoding: .utf8) ?? ""
            }
            proc.terminationHandler = { _ in Task { let output = await readTask.value; let parsed = self.parseShowFiles(output); cont.resume(returning: parsed) } }
            do { try proc.run(); Task { try? await Task.sleep(nanoseconds: 120_000_000_000); if proc.isRunning { proc.terminate() } } } catch { cont.resume(returning: []) }
        }
    }
    
    nonisolated func parseShowFiles(_ output: String) -> [SubFile] {
        var files: [SubFile] = []
        let lines = output.components(separatedBy: .newlines)
        var currentIndex: Int?; var currentPath: String?

        for line in lines {
            if let sepRange = line.range(of: "|") {
                let left = line[..<sepRange.lowerBound].trimmingCharacters(in: .whitespaces)
                let right = line[sepRange.upperBound...].trimmingCharacters(in: .whitespaces)
                if let idx = Int(left) { currentIndex = idx; currentPath = right }
                else if let idx = currentIndex, let path = currentPath, left.isEmpty {
                    if let start = right.firstIndex(of: "("), let end = right.lastIndex(of: ")") {
                        let bytesStr = right[right.index(after: start)...end].dropLast().replacingOccurrences(of: ",", with: "")
                        if let bytes = Int64(bytesStr) {
                            files.append(SubFile(id: UUID(), index: idx, path: path, filename: URL(fileURLWithPath: path).lastPathComponent, totalBytes: bytes, downloadedBytes: 0, isStopped: false))
                        }
                    }
                    currentIndex = nil; currentPath = nil
                }
            }
        }
        return files
    }
}
