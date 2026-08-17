import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ProgressWindowView: View {
    let item: DownloadItem
    var engine = DownloadEngine.shared
    @Environment(\.dismiss) var dismiss

    @State private var selectedTab  = 0
    @State private var limitEnabled = false
    @State private var limitInput   = ""
    @State private var isPinned     = false
    @State private var now = Date()
    @State private var window: NSWindow?
    
    // For robust Keyboard handling
    @State private var eventMonitor: Any?

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    @AppStorage("accentColorHex") private var accentColorHex = "#0A84FF"
    @AppStorage("matchProgressBarToAccent") private var matchProgressBarToAccent = true
    @AppStorage("progressBarColorHex") private var progressBarColorHex = "#34C759"
    @AppStorage("alwaysPinProgressWindows") private var alwaysPinProgressWindows = false

    private var liveItem: DownloadItem {
        engine.items.first(where: { $0.id == item.id }) ?? item
    }

    var elapsed: TimeInterval {
        if liveItem.status == .completed, let end = liveItem.dateCompleted {
            return end.timeIntervalSince(liveItem.dateAdded)
        }
        if liveItem.status == .stopped || liveItem.status == .failed {
            return liveItem.totalActiveDuration
        }
        return now.timeIntervalSince(liveItem.dateAdded)
    }

    var formattedElapsed: String {
        let s = Int(elapsed)
        if s < 60   { return "\(s)s" }
        if s < 3600 { return "\(s/60)m \(s%60)s" }
        return "\(s/3600)h \((s%3600)/60)m \(s%60)s"
    }
    
    var currentBarColor: Color {
        if liveItem.status == .failed { return .red }
        let hexString = matchProgressBarToAccent ? accentColorHex : progressBarColorHex
        let baseColor = Color(hex: hexString)
        return liveItem.status == .stopped ? baseColor.opacity(0.5) : baseColor
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            statusTab.tabItem     { Text("Status") }.tag(0)
            speedLimitTab.tabItem { Text("Speed Limit") }.tag(1)
        }
        .frame(width: 460)
        .fixedSize(horizontal: true, vertical: true)
        .background(TabBarContextMenuDisabler())
        .background(VisualEffectView(material: .popover, blendingMode: .behindWindow)
            .ignoresSafeArea())
        .background(WindowAccessor(window: $window))
        .onAppear {
            TrayViewModel.shared.removeFromTray(liveItem.id)
            setupWindowSettings()
            setupEventMonitor()
        }
        .onDisappear {
            if let monitor = eventMonitor {
                NSEvent.removeMonitor(monitor)
            }
            if let win = window { removeCustomTrayButton(from: win) }
        }
        .onReceive(timer) { _ in
            now = Date()
            updateTrayButtonVisibility()
        }
        .onChange(of: window) { _, _ in setupWindowSettings() }
        .onChange(of: liveItem.status) { _, _ in updateTrayButtonVisibility() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notif in
            if let obj = notif.object as? NSWindow, obj == window {
                TrayViewModel.shared.removeFromTray(liveItem.id)
                disableProgressTabContextMenu()
            }
        }
    }

    private var canHideToTray: Bool {
        liveItem.status != .completed && liveItem.status != .failed
    }

    private func disableProgressTabContextMenu() {
        guard let win = window, let content = win.contentView else { return }
        func findTabView(_ view: NSView) -> NSTabView? {
            if let tabView = view as? NSTabView { return tabView }
            for subview in view.subviews {
                if let tabView = findTabView(subview) { return tabView }
            }
            return nil
        }
        findTabView(content)?.menu = nil
    }

    private func updateTrayButtonVisibility() {
        guard let win = window else { return }
        if canHideToTray {
            injectTrafficLight(into: win)
        } else {
            removeCustomTrayButton(from: win)
        }
    }

    private func removeCustomTrayButton(from win: NSWindow) {
        let customId = NSUserInterfaceItemIdentifier("CustomMenuTrafficLight")
        func sweep(_ view: NSView) {
            for subview in Array(view.subviews) {
                if subview.identifier == customId {
                    subview.removeFromSuperview()
                } else {
                    sweep(subview)
                }
            }
        }
        if let content = win.contentView { sweep(content) }
        if let titlebar = win.standardWindowButton(.zoomButton)?.superview {
            sweep(titlebar)
        }
    }
    
    private func setupWindowSettings() {
        if liveItem.speedLimit > 0 {
            limitEnabled = true
            limitInput = "\(liveItem.speedLimit)"
        }
        
        if let win = window {
            win.isOpaque = false
            win.backgroundColor = .clear
            win.titlebarAppearsTransparent = true
            win.makeKeyAndOrderFront(nil)
            if alwaysPinProgressWindows || isPinned {
                isPinned = true
                win.level = .floating
            }
            disableProgressTabContextMenu()
            updateTrayButtonVisibility()
        }
    }
    
    private func injectTrafficLight(into win: NSWindow) {
        guard canHideToTray else { return }
        guard let zoomBtn = win.standardWindowButton(.zoomButton),
              let titlebar = zoomBtn.superview else { return }
        
        let customId = NSUserInterfaceItemIdentifier("CustomMenuTrafficLight")
        if titlebar.subviews.contains(where: { $0.identifier == customId }) { return }
        
        let btnFrame = NSRect(
            x: zoomBtn.frame.maxX + 8,
            y: zoomBtn.frame.minY,
            width: zoomBtn.frame.width,
            height: zoomBtn.frame.height
        )
        
        let accentNSColor = NSColor(Color(hex: accentColorHex))
        let btn = HoverTrafficLightButton(frame: btnFrame, itemId: liveItem.id, accentColor: accentNSColor)
        btn.identifier = customId
        btn.target = btn
        btn.action = #selector(HoverTrafficLightButton.performTrayAction)
        btn.toolTip = "Hide to Menu Bar"
        titlebar.addSubview(btn)
    }
    
    private func setupEventMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                dismiss()
                return nil
            }
            if event.keyCode == 49 {
                let responder = window?.firstResponder
                if !(responder is NSTextView || responder is NSTextField) {
                    toggleDownload()
                    return nil
                }
            }
            return event
        }
    }

    private func toggleDownload() {
        if liveItem.status == .downloading || liveItem.status == .queued {
            engine.stop(liveItem)
        } else if liveItem.status == .stopped || liveItem.status == .failed {
            engine.resume(liveItem)
        }
    }

    private func toggleSubFile(_ id: UUID) {
        guard let index = liveItem.subFiles.firstIndex(where: { $0.id == id }) else { return }
        var updated = liveItem.subFiles
        updated[index].isStopped.toggle()
        liveItem.subFiles = updated
        engine.items = engine.items
        
        if liveItem.status == .stopped || liveItem.status == .failed {
            if !liveItem.subFiles[index].isStopped {
                engine.resume(liveItem, resumeSubFiles: false)
            } else {
                engine.persist()
            }
        } else {
            engine.updateTorrentSelection(for: liveItem)
        }
    }

    var statusTab: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                let isBundle = liveItem.type == .torrent || liveItem.type == .batch
                let progressIcon: NSImage = {
                    if isBundle { return SharedIconCache.shared.bundleIcon(size: 40) }
                    let ext  = (liveItem.filename as NSString).pathExtension
                    let type = UTType(filenameExtension: ext) ?? .data
                    return NSWorkspace.shared.icon(for: type)
                }()
                Image(nsImage: progressIcon)
                    .resizable().frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 3) {
                    Text(liveItem.filename)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 6) {
                        StatusPill(status: liveItem.status, accentColorHex: accentColorHex)
                        if liveItem.supportsRanges {
                            Text("Resumable")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.green)
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
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.primary.opacity(0.08))
                            .frame(height: 8)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(currentBarColor)
                            .frame(width: max(0, CGFloat(liveItem.progress) * geo.size.width), height: 8)
                            .animation(.easeInOut(duration: 0.4), value: liveItem.progress)
                    }
                }
                .frame(height: 8)

                HStack {
                    Text(liveItem.transferLabel).font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    if liveItem.totalBytes > 0 || (liveItem.isHLS && liveItem.hlsTotalSeconds > 0) {
                        Text(String(format: "%.1f%%", liveItem.progress * 100))
                            .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    }
                }
            }
            .padding(.horizontal, 16)

            Divider().padding(.vertical, 10)

            HStack(spacing: 8) {
                ActiveStatCell(label: "Speed",     value: liveItem.status == .downloading ? liveItem.formattedSpeed : "0B/s")
                ActiveStatCell(label: "ETA",       value: liveItem.formattedETA ?? "0s")
                ActiveStatCell(label: "Elapsed",   value: formattedElapsed)
                ActiveStatCell(label: "Remaining", value: remainingSize)
            }
            .padding(.horizontal, 16)

            if !liveItem.subFiles.isEmpty {
                Divider().padding(.vertical, 10)
                VStack(alignment: .leading, spacing: 4) {
                    Text(liveItem.type == .batch ? "Batch Items" : "Files")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 16)
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(spacing: 10) {
                            ForEach(liveItem.subFiles) { file in
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(file.filename)
                                            .font(.system(size: 11))
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        GeometryReader { geo in
                                            ZStack(alignment: .leading) {
                                                RoundedRectangle(cornerRadius: 2)
                                                    .fill(Color.primary.opacity(0.08))
                                                let fileProgress = file.totalBytes > 0 ? min(1.0, max(0.0, Double(file.downloadedBytes) / Double(file.totalBytes))) : 0.0
                                                RoundedRectangle(cornerRadius: 2)
                                                    .fill(currentBarColor)
                                                    .frame(width: max(0, CGFloat(fileProgress) * geo.size.width))
                                            }
                                        }
                                        .frame(height: 4)
                                    }
                                    
                                    VStack(alignment: .trailing, spacing: 2) {
                                        let filePercentage = file.totalBytes > 0 ? (Double(file.downloadedBytes) / Double(file.totalBytes)) * 100 : 0
                                        Text(String(format: "%.1f%%", filePercentage))
                                            .font(.system(size: 10, weight: .semibold))
                                            .monospacedDigit()
                                        Text(file.totalBytes > 0 ? "\(formatBytes(file.downloadedBytes)) / \(formatBytes(file.totalBytes))" : formatBytes(file.downloadedBytes))
                                            .font(.system(size: 9))
                                            .foregroundStyle(.secondary)
                                    }
                                    .frame(width: 80, alignment: .trailing)
                                    
                                    let isFinished = file.totalBytes > 0 && file.downloadedBytes >= file.totalBytes
                                    if isFinished {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 14))
                                            .foregroundStyle(Color(hex: progressBarColorHex))
                                            .frame(width: 44, alignment: .trailing)
                                    } else if liveItem.type == .torrent || liveItem.type == .batch {
                                        let isEffectivelyPaused = liveItem.status == .stopped || liveItem.status == .failed || liveItem.subFiles.first(where: { $0.id == file.id })?.isStopped == true
                                        Button {
                                            toggleSubFile(file.id)
                                        } label: {
                                            Image(systemName: isEffectivelyPaused ? "play.circle.fill" : "pause.circle.fill")
                                                .font(.system(size: 14))
                                                .foregroundStyle(isEffectivelyPaused ? .secondary : Color(hex: accentColorHex))
                                        }
                                        .buttonStyle(.plain)
                                        .frame(width: 44, alignment: .trailing)
                                    } else {
                                        Spacer().frame(width: 44)
                                    }
                                }
                                .id("\(file.id)-\(file.downloadedBytes)-\(file.totalBytes)-\(liveItem.subFiles.first(where: { $0.id == file.id })?.isStopped == true)")
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .frame(maxHeight: 120)
                }
            }

            if liveItem.status == .completed {
                Divider().padding(.vertical, 10)
                DragOutBoxView(fileURL: liveItem.destinationURL, accentColorHex: accentColorHex)
                    .padding(.horizontal, 16)
            }

            Divider().padding(.vertical, 10)

            VStack(alignment: .leading, spacing: 4) {
                Text("Source")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                let lineHeight: CGFloat = 11 * 1.35
                ScrollView(.vertical, showsIndicators: true) {
                    Text(liveItem.url.absoluteString)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(.trailing, 8)
                }
                .frame(maxHeight: lineHeight * 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            Divider()

            HStack(spacing: 8) {
                if liveItem.status == .downloading || liveItem.status == .queued {
                    Button(action: { engine.stop(liveItem) }) {
                        Label("Pause", systemImage: "pause.fill")
                    }
                    .buttonStyle(ActionButtonStyle(prominent: true, hex: accentColorHex))
                    Button(action: { engine.stop(liveItem); dismiss() }) {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(ActionButtonStyle(prominent: false, hex: accentColorHex))
                } else if liveItem.status == .stopped || liveItem.status == .failed {
                    Button(action: { engine.resume(liveItem) }) {
                        Label("Resume", systemImage: "play.fill")
                    }
                    .buttonStyle(ActionButtonStyle(prominent: true, hex: accentColorHex))
                    Button(action: { engine.stop(liveItem); dismiss() }) {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(ActionButtonStyle(prominent: false, hex: accentColorHex))
                } else if liveItem.status == .completed {
                    Button(action: { NSWorkspace.shared.open(liveItem.destinationURL); dismiss() }) {
                        Label("Open File", systemImage: "doc.text.magnifyingglass")
                    }
                    .buttonStyle(ActionButtonStyle(prominent: true, hex: accentColorHex))
                    Button(action: { NSWorkspace.shared.activateFileViewerSelecting([liveItem.destinationURL]); dismiss() }) {
                        Label("Reveal in Finder", systemImage: "folder")
                    }
                    .buttonStyle(ActionButtonStyle(prominent: false, hex: accentColorHex))
                }
                Spacer()
                Button(action: { dismiss() }) {
                    Label(liveItem.status == .completed ? "Close" : "Hide", systemImage: liveItem.status == .completed ? "xmark" : "eye.slash")
                }
                .buttonStyle(ActionButtonStyle(prominent: false, hex: accentColorHex))
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
            window?.level = isPinned ? .floating : .normal
        } label: {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.system(size: 13))
                .foregroundStyle(isPinned ? Color(hex: accentColorHex) : .secondary)
        }
        .buttonStyle(.plain).help("Always on top")
    }

    var remainingSize: String {
        if liveItem.isHLS && liveItem.hlsTotalSeconds > 0 {
            let remSeconds = max(0, liveItem.hlsTotalSeconds - liveItem.hlsDownloadedSeconds)
            return formatDuration(remSeconds)
        }
        guard liveItem.totalBytes > 0 else { return "0MB" }
        let rem = liveItem.totalBytes - liveItem.downloadedBytes
        guard rem > 0 else { return "0Mb" }
        return formatBytes(rem)
    }

    func applyLimit(enabled: Bool, input: String) {
        if !enabled { engine.updateSpeedLimit(for: liveItem, limitKB: 0) }
        else if let val = Int(input), val > 0 { engine.updateSpeedLimit(for: liveItem, limitKB: val) }
    }
}


// MARK: - Subcomponents

struct ActiveStatCell: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(NSColor.separatorColor).opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct DragOutBoxView: View {
    let fileURL: URL
    let accentColorHex: String

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color(hex: accentColorHex).opacity(0.1))
                    .frame(width: 36, height: 36)
                Image(systemName: "hand.draw.fill")
                    .font(.system(size: 16))
                    .foregroundColor(Color(hex: accentColorHex))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Drag to Move File")
                    .font(.system(size: 12, weight: .semibold))
                Text("Drop into Finder or another application")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(Color.primary.opacity(0.03))
        .contentShape(Rectangle())
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4]))
                .foregroundColor(Color(hex: accentColorHex).opacity(0.4))
        )
        .overlay(MoveDragSourceView(fileURL: fileURL))
    }
}

