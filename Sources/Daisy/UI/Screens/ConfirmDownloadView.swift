import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ConfirmDownloadRequest: Identifiable {
    let id = UUID()
    let url:      URL
    var filename: String
    var headers:  [String: String]? = [:]
    let cookies:  String
    let referer:  String
    let ua:       String
    var forceHLS: Bool = false
    var forceDASH: Bool = false
    var forceDirectDownload: Bool = false
    var youtubeQuality: String? = nil
    /// Proof-of-origin token captured by the browser extension from the
    /// real YouTube player request. When present, the InnerTube call
    /// looks like a normal in-page player request rather than an
    /// anonymous server-side scrape, which clears the bot gate.
    var ytPoToken: String? = nil
    var ytPoTokenVisitor: String? = nil
    /// IDM-style: when the popup picked a YouTube quality the browser had
    /// already requested (and we captured), these carry the resolved URL
    /// pair so the download engine can skip the InnerTube extractor.
    var ytVideoUrl: String? = nil
    var ytAudioUrl: String? = nil
    var ytVideoMime: String? = nil
    var ytAudioMime: String? = nil
    var ytHeight: Int? = nil
    var ytTitle: String? = nil
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
    @State private var isDetectedDASH: Bool = false
    @State private var forceDirectDownload: Bool
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
        
        // --- FIXED MAGNET & TORRENT NAME INITIALIZATION ---
        var initialName = request.filename
        let isMagnet = request.url.scheme?.lowercased() == "magnet"
        let isTorrentFile = request.url.pathExtension.lowercased() == "torrent"

        // For magnets: always derive the name from the URL's dn= param — ignore whatever the extension passed
        if isMagnet {
            initialName = suggestName(request.url)
        } else if isTorrentFile {
            // For .torrent files, fall back to suggestName only if the filename is empty or generic
            if initialName.isEmpty || initialName == "download" {
                initialName = suggestName(request.url)
            }
            // Strip any incorrectly appended .mp4
            if initialName.lowercased().hasSuffix(".mp4") {
                initialName = String(initialName.dropLast(4))
            }
        } else if initialName.isEmpty || initialName == "download" || initialName.hasPrefix("?xt=urn:btih") {
            initialName = suggestName(request.url)
        }
        
        _filename      = State(initialValue: initialName)
        _isDetectedHLS = State(initialValue: request.forceHLS)
        _isDetectedDASH = State(initialValue: request.forceDASH)
        _forceDirectDownload = State(initialValue: request.forceDirectDownload)
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
                    
                    if isDetectedHLS || isDetectedDASH || request.url.absoluteString.lowercased().contains(".m3u8") || request.url.absoluteString.lowercased().contains(".mpd") {
                        Toggle("Download as raw file instead of media stream", isOn: $forceDirectDownload)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                            .onChange(of: forceDirectDownload) { _, isRaw in
                                if isRaw {
                                    if filename.hasSuffix(".mp4") {
                                        let ext = isDetectedDASH || request.url.absoluteString.lowercased().contains(".mpd") ? ".mpd" : ".m3u8"
                                        filename = String(filename.dropLast(4)) + ext
                                    }
                                } else {
                                    if filename.hasSuffix(".m3u8") {
                                        filename = String(filename.dropLast(5)) + ".mp4"
                                    } else if filename.hasSuffix(".mpd") {
                                        filename = String(filename.dropLast(4)) + ".mp4"
                                    }
                                }
                            }
                    }
                }

                // 3. YouTube Quality
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
                                        Text("1080p (MP4)").tag("bestvideo[height<=1080][ext=mp4]+bestaudio/best")
                                        Text("720p (MP4)").tag("bestvideo[height<=720][ext=mp4]+bestaudio/best")
                                        Text("Audio Only (M4A)").tag("bestaudio[ext=m4a]/bestaudio/best")
                                    }
                                    .labelsHidden()
                                    .frame(maxWidth: .infinity, alignment: .leading)
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
                            Text("Advanced Details (Headers & Cookies)")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)

                    if showDetails {
                        ScrollView(.vertical, showsIndicators: true) {
                            VStack(alignment: .leading, spacing: 10) {
                                if let headers = request.headers, !headers.isEmpty {
                                    ForEach(headers.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                                        CappedDetailRow(label: key.capitalized, value: value, labelWidth: 100)
                                    }
                                }
                                if !request.cookies.isEmpty {
                                    CappedDetailRow(label: "Cookies", value: request.cookies, labelWidth: 100)
                                }
                                if !request.referer.isEmpty && request.headers?["referer"] == nil {
                                    CappedDetailRow(label: "Referer", value: request.referer, labelWidth: 100)
                                }
                                if !request.ua.isEmpty && request.headers?["user-agent"] == nil {
                                    CappedDetailRow(label: "User-Agent", value: request.ua, labelWidth: 100)
                                }
                                if (request.headers?.isEmpty ?? true) && request.referer.isEmpty && request.cookies.isEmpty && request.ua.isEmpty {
                                    Text("No advanced headers provided.")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.top, 8)
                            .padding(.bottom, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 180)
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
                    r.forceDASH = isDetectedDASH
                    r.forceDirectDownload = forceDirectDownload
                    
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
                NSApplication.shared.activate(ignoringOtherApps: true)
                if win.isMiniaturized { win.deminiaturize(nil) }
                win.makeKeyAndOrderFront(nil)
            }
        }
    }
    
    // MARK: - Helpers
    
    private func performBackgroundSniff() async {
        // --- FIXED: BLOCK SNIFFER FOR MAGNETS AND TORRENTS ---
        if request.url.scheme?.lowercased() == "magnet" ||
           request.url.pathExtension.lowercased() == "torrent" ||
           filename.lowercased().hasSuffix(".torrent") {
            return
        }

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
                if let t = title { self.filename = t }
                else if self.filename.isEmpty || self.filename == "download" { self.filename = "YouTube_Video.mp4" }
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
        
        let isHLSUrl = request.forceHLS || request.url.absoluteString.lowercased().contains(".m3u8") || request.filename.lowercased().contains(".m3u8")
        let isDASHUrl = request.forceDASH || request.url.absoluteString.lowercased().contains(".mpd") || request.filename.lowercased().contains(".mpd")
        
        var req = URLRequest(url: request.url)
        req.httpMethod = "GET"
        req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        
        if !request.ua.isEmpty { req.setValue(request.ua, forHTTPHeaderField: "User-Agent") }
        if !request.referer.isEmpty { req.setValue(request.referer, forHTTPHeaderField: "Referer") }
        if !request.cookies.isEmpty { req.setValue(request.cookies, forHTTPHeaderField: "Cookie") }
        
        if let hdrs = request.headers {
            for (k, v) in hdrs {
                let lower = k.lowercased()
                if lower != "host" && lower != "accept-encoding" && lower != "range" {
                    req.setValue(v, forHTTPHeaderField: k)
                }
            }
        }
        
        do {
            let (asyncBytes, response) = try await URLSession.shared.bytes(for: req)
            asyncBytes.task.cancel()
            
            if let httpResp = response as? HTTPURLResponse {
                let ct = (httpResp.value(forHTTPHeaderField: "Content-Type") ?? httpResp.value(forHTTPHeaderField: "content-type"))?.lowercased() ?? ""
                
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
                    
                    if let fn = foundName, fn != "download", fn != "file" { self.filename = fn }
                    
                    let isHLS = isHLSUrl || ct.contains("mpegurl") || ct.contains("m3u8") || ct.contains("apple.mpegurl")
                    let isDASH = isDASHUrl || ct.contains("dash+xml")
                    
                    if isHLS {
                        self.isDetectedHLS = true
                        if !self.forceDirectDownload {
                            if self.filename.lowercased().hasSuffix(".m3u8") {
                                self.filename = String(self.filename.dropLast(5)) + ".mp4"
                            } else if !self.filename.lowercased().hasSuffix(".mp4") {
                                self.filename += ".mp4"
                            }
                        }
                        self.resolvedSize = 0
                    } else if isDASH {
                        self.isDetectedDASH = true
                        if !self.forceDirectDownload {
                            if self.filename.lowercased().hasSuffix(".mpd") {
                                self.filename = String(self.filename.dropLast(4)) + ".mp4"
                            } else if !self.filename.lowercased().hasSuffix(".mp4") {
                                self.filename += ".mp4"
                            }
                        }
                        self.resolvedSize = 0
                    } else {
                        if let contentRange = httpResp.value(forHTTPHeaderField: "Content-Range") ?? httpResp.value(forHTTPHeaderField: "content-range") {
                            if let totalStr = contentRange.components(separatedBy: "/").last, let total = Int64(totalStr.trimmingCharacters(in: .whitespaces)) {
                                self.resolvedSize = total
                            }
                        } else {
                            let expected = httpResp.expectedContentLength
                            if expected > 0 { self.resolvedSize = expected }
                            else if let clStr = httpResp.value(forHTTPHeaderField: "Content-Length") ?? httpResp.value(forHTTPHeaderField: "content-length"), let cl = Int64(clStr), cl > 0 {
                                self.resolvedSize = cl
                            }
                        }
                    }
                }
            }
        } catch { }
    }

    /// Lazily extracts video metadata once per `ConfirmDownloadView` show so the
    /// title and format list share a single InnerTube round-trip.
    private static let infoCache = NSCache<NSString, CachedYouTubeInfo>()

    private func cachedYouTubeInfo(for url: URL) async -> YouTubeVideoInfo? {
        let key = url.absoluteString as NSString
        if let cached = Self.infoCache.object(forKey: key) {
            return cached.info
        }
        // Forward the cookie + UA captured by the browser extension so the
        // InnerTube call looks like it's coming from the same logged-in
        // session — gets us past the "Sign in to confirm you're not a bot"
        // gate without having to ship a real OAuth flow.
        let credentials = YouTubeExtractor.Credentials(
            cookies: request.cookies.isEmpty ? nil : request.cookies,
            userAgent: request.ua.isEmpty ? nil : request.ua,
            poToken: request.ytPoToken,
            poTokenVisitor: request.ytPoTokenVisitor
        )
        do {
            let info = try await YouTubeExtractor.shared.extract(url: url, credentials: credentials)
            Self.infoCache.setObject(CachedYouTubeInfo(info: info), forKey: key)
            return info
        } catch {
            return nil
        }
    }

    private func fetchYouTubeTitle(url: URL) async -> String? {
        guard let info = await cachedYouTubeInfo(for: url) else { return nil }
        let trimmed = info.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let sanitised = trimmed.replacingOccurrences(
            of: #"[/\\:*?\"<>|]"#,
            with: "_",
            options: .regularExpression
        )
        return sanitised + ".mp4"
    }

    private func fetchYouTubeFormats(url: URL) async -> [YouTubeFormatOption] {
        guard let info = await cachedYouTubeInfo(for: url) else { return [] }
        return Self.makeFormatOptions(from: info)
    }

    /// Builds the UI's quality picker list from a parsed `YouTubeVideoInfo`.
    /// We only surface adaptive (bestvideo + bestaudio) entries because those
    /// drive the existing aria2 + ffmpeg merge pipeline; progressive entries
    /// are reserved for the silent "Best Quality (Default)" fallback when no
    /// adaptive video is usable.
    static func makeFormatOptions(from info: YouTubeVideoInfo) -> [YouTubeFormatOption] {
        let usableAudio = info.adaptiveFormats.filter { $0.isAudio && $0.hasUsableUrl }
        let bestAudioSize = usableAudio.compactMap { $0.contentLength }.max() ?? 0

        let usableVideo = info.adaptiveFormats
            .filter { $0.isVideo && $0.hasUsableUrl && ($0.height ?? 0) > 0 }
            .sorted { ($0.height ?? 0, $0.bitrate) > ($1.height ?? 0, $1.bitrate) }

        var options: [YouTubeFormatOption] = []
        var seen = Set<String>()
        for v in usableVideo {
            guard let h = v.height, h > 0 else { continue }
            let ext = v.fileExtension
            let fps = v.fps ?? 0
            let fpsLabel = fps > 30 ? "\(fps)" : ""
            let key = "\(h)\(fpsLabel)-\(ext)"
            if seen.contains(key) { continue }
            seen.insert(key)
            let label = "\(h)p\(fpsLabel) (\(ext.uppercased()))"
            let query = "bestvideo[height<=\(h)][ext=\(ext)]+bestaudio/best"
            let estimated: Int64 = {
                guard let v = v.contentLength, v > 0 else { return 0 }
                return v + bestAudioSize
            }()
            options.append(YouTubeFormatOption(label: label, query: query, estimatedSize: estimated))
        }
        let defaultSize = options.first?.estimatedSize ?? 0
        options.insert(YouTubeFormatOption(label: "Best Quality (Default)", query: "", estimatedSize: defaultSize), at: 0)
        return options
    }
}

