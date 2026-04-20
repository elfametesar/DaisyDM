import Foundation
import AppKit
import UserNotifications

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
    public var browser: String?
    public var youtubeQuality: String?

    public var isPrepared: Bool = false
    public var supportsRanges: Bool = false
    public var speedLimit: Int = 0
    public var retryCount: Int = 0
    
    public var cookies: String?
    public var userAgent: String?
    public var referer: String?

    public var isHLS: Bool = false
    public var isDASH: Bool = false
    public var hlsSegmentsDone: Int32 = 0
    public var hlsSegmentsTotal: Int32 = 0
    public var hlsDownloadedSeconds: Double = 0
    public var hlsTotalSeconds: Double = 0
    
    public let hlsCancelPointer: UnsafeMutablePointer<Int32>
    
    public var _managesOwnSpeed: Bool = false
    public var batchGroupID: UUID? = nil
    public var needsFuckingFastResolve: Bool = false
    public var totalActiveDuration: TimeInterval = 0
    
    var processes: [Process] = []
    var _lastBytes: Int64 = 0
    var _lastTickDate: Date? = nil

    public static func == (lhs: DownloadItem, rhs: DownloadItem) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    
    public var tempDirURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Dispatch/ActiveDownloads").appendingPathComponent(id.uuidString)
    }

    // In DownloadEngine.swift inside class DownloadItem
    public var progress: Double {
        if status == .completed { return 1.0 }
        
        // FIX: Use duration ratio for HLS/DASH progress
        if (isHLS || isDASH) && hlsTotalSeconds > 0 {
            return min(1.0, max(0.0, hlsDownloadedSeconds / hlsTotalSeconds))
        }
        
        guard totalBytes > 0 else { return 0 }
        let p = Double(downloadedBytes) / Double(totalBytes)
        return min(1.0, max(0.0, p))
    }

    // In DaisyDM/Sources/Daisy/Core/DownloadEngine.swift

    public var eta: TimeInterval? {
        if status == .completed { return nil }
        
        // Check for HLS/DASH duration-based ETA first
        if (isHLS || isDASH) && hlsTotalSeconds > 0 && speed > 0 {
            let remainingSeconds = max(0, hlsTotalSeconds - hlsDownloadedSeconds)
            // Note: For HLS, 'speed' is often reported as bytes/sec by the bridge,
            // so we must ensure we are using a consistent ratio or simply
            // relying on the bridge's segment-based progress if available.
            // If the bridge provides a stable speed, you can use:
            return remainingSeconds / (hlsDownloadedSeconds / totalActiveDuration)
        }

        // Standard byte-based ETA fallback
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
        if status == .completed { return "–" }
        guard speed > 0 else { return "–" }
        return formatBytes(Int64(speed)) + "/s"
    }
    
    // In DaisyDM/Sources/Daisy/Core/DownloadEngine.swift

    public var formattedETA: String? {
        if status == .completed { return nil }
        guard let eta, eta > 0, eta.isFinite else { return nil } // Added finite check for HLS calcs
        
        if eta < 60 { return "\(Int(eta))s" }
        if eta < 3600 { return "\(Int(eta/60))m \(Int(eta.truncatingRemainder(dividingBy:60)))s" }
        return "\(Int(eta/3600))h \(Int((eta.truncatingRemainder(dividingBy:3600))/60))m"
    }

    // In DownloadEngine.swift inside class DownloadItem
    public var transferLabel: String {
        if status == .completed {
            if (isHLS || isDASH) && hlsTotalSeconds > 0 {
                let totalTime = formatDuration(hlsTotalSeconds)
                return "\(totalTime) / \(totalTime)"
            }
            if totalBytes > 0 { return "\(formattedSize) of \(formattedSize)" }
            return formattedDownloaded
        }
        
        if (isHLS || isDASH) && hlsTotalSeconds > 0 {
            // FIX: Use hlsDownloadedSeconds directly instead of calculating via bytes
            let currentSecs = min(hlsTotalSeconds, hlsDownloadedSeconds)
            return "\(formatDuration(currentSecs)) / \(formatDuration(hlsTotalSeconds))"
        }
        
        if totalBytes > 0 { return "\(formattedDownloaded) of \(formattedSize)" }
        return downloadedBytes > 0 ? formattedDownloaded : "Zero KB"
    }

    public init(url: URL, filename: String, destination: URL) {
        self.id = UUID(); self.url = url; self.filename = filename
        self.destinationURL = destination.appendingPathComponent(filename)
        self.status = .queued
        
        self.hlsCancelPointer = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        self.hlsCancelPointer.initialize(to: 0)
        
        let isTorrentExtension = url.pathExtension.lowercased() == "torrent"
        let downloadTorrentsAsFiles = UserDefaults.standard.bool(forKey: "downloadTorrentsAsFiles")
        let computedType: DownloadType
        if url.scheme == "magnet" {
            computedType = .torrent
        } else if isTorrentExtension && url.isFileURL && !downloadTorrentsAsFiles {
            computedType = .torrent
        } else if isTorrentExtension && !url.isFileURL && !downloadTorrentsAsFiles {
            computedType = .torrent
        } else {
            computedType = .directLink
        }
        self.type = computedType; self.totalBytes = 0; self.downloadedBytes = 0; self.speed = 0; self.dateAdded = Date()
        self.connectionCount = 16; self.sourceHost = url.host ?? (computedType == .torrent ? "P2P Network" : "")
    }

    enum CodingKeys: String, CodingKey {
        case id, url, filename, destinationURL, status, type, totalBytes, downloadedBytes
        case error, dateAdded, dateCompleted, connectionCount, mimeType, sourceHost
        case isPrepared, supportsRanges, speedLimit, subFiles, batchURLs
        case cookies, userAgent, referer, retryCount, isHLS, isDASH
        case browser, totalActiveDuration
    }

    public required init(from decoder: Decoder) throws {
        self.hlsCancelPointer = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        self.hlsCancelPointer.initialize(to: 0)
        
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
        isHLS = try c.decodeIfPresent(Bool.self, forKey: .isHLS) ?? false
        isDASH = try c.decodeIfPresent(Bool.self, forKey: .isDASH) ?? false
        browser = try c.decodeIfPresent(String.self, forKey: .browser)
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
        try c.encode(retryCount, forKey: .retryCount); try c.encode(isHLS, forKey: .isHLS); try c.encode(isDASH, forKey: .isDASH)
        try c.encodeIfPresent(browser, forKey: .browser)
    }
    
    deinit {
        self.hlsCancelPointer.deinitialize(count: 1)
        self.hlsCancelPointer.deallocate()
    }
}

