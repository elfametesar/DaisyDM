import SwiftUI
import AppKit

struct RightClickModifier: ViewModifier {
    let action: () -> Void
    func body(content: Content) -> some View {
        content.background(RightClickCatcher(action: action))
    }
}

struct RightClickCatcher: NSViewRepresentable {
    let action: () -> Void
    func makeNSView(context: Context) -> RightClickCatcherView {
        let view = RightClickCatcherView()
        view.onRightClick = action
        return view
    }
    func updateNSView(_ nsView: RightClickCatcherView, context: Context) {
        nsView.onRightClick = action
    }
}

class RightClickCatcherView: NSView {
    var onRightClick: (() -> Void)?
    
    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
        super.rightMouseDown(with: event)
    }
    
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent, event.type == .rightMouseDown else { return nil }
        return bounds.contains(point) ? self : nil
    }
}

extension View {
    func onRightClick(perform action: @escaping () -> Void) -> some View {
        self.modifier(RightClickModifier(action: action))
    }
}

struct DownloadListView: View {
    let items: [DownloadItem]
    @Binding var selected: Set<UUID>
    @Binding var search: String
    var engine = DownloadEngine.shared

    let onRequestRemove: ([DownloadItem]) -> Void

    @State private var lastSelectedIndex: Int? = nil
    @State private var propertiesItem: DownloadItem? = nil
    @FocusState private var isSearchFocused: Bool
    
    @AppStorage("accentColorHex") private var accentColorHex = "#0A84FF"
    @AppStorage("enableBackgroundTint") private var enableBackgroundTint = false

