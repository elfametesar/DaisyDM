import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ConfirmDownloadRequest: Identifiable {
    let id = UUID()
    let url:      URL
    var filename: String
    let cookies:  String
    let referer:  String
    let ua:       String
    var forceHLS: Bool = false
    var youtubeQuality: String? = nil
}

struct YouTubeFormatOption: Hashable {
    let label: String
    let query: String
    let estimatedSize: Int64
}

struct ConfirmDownloadView: View {
    let request: ConfirmDownloadRequest
    let onConfirm: (ConfirmDownloadRequest, URL, Int) -> Void
    let onCancel:  () -> Void

    @State private var filename:    String
    @State private var destination: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
    @State private var connections: Int = 16
    @State private var showDetails  = false
    
    @State private var isResolving  = false
    @State private var resolvedSize: Int64 = 0
    @State private var isDetectedHLS: Bool = false
    @State private var youtubeQuality: String
    
    @State private var availableYouTubeQualities: [YouTubeFormatOption] = []
    @State private var isFetchingQualities = false

    private let engine = DownloadEngine.shared

    @AppStorage("accentColorHex") private var accentColorHex = "#0A84FF"
    @State private var window: NSWindow?

    var isYouTube: Bool {
        request.url.host?.contains("youtube.com") == true || request.url.host?.contains("youtu.be") == true
    }
    
    var showQualityPicker: Bool {
        isYouTube && (request.youtubeQuality == nil || request.youtubeQuality!.isEmpty)
    }

    init(request: ConfirmDownloadRequest,
         onConfirm: @escaping (ConfirmDownloadRequest, URL, Int) -> Void,
         onCancel:  @escaping () -> Void) {
        self.request   = request
        self.onConfirm = onConfirm
        self.onCancel  = onCancel
        _filename      = State(initialValue: request.filename.isEmpty ? suggestName(request.url) : request.filename)
        _isDetectedHLS = State(initialValue: request.forceHLS)
        _youtubeQuality = State(initialValue: request.youtubeQuality ?? "")
    }

    private var fileIcon: NSImage {
        let ext  = (filename as NSString).pathExtension
        let type = UTType(filenameExtension: ext) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }

    private var fileExt: String {
        let ext = (filename as NSString).pathExtension.uppercased()
        return ext.isEmpty ? "FILE" : ext
    }
    
