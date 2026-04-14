import SwiftUI
import AppKit
import UniformTypeIdentifiers

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
    @FocusState private var isListFocused: Bool

    @AppStorage("accentColorHex") private var accentColorHex = "#0A84FF"
    @AppStorage("enableBackgroundTint") private var enableBackgroundTint = false
    
    // Sort sync
    @AppStorage("sortColumn") private var sortColumn: SortColumn = .dateAdded
    @AppStorage("sortAscending") private var sortAscending: Bool = false

    // ── Unified Sorting Logic ─────────────────────────────────
    var sortedItems: [DownloadItem] {
        items.sorted { a, b in
            let isAsc = sortAscending
            switch sortColumn {
            case .name:
                let cmp = a.filename.localizedStandardCompare(b.filename)
                if cmp == .orderedSame { return a.dateAdded > b.dateAdded }
                return isAsc ? cmp == .orderedAscending : cmp == .orderedDescending
            case .status:
                if a.status == b.status { return a.dateAdded > b.dateAdded }
                return isAsc ? a.status.rawValue < b.status.rawValue : a.status.rawValue > b.status.rawValue
            case .transfer:
                if a.progress == b.progress { return a.dateAdded > b.dateAdded }
                return isAsc ? a.progress < b.progress : a.progress > b.progress
            case .type:
                if a.type == b.type { return a.dateAdded > b.dateAdded }
                return isAsc ? a.type.rawValue < b.type.rawValue : a.type.rawValue > b.type.rawValue
            case .speed:
                if a.speed == b.speed { return a.dateAdded > b.dateAdded }
                return isAsc ? a.speed < b.speed : a.speed > b.speed
            case .dateAdded:
                if a.dateAdded == b.dateAdded { return a.filename < b.filename }
                return isAsc ? a.dateAdded < b.dateAdded : a.dateAdded > b.dateAdded
            case .dateModified:
                let d1 = a.dateCompleted ?? a.dateAdded
                let d2 = b.dateCompleted ?? b.dateAdded
                if d1 == d2 { return a.filename < b.filename }
                return isAsc ? d1 < d2 : d1 > d2
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ColumnHeader(sortColumn: $sortColumn, sortAscending: $sortAscending)
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
                        ForEach(Array(sortedItems.enumerated()), id: \.element.id) { index, item in
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
                    isListFocused = true
                    selected.removeAll()
                    lastSelectedIndex = nil
                }
            }
        }
        .background(enableBackgroundTint ? Color(hex: accentColorHex).opacity(0.04) : Color(NSColor.controlBackgroundColor))
        .focusable()
        .focused($isListFocused)
        .focusEffectDisabled()
        .sheet(item: $propertiesItem) { item in
            PropertiesSheet(item: item)
        }
        .onKeyPress(.init("a"), phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            selected = Set(sortedItems.map { $0.id })
            return .handled
        }
        .onKeyPress(.delete, phases: .down) { _ in // Handles the standard 'Backspace' key
            let toDelete = engine.items.filter { selected.contains($0.id) }
            if toDelete.isEmpty { return .ignored }
            onRequestRemove(toDelete)
            return .handled
        }
        .onKeyPress(.deleteForward, phases: .down) { _ in // Handles the forward 'Delete' key
            let toDelete = engine.items.filter { selected.contains($0.id) }
            if toDelete.isEmpty { return .ignored }
            onRequestRemove(toDelete)
            return .handled
        }
        .onDeleteCommand { // Fallback native hook
            let toDelete = engine.items.filter { selected.contains($0.id) }
            guard !toDelete.isEmpty else { return }
            onRequestRemove(toDelete)
        }
        .onAppear {
            // Give the list focus when it appears so hotkeys work immediately
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isListFocused = true
            }
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
        isListFocused = true // Give keyboard focus to the list
        
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
            guard let last = lastSelectedIndex, last < sortedItems.count else {
                selected = [item.id]
                lastSelectedIndex = index
                return
            }
            let range = min(last, index)...max(last, index)
            selected = Set(sortedItems[range].map { $0.id })
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
    
    @AppStorage("accentColorHex") private var accentColorHex = "#0A84FF"
    @AppStorage("enableBackgroundTint") private var enableBackgroundTint = false

    var body: some View {
        ZStack {
            // This layer now correctly switches between your Accent Color and Material
            Capsule()
                .fill(backgroundStyle)
            
            let accentColor = Color(hex: accentColorHex)
            GeometryReader { geo in
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: accentColor.opacity(0.01), location: 0.4),
                        .init(color: accentColor.opacity(0.05), location: 0.5),
                        .init(color: accentColor.opacity(0.10), location: 0.6),
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
        // Tint the shadow with the accent color for better integration
        .shadow(color: enableBackgroundTint ? Color(hex: accentColorHex).opacity(0.15) : .black.opacity(0.08), radius: 12, x: 0, y: 6)
    }

    private var backgroundStyle: AnyShapeStyle {
        if enableBackgroundTint {
            // Apply a heavier opacity of the accent color to make the difference visible
            return AnyShapeStyle(Color(hex: accentColorHex).opacity(0.15))
        } else {
            return AnyShapeStyle(.ultraThinMaterial.opacity(0.85))
        }
    }
}

// ── Clickable Column Headers ──────────────────────────────────
struct ColumnHeader: View {
    @Binding var sortColumn: SortColumn
    @Binding var sortAscending: Bool

    @AppStorage("accentColorHex") private var accentColorHex = "#0A84FF"
    @AppStorage("enableBackgroundTint") private var enableBackgroundTint = false

    var body: some View {
        // MATCHING HSTACK SPACING
        HStack(spacing: 12) {
            Button(action: { sort(by: .name) }) {
                HStack(spacing: 4) {
                    Text("Name")
                    sortIcon(for: .name)
                }
                .frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: { sort(by: .status) }) {
                HStack(spacing: 4) {
                    Text("Status")
                    sortIcon(for: .status)
                }
                .frame(width: 100, alignment: .leading) // EXACT WIDTH
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: { sort(by: .transfer) }) {
                HStack(spacing: 4) {
                    Text("Transfer")
                    sortIcon(for: .transfer)
                }
                .frame(width: 130, alignment: .leading) // EXACT WIDTH
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: { sort(by: .type) }) {
                HStack(spacing: 4) {
                    Text("Type")
                    sortIcon(for: .type)
                }
                .frame(width: 80, alignment: .leading) // EXACT WIDTH
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: { sort(by: .speed) }) {
                HStack(spacing: 4) {
                    Text("Speed")
                    sortIcon(for: .speed)
                }
                .frame(width: 70, alignment: .leading) // EXACT WIDTH
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12) // MATCHING OUTER PADDING
        .padding(.vertical, 8)
        .background(enableBackgroundTint ? Color(hex: accentColorHex).opacity(0.04) : Color(NSColor.controlBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func sort(by column: SortColumn) {
        if sortColumn == column {
            sortAscending.toggle()
        } else {
            sortColumn = column
            switch column {
            case .name, .type, .status: sortAscending = true
            case .transfer, .speed, .dateAdded, .dateModified: sortAscending = false
            }
        }
    }

    @ViewBuilder
    private func sortIcon(for column: SortColumn) -> some View {
        if sortColumn == column {
            Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color(hex: accentColorHex))
        }
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
        if ext.isEmpty { return NSWorkspace.shared.icon(for: .data) }
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
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
        // MATCHING HSTACK SPACING
        HStack(spacing: 12) {
            
            // 1. NAME
            HStack(spacing: 8) {
                if (item.type == .torrent || item.type == .batch) && (!item.subFiles.isEmpty || item.status == .downloading) {
                    Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() } }) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(isSelected ? dynamicTextColor : .secondary)
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                } else {}
                
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
            .frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)

            // 2. STATUS
            StatusPill(status: item.status, isSelected: isSelected, accentColorHex: accentColorHex)
                .frame(width: 100, alignment: .leading) // EXACT WIDTH

            // 3. TRANSFER
            VStack(alignment: .leading, spacing: 3) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.primary.opacity(isSelected ? 0.2 : 0.1))
                            .frame(height: 6)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(progressColor)
                            .frame(width: max(0, CGFloat(item.progress) * geo.size.width), height: 6)
                    }
                }
                .frame(height: 4)
                Text(item.transferLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? dynamicTextColor.opacity(0.8) : .secondary)
                    .lineLimit(1)
            }
            .frame(width: 130, alignment: .leading) // EXACT WIDTH (and removed rogue padding)

            // 4. TYPE
            Text(item.type.rawValue)
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? dynamicTextColor.opacity(0.85) : .primary)
                .lineLimit(1)
                .frame(width: 80, alignment: .leading) // EXACT WIDTH

            // 5. SPEED
            Text(item.status == .downloading ? item.formattedSpeed : "–")
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? dynamicTextColor.opacity(0.85) : .secondary)
                .lineLimit(1)
                .frame(width: 70, alignment: .leading) // EXACT WIDTH

        }
        .padding(.horizontal, 12) // MATCHING OUTER PADDING
        .padding(.vertical, isCompactList ? 4 : 9)
    }

    var progressColor: Color {
        if isSelected { return Color(hex: accentColorHex).accessibleText }
        switch item.status {
        case .downloading, .completed, .failed, .stopped:
            return matchProgressBarToAccent ? Color(hex: accentColorHex) : Color(hex: progressBarColorHex)
        case .queued: return .secondary
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