enum HLSBridge {
    typealias Closure = (Int32, Int32, Int64, Double, Double, Double) -> Void

    private static let lock = NSLock()
    private static var registry: [UUID: Closure] = [:]
    private static var currentID: UUID?

    static func register(id: UUID, closure: @escaping Closure) {
        lock.lock(); defer { lock.unlock() }
        registry[id] = closure
        currentID    = id
    }

    static func unregister(id: UUID) {
        lock.lock(); defer { lock.unlock() }
        registry.removeValue(forKey: id)
        if currentID == id { currentID = nil }
    }

    static func dispatch(done: Int32, total: Int32, bytes: Int64, speed: Double, dlSeconds: Double, totalSeconds: Double) {
        lock.lock()
        let closure = currentID.flatMap { registry[$0] }
        lock.unlock()
        closure?(done, total, bytes, speed, dlSeconds, totalSeconds)
    }
}

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

    nonisolated private func resolveHomebrewPath(for binary: String, isLibrary: Bool = false) -> String? {
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
    
    private var aria2Path: String? {
        return resolveHomebrewPath(for: "aria2c")
    }
    
    private var ytDlpPath: String? {
        return resolveHomebrewPath(for: "yt-dlp")
    }

    private var ffmpegPath: String? {
        return resolveHomebrewPath(for: "ffmpeg")
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

    public func addDownload(urls: [URL], destination: URL? = nil, connections: Int = 16, cookies: String? = nil, userAgent: String? = nil, referer: String? = nil, filename: String? = nil, youtubeQuality: String? = nil, isHLS: Bool = false, isDASH: Bool = false, browser: String? = nil, forceDirectDownload: Bool = false) {
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
            item.cookies = cookies
            item.userAgent = userAgent
            item.referer = referer
            item.browser = browser
            item.youtubeQuality = youtubeQuality
            
            if isFuckingFast {
                item.needsFuckingFastResolve = true
            }

            let urlStr = url.absoluteString.lowercased()
            let looksLikeHLS = !forceDirectDownload && (isHLS
                || url.pathExtension.lowercased() == "m3u8"
                || item.filename.lowercased().hasSuffix(".m3u8")
                || urlStr.contains(".m3u8")
                || urlStr.contains("m3u8"))

            let looksLikeDASH = !forceDirectDownload && (isDASH
                || url.pathExtension.lowercased() == "mpd"
                || item.filename.lowercased().hasSuffix(".mpd")
                || urlStr.contains(".mpd"))

            if looksLikeHLS {
                item.isHLS = true
                item.filename = item.filename
                    .replacingOccurrences(of: ".m3u8", with: "", options: .caseInsensitive)
                if !item.filename.lowercased().hasSuffix(".mp4") { item.filename += ".mp4" }
                item.destinationURL = item.destinationURL
                    .deletingLastPathComponent()
                    .appendingPathComponent(item.filename)
            } else if looksLikeDASH {
                item.isDASH = true
                item.filename = item.filename
                    .replacingOccurrences(of: ".mpd", with: "", options: .caseInsensitive)
                if !item.filename.lowercased().hasSuffix(".mp4") { item.filename += ".mp4" }
                item.destinationURL = item.destinationURL
                    .deletingLastPathComponent()
                    .appendingPathComponent(item.filename)
            }
            
            item.status = .queued
            items.insert(item, at: 0)
            persist()
            scheduleNext()
            
            NotificationCenter.default.post(name: .openProgressWindow, object: nil, userInfo: ["id": item.id])
        } else {
            var batchName = "Batch Download (\(urls.count) files)"
            
            if let firstURL = urls.first, firstURL.host?.contains("fuckingfast.co") == true, let fragment = firstURL.fragment {
                var cleanName = fragment.removingPercentEncoding ?? fragment
                if let regex = try? NSRegularExpression(pattern: #"\.part\d+\..+$"#, options: .caseInsensitive) {
                    let range = NSRange(cleanName.startIndex..<cleanName.endIndex, in: cleanName)
                    cleanName = regex.stringByReplacingMatches(in: cleanName, options: [], range: range, withTemplate: "")
                }
                while cleanName.hasSuffix("_") || cleanName.hasSuffix("-") || cleanName.hasSuffix(".") {
                    cleanName.removeLast()
                }
                if !cleanName.isEmpty {
                    batchName = cleanName
                }
            }
            
            let item = DownloadItem(url: urls.first!, filename: batchName, destination: dest)
            item.type = .batch
            item.connectionCount = connections
            item.cookies = cookies
            item.userAgent = userAgent
            item.referer = referer
            item.browser = browser
            
            item.batchURLs = urls.map { $0.absoluteString }
            
            var initialSubFiles: [SubFile] = []
            
            for (index, url) in urls.enumerated() {
                let isFuckingFast = url.host?.contains("fuckingfast.co") == true && !url.path.starts(with: "/dl/")
                
                let fn = isFuckingFast ? "Resolving…" : suggestFilename(from: url)
                initialSubFiles.append(SubFile(
                    id: UUID(),
                    index: index + 1,
                    path: fn,
                    filename: fn,
                    totalBytes: 0,
                    downloadedBytes: 0,
                    isStopped: false
                ))
            }
            
            item.subFiles = initialSubFiles
            item.status = .queued
            
            items.insert(item, at: 0)
            persist()
            scheduleNext()
            
            NotificationCenter.default.post(name: .openProgressWindow, object: nil, userInfo: ["id": item.id])
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

    public func stop(_ item: DownloadItem, stopSubFiles: Bool = true) {
        guard item.status == .downloading || item.status == .queued else { return }
        
        item.hlsCancelPointer.pointee = 1
        killProcesses(item)
        
        item.status = .stopped
        item.speed = 0
        item._lastTickDate = nil
        
        if stopSubFiles && (item.type == .torrent || item.type == .batch) {
            var updated = item.subFiles
            for i in updated.indices { updated[i].isStopped = true }
            item.subFiles = updated
        }
        
        persist()
        scheduleNext()
    }
    
    public func stopAll() {
        items.filter { $0.status == .downloading || $0.status == .queued }.forEach { stop($0, stopSubFiles: true) }
    }

    public func resume(_ item: DownloadItem, resumeSubFiles: Bool = true) {
        guard item.status == .stopped || item.status == .failed else { return }
        item.retryCount = 0
        
        if resumeSubFiles && (item.type == .torrent || item.type == .batch) {
            var updated = item.subFiles
            for i in updated.indices { updated[i].isStopped = false }
            item.subFiles = updated
        }
        
        if activeCount >= maxConcurrent {
            item.status = .queued
            persist()
            return
        }

        item.processes = []
        startDownload(item)
    }

    public func retry(_ item: DownloadItem) {
        killProcesses(item)
        item.retryCount = 0
        
        item.totalActiveDuration = 0
        item.dateAdded = Date()
        
        try? FileManager.default.removeItem(at: item.tempDirURL)
        if item.type != .torrent && item.type != .batch { try? FileManager.default.removeItem(at: item.destinationURL) }
        
        item.status = .queued; item.downloadedBytes = 0; item.totalBytes = 0; item.speed = 0
        item.error = nil; item.isPrepared = false; item.supportsRanges = false
        
        if item.type != .batch { item.subFiles = [] }
        else {
            var updated = item.subFiles
            for i in updated.indices {
                updated[i].downloadedBytes = 0
                updated[i].totalBytes = 0
                updated[i].isStopped = false
            }
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.resume(item, resumeSubFiles: false) }
        }
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
    
    private func fetchMetadata(url: URL, userAgent: String?, cookies: String?) async -> (size: Int64, filename: String?) {
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
               let totalStr = cr.components(separatedBy: "/").last,
               let len = Int64(totalStr) {
                size = len
            } else if let lenStr = httpResp.value(forHTTPHeaderField: "Content-Length"),
                      let len = Int64(lenStr) {
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
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            extract(from: response)
        } catch {}
        
        // Fallback to HEAD if GET bypass fails
        if size == 0 {
            request.httpMethod = "HEAD"
            request.setValue(nil, forHTTPHeaderField: "Range")
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                extract(from: response)
            } catch {}
        }
        
        return (size, filename)
    }

    private func startDownload(_ item: DownloadItem) {
        if item.url.scheme == "blob" {
            item.status = .failed
            item.error = "Blob URLs cannot be downloaded directly."
            persist(); scheduleNext(); return
        }

        // Pre-flight validation & File Size Extraction (Crucial for proper batch overall sizes)
        if item.needsFuckingFastResolve || (item.type == .batch && item.totalBytes == 0) {
            item.status = .downloading
            item.error = nil; persist()
            
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
                        if isFuckingFast {
                            targetURL = await resolveFuckingFast(url)
                        }
                        
                        if let dURL = targetURL {
                            resolvedURLs.append(dURL.absoluteString)
                            let meta = await fetchMetadata(url: dURL, userAgent: item.userAgent, cookies: item.cookies)
                            
                            await MainActor.run {
                                let newName = meta.filename ?? (isFuckingFast ? self.suggestFilename(from: dURL) : updatedSubFiles[i].filename)
                                updatedSubFiles[i].filename = newName
                                updatedSubFiles[i].path = newName
                                if meta.size > 0 { updatedSubFiles[i].totalBytes = meta.size }
                            }
                            totalBatchBytes += meta.size > 0 ? meta.size : 0
                        } else {
                            hasFailures = true
                            break
                        }
                    }
                    
                    await MainActor.run {
                        if hasFailures {
                            item.status = .failed
                            item.error = "Could not resolve one or more links in the batch."
                            self.persist(); self.scheduleNext()
                        } else {
                            item.batchURLs = resolvedURLs
                            item.subFiles = updatedSubFiles
                            item.needsFuckingFastResolve = false
                            if totalBatchBytes > 0 { item.totalBytes = totalBatchBytes }
                            self.continueStartDownload(item)
                        }
                    }
                } else {
                    if let directURL = await resolveFuckingFast(item.url) {
                        let meta = await fetchMetadata(url: directURL, userAgent: item.userAgent, cookies: item.cookies)
                        await MainActor.run {
                            item.url = directURL
                            item.filename = meta.filename ?? self.suggestFilename(from: directURL)
                            item.destinationURL = item.destinationURL.deletingLastPathComponent().appendingPathComponent(item.filename)
                            item.sourceHost = directURL.host ?? item.sourceHost
                            item.needsFuckingFastResolve = false
                            if meta.size > 0 { item.totalBytes = meta.size }
                            self.continueStartDownload(item)
                        }
                    } else {
                        await MainActor.run {
                            item.status = .failed
                            item.error = "Could not resolve fuckingfast.co link"
                            self.persist(); self.scheduleNext()
                        }
                    }
                }
            }
            return
        }

        if item.isHLS {
            item.status = .downloading
            item.error = nil
            item._lastTickDate = Date()
            persist()
            Task {
                await runNativeHLSEngine(item)
            }
            return
        }

        if item.isDASH {
            item.status = .downloading
            item.error = nil
            item._lastTickDate = Date()
            persist()
            Task {
                await runDashDownload(item)
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
    
    nonisolated private func parseISODuration(_ string: String) -> Double {
        var total: Double = 0
        var currentNumber = ""
        for char in string {
            if char.isNumber || char == "." {
                currentNumber.append(char)
            } else {
                if let val = Double(currentNumber) {
                    if char == "H" { total += val * 3600 }
                    else if char == "M" { total += val * 60 }
                    else if char == "S" { total += val }
                }
                currentNumber = ""
            }
        }
        return total
    }

    private func runDashDownload(_ item: DownloadItem) async {
        guard let exe = ytDlpPath else {
            await MainActor.run {
                item.status = .failed
                item.error = "Missing Engine. Ensure yt-dlp is installed via Homebrew to download DASH streams."
                persist(); scheduleNext()
            }
            return
        }

        await MainActor.run {
            item._managesOwnSpeed = true
            if !item.isPrepared {
                let policy = UserDefaults.standard.string(forKey: "fileCollisionBehavior") ?? "rename"
                var dest = item.destinationURL
                if dest.pathExtension.lowercased() != "mp4" {
                    dest = dest.deletingPathExtension().appendingPathExtension("mp4")
                }
                if policy == "replace" { try? FileManager.default.removeItem(at: dest) }
                else { dest = uniqueURL(dest) }
                item.destinationURL = dest
                item.filename = dest.lastPathComponent
                item.isPrepared = true
                persist()
            }
        }

        let url = await MainActor.run { item.url.absoluteString }
        let destPath = await MainActor.run { item.destinationURL.path }
        let referer = await MainActor.run { item.referer }
        let userAgent = await MainActor.run { item.userAgent }
        let cookies = await MainActor.run { item.cookies }
        let tempDir = await MainActor.run { item.tempDirURL }
        let selectedFormat = await MainActor.run { item.youtubeQuality ?? "bestvideo+bestaudio/best" }
        let safeFfmpegPath = self.ffmpegPath

        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let manifestTask = Task { () -> Double in
            guard let mpdURL = URL(string: url) else { return 0 }
            var request = URLRequest(url: mpdURL)
            if let ref = referer, !ref.isEmpty { request.setValue(ref, forHTTPHeaderField: "Referer") }
            if let ua = userAgent, !ua.isEmpty { request.setValue(ua, forHTTPHeaderField: "User-Agent") }
            if let cookies = cookies, !cookies.isEmpty {
                let cleanCookies = cookies.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
                request.setValue(cleanCookies, forHTTPHeaderField: "Cookie")
            }
            
            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                if let xml = String(data: data, encoding: .utf8) {
                    if let range = xml.range(of: "mediaPresentationDuration=\"PT"),
                       let endRange = xml[range.upperBound...].firstIndex(of: "\"") {
                        let durationStr = String(xml[range.upperBound..<endRange])
                        return self.parseISODuration(durationStr)
                    }
                }
            } catch {}
            return 0
        }
        
        let dur = await manifestTask.value
        await MainActor.run { item.hlsTotalSeconds = dur }

        await Task.detached(priority: .userInitiated) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: exe)
            
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            proc.environment = env

            var args = [
                "--newline",
                "--concurrent-fragments", "8",
                "-f", selectedFormat,
                "--abort-on-error",
                "--paths", "temp:\(tempDir.path)",
                "-o", destPath
            ]
            
            if let ffmpegExe = safeFfmpegPath {
                args.append(contentsOf: ["--ffmpeg-location", ffmpegExe])
            }
            
            if let ref = referer, !ref.isEmpty { args.append(contentsOf: ["--referer", ref]) }
            
            let uaToUse = (userAgent != nil && !userAgent!.isEmpty) ? userAgent! : "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
            args.append(contentsOf: ["--user-agent", uaToUse])
            args.append(contentsOf: [
                "--add-header", "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                "--add-header", "Accept-Language: en-US,en;q=0.9",
                "--add-header", "Sec-Fetch-Dest: document",
                "--add-header", "Sec-Fetch-Mode: navigate",
                "--add-header", "Sec-Fetch-Site: cross-site",
                "--add-header", "Upgrade-Insecure-Requests: 1"
            ])
            
            if let cookies = cookies, !cookies.isEmpty {
                if cookies.hasPrefix("# Netscape") {
                    let cookieFile = tempDir.appendingPathComponent("cookies.txt")
                    try? cookies.write(to: cookieFile, atomically: true, encoding: .utf8)
                    args.append(contentsOf: ["--cookies", cookieFile.path])
                } else {
                    let cleanCookies = cookies.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
                    args.append(contentsOf: ["--add-header", "Cookie: \(cleanCookies)"])
                }
            }
            
            args.append(url)
            proc.arguments = args

            let pipe = Pipe()
            let errorPipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = errorPipe
            
            await MainActor.run { item.processes.append(proc) }
            
            let parseTask = Task {
                var completedFilesSize: Int64 = 0
                var currentFileTotal: Int64 = 0
                var isMerging = false
                
                var trackCount = 1
                var seenDestinations = 0
                
                for try await line in pipe.fileHandleForReading.bytes.lines {
                    if line.contains("[Merger]") || line.contains("[ffmpeg]") {
                        isMerging = true
                    }
                    if line.contains("[download] Destination:") {
                        seenDestinations += 1
                        if seenDestinations > 1 {
                            trackCount = 2
                            if currentFileTotal > 0 {
                                completedFilesSize += currentFileTotal
                                currentFileTotal = 0
                            }
                        }
                        continue
                    }
                    
                    let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                    var percentStr = ""
                    var sizeStr = ""
                    var speedStr = ""
                    
                    for (i, part) in parts.enumerated() {
                        if part.hasSuffix("%") {
                            percentStr = String(part.dropLast())
                        }
                        if part == "of" && i + 1 < parts.count {
                            let next = parts[i+1]
                            if next == "~" && i + 2 < parts.count {
                                sizeStr = String(parts[i+2])
                            } else {
                                sizeStr = String(next)
                            }
                        }
                        if part == "at" && i + 1 < parts.count {
                            speedStr = String(parts[i+1])
                        }
                    }
                    
                    await MainActor.run {
                        if !sizeStr.isEmpty {
                            let parsedTotal = self.parseAriaSize(sizeStr)
                            if parsedTotal > currentFileTotal { currentFileTotal = parsedTotal }
                        }
                        
                        if !percentStr.isEmpty, let pct = Double(percentStr) {
                            if currentFileTotal > 0 {
                                let curDl = Int64(Double(currentFileTotal) * (pct / 100.0))
                                item.downloadedBytes = completedFilesSize + curDl
                                
                                // Smooth 85/15 scaling for total bytes estimation
                                var estimatedTotal: Double = 0
                                if trackCount <= 1 {
                                    estimatedTotal = Double(currentFileTotal) / 0.85
                                } else {
                                    estimatedTotal = Double(completedFilesSize + currentFileTotal)
                                }
                                item.totalBytes = Int64(estimatedTotal)
                            }
                            
                            // Smooth 85/15 scaling for duration tracking
                            if item.hlsTotalSeconds > 0 {
                                let videoRatio = 0.85
                                let audioRatio = 0.15
                                if trackCount <= 1 {
                                    item.hlsDownloadedSeconds = item.hlsTotalSeconds * (pct / 100.0) * videoRatio
                                } else {
                                    item.hlsDownloadedSeconds = item.hlsTotalSeconds * (videoRatio + (pct / 100.0) * audioRatio)
                                }
                            }
                        }
                        
                        if !speedStr.isEmpty {
                            let s = speedStr.replacingOccurrences(of: "/s", with: "")
                            let speed = self.parseAriaSize(s)
                            if speed > 0 { item.speed = Double(speed) }
                        }
                        
                        if isMerging {
                            item.downloadedBytes = item.totalBytes
                            if item.hlsTotalSeconds > 0 { item.hlsDownloadedSeconds = item.hlsTotalSeconds }
                            item.speed = 0
                        }
                        item._lastTickDate = Date()
                    }
                }
            }
            
            do {
                try proc.run()
                proc.waitUntilExit()
                parseTask.cancel()
                
                let isDownloading = await MainActor.run { item.status == .downloading }
                guard isDownloading else { return }
                
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorOutput = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                
                await MainActor.run {
                    if proc.terminationStatus == 0 {
                        item.status = .completed
                        item.dateCompleted = Date()
                        item.speed = 0
                        item.downloadedBytes = item.totalBytes
                        if item.hlsTotalSeconds > 0 { item.hlsDownloadedSeconds = item.hlsTotalSeconds }
                        self.notifyCompletion(for: item)
                    } else {
                        item.status = .failed
                        var finalError = "DASH download failed (yt-dlp exit code \(proc.terminationStatus))."
                        if !errorOutput.isEmpty {
                            if let errorLine = errorOutput.components(separatedBy: .newlines).first(where: { $0.contains("ERROR:") }) {
                                finalError = errorLine
                            } else {
                                finalError = errorOutput
                            }
                        }
                        item.error = finalError
                    }
                    try? FileManager.default.removeItem(at: tempDir)
                    self.persist(); self.scheduleNext()
                }
            } catch {
                let isDownloading = await MainActor.run { item.status == .downloading }
                if isDownloading {
                    await MainActor.run {
                        item.status = .failed
                        item.error = "DASH execution error: \(error.localizedDescription)"
                        self.persist(); self.scheduleNext()
                    }
                }
            }
        }.value
    }

    private func runNativeHLSEngine(_ item: DownloadItem) async {
        let urlStr  = item.url.absoluteString
        let outPath = item.destinationURL.path
        let itemID  = item.id
        
        let ffmpegExe = self.ffmpegPath ?? "ffmpeg"
        let tempDirPath = item.tempDirURL.path
        
        try? FileManager.default.createDirectory(at: item.tempDirURL, withIntermediateDirectories: true)

        // Setup the headers to pass to C++
        let ua = item.userAgent ?? ""
        let ref = item.referer ?? ""
        var cookieArg = ""
        
        if let cookies = item.cookies, !cookies.isEmpty {
            if cookies.hasPrefix("# Netscape") {
                let cookieFile = item.tempDirURL.appendingPathComponent("cookies_hls.txt")
                try? cookies.write(to: cookieFile, atomically: true, encoding: .utf8)
                cookieArg = "FILE:" + cookieFile.path
            } else {
                let cleanCookies = cookies.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
                cookieArg = cleanCookies
            }
        }

        await MainActor.run { item.hlsCancelPointer.pointee = 0 }

        HLSBridge.register(id: itemID) { done, total, bytes, speed, dlSecs, totSecs in
            Task { @MainActor in
                guard let liveItem = DownloadEngine.shared.items.first(where: { $0.id == itemID }) else { return }
                liveItem.downloadedBytes      = bytes
                liveItem.hlsSegmentsDone      = done
                liveItem.hlsSegmentsTotal     = total
                liveItem.hlsDownloadedSeconds = dlSecs
                liveItem.hlsTotalSeconds      = totSecs
                liveItem.speed                = speed
                liveItem._lastTickDate        = Date()
            }
        }
        
        let hlsLibPath = resolveHomebrewPath(for: "libhls_downloader.dylib", isLibrary: true)

        let result = await Task.detached(priority: .userInitiated) {
            var handle: UnsafeMutableRawPointer? = nil
            if let path = hlsLibPath {
                handle = dlopen(path, RTLD_NOW | RTLD_LOCAL)
            }
            if handle == nil {
                handle = dlopen("libhls_downloader.dylib", RTLD_NOW | RTLD_LOCAL)
            }
            
            guard let handle = handle else { return Int32(-99) }
            defer { dlclose(handle) }

            guard let sym = dlsym(handle, "download_hls") else { return Int32(-98) }

            // Updated C signature to include User-Agent, Referer, and Cookies
            typealias DownloadHLSFn = @convention(c) (
                UnsafePointer<CChar>, // url
                UnsafePointer<CChar>, // out_mp4
                UnsafePointer<CChar>, // ffmpeg path
                UnsafePointer<CChar>, // temp dir
                UnsafePointer<CChar>, // user_agent
                UnsafePointer<CChar>, // referer
                UnsafePointer<CChar>, // cookies
                @convention(c) (Int32, Int32, Int64, Double, Double, Double) -> Void,
                UnsafeMutablePointer<Int32>
            ) -> Int32

            let download_hls_fn = unsafeBitCast(sym, to: DownloadHLSFn.self)

            let callback: @convention(c) (Int32, Int32, Int64, Double, Double, Double) -> Void = { done, total, bytes, speed, dlSecs, totSecs in
                HLSBridge.dispatch(done: done, total: total, bytes: bytes, speed: speed, dlSeconds: dlSecs, totalSeconds: totSecs)
            }

            return urlStr.withCString { cURL in
                outPath.withCString { cOut in
                    ffmpegExe.withCString { cFFmpeg in
                        tempDirPath.withCString { cTempDir in
                            ua.withCString { cUa in
                                ref.withCString { cRef in
                                    cookieArg.withCString { cCookies in
                                        withExtendedLifetime(item) {
                                            download_hls_fn(cURL, cOut, cFFmpeg, cTempDir, cUa, cRef, cCookies, callback, item.hlsCancelPointer)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }.value

        HLSBridge.unregister(id: itemID)

        await MainActor.run {
            if result == 0 {
                item.status        = .completed
                item.dateCompleted = Date()
                item.speed         = 0
                if item.hlsTotalSeconds > 0 { item.hlsDownloadedSeconds = item.hlsTotalSeconds }
                self.notifyCompletion(for: item)
            } else if result == -2 {
                item.speed = 0 // Stopped cleanly
            } else if result == -5 {
                item.status = .failed
                item.error  = "Network Error 403: CDN blocked the request. Check your cookies or headers."
                item.speed  = 0
            } else {
                item.status = .failed
                item.error  = result == -99 ? "Could not load libhls_downloader.dylib — make sure it is installed via Homebrew."
                            : result == -98 ? "Symbol 'download_hls' not found in libhls_downloader.dylib."
                            :                 "Native HLS Engine error code: \(result)"
                item.speed  = 0
            }
            persist()
            scheduleNext()
        }
    }
    
    nonisolated private func parseYtDlpLine(_ line: String, for item: DownloadItem) {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        var percentStr = ""
        var sizeStr = ""
        var speedStr = ""
        
        for (i, part) in parts.enumerated() {
            if part.hasSuffix("%") {
                percentStr = String(part.dropLast())
            }
            if part == "of" && i + 1 < parts.count {
                let next = parts[i+1]
                if next == "~" && i + 2 < parts.count {
                    sizeStr = String(parts[i+2])
                } else {
                    sizeStr = String(next)
                }
            }
            if part == "at" && i + 1 < parts.count {
                speedStr = String(parts[i+1])
            }
        }
        
        Task { @MainActor in
            if !sizeStr.isEmpty {
                let total = parseAriaSize(sizeStr)
                if total > 0 { item.totalBytes = total }
            }
            if !percentStr.isEmpty, let pct = Double(percentStr) {
                if item.totalBytes > 0 {
                    item.downloadedBytes = Int64(Double(item.totalBytes) * (pct / 100.0))
                }
            }
            if !speedStr.isEmpty {
                let s = speedStr.replacingOccurrences(of: "/s", with: "")
                let speed = parseAriaSize(s)
                if speed > 0 { item.speed = Double(speed) }
            }
            item._lastTickDate = Date()
        }
    }

    private func runYoutubeDownload(_ item: DownloadItem) async {
        guard let exe = ytDlpPath else {
            await MainActor.run {
                item.status = .failed
                item.error = "Missing Engine. Ensure yt-dlp is installed via Homebrew."
                persist(); scheduleNext()
            }
            return
        }

        await MainActor.run {
            item._managesOwnSpeed = true
            if !item.isPrepared {
                let policy = UserDefaults.standard.string(forKey: "fileCollisionBehavior") ?? "rename"
                var dest = item.destinationURL
                if dest.pathExtension.lowercased() != "mp4" {
                    dest = dest.deletingPathExtension().appendingPathExtension("mp4")
                }
                if policy == "replace" { try? FileManager.default.removeItem(at: dest) }
                else { dest = uniqueURL(dest) }
                item.destinationURL = dest
                item.filename = dest.lastPathComponent
                item.isPrepared = true
                persist()
            }
        }

        let url = await MainActor.run { item.url.absoluteString }
        let formatID = await MainActor.run { item.youtubeQuality ?? "bestvideo+bestaudio/best" }
        let browser = await MainActor.run { item.browser ?? "chrome" }

        await Task.detached(priority: .userInitiated) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: exe)
            
            var env = ProcessInfo.processInfo.environment
            let customPaths = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            env["PATH"] = customPaths
            proc.environment = env

            proc.arguments = ["--get-url", "-f", formatID, "--cookies-from-browser", browser, url]

            let pipe = Pipe()
            proc.standardOutput = pipe
            
            await MainActor.run { item.processes.append(proc) }
            
            do {
                try proc.run()
                proc.waitUntilExit()
                
                let isDownloading = await MainActor.run { item.status == .downloading }
                guard isDownloading else { return }
                
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                let parts = output.components(separatedBy: .newlines).filter { !$0.isEmpty }

                if parts.count >= 2 {
                    await self.handleMultiPartYoutube(item, videoURL: parts[0], audioURL: parts[1])
                } else if parts.count == 1 {
                    await MainActor.run {
                        item.url = URL(string: parts[0])!
                        self.continueStartDownload(item)
                    }
                } else {
                    await MainActor.run {
                        item.status = .failed
                        item.error = "yt-dlp could not extract media URLs."
                        self.persist(); self.scheduleNext()
                    }
                }
            } catch {
                let isDownloading = await MainActor.run { item.status == .downloading }
                if isDownloading {
                    await MainActor.run {
                        item.status = .failed
                        item.error = "yt-dlp extract error: \(error.localizedDescription)"
                        self.persist(); self.scheduleNext()
                    }
                }
            }
        }.value
    }

    private func handleMultiPartYoutube(_ item: DownloadItem, videoURL: String, audioURL: String) async {
        let tempDir = item.tempDirURL
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let vFile = tempDir.appendingPathComponent("video.tmp").path
        let aFile = tempDir.appendingPathComponent("audio.tmp").path
        
        guard let aria = aria2Path else {
            await MainActor.run { item.status = .failed; item.error = "aria2c missing" }
            return
        }

        await MainActor.run {
            item.status = .downloading
            persist()
        }

        await Task.detached(priority: .userInitiated) {
            let commonArgs = ["-x16", "-s16", "-k1M", "--summary-interval=1", "--console-log-level=notice", "--file-allocation=none", "--continue=true", "--auto-file-renaming=false"]
            
            let vProc = Process()
            vProc.executableURL = URL(fileURLWithPath: aria)
            vProc.arguments = commonArgs + ["-o", "video.tmp", "--dir=\(tempDir.path)", videoURL]
            let vPipe = Pipe()
            vProc.standardOutput = vPipe
            
            let aProc = Process()
            aProc.executableURL = URL(fileURLWithPath: aria)
            aProc.arguments = commonArgs + ["-o", "audio.tmp", "--dir=\(tempDir.path)", audioURL]
            let aPipe = Pipe()
            aProc.standardOutput = aPipe
            
            await MainActor.run {
                item.processes.append(vProc)
                item.processes.append(aProc)
            }
            
            let vAttr = try? FileManager.default.attributesOfItem(atPath: vFile)
            var vBytes: Int64 = (vAttr?[.size] as? NSNumber)?.int64Value ?? 0
            
            let aAttr = try? FileManager.default.attributesOfItem(atPath: aFile)
            var aBytes: Int64 = (aAttr?[.size] as? NSNumber)?.int64Value ?? 0

            await MainActor.run {
                if vBytes + aBytes > 0 { item.downloadedBytes = vBytes + aBytes }
            }

            var vTotal: Int64 = 0
            var aTotal: Int64 = 0
            var vSpeed: Double = 0
            var aSpeed: Double = 0

            func sniff(_ line: String) -> (cur: Int64, tot: Int64, spd: Double)? {
                let sizePattern = #"(?<cur>[\d\.]+[A-Z]iB)/(?<tot>[\d\.]+[A-Z]iB)"#
                let speedPattern = #"DL:(?<spd>[\d\.]+[A-Z]iB)"#
                
                var c: Int64 = 0, t: Int64 = 0, s: Double = 0
                
                if let range = line.range(of: sizePattern, options: .regularExpression) {
                    let parts = line[range].split(separator: "/")
                    if parts.count == 2 {
                        c = self.parseAriaSize(String(parts[0]))
                        t = self.parseAriaSize(String(parts[1]))
                    }
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
                        vBytes = res.cur; vTotal = res.tot; vSpeed = res.spd
                        await MainActor.run {
                            item.downloadedBytes = vBytes + aBytes
                            item.speed = vSpeed + aSpeed
                            if vTotal > 0 && aTotal > 0 { item.totalBytes = vTotal + aTotal }
                            item._lastTickDate = Date()
                        }
                    }
                }
            }

            let aTask = Task {
                for try await line in aPipe.fileHandleForReading.bytes.lines {
                    if let res = sniff(line) {
                        aBytes = res.cur; aTotal = res.tot; aSpeed = res.spd
                        await MainActor.run {
                            item.downloadedBytes = vBytes + aBytes
                            item.speed = vSpeed + aSpeed
                            if vTotal > 0 && aTotal > 0 { item.totalBytes = vTotal + aTotal }
                            item._lastTickDate = Date()
                        }
                    }
                }
            }

            do {
                try vProc.run(); try aProc.run()
                vProc.waitUntilExit(); aProc.waitUntilExit()
                vTask.cancel(); aTask.cancel()
                
                let isDownloading = await MainActor.run { item.status == .downloading }
                let finalVSz = (try? FileManager.default.attributesOfItem(atPath: vFile)[.size] as? NSNumber)?.int64Value ?? 0
                let finalASz = (try? FileManager.default.attributesOfItem(atPath: aFile)[.size] as? NSNumber)?.int64Value ?? 0
                
                // Strictly block FFmpeg if not actively downloading, process failed, or files are empty
                if isDownloading && vProc.terminationStatus == 0 && aProc.terminationStatus == 0 && finalVSz > 0 && finalASz > 0 {
                    await self.mergeYoutubeParts(item, videoPath: vFile, audioPath: aFile)
                } else if isDownloading {
                    await MainActor.run { item.status = .failed; item.error = "Aria2 download failed or returned incomplete files." }
                }
            } catch {
                let isDownloading = await MainActor.run { item.status == .downloading }
                if isDownloading {
                    await MainActor.run { item.status = .failed; item.error = error.localizedDescription }
                }
            }
        }.value
    }

    private func mergeYoutubeParts(_ item: DownloadItem, videoPath: String, audioPath: String) async {
        guard let ffmpeg = ffmpegPath else {
            await MainActor.run { item.status = .failed; item.error = "FFmpeg missing" }
            return
        }
        
        let finalPath = await MainActor.run { item.destinationURL.path }
        
        await Task.detached(priority: .userInitiated) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: ffmpeg)
            proc.arguments = ["-i", videoPath, "-i", audioPath, "-c", "copy", "-map", "0:v:0", "-map", "1:a:0", "-y", finalPath]
            
            await MainActor.run { item.processes.append(proc) }
            
            do {
                try proc.run()
                proc.waitUntilExit()
                
                await MainActor.run {
                    let isDownloading = item.status == .downloading
                    if proc.terminationStatus == 0 {
                        item.status = .completed
                        item.dateCompleted = Date()
                        item.speed = 0
                        try? FileManager.default.removeItem(at: item.tempDirURL)
                    } else if isDownloading {
                        item.status = .failed
                        item.error = "FFmpeg merge failed"
                    }
                    self.persist(); self.scheduleNext()
                }
            } catch {
                await MainActor.run {
                    if item.status == .downloading {
                        item.status = .failed; item.error = error.localizedDescription
                    }
                }
            }
        }.value
    }

    private func continueStartDownload(_ item: DownloadItem) {
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
        } else {
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
        
        if let cookies = cookies, !cookies.isEmpty {
            if cookies.hasPrefix("# Netscape") {
                let cookieFile = tempDir.appendingPathComponent("cookies.txt")
                try? cookies.write(to: cookieFile, atomically: true, encoding: .utf8)
                args.append("--load-cookies=\(cookieFile.path)")
            } else {
                args.append("--header=Cookie: \(cookies)")
            }
        }
        
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
                "--bt-tracker=udp://tracker.opentrackr.org:1337/announce,udp://open.stealth.si:80/announce,udp://tracker.torrent.eu.org:451/announce,udp://tracker.dler.org:6969/announce,udp://exodus.desync.com:6969/announce,udp://retracker.lanta-net.ru:2710/announce,udp://tracker.moeking.me:6969/announce,udp://tracker.pomf.se:80/announce,udp://tracker.publicbt.com:80/announce,udp://tracker.tiny-vps.com:6969/announce,udp://tracker.files.fm:6969/announce"
            ]
        }
        
        if type == .batch {
            let listPath = tempDir.appendingPathComponent("batch_list.txt")
            let listContent = (await MainActor.run { item.batchURLs })?.joined(separator: "\n") ?? ""
            try? listContent.write(to: listPath, atomically: true, encoding: .utf8)
            args.append("-i"); args.append(listPath.path)
            args.append("-j1")
        } else if type == .torrent {
            let activeIndices = await MainActor.run { item.subFiles.filter { !$0.isStopped }.map { String($0.index) }.joined(separator: ",") }
            if !activeIndices.isEmpty { args.append("--select-file=\(activeIndices)") }
            else if !(await MainActor.run { item.subFiles.isEmpty }) { await MainActor.run { stop(item, stopSubFiles: false) }; return }
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
                        if let bytes = Int64(bytesStr), bytes > 0 {
                            await MainActor.run {
                                if item.type == .directLink && item.totalBytes == 0 { item.totalBytes = bytes }
                            }
                        }
                    }
                }
                
                if line.contains("[#") && line.contains("DL:") {
                    var totalDl: Int64 = 0; var totalSz: Int64 = 0; var totalSpeed: Double = 0; var foundMatch = false
                    
                    let blocks = line.components(separatedBy: "[#")
                    for block in blocks {
                        if let dlRange = block.range(of: "DL:") {
                            let sub = block[dlRange.upperBound...]
                            let speedStr = sub.prefix(while: { $0 != " " && $0 != "]" })
                            totalSpeed += Double(parseAriaSize(String(speedStr)))
                            foundMatch = true
                        }
                        if item.type == .directLink {
                            let parts = block.split(separator: " ")
                            if parts.count >= 2 {
                                let transferPart = parts[1]
                                let sizes = transferPart.components(separatedBy: "(")[0]
                                let sizeParts = sizes.components(separatedBy: "/")
                                totalDl += parseAriaSize(sizeParts[0])
                                if sizeParts.count > 1 { totalSz += parseAriaSize(sizeParts[1]) }
                            }
                        }
                    }
                    
                    if foundMatch {
                        await MainActor.run {
                            if item.type == .directLink {
                                if totalDl > 0 { item.downloadedBytes = totalDl }
                                if totalSz > item.totalBytes { item.totalBytes = totalSz }
                            }
                            item.speed = totalSpeed
                            item._lastTickDate = Date()
                        }
                    }
                }
            }
        }
        
        let pollTask = Task { [weak item] in
            guard let item else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                
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
                        var totalDownloaded: Int64 = 0
                        var totalActiveBytes: Int64 = 0
                        
                        for i in updatedSubFiles.indices {
                            let sub = updatedSubFiles[i]
                            let fileURL = tempDir.appendingPathComponent(sub.path)
                            
                            if let vals = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]) {
                                let physical = vals.totalFileAllocatedSize ?? 0
                                let logical = vals.fileSize ?? 0
                                let downloaded = Int64(min(physical, logical))
                                
                                if !sub.isStopped { updatedSubFiles[i].downloadedBytes = downloaded }
                            }
                            
                            totalDownloaded += updatedSubFiles[i].downloadedBytes
                            totalActiveBytes += updatedSubFiles[i].totalBytes
                        }
                        await MainActor.run {
                            item.subFiles = updatedSubFiles
                            item.downloadedBytes = totalDownloaded
                            if totalActiveBytes > 0 { item.totalBytes = totalActiveBytes }
                        }
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
                        var totalDownloaded: Int64 = 0
                        var totalActiveBytes: Int64 = 0
                        
                        for newSub in updatedSubFiles {
                            if let idx = merged.firstIndex(where: { $0.filename == newSub.filename || $0.path == newSub.path }) {
                                if !merged[idx].isStopped {
                                    merged[idx].downloadedBytes = max(merged[idx].downloadedBytes, newSub.downloadedBytes)
                                }
                                if newSub.totalBytes > merged[idx].totalBytes {
                                    merged[idx].totalBytes = newSub.totalBytes
                                }
                            } else {
                                merged.append(newSub)
                            }
                        }
                        for sub in merged {
                            totalDownloaded += sub.downloadedBytes
                            totalActiveBytes += sub.totalBytes
                        }
                        item.subFiles = merged
                        item.downloadedBytes = totalDownloaded
                        if totalActiveBytes > 0 { item.totalBytes = totalActiveBytes }
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
                
                // FINAL SAFETY CHECK: Read exact disk size for instantly downloaded tiny files
                if let attr = try? FileManager.default.attributesOfItem(atPath: destinationURL.path), let fileSize = attr[.size] as? NSNumber {
                    await MainActor.run {
                        item.downloadedBytes = fileSize.int64Value
                        if item.totalBytes == 0 || item.totalBytes < fileSize.int64Value {
                            item.totalBytes = fileSize.int64Value
                        }
                    }
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
                if item.type == .torrent && item.downloadedBytes < item.totalBytes && !item.subFiles.isEmpty {
                    item.status = .stopped
                } else {
                    // Force 100% completion stat display
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
        
        if let cookies = cookies, !cookies.isEmpty {
            if cookies.hasPrefix("# Netscape") {
                let cookieFile = tempDir.appendingPathComponent("cookies.txt")
                try? cookies.write(to: cookieFile, atomically: true, encoding: .utf8)
                args.append(contentsOf: ["--cookie", cookieFile.path])
            } else {
                args.append(contentsOf: ["--cookie", cookies])
            }
        }
        
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
                let maxRetries = UserDefaults.standard.object(forKey: "maxRetryCount") as? Int ?? 3
                if r < maxRetries && status != 401 && status != 403 && status != 404 {
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
                
                // FINAL SAFETY CHECK: Read exact disk size for instantly downloaded tiny files
                if let attr = try? FileManager.default.attributesOfItem(atPath: finalDest.path), let fileSize = attr[.size] as? NSNumber {
                    await MainActor.run {
                        item.downloadedBytes = fileSize.int64Value
                        if item.totalBytes == 0 || item.totalBytes < fileSize.int64Value {
                            item.totalBytes = fileSize.int64Value
                        }
                    }
                }
                
                await MainActor.run {
                    if let line = stdoutText.components(separatedBy: "\n").last(where: { !$0.isEmpty }) {
                        let parts = line.split(separator: " ")
                        if parts.count >= 2, let sz = Int64(parts[1]), sz > 0 {
                            if sz > item.downloadedBytes {
                                item.downloadedBytes = sz
                            }
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
                item.filename = fn
                item.destinationURL = finalDest
                
                if fn.lowercased().hasSuffix(".torrent") {
                    let downloadAsFile = UserDefaults.standard.bool(forKey: "downloadTorrentsAsFiles")
                    if downloadAsFile {
                        item.totalBytes = Int64(data.count)
                        item.downloadedBytes = Int64(data.count)
                        item.status = .completed
                        item.dateCompleted = Date()
                        item.speed = 0
                        self.notifyCompletion(for: item)
                        persist()
                        scheduleNext()
                    } else {
                        item.url = finalDest
                        item.type = .torrent
                        item.status = .queued
                        item.downloadedBytes = 0
                        item.totalBytes = 0
                        item.speed = 0
                        persist()
                        scheduleNext()
                    }
                } else {
                    item.totalBytes = Int64(data.count)
                    item.downloadedBytes = Int64(data.count)
                    item.status = .completed
                    item.dateCompleted = Date()
                    item.speed = 0
                    self.notifyCompletion(for: item)
                    persist()
                    scheduleNext()
                }
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
        for proc in item.processes {
            if proc.isRunning {
                proc.interrupt()
                
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                    if proc.isRunning {
                        proc.terminate()
                    }
                }
            }
        }
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

func formatDuration(_ seconds: Double) -> String {
    guard seconds > 0 else { return "00:00" }
    let totalSeconds = Int(seconds.rounded())
    let hours = totalSeconds / 3600
    let minutes = (totalSeconds % 3600) / 60
    let secs = totalSeconds % 60
    
    if hours > 0 {
        return String(format: "%02d:%02d:%02d", hours, minutes, secs)
    } else {
        return String(format: "%02d:%02d", minutes, secs)
    }
}
