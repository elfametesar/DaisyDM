import AppKit
import SafariServices
import SwiftUI
import UniformTypeIdentifiers

@main
struct DaisyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Window("Daisy", id: "main") {
            ContentView()
                .frame(minWidth: 1300, minHeight: 550)
                .onOpenURL { url in
                    if url.scheme == URLSchemeHandler.scheme {
                        URLSchemeHandler.handle(url)
                    } else if url.isFileURL && url.pathExtension.lowercased() == "torrent" {
                        Task { @MainActor in
                            let engine = DownloadEngine.shared
                            let defaults = UserDefaults.standard
                            let defaultPath = defaults.string(forKey: "defaultDownloadPath") ?? engine.downloadsDir().path
                            let dest = URL(fileURLWithPath: defaultPath)
                            engine.addDownload(urls: [url], destination: dest, connections: 16)
                            NSApp.activate(ignoringOtherApps: true)
                        }
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Download…") {
                    NotificationCenter.default.post(name: .showAddDownload, object: nil)
                }
                .keyboardShortcut("n")
            }

            CommandMenu("Download") {
                Button("Show Progress Window") {
                    NotificationCenter.default.post(name: .openSelectedProgressWindow, object: nil)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }

            CommandMenu("Daisy DM") {
                Button("Check for Stable Update…") {
                    Task { @MainActor in
                        DaisyUpdateManager.shared.checkAndOffer(channel: .stable)
                    }
                }

                Button("Check for Beta Update…") {
                    Task { @MainActor in
                        DaisyUpdateManager.shared.checkAndOffer(channel: .beta)
                    }
                }

                Divider()

                Button("Use Stable Updates") {
                    UserDefaults.standard.set(DaisyUpdateChannel.stable.rawValue, forKey: DaisyUpdateManager.channelKey)
                }
                .state(UserDefaults.standard.string(forKey: DaisyUpdateManager.channelKey) == DaisyUpdateChannel.beta.rawValue ? .off : .on)

                Button("Use Beta Updates") {
                    UserDefaults.standard.set(DaisyUpdateChannel.beta.rawValue, forKey: DaisyUpdateManager.channelKey)
                }
                .state(UserDefaults.standard.string(forKey: DaisyUpdateManager.channelKey) == DaisyUpdateChannel.beta.rawValue ? .on : .off)
            }
        }
 