    var body: some View {
        VStack(spacing: 0) {
            ColumnHeader()
            mainContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    @ViewBuilder
    private var mainContent: some View {
        ZStack(alignment: .bottom) {
            if items.isEmpty && search.isEmpty {
                EmptyListPlaceholder()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(enableBackgroundTint ? Color(hex: accentColorHex).opacity(0.04) : Color(NSColor.controlBackgroundColor))
            } else if items.isEmpty && !search.isEmpty {
                ContentUnavailableView.search(text: search)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(enableBackgroundTint ? Color(hex: accentColorHex).opacity(0.04) : Color(NSColor.controlBackgroundColor))
            } else {
                scrollableList
            }
            
            if !engine.items.isEmpty || !search.isEmpty {
                searchBarContainer
            }
        }
    }
    
    private var scrollableList: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 0) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            DownloadRow(
                                item: item,
                                isSelected: selected.contains(item.id)
                            )
                            .contentShape(Rectangle())
                            .onRightClick {
                                if !selected.contains(item.id) {
                                    selected = [item.id]
                                    lastSelectedIndex = index
                                }
                            }
                            .onTapGesture { handleRowTap(item: item, index: index) }
                            .contextMenu { rowContextMenu(item) }

                            Divider().padding(.leading, 12)
                        }
                    }
                    Spacer(minLength: 90)
                }
                .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .top)
                .contentShape(Rectangle())
                .onTapGesture {
                    selected.removeAll()
                    lastSelectedIndex = nil
                }
            }
        }
        .background(enableBackgroundTint ? Color(hex: accentColorHex).opacity(0.04) : Color(NSColor.controlBackgroundColor))
        .sheet(item: $propertiesItem) { item in
            PropertiesSheet(item: item)
        }
        .onKeyPress(.init("a"), phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            selected = Set(items.map { $0.id })
            return .handled
        }
        .onDeleteCommand {
            let toDelete = engine.items.filter { selected.contains($0.id) }
            guard !toDelete.isEmpty else { return }
            onRequestRemove(toDelete)
        }
    }
    
    private var searchBarContainer: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 16, weight: .medium))
            
            TextField("Search Downloads...", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($isSearchFocused)
            
            searchActionButtons
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(LiquidGlassBackground())
        .padding(.horizontal, 40)
        .padding(.bottom, 24)
    }

    @ViewBuilder
    private var searchActionButtons: some View {
        if !search.isEmpty {
            Button { search = "" } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .focusable(false)
        } else {
            dictationButton
        }
    }

    private var dictationButton: some View {
        Button {
            isSearchFocused = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                NSApp.sendAction(Selector(("startDictation:")), to: nil, from: nil)
            }
        } label: {
            Image(systemName: "mic.fill")
                .foregroundStyle(.secondary)
                .font(.system(size: 16))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help("Start Dictation")
    }
    
    private func handleRowTap(item: DownloadItem, index: Int) {
        let event = NSApp.currentEvent
        let flags = event?.modifierFlags ?? []
        let isDoubleClick = event?.clickCount == 2
        
        if isDoubleClick {
            if item.status == .completed { NSWorkspace.shared.open(item.destinationURL)
            } else {
                propertiesItem = item
            }
            return
        }
        
        if flags.contains(.command) {
            if selected.contains(item.id) { selected.remove(item.id) }
            else { selected.insert(item.id) }
            lastSelectedIndex = index
        } else if flags.contains(.shift) {
            guard let last = lastSelectedIndex, last < items.count else {
                selected = [item.id]
                lastSelectedIndex = index
                return
            }
            let range = min(last, index)...max(last, index)
            selected = Set(items[range].map { $0.id })
        } else {
            selected = [item.id]
            lastSelectedIndex = index
        }
    }

    @ViewBuilder
    func rowContextMenu(_ item: DownloadItem) -> some View {
        let targetItems = selected.contains(item.id)
            ? engine.items.filter { selected.contains($0.id) }
            : [item]

        if targetItems.contains(where: { $0.status == .downloading || $0.status == .queued }) {
            Button("Stop") { targetItems.forEach { engine.stop($0) } }
        }
        
        if targetItems.contains(where: { $0.status == .stopped || $0.status == .failed }) {
            Button("Resume") { targetItems.forEach { engine.resume($0) } }
        }
        
        if targetItems.contains(where: { $0.status == .completed || $0.status == .failed }) {
            Button("Restart Download") { targetItems.forEach { engine.retry($0) } }
        }

        Divider()

        if targetItems.count == 1, let single = targetItems.first {
            if single.status == .downloading || single.status == .queued {
                Button("Show Progress Window") {
                    NotificationCenter.default.post(name: .openProgressWindow, object: nil, userInfo: ["id": single.id])
                }
            }
            
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([single.destinationURL]) }
            
            if single.status == .completed {
                Button("Open File") { NSWorkspace.shared.open(single.destinationURL) }
                
                Menu("Open With") {
                    let appURLs = NSWorkspace.shared.urlsForApplications(toOpen: single.destinationURL)
                    ForEach(appURLs, id: \.self) { appURL in
                        Button(appURL.deletingPathExtension().lastPathComponent) {
                            NSWorkspace.shared.open([single.destinationURL], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
                        }
                    }
                    Divider()
                    Button("Other...") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.application]
                        if panel.runModal() == .OK, let appURL = panel.url {
                            NSWorkspace.shared.open([single.destinationURL], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
                        }
                    }
                }
            }
            
            Button("Copy URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(single.url.absoluteString, forType: .string)
            }
            
            Divider()
            Button("Remove", role: .destructive) { onRequestRemove(targetItems) }
            Divider()
            Button("Properties") { propertiesItem = single }
            
        } else if targetItems.count > 1 {
            if targetItems.allSatisfy({ $0.status == .completed }) {
                Button("Open Files") {
                    targetItems.forEach { NSWorkspace.shared.open($0.destinationURL) }
                }
            }
            Divider()
            Button("Remove Selected", role: .destructive) { onRequestRemove(targetItems) }
        }
    }
}

