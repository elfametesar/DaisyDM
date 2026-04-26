import Foundation

/// A single stream returned by YouTube's InnerTube `/youtubei/v1/player` API.
/// Either video-only, audio-only (adaptiveFormats) or muxed (formats).
struct YouTubeFormat: Sendable {
    let itag: Int
    let url: String?
    let signatureCipher: String?
    let mimeType: String
    let codecs: String
    let bitrate: Int
    let width: Int?
    let height: Int?
    let fps: Int?
    let qualityLabel: String?
    let audioQuality: String?
    let contentLength: Int64?
    let approxDurationMs: Int64?

    /// True when we can hand the URL straight to aria2 — i.e. the response gave
    /// us a cleartext URL with no signature deciphering required.
    var hasUsableUrl: Bool { (url?.isEmpty == false) && (signatureCipher?.isEmpty != false) }

    var isVideo: Bool {
        let lower = mimeType.lowercased()
        return lower.hasPrefix("video/") && (height ?? 0) > 0
    }

    var isAudio: Bool {
        mimeType.lowercased().hasPrefix("audio/")
    }

    var fileExtension: String {
        let mt = mimeType.lowercased()
        if mt.contains("mp4") { return isAudio ? "m4a" : "mp4" }
        if mt.contains("webm") { return isAudio ? "weba" : "webm" }
        if mt.contains("mp3") { return "mp3" }
        return isAudio ? "m4a" : "mp4"
    }
}

/// Player metadata + every format we could harvest for a single video id.
struct YouTubeVideoInfo: Sendable {
    let videoId: String
    let title: String
    let author: String?
    let durationSeconds: Int?
    /// Pre-muxed legacy progressive streams (single file with both tracks).
    let formats: [YouTubeFormat]
    /// Separate video-only and audio-only streams (DASH style).
    let adaptiveFormats: [YouTubeFormat]
    /// The sourcing client (e.g. "IOS"), useful for diagnostics.
    let sourceClient: String

    /// Distinct (height, fps) buckets that can actually be downloaded right now.
    /// Used to populate the popup quality picker.
    var distinctVideoHeights: [Int] {
        let usable = adaptiveFormats.filter { $0.isVideo && $0.hasUsableUrl }
        let heights = usable.compactMap { $0.height }
        return Array(Set(heights)).sorted(by: >)
    }

    /// Best (highest bitrate / preferred codec) video stream <= maxHeight.
    /// Pass `maxHeight = nil` for absolute best.
    func bestVideo(maxHeight: Int?, preferContainer: String? = "mp4") -> YouTubeFormat? {
        let candidates = adaptiveFormats.filter { $0.isVideo && $0.hasUsableUrl }
        let bounded: [YouTubeFormat]
        if let cap = maxHeight, cap > 0 {
            bounded = candidates.filter { ($0.height ?? 0) <= cap }
        } else {
            bounded = candidates
        }
        return bounded.sorted { lhs, rhs in
            // Prefer container match (mp4 by default for compatibility with m4a + ffmpeg copy mux)
            if let want = preferContainer?.lowercased() {
                let lhsMatch = lhs.mimeType.lowercased().contains(want)
                let rhsMatch = rhs.mimeType.lowercased().contains(want)
                if lhsMatch != rhsMatch { return lhsMatch }
            }
            // Then highest resolution
            if (lhs.height ?? 0) != (rhs.height ?? 0) { return (lhs.height ?? 0) > (rhs.height ?? 0) }
            // Then highest bitrate
            return lhs.bitrate > rhs.bitrate
        }.first
    }

    /// Best audio stream — prefer m4a (mp4 audio) so ffmpeg can stream-copy
    /// into the mp4 container without re-encoding.
    func bestAudio(preferContainer: String? = "mp4") -> YouTubeFormat? {
        let candidates = adaptiveFormats.filter { $0.isAudio && $0.hasUsableUrl }
        return candidates.sorted { lhs, rhs in
            if let want = preferContainer?.lowercased() {
                let lhsMatch = lhs.mimeType.lowercased().contains(want)
                let rhsMatch = rhs.mimeType.lowercased().contains(want)
                if lhsMatch != rhsMatch { return lhsMatch }
            }
            return lhs.bitrate > rhs.bitrate
        }.first
    }