        WindowGroup(for: UUID.self) { $id in
            if let id = id, let item = DownloadEngine.shared.items.first(where: { $0.id == id }) {
                if item.status == .failed {
                    FailedDownloadDialog(item: item)
                } else {
                    ProgressWindowView(item: item)
                }
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 460, height: 370)
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let safariExtensionBundleIdentifier = "com.daisy.dm.Extension"

    private var confirmPanel: NSPanel?
    private var confirmObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        TrayController.shared.setup()
        LocalServer.shared.start()

        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:replyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        confirmObserver = NotificationCenter.default.addObserver(
            forName: .confirmDownload,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let info = note.userInfo, let url = info["url"] as? URL else { return }

            let filename = info["filename"] as? String ?? ""
            let cookies = info["cookies"] as? String ?? ""
            let referer = info["referer"] as? String ?? ""
            let ua = info["ua"] as? String ?? ""
            let forceHLS = info["forceHLS"] as? Bool ?? false
            let forceDASH = info["forceDASH"] as? Bool ?? false
            let forceDirectDownload = info["forceDirectDownload"] as? Bool ?? false
            let youtubeQuality = info["youtubeQuality"] as? String
            let headers = info["headers"] as? [String: String] ?? [:]

            let request = ConfirmDownloadRequest(
                url: url,
                filename: filename,
                headers: headers,
                cookies: cookies,
                referer: referer,
                ua: ua,
                forceHLS: forceHLS,
                forceDASH: forceDASH,
                forceDirectDownload: forceDirectDownload,
                youtubeQuality: youtubeQuality
            )
            self?.presentConfirmPanel(request: request)
        }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            let channel = DaisyUpdateChannel(rawValue: UserDefaults.standard.string(forKey: DaisyUpdateManager.channelKey) ?? "stable") ?? .stable
            DaisyUpdateManager.shared.checkAndOffer(channel: channel, automatic: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }

    @objc func handleURLEvent(_ event: NSAppleEventDescriptor, replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: urlString) else { return }
        URLSchemeHandler.handle(url)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.scheme == URLSchemeHandler.scheme {
                URLSchemeHandler.handle(url)
            } else if url.isFileURL && url.pathExtension.lowercased() == "torrent" {
                Task { @MainActor in
                    let engine = DownloadEngine.shared
                    let defaults = UserDefaults.standard
                    let defaultPath = defaults.string(forKey: "defaultDownloadPath") ?? engine.downloadsDir().path
                    let dest = URL(fileURLWithPath: defaultPath)
                    engine.addDownload(urls: [url], destination: dest, connections: 16)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
    }

    private func presentConfirmPanel(request: ConfirmDownloadRequest) {
        confirmPanel?.close()
        confirmPanel = nil

        if NSApp.isHidden { NSApp.unhide(nil) }
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 1),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Download"
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = false
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior.insert(.moveToActiveSpace)

        let confirmView = ConfirmDownloadView(
            request: request,
            onConfirm: { [weak panel] confirmedRequest, destination, connections in
                panel?.close()
                Task { @MainActor in
                    let engine = DownloadEngine.shared
                    let dest = destination
                    let url = confirmedRequest.url

                    engine.addDownload(
                        urls: [url],
                        destination: dest,
                        connections: connections,
                        cookies: confirmedRequest.cookies.isEmpty ? nil : confirmedRequest.cookies,
                        userAgent: confirmedRequest.ua.isEmpty ? nil : confirmedRequest.ua,
                        referer: confirmedRequest.referer.isEmpty ? nil : confirmedRequest.referer,
                        filename: confirmedRequest.filename.isEmpty ? nil : confirmedRequest.filename,
                        youtubeQuality: confirmedRequest.youtubeQuality?.isEmpty == false ? confirmedRequest.youtubeQuality : nil,
                        isHLS: confirmedRequest.forceHLS,
                        isDASH: confirmedRequest.forceDASH,
                        browser: nil,
                        forceDirectDownload: confirmedRequest.forceDirectDownload
                    )

                    if let newestItem = engine.items.last(where: { $0.url == url }) {
                        newestItem.headers = confirmedRequest.headers
                    }
                    NSApp.activate(ignoringOtherApps: true)
                }
            },
            onCancel: { [weak panel] in panel?.close() }
        )

        let hostingView = NSHostingView(rootView: confirmView)
        if #available(macOS 13.0, *) { hostingView.sizingOptions = [.preferredContentSize] }
        panel.contentView = hostingView
        panel.setContentSize(hostingView.fittingSize)
        panel.center()
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.main.async { [weak panel] in
            guard let panel else { return }
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        }

        self.confirmPanel = panel
    }
}

enum DaisyUpdateChannel: String {
    case stable
    case beta
}

struct DaisyUpdateCandidate {
    let version: String
    let downloadURL: URL
    let channel: DaisyUpdateChannel
    let releasePageURL: URL?
}

@MainActor
final class DaisyUpdateManager {
    static let shared = DaisyUpdateManager()
    static let channelKey = "daisyUpdateChannel"

    private let repository = "elfametesar/DaisyDM"
    private var isChecking = false
    private var isInstalling = false

    private init() {}

    func checkAndOffer(channel: DaisyUpdateChannel, automatic: Bool = false) {
        guard !isChecking && !isInstalling else { return }
        isChecking = true

        Task {
            defer { isChecking = false }
            do {
                guard let candidate = try await fetchCandidate(channel: channel) else {
                    if !automatic { showInfo(title: "Daisy DM", message: "No newer \(channel == .stable ? "stable" : "beta") version is available.") }
                    return
                }
                guard isNewer(candidate.version, than: currentVersion) else {
                    if !automatic { showInfo(title: "Daisy DM", message: "You are already running the latest \(channel == .stable ? "stable" : "beta") version (\(currentVersion)).") }
                    return
                }
                offer(candidate)
            } catch {
                if !automatic { showInfo(title: "Update Check Failed", message: error.localizedDescription) }
            }
        }
    }

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    private func fetchCandidate(channel: DaisyUpdateChannel) async throws -> DaisyUpdateCandidate? {
        switch channel {
        case .stable:
            return try await fetchStableCandidate()
        case .beta:
            return try await fetchBetaCandidate()
        }
    }

