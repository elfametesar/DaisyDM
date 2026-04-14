import Foundation
import AppKit
import UserNotifications

// MARK: - Extensions & UI Components

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s = String(s.dropFirst()) }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard let value = UInt64(s, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xFF) / 255
        let g = CGFloat((value >>  8) & 0xFF) / 255
        let b = CGFloat( value        & 0xFF) / 255
        self.init(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }
}

class DockProgressView: NSView {
    var progress: Double = 0.0 {
        didSet { needsDisplay = true }
    }
    
    private func getBarColor() -> NSColor {
        let defaults = UserDefaults.standard
        let match = defaults.bool(forKey: "matchProgressBarToAccent")
        let hexString = match ? (defaults.string(forKey: "accentColorHex") ?? "#0A84FF") : (defaults.string(forKey: "progressBarColorHex") ?? "#34C759")
        return NSColor(hex: hexString) ?? .systemGreen
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if let appIcon = NSImage(named: NSImage.applicationIconName) { appIcon.draw(in: bounds) }
        
        let inset: CGFloat = bounds.width * 0.12
        let cornerRadius: CGFloat = bounds.width * 0.18
        let barThick: CGFloat = 6.0
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let startY = rect.maxY - (rect.height * 0.45)
        let straightLen = startY - (rect.minY + cornerRadius)
        let arcLen = 0.5 * .pi * cornerRadius
        let bottomLen = rect.width - (2 * cornerRadius)
        let totalLen = (straightLen * 2) + (arcLen * 2) + bottomLen
        
        let bgPath = NSBezierPath()
        bgPath.move(to: NSPoint(x: rect.minX, y: startY))
        bgPath.line(to: NSPoint(x: rect.minX, y: rect.minY + cornerRadius))
        bgPath.appendArc(withCenter: NSPoint(x: rect.minX + cornerRadius, y: rect.minY + cornerRadius), radius: cornerRadius, startAngle: 180, endAngle: 270)
        bgPath.line(to: NSPoint(x: rect.maxX - cornerRadius, y: rect.minY))
        bgPath.appendArc(withCenter: NSPoint(x: rect.maxX - cornerRadius, y: rect.minY + cornerRadius), radius: cornerRadius, startAngle: 270, endAngle: 360)
        bgPath.line(to: NSPoint(x: rect.maxX, y: startY))
        bgPath.lineWidth = barThick; bgPath.lineCapStyle = .round
        NSColor.black.withAlphaComponent(0.4).setStroke(); bgPath.stroke()
        
        if progress > 0 {
            let targetLen = totalLen * CGFloat(min(1.0, progress))
            var currentLen: CGFloat = 0
            let fgPath = NSBezierPath()
            fgPath.move(to: NSPoint(x: rect.minX, y: startY))
            
            if targetLen > currentLen {
                let segLen = straightLen
                if targetLen < currentLen + segLen {
                    let p = (targetLen - currentLen) / segLen
                    fgPath.line(to: NSPoint(x: rect.minX, y: startY - (straightLen * p)))
                    currentLen = targetLen
                } else { fgPath.line(to: NSPoint(x: rect.minX, y: rect.minY + cornerRadius)); currentLen += segLen }
            }
            if targetLen > currentLen {
                let segLen = arcLen
                let center = NSPoint(x: rect.minX + cornerRadius, y: rect.minY + cornerRadius)
                if targetLen < currentLen + segLen {
                    let p = (targetLen - currentLen) / segLen
                    fgPath.appendArc(withCenter: center, radius: cornerRadius, startAngle: 180, endAngle: 180 + (90 * p))
                    currentLen = targetLen
                } else { fgPath.appendArc(withCenter: center, radius: cornerRadius, startAngle: 180, endAngle: 270); currentLen += segLen }
            }
            if targetLen > currentLen {
                let segLen = bottomLen
                if targetLen < currentLen + segLen {
                    let p = (targetLen - currentLen) / segLen
                    fgPath.line(to: NSPoint(x: rect.minX + cornerRadius + (bottomLen * p), y: rect.minY))
                    currentLen = targetLen
                } else { fgPath.line(to: NSPoint(x: rect.maxX - cornerRadius, y: rect.minY)); currentLen += segLen }
            }
            if targetLen > currentLen {
                let segLen = arcLen
                let center = NSPoint(x: rect.maxX - cornerRadius, y: rect.minY + cornerRadius)
                if targetLen < currentLen + segLen {
                    let p = (targetLen - currentLen) / segLen
                    fgPath.appendArc(withCenter: center, radius: cornerRadius, startAngle: 270, endAngle: 270 + (90 * p))
                    currentLen = targetLen
                } else { fgPath.appendArc(withCenter: center, radius: cornerRadius, startAngle: 270, endAngle: 360); currentLen += segLen }
            }
            if targetLen > currentLen {
                let segLen = straightLen
                if targetLen < currentLen + segLen {
                    let p = (targetLen - currentLen) / segLen
                    fgPath.line(to: NSPoint(x: rect.maxX, y: rect.minY + cornerRadius + (straightLen * p)))
                    currentLen = targetLen
                } else { fgPath.line(to: NSPoint(x: rect.maxX, y: startY)); currentLen += segLen }
            }
            fgPath.lineWidth = barThick; fgPath.lineCapStyle = .round
            getBarColor().setStroke(); fgPath.stroke()
        }
    }
}

// MARK: - Models