    /// Best pre-muxed (progressive) format <= maxHeight, or absolute best.
    /// Used as a fallback when separate adaptive streams aren't available.
    func bestMuxed(maxHeight: Int? = nil) -> YouTubeFormat? {
        let candidates = formats.filter { $0.hasUsableUrl }
        let bounded: [YouTubeFormat]
        if let cap = maxHeight, cap > 0 {
            bounded = candidates.filter { ($0.height ?? 0) <= cap }
        } else {
            bounded = candidates
        }
        return bounded.sorted { ($0.height ?? 0) > ($1.height ?? 0) }.first
    }
}

enum YouTubeExtractorError: Error, LocalizedError {
    case missingVideoId
    case noStreamingData
    case allClientsFailed(String?)
    case unplayable(reason: String)
    case noFormatMatch
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .missingVideoId: return "Couldn't extract a YouTube video id from the URL."
        case .noStreamingData: return "YouTube returned no streaming data for this video."
        case .allClientsFailed(let detail):
            return "Every YouTube client variant failed to return playable formats." + (detail.map { " (\($0))" } ?? "")
        case .unplayable(let reason): return "YouTube reported the video as unplayable: \(reason)"
        case .noFormatMatch: return "No streamable format matched the requested quality."
        case .networkError(let m): return "Network error contacting YouTube: \(m)"
        }
    }
}

