import Foundation
import AppKit

extension DownloadEngine {
    
    nonisolated func parseYtDlpLine(_ line: String, for item: DownloadItem) {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        var percentStr = "", sizeStr = "", speedStr = ""
        
        for (i, part) in parts.enumerated() {
            if part.hasSuffix("%") { percentStr = String(part.dropLast()) }
            if part == "of" && i + 1 < parts.count {
                let next = parts[i+1]
                if next == "~" && i + 2 < parts.count { sizeStr = String(parts[i+2]) }
                else { sizeStr = String(next) }
            }
            if part == "at" && i + 1 < parts.count { speedStr = String(parts[i+1]) }
        }
        
        Task { @MainActor in
            if !sizeStr.isEmpty {
                let total = self.parseAriaSize(sizeStr)
                if total > 0 { item.totalBytes = total }
            }
            if !percentStr.isEmpty, let pct = Double(percentStr) {
                if item.totalBytes > 0 { item.downloadedBytes = Int64(Double(item.totalBytes) * (pct / 100.0)) }
            }
            if !speedStr.isEmpty {
                let s = speedStr.replacingOccurrences(of: "/s", with: "")
                let speed = self.parseAriaSize(s)
                if speed > 0 { item.speed = Double(speed) }
            }
            item._lastTickDate = Date()
        }
    }

    func runYoutubeDownload(_ item: DownloadItem) async {
        await MainActor.run {
            item._managesOwnSpeed = true
            if !item.isPrepared {
                let policy = UserDefaults.standard.string(forKey: "fileCollisionBehavior") ?? "rename"
                var dest = item.destinationURL
                if dest.pathExtension.lowercased() != "mp4" { dest = dest.deletingPathExtension().appendingPathExtension("mp4") }
                if policy == "replace" {
                    try? FileManager.default.removeItem(at: dest)
                    try? FileManager.default.removeItem(at: dest.appendingPathExtension("dysy"))
                }
                else { dest = uniqueURL(dest) }
                item.destinationURL = dest; item.filename = dest.lastPathComponent; item.isPrepared = true; persist()
            }

            // Setup the macOS .dysy bundle proxy for the UI
            let bundleURL = item.destinationURL.appendingPathExtension("dysy")
            try? FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
            if let folderIcon = NSImage(named: "FolderIcon") ?? NSImage(named: NSImage.applicationIconName) {
                NSWorkspace.shared.setIcon(folderIcon, forFile: bundleURL.path, options: [])
            }
        }

        let url = await MainActor.run { item.url }
        let formatQuery = await MainActor.run { item.youtubeQuality }
        let itemCookies = await MainActor.run { item.cookies }
        let itemUserAgent = await MainActor.run { item.userAgent }
        let itemPoToken = await MainActor.run { item.ytPoToken }
        let itemPoTokenVisitor = await MainActor.run { item.ytPoTokenVisitor }

        do {
            let credentials = YouTubeExtractor.Credentials(
                cookies: itemCookies,
                userAgent: itemUserAgent,
                poToken: itemPoToken,
                poTokenVisitor: itemPoTokenVisitor
            )
            let info = try await YouTubeExtractor.shared.extract(url: url, credentials: credentials)
            let selection = YouTubeFormatSelection.parse(formatQuery)
            let resolved = try selection.resolve(in: info)
            let isDownloading = await MainActor.run { item.status == .downloading }
            guard isDownloading else { return }

            // Adopt the canonical title for the saved filename, if the user
            // hasn't customised it. Done before kicking off any download so
            // the .dysy bundle and final mp4 land at the right path.
            await self.adoptYouTubeTitleIfDefault(item: item, info: info)

            if let audio = resolved.audio, let videoURL = resolved.video.url {
                guard let audioURL = audio.url else {
                    await MainActor.run {
                        item.status = .failed
                        item.error = "Resolved audio stream had no usable URL."
                        self.persist(); self.scheduleNext()
                    }
                    return
                }
                if let total = self.estimatedTotalBytes(video: resolved.video, audio: audio) {
                    await MainActor.run { item.totalBytes = total }
                }
                await self.handleMultiPartYoutube(item, videoURL: videoURL, audioURL: audioURL)
            } else if let progressiveURL = resolved.video.url {
                if let total = resolved.video.contentLength {
                    await MainActor.run { item.totalBytes = total }
                }
                await MainActor.run {
                    guard let u = URL(string: progressiveURL) else {
                        item.status = .failed
                        item.error = "Resolved progressive URL was not parseable."
                        self.persist(); self.scheduleNext()
                        return
                    }
                    item.url = u
                    self.continueStartDownload(item)
                }
            } else {
                await MainActor.run {
                    item.status = .failed
                    item.error = "YouTube returned no usable stream URL for the selected quality."
                    self.persist(); self.scheduleNext()
                }
            }
        } catch {
            let isDownloading = await MainActor.run { item.status == .downloading }
            if isDownloading {
                await MainActor.run {
                    item.status = .failed
                    item.error = "YouTube extract error: \(error.localizedDescription)"
                    self.persist(); self.scheduleNext()
                }
            }
        }
    }