    private func fetchStableCandidate() async throws -> DaisyUpdateCandidate? {
        let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
        let release = try await getJSON(url: url)
        guard let tag = release["tag_name"] as? String,
              let version = normalizedVersion(tag),
              let assets = release["assets"] as? [[String: Any]] else { return nil }

        let asset = assets.first { asset in
            guard let name = asset["name"] as? String else { return false }
            return name.hasPrefix("Daisy-DM-") && name.contains("-macOS-universal.zip")
        }
        guard let asset, let rawURL = asset["browser_download_url"] as? String,
              let downloadURL = URL(string: rawURL) else { return nil }

        let pageURL = (release["html_url"] as? String).flatMap(URL.init(string:))
        return DaisyUpdateCandidate(version: version, downloadURL: downloadURL, channel: .stable, releasePageURL: pageURL)
    }

    private func fetchBetaCandidate() async throws -> DaisyUpdateCandidate? {
        var components = URLComponents(string: "https://api.github.com/repos/\(repository)/actions/runs")!
        components.queryItems = [
            URLQueryItem(name: "workflow_id", value: "manual-build-release.yml"),
            URLQueryItem(name: "branch", value: "main"),
            URLQueryItem(name: "status", value: "completed"),
            URLQueryItem(name: "per_page", value: "20")
        ]
        let runsURL = components.url!
        let runs = try await getJSON(url: runsURL)
        guard let workflowRuns = runs["workflow_runs"] as? [[String: Any]] else { return nil }

        for run in workflowRuns {
            guard (run["conclusion"] as? String) == "success",
                  let runID = run["id"] as? Int else { continue }

            let artifactsURL = URL(string: "https://api.github.com/repos/\(repository)/actions/runs/\(runID)/artifacts")!
            let artifacts = try await getJSON(url: artifactsURL)
            guard let values = artifacts["artifacts"] as? [[String: Any]],
                  let artifact = values.first(where: { ($0["name"] as? String)?.hasPrefix("daisy-dm-") == true }),
                  let artifactName = artifact["name"] as? String,
                  let artifactID = artifact["id"] as? Int,
                  let version = normalizedVersion(String(artifactName.dropFirst("daisy-dm-".count))) else { continue }

            let downloadURL = URL(string: "https://api.github.com/repos/\(repository)/actions/artifacts/\(artifactID)/zip")!
            let pageURL = (run["html_url"] as? String).flatMap(URL.init(string:))
            return DaisyUpdateCandidate(version: version, downloadURL: downloadURL, channel: .beta, releasePageURL: pageURL)
        }
        return nil
    }

    private func getJSON(url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("DaisyDM-Updater/1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UpdateError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UpdateError.invalidResponse
        }
        return json
    }

    private func normalizedVersion(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "^v", with: "", options: .regularExpression)
        let parts = value.split(separator: ".")
        guard parts.count == 3, parts.allSatisfy({ Int($0) != nil }) else { return nil }
        return value
    }

    private func isNewer(_ lhs: String, than rhs: String) -> Bool {
        let a = lhs.split(separator: ".").compactMap { Int($0) }
        let b = rhs.split(separator: ".").compactMap { Int($0) }
        guard a.count == 3, b.count == 3 else { return lhs.compare(rhs, options: .numeric) == .orderedDescending }
        return a.lexicographicallyPrecedes(b) == false && a != b
    }

    private func offer(_ candidate: DaisyUpdateCandidate) {
        let alert = NSAlert()
        alert.messageText = "Daisy DM \(candidate.channel == .stable ? "Stable" : "Beta") Update"
        alert.informativeText = "Version \(candidate.version) is available. You are running \(currentVersion)."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Install Update")
        alert.addButton(withTitle: "Later")
        if let page = candidate.releasePageURL {
            alert.addButton(withTitle: "View on GitHub")
            let response = alert.runModal()
            if response == .alertThirdButtonReturn {
                NSWorkspace.shared.open(page)
                return
            }
            if response != .alertFirstButtonReturn { return }
        } else if alert.runModal() != .alertFirstButtonReturn {
            return
        }
        install(candidate)
    }

