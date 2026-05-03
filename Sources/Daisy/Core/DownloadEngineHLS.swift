import Foundation
import AppKit

extension DownloadEngine {

    func runNativeHLSEngine(_ item: DownloadItem) async {
        let itemID = item.id

        try? FileManager.default.createDirectory(at: item.tempDirURL, withIntermediateDirectories: true)

        let fileName    = await MainActor.run { item.filename }
        let tempOutURL  = item.tempDirURL.appendingPathComponent(fileName)
        let ffmpegURL   = URL(fileURLWithPath: self.ffmpegPath ?? "ffmpeg")

        // Build cookie arg
        var cookieArg: String? = nil
        if let cookies = item.cookies, !cookies.isEmpty {
            if cookies.hasPrefix("# Netscape") {
                let cookieFile = item.tempDirURL.appendingPathComponent("cookies_hls.txt")
                try? cookies.write(to: cookieFile, atomically: true, encoding: .utf8)
                cookieArg = "FILE:" + cookieFile.path
            } else {
                cookieArg = cookies
                    .replacingOccurrences(of: "\n", with: "")
                    .replacingOccurrences(of: "\r", with: "")
            }
        }

        // Setup .dysy bundle proxy for UI
        await MainActor.run {
            let bundleURL = item.destinationURL.appendingPathExtension("dysy")
            try? FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
            if let bundleIcon = NSImage(named: "BundleIcon") ?? NSImage(named: NSImage.applicationIconName) {
                NSWorkspace.shared.setIcon(bundleIcon, forFile: bundleURL.path, options: [])
            }
        }

        // Dummy size task so Finder shows download progress
        let dummySizeTask = Task { [weak item] in
            guard let item else { return }
            let bundleURL   = await MainActor.run { item.destinationURL.appendingPathExtension("dysy") }
            let dummyFileURL = await MainActor.run { bundleURL.appendingPathComponent(item.filename) }

            while !Task.isCancelled {
                if !FileManager.default.fileExists(atPath: dummyFileURL.path) {
                    try? FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
                    FileManager.default.createFile(atPath: dummyFileURL.path, contents: nil)
                }
                if let fh = try? FileHandle(forWritingTo: dummyFileURL) {
                    let currentSize = await MainActor.run { item.downloadedBytes }
                    let actualSize  = (try? fh.seekToEnd()) ?? 0
                    if currentSize > 0 && currentSize != actualSize {
                        try? fh.truncate(atOffset: UInt64(currentSize))
                        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: bundleURL.path)
                    }
                    try? fh.close()
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }

        // Build config
        var config = HLSDownloadConfig(
            url:       item.url,
            outputURL: tempOutURL,
            ffmpegURL: ffmpegURL,
            tempDir:   item.tempDirURL
        )
        config.userAgent = item.userAgent
        config.referer   = item.referer
        config.cookies   = cookieArg
        config.onProgress = { done, total, bytes, speed, dlSecs, totSecs in
            Task { @MainActor in
                guard let liveItem = DownloadEngine.shared.items.first(where: { $0.id == itemID }) else { return }
                liveItem.downloadedBytes      = bytes
                if done > 0 && total > 0 {
                    liveItem.totalBytes = Int64(Double(bytes) / Double(done) * Double(total))
                }
                liveItem.hlsSegmentsDone      = Int32(done)
                liveItem.hlsSegmentsTotal     = Int32(total)
                liveItem.hlsDownloadedSeconds = dlSecs
                liveItem.hlsTotalSeconds      = totSecs
                liveItem.speed                = speed
                liveItem._lastTickDate        = Date()
            }
        }

        // Reset cancel flag before starting
        await MainActor.run { item.hlsCancelPointer.pointee = 0 }

        let downloader = HLSDownloader()

        let cancelObserver = Task { [weak item] in
            guard let item else { return }
            while !Task.isCancelled {
                let shouldCancel = await MainActor.run { item.hlsCancelPointer.pointee != 0 }
                if shouldCancel { await downloader.cancel(); return }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        var result: Result<Void, Error> = .success(())
        do {
            try await downloader.download(config)
        } catch {
            result = .failure(error)
        }

        cancelObserver.cancel()
        dummySizeTask.cancel()

        await MainActor.run {
            switch result {
            case .success:
                let bundleURL = item.destinationURL.appendingPathExtension("dysy")
                _ = try? FileManager.default.removeItem(at: item.destinationURL)
                try? FileManager.default.moveItem(at: tempOutURL, to: item.destinationURL)
                try? FileManager.default.removeItem(at: bundleURL)

                item.status = .completed
                item.dateCompleted = Date()
                item.speed = 0
                if item.hlsTotalSeconds > 0 { item.hlsDownloadedSeconds = item.hlsTotalSeconds }
                self.notifyCompletion(for: item)

            case .failure(let error):
                item.speed = 0
                switch error {
                case HLSError.cancelled:
                    item.speed = 0  // stay in stopped state, no status change
                case HLSError.segmentDownloadFailed:
                    item.status = .failed
                    item.error  = "Network Error: CDN blocked the request. Check your cookies or headers."
                case HLSError.ffmpegFailed(let code):
                    item.status = .failed
                    item.error  = "FFmpeg failed with exit code \(code)."
                case HLSError.noSegmentsFound:
                    item.status = .failed
                    item.error  = "No segments found in HLS manifest."
                default:
                    item.status = .failed
                    item.error  = error.localizedDescription
                }
            }
            persist()
            scheduleNext()
        }
    }
}
