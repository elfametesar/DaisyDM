import Foundation
import CryptoKit

// MARK: - Types

// MARK: - Public API

struct HLSDownloadConfig {
    var url: URL
    var outputURL: URL
    var ffmpegURL: URL
    var tempDir: URL
    var userAgent: String?
    var referer: String?
    var cookies: String?
    var concurrency: Int = 24
    var onProgress: HLSProgressCallback?

    init(url: URL, outputURL: URL, ffmpegURL: URL, tempDir: URL) {
        self.url = url
        self.outputURL = outputURL
        self.ffmpegURL = ffmpegURL
        self.tempDir = tempDir
    }
}

typealias HLSProgressCallback = (
    _ completed: Int,
    _ total: Int,
    _ bytesDownloaded: Int64,
    _ speed: Double,          // bytes/sec
    _ videoTimeDownloaded: Double,
    _ totalVideoDuration: Double
) -> Void

enum HLSError: Error {
    case invalidURL
    case manifestFetchFailed
    case noSegmentsFound
    case segmentDownloadFailed
    case ffmpegFailed(Int32)
    case cancelled
}

private struct SegmentInfo {
    let url: URL
    let duration: Double
    let encrypted: Bool
    let key: Data
    let iv: Data
}

// MARK: - HLSDownloader