struct LiquidGlassBackground: View {
@State private var shimmerPhase: CGFloat = -1.0

var body: some View {
    ZStack {
        Capsule().fill(.ultraThinMaterial.opacity(0.80))
        
        GeometryReader { geo in
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .white.opacity(0.3), location: 0.4),
                    .init(color: .white.opacity(0.7), location: 0.5),
                    .init(color: .white.opacity(0.3), location: 0.6),
                    .init(color: .clear, location: 1.0)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .frame(width: geo.size.width * 2)
            .offset(x: geo.size.width * shimmerPhase)
            .blendMode(.plusLighter)
        }
        .clipShape(Capsule())
        .onAppear {
            withAnimation(.linear(duration: 4.5).repeatForever(autoreverses: false)) {
                shimmerPhase = 1.0
            }
        }
        
        Capsule()
            .fill(
                LinearGradient(colors: [.white.opacity(0.9), .white.opacity(0.1), .clear], startPoint: .top, endPoint: .bottom)
            )
            .padding(1.5)
        
        Capsule()
            .strokeBorder(
                LinearGradient(colors: [.white.opacity(1.0), .white.opacity(0.2), .black.opacity(0.05), .white.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing),
                lineWidth: 1.5
            )
    }
    .shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 6)
    .shadow(color: .black.opacity(0.04), radius: 3, x: 0, y: 1)
}
}

struct ColumnHeader: View {
    @AppStorage("accentColorHex") private var accentColorHex = "#0A84FF"
    @AppStorage("enableBackgroundTint") private var enableBackgroundTint = false

