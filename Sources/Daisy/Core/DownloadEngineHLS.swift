import Foundation
import AppKit

extension DownloadEngine {
    
    func runNativeHLSEngine(_ item: DownloadItem) async {
        let urlStr  = item.url.absoluteString
        let itemID  = item.id
        let ffmpegExe = self.ffmpegPath ?? "ffmpeg"
        let tempDirPath = item.tempDirURL.path
        
        try? FileManager.default.createDirectory(at: item.tempDirURL, withIntermediateDirectories: true)
        
        let fileName = await MainActor.run { item.filename }
        let tempOutPath = item.tempDirURL.appendingPathComponent(fileName).path

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

        // Setup the macOS .dysy bundle proxy for the UI
        await MainActor.run {
            let bundleURL = item.destinationURL.appendingPathExtension("dysy")
            try? FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
            if let folderIcon = NSImage(named: "FolderIcon") ?? NSImage(named: NSImage.applicationIconName) {
                NSWorkspace.shared.setIcon(folderIcon, forFile: bundleURL.path, options: [])
            }
        }

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

        HLSBridge.register(id: itemID) { done, total, bytes, speed, dlSecs, totSecs in
            Task { @MainActor in
                guard let liveItem = DownloadEngine.shared.items.first(where: { $0.id == itemID }) else { return }
                liveItem.downloadedBytes      = bytes
                if done > 0 && total > 0 { liveItem.totalBytes = Int64(Double(bytes) / Double(done) * Double(total)) }
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
            if let path = hlsLibPath { handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) }
            if handle == nil { handle = dlopen("libhls_downloader.dylib", RTLD_NOW | RTLD_LOCAL) }
            
            guard let handle = handle else { return Int32(-99) }
            defer { dlclose(handle) }

            guard let sym = dlsym(handle, "download_hls") else { return Int32(-98) }

            typealias DownloadHLSFn = @convention(c) (
                UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafePointer<CChar>,
                UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafePointer<CChar>,
                @convention(c) (Int32, Int32, Int64, Double, Double, Double) -> Void, UnsafeMutablePointer<Int32>
            ) -> Int32

            let download_hls_fn = unsafeBitCast(sym, to: DownloadHLSFn.self)

            let callback: @convention(c) (Int32, Int32, Int64, Double, Double, Double) -> Void = { done, total, bytes, speed, dlSecs, totSecs in
                HLSBridge.dispatch(done: done, total: total, bytes: bytes, speed: speed, dlSeconds: dlSecs, totalSeconds: totSecs)
            }

            return urlStr.withCString { cURL in
                tempOutPath.withCString { cOut in
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

        dummySizeTask.cancel()
        HLSBridge.unregister(id: itemID)

        await MainActor.run {
            if result == 0 {
                let bundleURL = item.destinationURL.appendingPathExtension("dysy")
                _ = try? FileManager.default.removeItem(at: item.destinationURL)
                try? FileManager.default.moveItem(atPath: tempOutPath, toPath: item.destinationURL.path)
                try? FileManager.default.removeItem(at: bundleURL)

                item.status = .completed; item.dateCompleted = Date(); item.speed = 0
                if item.hlsTotalSeconds > 0 { item.hlsDownloadedSeconds = item.hlsTotalSeconds }
                self.notifyCompletion(for: item)
            } else if result == -2 {
                item.speed = 0
            } else if result == -5 {
                item.status = .failed; item.error = "Network Error 403: CDN blocked the request. Check your cookies or headers."; item.speed = 0
            } else {
                item.status = .failed
                item.error  = result == -99 ? "Could not load libhls_downloader.dylib — make sure it is installed via Homebrew."
                            : result == -98 ? "Symbol 'download_hls' not found in libhls_downloader.dylib."
                            :                 "Native HLS Engine error code: \(result)"
                item.speed  = 0
            }
            persist(); scheduleNext()
        }
    }
}