public enum DownloadStatus: String, Codable, Equatable {
    case queued      = "Queued"
    case downloading = "Downloading"
    case stopped     = "Stopped"
    case completed   = "Completed"
    case failed      = "Failed"
}

public enum DownloadType: String, Codable {
    case directLink  = "Direct Link"
    case torrent     = "Torrent"
    case batch       = "Batch"
}

public struct SubFile: Identifiable, Codable, Hashable {
    public var id = UUID()
    public var index: Int
    public var path: String
    public var filename: String
    public var totalBytes: Int64
    public var downloadedBytes: Int64
    public var isStopped: Bool = false
    
    public init(id: UUID = UUID(), index: Int, path: String, filename: String, totalBytes: Int64, downloadedBytes: Int64, isStopped: Bool) {
        self.id = id; self.index = index; self.path = path; self.filename = filename
        self.totalBytes = totalBytes; self.downloadedBytes = downloadedBytes; self.isStopped = isStopped
    }
    
    enum CodingKeys: String, CodingKey { case id, index, path, filename, totalBytes, downloadedBytes, isStopped }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        index = try container.decodeIfPresent(Int.self, forKey: .index) ?? 1
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        filename = try container.decode(String.self, forKey: .filename)
        totalBytes = try container.decode(Int64.self, forKey: .totalBytes)
        downloadedBytes = try container.decode(Int64.self, forKey: .downloadedBytes)
        isStopped = try container.decodeIfPresent(Bool.self, forKey: .isStopped) ?? true
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id); try container.encode(index, forKey: .index)
        try container.encode(path, forKey: .path); try container.encode(filename, forKey: .filename)
        try container.encode(totalBytes, forKey: .totalBytes); try container.encode(downloadedBytes, forKey: .downloadedBytes)
        try container.encode(isStopped, forKey: .isStopped)
    }
}

@Observable
public final class DownloadItem: Identifiable, Codable, Hashable {
    public let id: UUID
    public var url: URL
    public var filename: String
    public var destinationURL: URL
    public var status: DownloadStatus
    public var type: DownloadType
    public var totalBytes: Int64
    public var downloadedBytes: Int64
    public var speed: Double
    public var error: String?
    public var dateAdded: Date
    public var dateCompleted: Date?
    public var connectionCount: Int
    public var mimeType: String?
    public var sourceHost: String
    public var subFiles: [SubFile] = []
    public var batchURLs: [String]?

    public var isPrepared: Bool = false
    public var supportsRanges: Bool = false
    public var speedLimit: Int = 0
    public var retryCount: Int = 0
    
    public var cookies: String?
    public var userAgent: String?
    public var referer: String?

    public var _managesOwnSpeed: Bool = false
    public var batchGroupID: UUID? = nil
    public var needsFuckingFastResolve: Bool = false
    
    var processes: [Process] = []
    var _lastBytes: Int64 = 0
    var _lastTickDate: Date? = nil