    var body: some View {
        HStack(spacing: 0) {
            Text("Name").frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
            Text("Status").frame(width: 105, alignment: .leading)
            Text("Transfer").frame(width: 140, alignment: .leading)
            Text("Type").frame(width: 100, alignment: .leading)
            Text("Speed").frame(width: 75, alignment: .leading)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(enableBackgroundTint ? Color(hex: accentColorHex).opacity(0.04) : Color(NSColor.controlBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct DownloadRow: View {
    let item: DownloadItem
    let isSelected: Bool

    @AppStorage("isCompactList") private var isCompactList = false
    @AppStorage("accentColorHex") private var accentColorHex = "#0A84FF"
    @AppStorage("progressBarColorHex") private var progressBarColorHex = "#34C759"
    @AppStorage("matchProgressBarToAccent") private var matchProgressBarToAccent = false
    
    @State private var isExpanded = false
    var engine = DownloadEngine.shared

    var dragPayload: URL {
        if item.status == .completed && FileManager.default.fileExists(atPath: item.destinationURL.path) {
            return item.destinationURL
        }
        return item.url
    }
    
    var fileIcon: NSImage {
        let ext = (item.filename as NSString).pathExtension
        return ext.isEmpty ? NSWorkspace.shared.icon(forFileType: "public.data") : NSWorkspace.shared.icon(forFileType: ext)
    }

    var dynamicTextColor: Color {
        isSelected ? Color(hex: accentColorHex).accessibleText : .primary
    }

    var body: some View {
        VStack(spacing: 0) {
            mainRow
            
            if isExpanded && (item.type == .torrent || item.type == .batch) && !item.subFiles.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(item.subFiles.enumerated()), id: \.element.id) { index, file in
                        HStack(spacing: 12) {
                            Image(systemName: "doc")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            
                            Text(file.filename)
                                .font(.system(size: 12))
                                .foregroundStyle(isSelected ? dynamicTextColor.opacity(0.9) : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            
                            Text(formatBytes(file.downloadedBytes) + (file.totalBytes > 0 ? " / " + formatBytes(file.totalBytes) : ""))
                                .font(.system(size: 10))
                                .foregroundStyle(isSelected ? dynamicTextColor.opacity(0.7) : .secondary)
                                .frame(width: 110, alignment: .trailing)
                            
                            if item.type == .torrent {
                                Button(action: {
                                    item.subFiles[index].isStopped.toggle()
                                    engine.updateTorrentSelection(for: item)
                                }) {
                                    Image(systemName: file.isStopped ? "play.circle.fill" : "pause.circle.fill")
                                        .font(.system(size: 14))
                                        .foregroundStyle(file.isStopped ? Color.orange : Color(hex: accentColorHex))
                                }
                                .buttonStyle(.plain)
                            } else {
                                Spacer().frame(width: 14)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .padding(.leading, 30)
                        .background(Color.black.opacity(isSelected ? 0.1 : 0.03))
                        
                        if index < item.subFiles.count - 1 {
                            Divider().padding(.leading, 42)
                        }
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .background(isSelected ? Color(hex: accentColorHex) : Color.clear)
        .draggable(dragPayload)
    }
    
    var mainRow: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                if (item.type == .torrent || item.type == .batch) && (!item.subFiles.isEmpty || item.status == .downloading) {
                    Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() } }) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(isSelected ? dynamicTextColor : .secondary)
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                } else {
                }
                
                Image(nsImage: fileIcon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.filename)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(isSelected ? dynamicTextColor : .primary)
                    Text(item.type == .batch ? "\(item.subFiles.count) Sub-files" : (item.url.host ?? item.url.absoluteString))
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? dynamicTextColor.opacity(0.7) : .secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            StatusPill(status: item.status, isSelected: isSelected, accentColorHex: accentColorHex)
                .frame(width: 105, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.primary.opacity(isSelected ? 0.2 : 0.1))
                            .frame(height: 4)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(progressColor)
                            .frame(width: max(0, CGFloat(item.progress) * geo.size.width), height: 4)
                    }
                }
                .frame(height: 4)
                Text(item.transferLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? dynamicTextColor.opacity(0.8) : .secondary)
            }
            .frame(width: 140, alignment: .leading)
            .padding(.trailing, 8)

            Text(item.type.rawValue)
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? dynamicTextColor.opacity(0.85) : .primary)
                .lineLimit(1)
                .frame(width: 100, alignment: .leading)

            Text(item.status == .downloading ? item.formattedSpeed : "–")
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? dynamicTextColor.opacity(0.85) : .secondary)
                .frame(width: 75, alignment: .leading)

        }
        .padding(.horizontal, 12)
        .padding(.vertical, isCompactList ? 4 : 9)
    }

    var progressColor: Color {
        if isSelected { return Color(hex: accentColorHex).accessibleText }
        switch item.status {
        case .downloading, .completed, .failed, .stopped:
            return matchProgressBarToAccent ? Color(hex: accentColorHex) : Color(hex: progressBarColorHex)
        default: return .secondary
        }
    }
}

// MARK: - Updated Status Pill
struct StatusPill: View {
    let status: DownloadStatus
    var isSelected: Bool = false
    var accentColorHex: String = "#0A84FF"
    
    @AppStorage("matchBadgesToAccent") private var matchBadgesToAccent = false
    @AppStorage("completedColorHex")   private var completedColorHex   = "#34C759"
    @AppStorage("failedColorHex")      private var failedColorHex      = "#FF3B30"
    @AppStorage("downloadingColorHex") private var downloadingColorHex = "#0A84FF"
    @AppStorage("stoppedColorHex")     private var stoppedColorHex     = "#FF9500"
    
    @Environment(\.colorScheme) private var colorScheme
    
    var dynamicTextColor: Color {
        isSelected ? Color(hex: accentColorHex).accessibleText : labelColor
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(isSelected ? dynamicTextColor.opacity(0.9) : dotColor).frame(width: 6, height: 6)
            Text(status.rawValue)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(dynamicTextColor)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(isSelected ? dynamicTextColor.opacity(0.2) : bgColor, in: Capsule())
    }
    