    private func install(_ candidate: DaisyUpdateCandidate) {
        guard !isInstalling else { return }
        isInstalling = true

        Task {
            do {
                let temp = FileManager.default.temporaryDirectory.appendingPathComponent("DaisyDM-update-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: temp) }

                let archive = temp.appendingPathComponent("update.zip")
                try await download(candidate.downloadURL, to: archive)

                let extracted = temp.appendingPathComponent("extracted", isDirectory: true)
                try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
                try runTool("/usr/bin/ditto", arguments: ["-x", "-k", archive.path, extracted.path])

                let appArchive: URL
                if candidate.channel == .stable {
                    guard let found = findZip(in: extracted, matching: "-macOS-universal.zip") else { throw UpdateError.assetMissing }
                    appArchive = found
                } else {
                    guard let found = findZip(in: extracted, matching: "-macOS-universal.zip") else { throw UpdateError.assetMissing }
                    appArchive = found
                }

                let appExtracted = temp.appendingPathComponent("app", isDirectory: true)
                try FileManager.default.createDirectory(at: appExtracted, withIntermediateDirectories: true)
                try runTool("/usr/bin/ditto", arguments: ["-x", "-k", appArchive.path, appExtracted.path])
                let newApp = appExtracted.appendingPathComponent("Daisy.app")
                guard FileManager.default.fileExists(atPath: newApp.path) else { throw UpdateError.appMissing }

                let currentApp = Bundle.main.bundleURL.standardizedFileURL
                let stagedApp = currentApp.deletingLastPathComponent().appendingPathComponent(".Daisy.app.new-\(UUID().uuidString)")
                try FileManager.default.moveItem(at: newApp, to: stagedApp)

                let script = """
                #!/bin/bash
                set -e
                sleep 1
                rm -rf -- \(shellQuote(currentApp.path))
                mv -- \(shellQuote(stagedApp.path)) \(shellQuote(currentApp.path))
                open -- \(shellQuote(currentApp.path))
                """
                let scriptURL = temp.appendingPathComponent("install.sh")
                try script.write(to: scriptURL, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/bin/bash")
                task.arguments = [scriptURL.path]
                try task.run()
                NSApp.terminate(nil)
            } catch {
                isInstalling = false
                showInfo(title: "Update Failed", message: error.localizedDescription)
            }
        }
    }

    private func download(_ url: URL, to destination: URL) async throws {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("DaisyDM-Updater/1", forHTTPHeaderField: "User-Agent")
        let (temporaryURL, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UpdateError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
    }

    private func findZip(in directory: URL, matching suffix: String) -> URL? {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "zip" && url.lastPathComponent.hasSuffix(suffix) {
            return url
        }
        return nil
    }

    private func runTool(_ path: String, arguments: [String]) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw UpdateError.commandFailed(path) }
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func showInfo(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    enum UpdateError: LocalizedError {
        case httpStatus(Int)
        case invalidResponse
        case assetMissing
        case appMissing
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .httpStatus(let status): return "GitHub returned HTTP \(status)."
            case .invalidResponse: return "GitHub returned an unexpected response."
            case .assetMissing: return "The update archive did not contain a universal macOS app archive."
            case .appMissing: return "The downloaded archive did not contain Daisy.app."
            case .commandFailed(let command): return "The update archive could not be extracted (\(command))."
            }
        }
    }
}

extension Notification.Name {
    static let showAddDownload = Notification.Name("showAddDownload")
    static let openProgressWindow = Notification.Name("openProgressWindow")
    static let openSelectedProgressWindow = Notification.Name("openSelectedProgressWindow")
    static let requestAddDownload = Notification.Name("requestAddDownload")
    static let confirmDownload = Notification.Name("confirmDownload")
    static let showSettings = Notification.Name("showSettings")
}
