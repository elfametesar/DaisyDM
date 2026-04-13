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
            // Overrides the native macOS Settings menu so it opens as a blocking sheet
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    NotificationCenter.default.post(name: .showSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            
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

        // Removed the standalone Settings{} block because it allows background clicking

        WindowGroup(for: UUID.self) { $id in
            if let id = id, let item = DownloadEngine.shared.items.first(where: { $0.id == id }) {
                ProgressWindowView(item: item)
                    .navigationTitle(item.status == .completed ? "Download complete" : (item.status == .failed ? "Download failed" : "Daisy"))
            }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 460, height: 370)
        .windowResizability(.contentSize)
    }
}

// MARK: - WindowAccessor

struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { self.window = view.window }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - ProgressWindowView

struct ProgressWindowView: View {
    let item: DownloadItem
    var engine = DownloadEngine.shared
    @Environment(\.dismiss) var dismiss

    @State private var selectedTab    = 0
    @State private var limitEnabled   = false
    @State private var limitInput     = ""
    @State private var isPinned       = false
    @State private var hostingWindow: NSWindow?
    @State private var now            = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var elapsed: TimeInterval { now.timeIntervalSince(item.dateAdded) }

    var formattedElapsed: String {
        let s = Int(elapsed)
        if s < 60   { return "\(s)s" }
        if s < 3600 { return "\(s/60)m \(s%60)s" }
        return "\(s/3600)h \((s%3600)/60)m \(s%60)s"
    }

    var body: some View {
        Group {
            if item.status == .completed { completedView }
            else if item.status == .failed { failedView }
            else                         { activeView }
        }
        .background(WindowAccessor(window: $hostingWindow))
        .onAppear {
            if item.speedLimit > 0 { limitEnabled = true; limitInput = "\(item.speedLimit)" }
        }
        .onReceive(timer) { _ in now = Date() }
    }