    public static func == (lhs: DownloadItem, rhs: DownloadItem) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    
    public var tempDirURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Dispatch/ActiveDownloads").appendingPathComponent(id.uuidString)
    }

    public var progress: Double {
        if status == .completed { return 1.0 }
        guard totalBytes > 0 else { return 0 }
        let cappedDownloaded = min(downloadedBytes, totalBytes)
        return Double(cappedDownloaded) / Double(totalBytes)
    }

    public var eta: TimeInterval? {
        guard speed > 0, totalBytes > 0 else { return nil }
        let remaining = max(0, totalBytes - downloadedBytes)
        return Double(remaining) / speed
    }

    public var formattedSize: String { formatBytes(totalBytes) }
    public var formattedDownloaded: String {
        let displayBytes = totalBytes > 0 ? min(downloadedBytes, totalBytes) : downloadedBytes
        return formatBytes(displayBytes)
    }
    public var formattedSpeed: String {
        guard speed > 0 else { return "–" }
        return formatBytes(Int64(speed)) + "/s"
    }
    public var formattedETA: String? {
        guard let eta else { return nil }
        if eta < 60 { return "\(Int(eta))s" }
        if eta < 3600 { return "\(Int(eta/60))m \(Int(eta.truncatingRemainder(dividingBy:60)))s" }
        return "\(Int(eta/3600))h \(Int((eta.truncatingRemainder(dividingBy:3600))/60))m"
    }
    public var transferLabel: String {
        if totalBytes > 0 { return "\(formattedDownloaded) of \(formattedSize)" }
        return downloadedBytes > 0 ? formattedDownloaded : "Zero KB"
    }

    public init(url: URL, filename: String, destination: URL) {
        self.id = UUID(); self.url = url; self.filename = filename
        self.destinationURL = destination.appendingPathComponent(filename)
        self.status = .queued
        let isTorrentFile = url.isFileURL && url.pathExtension.lowercased() == "torrent"
        let computedType: DownloadType = (url.scheme == "magnet" || isTorrentFile) ? .torrent : .directLink
        self.type = computedType; self.totalBytes = 0; self.downloadedBytes = 0; self.speed = 0; self.dateAdded = Date()
        self.connectionCount = 16; self.sourceHost = url.host ?? (computedType == .torrent ? "P2P Network" : "")
    }

    enum CodingKeys: String, CodingKey {
        case id, url, filename, destinationURL, status, type, totalBytes, downloadedBytes
        case error, dateAdded, dateCompleted, connectionCount, mimeType, sourceHost
        case isPrepared, supportsRanges, speedLimit, subFiles, batchURLs
        case cookies, userAgent, referer, retryCount
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); url = try c.decode(URL.self, forKey: .url)
        filename = try c.decode(String.self, forKey: .filename); destinationURL = try c.decode(URL.self, forKey: .destinationURL)
        status = try c.decode(DownloadStatus.self, forKey: .status)
        if let rawStatus = try? c.decode(String.self, forKey: .status) { if rawStatus == "Stopped" || rawStatus == "Cancelled" { status = .stopped } }
        type = try c.decodeIfPresent(DownloadType.self, forKey: .type) ?? .directLink
        totalBytes = try c.decode(Int64.self, forKey: .totalBytes); downloadedBytes = try c.decode(Int64.self, forKey: .downloadedBytes)
        speed = 0; error = try c.decodeIfPresent(String.self, forKey: .error); dateAdded = try c.decode(Date.self, forKey: .dateAdded)
        dateCompleted = try c.decodeIfPresent(Date.self, forKey: .dateCompleted)
        connectionCount = try c.decodeIfPresent(Int.self, forKey: .connectionCount) ?? 16
        mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType); sourceHost = try c.decodeIfPresent(String.self, forKey: .sourceHost) ?? ""
        isPrepared = try c.decodeIfPresent(Bool.self, forKey: .isPrepared) ?? false; supportsRanges = try c.decodeIfPresent(Bool.self, forKey: .supportsRanges) ?? false
        speedLimit = try c.decodeIfPresent(Int.self, forKey: .speedLimit) ?? 0; subFiles = try c.decodeIfPresent([SubFile].self, forKey: .subFiles) ?? []
        batchURLs = try c.decodeIfPresent([String].self, forKey: .batchURLs); cookies = try c.decodeIfPresent(String.self, forKey: .cookies)
        userAgent = try c.decodeIfPresent(String.self, forKey: .userAgent); referer = try c.decodeIfPresent(String.self, forKey: .referer)
        retryCount = try c.decodeIfPresent(Int.self, forKey: .retryCount) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(url, forKey: .url); try c.encode(filename, forKey: .filename)
        try c.encode(destinationURL, forKey: .destinationURL); try c.encode(status, forKey: .status); try c.encode(type, forKey: .type)
        try c.encode(totalBytes, forKey: .totalBytes); try c.encode(downloadedBytes, forKey: .downloadedBytes)
        try c.encodeIfPresent(error, forKey: .error); try c.encode(dateAdded, forKey: .dateAdded)
        try c.encodeIfPresent(dateCompleted, forKey: .dateCompleted); try c.encode(connectionCount, forKey: .connectionCount)
        try c.encodeIfPresent(mimeType, forKey: .mimeType); try c.encode(sourceHost, forKey: .sourceHost)
        try c.encode(isPrepared, forKey: .isPrepared); try c.encode(supportsRanges, forKey: .supportsRanges)
        try c.encode(speedLimit, forKey: .speedLimit); try c.encode(subFiles, forKey: .subFiles)
        try c.encodeIfPresent(batchURLs, forKey: .batchURLs); try c.encodeIfPresent(cookies, forKey: .cookies)
        try c.encodeIfPresent(userAgent, forKey: .userAgent); try c.encodeIfPresent(referer, forKey: .referer)
        try c.encode(retryCount, forKey: .retryCount)
    }
}

// MARK: - Engine

@Observable
@MainActor
public final class DownloadEngine {
    public static let shared = DownloadEngine()
    public var items: [DownloadItem] = []
    public var globalDownloadSpeed: Double = 0

    private let persistenceURL: URL
    private var speedTimer: Timer?

    private var maxConcurrent: Int {
        let max = UserDefaults.standard.integer(forKey: "maxConcurrentDownloads")
        return max > 0 ? max : 5
    }

    private var activeCount: Int { items.filter { $0.status == .downloading }.count }

    private var aria2Path: String? {
        let paths = ["/opt/homebrew/bin/aria2c", "/usr/local/bin/aria2c", "/usr/bin/aria2c"]
        return paths.first { FileManager.default.fileExists(atPath: $0) }
    }

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

    public func addDownload(urls: [URL], destination: URL? = nil, connections: Int = 16, cookies: String? = nil, userAgent: String? = nil, referer: String? = nil, filename: String? = nil) {
        guard !urls.isEmpty else { return }
        let defaults = UserDefaults.standard
        let defaultPath = defaults.string(forKey: "defaultDownloadPath") ?? downloadsDir().path
        let dest = destination ?? URL(fileURLWithPath: defaultPath)

        if urls.count == 1 {
            let url = urls[0]
            let isTorrentFile = url.isFileURL && url.pathExtension.lowercased() == "torrent"

            let computedFilename: String
            if let provided = filename { computedFilename = provided }
            else if url.scheme == "magnet" { computedFilename = suggestMagnetName(from: url) }
            else if isTorrentFile {
                let base = url.deletingPathExtension().lastPathComponent
                computedFilename = base.isEmpty ? "Torrent Download" : base
            } else { computedFilename = suggestFilename(from: url) }

            let item = DownloadItem(url: url, filename: computedFilename, destination: dest)
            item.connectionCount = connections
            item.cookies = cookies; item.userAgent = userAgent; item.referer = referer
            
            item.status = .queued
            items.insert(item, at: 0)
            persist()
            scheduleNext()
            
            NotificationCenter.default.post(name: .openProgressWindow, object: nil, userInfo: ["id": item.id])
        } else {
            let groupID = UUID()
            var newItems: [DownloadItem] = []
            for (_, url) in urls.enumerated() {
                let isFuckingFast = url.host?.contains("fuckingfast.co") == true && !url.path.starts(with: "/dl/")
                let fn = isFuckingFast ? "Resolving…" : suggestFilename(from: url)
                let item = DownloadItem(url: url, filename: fn, destination: dest)
                item.connectionCount = connections
                item.cookies = cookies; item.userAgent = userAgent; item.referer = referer
                item.batchGroupID = groupID
                item.sourceHost = url.host ?? ""
                if isFuckingFast {
                    item.type = .directLink
                    item.needsFuckingFastResolve = true
                }
                item.status = .queued
                newItems.append(item)
            }
            
            for item in newItems.reversed() { items.insert(item, at: 0) }
            persist()
            scheduleNext()
            
            if let first = newItems.first {
                NotificationCenter.default.post(name: .openProgressWindow, object: nil, userInfo: ["id": first.id])
            }
        }
    }
    
