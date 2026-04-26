import Foundation
import Observation

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
    
    public var headers: [String: String]?
    public var cookies: String?
    public var userAgent: String?
    public var referer: String?
    /// YouTube proof-of-origin token captured by the browser extension
    /// from the in-page player request. Forwarded to InnerTube so the
    /// server-side download call doesn't trip the bot gate.
    public var ytPoToken: String?
    public var ytPoTokenVisitor: String?

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
        return support.appendingPathComponent("Daisy/ActiveDownloads").appendingPathComponent(id.uuidString)
    }

    public var progress: Double {
        if status == .completed { return 1.0 }
        
        if (isHLS || isDASH) && hlsTotalSeconds > 0 {
            return min(1.0, max(0.0, hlsDownloadedSeconds / hlsTotalSeconds))
        }
        
        guard totalBytes > 0 else { return 0 }
        let p = Double(downloadedBytes) / Double(totalBytes)
        return min(1.0, max(0.0, p))
    }

    public var eta: TimeInterval? {
        if status == .completed { return nil }
        
        if (isHLS || isDASH) && hlsTotalSeconds > 0 && speed > 0 && totalActiveDuration > 0 {
            let remainingSeconds = max(0, hlsTotalSeconds - hlsDownloadedSeconds)
            let rate = hlsDownloadedSeconds / totalActiveDuration
            guard rate > 0 else { return nil }
            return remainingSeconds / rate
        }

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
        if status == .completed { return "0B/s" }
        guard speed > 0 else { return "0B/s" }
        return formatBytes(Int64(speed)) + "/s"
    }
    
    public var formattedETA: String? {
        if status == .completed { return nil }
        guard let eta, eta > 0, eta.isFinite else { return nil }
        
        if eta < 60 { return "\(Int(eta))s" }
        if eta < 3600 { return "\(Int(eta/60))m \(Int(eta.truncatingRemainder(dividingBy:60)))s" }
        return "\(Int(eta/3600))h \(Int((eta.truncatingRemainder(dividingBy:3600))/60))m"
    }

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
        case headers, cookies, userAgent, referer, retryCount, isHLS, isDASH
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
        batchURLs = try c.decodeIfPresent([String].self, forKey: .batchURLs)
        headers = try c.decodeIfPresent([String: String].self, forKey: .headers)
        cookies = try c.decodeIfPresent(String.self, forKey: .cookies)
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
        try c.encodeIfPresent(batchURLs, forKey: .batchURLs); try c.encodeIfPresent(headers, forKey: .headers)
        try c.encodeIfPresent(cookies, forKey: .cookies)
        try c.encodeIfPresent(userAgent, forKey: .userAgent); try c.encodeIfPresent(referer, forKey: .referer)
        try c.encode(retryCount, forKey: .retryCount); try c.encode(isHLS, forKey: .isHLS); try c.encode(isDASH, forKey: .isDASH)
        try c.encodeIfPresent(browser, forKey: .browser)
    }
    
    deinit {
        self.hlsCancelPointer.deinitialize(count: 1)
        self.hlsCancelPointer.deallocate()
    }
}
