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
            
            // Extract the headers dictionary from the notification info payload
            let headers = info["headers"] as? [String: String] ?? [:]

            let request = ConfirmDownloadRequest(
                url:      url,
                filename: filename,
                headers:  headers, // <-- Corrected: Use the extracted local 'headers' variable
                cookies:  cookies,
                referer:  referer,
                ua:       ua,
                forceHLS: forceHLS,
                forceDASH: forceDASH,
                forceDirectDownload: forceDirectDownload,
                youtubeQuality: youtubeQuality
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
        for url in urls where url.scheme == URLSchemeHandler.scheme {
            URLSchemeHandler.handle(url)
        }
    }

    private func presentConfirmPanel(request: ConfirmDownloadRequest) {
        confirmPanel?.close()
        confirmPanel = nil

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
                        forceDirectDownload: confirmedRequest.forceDirectDownload
                    )
                    
                    // Inject custom captured headers (like X-Playback-Session-Id)
                    // directly into the newly created DownloadItem
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

        panel.contentView = NSHostingView(rootView: confirmView)
        panel.setContentSize(panel.contentView!.fittingSize)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

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
