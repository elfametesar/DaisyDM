import Foundation

extension DownloadEngine {
    
    nonisolated func dashLog(_ msg: String) {
        print("[DASH-DEBUG] \(msg)")
    }
    
    struct DASHTrack {
        enum Kind { case video, audio }
        let kind: Kind
        let initURL: String
        let mediaTemplate: String
        let segmentCount: Int
        let totalDurationSec: Double
        let bandwidth: Int
        let codecs: String
        let startNumber: Int
    }

    func dashResolveURL(base: String, href: String) -> String {
        if href.hasPrefix("http://") || href.hasPrefix("https://") { return href }
        let basePath = base.components(separatedBy: "?")[0]
        if href.hasPrefix("/") {
            if let schemeEnd = basePath.range(of: "://") {
                let afterScheme = basePath[schemeEnd.upperBound...]
                if let pathStart = afterScheme.firstIndex(of: "/") {
                    let hostOnly = basePath[..<basePath.index(schemeEnd.upperBound, offsetBy: basePath.distance(from: schemeEnd.upperBound, to: pathStart))]
                    return String(hostOnly) + href
                }
            }
            return href
        } else {
            if basePath.hasSuffix("/") { return basePath + href }
            else if let lastSlash = basePath.lastIndex(of: "/") {
                let dirPath = String(basePath[...lastSlash]); return dirPath + href
            }
            return href
        }
    }

    func dashParseSegmentTimeline(xml: String, searchFrom: String.Index, searchTo: String.Index) -> (count: Int, durationSec: Double) {
        let sub = String(xml[searchFrom..<searchTo])
        var timescale: Double = 1
        if let tsRange = sub.range(of: "timescale=\"") {
            let after = sub[tsRange.upperBound...]
            if let end = after.firstIndex(of: "\""), let v = Double(String(after[..<end])) { timescale = v }
        }
        
        var count = 0
        var totalTicks: Double = 0
        var d: Double = 0
        
        if let regex = try? NSRegularExpression(pattern: "<S\\s+([^>]+)>", options: []) {
            let nsString = sub as NSString
            let matches = regex.matches(in: sub, options: [], range: NSRange(location: 0, length: nsString.length))
            
            for match in matches {
                let attrs = nsString.substring(with: match.range(at: 1))
                var r: Int = 0
                
                if let dRegex = try? NSRegularExpression(pattern: "d=\"([\\d\\.]+)\""),
                   let dMatch = dRegex.firstMatch(in: attrs, options: [], range: NSRange(location: 0, length: attrs.utf16.count)) {
                    let dStr = (attrs as NSString).substring(with: dMatch.range(at: 1))
                    d = Double(dStr) ?? d
                }
                
                if let rRegex = try? NSRegularExpression(pattern: "r=\"([\\-\\d]+)\""),
                   let rMatch = rRegex.firstMatch(in: attrs, options: [], range: NSRange(location: 0, length: attrs.utf16.count)) {
                    let rStr = (attrs as NSString).substring(with: rMatch.range(at: 1))
                    r = Int(rStr) ?? 0
                }
                
                let repeatCount = r >= 0 ? (r + 1) : 1
                count += repeatCount
                totalTicks += d * Double(repeatCount)
            }
        }
        let durationSec = timescale > 0 ? totalTicks / timescale : 0
        return (count, durationSec)
    }

    func dashParseISODuration(_ s: String) -> Double {
        var total = 0.0; var num = ""
        for c in s {
            if c.isNumber || c == "." { num.append(c) }
            else {
                if let v = Double(num) {
                    switch c { case "H": total += v * 3600; case "M": total += v * 60; case "S": total += v; default: break }
                }
                num = ""
            }
        }
        return total
    }