struct MoveDragSourceView: NSViewRepresentable {
    let fileURL: URL
    func makeNSView(context: Context) -> DragSourceNSView {
        let view = DragSourceNSView()
        view.fileURL = fileURL
        return view
    }
    func updateNSView(_ nsView: DragSourceNSView, context: Context) {
        nsView.fileURL = fileURL
    }
}

class DragSourceNSView: NSView, NSDraggingSource {
    var fileURL: URL?
    var isDragging = false
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }
    override func resetCursorRects() { super.resetCursorRects(); addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {
        guard !isDragging, let fileURL = fileURL else { return }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        isDragging = true
        let icon = NSWorkspace.shared.icon(forFile: fileURL.path)
        icon.size = NSSize(width: 48, height: 48)
        let dragPoint = convert(event.locationInWindow, from: nil)
        let dragFrame = NSRect(x: dragPoint.x - 24, y: dragPoint.y - 24, width: 48, height: 48)
        let draggingItem = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
        draggingItem.setDraggingFrame(dragFrame, contents: icon)
        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .every }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { isDragging = false }
}

class HoverTrafficLightButton: NSButton {
    let itemId: UUID
    let accentColor: NSColor
    init(frame frameRect: NSRect, itemId: UUID, accentColor: NSColor) {
        self.itemId = itemId
        self.accentColor = accentColor
        super.init(frame: frameRect)
        wantsLayer = true
        isBordered = false
        title = ""
        layer?.cornerRadius = frameRect.width / 2
        layer?.backgroundColor = accentColor.withAlphaComponent(0.6).cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.black.withAlphaComponent(0.12).cgColor
        let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
        self.image = NSImage(systemSymbolName: "arrow.down.to.line", accessibilityDescription: nil)?.withSymbolConfiguration(config)
        self.contentTintColor = .clear
        self.imagePosition = .imageOnly
        let tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(tracking)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func performTrayAction() {
        TrayViewModel.shared.addToTray(itemId)
        self.window?.orderOut(nil)
    }
    override func mouseEntered(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            self.layer?.backgroundColor = accentColor.cgColor
            self.animator().contentTintColor = NSColor(Color(nsColor: accentColor).accessibleText)
        }
    }
    override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            self.animator().contentTintColor = .clear
            self.layer?.backgroundColor = accentColor.withAlphaComponent(0.6).cgColor
        }
    }
}