    // ── Completed ──────────────────────────────────────────────────────
    var completedView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                let ext  = (item.filename as NSString).pathExtension
                let type = UTType(filenameExtension: ext) ?? .data
                Image(nsImage: NSWorkspace.shared.icon(for: type))
                    .resizable().frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.filename)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle)
                    Text("Download Complete")
                        .font(.system(size: 12)).foregroundStyle(.green)
                }
                Spacer()
                pinButton
            }
            .padding(16)

            Divider()

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 0) {
                CompletedStatCell(label: "File Size",  value: item.formattedSize)
                CompletedStatCell(label: "Downloaded", value: item.formattedDownloaded)
                CompletedStatCell(label: "Started",    value: shortDate(item.dateAdded))
                CompletedStatCell(label: "Finished",   value: shortDate(item.dateCompleted ?? Date()))
                if let done = item.dateCompleted {
                    CompletedStatCell(label: "Duration", value: formatDur(done.timeIntervalSince(item.dateAdded)))
                }
                if let mime = item.mimeType, !mime.isEmpty {
                    CompletedStatCell(label: "Type", value: mime)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                PwRow(label: "URL",     value: item.url.absoluteString)
                PwRow(label: "Saved to", value: item.destinationURL.path(percentEncoded: false))
            }
            .padding(16)

            Divider()

            HStack(spacing: 8) {
                Button("Open") { NSWorkspace.shared.open(item.destinationURL); dismiss() }
                Menu("Open with…") {
                    let appURLs = NSWorkspace.shared.urlsForApplications(toOpen: item.destinationURL)
                    ForEach(appURLs, id: \.self) { appURL in
                        Button(appURL.deletingPathExtension().lastPathComponent) {
                            NSWorkspace.shared.open([item.destinationURL], withApplicationAt: appURL,
                                                    configuration: NSWorkspace.OpenConfiguration())
                            dismiss()
                        }
                    }
                    Divider()
                    Button("Other…") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.application]
                        if panel.runModal() == .OK, let appURL = panel.url {
                            NSWorkspace.shared.open([item.destinationURL], withApplicationAt: appURL,
                                                    configuration: NSWorkspace.OpenConfiguration())
                            dismiss()
                        }
                    }
                }
                .frame(width: 100)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.destinationURL]); dismiss() }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.escape)
            }
            .padding(16)
        }
        .frame(width: 460)
    }

    // ── Failed ─────────────────────────────────────────────────────────
    var failedView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                let ext  = (item.filename as NSString).pathExtension
                let type = UTType(filenameExtension: ext) ?? .data
                Image(nsImage: NSWorkspace.shared.icon(for: type))
                    .resizable().frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.filename)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle)
                    Text("Download Failed")
                        .font(.system(size: 12)).foregroundStyle(.red)
                }
                Spacer()
                pinButton
            }
            .padding(16)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        .font(.system(size: 16))
                        .padding(.top, 2)
                    Text(item.error ?? "An unknown error occurred.")
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(16)

            Divider()
            
            VStack(alignment: .leading, spacing: 6) {
                PwRow(label: "URL",     value: item.url.absoluteString)
                PwRow(label: "Saved to", value: item.destinationURL.path(percentEncoded: false))
            }
            .padding(16)

            Spacer()
            Divider()

            HStack(spacing: 8) {
                Button("Retry") { engine.retry(item) }.buttonStyle(.borderedProminent)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.escape)
            }
            .padding(16)
        }
        .frame(width: 460)
    }

    // ── Active ─────────────────────────────────────────────────────────
    var activeView: some View {
        TabView(selection: $selectedTab) {
            statusTab.tabItem      { Text("Status") }.tag(0)
            speedLimitTab.tabItem  { Text("Speed Limit") }.tag(1)
        }
        .frame(width: 460, height: 370)
    }

    var statusTab: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                let ext  = (item.filename as NSString).pathExtension
                let type = UTType(filenameExtension: ext) ?? .data
                Image(nsImage: NSWorkspace.shared.icon(for: type))
                    .resizable().frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.filename)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 6) {
                        StatusPill(status: item.status)
                        if item.supportsRanges {
                            Text("Resumable")
                                .font(.system(size: 10, weight: .medium)).foregroundStyle(.green)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(Color.green.opacity(0.1), in: Capsule())
                        }
                    }
                }
                Spacer()
                pinButton
            }
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)

            VStack(spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.08)).frame(height: 8)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(item.status == .stopped ? Color.orange : Color.blue)
                            .frame(width: max(0, CGFloat(item.progress) * geo.size.width), height: 8)
                            .animation(.easeInOut(duration: 0.4), value: item.progress)
                    }
                }
                .frame(height: 8)
                HStack {
                    Text(item.transferLabel).font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    if item.totalBytes > 0 {
                        Text(String(format: "%.1f%%", item.progress * 100))
                            .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    }
                }
            }
            .padding(.horizontal, 16)

            Divider().padding(.vertical, 10)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ActiveStatCell(label: "Speed",       value: item.status == .downloading ? item.formattedSpeed : "–")
                ActiveStatCell(label: "ETA",         value: item.formattedETA ?? "–")
                ActiveStatCell(label: "Connections", value: "\(item.connectionCount)")
                ActiveStatCell(label: "Started",     value: shortDate(item.dateAdded))
                ActiveStatCell(label: "Elapsed",     value: formattedElapsed)
                ActiveStatCell(label: "Remaining",   value: remainingSize)
            }
            .padding(.horizontal, 16)

            Divider().padding(.vertical, 10)

            VStack(alignment: .leading, spacing: 4) {
                Text("Source")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                Text(item.url.absoluteString)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)

            Spacer()
            Divider()

            HStack(spacing: 8) {
                if item.status == .downloading || item.status == .queued {
                    Button { engine.stop(item) } label: {
                            Label("Pause", systemImage: "")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(minWidth: 50)
                                .padding(.vertical, 4)
                                .padding(.horizontal, 12)
                                .background(Color.accentColor)
                                .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                } else if item.status == .stopped || item.status == .failed {
                    Button { engine.resume(item) } label: {
                            Label("Resume", systemImage: "")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(minWidth: 50)
                                .padding(.vertical, 4)
                                .padding(.horizontal, 12)
                                .background(Color.accentColor)
                                .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                } else {
                    Button("Pause") {}.disabled(true)
                }
                Button("Stop") { engine.stop(item); dismiss() }
                Spacer()
                Button("Hide") { dismiss() }.keyboardShortcut(.escape)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
    }

    var speedLimitTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            Toggle("Enable Speed Limit for this download", isOn: $limitEnabled)
                .onChange(of: limitEnabled) { _, enabled in applyLimit(enabled: enabled, input: limitInput) }
            HStack {
                Text("Maximum download speed:")
                TextField("e.g. 500", text: $limitInput)
                    .textFieldStyle(.roundedBorder).frame(width: 80)
                    .onChange(of: limitInput) { _, val in applyLimit(enabled: limitEnabled, input: val) }
                Text("KB/s")
            }
            .disabled(!limitEnabled)
            Spacer()
        }
        .padding(24)
    }

    var pinButton: some View {
        Button {
            isPinned.toggle()
            hostingWindow?.level = isPinned ? .floating : .normal
        } label: {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.system(size: 13))
                .foregroundStyle(isPinned ? .blue : .secondary)
        }
        .buttonStyle(.plain).help("Always on top")
    }

    var remainingSize: String {
        guard item.totalBytes > 0 else { return "–" }
        let rem = item.totalBytes - item.downloadedBytes
        guard rem > 0 else { return "–" }
        return formatBytes(rem)
    }

    func applyLimit(enabled: Bool, input: String) {
        if !enabled { engine.updateSpeedLimit(for: item, limitKB: 0) }
        else if let val = Int(input), val > 0 { engine.updateSpeedLimit(for: item, limitKB: val) }
    }

    func shortDate(_ date: Date) -> String {
        let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .medium
        return f.string(from: date)
    }

    func formatDur(_ t: TimeInterval) -> String {
        let s = Int(t)
        if s < 60   { return "\(s)s" }
        if s < 3600 { return "\(s/60)m \(s%60)s" }
        return "\(s/3600)h \((s%3600)/60)m \(s%60)s"
    }
}

