import Foundation
import AppKit
import UserNotifications
import Observation

@Observable
@MainActor
public final class DownloadEngine {
    public static let shared = DownloadEngine()
    public var items: [DownloadItem] = []
    public var globalDownloadSpeed: Double = 0

    let persistenceURL: URL
    var speedTimer: Timer?

    var maxConcurrent: Int {
        let max = UserDefaults.standard.integer(forKey: "maxConcurrentDownloads")
        return max > 0 ? max : 5
    }

    var activeCount: Int { items.filter { $0.status == .downloading }.count }

    nonisolated func resolveHomebrewPath(for binary: String, isLibrary: Bool = false) -> String? {
        let basePath = isLibrary ? "lib" : "bin"
        let paths = [
            "/opt/homebrew/\(basePath)/\(binary)",
            "/usr/local/\(basePath)/\(binary)"
        ]
        for path in paths {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return nil
    }
    
    var aria2Path: String? { resolveHomebrewPath(for: "aria2c") }
    var ytDlpPath: String? { resolveHomebrewPath(for: "yt-dlp") }
    var ffmpegPath: String? { resolveHomebrewPath(for: "ffmpeg") }

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Dispatch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        persistenceURL = dir.appendingPathComponent("queue.json")
        loadPersisted()
        startSpeedTimer()
        
        for item in items {
            if item.status == .downloading { item.status = .stopped }
            if item.type == .torrent && (item.subFiles.first?.path ?? "").isEmpty { item.subFiles = [] }
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    public func addDownload(urls: [URL], destination: URL? = nil, connections: Int = 16, headers: [String: String]? = nil, cookies: String? = nil, userAgent: String? = nil, referer: String? = nil, filename: String? = nil, youtubeQuality: String? = nil, isHLS: Bool = false, isDASH: Bool = false, browser: String? = nil, forceDirectDownload: Bool = false) {
        guard !urls.isEmpty else { return }
        let defaults = UserDefaults.standard
        let defaultPath = defaults.string(forKey: "defaultDownloadPath") ?? downloadsDir().path
        let dest = destination ?? URL(fileURLWithPath: defaultPath)

        if urls.count == 1 {
            let url = urls[0]
            let isTorrentFile = url.isFileURL && url.pathExtension.lowercased() == "torrent"
            let isFuckingFast = url.host?.contains("fuckingfast.co") == true && !url.path.starts(with: "/dl/")

            let computedFilename: String
            if let provided = filename { computedFilename = provided }
            else if isFuckingFast { computedFilename = "Resolving…" }
            else if url.scheme == "magnet" { computedFilename = suggestMagnetName(from: url) }
            else if isTorrentFile {
                let base = url.deletingPathExtension().lastPathComponent
                computedFilename = base.isEmpty ? "Torrent Download" : base
            } else { computedFilename = suggestFilename(from: url) }

            let item = DownloadItem(url: url, filename: computedFilename, destination: dest)
            item.connectionCount = connections
            item.headers = headers
            item.cookies = cookies
            item.userAgent = userAgent
            item.referer = referer
            item.browser = browser
            item.youtubeQuality = youtubeQuality
            
            if isFuckingFast { item.needsFuckingFastResolve = true }

            let urlStr = url.absoluteString.lowercased()
            let looksLikeHLS = !forceDirectDownload && (isHLS || url.pathExtension.lowercased() == "m3u8" || item.filename.lowercased().hasSuffix(".m3u8") || urlStr.contains(".m3u8") || urlStr.contains("m3u8"))
            let looksLikeDASH = !forceDirectDownload && (isDASH || url.pathExtension.lowercased() == "mpd" || item.filename.lowercased().hasSuffix(".mpd") || urlStr.contains(".mpd"))

            if looksLikeHLS {
                item.isHLS = true
                item.filename = item.filename.replacingOccurrences(of: ".m3u8", with: "", options: .caseInsensitive)
                if !item.filename.lowercased().hasSuffix(".mp4") { item.filename += ".mp4" }
                item.destinationURL = item.destinationURL.deletingLastPathComponent().appendingPathComponent(item.filename)
            } else if looksLikeDASH {
                item.isDASH = true
                item.filename = item.filename.replacingOccurrences(of: ".mpd", with: "", options: .caseInsensitive)
                if !item.filename.lowercased().hasSuffix(".mp4") { item.filename += ".mp4" }
                item.destinationURL = item.destinationURL.deletingLastPathComponent().appendingPathComponent(item.filename)
            }
            
            item.status = .queued
            items.insert(item, at: 0)
            persist(); scheduleNext()
            NotificationCenter.default.post(name: .openProgressWindow, object: nil, userInfo: ["id": item.id])
        } else {
            var batchName = "Batch Download (\(urls.count) files)"
            if let firstURL = urls.first, firstURL.host?.contains("fuckingfast.co") == true, let fragment = firstURL.fragment {
                var cleanName = fragment.removingPercentEncoding ?? fragment
                if let regex = try? NSRegularExpression(pattern: #"\.part\d+\..+$"#, options: .caseInsensitive) {
                    let range = NSRange(cleanName.startIndex..<cleanName.endIndex, in: cleanName)
                    cleanName = regex.stringByReplacingMatches(in: cleanName, options: [], range: range, withTemplate: "")
                }
                while cleanName.hasSuffix("_") || cleanName.hasSuffix("-") || cleanName.hasSuffix(".") { cleanName.removeLast() }
                if !cleanName.isEmpty { batchName = cleanName }
            }
            
            let item = DownloadItem(url: urls.first!, filename: batchName, destination: dest)
            item.type = .batch
            item.connectionCount = connections
            item.headers = headers
            item.cookies = cookies
            item.userAgent = userAgent
            item.referer = referer
            item.browser = browser
            item.batchURLs = urls.map { $0.absoluteString }
            
            var initialSubFiles: [SubFile] = []
            for (index, url) in urls.enumerated() {
                let isFuckingFast = url.host?.contains("fuckingfast.co") == true && !url.path.starts(with: "/dl/")
                let fn = isFuckingFast ? "Resolving…" : suggestFilename(from: url)
                initialSubFiles.append(SubFile(id: UUID(), index: index + 1, path: fn, filename: fn, totalBytes: 0, downloadedBytes: 0, isStopped: false))
            }
            
            item.subFiles = initialSubFiles
            item.status = .queued
            items.insert(item, at: 0)
            persist(); scheduleNext()
            NotificationCenter.default.post(name: .openProgressWindow, object: nil, userInfo: ["id": item.id])
        }
    }

    public func stop(_ item: DownloadItem, stopSubFiles: Bool = true) {
        guard item.status == .downloading || item.status == .queued else { return }
        item.hlsCancelPointer.pointee = 1
        killProcesses(item)
        item.status = .stopped; item.speed = 0; item._lastTickDate = nil
        if stopSubFiles && (item.type == .torrent || item.type == .batch) {
            var updated = item.subFiles
            for i in updated.indices { updated[i].isStopped = true }
            item.subFiles = updated
        }
        persist(); scheduleNext()
    }
    
    public func stopAll() { items.filter { $0.status == .downloading || $0.status == .queued }.forEach { stop($0, stopSubFiles: true) } }

    public func resume(_ item: DownloadItem, resumeSubFiles: Bool = true) {
        guard item.status == .stopped || item.status == .failed else { return }
        item.retryCount = 0
        if resumeSubFiles && (item.type == .torrent || item.type == .batch) {
            var updated = item.subFiles
            for i in updated.indices { updated[i].isStopped = false }
            item.subFiles = updated
        }
        if activeCount >= maxConcurrent {
            item.status = .queued; persist(); return
        }
        item.processes = []
        startDownload(item)
    }

    public func retry(_ item: DownloadItem) {
        killProcesses(item)
        item.retryCount = 0; item.totalActiveDuration = 0; item.dateAdded = Date()
        try? FileManager.default.removeItem(at: item.tempDirURL)
        if item.type != .torrent && item.type != .batch { try? FileManager.default.removeItem(at: item.destinationURL) }
        item.status = .queued; item.downloadedBytes = 0; item.totalBytes = 0; item.speed = 0
        item.error = nil; item.isPrepared = false; item.supportsRanges = false
        
        if item.type != .batch { item.subFiles = [] }
        else {
            var updated = item.subFiles
            for i in updated.indices { updated[i].downloadedBytes = 0; updated[i].totalBytes = 0; updated[i].isStopped = false }
            item.subFiles = updated
        }
        item._lastTickDate = nil; persist(); scheduleNext()
    }

    public func remove(_ item: DownloadItem, trashFile: Bool = false) {
        killProcesses(item)
        try? FileManager.default.removeItem(at: item.tempDirURL)
        if trashFile || item.status != .completed {
            let fileURL = item.destinationURL
            if FileManager.default.fileExists(atPath: fileURL.path) { try? FileManager.default.trashItem(at: fileURL, resultingItemURL: nil) }
        }
        items.removeAll { $0.id == item.id }; persist(); scheduleNext()
    }

    public func updateSpeedLimit(for item: DownloadItem, limitKB: Int) {
        guard item.speedLimit != limitKB else { return }
        item.speedLimit = limitKB; persist()
        if item.status == .downloading {
            stop(item, stopSubFiles: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.resume(item, resumeSubFiles: false) }
        }
    }

    public func updateTorrentSelection(for item: DownloadItem) {
        persist()
        if item.status == .downloading {
            stop(item, stopSubFiles: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.resume(item, resumeSubFiles: false) }
        }
    }

    func scheduleNext() {
        for next in items where next.status == .queued {
            if activeCount >= maxConcurrent { break }
            if next.type == .batch {
                let activeBatches = items.filter { $0.status == .downloading && $0.type == .batch }
                if !activeBatches.isEmpty { continue }
            }
            startDownload(next)
        }
    }
    
    func startDownload(_ item: DownloadItem) {
        if item.url.scheme == "blob" {
            item.status = .failed; item.error = "Blob URLs cannot be downloaded directly."
            persist(); scheduleNext(); return
        }

        if item.needsFuckingFastResolve || (item.type == .batch && item.totalBytes == 0) {
            item.status = .downloading; item.error = nil; persist()
            Task {
                if item.type == .batch {
                    var resolvedURLs: [String] = []
                    var updatedSubFiles = item.subFiles
                    var hasFailures = false
                    var totalBatchBytes: Int64 = 0
                    
                    for (i, urlStr) in (item.batchURLs ?? []).enumerated() {
                        guard let url = URL(string: urlStr) else { continue }
                        let isFuckingFast = url.host?.contains("fuckingfast.co") == true && !url.path.starts(with: "/dl/")
                        var targetURL: URL? = url
                        if isFuckingFast { targetURL = await resolveFuckingFast(url) }
                        
                        if let dURL = targetURL {
                            resolvedURLs.append(dURL.absoluteString)
                            let meta = await fetchMetadata(url: dURL, userAgent: item.userAgent, cookies: item.cookies)
                            await MainActor.run {
                                let newName = meta.filename ?? (isFuckingFast ? self.suggestFilename(from: dURL) : updatedSubFiles[i].filename)
                                updatedSubFiles[i].filename = newName; updatedSubFiles[i].path = newName
                                if meta.size > 0 { updatedSubFiles[i].totalBytes = meta.size }
                            }
                            totalBatchBytes += meta.size > 0 ? meta.size : 0
                        } else { hasFailures = true; break }
                    }
                    
                    await MainActor.run {
                        if hasFailures {
                            item.status = .failed; item.error = "Could not resolve one or more links in the batch."
                            self.persist(); self.scheduleNext()
                        } else {
                            item.batchURLs = resolvedURLs; item.subFiles = updatedSubFiles; item.needsFuckingFastResolve = false
                            if totalBatchBytes > 0 { item.totalBytes = totalBatchBytes }
                            self.continueStartDownload(item)
                        }
                    }
                } else {
                    if let directURL = await resolveFuckingFast(item.url) {
                        let meta = await fetchMetadata(url: directURL, userAgent: item.userAgent, cookies: item.cookies)
                        await MainActor.run {
                            item.url = directURL; item.filename = meta.filename ?? self.suggestFilename(from: directURL)
                            item.destinationURL = item.destinationURL.deletingLastPathComponent().appendingPathComponent(item.filename)
                            item.sourceHost = directURL.host ?? item.sourceHost; item.needsFuckingFastResolve = false
                            if meta.size > 0 { item.totalBytes = meta.size }
                            self.continueStartDownload(item)
                        }
                    } else {
                        await MainActor.run {
                            item.status = .failed; item.error = "Could not resolve fuckingfast.co link"
                            self.persist(); self.scheduleNext()
                        }
                    }
                }
            }
            return
        }

        if item.isHLS {
            item.status = .downloading; item.error = nil; item._lastTickDate = Date(); persist()
            Task { await runNativeHLSEngine(item) }
            return
        }

        if item.isDASH {
            item.status = .downloading; item.error = nil; item._lastTickDate = Date(); persist()
            Task { await runNativeDASHEngine(item) }
            return
        }

        item.status = .downloading; item.error = nil; item._lastBytes = item.downloadedBytes; item._lastTickDate = Date()
        persist(); continueStartDownload(item)
    }

    func continueStartDownload(_ item: DownloadItem) {
        if item.type == .directLink && item.url.scheme == "data" {
            Task { await writeDataURL(item) }
            return
        }
        if item.url.host?.contains("youtube.com") == true || item.url.host?.contains("youtu.be") == true {
            Task { await runYoutubeDownload(item) }
            return
        }
        if let exe = aria2Path {
            Task { await runAria2(item, executable: exe) }
        } else if item.type == .directLink {
            Task { await runCurl(item) }
        }
    }

    func startSpeedTimer() {
        speedTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    func tick() {
        let now = Date()
        var totalSpeed: Double = 0
        var totalActiveBytes: Int64 = 0
        var totalActiveDownloaded: Int64 = 0
        var activeCount = 0

        for item in items where item.status == .downloading {
            let curBytes = item.downloadedBytes
            item.totalActiveDuration += 0.1

            if let lastDate = item._lastTickDate {
                let dt = now.timeIntervalSince(lastDate)
                if !item._managesOwnSpeed {
                    if dt >= 0.5 {
                        item.speed = max(0.0, Double(curBytes - item._lastBytes) / dt)
                        item._lastBytes = curBytes; item._lastTickDate = now
                    }
                } else {
                    if dt > 3.0 { item.speed = 0 }
                }
            } else { item._lastBytes = curBytes; item._lastTickDate = now }

            totalSpeed += item.speed; totalActiveBytes += item.totalBytes; totalActiveDownloaded += item.downloadedBytes; activeCount += 1
        }

        for item in items where item.status != .downloading && item.speed > 0 { item.speed = 0 }
        globalDownloadSpeed = totalSpeed
        
        let progress = totalActiveBytes > 0 ? Double(totalActiveDownloaded) / Double(totalActiveBytes) : 0.0
        updateDockProgress(progress: progress, totalActive: activeCount)
    }

    func updateDockProgress(progress: Double, totalActive: Int) {
        DispatchQueue.main.async {
            let dockTile = NSApp.dockTile
            if totalActive == 0 { dockTile.contentView = nil; dockTile.badgeLabel = nil; dockTile.display(); return }
            if let customView = dockTile.contentView as? DockProgressView { customView.progress = progress }
            else {
                let size = dockTile.size.width > 0 ? dockTile.size : NSSize(width: 128, height: 128)
                let view = DockProgressView(frame: NSRect(origin: .zero, size: size))
                view.progress = progress; dockTile.contentView = view
            }
            dockTile.badgeLabel = "\(totalActive)"; dockTile.display()
        }
    }

    func killProcesses(_ item: DownloadItem) {
        for proc in item.processes {
            if proc.isRunning {
                proc.interrupt()
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                    if proc.isRunning { proc.terminate() }
                }
            }
        }
        item.processes = []
    }

    func downloadsDir() -> URL { FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first! }

    func notifyCompletion(for item: DownloadItem) {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "playSoundOnComplete") { NSSound(named: .init("Glass"))?.play() }
        let content = UNMutableNotificationContent()
        content.title = "Download Complete"
        content.body = item.filename
        content.sound = .default
        let request = UNNotificationRequest(identifier: item.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func persist() {
        if let d = try? JSONEncoder().encode(items) { try? d.write(to: persistenceURL, options: .atomic) }
    }

    func loadPersisted() {
        guard let d = try? Data(contentsOf: persistenceURL), let dec = try? JSONDecoder().decode([DownloadItem].self, from: d) else { return }
        items = dec
    }
}