actor HLSDownloader {

    private var isCancelled = false

    nonisolated private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 32
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }()

    init() {}

    func cancel() {
        isCancelled = true
    }

    // MARK: - Public Entry Point

    func download(_ config: HLSDownloadConfig) async throws {
        isCancelled = false

        let ua = config.userAgent
        let ref = config.referer
        let ck = config.cookies

        // 1. Fetch manifest
        let manifest = try await fetchString(url: config.url, userAgent: ua, referer: ref, cookies: ck)

        // 2. Parse segments
        let (segments, totalDuration) = try await parseManifest(manifest, baseURL: config.url, userAgent: ua, referer: ref, cookies: ck)

        guard !segments.isEmpty else { throw HLSError.noSegmentsFound }

        // 3. Download segments concurrently
        let segmentPaths = try await downloadSegments(
            segments: segments,
            tempDir: config.tempDir,
            userAgent: ua,
            referer: ref,
            cookies: ck,
            concurrency: config.concurrency,
            totalDuration: totalDuration,
            progress: config.onProgress
        )

        // 4. Write concat list
        let listURL = config.tempDir.appendingPathComponent("list.txt")
        let listContent = segmentPaths.map { ffmpegListEscape($0.path) }.joined(separator: "\n")
        try listContent.write(to: listURL, atomically: true, encoding: .utf8)

        // 5. Run FFmpeg
        try await runFFmpeg(ffmpegURL: config.ffmpegURL, listURL: listURL, outputURL: config.outputURL)
    }

    // MARK: - Manifest Parsing

    private func parseManifest(
        _ manifest: String,
        baseURL: URL,
        userAgent: String?,
        referer: String?,
        cookies: String?
    ) async throws -> ([SegmentInfo], Double) {

        let baseString = baseURL.absoluteString
        let basePath = String(baseString.prefix(upTo: baseString.range(of: "/", options: .backwards)!.upperBound))

        var segments: [SegmentInfo] = []
        var totalDuration = 0.0
        var currentDuration = 0.0

        var isEncrypted = false
        var currentKey = Data()
        var currentIVString = ""
        var mediaSequence: UInt64 = 0
        var currentSegmentIndex: UInt64 = 0

        let lines = manifest.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            if trimmed.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                let val = trimmed.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)
                mediaSequence = UInt64(val) ?? 0
                currentSegmentIndex = mediaSequence

            } else if trimmed.hasPrefix("#EXT-X-KEY:") {
                if trimmed.contains("METHOD=NONE") {
                    isEncrypted = false
                } else if trimmed.contains("METHOD=AES-128") {
                    isEncrypted = true

                    // Parse URI
                    if let uriRange = trimmed.range(of: "URI=\"") {
                        let afterURI = trimmed[uriRange.upperBound...]
                        if let endQuote = afterURI.firstIndex(of: "\"") {
                            var keyURLString = String(afterURI[..<endQuote])
                            if !keyURLString.hasPrefix("http") { keyURLString = basePath + keyURLString }
                            if let keyURL = URL(string: keyURLString) {
                                currentKey = (try? await fetchData(url: keyURL, userAgent: userAgent, referer: referer, cookies: cookies)) ?? Data()
                            }
                        }
                    }

                    // Parse IV
                    if let ivRange = trimmed.range(of: "IV=0x") {
                        let afterIV = trimmed[ivRange.upperBound...]
                        let end = afterIV.firstIndex(of: ",") ?? afterIV.endIndex
                        currentIVString = String(afterIV[..<end])
                    } else {
                        currentIVString = ""
                    }
                }

            } else if trimmed.hasPrefix("#EXTINF:") {
                let val = trimmed.dropFirst("#EXTINF:".count)
                let durationStr = val.prefix(while: { $0 != "," })
                currentDuration = Double(durationStr) ?? 0.0

            } else if !trimmed.hasPrefix("#") {
                let segURLString = trimmed.hasPrefix("http") ? trimmed : basePath + trimmed
                guard let segURL = URL(string: segURLString) else { continue }

                let iv: Data
                if isEncrypted {
                    iv = currentIVString.isEmpty ? seqToIV(currentSegmentIndex) : hexToBytes(currentIVString)
                } else {
                    iv = Data()
                }

                segments.append(SegmentInfo(
                    url: segURL,
                    duration: currentDuration,
                    encrypted: isEncrypted,
                    key: currentKey,
                    iv: iv
                ))
                totalDuration += currentDuration
                currentSegmentIndex += 1
            }
        }

        return (segments, totalDuration)
    }

    // MARK: - Concurrent Segment Download

    private func downloadSegments(
        segments: [SegmentInfo],
        tempDir: URL,
        userAgent: String?,
        referer: String?,
        cookies: String?,
        concurrency: Int,
        totalDuration: Double,
        progress: HLSProgressCallback?
    ) async throws -> [URL] {

        let total = segments.count
        let globalBytes = LockAtomic<Int64>(0)
        let completedCount = LockAtomic<Int>(0)
        let videoTime = LockAtomic<Double>(0.0)
        let startTime = Date()

        // Pre-allocate result slots
        var paths = Array(repeating: URL(fileURLWithPath: ""), count: total)

        // Progress reporter task
        let progressTask = Task {
            while !Task.isCancelled {
                let elapsed = Date().timeIntervalSince(startTime)
                let bytes = globalBytes.value
                let speed = elapsed > 0 ? Double(bytes) / elapsed : 0
                progress?(completedCount.value, total, bytes, speed, videoTime.value, totalDuration)
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        defer { progressTask.cancel() }

        // Download with concurrency limit (24 workers, all enqueued immediately)
        try await withThrowingTaskGroup(of: (Int, URL).self) { group in
            let semaphore = AsyncSemaphore(limit: concurrency)

            for (idx, segment) in segments.enumerated() {
                // Enqueue all tasks immediately; semaphore throttles inside the task
                group.addTask {
                    await semaphore.wait()
                    defer { Task { await semaphore.signal() } }

                    guard await !self.isCancelled else { throw HLSError.cancelled }

                    var data = try await self.fetchData(
                        url: segment.url,
                        userAgent: userAgent,
                        referer: referer,
                        cookies: cookies
                    )

                    globalBytes.add(Int64(data.count))

                    if segment.encrypted && segment.key.count == 16 {
                        data = (try? self.decryptAES128(data, key: segment.key, iv: segment.iv)) ?? data
                    }

                    let segPath = tempDir.appendingPathComponent("seg_\(idx).tmp")
                    // Offload blocking write to utility thread
                    try await Task.detached(priority: .utility) {
                        try data.write(to: segPath, options: .atomic)
                    }.value

                    videoTime.add(segment.duration)
                    completedCount.increment()

                    return (idx, segPath)
                }
            }

            // Collect results sequentially on actor executor — no lock needed
            for try await (idx, path) in group {
                paths[idx] = path
            }
        }

        if isCancelled { throw HLSError.cancelled }
        return paths
    }

    // MARK: - AES-128 Decryption

    nonisolated private func decryptAES128(_ ciphertext: Data, key: Data, iv: Data) throws -> Data {
        let symKey = SymmetricKey(data: key)
        let sealedBox = try AES.CBC.SealedBox(combined: iv + ciphertext, ivLength: 16)
        return try AES.CBC.open(sealedBox, using: symKey)
    }

    // MARK: - FFmpeg

    private func runFFmpeg(ffmpegURL: URL, listURL: URL, outputURL: URL) async throws {
        let process = Process()
        process.executableURL = ffmpegURL
        process.arguments = [
            "-protocol_whitelist", "file,crypto,data",
            "-f", "concat",
            "-safe", "0",
            "-i", listURL.path,
            "-c", "copy",
            "-movflags", "+faststart",
            "-y", outputURL.path
        ]

        return try await withCheckedThrowingContinuation { cont in
            process.terminationHandler = { p in
                if p.terminationStatus == 0 {
                    cont.resume()
                } else {
                    cont.resume(throwing: HLSError.ffmpegFailed(p.terminationStatus))
                }
            }
            do {
                try process.run()
            } catch {
                cont.resume(throwing: error)
            }
        }
    }

    // MARK: - Networking

    nonisolated private func fetchString(url: URL, userAgent: String?, referer: String?, cookies: String?) async throws -> String {
        let data = try await fetchData(url: url, userAgent: userAgent, referer: referer, cookies: cookies)
        return String(data: data, encoding: .utf8) ?? ""
    }

    nonisolated private func fetchData(url: URL, userAgent: String?, referer: String?, cookies: String?) async throws -> Data {
        var request = URLRequest(url: url)
        if let ua = userAgent, !ua.isEmpty { request.setValue(ua, forHTTPHeaderField: "User-Agent") }
        if let ref = referer, !ref.isEmpty { request.setValue(ref, forHTTPHeaderField: "Referer") }
        if let c = cookies, !c.isEmpty { request.setValue(c, forHTTPHeaderField: "Cookie") }

        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode != 403 else {
            throw HLSError.segmentDownloadFailed
        }
        return data
    }

    // MARK: - Helpers

    private func hexToBytes(_ hex: String) -> Data {
        var h = hex
        if h.count % 2 != 0 { h = "0" + h }
        var bytes = [UInt8]()
        var idx = h.startIndex
        while idx < h.endIndex {
            let next = h.index(idx, offsetBy: 2)
            bytes.append(UInt8(h[idx..<next], radix: 16) ?? 0)
            idx = next
        }
        // Pad to 16 bytes (left-pad with zeros)
        var padded = [UInt8](repeating: 0, count: 16)
        let start = 16 - min(bytes.count, 16)
        for (i, b) in bytes.suffix(16).enumerated() { padded[start + i] = b }
        return Data(padded)
    }

    private func seqToIV(_ seq: UInt64) -> Data {
        var iv = [UInt8](repeating: 0, count: 16)
        var s = seq
        for i in stride(from: 15, through: 8, by: -1) {
            iv[i] = UInt8(s & 0xFF)
            s >>= 8
        }
        return Data(iv)
    }

    private func ffmpegListEscape(_ path: String) -> String {
        let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
        return "file '\(escaped)'"
    }
}

// MARK: - AES CBC (CryptoKit doesn't expose CBC publicly, use CommonCrypto)

import CommonCrypto

private extension AES {
    enum CBC {
        struct SealedBox {
            let iv: Data
            let ciphertext: Data
            init(combined: Data, ivLength: Int) throws {
                iv = combined.prefix(ivLength)
                ciphertext = combined.dropFirst(ivLength)
            }
        }
        static func open(_ box: SealedBox, using key: SymmetricKey) throws -> Data {
            let keyBytes = key.withUnsafeBytes { Array($0) }
            let outLen = box.ciphertext.count + kCCBlockSizeAES128
            var out = [UInt8](repeating: 0, count: outLen)
            var moved = 0

            let status = box.iv.withUnsafeBytes { ivPtr in
                box.ciphertext.withUnsafeBytes { ctPtr in
                    keyBytes.withUnsafeBytes { keyPtr in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress, keyBytes.count,
                            ivPtr.baseAddress,
                            ctPtr.baseAddress, box.ciphertext.count,
                            &out, outLen, &moved
                        )
                    }
                }
            }
            guard status == kCCSuccess else { throw HLSError.segmentDownloadFailed }
            return Data(out.prefix(moved))
        }
    }
}

// MARK: - Concurrency Utilities

private final class LockAtomic<T: Numeric> {
    private var _value: T
    private let lock = NSLock()
    init(_ value: T) { _value = value }
    var value: T { lock.withLock { _value } }
    func add(_ v: T) { lock.withLock { _value += v } }
    func increment() { lock.withLock { _value += 1 } }
}

private actor AsyncSemaphore {
    private var count: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(limit: Int) { count = limit }
    func wait() async {
        if count > 0 { count -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func signal() {
        if waiters.isEmpty { count += 1 }
        else { waiters.removeFirst().resume() }
    }
}