/// Reference-type wrapper so we can stash `YouTubeVideoInfo` (a value type)
/// inside `NSCache`, which only accepts class instances.
private final class CachedYouTubeInfo {
    let info: YouTubeVideoInfo
    init(info: YouTubeVideoInfo) { self.info = info }
}

// --- FIXED: FETCH REAL NAME FROM MAGNET PARAMETERS ---
private func suggestName(_ url: URL) -> String {
    if url.scheme?.lowercased() == "magnet" {
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let queryItems = components.queryItems,
           let dn = queryItems.first(where: { $0.name == "dn" })?.value {
            return dn.replacingOccurrences(of: "+", with: " ")
        }
        return "Torrent Download"
    }
    
    let last = url.lastPathComponent
    let dec = last.removingPercentEncoding ?? last
    return (!dec.isEmpty && dec != "/") ? dec : "download"
}

struct CappedDetailRow: View {
    let label: String
    let value: String
    let labelWidth: CGFloat
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).frame(width: labelWidth, alignment: .leading).fixedSize(horizontal: true, vertical: false).padding(.top, 1)
            ScrollView(.vertical, showsIndicators: true) {
                Text(value).font(.system(size: 10)).foregroundStyle(.primary).lineSpacing(5).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true).padding(.vertical, 4).padding(.horizontal, 6)
            }.frame(maxHeight: 72).background(Color(NSColor.controlBackgroundColor).opacity(0.4), in: RoundedRectangle(cornerRadius: 5)).overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(NSColor.separatorColor).opacity(0.4), lineWidth: 1))
        }
    }
}