    nonisolated func buildAria2InputFile(segments: [(url: String, out: String)], headers: [String]) -> String {
        var lines: [String] = []
        for seg in segments {
            lines.append(seg.url); lines.append("  out=\(seg.out)")
            for h in headers { lines.append("  header=\(h)") }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    func dashParseMPD(xml: String, mpdURL: String) -> (video: DASHTrack?, audio: DASHTrack?) {
        dashLog("Starting MPD XML Parse...")
        let baseURL: String = mpdURL
        var totalDur: Double = 0
        
        if let durRange = xml.range(of: "mediaPresentationDuration=\"PT"), let endIdx = xml[durRange.upperBound...].firstIndex(of: "\"") {
            let durStr = String(xml[durRange.upperBound..<endIdx])
            totalDur = dashParseISODuration(durStr)
            dashLog("Extracted mediaPresentationDuration: \(totalDur) seconds")
        }

        var videoTracks: [DASHTrack] = []; var audioTracks: [DASHTrack] = []
        var searchIdx = xml.startIndex

        while let asOpen = xml.range(of: "<AdaptationSet", range: searchIdx..<xml.endIndex) {
            guard let asClose = xml.range(of: "</AdaptationSet>", range: asOpen.upperBound..<xml.endIndex) else { break }
            let asBlock = String(xml[asOpen.lowerBound..<asClose.upperBound])
            var mimeType = ""
            if let m = asBlock.range(of: "mimeType=\"") {
                let after = asBlock[m.upperBound...]; if let end = after.firstIndex(of: "\"") { mimeType = String(after[..<end]) }
            }

            let isVideo = mimeType.contains("video"); let isAudio = mimeType.contains("audio")
            guard isVideo || isAudio else { searchIdx = asClose.upperBound; continue }
            guard let stOpen = asBlock.range(of: "<SegmentTemplate"), let stClose = asBlock.range(of: ">", range: stOpen.upperBound..<asBlock.endIndex) else {
                searchIdx = asClose.upperBound; continue
            }
            
            let stTag = String(asBlock[stOpen.lowerBound..<stClose.upperBound])
            var initAttr = ""; var mediaAttr = ""
            if let r = stTag.range(of: "initialization=\"") {
                let after = stTag[r.upperBound...]; if let end = after.firstIndex(of: "\"") { initAttr = String(after[..<end]) }
            }
            if let r = stTag.range(of: "media=\"") {
                let after = stTag[r.upperBound...]; if let end = after.firstIndex(of: "\"") { mediaAttr = String(after[..<end]) }
            }
            
            var startNum = 1
            if let snRange = stTag.range(of: "startNumber=\"") {
                let after = stTag[snRange.upperBound...]
                if let end = after.firstIndex(of: "\""), let v = Int(String(after[..<end])) { startNum = v }
            }

            initAttr = initAttr.replacingOccurrences(of: "&amp;", with: "&")
            mediaAttr = mediaAttr.replacingOccurrences(of: "&amp;", with: "&")

            let resolvedInit = dashResolveURL(base: baseURL, href: initAttr)
            let resolvedMedia = dashResolveURL(base: baseURL, href: mediaAttr)
            let (segCount, segDur) = dashParseSegmentTimeline(xml: asBlock, searchFrom: stOpen.lowerBound, searchTo: asBlock.endIndex)

            let effectiveDur = totalDur > 0 ? totalDur : segDur
            
            var finalCount = segCount
            if finalCount == 0 {
                var durAttr: Double = 0
                if let dRange = asBlock.range(of: "duration=\"") {
                    let after = asBlock[dRange.upperBound...]; if let end = after.firstIndex(of: "\""), let v = Double(String(after[..<end])) { durAttr = v }
                }
                var timescale: Double = 1
                if let tsRange = asBlock.range(of: "timescale=\"") {
                    let after = asBlock[tsRange.upperBound...]; if let end = after.firstIndex(of: "\""), let v = Double(String(after[..<end])) { timescale = v }
                }
                if durAttr > 0 && effectiveDur > 0 { finalCount = Int(ceil(effectiveDur / (durAttr / timescale))) }
                else if effectiveDur > 0 { finalCount = Int(ceil(effectiveDur / 5.0)) }
            }

            var bestBW = 0; var bestCodec = ""; var repSearch = asBlock.startIndex
            while let repOpen = asBlock.range(of: "<Representation", range: repSearch..<asBlock.endIndex),
                  let repClose = asBlock.range(of: ">", range: repOpen.upperBound..<asBlock.endIndex) {
                let repTag = String(asBlock[repOpen.lowerBound..<repClose.upperBound]); var bw = 0; var codec = ""
                if let r = repTag.range(of: "bandwidth=\"") {
                    let after = repTag[r.upperBound...]; if let end = after.firstIndex(of: "\""), let v = Int(String(after[..<end])) { bw = v }
                }
                if let r = repTag.range(of: "codecs=\"") {
                    let after = repTag[r.upperBound...]; if let end = after.firstIndex(of: "\"") { codec = String(after[..<end]) }
                }
                if bw > bestBW { bestBW = bw; bestCodec = codec }
                repSearch = repClose.upperBound
            }

            let track = DASHTrack(kind: isVideo ? .video : .audio, initURL: resolvedInit, mediaTemplate: resolvedMedia, segmentCount: finalCount, totalDurationSec: effectiveDur, bandwidth: bestBW, codecs: bestCodec, startNumber: startNum)
            if isVideo { videoTracks.append(track) } else { audioTracks.append(track) }
            searchIdx = asClose.upperBound
        }

        dashLog("MPD Parse Complete. Found \(videoTracks.count) video tracks and \(audioTracks.count) audio tracks.")
        return (videoTracks.max(by: { $0.bandwidth < $1.bandwidth }), audioTracks.first)
    }

    func runNativeDASHEngine(_ item: DownloadItem) async {
            dashLog("========== STARTING DASH DOWNLOAD ==========")
            guard let aria2Exe = aria2Path else {
                dashLog("ERROR: aria2c not found")
                await MainActor.run { item.status = .failed; item.error = "Missing engine: aria2c not found. Install via Homebrew."; persist(); scheduleNext() }
                return
            }
            guard let ffmpegExe = ffmpegPath else {
                dashLog("ERROR: ffmpeg not found")
                await MainActor.run { item.status = .failed; item.error = "Missing engine: ffmpeg not found. Install via Homebrew."; persist(); scheduleNext() }
                return
            }

            await MainActor.run {
                item._managesOwnSpeed = true
                if !item.isPrepared {
                    let policy = UserDefaults.standard.string(forKey: "fileCollisionBehavior") ?? "rename"
                    var dest = item.destinationURL
                    if dest.pathExtension.lowercased() != "mp4" { dest = dest.deletingPathExtension().appendingPathExtension("mp4") }
                    if policy == "replace" { try? FileManager.default.removeItem(at: dest) } else { dest = uniqueURL(dest) }
                    item.destinationURL = dest; item.filename = dest.lastPathComponent; item.isPrepared = true; persist()
                }
            }

            var mpdURLStr = await MainActor.run { item.url.absoluteString }
            let destPath = await MainActor.run { item.destinationURL.path }
            let referer = await MainActor.run { item.referer }; let userAgent = await MainActor.run { item.userAgent }; let cookies = await MainActor.run { item.cookies }
            let tempDir = await MainActor.run { item.tempDirURL }; let speedLimit = await MainActor.run { item.speedLimit }

            let videoDir = tempDir.appendingPathComponent("video_segs", isDirectory: true); let audioDir = tempDir.appendingPathComponent("audio_segs", isDirectory: true)

            dashLog("Destination: \(destPath)")
            dashLog("Temp Directory: \(tempDir.path)")

            if mpdURLStr.hasPrefix("//") { mpdURLStr = "https:" + mpdURLStr }
            if mpdURLStr.contains("%25") {
                let decoded = mpdURLStr.removingPercentEncoding ?? mpdURLStr
                let testable = decoded.replacingOccurrences(of: "[", with: "%5B").replacingOccurrences(of: "]", with: "%5D")
                if URL(string: testable) != nil { mpdURLStr = decoded }
            }

            do {
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: videoDir, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
            } catch {
                dashLog("ERROR: Could not create temp directories: \(error.localizedDescription)")
                await MainActor.run { item.status = .failed; item.error = "Could not create temp directories: \(error.localizedDescription)"; persist(); scheduleNext() }
                return
            }

            let safeMpdURLStr = mpdURLStr.replacingOccurrences(of: "[", with: "%5B").replacingOccurrences(of: "]", with: "%5D")
            guard let mpdURL = URL(string: safeMpdURLStr) else {
                dashLog("ERROR: Invalid MPD URL")
                await MainActor.run { item.status = .failed; item.error = "Invalid MPD URL."; persist(); scheduleNext() }
                return
            }

            var mpdRequest = URLRequest(url: mpdURL, timeoutInterval: 30)
            let ua = (userAgent != nil && !userAgent!.isEmpty) ? userAgent! : "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
            mpdRequest.setValue(ua, forHTTPHeaderField: "User-Agent")
            
            let effectiveReferer: String
            if mpdURLStr.contains("mail.ru") || mpdURLStr.contains("mycdn.me") { effectiveReferer = "https://my.mail.ru/" } else { effectiveReferer = referer ?? "" }
            if !effectiveReferer.isEmpty { mpdRequest.setValue(effectiveReferer, forHTTPHeaderField: "Referer") }
            
            if let c = cookies, !c.isEmpty {
                let clean = c.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
                mpdRequest.setValue(clean, forHTTPHeaderField: "Cookie")
            }

            dashLog("Fetching MPD File...")
            let mpdXML: String
            do {
                let (data, response) = try await URLSession.shared.data(for: mpdRequest)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    dashLog("ERROR: Server returned HTTP \(http.statusCode) for MPD.")
                    await MainActor.run { item.status = .failed; item.error = "Server returned HTTP \(http.statusCode) for MPD."; persist(); scheduleNext() }; return
                }
                guard let xml = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { throw URLError(.cannotDecodeRawData) }
                mpdXML = xml
            } catch {
                dashLog("ERROR: Failed to fetch MPD: \(error.localizedDescription)")
                await MainActor.run { item.status = .failed; item.error = "Failed to fetch MPD: \(error.localizedDescription)"; persist(); scheduleNext() }; return
            }

            let mpdDebugPath = tempDir.appendingPathComponent("stream.mpd")
            try? mpdXML.write(to: mpdDebugPath, atomically: true, encoding: .utf8)

            let (videoTrack, audioTrack) = dashParseMPD(xml: mpdXML, mpdURL: mpdURLStr)
            guard let video = videoTrack else {
                dashLog("ERROR: No video track found in MPD.")
                await MainActor.run { item.status = .failed; item.error = "No video track found in MPD."; persist(); scheduleNext() }; return
            }

            let hasAudio = audioTrack != nil; let totalSec = video.totalDurationSec
            await MainActor.run { item.hlsTotalSeconds = totalSec }
            
            dashLog("Calculated Total Duration: \(totalSec)s. Video Segments Needed: \(video.segmentCount)")

            func buildSegmentList(track: DASHTrack, label: String) -> [(url: String, out: String)] {
                var segs: [(url: String, out: String)] = []
                for i in 0..<track.segmentCount {
                    let num = track.startNumber + i
                    let url = track.mediaTemplate.replacingOccurrences(of: "$Number$", with: "\(num)")
                    let paddedNum = String(format: "%06d", num); let prefix = label == "Video" ? "vseg" : "aseg"
                    segs.append((url: url, out: "\(prefix)-\(paddedNum).m4s"))
                }
                return segs
            }

            let videoSegments = buildSegmentList(track: video, label: "Video")
            let audioSegments = audioTrack.map { buildSegmentList(track: $0, label: "Audio") } ?? []

            var aria2Headers: [String] = []
            aria2Headers.append("User-Agent: \(ua)")
            if !effectiveReferer.isEmpty { aria2Headers.append("Referer: \(effectiveReferer)") }
            if let c = cookies, !c.isEmpty {
                let clean = c.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
                aria2Headers.append("Cookie: \(clean)")
            }
            aria2Headers.append("Accept: */*"); aria2Headers.append("Accept-Language: en-US,en;q=0.9")

            @Sendable func dashDownloadSegments(segments: [(url: String, out: String)], outputDir: URL, label: String, progressOffset: Double, progressShare: Double) async -> Bool {
                dashLog("Building aria2c input file for \(segments.count) \(label) segments...")
                let inputContent = buildAria2InputFile(segments: segments, headers: aria2Headers)
                let inputFile = tempDir.appendingPathComponent("aria2_\(label).txt")
                do { try inputContent.write(to: inputFile, atomically: true, encoding: .utf8) } catch { return false }

                let initSeg: DASHTrack = label == "video" ? video : audioTrack!
                let initOut = outputDir.appendingPathComponent(label == "video" ? "vinit.mp4" : "ainit.mp4")
                let safeInitURLStr = initSeg.initURL.replacingOccurrences(of: "[", with: "%5B").replacingOccurrences(of: "]", with: "%5D")
                guard let initSafeURL = URL(string: safeInitURLStr) else { return false }

                dashLog("Downloading Initialization Segment for \(label)...")
                var initReq = URLRequest(url: initSafeURL, timeoutInterval: 30)
                initReq.setValue(ua, forHTTPHeaderField: "User-Agent")
                if let ref = referer, !ref.isEmpty { initReq.setValue(ref, forHTTPHeaderField: "Referer") }
                if let c = cookies, !c.isEmpty {
                    let clean = c.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
                    initReq.setValue(clean, forHTTPHeaderField: "Cookie")
                }
                do {
                    let (initData, initResp) = try await URLSession.shared.data(for: initReq)
                    if let http = initResp as? HTTPURLResponse, http.statusCode != 200 {
                        dashLog("ERROR: Init segment returned HTTP \(http.statusCode)")
                        return false
                    }
                    try initData.write(to: initOut)
                } catch {
                    dashLog("ERROR: Init segment failed: \(error.localizedDescription)")
                    return false
                }

                // CRITICAL FIX: Removed --async-dns=false
                var args: [String] = [
                    "--input-file=\(inputFile.path)",
                    "--dir=\(outputDir.path)",
                    "--continue=true",
                    "--file-allocation=none",
                    "--auto-file-renaming=false",
                    "--max-connection-per-server=1",
                    "--split=1",
                    "--max-concurrent-downloads=3",
                    "--timeout=15",
                    "--connect-timeout=15",
                    "--lowest-speed-limit=10K",
                    "--min-split-size=1M",
                    "--retry-wait=3",
                    "--max-tries=5",
                    "--summary-interval=1",
                    "--console-log-level=notice",
                    "--quiet=false"
                ]
                if speedLimit > 0 { args.append("--max-overall-download-limit=\(speedLimit)K") }

                dashLog("Launching aria2c for \(label). Args: \(args.joined(separator: " "))")

                let proc = Process(); let pipe = Pipe(); let errPipe = Pipe()
                proc.executableURL = URL(fileURLWithPath: aria2Exe)
                proc.arguments = args
                proc.standardOutput = pipe
                proc.standardError = errPipe
                
                // CRITICAL: Prevent SIGTTIN by detaching from standard input
                proc.standardInput = FileHandle.nullDevice

                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin"
                proc.environment = env

                await MainActor.run { item.processes.append(proc) }

                // CRITICAL: Non-blocking ReadabilityHandlers prevent buffer deadlocks
                var downloadedSegs = 0
                pipe.fileHandleForReading.readabilityHandler = { fh in
                    let data = fh.availableData
                    guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
                    
                    let lines = str.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
                    for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                        
                        if line.contains("Download complete:") {
                            downloadedSegs += 1
                            let ratio = Double(downloadedSegs) / Double(segments.count)
                            let dlSec = totalSec * (progressOffset + ratio * progressShare)
                            Task { @MainActor in
                                item.hlsDownloadedSeconds = min(dlSec, totalSec)
                                item._lastTickDate = Date()
                            }
                        }
                        if line.contains("DL:") {
                            if let dlRange = line.range(of: "DL:"), let endRange = line[dlRange.upperBound...].firstIndex(where: { $0 == " " || $0 == "]" }) {
                                let speedStr = String(line[dlRange.upperBound..<endRange])
                                let bytes = self.parseAriaSize(speedStr)
                                if bytes > 0 {
                                    Task { @MainActor in
                                        item.speed = Double(bytes)
                                        item._lastTickDate = Date()
                                    }
                                }
                            }
                        }
                    }
                }

                errPipe.fileHandleForReading.readabilityHandler = { fh in
                    let data = fh.availableData
                    if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                        for line in str.components(separatedBy: CharacterSet(charactersIn: "\r\n")) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                            self.dashLog("[ARIA2-ERR-\(label)] \(line)")
                        }
                    }
                }