    var dotColor: Color {
        let baseColor: Color
        switch status {
        case .completed:            baseColor = Color(hex: completedColorHex)
        case .failed:               baseColor = Color(hex: failedColorHex)
        case .downloading, .queued: baseColor = Color(hex: downloadingColorHex)
        case .stopped:              baseColor = Color(hex: stoppedColorHex)
        default:                    return .secondary
        }
        
        let matchedColor = matchBadgesToAccent
            ? baseColor.matchingThemeVisualWeight(of: Color(hex: accentColorHex))
            : baseColor
            
        return matchedColor.adaptedForScheme(colorScheme)
    }
    
    var labelColor: Color { dotColor }
    var bgColor: Color { dotColor.opacity(0.12) }
}

struct EmptyListPlaceholder: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.down.circle.dotted")
                .font(.system(size: 52))
                .foregroundStyle(.tertiary)
            VStack(spacing: 4) {
                Text("No Downloads")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Add a URL to get started, or install the Chrome extension to capture downloads automatically.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }
        }
    }
}

// MARK: - Properties Sheet

struct PropertiesSheet: View {
    let item: DownloadItem
    @Environment(\.dismiss) private var dismiss
    var engine = DownloadEngine.shared

    @State private var urlText: String = ""
    @State private var urlIsValid: Bool = true
    
    @AppStorage("accentColorHex") private var accentColorHex = "#0A84FF"
    @AppStorage("enableBackgroundTint") private var enableBackgroundTint = false

    private var fileSize: String {
        if item.totalBytes > 0 { return formatBytes(item.totalBytes) }
        if item.downloadedBytes > 0 { return formatBytes(item.downloadedBytes) + " (partial)" }
        return "Unknown"
    }