    /// Sum of contentLength on the chosen video + audio streams (when both
    /// are reported). Lets the UI show a total before either aria2 worker
    /// has emitted its first progress line.
    nonisolated func estimatedTotalBytes(video: YouTubeFormat, audio: YouTubeFormat) -> Int64? {
        guard let v = video.contentLength, let a = audio.contentLength else { return nil }
        let sum = v + a
        return sum > 0 ? sum : nil
    }

    /// If the queued item is still using a placeholder filename (the user
    /// never customised it), replace it with the canonical title returned
    /// by the InnerTube API, sanitised for the filesystem.
    @MainActor
    func adoptYouTubeTitleIfDefault(item: DownloadItem, info: YouTubeVideoInfo) {
        let current = item.filename
        let placeholderHints = [
            "youtube_video.mp4",
            "video.mp4",
            "download",
            "download.mp4"
        ]
        let isPlaceholder = current.isEmpty
            || placeholderHints.contains(current.lowercased())
            || current.hasPrefix("watch?v=")
            || (item.url.absoluteString.contains("/watch") && current.lowercased().hasPrefix("watch"))
        guard isPlaceholder else { return }

        var sanitised = info.title
            .replacingOccurrences(of: #"[/\\:*?\"<>|]"#, with: "_", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if sanitised.isEmpty { sanitised = "YouTube Video" }
        if !sanitised.lowercased().hasSuffix(".mp4") { sanitised += ".mp4" }

        var dest = item.destinationURL
        dest = dest.deletingLastPathComponent().appendingPathComponent(sanitised)
        if FileManager.default.fileExists(atPath: dest.path) { dest = uniqueURL(dest) }

        item.filename = dest.lastPathComponent
        item.destinationURL = dest
        persist()
    }

    func handleMultiPartYoutube(_ item: DownloadItem, videoURL: String, audioURL: String) async {
        let tempDir = item.tempDirURL
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let vFile = tempDir.appendingPathComponent("video.tmp").path; let aFile = tempDir.appendingPathComponent("audio.tmp").path
        guard let aria = aria2Path else { await MainActor.run { item.status = .failed; item.error = "aria2c missing" }; return }
        await MainActor.run { item.status = .downloading; persist() }

        let dummySizeTask = Task { [weak item] in
            guard let item = item else { return }
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

        await Task.detached(priority: .userInitiated) {
            let commonArgs = ["-x16", "-s16", "-k1M", "--summary-interval=1", "--console-log-level=notice", "--file-allocation=none", "--continue=true", "--auto-file-renaming=false"]
            let vProc = Process(); vProc.executableURL = URL(fileURLWithPath: aria); vProc.arguments = commonArgs + ["-o", "video.tmp", "--dir=\(tempDir.path)", videoURL]
            let vPipe = Pipe(); vProc.standardOutput = vPipe
            
            let aProc = Process(); aProc.executableURL = URL(fileURLWithPath: aria); aProc.arguments = commonArgs + ["-o", "audio.tmp", "--dir=\(tempDir.path)", audioURL]
            let aPipe = Pipe(); aProc.standardOutput = aPipe
            
            await MainActor.run { item.processes.append(vProc); item.processes.append(aProc) }
            
            let vAttr = try? FileManager.default.attributesOfItem(atPath: vFile)
            let initialVBytes: Int64 = (vAttr?[.size] as? NSNumber)?.int64Value ?? 0
            
            let aAttr = try? FileManager.default.attributesOfItem(atPath: aFile)
            let initialABytes: Int64 = (aAttr?[.size] as? NSNumber)?.int64Value ?? 0

            await MainActor.run { if initialVBytes + initialABytes > 0 { item.downloadedBytes = initialVBytes + initialABytes } }

            let tracker = YoutubeProgressTracker(vBytes: initialVBytes, aBytes: initialABytes)

            func sniff(_ line: String) -> (cur: Int64, tot: Int64, spd: Double)? {
                let sizePattern = #"(?<cur>[\d\.]+[A-Z]iB)/(?<tot>[\d\.]+[A-Z]iB)"#
                let speedPattern = #"DL:(?<spd>[\d\.]+[A-Z]iB)"#
                var c: Int64 = 0, t: Int64 = 0, s: Double = 0
                
                if let range = line.range(of: sizePattern, options: .regularExpression) {
                    let parts = line[range].split(separator: "/")
                    if parts.count == 2 { c = self.parseAriaSize(String(parts[0])); t = self.parseAriaSize(String(parts[1])) }
                }
                if let range = line.range(of: speedPattern, options: .regularExpression) {
                    let spdStr = line[range].replacingOccurrences(of: "DL:", with: "")
                    s = Double(self.parseAriaSize(spdStr))
                }
                return (c > 0 || s > 0) ? (c, t, s) : nil
            }

            let vTask = Task {
                for try await line in vPipe.fileHandleForReading.bytes.lines {
                    if let res = sniff(line) {
                        let state = await tracker.updateVideo(bytes: res.cur, total: res.tot, speed: res.spd)
                        await MainActor.run {
                            item.downloadedBytes = state.downloaded
                            item.speed = state.speed
                            if state.total > 0 { item.totalBytes = state.total }
                            item._lastTickDate = Date()
                        }
                    }
                }
            }

            let aTask = Task {
                for try await line in aPipe.fileHandleForReading.bytes.lines {
                    if let res = sniff(line) {
                        let state = await tracker.updateAudio(bytes: res.cur, total: res.tot, speed: res.spd)
                        await MainActor.run {
                            item.downloadedBytes = state.downloaded
                            item.speed = state.speed
                            if state.total > 0 { item.totalBytes = state.total }
                            item._lastTickDate = Date()
                        }
                    }
                }
            }

            do {
                try vProc.run(); try aProc.run()
                vProc.waitUntilExit(); aProc.waitUntilExit()
                vTask.cancel(); aTask.cancel()
                
                dummySizeTask.cancel()
                
                let isDownloading = await MainActor.run { item.status == .downloading }
                let finalVSz = (try? FileManager.default.attributesOfItem(atPath: vFile)[.size] as? NSNumber)?.int64Value ?? 0
                let finalASz = (try? FileManager.default.attributesOfItem(atPath: aFile)[.size] as? NSNumber)?.int64Value ?? 0
                
                if isDownloading && vProc.terminationStatus == 0 && aProc.terminationStatus == 0 && finalVSz > 0 && finalASz > 0 {
                    await self.mergeYoutubeParts(item, videoPath: vFile, audioPath: aFile)
                } else if isDownloading {
                    await MainActor.run { item.status = .failed; item.error = "Aria2 download failed or returned incomplete files." }
                }
            } catch {
                dummySizeTask.cancel()
                let isDownloading = await MainActor.run { item.status == .downloading }
                if isDownloading { await MainActor.run { item.status = .failed; item.error = error.localizedDescription } }
            }
        }.value
    }

    func mergeYoutubeParts(_ item: DownloadItem, videoPath: String, audioPath: String) async {
        guard let ffmpeg = ffmpegPath else { await MainActor.run { item.status = .failed; item.error = "FFmpeg missing" }; return }
        
        // Merge into temp dir to avoid leaving incomplete files directly in user downloads
        let tempMergePath = await MainActor.run { item.tempDirURL.appendingPathComponent(item.filename).path }
        
        await Task.detached(priority: .userInitiated) {
            let proc = Process(); proc.executableURL = URL(fileURLWithPath: ffmpeg)
            proc.arguments = ["-i", videoPath, "-i", audioPath, "-c", "copy", "-map", "0:v:0", "-map", "1:a:0", "-y", tempMergePath]
            await MainActor.run { item.processes.append(proc) }
            
            do {
                try proc.run(); proc.waitUntilExit()
                await MainActor.run {
                    let isDownloading = item.status == .downloading
                    if proc.terminationStatus == 0 {
                        let finalDest = item.destinationURL
                        let bundleURL = finalDest.appendingPathExtension("dysy")
                        
                        _ = try? FileManager.default.removeItem(at: finalDest)
                        try? FileManager.default.moveItem(atPath: tempMergePath, toPath: finalDest.path)
                        try? FileManager.default.removeItem(at: bundleURL)

                        item.status = .completed; item.dateCompleted = Date(); item.speed = 0
                        try? FileManager.default.removeItem(at: item.tempDirURL)
                    } else if isDownloading { item.status = .failed; item.error = "FFmpeg merge failed" }
                    self.persist(); self.scheduleNext()
                }
            } catch {
                await MainActor.run { if item.status == .downloading { item.status = .failed; item.error = error.localizedDescription } }
            }
        }.value
    }
}

private actor YoutubeProgressTracker {
    var vBytes: Int64
    var aBytes: Int64
    var vTotal: Int64 = 0
    var aTotal: Int64 = 0
    var vSpeed: Double = 0
    var aSpeed: Double = 0

    init(vBytes: Int64, aBytes: Int64) {
        self.vBytes = vBytes
        self.aBytes = aBytes
    }

    func updateVideo(bytes: Int64, total: Int64, speed: Double) -> (downloaded: Int64, total: Int64, speed: Double) {
        self.vBytes = bytes
        self.vTotal = total
        self.vSpeed = speed
        return (self.vBytes + self.aBytes, self.vTotal + self.aTotal, self.vSpeed + self.aSpeed)
    }

    func updateAudio(bytes: Int64, total: Int64, speed: Double) -> (downloaded: Int64, total: Int64, speed: Double) {
        self.aBytes = bytes
        self.aTotal = total
        self.aSpeed = speed
        return (self.vBytes + self.aBytes, self.vTotal + self.aTotal, self.vSpeed + self.aSpeed)
    }
}