    private var safeLabelTitle: String {
        let trimmed = filename.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "download" : trimmed
    }

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Header
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: fileIcon)
                    .resizable()
                    .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 3) {
                    Text(safeLabelTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(.primary)
                    
                    HStack(spacing: 6) {
                        Text(fileExt)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color(hex: accentColorHex).accessibleText)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color(hex: accentColorHex), in: Capsule())
                        
                        Text(request.url.host ?? request.url.absoluteString)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            
                        Text("•").foregroundStyle(.secondary)
                        
                        if isResolving {
                            ProgressView().controlSize(.small).scaleEffect(0.6)
                        } else {
                            Text(resolvedSize > 0 ? "Size: \(formatBytes(resolvedSize))" : "Size: Unknown")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)

            Divider()

            // MARK: - Form Body
            VStack(alignment: .leading, spacing: 16) {
                
                // 1. File Name
                VStack(alignment: .leading, spacing: 4) {
                    Text("File Name")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.primary)
                    TextField("filename", text: $filename)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                }
                
                // 2. Source URL
                VStack(alignment: .leading, spacing: 4) {
                    Text("Source URL")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.primary)
                    HStack {
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(request.url.absoluteString)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .textSelection(.enabled)
                        }
                        .frame(height: 16)
                        Spacer(minLength: 0)
                    }
                    .padding(6)
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(NSColor.separatorColor).opacity(0.5), lineWidth: 1))
                }

                // 3. YouTube Quality (Dynamic + Fallback)
                if showQualityPicker {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text("Video Quality")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.primary)
                            
                            if isFetchingQualities {
                                ProgressView().controlSize(.small).scaleEffect(0.6)
                                Text("Fetching available qualities...")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                            
                        if !isFetchingQualities {
                            if !availableYouTubeQualities.isEmpty {
                                Picker("", selection: $youtubeQuality) {
                                    ForEach(availableYouTubeQualities, id: \.query) { option in
                                        Text(option.label).tag(option.query)
                                    }
                                }
                                .labelsHidden()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .onChange(of: youtubeQuality) { _, newQuery in
                                    if let match = availableYouTubeQualities.first(where: { $0.query == newQuery }) {
                                        self.resolvedSize = match.estimatedSize
                                    }
                                }
                            } else {
                                VStack(alignment: .leading, spacing: 4) {
                                    Picker("", selection: $youtubeQuality) {
                                        Text("Best (Video + Audio)").tag("")
                                        Text("4K (MP4)").tag("bestvideo[height<=2160][ext=mp4]+bestaudio/best")
                                        Text("4K (WebM)").tag("bestvideo[height<=2160][ext=webm]+bestaudio/best")
                                        Text("1440p (MP4)").tag("bestvideo[height<=1440][ext=mp4]+bestaudio/best")
                                        Text("1440p (WebM)").tag("bestvideo[height<=1440][ext=webm]+bestaudio/best")
                                        Text("1080p (MP4)").tag("bestvideo[height<=1080][ext=mp4]+bestaudio/best")
                                        Text("1080p (WebM)").tag("bestvideo[height<=1080][ext=webm]+bestaudio/best")
                                        Text("720p (MP4)").tag("bestvideo[height<=720][ext=mp4]+bestaudio/best")
                                        Text("720p (WebM)").tag("bestvideo[height<=720][ext=webm]+bestaudio/best")
                                        Text("480p (MP4)").tag("bestvideo[height<=480][ext=mp4]+bestaudio/best")
                                        Text("480p (WebM)").tag("bestvideo[height<=480][ext=webm]+bestaudio/best")
                                        Text("Audio Only (M4A)").tag("bestaudio[ext=m4a]/bestaudio/best")
                                        Text("Audio Only (WebM)").tag("bestaudio[ext=webm]/bestaudio/best")
                                    }
                                    .labelsHidden()
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    
                                    HStack {
                                        Image(systemName: "exclamationmark.triangle")
                                            .foregroundStyle(.orange)
                                            .font(.system(size: 10))
                                        Text("Could not auto-detect formats. Showing manual list.")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.top, 2)
                                }
                            }
                        }
                    }
                }

                // 4. Save To
                VStack(alignment: .leading, spacing: 4) {
                    Text("Save To")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.primary)
                    HStack {
                        ScrollView(.vertical, showsIndicators: false) {
                            Text(destination.path(percentEncoded: false))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 16)
                        
                        Button("Choose…") {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles       = false
                            panel.canChooseDirectories = true
                            panel.prompt               = "Select"
                            if panel.runModal() == .OK, let u = panel.url { destination = u }
                        }
                        .font(.system(size: 11))
                        .buttonStyle(ActionButtonStyle(prominent: false, hex: accentColorHex))
                    }
                    .padding(6)
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(NSColor.separatorColor).opacity(0.5), lineWidth: 1))
                }

                // 5. Connections
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Connections")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.primary)
                        Spacer()
                        Text("\(connections)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.primary)
                            .monospacedDigit()
                    }
                    HStack(spacing: 8) {
                        Text("1").font(.system(size: 10)).foregroundStyle(.primary)
                        Slider(value: Binding(get: { Double(connections) },
                                              set: { connections = Int($0) }),
                               in: 1...32, step: 1)
                        .tint(Color(hex: accentColorHex))
                        Text("32").font(.system(size: 10)).foregroundStyle(.primary)
                    }
                }

                // 6. Advanced Details
                VStack(alignment: .leading, spacing: 4) {
                    Button(action: {
                        withAnimation(nil) {
                            showDetails.toggle()
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: showDetails ? "chevron.down" : "chevron.right")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 12)
                            Text("Advanced Details")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)

                    if showDetails {
                        VStack(alignment: .leading, spacing: 10) {
                            if !request.referer.isEmpty {
                                ScrollableDetailRow(label: "Referer", value: request.referer, labelWidth: 70)
                            }
                            if !request.cookies.isEmpty {
                                ScrollableDetailRow(label: "Cookies", value: request.cookies, labelWidth: 70)
                            }
                            if !request.ua.isEmpty {
                                ScrollableDetailRow(label: "User-Agent", value: request.ua, labelWidth: 70)
                            }
                            if request.referer.isEmpty && request.cookies.isEmpty && request.ua.isEmpty {
                                Text("No advanced headers provided.")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, 8)
                        .padding(.bottom, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)

            Spacer(minLength: 16)
            Divider()

            // MARK: - Footer Actions
            HStack(spacing: 10) {
                Button(action: onCancel) {
                    Label("Cancel", systemImage: "xmark")
                }
                .keyboardShortcut(.escape)
                .buttonStyle(ActionButtonStyle(prominent: false, hex: accentColorHex))

                Spacer()

                Button(action: {
                    var r = request
                    r.filename = filename.trimmingCharacters(in: .whitespacesAndNewlines)
                    if r.filename.isEmpty { r.filename = suggestName(request.url) }
                    r.forceHLS = isDetectedHLS
                    
                    if showQualityPicker && !youtubeQuality.isEmpty {
                        r.youtubeQuality = youtubeQuality
                    }
                    
                    onConfirm(r, destination, connections)
                }) {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                .keyboardShortcut(.return)
                .buttonStyle(ActionButtonStyle(prominent: true, hex: accentColorHex))
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .animation(nil, value: showDetails)
        .task { await performBackgroundSniff() }
        .background(VisualEffectView(material: .popover, blendingMode: .behindWindow).ignoresSafeArea())
        .background(WindowAccessor(window: $window))
        .onChange(of: window) { _, newWindow in
            if let win = newWindow {
                win.isOpaque = false
                win.backgroundColor = .clear
                win.animationBehavior = .none
            }
        }
    }
    
    // MARK: - Helpers
    
    private func getInstalledYTDlpPath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let executablePaths = [
            "/opt/homebrew/bin/yt-dlp",
            "/usr/local/bin/yt-dlp",
            "\(home)/.local/bin/yt-dlp",
            "/usr/bin/yt-dlp",
            "/bin/yt-dlp"
        ]
        return executablePaths.first(where: { FileManager.default.fileExists(atPath: $0) })
    }
    
    private func fetchYouTubeTitle(url: URL) async -> String? {
        guard let ytDlpPath = getInstalledYTDlpPath() else { return nil }
        
        let browsersToTry: [String?] = [nil, "safari", "chrome", "brave", "firefox", "edge", "opera"]
        
        for browser in browsersToTry {
            if let title = await runYTDlpTitleFetch(url: url, ytDlpPath: ytDlpPath, browser: browser) {
                return title
            }
        }
        return nil
    }
    
    private func runYTDlpTitleFetch(url: URL, ytDlpPath: String, browser: String?) async -> String? {
        return await Task.detached(priority: .userInitiated) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: ytDlpPath)
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:\(FileManager.default.homeDirectoryForCurrentUser.path)/.local/bin"
            proc.environment = env
            
            var args = ["--print", "title", "--no-warnings", "--no-playlist"]
            if let b = browser {
                args.append(contentsOf: ["--cookies-from-browser", b])
            }
            args.append(url.absoluteString)
            proc.arguments = args
            
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice
            
            do {
                try proc.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                
                if proc.terminationStatus == 0, let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty {
                    let safeTitle = output.replacingOccurrences(of: "/", with: "_")
                    return safeTitle + ".mp4"
                }
            } catch {}
            return nil
        }.value
    }
    
    private func fetchYouTubeFormats(url: URL) async -> [YouTubeFormatOption] {
        guard let ytDlpPath = getInstalledYTDlpPath() else { return [] }
        
        let browsersToTry: [String?] = [nil, "safari", "chrome", "brave", "firefox", "edge", "opera"]
        
        for browser in browsersToTry {
            let formats = await runYTDlpFormatFetch(url: url, ytDlpPath: ytDlpPath, browser: browser)
            if !formats.isEmpty {
                return formats
            }
        }
        return []
    }
    
    private func runYTDlpFormatFetch(url: URL, ytDlpPath: String, browser: String?) async -> [YouTubeFormatOption] {
        return await Task.detached(priority: .userInitiated) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: ytDlpPath)
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:\(FileManager.default.homeDirectoryForCurrentUser.path)/.local/bin"
            proc.environment = env
            
            var args = ["-j", "--no-warnings", "--no-playlist"]
            if let b = browser {
                args.append(contentsOf: ["--cookies-from-browser", b])
            }
            args.append(url.absoluteString)
            proc.arguments = args
            
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice
            
            do {
                try proc.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                
                if proc.terminationStatus == 0,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let formats = json["formats"] as? [[String: Any]] {
                    
                    var options: [YouTubeFormatOption] = []
                    
                    let audios = formats.filter {
                        let vcodec = $0["vcodec"] as? String ?? "none"
                        let acodec = $0["acodec"] as? String ?? "none"
                        return vcodec == "none" && acodec != "none"
                    }
                    let bestAudioSize = audios.compactMap { $0["filesize"] as? Int64 ?? $0["filesize_approx"] as? Int64 }.max() ?? 0
                    
                    let videos = formats.filter {
                        let vcodec = $0["vcodec"] as? String ?? "none"
                        let height = $0["height"] as? Int ?? 0
                        return vcodec != "none" && height > 0
                    }.sorted {
                        let h1 = $0["height"] as? Int ?? 0
                        let h2 = $1["height"] as? Int ?? 0
                        return h1 > h2
                    }
                    
                    var seen = Set<String>()
                    
                    for v in videos {
                        let h = v["height"] as? Int ?? 0
                        let ext = v["ext"] as? String ?? ""
                        let fps = v["fps"] as? Int ?? 0
                        if h == 0 || ext.isEmpty { continue }
                        
                        let vSize = v["filesize"] as? Int64 ?? v["filesize_approx"] as? Int64 ?? 0
                        let estimatedTotal = (vSize > 0) ? (vSize + bestAudioSize) : 0
                        
                        let fpsString = (fps > 30) ? "\(fps)" : ""
                        let key = "\(h)\(fpsString)-\(ext)"
                        
                        if !seen.contains(key) {
                            seen.insert(key)
                            let label = "\(h)p\(fpsString) (\(ext.uppercased()))"
                            let query = "bestvideo[height<=\(h)][ext=\(ext)]+bestaudio/best"
                            options.append(YouTubeFormatOption(label: label, query: query, estimatedSize: estimatedTotal))
                        }
                    }
                    
                    let defaultBestSize = options.first?.estimatedSize ?? 0
                    options.insert(YouTubeFormatOption(label: "Best Quality (Default)", query: "", estimatedSize: defaultBestSize), at: 0)
                    
                    if options.count > 1 {
                        options.append(YouTubeFormatOption(label: "Audio Only (M4A)", query: "bestaudio[ext=m4a]/bestaudio/best", estimatedSize: bestAudioSize))
                        options.append(YouTubeFormatOption(label: "Audio Only (WebM)", query: "bestaudio[ext=webm]/bestaudio/best", estimatedSize: bestAudioSize))
                        return options
                    }
                }
            } catch {}
            return []
        }.value
    }
    
    private func performBackgroundSniff() async {
        guard request.url.scheme?.starts(with: "http") == true else { return }
        
        isResolving = true
        defer { isResolving = false }
        
        if isYouTube {
            await MainActor.run { isFetchingQualities = true }
            
            async let titleTask = fetchYouTubeTitle(url: request.url)
            async let formatsTask = fetchYouTubeFormats(url: request.url)
            
            let title = await titleTask
            let formats = await formatsTask
            
            await MainActor.run {
                if let t = title {
                    self.filename = t
                } else if self.filename.isEmpty || self.filename == "download" {
                    self.filename = "YouTube_Video.mp4"
                }
                
                if !formats.isEmpty {
                    self.availableYouTubeQualities = formats
                    if self.youtubeQuality.isEmpty || !formats.contains(where: { $0.query == self.youtubeQuality }) {
                        self.youtubeQuality = formats.first?.query ?? ""
                    }
                    if let match = formats.first(where: { $0.query == self.youtubeQuality }) {
                        self.resolvedSize = match.estimatedSize
                    }
                }
                
                self.isFetchingQualities = false
            }
            return
        }
        
        let isHLSUrl = request.forceHLS
            || request.url.absoluteString.lowercased().contains("m3u8")
            || request.filename.lowercased().contains(".m3u8")
        
        var req = URLRequest(url: request.url)
        req.httpMethod = "GET"
        req.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8", forHTTPHeaderField: "Accept")
        req.setValue("document", forHTTPHeaderField: "Sec-Fetch-Dest")
        req.setValue("navigate", forHTTPHeaderField: "Sec-Fetch-Mode")
        req.setValue("none", forHTTPHeaderField: "Sec-Fetch-Site")
        
        if !request.cookies.isEmpty { req.setValue(request.cookies, forHTTPHeaderField: "Cookie") }
        if !request.ua.isEmpty { req.setValue(request.ua, forHTTPHeaderField: "User-Agent") }
        if !request.referer.isEmpty { req.setValue(request.referer, forHTTPHeaderField: "Referer") }
        
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: req)
            bytes.task.cancel()
            
            if let httpResp = response as? HTTPURLResponse {
                let ct = (httpResp.value(forHTTPHeaderField: "Content-Type") ?? httpResp.value(forHTTPHeaderField: "content-type"))?.lowercased() ?? ""
                let isHLS = isHLSUrl || ct.contains("mpegurl") || ct.contains("m3u8") || ct.contains("apple.mpegurl")
                
                await MainActor.run {
                    var foundName: String? = nil
                    
                    if let disposition = httpResp.value(forHTTPHeaderField: "Content-Disposition") ?? httpResp.value(forHTTPHeaderField: "content-disposition") {
                        if let range = disposition.range(of: "filename=", options: .caseInsensitive) {
                            var fn = String(disposition[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                            if fn.hasPrefix("\"") {
                                fn = String(fn.dropFirst())
                                if let endQuote = fn.firstIndex(of: "\"") { fn = String(fn[..<endQuote]) }
                            } else {
                                if let endSemi = fn.firstIndex(of: ";") { fn = String(fn[..<endSemi]) }
                            }
                            if !fn.isEmpty { foundName = fn }
                        }
                    }
                    
                    if foundName == nil {
                        let finalURL = httpResp.url ?? request.url
                        let lastComponent = finalURL.lastPathComponent.removingPercentEncoding ?? finalURL.lastPathComponent
                        if lastComponent.contains(".") && lastComponent != "/" {
                            foundName = lastComponent
                        }
                    }
                    
                    if let fn = foundName, fn != "download", fn != "file" {
                        self.filename = fn
                    }
                    
                    if isHLS {
                        self.isDetectedHLS = true
                        if self.filename.lowercased().hasSuffix(".m3u8") {
                            self.filename = String(self.filename.dropLast(5)) + ".mp4"
                        } else if !self.filename.lowercased().hasSuffix(".mp4") {
                            self.filename += ".mp4"
                        }
                        self.resolvedSize = 0
                    } else {
                        let expected = httpResp.expectedContentLength
                        if expected > 0 {
                            self.resolvedSize = expected
                        } else if let clStr = httpResp.value(forHTTPHeaderField: "Content-Length") ?? httpResp.value(forHTTPHeaderField: "content-length"), let cl = Int64(clStr), cl > 0 {
                            self.resolvedSize = cl
                        }
                    }
                }
            }
        } catch { }
    }
}

private func suggestName(_ url: URL) -> String {
    let last = url.lastPathComponent
    let dec = last.removingPercentEncoding ?? last
    return (!dec.isEmpty && dec != "/") ? dec : "download"
}
