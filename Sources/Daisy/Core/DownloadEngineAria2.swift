import Foundation
import AppKit
import UniformTypeIdentifiers

extension DownloadEngine {
    
    func runAria2(_ item: DownloadItem, executable: String) async {
        await MainActor.run { item._managesOwnSpeed = true }
        
        let tempDir = await MainActor.run { item.tempDirURL }
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        var targetPath = await MainActor.run { item.url.isFileURL ? item.url.path : item.url.absoluteString }
        let isMagnet = await MainActor.run { item.url.scheme == "magnet" }

        // macOS Sandbox TCC Workaround & HTML Validation
        let isFileURL = await MainActor.run { item.url.isFileURL }
        if isFileURL {
            let url = await MainActor.run { item.url }
            let safeLocalPath = tempDir.appendingPathComponent(url.lastPathComponent)
            if url.path != safeLocalPath.path {
                let _ = url.startAccessingSecurityScopedResource()
                do {
                    let data = try Data(contentsOf: url)
                    
                    if data.count < 50 {
                        throw NSError(domain: "Daisy", code: 1, userInfo: [NSLocalizedDescriptionKey: "File is completely empty or too small to be a torrent."])
                    }
                    let prefix = String(decoding: data.prefix(100), as: UTF8.self).lowercased()
                    if prefix.contains("<!doctype html>") || prefix.contains("<html") {
                        throw NSError(domain: "Daisy", code: 2, userInfo: [NSLocalizedDescriptionKey: "File is an HTML webpage, not a .torrent file. The tracker site likely blocked the download."])
                    }
                    
                    try data.write(to: safeLocalPath)
                    targetPath = safeLocalPath.path
                } catch {
                    print("SANDBOX COPY FAILED: \(error.localizedDescription)")
                    await MainActor.run { item.error = "Invalid File: \(error.localizedDescription)" }
                }
                url.stopAccessingSecurityScopedResource()
            }
        }

        if isMagnet {
            let tempFiles = (try? FileManager.default.contentsOfDirectory(atPath: tempDir.path)) ?? []
            
            let validTorrent = tempFiles.first { file in
                guard file.hasSuffix(".torrent") else { return false }
                let attr = try? FileManager.default.attributesOfItem(atPath: tempDir.appendingPathComponent(file).path)
                let size = (attr?[.size] as? NSNumber)?.int64Value ?? 0
                return size > 100
            }
            
            if let torrentFile = validTorrent {
                targetPath = tempDir.appendingPathComponent(torrentFile).path
            } else {
                if let localTorrentURL = await resolveMagnetLink(item: item, executable: executable) {
                    targetPath = localTorrentURL.path
                } else {
                    await MainActor.run {
                        item.status = .failed; item.error = "Failed to resolve magnet link metadata. No seeders found or network timeout."; item.speed = 0
                        persist(); scheduleNext()
                    }
                    return
                }
            }
        }

        let needsTorrentFetch = await MainActor.run { item.type == .torrent && item.subFiles.isEmpty }
        if needsTorrentFetch {
            let result = await fetchTorrentInfo(item: item, executable: executable, targetPath: targetPath)
            await MainActor.run {
                if !result.files.isEmpty {
                    item.subFiles = result.files
                    item.totalBytes = result.files.map { $0.totalBytes }.reduce(0, +)
                    // Use the torrent's actual top-level content name (the
                    // shared first path component for multi-file torrents,
                    // or the file name for single-file torrents) as the
                    // destination. aria2 will write directly to
                    // `<parentDir>/<contentName>` which matches the
                    // torrent's metainfo, so we no longer wrap the
                    // download in an extra folder named after the magnet's
                    // `dn=` parameter. For the rare mixed-root torrent
                    // (multiple files at root with no shared folder) we
                    // keep the `dn=` folder as a wrapper so loose files
                    // don't litter the user's Downloads directory.
                    if let contentName = self.torrentContentName(from: result.files) {
                        let parentDir = item.destinationURL.deletingLastPathComponent()
                        item.destinationURL = parentDir.appendingPathComponent(contentName)
                        item.filename = contentName
                    } else {
                        try? FileManager.default.createDirectory(at: item.destinationURL, withIntermediateDirectories: true)
                    }
                }
            }
            let stillEmpty = await MainActor.run { item.subFiles.isEmpty }
            if stillEmpty {
                await MainActor.run {
                    let errSnippet = result.error?.isEmpty == false ? result.error! : "Unknown error occurred."
                    let customError = item.error ?? "Parse failed: \(errSnippet)"
                    item.status = .failed; item.error = customError; item.speed = 0
                    persist(); scheduleNext()
                }
                return
            }
        }

        // 1. Resolve collision policies and commit to the final destination path
        await MainActor.run {
            if !item.isPrepared {
                let policy = UserDefaults.standard.string(forKey: "fileCollisionBehavior") ?? "rename"
                
                if item.type == .torrent {
                    var uiName = item.filename
                    if uiName == "." || uiName.isEmpty || uiName.lowercased().hasPrefix("magnet") {
                        uiName = item.destinationURL.lastPathComponent
                    }
                    item.filename = uiName
                    
                } else if item.type == .batch {
                    if policy == "replace" {
                        try? FileManager.default.removeItem(at: item.destinationURL)
                    } else {
                        item.destinationURL = uniqueURL(item.destinationURL)
                    }
                    try? FileManager.default.createDirectory(at: item.destinationURL, withIntermediateDirectories: true)
                    item.filename = item.destinationURL.lastPathComponent
                } else {
                    if policy == "replace" {
                        try? FileManager.default.removeItem(at: item.destinationURL)
                        try? FileManager.default.removeItem(at: item.destinationURL.appendingPathExtension("dysy"))
                    } else {
                        item.destinationURL = uniqueURL(item.destinationURL)
                        item.filename = item.destinationURL.lastPathComponent
                    }
                }
                
                item.isPrepared = true; persist()
            }
        }

        let type         = await MainActor.run { item.type }
        let fileName     = await MainActor.run { item.filename }

        // For single-content torrents `item.destinationURL` already points
        // at the torrent's own content folder/file, so aria2 needs the
        // *parent* directory and will recreate that exact name. For the
        // rare mixed-root torrent we kept the `dn=` wrapper folder as the
        // destination, so aria2 writes directly into it.
        let destDir = await MainActor.run { () -> String in
            if type == .torrent {
                let usesParent = !item.subFiles.isEmpty && self.torrentContentName(from: item.subFiles) != nil
                return usesParent
                    ? item.destinationURL.deletingLastPathComponent().path
                    : item.destinationURL.path
            }
            return item.tempDirURL.path
        }

        // 2. Hide the messy .aria2 AND the 100% sparse file in Application Support (Skipped for torrents)
        await MainActor.run {
            if item.type != .torrent {
                let bundleURL = item.destinationURL.appendingPathExtension("dysy")
                try? FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
                
                if let folderIcon = NSImage(named: "FolderIcon") ?? NSImage(named: NSImage.applicationIconName) {
                    NSWorkspace.shared.setIcon(folderIcon, forFile: bundleURL.path, options: [])
                }
            }
        }
        
        let conns        = await MainActor.run { item.connectionCount }
        let url          = await MainActor.run { item.url }
        let speedLimit   = await MainActor.run { item.speedLimit }
        let cookies      = await MainActor.run { item.cookies }
        let userAgent    = await MainActor.run { item.userAgent }
        let referer      = await MainActor.run { item.referer }
        let extraHeaders = await MainActor.run { item.headers }

        let proc = Process(); proc.executableURL = URL(fileURLWithPath: executable)
        var didLaunch = false

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
                if lowerKey == "cookie" { continue }
                args.append("--header=\(key): \(value)")
                appliedKeys.insert(lowerKey)
            }
        }

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

        if !appliedKeys.contains("referer"), let ref = referer, !ref.isEmpty {
            args.append("--referer=\(ref)")
        }
        
        if !appliedKeys.contains("user-agent") {
            let ua = (userAgent != nil && !userAgent!.isEmpty) ? userAgent! : "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
            args.append("--user-agent=\(ua)")
        }

        // googlevideo.com fingerprints requests aggressively. A Safari UA
        // paired with Chrome-style Sec-Ch-Ua-* headers is a dead
        // giveaway for a non-browser client and produces 403s. Send the
        // bare minimum a real <video> element fetch would emit and skip
        // the navigation/Chrome-specific headers entirely.
        let isGoogleVideo = (url.host?.contains("googlevideo.com") == true)

        if !appliedKeys.contains("accept") { args.append("--header=Accept: */*") }
        if !appliedKeys.contains("accept-language") { args.append("--header=Accept-Language: en-US,en;q=0.9") }
        if !isGoogleVideo, !appliedKeys.contains("sec-ch-ua") {
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
        } else if !isGoogleVideo {
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
            let isSubFilesEmpty = await MainActor.run { item.subFiles.isEmpty }
            
            if !activeIndices.isEmpty {
                args.append("--select-file=\(activeIndices)")
            } else if !isSubFilesEmpty {
                let allFinished = await MainActor.run { item.subFiles.allSatisfy { $0.totalBytes > 0 && $0.downloadedBytes >= $0.totalBytes } }
                if allFinished {
                    await MainActor.run { item.status = .completed; item.dateCompleted = Date(); self.notifyCompletion(for: item); persist(); scheduleNext() }
                } else {
                    await MainActor.run { stop(item, stopSubFiles: false) }
                }
                return
            }
            args.append(targetPath)
        } else {
            args.append(targetPath)
        }

        proc.arguments = args
        if url.host?.contains("googlevideo.com") == true {
            print("[Daisy] aria2 args for googlevideo: \(args.joined(separator: " "))")
        }
        let stdoutPipe = Pipe(); proc.standardOutput = stdoutPipe
        let stderrPipe: Pipe? = (url.host?.contains("googlevideo.com") == true) ? Pipe() : nil
        if let p = stderrPipe { proc.standardError = p } else { proc.standardError = FileHandle.nullDevice }
        if let p = stderrPipe {
            Task.detached {
                for try await line in p.fileHandleForReading.bytes.lines {
                    print("[Daisy] aria2 gv-err> \(line)")
                }
            }
        }
        
        let dummySizeTask = Task { [weak item] in
            guard let item = item else { return }
            let itemType = await MainActor.run { item.type }
            
            if itemType == .torrent { return } // No dummy bundle wrapper needed for torrents
            
            let bundleURL = await MainActor.run { item.destinationURL.appendingPathExtension("dysy") }
            let dummyFileURL = await MainActor.run { bundleURL.appendingPathComponent(item.filename) }
            
            while !Task.isCancelled {
                if !FileManager.default.fileExists(atPath: dummyFileURL.path) {
                    try? FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
                    FileManager.default.createFile(atPath: dummyFileURL.path, contents: nil)
                }
                
                if let fh = try? FileHandle(forWritingTo: dummyFileURL) {
                    let currentSize = await MainActor.run { item.downloadedBytes }
                    let actualSize = (try? fh.seekToEnd()) ?? 0
                    if currentSize > 0 && currentSize != actualSize {
                        try? fh.truncate(atOffset: UInt64(currentSize))
                        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: bundleURL.path)
                    }
                    try? fh.close()
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        
        // Hide the `.aria2` resume sidecar so Finder doesn't show it next
        // to the actual download. For torrents we know the exact sidecar
        // path (`<destinationURL>.aria2`, sibling of the content folder);
        // for everything else aria2 writes inside `tempDir` which the user
        // never sees, but we still hide any sidecar in the directory for
        // safety.
        let hideAriaTask = Task { [weak item, destDir] in
            guard let item = item else { return }
            let target = await MainActor.run { item.destinationURL }
            let isTorrent = await MainActor.run { item.type == .torrent }
            let specificSidecar = isTorrent ? target.appendingPathExtension("aria2") : nil

            while !Task.isCancelled {
                if let sidecar = specificSidecar,
                   FileManager.default.fileExists(atPath: sidecar.path) {
                    var fileURL = sidecar
                    var rv = URLResourceValues()
                    rv.isHidden = true
                    try? fileURL.setResourceValues(rv)
                } else if let files = try? FileManager.default.contentsOfDirectory(atPath: destDir) {
                    for file in files where file.hasSuffix(".aria2") {
                        var fileURL = URL(fileURLWithPath: destDir).appendingPathComponent(file)
                        var rv = URLResourceValues()
                        rv.isHidden = true
                        try? fileURL.setResourceValues(rv)
                    }
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        
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
            
            let logGoogleVideo = url.host?.contains("googlevideo.com") == true
            for try await line in stdoutPipe.fileHandleForReading.bytes.lines {
                if logGoogleVideo {
                    print("[Daisy] aria2 gv> \(line)")
                }
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
                                                self.items = self.items
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
                                        let previousTotal = updated.reduce(0) { $0 + $1.downloadedBytes }
                                        let delta = downloaded - previousTotal
                                        
                                        if delta > 0 {
                                            var remainingDelta = delta
                                            for i in 0..<updated.count {
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
                                        self.items = self.items
                                    }
                                } else {
                                    if downloaded > 0 { item.downloadedBytes = downloaded }
                                    if total > 0 && item.totalBytes == 0 { item.totalBytes = total }
                                }
                            }
                        }
                    }

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
                                        self.items = self.items
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
        dummySizeTask.cancel()
        hideAriaTask.cancel()

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

        // 4. Extract the final file from Application Support to the user's destination, and delete the .dysy proxy
        if proc.terminationStatus == 0 {
            let destinationURL = await MainActor.run { item.destinationURL }
            let bundleURL = destinationURL.appendingPathExtension("dysy")
            
            if type == .torrent {
                try? FileManager.default.removeItem(at: tempDir)
            } else if type == .directLink {
                let downloadedFile = tempDir.appendingPathComponent(fileName)
                
                _ = try? FileManager.default.removeItem(at: destinationURL)
                try? FileManager.default.moveItem(at: downloadedFile, to: destinationURL)
                try? FileManager.default.removeItem(at: bundleURL)
                
                if let attr = try? FileManager.default.attributesOfItem(atPath: destinationURL.path), let fileSize = attr[.size] as? NSNumber {
                    await MainActor.run { item.downloadedBytes = fileSize.int64Value; if item.totalBytes == 0 || item.totalBytes < fileSize.int64Value { item.totalBytes = fileSize.int64Value } }
                }
            } else {
                let destDirURL = type == .batch ? destinationURL : destinationURL.deletingLastPathComponent()
                let subFiles = await MainActor.run { item.subFiles }
                for file in subFiles {
                    if file.isStopped { continue }
                    let src = tempDir.appendingPathComponent(file.path); let dst = destDirURL.appendingPathComponent(file.path)
                    try? FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                    _ = try? FileManager.default.removeItem(at: dst); try? FileManager.default.moveItem(at: src, to: dst)
                }
                try? FileManager.default.removeItem(at: bundleURL)
                try? FileManager.default.removeItem(at: tempDir)
            }
            
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

    func resolveMagnetLink(item: DownloadItem, executable: String) async -> URL? {
        let tempDir = await MainActor.run { item.tempDirURL }
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let targetPath = await MainActor.run { item.url.absoluteString }
        
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = [
            "--bt-metadata-only=true", "--bt-save-metadata=true", "--console-log-level=notice",
            "--enable-dht=true", "--bt-enable-lpd=true", "--enable-peer-exchange=true",
            "--dht-listen-port=6881-6999",
            "--bt-tracker=udp://tracker.opentrackr.org:1337/announce,udp://open.stealth.si:80/announce",
            "--dir=\(tempDir.path)", targetPath
        ]
        
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        
        do {
            try proc.run()
        } catch {
            return nil
        }
        
        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            if proc.isRunning { proc.terminate() }
        }
        
        var resolvedURL: URL? = nil
        do {
            for try await line in pipe.fileHandleForReading.bytes.lines {
                if let range = line.range(of: "Saved metadata as ") {
                    let path = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                    resolvedURL = URL(fileURLWithPath: path)
                }
            }
        } catch {}
        
        await Task.detached { proc.waitUntilExit() }.value
        timeoutTask.cancel()
        
        if let resolved = resolvedURL {
            let size = (try? FileManager.default.attributesOfItem(atPath: resolved.path)[.size] as? NSNumber)?.int64Value ?? 0
            if size > 100 { return resolved }
        }
        
        if let files = try? FileManager.default.contentsOfDirectory(atPath: tempDir.path),
           let torrentFile = files.first(where: { $0.hasSuffix(".torrent") }) {
            let fallbackPath = tempDir.appendingPathComponent(torrentFile)
            let size = (try? FileManager.default.attributesOfItem(atPath: fallbackPath.path)[.size] as? NSNumber)?.int64Value ?? 0
            if size > 100 { return fallbackPath }
        }
        
        return nil
    }

    func fetchTorrentInfo(item: DownloadItem, executable: String, targetPath: String) async -> (files: [SubFile], error: String?) {
        let tempDir = await MainActor.run { item.tempDirURL.path }
        
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = [
            "--show-files", "--enable-dht=true", "--bt-enable-lpd=true", "--enable-peer-exchange=true", "--dht-listen-port=6881-6999",
            "--bt-tracker=udp://tracker.opentrackr.org:1337/announce,udp://open.stealth.si:80/announce",
            "--dir=\(tempDir)", targetPath
        ]
        
        let pipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = errPipe
        
        do {
            try proc.run()
        } catch {
            return ([], "Failed to launch process: \(error.localizedDescription)")
        }
        
        async let outputTask = Task.detached(priority: .userInitiated) {
            let data = try? pipe.fileHandleForReading.readToEnd()
            return String(decoding: data ?? Data(), as: UTF8.self)
        }.value
        
        async let errorTask = Task.detached(priority: .userInitiated) {
            let data = try? errPipe.fileHandleForReading.readToEnd()
            return String(decoding: data ?? Data(), as: UTF8.self)
        }.value
        
        let (output, stderr) = await (outputTask, errorTask)
        proc.waitUntilExit()
        
        let files = self.parseShowFiles(output)
        
        if files.isEmpty {
            var combinedError = ""
            if !output.isEmpty { combinedError += "STDOUT: \(output.prefix(300)) " }
            if !stderr.isEmpty { combinedError += "STDERR: \(stderr.prefix(300))" }
            return ([], combinedError.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        
        return (files, stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    
    /// Returns the torrent's top-level content name. For multi-file torrents
    /// this is the shared first path component (e.g.
    /// `Resident Evil Requiem [FitGirl Repack]`). For single-file torrents
    /// it's just the filename. Returns `nil` when the files don't share a
    /// common root, in which case the caller should fall back to whatever
    /// name was chosen earlier (typically the magnet `dn=` value).
    nonisolated func torrentContentName(from files: [SubFile]) -> String? {
        let firstSegments = files.compactMap { sub -> String? in
            let path = sub.path.trimmingCharacters(in: .init(charactersIn: "/"))
            guard !path.isEmpty else { return nil }
            return path.split(separator: "/", maxSplits: 1).first.map(String.init)
        }
        guard let first = firstSegments.first, !first.isEmpty else { return nil }
        // Single file at root: use the filename verbatim
        if files.count == 1 && !files[0].path.contains("/") { return files[0].path }
        // Multi-file with a shared content folder: use that folder name
        if firstSegments.allSatisfy({ $0 == first }) { return first }
        return nil
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
                        let bytesStr = right[right.index(after: start)..<end].replacingOccurrences(of: ",", with: "")
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