    private func getProxyString() -> String? {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "proxyEnabled") else { return nil }
        let host = defaults.string(forKey: "proxyHost") ?? ""
        let port = defaults.string(forKey: "proxyPort") ?? "8080"
        let user = defaults.string(forKey: "proxyUsername") ?? ""
        let pass = defaults.string(forKey: "proxyPassword") ?? ""
        
        guard !host.isEmpty else { return nil }
        var prefix = host.hasPrefix("http") || host.hasPrefix("socks") ? host : "http://\(host)"
        if !user.isEmpty {
            let auth = pass.isEmpty ? "\(user)@" : "\(user):\(pass)@"
            if let schemeRange = prefix.range(of: "://") { prefix.insert(contentsOf: auth, at: schemeRange.upperBound) }
        }
        return "\(prefix):\(port)"
    }

    private func notifyCompletion(for item: DownloadItem) {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "playSoundOnComplete") { NSSound(named: .init("Glass"))?.play() }
        
        let content = UNMutableNotificationContent()
        content.title = "Download Complete"
        content.body = item.filename
        content.sound = .default
        
        let request = UNNotificationRequest(identifier: item.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    public func stop(_ item: DownloadItem) {
        guard item.status == .downloading || item.status == .queued else { return }
        killProcesses(item)
        item.status = .stopped; item.speed = 0; item._lastTickDate = nil
        persist(); scheduleNext()
    }
    
    public func stopAll() {
        items.filter { $0.status == .downloading || $0.status == .queued }.forEach { stop($0) }
    }

    public func resume(_ item: DownloadItem) {
        guard item.status == .stopped || item.status == .failed else { return }
        item.retryCount = 0
        if activeCount >= maxConcurrent { item.status = .queued; persist(); return }
        startDownload(item)
    }

    public func retry(_ item: DownloadItem) {
        killProcesses(item)
        item.retryCount = 0
        try? FileManager.default.removeItem(at: item.tempDirURL)
        if item.type != .torrent && item.type != .batch { try? FileManager.default.removeItem(at: item.destinationURL) }
        
        item.status = .queued; item.downloadedBytes = 0; item.totalBytes = 0; item.speed = 0
        item.error = nil; item.isPrepared = false; item.supportsRanges = false
        
        if item.type != .batch { item.subFiles = [] }
        else { for i in item.subFiles.indices { item.subFiles[i].downloadedBytes = 0; item.subFiles[i].totalBytes = 0 } }
        
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
        if item.status == .downloading { stop(item); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.resume(item) } }
    }

    public func updateTorrentSelection(for item: DownloadItem) {
        persist()
        if item.status == .downloading { stop(item); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.resume(item) } }
        else if item.status == .stopped || item.status == .completed { item.status = .stopped; resume(item) }
    }

    private func scheduleNext() {
        for next in items where next.status == .queued {
            if activeCount >= maxConcurrent { break }
            
            if next.type == .batch {
                let activeBatches = items.filter { $0.status == .downloading && $0.type == .batch }
                if !activeBatches.isEmpty { continue }
            }
            
            startDownload(next)
        }
    }

    private func startDownload(_ item: DownloadItem) {
        if item.url.scheme == "blob" {
            item.status = .failed
            item.error = "Blob URLs are browser-local and cannot be downloaded directly. Please download the .torrent file to your Mac and add it to Dispatch manually."
            persist(); scheduleNext(); return
        }

        if item.needsFuckingFastResolve {
            item.status = .downloading
            item.error = nil; persist()
            Task {
                if let directURL = await resolveFuckingFast(item.url) {
                    await MainActor.run {
                        item.url = directURL
                        item.filename = suggestFilename(from: directURL)
                        item.destinationURL = item.destinationURL.deletingLastPathComponent().appendingPathComponent(item.filename)
                        item.sourceHost = directURL.host ?? item.sourceHost
                        item.needsFuckingFastResolve = false
                    }
                    await MainActor.run { self.continueStartDownload(item) }
                } else {
                    await MainActor.run {
                        item.status = .failed; item.error = "Could not resolve direct link from fuckingfast.co"
                        persist(); scheduleNext()
                    }
                }
            }
            return
        }

        item.status = .downloading
        item.error = nil
        item._lastBytes = item.downloadedBytes
        item._lastTickDate = Date()
        persist()
        continueStartDownload(item)
    }

    private func continueStartDownload(_ item: DownloadItem) {
        if item.type == .directLink && item.url.scheme == "data" {
            Task { await writeDataURL(item) }
            return
        }

        if let exe = aria2Path {
            Task { await runAria2(item, executable: exe) }
        } else if item.type == .directLink {
            Task { await runCurl(item) }
        } else {
            item.status = .failed
            item.error = "Missing Engine. Please run 'brew install aria2' in your Terminal."
            persist(); scheduleNext()
        }
    }

    private func resolveFuckingFast(_ url: URL) async -> URL? {
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

    private func runAria2(_ item: DownloadItem, executable: String) async {
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

        let destDir    = tempDir.path
        let fileName   = await MainActor.run { item.filename }
        let conns      = await MainActor.run { item.connectionCount }
        let type       = await MainActor.run { item.type }
        let url        = await MainActor.run { item.url }
        let speedLimit = await MainActor.run { item.speedLimit }
        
        let cookies   = await MainActor.run { item.cookies }
        let userAgent = await MainActor.run { item.userAgent }
        let referer   = await MainActor.run { item.referer }

        var args = [
            "--dir=\(destDir)", "--continue=true", "--file-allocation=none",
            "--max-connection-per-server=\(conns)", "--split=\(conns)", "--min-split-size=1M",
            "--seed-time=0", "--auto-file-renaming=false", "--summary-interval=1", "--console-log-level=notice"
        ]

        if speedLimit > 0 { args.append("--max-overall-download-limit=\(speedLimit)K") }
        if type != .torrent && type != .batch { args.append("--out=\(fileName)") }
        if let cookies = cookies, !cookies.isEmpty { args.append("--header=Cookie: \(cookies)") }
        
        let host = url.host ?? ""
        let resolvedReferer = (referer != nil && !referer!.isEmpty) ? referer! : "https://\(host)/"
        let refHost = URL(string: resolvedReferer)?.host ?? host
        let isSameOrigin = host.hasSuffix(refHost) || refHost.hasSuffix(host)
        
        args.append("--referer=\(resolvedReferer)")
        args.append("--header=Origin: https://\(host)")
        args.append("--header=Sec-Fetch-Site: \(isSameOrigin ? "same-origin" : "cross-site")")
        args.append("--header=Sec-Fetch-Dest: document")
        args.append("--header=Sec-Fetch-Mode: navigate")
        args.append("--header=Sec-Fetch-User: ?1")
        args.append("--header=Upgrade-Insecure-Requests: 1")
        
        let ua = (userAgent != nil && !userAgent!.isEmpty) ? userAgent! : "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
        args.append("--user-agent=\(ua)")
        args.append("--header=Sec-Ch-Ua: \"Google Chrome\";v=\"131\", \"Chromium\";v=\"131\", \"Not_A Brand\";v=\"24\"")
        args.append("--header=Sec-Ch-Ua-Mobile: ?0")
        args.append("--header=Sec-Ch-Ua-Platform: \"macOS\"")
        args.append("--header=Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8")
        args.append("--header=Accept-Language: en-US,en;q=0.9")

        if type == .torrent {
            args += [
                "--enable-dht=true", "--bt-enable-lpd=true", "--enable-peer-exchange=true", "--bt-save-metadata=true",
                "--dht-listen-port=6881-6999",
                "--bt-tracker=udp://tracker.opentrackr.org:1337/announce,udp://open.stealth.si:80/announce,udp://tracker.torrent.eu.org:451/announce,udp://open.demonii.com:1337/announce,udp://exodus.desync.com:6969/announce,udp://tracker.torrent.eu.org:451/announce,udp://tracker.cyberia.is:6969/announce,udp://retracker.lanta-net.ru:2710/announce,udp://tracker.moeking.me:6969/announce,udp://tracker.pomf.se:80/announce,udp://tracker.publicbt.com:80/announce,udp://tracker.tiny-vps.com:6969/announce,udp://tracker.files.fm:6969/announce"
            ]
        }
        
        if type == .batch {
            let listPath = tempDir.appendingPathComponent("batch_list.txt")
            let listContent = (await MainActor.run { item.batchURLs })?.joined(separator: "\n") ?? ""
            try? listContent.write(to: listPath, atomically: true, encoding: .utf8)
            args.append("-i"); args.append(listPath.path)
        } else if type == .torrent {
            let activeIndices = await MainActor.run { item.subFiles.filter { !$0.isStopped }.map { String($0.index) }.joined(separator: ",") }
            if !activeIndices.isEmpty { args.append("--select-file=\(activeIndices)") }
            else if !(await MainActor.run { item.subFiles.isEmpty }) { await MainActor.run { stop(item) }; return }
            args.append(url.isFileURL ? url.path : url.absoluteString)
        } else {
            args.append(url.isFileURL ? url.path : url.absoluteString)
        }

        proc.arguments = args
        let stdoutPipe = Pipe(); proc.standardOutput = stdoutPipe; proc.standardError = FileHandle.nullDevice
        
        let sizeSnifferTask = Task { [weak item] in
            guard let item else { return }
            for try await line in stdoutPipe.fileHandleForReading.bytes.lines {
                if line.contains("Length: ") {
                    if let range = line.range(of: "Length: ") {
                        let sub = line[range.upperBound...]
                        let bytesStr = sub.prefix(while: { $0.isNumber })
                        if let bytes = Int64(bytesStr), bytes > 0 { await MainActor.run { if item.totalBytes == 0 { item.totalBytes = bytes } } }
                    }
                }
                
                if line.contains("[#") && line.contains("CN:") {
                    var totalDl: Int64 = 0; var totalSz: Int64 = 0; var parsedSpeed: Double? = nil; var foundMatch = false
                    
                    let blocks = line.components(separatedBy: "[#")
                    for block in blocks {
                        guard block.contains("CN:") else { continue }
                        let parts = block.split(separator: " ")
                        guard parts.count >= 2 else { continue }
                        
                        let transferPart = parts[1]; let sizes = transferPart.components(separatedBy: "(")[0]; let sizeParts = sizes.components(separatedBy: "/")
                        
                        totalDl += parseAriaSize(sizeParts[0])
                        if sizeParts.count > 1 { totalSz += parseAriaSize(sizeParts[1]) }
                        foundMatch = true
                        
                        if let dlRange = block.range(of: "DL:") {
                            let sub = block[dlRange.upperBound...]; let speedStr = sub.prefix(while: { $0 != " " && $0 != "]" })
                            parsedSpeed = Double(parseAriaSize(String(speedStr)))
                        }
                    }
                    
                    if foundMatch {
                        await MainActor.run {
                            if totalDl > 0 { item.downloadedBytes = totalDl }
                            if totalSz > item.totalBytes { item.totalBytes = totalSz }
                            if let s = parsedSpeed { item.speed = s }
                        }
                    }
                }
            }
        }
        
        let pollTask = Task { [weak item] in
            guard let item else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                
                if item.type == .torrent {
                    let currentSubFiles = await MainActor.run { item.subFiles }
                    if currentSubFiles.isEmpty {
                        if let enumerator = FileManager.default.enumerator(at: tempDir, includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants]) {
                            let fileURLs = enumerator.allObjects.compactMap { $0 as? URL }
                            if let torrent = fileURLs.first(where: { $0.pathExtension == "torrent" }) {
                                let newSubFiles = await self.fetchLocalTorrentInfo(path: torrent.path, executable: executable)
                                if !newSubFiles.isEmpty {
                                    await MainActor.run {
                                        item.subFiles = newSubFiles; item.totalBytes = newSubFiles.map { $0.totalBytes }.reduce(0, +)
                                    }
                                }
                            }
                        }
                    } else {
                        var updatedSubFiles = currentSubFiles
                        for i in updatedSubFiles.indices {
                            let fileURL = tempDir.appendingPathComponent(updatedSubFiles[i].path)
                            if let vals = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]) {
                                let physical = vals.totalFileAllocatedSize ?? 0; let logical = vals.fileSize ?? 0
                                updatedSubFiles[i].downloadedBytes = Int64(min(physical, logical))
                            }
                        }
                        await MainActor.run { item.subFiles = updatedSubFiles }
                    }
                } else if item.type == .batch {
                    var updatedSubFiles: [SubFile] = []
                    if let enumerator = FileManager.default.enumerator(at: tempDir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey], options: [.skipsSubdirectoryDescendants]) {
                        var index = 1
                        let fileURLs = enumerator.allObjects.compactMap { $0 as? URL }
                        for fileURL in fileURLs {
                            let fname = fileURL.lastPathComponent
                            if fname == "batch_list.txt" || fname.hasSuffix(".aria2") { continue }
                            if let vals = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]) {
                                let physical = vals.totalFileAllocatedSize ?? 0; let logical = vals.fileSize ?? 0
                                updatedSubFiles.append(SubFile(id: UUID(), index: index, path: fname, filename: fname, totalBytes: Int64(logical), downloadedBytes: Int64(min(physical, logical)), isStopped: false))
                                index += 1
                            }
                        }
                    }
                    await MainActor.run {
                        var merged = item.subFiles
                        for newSub in updatedSubFiles {
                            if let idx = merged.firstIndex(where: { $0.filename == newSub.filename }) {
                                merged[idx].downloadedBytes = newSub.downloadedBytes; merged[idx].totalBytes = newSub.totalBytes
                            } else { merged.append(newSub) }
                        }
                        item.subFiles = merged
                    }
                }
            }
        }

        await MainActor.run { item._lastBytes = item.downloadedBytes; item._lastTickDate = Date(); item.processes.append(proc) }

        await withCheckedContinuation { cont in
            proc.terminationHandler = { _ in cont.resume() }
            do { try proc.run(); didLaunch = true } catch { cont.resume() }
        }

        pollTask.cancel(); sizeSnifferTask.cancel()
        
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
                        let src = tempDir.appendingPathComponent(file.path); let dst = destDirURL.appendingPathComponent(file.path)
                        try? FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                        _ = try? FileManager.default.removeItem(at: dst); try? FileManager.default.moveItem(at: src, to: dst)
                    }
                }
            }
            
            try? FileManager.default.removeItem(at: tempDir)
            await MainActor.run {
                if item.totalBytes == 0 { item.totalBytes = item.downloadedBytes }
                if item.type == .torrent && item.downloadedBytes < item.totalBytes && !item.subFiles.isEmpty {
                    item.status = .stopped
                } else {
                    item.status = .completed; item.dateCompleted = Date(); self.notifyCompletion(for: item)
                }
                item.speed = 0; item._lastTickDate = nil; persist(); scheduleNext()
            }
        } else if status == .downloading && isStillTracked {
            let currentRetry = await MainActor.run { item.retryCount }
            if currentRetry < 3 {
                await MainActor.run { item.retryCount += 1; item.status = .queued; item.speed = 0; item._lastTickDate = nil }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await MainActor.run { scheduleNext() }
            } else {
                await MainActor.run { item.status = .failed; item.error = self.aria2HumanError(exitCode: proc.terminationStatus); item.speed = 0; item._lastTickDate = nil; persist(); scheduleNext() }
            }
        }
    }

    private func runCurl(_ item: DownloadItem) async {
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
        if let cookies = cookies, !cookies.isEmpty { args.append(contentsOf: ["--cookie", cookies]) }
        
        let host = url.host ?? ""
        let resolvedReferer = (referer != nil && !referer!.isEmpty) ? referer! : "https://\(host)/"
        let refHost = URL(string: resolvedReferer)?.host ?? host
        let isSameOrigin = host.hasSuffix(refHost) || refHost.hasSuffix(host)
        
        args.append(contentsOf: ["--referer", resolvedReferer])
        args.append(contentsOf: ["--header", "Origin: https://\(host)"])
        args.append(contentsOf: ["--header", "Sec-Fetch-Site: \(isSameOrigin ? "same-origin" : "cross-site")"])
        args.append(contentsOf: ["--header", "Sec-Fetch-Dest: document"])
        args.append(contentsOf: ["--header", "Sec-Fetch-Mode: navigate"])
        args.append(contentsOf: ["--header", "Sec-Fetch-User: ?1"])
        
        let ua = (userAgent != nil && !userAgent!.isEmpty) ? userAgent! : "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
        args.append(contentsOf: ["--user-agent", ua])
        args.append(contentsOf: [
            "--header", "Sec-Ch-Ua: \"Google Chrome\";v=\"131\", \"Chromium\";v=\"131\", \"Not_A Brand\";v=\"24\"",
            "--header", "Sec-Ch-Ua-Mobile: ?0", "--header", "Sec-Ch-Ua-Platform: \"macOS\"",
            "--header", "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8",
            "--header", "Accept-Language: en-US,en;q=0.9"
        ])
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
        await withCheckedContinuation { cont in
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
                if r < 3 && status != 401 && status != 403 && status != 404 {
                    await MainActor.run { item.retryCount += 1; item.status = .queued; item.speed = 0; item._lastTickDate = nil }
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    await MainActor.run { scheduleNext() }
                } else {
                    await MainActor.run { item.status = .failed; item.error = errorMsg; item.speed = 0; item._lastTickDate = nil; persist(); scheduleNext() }
                }
            } else {
                let finalDest = await MainActor.run { item.destinationURL }
                if finalDest.path != destFile && FileManager.default.fileExists(atPath: destFile) {
                    _ = try? FileManager.default.removeItem(at: finalDest)
                    try? FileManager.default.moveItem(atPath: destFile, toPath: finalDest.path)
                }
                await MainActor.run {
                    if let line = stdoutText.components(separatedBy: "\n").last(where: { !$0.isEmpty }) {
                        let parts = line.split(separator: " ")
                        if parts.count >= 2, let sz = Int64(parts[1]), sz > 0 {
                            item.downloadedBytes = sz; if item.totalBytes == 0 { item.totalBytes = sz }
                        }
                    }
                    item.status = .completed; item.dateCompleted = Date(); item.speed = 0; item._lastTickDate = nil
                    self.notifyCompletion(for: item); persist(); scheduleNext()
                }
            }
        } else if currentStatus == .downloading && isStillTracked {
            let errorMsg = curlHumanError(exitCode: proc.terminationStatus, stderr: stderrText, stdout: stdoutText)
            let r = await MainActor.run { item.retryCount }
            if r < 3 {
                await MainActor.run { item.retryCount += 1; item.status = .queued; item.speed = 0; item._lastTickDate = nil }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await MainActor.run { scheduleNext() }
            } else {
                await MainActor.run { item.status = .failed; item.error = errorMsg; item.speed = 0; item._lastTickDate = nil; persist(); scheduleNext() }
            }
        }
    }
    
    private func writeDataURL(_ item: DownloadItem) async {
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
            item.filename        = fn; item.destinationURL  = finalDest
            item.totalBytes      = Int64(data.count); item.downloadedBytes = Int64(data.count)
            item.status          = .completed; item.dateCompleted   = Date(); item.speed = 0
            self.notifyCompletion(for: item)
            persist(); scheduleNext()
        }
    }

    private func mimeToExt(_ mime: String) -> String {
        switch mime {
        case "video/mp4": return ".mp4"; case "video/webm": return ".webm"; case "audio/mpeg": return ".mp3"; case "audio/mp4": return ".m4a"
        case "application/zip": return ".zip"; case "application/pdf": return ".pdf"; case "image/jpeg": return ".jpg"; case "image/png": return ".png"
        case "image/gif": return ".gif"; case "application/octet-stream": return ".bin"; default: return ""
        }
    }

    private func aria2HumanError(exitCode: Int32) -> String {
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

    private func curlHumanError(exitCode: Int32, stderr: String, stdout: String) -> String {
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
    
    private func fetchLocalTorrentInfo(path: String, executable: String) async -> [SubFile] {
        return await withCheckedContinuation { cont in
            let proc = Process(); proc.executableURL = URL(fileURLWithPath: executable); proc.arguments = ["--show-files", path]
            let pipe = Pipe(); proc.standardOutput = pipe; proc.standardError = Pipe()
            let readTask = Task {
                var outputData = Data()
                do { if let data = try pipe.fileHandleForReading.readToEnd() { outputData = data } } catch {}
                return String(data: outputData, encoding: .utf8) ?? ""
            }
            proc.terminationHandler = { _ in Task { let output = await readTask.value; cont.resume(returning: self.parseShowFiles(output)) } }
            do { try proc.run() } catch { cont.resume(returning: []) }
        }
    }

    private func fetchTorrentInfo(item: DownloadItem, executable: String) async -> [SubFile] {
        let tempDir = await MainActor.run { item.tempDirURL.path }
        let targetPath = item.url.isFileURL ? item.url.path : item.url.absoluteString
        
        return await withCheckedContinuation { cont in
            let proc = Process(); proc.executableURL = URL(fileURLWithPath: executable)
            proc.arguments = [
                "--show-files", "--enable-dht=true", "--bt-enable-lpd=true", "--enable-peer-exchange=true", "--dht-listen-port=6881-6999",
                "--bt-tracker=udp://tracker.opentrackr.org:1337/announce,udp://open.stealth.si:80/announce,udp://tracker.torrent.eu.org:451/announce,udp://tracker.dler.org:6969/announce,udp://exodus.desync.com:6969/announce,udp://retracker.lanta-net.ru:2710/announce,udp://tracker.moeking.me:6969/announce,udp://tracker.pomf.se:80/announce,udp://tracker.publicbt.com:80/announce,udp://tracker.tiny-vps.com:6969/announce,udp://tracker.files.fm:6969/announce",
                "--dir=\(tempDir)", targetPath
            ]
            let pipe = Pipe(); proc.standardOutput = pipe; proc.standardError = Pipe()
            let readTask = Task {
                var outputData = Data()
                do { if let data = try pipe.fileHandleForReading.readToEnd() { outputData = data } } catch {}
                return String(data: outputData, encoding: .utf8) ?? ""
            }
            proc.terminationHandler = { _ in Task { let output = await readTask.value; let parsed = self.parseShowFiles(output); cont.resume(returning: parsed) } }
            do {
                try proc.run()
                Task { try? await Task.sleep(nanoseconds: 120_000_000_000); if proc.isRunning { proc.terminate() } }
            } catch { cont.resume(returning: []) }
        }
    }
    
    nonisolated private func parseShowFiles(_ output: String) -> [SubFile] {
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

    private func startSpeedTimer() {
        speedTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    private func tick() {
        let now = Date()
        var totalSpeed: Double = 0
        var totalActiveBytes: Int64 = 0
        var totalActiveDownloaded: Int64 = 0
        var activeCount = 0

        for item in items where item.status == .downloading {
            let curBytes = item.downloadedBytes
            if let lastDate = item._lastTickDate {
                let dt = now.timeIntervalSince(lastDate)
                if !item._managesOwnSpeed {
                    if dt >= 0.5 {
                        item.speed = max(0.0, Double(curBytes - item._lastBytes) / dt)
                        item._lastBytes = curBytes; item._lastTickDate = now
                    }
                } else {
                    if curBytes == item._lastBytes && dt > 3.0 { item.speed = 0 }
                    else if curBytes != item._lastBytes { item._lastBytes = curBytes; item._lastTickDate = now }
                }
            } else { item._lastBytes = curBytes; item._lastTickDate = now }

            totalSpeed += item.speed
            totalActiveBytes += item.totalBytes
            totalActiveDownloaded += item.downloadedBytes
            activeCount += 1
        }

        for item in items where item.status != .downloading && item.speed > 0 { item.speed = 0 }
        globalDownloadSpeed = totalSpeed
        
        let progress = totalActiveBytes > 0 ? Double(totalActiveDownloaded) / Double(totalActiveBytes) : 0.0
        updateDockProgress(progress: progress, totalActive: activeCount)
    }
    
    private func updateDockProgress(progress: Double, totalActive: Int) {
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

    private func killProcesses(_ item: DownloadItem) {
        item.processes.forEach { guard $0.isRunning else { return }; $0.terminate() }
        item.processes = []
    }
    
    private func downloadsDir() -> URL { FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first! }

    private func suggestFilename(from url: URL) -> String {
        if url.scheme == "data" { return "attachment_\(Int(Date().timeIntervalSince1970))" }
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        c?.query = nil
        let last = (c?.url ?? url).lastPathComponent
        let dec = last.removingPercentEncoding ?? last
        return (!dec.isEmpty && dec != "/") ? dec : "download_\(Int(Date().timeIntervalSince1970))"
    }

    private func suggestMagnetName(from url: URL) -> String {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let dn = comps.queryItems?.first(where: { $0.name == "dn" })?.value else {
            return "Torrent_\(Int(Date().timeIntervalSince1970))"
        }
        return dn.removingPercentEncoding ?? dn
    }

    private func uniqueURL(_ url: URL) -> URL {
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

    func persist() {
        if let d = try? JSONEncoder().encode(items) { try? d.write(to: persistenceURL, options: .atomic) }
    }

    private func loadPersisted() {
        guard let d = try? Data(contentsOf: persistenceURL), let dec = try? JSONDecoder().decode([DownloadItem].self, from: d) else { return }
        items = dec
    }
    
    nonisolated private func parseAriaSize(_ str: String) -> Int64 {
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
}

func formatBytes(_ bytes: Int64) -> String {
    guard bytes > 0 else { return "0 B" }
    let units = ["B", "KB", "MB", "GB", "TB"]
    var v = Double(bytes), u = 0
    while v >= 1024, u < units.count - 1 { v /= 1024; u += 1 }
    return String(format: v >= 100 ? "%.0f %@" : "%.1f %@", v, units[u])
}