                // Await completion async
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    proc.terminationHandler = { _ in
                        pipe.fileHandleForReading.readabilityHandler = nil
                        errPipe.fileHandleForReading.readabilityHandler = nil
                        cont.resume()
                    }
                    do {
                        try proc.run()
                    } catch {
                        dashLog("ERROR: Failed to run aria2c process.")
                        pipe.fileHandleForReading.readabilityHandler = nil
                        errPipe.fileHandleForReading.readabilityHandler = nil
                        cont.resume()
                    }
                }
                
                dashLog("Aria2c finished for \(label) with exit code: \(proc.terminationStatus)")
                return proc.terminationStatus == 0
            }

            func isCancelled() async -> Bool { await MainActor.run { item.status != .downloading || item.hlsCancelPointer.pointee != 0 } }

            dashLog("Phase 1: Downloading Video Segments...")
            let videoOK = await dashDownloadSegments(segments: videoSegments, outputDir: videoDir, label: "video", progressOffset: 0.0, progressShare: hasAudio ? 0.80 : 1.0)
            if await isCancelled() { return }

            guard videoOK else {
                dashLog("FATAL: Video segment download blocked or failed.")
                await MainActor.run { item.status = .failed; item.error = "DASH: Segment download blocked or failed. Check console logs."; persist(); scheduleNext() }
                return
            }

            if hasAudio, let audio = audioTrack {
                dashLog("Phase 2: Downloading Audio Segments...")
                let audioOK = await dashDownloadSegments(segments: audioSegments, outputDir: audioDir, label: "audio", progressOffset: 0.80, progressShare: 0.20)
                if await isCancelled() { return }
                guard audioOK else {
                    dashLog("FATAL: Audio segment download blocked or failed.")
                    await MainActor.run { item.status = .failed; item.error = "DASH: Audio segment download blocked or failed. Check console logs."; persist(); scheduleNext() }
                    return
                }
            }

            dashLog("Phase 3: Concatenating Segments...")
            let videoCombinedPath = tempDir.appendingPathComponent("video_combined.mp4")
            do {
                FileManager.default.createFile(atPath: videoCombinedPath.path, contents: nil)
                let handle = try FileHandle(forWritingTo: videoCombinedPath)
                let initPath = videoDir.appendingPathComponent("vinit.mp4")
                if let initData = try? Data(contentsOf: initPath, options: .mappedIfSafe) { try handle.write(contentsOf: initData) }
                
                for seg in videoSegments {
                    let segPath = videoDir.appendingPathComponent(seg.out)
                    if let segData = try? Data(contentsOf: segPath, options: .mappedIfSafe) {
                        if segData.count < 32 { continue }
                        if segData[0] == 0x3C { continue } // Strip HTML
                        try handle.write(contentsOf: segData)
                    }
                }
                try handle.close()
            } catch {
                dashLog("ERROR: Video concat failed: \(error.localizedDescription)")
                await MainActor.run { item.status = .failed; item.error = "Video concat failed: \(error.localizedDescription)"; persist(); scheduleNext() }; return
            }

            var audioCombinedPath: URL? = nil
            if hasAudio {
                let acp = tempDir.appendingPathComponent("audio_combined.mp4")
                do {
                    FileManager.default.createFile(atPath: acp.path, contents: nil)
                    let handle = try FileHandle(forWritingTo: acp)
                    let initPath = audioDir.appendingPathComponent("ainit.mp4")
                    if let initData = try? Data(contentsOf: initPath, options: .mappedIfSafe) { try handle.write(contentsOf: initData) }
                    for seg in audioSegments {
                        let segPath = audioDir.appendingPathComponent(seg.out)
                        if let segData = try? Data(contentsOf: segPath, options: .mappedIfSafe) {
                            if segData.count < 32 { continue }
                            if segData[0] == 0x3C { continue }
                            try handle.write(contentsOf: segData)
                        }
                    }
                    try handle.close(); audioCombinedPath = acp
                } catch {}
            }

            await MainActor.run { item.speed = 0; if item.hlsTotalSeconds > 0 { item.hlsDownloadedSeconds = item.hlsTotalSeconds * 0.98 }; item._lastTickDate = Date() }

            dashLog("Phase 4: Merging with FFmpeg...")
            let ffmpegProc = Process(); let ffmpegErrPipe = Pipe()
            ffmpegProc.executableURL = URL(fileURLWithPath: ffmpegExe); ffmpegProc.standardOutput = Pipe(); ffmpegProc.standardError = ffmpegErrPipe
            ffmpegProc.standardInput = FileHandle.nullDevice

            var ffmpegArgs: [String] = ["-y", "-i", videoCombinedPath.path]
            if let acp = audioCombinedPath { ffmpegArgs += ["-i", acp.path] }
            ffmpegArgs += ["-c", "copy"]
            if audioCombinedPath != nil { ffmpegArgs += ["-map", "0:v:0", "-map", "1:a:0"] }
            ffmpegArgs += ["-movflags", "+faststart", destPath]

            var ffEnv = ProcessInfo.processInfo.environment
            ffEnv["PATH"] = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin"
            ffmpegProc.environment = ffEnv; ffmpegProc.arguments = ffmpegArgs

            await MainActor.run { item.processes.append(ffmpegProc) }

            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                ffmpegProc.terminationHandler = { _ in cont.resume() }
                do {
                    try ffmpegProc.run()
                } catch {
                    dashLog("ERROR: FFmpeg launch failed.")
                    cont.resume()
                }
            }
            
            if await isCancelled() { return }

            guard ffmpegProc.terminationStatus == 0 else {
                let errStr = String(data: ffmpegErrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                dashLog("ERROR: ffmpeg failed. \(errStr)")
                await MainActor.run { item.status = .failed; item.error = "ffmpeg failed. Last error: \(errStr.components(separatedBy: .newlines).last(where: { !$0.isEmpty }) ?? "unknown")"; persist(); scheduleNext() }
                return
            }

            let outputSize = (try? FileManager.default.attributesOfItem(atPath: destPath)[.size] as? Int64) ?? 0
            if outputSize == 0 {
                dashLog("ERROR: Output file is empty after merge.")
                await MainActor.run { item.status = .failed; item.error = "Output file empty after merge."; persist(); scheduleNext() }
                return
            }

            dashLog("========== DASH DOWNLOAD COMPLETE ==========")
            try? FileManager.default.removeItem(at: tempDir)

            await MainActor.run {
                item.status = .completed; item.dateCompleted = Date(); item.speed = 0; item.totalBytes = outputSize; item.downloadedBytes = outputSize
                if item.hlsTotalSeconds > 0 { item.hlsDownloadedSeconds = item.hlsTotalSeconds }
                notifyCompletion(for: item); persist(); scheduleNext()
            }
        }
    }