/// Pulls metadata + stream URLs for a YouTube video by talking directly to
/// the InnerTube `/youtubei/v1/player` endpoint. Walks several official
/// client identities (iOS → Android → TV embedded) so a single client's
/// signature/throttling quirk doesn't block the whole download. We never
/// touch the page or the player JS — this is the same surface the official
/// YouTube apps use, so for the vast majority of public videos we get back
/// cleartext CDN URLs that aria2 can fetch directly.
actor YouTubeExtractor {
    static let shared = YouTubeExtractor()

    struct ClientContext: Sendable {
        let name: String
        let version: String
        let userAgent: String
        let xClientName: String
        let xClientVersion: String
        let deviceMake: String?
        let deviceModel: String?
        let osName: String?
        let osVersion: String?
        let androidSdkVersion: Int?
        /// InnerTube API key, appended as `?key=` to the endpoint. YouTube
        /// rotates these but the public set is stable enough that hard-coding
        /// matches yt-dlp's approach.
        let apiKey: String?
    }

    /// Client identities used to talk to /youtubei/v1/player. Order matters —
    /// we walk them in sequence and merge results. The lineup mirrors yt-dlp's
    /// 2025 default set, biased toward clients that don't require a Proof-of-
    /// Origin (PO) token to return playable URLs:
    ///
    /// 1. ANDROID_VR — Quest YouTube app. Currently the most reliable bypass.
    /// 2. TVHTML5 — full TV client, exposes premium resolutions.
    /// 3. WEB_EMBEDDED_PLAYER — works for the vast majority of embeds.
    /// 4. TVHTML5_SIMPLY_EMBEDDED_PLAYER — last-ditch for age-gated content.
    /// 5. IOS — kept as a final fallback; some clients reject AVR for music.
    private let clients: [ClientContext] = [
        ClientContext(
            name: "ANDROID_VR",
            version: "1.60.19",
            userAgent: "com.google.android.apps.youtube.vr.oculus/1.60.19 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
            xClientName: "28",
            xClientVersion: "1.60.19",
            deviceMake: "Oculus",
            deviceModel: "Quest 3",
            osName: "Android",
            osVersion: "12L",
            androidSdkVersion: 32,
            apiKey: "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8"
        ),
        ClientContext(
            name: "TVHTML5",
            version: "7.20250115.16.00",
            userAgent: "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version",
            xClientName: "7",
            xClientVersion: "7.20250115.16.00",
            deviceMake: nil,
            deviceModel: nil,
            osName: nil,
            osVersion: nil,
            androidSdkVersion: nil,
            apiKey: "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8"
        ),
        ClientContext(
            name: "WEB_EMBEDDED_PLAYER",
            version: "1.20250115.01.00",
            userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
            xClientName: "56",
            xClientVersion: "1.20250115.01.00",
            deviceMake: nil,
            deviceModel: nil,
            osName: nil,
            osVersion: nil,
            androidSdkVersion: nil,
            apiKey: "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8"
        ),
        ClientContext(
            name: "TVHTML5_SIMPLY_EMBEDDED_PLAYER",
            version: "2.0",
            userAgent: "Mozilla/5.0 (PlayStation 4 5.55) AppleWebKit/601.2 (KHTML, like Gecko)",
            xClientName: "85",
            xClientVersion: "2.0",
            deviceMake: nil,
            deviceModel: nil,
            osName: nil,
            osVersion: nil,
            androidSdkVersion: nil,
            apiKey: "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8"
        ),
        ClientContext(
            name: "IOS",
            version: "20.10.4",
            userAgent: "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
            xClientName: "5",
            xClientVersion: "20.10.4",
            deviceMake: "Apple",
            deviceModel: "iPhone16,2",
            osName: "iPhone",
            osVersion: "18.3.2.22D82",
            androidSdkVersion: nil,
            apiKey: "AIzaSyB-63vPrdThhKuerbB2N_l7Kwwcxj6yUAc"
        )
    ]

    /// Walk the configured clients in order. Merge usable formats from every
    /// client that responds — iOS often has more resolutions, Android often
    /// reports filesize for older itags, TV embedded sometimes plays content
    /// the others won't. The merged result is what we hand back.
    func extract(url: URL) async throws -> YouTubeVideoInfo {
        let videoId = try Self.parseVideoId(url)
        return try await extract(videoId: videoId)
    }

    func extract(videoId: String) async throws -> YouTubeVideoInfo {
        var lastError: Error?
        var merged: YouTubeVideoInfo?
        var seenItags = Set<Int>()
        var seenAdaptiveItags = Set<Int>()

        for client in clients {
            do {
                let info = try await fetch(videoId: videoId, client: client)
                if merged == nil {
                    merged = info
                    seenItags = Set(info.formats.map { $0.itag })
                    seenAdaptiveItags = Set(info.adaptiveFormats.map { $0.itag })
                } else {
                    // Append any *new* itags we hadn't seen yet, preferring
                    // streams with usable (non-cipher) URLs.
                    let newProgressive = info.formats.filter { !seenItags.contains($0.itag) && $0.hasUsableUrl }
                    let newAdaptive = info.adaptiveFormats.filter { !seenAdaptiveItags.contains($0.itag) && $0.hasUsableUrl }
                    seenItags.formUnion(newProgressive.map { $0.itag })
                    seenAdaptiveItags.formUnion(newAdaptive.map { $0.itag })
                    merged = YouTubeVideoInfo(
                        videoId: merged!.videoId,
                        title: merged!.title.isEmpty ? info.title : merged!.title,
                        author: merged!.author ?? info.author,
                        durationSeconds: merged!.durationSeconds ?? info.durationSeconds,
                        formats: merged!.formats + newProgressive,
                        adaptiveFormats: merged!.adaptiveFormats + newAdaptive,
                        sourceClient: merged!.sourceClient
                    )
                }
                // Early-exit: as soon as we have at least one usable video and
                // one usable audio in adaptiveFormats, OR any usable progressive
                // format, we're done.
                let hasUsableAdaptive =
                    (merged!.adaptiveFormats.contains { $0.isVideo && $0.hasUsableUrl }) &&
                    (merged!.adaptiveFormats.contains { $0.isAudio && $0.hasUsableUrl })
                let hasUsableProgressive = merged!.formats.contains { $0.hasUsableUrl }
                if hasUsableAdaptive || hasUsableProgressive {
                    return merged!
                }
            } catch {
                lastError = error
            }
        }

        if let info = merged { return info }
        throw lastError ?? YouTubeExtractorError.allClientsFailed(nil)
    }

    /// Parses the YouTube video id out of every URL form we care about:
    /// - youtube.com/watch?v=ID (and music.youtube.com)
    /// - youtu.be/ID
    /// - youtube.com/shorts/ID
    /// - youtube.com/embed/ID, /v/ID, /live/ID
    static func parseVideoId(_ url: URL) throws -> String {
        if let comp = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let v = comp.queryItems?.first(where: { $0.name == "v" })?.value,
           !v.isEmpty {
            return v
        }
        let path = url.path
        if let host = url.host?.lowercased(), host.contains("youtu.be") {
            let id = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !id.isEmpty {
                if let slash = id.firstIndex(of: "/") { return String(id[..<slash]) }
                return id
            }
        }
        for prefix in ["/shorts/", "/embed/", "/live/", "/v/"] {
            if path.hasPrefix(prefix) {
                let rest = String(path.dropFirst(prefix.count))
                if let slash = rest.firstIndex(of: "/") { return String(rest[..<slash]) }
                if !rest.isEmpty { return rest }
            }
        }
        throw YouTubeExtractorError.missingVideoId
    }

    private func fetch(videoId: String, client: ClientContext) async throws -> YouTubeVideoInfo {
        var endpointString = "https://www.youtube.com/youtubei/v1/player?prettyPrint=false"
        if let key = client.apiKey, !key.isEmpty {
            endpointString += "&key=\(key)"
        }
        guard let endpoint = URL(string: endpointString) else {
            throw YouTubeExtractorError.networkError("invalid endpoint")
        }

        var req = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(client.xClientName, forHTTPHeaderField: "X-YouTube-Client-Name")
        req.setValue(client.xClientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        req.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        req.setValue("https://www.youtube.com", forHTTPHeaderField: "Referer")

        var clientCtx: [String: Any] = [
            "clientName": client.name,
            "clientVersion": client.version,
            "userAgent": client.userAgent,
            "hl": "en",
            "gl": "US"
        ]
        if let m = client.deviceMake { clientCtx["deviceMake"] = m }
        if let m = client.deviceModel { clientCtx["deviceModel"] = m }
        if let o = client.osName { clientCtx["osName"] = o }
        if let v = client.osVersion { clientCtx["osVersion"] = v }
        if let s = client.androidSdkVersion { clientCtx["androidSdkVersion"] = s }

        let body: [String: Any] = [
            "context": ["client": clientCtx],
            "videoId": videoId,
            "playbackContext": [
                "contentPlaybackContext": [
                    "html5Preference": "HTML5_PREF_WANTS"
                ]
            ],
            "contentCheckOk": true,
            "racyCheckOk": true
        ]

        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw YouTubeExtractorError.networkError("could not encode request body")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw YouTubeExtractorError.networkError(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw YouTubeExtractorError.allClientsFailed("\(client.name) returned HTTP \(code)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw YouTubeExtractorError.allClientsFailed("\(client.name) returned non-JSON")
        }

        let videoDetails = json["videoDetails"] as? [String: Any] ?? [:]
        let title = (videoDetails["title"] as? String) ?? ""
        let author = videoDetails["author"] as? String
        let lengthString = videoDetails["lengthSeconds"] as? String
        let lengthInt = videoDetails["lengthSeconds"] as? Int
        let durationSeconds = lengthInt ?? Int(lengthString ?? "")
        let id = (videoDetails["videoId"] as? String) ?? videoId

        if let playability = json["playabilityStatus"] as? [String: Any],
           let status = playability["status"] as? String,
           status != "OK",
           (json["streamingData"] as? [String: Any]) == nil {
            let reason = (playability["reason"] as? String) ?? status
            throw YouTubeExtractorError.unplayable(reason: reason)
        }

        guard let streamingData = json["streamingData"] as? [String: Any] else {
            throw YouTubeExtractorError.noStreamingData
        }

        let formats = (streamingData["formats"] as? [[String: Any]] ?? []).compactMap { Self.parseFormat($0) }
        let adaptive = (streamingData["adaptiveFormats"] as? [[String: Any]] ?? []).compactMap { Self.parseFormat($0) }

        return YouTubeVideoInfo(
            videoId: id,
            title: title.isEmpty ? "YouTube Video" : title,
            author: author,
            durationSeconds: durationSeconds,
            formats: formats,
            adaptiveFormats: adaptive,
            sourceClient: client.name
        )
    }

    private static func parseFormat(_ dict: [String: Any]) -> YouTubeFormat? {
        guard let itag = dict["itag"] as? Int else { return nil }
        let mimeType = dict["mimeType"] as? String ?? ""
        if mimeType.isEmpty { return nil }

        let bitrate = (dict["bitrate"] as? Int) ?? (dict["averageBitrate"] as? Int) ?? 0
        let url = dict["url"] as? String
        let signatureCipher = (dict["signatureCipher"] as? String) ?? (dict["cipher"] as? String)
        let width = dict["width"] as? Int
        let height = dict["height"] as? Int
        let fps = dict["fps"] as? Int
        let qualityLabel = dict["qualityLabel"] as? String
        let audioQuality = dict["audioQuality"] as? String

        let contentLength: Int64?
        if let s = dict["contentLength"] as? String, let v = Int64(s) { contentLength = v }
        else if let i = dict["contentLength"] as? Int { contentLength = Int64(i) }
        else if let i = dict["contentLength"] as? Int64 { contentLength = i }
        else { contentLength = nil }

        let approxDurationMs: Int64?
        if let s = dict["approxDurationMs"] as? String, let v = Int64(s) { approxDurationMs = v }
        else if let i = dict["approxDurationMs"] as? Int { approxDurationMs = Int64(i) }
        else { approxDurationMs = nil }

        var codecs = ""
        if let r = mimeType.range(of: #"codecs="([^"]+)""#, options: .regularExpression) {
            let snippet = String(mimeType[r])
            codecs = snippet
                .replacingOccurrences(of: "codecs=\"", with: "")
                .replacingOccurrences(of: "\"", with: "")
        }

        return YouTubeFormat(
            itag: itag,
            url: url,
            signatureCipher: signatureCipher,
            mimeType: mimeType,
            codecs: codecs,
            bitrate: bitrate,
            width: width,
            height: height,
            fps: fps,
            qualityLabel: qualityLabel,
            audioQuality: audioQuality,
            contentLength: contentLength,
            approxDurationMs: approxDurationMs
        )
    }
}

/// Parses the yt-dlp-style format strings the rest of the app already speaks
/// (e.g. `bestvideo[height<=1080][ext=mp4]+bestaudio/best`) and resolves them
/// against a `YouTubeVideoInfo`. We only support the subset the popup actually
/// generates — anything else falls back to "best video <= cap + best audio".
struct YouTubeFormatSelection {
    var maxHeight: Int? = nil
    var preferContainer: String? = nil
    /// `true`  → bestvideo + bestaudio (DASH)
    /// `false` → best (legacy progressive single file)
    var preferAdaptive: Bool = true

    static func parse(_ query: String?) -> YouTubeFormatSelection {
        var sel = YouTubeFormatSelection()
        guard let raw = query?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return sel
        }
        let primary = raw.split(separator: "/").first.map(String.init) ?? raw
        if primary.lowercased() == "best" {
            sel.preferAdaptive = false
            return sel
        }
        if primary.lowercased().contains("bestvideo") {
            sel.preferAdaptive = true
        }
        if let r = primary.range(of: #"height\s*[<=]+\s*(\d+)"#, options: .regularExpression) {
            let captured = String(primary[r])
            if let m = captured.range(of: #"\d+"#, options: .regularExpression) {
                sel.maxHeight = Int(captured[m])
            }
        }
        if let r = primary.range(of: #"ext\s*=\s*([a-zA-Z0-9]+)"#, options: .regularExpression) {
            let captured = String(primary[r])
            sel.preferContainer = captured
                .replacingOccurrences(of: "ext", with: "")
                .replacingOccurrences(of: "=", with: "")
                .trimmingCharacters(in: .whitespaces)
        }
        return sel
    }

    /// Resolves to either `(video, audio)` for adaptive downloads
    /// (which the existing aria2 + ffmpeg merge pipeline expects)
    /// or `(muxed, nil)` for a progressive single-file download.
    func resolve(in info: YouTubeVideoInfo) throws -> (video: YouTubeFormat, audio: YouTubeFormat?) {
        if !preferAdaptive {
            if let muxed = info.bestMuxed(maxHeight: maxHeight) { return (muxed, nil) }
            // fall through to adaptive if no usable progressive
        }
        let want = preferContainer ?? "mp4"
        if let v = info.bestVideo(maxHeight: maxHeight, preferContainer: want),
           let a = info.bestAudio(preferContainer: v.mimeType.lowercased().contains("mp4") ? "mp4" : "webm") {
            return (v, a)
        }
        // Either no audio or no video stream — fall back to best progressive
        if let muxed = info.bestMuxed(maxHeight: maxHeight) { return (muxed, nil) }
        throw YouTubeExtractorError.noFormatMatch
    }
}