// MARK: - Stat cells / rows

struct ActiveStatCell: View {
    let label: String; let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 10)).foregroundStyle(.tertiary)
            Text(value).font(.system(size: 13, weight: .semibold)).monospacedDigit().lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(NSColor.separatorColor).opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct CompletedStatCell: View {
    let label: String; let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 10)).foregroundStyle(.tertiary)
            Text(value).font(.system(size: 12, weight: .medium)).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }
}

struct PwRow: View {
    let label: String; let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            Text(value).font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
        }
    }
}

// MARK: - AppDelegate

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

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            SFSafariApplication.showPreferencesForExtension(
                withIdentifier: self.safariExtensionBundleIdentifier
            ) { error in
                if let error {
                    NSLog("Failed to open Safari extension prefs: %@", error.localizedDescription)
                }
            }
        }

        confirmObserver = NotificationCenter.default.addObserver(
            forName: .confirmDownload,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard
                let info     = note.userInfo,
                let url      = info["url"]      as? URL,
                let filename = info["filename"] as? String,
                let cookies  = info["cookies"]  as? String,
                let referer  = info["referer"]  as? String,
                let ua       = info["ua"]       as? String
            else { return }

            let request = ConfirmDownloadRequest(
                url:      url,
                filename: filename,
                cookies:  cookies,
                referer:  referer,
                ua:       ua
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

    // MARK: - IDM-style confirmation panel

    private func presentConfirmPanel(request: ConfirmDownloadRequest) {
        confirmPanel?.close()
        confirmPanel = nil

        let panel = NSPanel(
            contentRect:  NSRect(x: 0, y: 0, width: 460, height: 1),
            styleMask:    [.titled, .closable, .fullSizeContentView],
            backing:      .buffered,
            defer:        false
        )
        panel.title                  = "Download"
        panel.titlebarAppearsTransparent = false
        panel.isMovableByWindowBackground = true
        panel.level                  = .floating // Intentionally floating (doesn't block app interactability)
        panel.isReleasedWhenClosed   = false

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
                        filename:    confirmedRequest.filename.isEmpty ? nil : confirmedRequest.filename
                    )
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

// MARK: - Notification names

extension Notification.Name {
    static let showAddDownload             = Notification.Name("showAddDownload")
    static let openProgressWindow         = Notification.Name("openProgressWindow")
    static let openSelectedProgressWindow = Notification.Name("openSelectedProgressWindow")
    static let requestAddDownload         = Notification.Name("requestAddDownload")
    static let confirmDownload            = Notification.Name("confirmDownload")
    static let showSettings               = Notification.Name("showSettings") // Added
}
