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
                    // 1. Handle daisy:// links
                    if url.scheme == URLSchemeHandler.scheme {
                        URLSchemeHandler.handle(url)
                    }
                    // 2. Handle double-clicked .torrent files
                    else if url.isFileURL && url.pathExtension.lowercased() == "torrent" {
                        Task { @MainActor in
                            let engine = DownloadEngine.shared
                            let defaults = UserDefaults.standard
                            let defaultPath = defaults.string(forKey: "defaultDownloadPath") ?? engine.downloadsDir().path
                            let dest = URL(fileURLWithPath: defaultPath)
                            
                            engine.addDownload(
                                urls: [url],
                                destination: dest,
                                connections: 16
                            )
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
        // Initialize the native AppKit Tray Controller
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
            guard
                let info     = note.userInfo,
                let url      = info["url"]      as? URL
            else { return }

            let filename = info["filename"] as? String ?? ""
            let cookies  = info["cookies"]  as? String ?? ""
            let referer  = info["referer"]  as? String ?? ""
            let ua       = info["ua"]       as? String ?? ""
            let forceHLS = info["forceHLS"] as? Bool ?? false
            let forceDASH = info["forceDASH"] as? Bool ?? false
            let forceDirectDownload = info["forceDirectDownload"] as? Bool ?? false
            let youtubeQuality = info["youtubeQuality"] as? String
            let headers = info["headers"] as? [String: String] ?? [:]
            let ytPoTokenRaw = info["ytPoToken"] as? String ?? ""
            let ytPoToken: String? = ytPoTokenRaw.isEmpty ? nil : ytPoTokenRaw
            let ytPoTokenVisitorRaw = info["ytPoTokenVisitor"] as? String ?? ""
            let ytPoTokenVisitor: String? = ytPoTokenVisitorRaw.isEmpty ? nil : ytPoTokenVisitorRaw
            let ytVideoUrlRaw = info["ytVideoUrl"] as? String ?? ""
            let ytVideoUrl: String? = ytVideoUrlRaw.isEmpty ? nil : ytVideoUrlRaw
            let ytAudioUrlRaw = info["ytAudioUrl"] as? String ?? ""
            let ytAudioUrl: String? = ytAudioUrlRaw.isEmpty ? nil : ytAudioUrlRaw
            let ytVideoMimeRaw = info["ytVideoMime"] as? String ?? ""
            let ytVideoMime: String? = ytVideoMimeRaw.isEmpty ? nil : ytVideoMimeRaw
            let ytAudioMimeRaw = info["ytAudioMime"] as? String ?? ""
            let ytAudioMime: String? = ytAudioMimeRaw.isEmpty ? nil : ytAudioMimeRaw
            let ytHeightRaw = info["ytHeight"] as? Int ?? 0
            let ytHeight: Int? = ytHeightRaw > 0 ? ytHeightRaw : nil
            let ytTitleRaw = info["ytTitle"] as? String ?? ""
            let ytTitle: String? = ytTitleRaw.isEmpty ? nil : ytTitleRaw

            let request = ConfirmDownloadRequest(
                url:      url,
                filename: filename,
                headers:  headers,
                cookies:  cookies,
                referer:  referer,
                ua:       ua,
                forceHLS: forceHLS,
                forceDASH: forceDASH,
                forceDirectDownload: forceDirectDownload,
                youtubeQuality: youtubeQuality,
                ytPoToken: ytPoToken,
                ytPoTokenVisitor: ytPoTokenVisitor,
                ytVideoUrl: ytVideoUrl,
                ytAudioUrl: ytAudioUrl,
                ytVideoMime: ytVideoMime,
                ytAudioMime: ytAudioMime,
                ytHeight: ytHeight,
                ytTitle: ytTitle
            )
            self?.presentConfirmPanel(request: request)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }

    @objc func handleURLEvent(_ event: NSAppleEventDescriptor, replyEvent: NSAppleEventDescriptor) {
        guard
            let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
            let url       = URL(string: urlString)
        else { return }
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
                    
                    engine.addDownload(
                        urls: [url],
                        destination: dest,
                        connections: 16
                    )
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
    }

    private func presentConfirmPanel(request: ConfirmDownloadRequest) {
        confirmPanel?.close()
        confirmPanel = nil

        // Make sure the app itself is foregrounded before we even create the
        // panel — without this, NSPanel.makeKeyAndOrderFront silently fails to
        // pull focus when triggered from the browser extension while Daisy is
        // hidden / in the background (notably for YouTube + HLS flows).
        if NSApp.isHidden { NSApp.unhide(nil) }
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSPanel(
            contentRect:  NSRect(x: 0, y: 0, width: 460, height: 1),
            styleMask:    [.titled, .closable, .fullSizeContentView],
            backing:      .buffered,
            defer:        false
        )
        panel.title                       = "Download"
        panel.titlebarAppearsTransparent  = true
        panel.isMovableByWindowBackground = false
        panel.level                       = .floating
        panel.isReleasedWhenClosed        = false
        panel.backgroundColor             = .clear
        panel.isOpaque                    = false
        panel.becomesKeyOnlyIfNeeded      = false
        panel.hidesOnDeactivate           = false
        panel.collectionBehavior.insert(.moveToActiveSpace)

        let confirmView = ConfirmDownloadView(
            request: request,
            onConfirm: { [weak panel] confirmedRequest, destination, connections in
                panel?.close()
                Task { @MainActor in
                    let engine = DownloadEngine.shared
                    let dest   = destination
                    let url    = confirmedRequest.url

                    engine.addDownload(
                        urls:        [url],
                        destination: dest,
                        connections: connections,
                        cookies:     confirmedRequest.cookies.isEmpty  ? nil : confirmedRequest.cookies,
                        userAgent:   confirmedRequest.ua.isEmpty       ? nil : confirmedRequest.ua,
                        referer:     confirmedRequest.referer.isEmpty  ? nil : confirmedRequest.referer,
                        filename:    confirmedRequest.filename.isEmpty ? nil : confirmedRequest.filename,
                        youtubeQuality: confirmedRequest.youtubeQuality?.isEmpty == false ? confirmedRequest.youtubeQuality : nil,
                        isHLS:       confirmedRequest.forceHLS,
                        isDASH:      confirmedRequest.forceDASH,
                        browser:     nil,
                        forceDirectDownload: confirmedRequest.forceDirectDownload,
                        ytPoToken:   confirmedRequest.ytPoToken,
                        ytPoTokenVisitor: confirmedRequest.ytPoTokenVisitor,
                        ytVideoUrl:  confirmedRequest.ytVideoUrl,
                        ytAudioUrl:  confirmedRequest.ytAudioUrl,
                        ytVideoMime: confirmedRequest.ytVideoMime,
                        ytAudioMime: confirmedRequest.ytAudioMime,
                        ytHeight:    confirmedRequest.ytHeight,
                        ytTitle:     confirmedRequest.ytTitle
                    )
                    
                    if let newestItem = engine.items.last(where: { $0.url == url }) {
                        newestItem.headers = confirmedRequest.headers
                    }

                    NSApp.activate(ignoringOtherApps: true)
                }
            },
            onCancel: { [weak panel] in
                panel?.close()
            }
        )

        let hostingView = NSHostingView(rootView: confirmView)
        // Allow the hosting view to push the panel to grow when async content
        // (e.g. fetched YouTube quality list) lands after the initial layout.
        if #available(macOS 13.0, *) {
            hostingView.sizingOptions = [.preferredContentSize]
        }
        panel.contentView = hostingView
        panel.setContentSize(hostingView.fittingSize)
        panel.center()
        // orderFrontRegardless guarantees the panel is shown above other apps'
        // windows even if the activation race below loses; makeKeyAndOrderFront
        // promotes it to key so keyboard input lands here.
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Re-assert focus on the next runloop tick. AppKit sometimes drops the
        // first activation request when the call originates from a background
        // network handler (Local server -> NotificationCenter), which is the
        // path used by YouTube and HLS downloads.
        DispatchQueue.main.async { [weak panel] in
            guard let panel else { return }
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        }

        self.confirmPanel = panel
    }
}

extension Notification.Name {
    static let showAddDownload             = Notification.Name("showAddDownload")
    static let openProgressWindow         = Notification.Name("openProgressWindow")
    static let openSelectedProgressWindow = Notification.Name("openSelectedProgressWindow")
    static let requestAddDownload         = Notification.Name("requestAddDownload")
    static let confirmDownload            = Notification.Name("confirmDownload")
    static let showSettings               = Notification.Name("showSettings")
}