    private var diskUsage: String {
        let url = item.destinationURL
        guard FileManager.default.fileExists(atPath: url.path),
              let vals = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]) else { return "–" }
        return formatBytes(Int64(vals.totalFileAllocatedSize ?? 0))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: item.type == .torrent ? "arrow.2.circlepath" : (item.type == .batch ? "square.stack.3d.down.right" : "link"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(item.filename)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    PropertiesSection("File") {
                        PropRow("Filename",    item.filename)
                        PropRow("Destination", item.destinationURL.path)
                        PropRow("File Size",   fileSize)
                        PropRow("On Disk",     diskUsage)
                        PropRow("Type",        item.type.rawValue)
                        if let mime = item.mimeType { PropRow("MIME Type", mime) }
                    }

                    PropertiesSection("Transfer") {
                        PropRow("Status",      item.status.rawValue)
                        PropRow("Downloaded",  formatBytes(item.downloadedBytes))
                        PropRow("Progress",    item.totalBytes > 0
                            ? String(format: "%.1f%%", item.progress * 100)
                            : "–")
                        PropRow("Connections", "\(item.connectionCount)")
                        PropRow("Range Support", item.supportsRanges ? "Yes" : "No")
                        if item.speedLimit > 0 {
                            PropRow("Speed Limit", "\(item.speedLimit) KB/s")
                        }
                        if let err = item.error { PropRow("Error", err) }
                    }

                    PropertiesSection("Source") {
                        if item.type == .batch {
                            PropRow("Batch URLs", "\(item.batchURLs?.count ?? 0) URLs", expandable: false)
                        } else {
                            HStack(alignment: .top, spacing: 12) {
                                Text("URL")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 120, alignment: .trailing)
                                VStack(alignment: .leading, spacing: 4) {
                                    TextField("", text: $urlText)
                                        .textFieldStyle(.plain)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundColor(urlIsValid ? .primary : .red)
                                        .onChange(of: urlText) { _, new in
                                            urlIsValid = URL(string: new) != nil && !new.isEmpty
                                        }
                                    if !urlIsValid {
                                        Text("Invalid URL")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.red)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(urlText, forType: .string)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 5)

                            PropRow("Host",   URL(string: urlText)?.host ?? item.url.host ?? "–")
                            PropRow("Scheme", URL(string: urlText)?.scheme?.uppercased() ?? item.url.scheme?.uppercased() ?? "–")
                        }
                        if let ua = item.userAgent, !ua.isEmpty { PropRow("User-Agent", ua, expandable: true) }
                        if let ck = item.cookies,  !ck.isEmpty  { PropRow("Cookies",    ck, expandable: true) }
                    }

                    PropertiesSection("Dates") {
                        PropRow("Added", formatDate(item.dateAdded))
                        if let done = item.dateCompleted {
                            PropRow("Completed", formatDate(done))
                            PropRow("Duration",  formatDuration(done.timeIntervalSince(item.dateAdded)))
                        }
                    }

                    if !item.subFiles.isEmpty {
                        PropertiesSection("\(item.type == .batch ? "Batch" : "Torrent") Files (\(item.subFiles.count))") {
                            ForEach(item.subFiles) { f in
                                PropRow(f.filename, f.totalBytes > 0 ? formatBytes(f.totalBytes) : "Unknown Size")
                            }
                        }
                    }
                }
                .padding(.bottom, 16)
            }

            Divider()

            HStack {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([item.destinationURL])
                }
                .buttonStyle(.bordered)
                Spacer()
                
                Button("Done") {
                    if item.type != .batch, urlIsValid, let newURL = URL(string: urlText), newURL != item.url {
                        let shouldResume = (item.status != .completed)
                        
                        if item.status == .downloading || item.status == .queued {
                            engine.stop(item)
                        }
                        
                        try? FileManager.default.removeItem(at: item.tempDirURL)
                        try? FileManager.default.removeItem(at: item.destinationURL)
                        
                        let newFilename: String = {
                            var c = URLComponents(url: newURL, resolvingAgainstBaseURL: false)
                            c?.query = nil
                            let last = (c?.url ?? newURL).lastPathComponent
                            let dec  = last.removingPercentEncoding ?? last
                            return (!dec.isEmpty && dec != "/") ? dec : "download"
                        }()
                        let destDir = item.destinationURL.deletingLastPathComponent()

                        item.url            = newURL
                        item.filename       = newFilename
                        item.destinationURL = destDir.appendingPathComponent(newFilename)
                        item.sourceHost     = newURL.host ?? ""
                        item.error          = nil
                        item.downloadedBytes = 0
                        item.totalBytes      = 0
                        item.isPrepared      = false
                        item.supportsRanges  = false
                        item.status          = .stopped
                        
                        engine.persist()
                        
                        if shouldResume {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                engine.resume(item)
                            }
                        }
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
                .disabled(!urlIsValid)
                .tint(Color(hex: accentColorHex))
                .foregroundStyle(Color(hex: accentColorHex).accessibleText)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 560, height: 520)
        .background(enableBackgroundTint ? Color(hex: accentColorHex).opacity(0.04) : Color(NSColor.windowBackgroundColor))
        .onAppear { urlText = item.url.absoluteString }
    }

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f.string(from: date)
    }

    private func formatDuration(_ t: TimeInterval) -> String {
        let s = Int(t)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s/60)m \(s%60)s" }
        return "\(s/3600)h \((s%3600)/60)m \(s%60)s"
    }
}

struct PropRow: View {
    let label: String
    let value: String
    var copiable: Bool = false
    var expandable: Bool = false
    var lineLimit: Int = 3
    @State private var copied = false
    @State private var expanded = false

    init(_ label: String, _ value: String, copiable: Bool = false, expandable: Bool = false, lineLimit: Int = 3) {
        self.label = label
        self.value = value
        self.copiable = copiable
        self.expandable = expandable
        self.lineLimit = lineLimit
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .trailing)
            VStack(alignment: .leading, spacing: 3) {
                Text(value)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .lineLimit(expandable && !expanded ? 1 : nil)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if expandable {
                    Button(expanded ? "Show less" : "Show more") {
                        expanded.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if copiable {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(copied ? .green : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 5)
    }
}

private struct PropertiesSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 6)
            content
        }
    }
}
