import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Global Icon Cache (Prevents Main-Thread Freezes)
class SharedIconCache {
    static let shared = SharedIconCache()
    private var cache: [String: NSImage] = [:]
    private let lock = NSLock()
    
    func icon(for ext: String) -> NSImage {
        let cleanExt = ext.lowercased()
        
        lock.lock()
        if let img = cache[cleanExt] {
            lock.unlock()
            return img
        }
        lock.unlock()
        
        let img: NSImage
        if cleanExt.isEmpty {
            img = NSWorkspace.shared.icon(for: .data)
        } else if let utType = UTType(filenameExtension: cleanExt) {
            img = NSWorkspace.shared.icon(for: utType)
        } else {
            img = NSWorkspace.shared.icon(for: .data)
        }
        
        // Massive Optimization: Rasterize huge 512x512 .icns blobs down to exactly 24x24.
        // This prevents SwiftUI from choking the GPU texture memory when rendering long lists.
        let targetSize = NSSize(width: 24, height: 24)
        let resizedImg = NSImage(size: targetSize)
        resizedImg.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        img.draw(in: NSRect(origin: .zero, size: targetSize))
        resizedImg.unlockFocus()
        
        lock.lock()
        cache[cleanExt] = resizedImg
        lock.unlock()
        
        return resizedImg
    }
}

// MARK: - Right Click Handling
struct RightClickModifier: ViewModifier {
    let action: () -> Void
    func body(content: Content) -> some View {
        content.overlay(RightClickCatcher(action: action))
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
        // Pass the event up the responder chain so SwiftUI's ContextMenu still fires
        super.rightMouseDown(with: event)
    }
    
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only intercept right clicks; let left clicks pass through to standard onTapGestures
        guard let event = NSApp.currentEvent, event.type == .rightMouseDown else { return nil }
        
        // 'point' is in the superview's coordinate space. We must convert it to local coordinates.
        let localPoint = convert(point, from: superview)
        return bounds.contains(localPoint) ? self : nil
    }
}

extension View {
    func onRightClick(perform action: @escaping () -> Void) -> some View {
        self.modifier(RightClickModifier(action: action))
    }
}

// MARK: - List Items
struct RowDynamicID: Hashable {
    let id: UUID
    let state: Int
}

enum ListRowItem: Identifiable {
    case main(DownloadItem)
    case sub(parent: DownloadItem, file: SubFile, index: Int)
    
    var id: UUID {
        switch self {
        case .main(let item): return item.id
        case .sub(_, let file, _): return file.id
        }
    }
    
    // Uses a highly optimized Hashable struct instead of String interpolation to prevent
    // massive memory allocations and CPU spikes when SwiftUI diffs the list on selection.
    var dynamicID: RowDynamicID {
        switch self {
        case .main(let item):
            return RowDynamicID(id: item.id, state: item.status.hashValue)
        case .sub(let parent, let file, _):
            return RowDynamicID(id: file.id, state: (file.isStopped ? 1 : 0) ^ parent.status.hashValue)
        }
    }
}

enum ArrowDirection { case up, down, left, right }

struct DownloadListView: View {
    let items: [DownloadItem]
    @Binding var selected: Set<UUID>
    @Binding var search: String
    var engine = DownloadEngine.shared

    let onRequestRemove: ([DownloadItem]) -> Void

    @State private var cursorID: UUID? = nil
    @State private var anchorID: UUID? = nil
    @State private var rightClickedID: UUID? = nil
    
    @State private var propertiesItem: DownloadItem? = nil
    @State private var expandedItems: Set<UUID> = []
    
    @FocusState private var isSearchFocused: Bool
    @FocusState private var isListFocused: Bool

    @AppStorage("accentColorHex") private var accentColorHex = "#0A84FF"
    @AppStorage("enableBackgroundTint") private var enableBackgroundTint = false
    
    @AppStorage("sortColumn") private var sortColumn: SortColumn = .dateAdded
    @AppStorage("sortAscending") private var sortAscending: Bool = false

    private func currentFileURL(for item: DownloadItem) -> URL {
        if item.status == .completed { return item.destinationURL }
        if item.type == .directLink { return item.destinationURL.appendingPathExtension("dysy") }
        return item.destinationURL
    }

    var sortedItems: [DownloadItem] {
        items.sorted { a, b in
            let isAsc = sortAscending
            switch sortColumn {
            case .name:
                // CaseInsensitiveCompare is significantly faster than localizedStandardCompare
                let cmp = a.filename.caseInsensitiveCompare(b.filename)
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

    var flattenedRows: [ListRowItem] {
        var rows: [ListRowItem] = []
        for item in sortedItems {
            rows.append(.main(item))
            if expandedItems.contains(item.id) && (item.type == .torrent || item.type == .batch) {
                for (index, file) in item.subFiles.enumerated() {
                    rows.append(.sub(parent: item, file: file, index: index))
                }
            }
        }
        return rows
    }

    var body: some View {
        VStack(spacing: 0) {
            ColumnHeader(sortColumn: $sortColumn, sortAscending: $sortAscending)
            mainContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tint(Color(hex: accentColorHex))
        .sheet(item: $propertiesItem) { item in
            PropertiesSheet(item: item)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
            // Clears the right-click border when the context menu is dismissed
            rightClickedID = nil
        }
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
        let emptyRowHeight: CGFloat = 28
        let color1 = Color(NSColor.controlBackgroundColor)
        let color2 = enableBackgroundTint
            ? Color(hex: accentColorHex).opacity(0.06)
            : Color.primary.opacity(0.04)
        
        return GeometryReader { geo in
            let exactRowWidth = max(0, geo.size.width - 16)
            
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        LazyVStack(spacing: 4) {
                            ForEach(Array(flattenedRows.enumerated()), id: \.element.dynamicID) { indexedItem in
                                listRow(
                                    rowItem: indexedItem.element,
                                    index: indexedItem.offset,
                                    exactRowWidth: exactRowWidth,
                                    color1: color1,
                                    color2: color2
                                )
                            }
                            
                            ForEach(0..<15, id: \.self) { emptyIndex in
                                emptyListRow(
                                    index: flattenedRows.count + emptyIndex,
                                    exactRowWidth: exactRowWidth,
                                    emptyRowHeight: emptyRowHeight,
                                    color1: color1,
                                    color2: color2
                                )
                            }
                        }
                        .padding(8)
                        
                        Spacer(minLength: 90)
                    }
                    .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .top)
                    .contentShape(Rectangle()) // Explicit shape capturing hits
                    .onTapGesture {
                        // Tapping outside list elements triggers this, removing highlights
                        isListFocused = true
                        selected.removeAll()
                        cursorID = nil
                        anchorID = nil
                        rightClickedID = nil
                    }
                }
                .background {
                    hiddenNavigationButtons(proxy: proxy)
                }
                .onChange(of: cursorID) { _, newID in
                    if let id = newID {
                        proxy.scrollTo(id, anchor: nil)
                    }
                }
            }
        }
        .background(enableBackgroundTint ? Color(hex: accentColorHex).opacity(0.06) : Color(NSColor.windowBackgroundColor))
        .focusable()
        .focused($isListFocused)
        .focusEffectDisabled()
        // Single unified block for list interactions prevents ContextMenu shortcut duplication bugs
        .onKeyPress(phases: [.down, .repeat]) { press in
            let isCmd = press.modifiers.contains(.command)
            let isShift = press.modifiers.contains(.shift)
            
            switch press.key {
            case .delete, .deleteForward:
                let toDelete = engine.items.filter { selected.contains($0.id) }
                if !toDelete.isEmpty {
                    onRequestRemove(toDelete)
                    return .handled
                }
            case .upArrow:
                handleArrow(.up, isShift: isShift); return .handled
            case .downArrow:
                handleArrow(.down, isShift: isShift); return .handled
            case .leftArrow:
                handleArrow(.left, isShift: isShift); return .handled
            case .rightArrow:
                handleArrow(.right, isShift: isShift); return .handled
            case .space:
                togglePlayPause(); return .handled
            case .return:
                triggerDefaultAction(); return .handled
            default:
                break
            }
            
            if isCmd {
                switch press.characters.lowercased() {
                case "a": selected = Set(flattenedRows.map { $0.id }); return .handled
                case "c": copySelectedURLs(); return .handled
                case "r": revealSelected(); return .handled
                case "i": showProperties(); return .handled
                case "p": showProgressWindow(); return .handled
                case "f": isSearchFocused = true; return .handled
                default: break
                }
            }
            
            // Explicit safety fallback to guarantee standard Backspace is captured
            if press.characters == "\u{7F}" || press.characters == "\u{08}" {
                let toDelete = engine.items.filter { selected.contains($0.id) }
                if !toDelete.isEmpty {
                    onRequestRemove(toDelete)
                    return .handled
                }
            }
            return .ignored
        }
        .onDeleteCommand {
            // Allows the native macOS "Edit -> Delete" menu item to function
            let toDelete = engine.items.filter { selected.contains($0.id) }
            guard !toDelete.isEmpty else { return }
            onRequestRemove(toDelete)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isListFocused = true
            }
        }
        .onChange(of: selected) { _, newSelected in
            // When auto-selected by an external event, sync the cursor
            if newSelected.count == 1, let newlySelectedID = newSelected.first {
                if cursorID != newlySelectedID {
                    cursorID = newlySelectedID
                    anchorID = newlySelectedID
                }
            }
        }
    }
    
    // MARK: - Extracted View Builders to appease the Compiler

    @ViewBuilder
    private func listRow(
        rowItem: ListRowItem,
        index: Int,
        exactRowWidth: CGFloat,
        color1: Color,
        color2: Color
    ) -> some View {
        Group {
            switch rowItem {
            case .main(let item):
                DownloadRow(
                    item: item,
                    isSelected: selected.contains(item.id),
                    isExpanded: Binding(
                        get: { expandedItems.contains(item.id) },
                        set: { val in
                            if val { expandedItems.insert(item.id) }
                            else { expandedItems.remove(item.id) }
                        }
                    )
                )
                
            case .sub(let parent, _, let subIndex):
                SubFileRow(
                    parent: parent,
                    index: subIndex,
                    isSelected: selected.contains(rowItem.id)
                )
            }
        }
        .frame(width: exactRowWidth, alignment: .leading)
        .background(index % 2 == 0 ? color1 : color2)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(rightClickedID == rowItem.id ? Color(hex: accentColorHex) : Color.clear, lineWidth: 2)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .clipped()
        .onRightClick {
            isListFocused = true
            cursorID = rowItem.id
            rightClickedID = rowItem.id
        }
        .onTapGesture {
            handleRowTap(rowItem: rowItem)
        }
        .contextMenu { rowContextMenu(rowItem) }
        .id(rowItem.id) // This explicitly links the view to the UUID so proxy.scrollTo() can find it
    }
    
    @ViewBuilder
    private func emptyListRow(
        index: Int,
        exactRowWidth: CGFloat,
        emptyRowHeight: CGFloat,
        color1: Color,
        color2: Color
    ) -> some View {
        HStack { Spacer() }
            .frame(width: exactRowWidth, height: emptyRowHeight)
            .background(index % 2 == 0 ? color1 : color2)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle()) // Ensures empty rows capture clicks for deselection bubbling
    }
    
    @ViewBuilder
    private func hiddenNavigationButtons(proxy: ScrollViewProxy) -> some View {
        Group {
            Button("") {
                if let first = flattenedRows.first {
                    selected = [first.id]
                    anchorID = first.id
                    cursorID = first.id
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        proxy.scrollTo(first.id, anchor: .top)
                    }
                }
            }
            .keyboardShortcut(.upArrow, modifiers: .command)

            Button("") {
                if let last = flattenedRows.last {
                    selected = [last.id]
                    anchorID = last.id
                    cursorID = last.id
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .keyboardShortcut(.downArrow, modifiers: .command)
        }
        .opacity(0)
        .allowsHitTesting(false)
    }
    
    // MARK: - Shortcut Implementations
    
    private func triggerDefaultAction() {
        let selectedRows = flattenedRows.filter { selected.contains($0.id) }
        for rowItem in selectedRows {
            switch rowItem {
            case .main(let item):
                if item.status == .completed { NSWorkspace.shared.open(item.destinationURL) }
                else { propertiesItem = item }
            case .sub(let parent, _, _):
                if parent.status == .completed { NSWorkspace.shared.open(parent.destinationURL) }
            }
        }
    }
    
    private func copySelectedURLs() {
        let selectedRows = flattenedRows.filter { selected.contains($0.id) }
        var urls: [String] = []
        for row in selectedRows {
            if case .main(let item) = row {
                urls.append(item.url.absoluteString)
            }
        }
        guard !urls.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urls.joined(separator: "\n"), forType: .string)
    }
    
    private func revealSelected() {
        let selectedRows = flattenedRows.filter { selected.contains($0.id) }
        var fileURLs: [URL] = []
        for row in selectedRows {
            if case .main(let item) = row {
                fileURLs.append(currentFileURL(for: item))
            } else if case .sub(let parent, _, _) = row {
                fileURLs.append(parent.destinationURL)
            }
        }
        guard !fileURLs.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(fileURLs)
    }
    
    private func showProperties() {
        let selectedRows = flattenedRows.filter { selected.contains($0.id) }
        if selectedRows.count == 1, case .main(let item) = selectedRows.first! {
            propertiesItem = item
        }
    }
    
    private func showProgressWindow() {
        let selectedRows = flattenedRows.filter { selected.contains($0.id) }
        if selectedRows.count == 1, case .main(let item) = selectedRows.first! {
            if item.status == .downloading || item.status == .queued {
                NotificationCenter.default.post(name: .openProgressWindow, object: nil, userInfo: ["id": item.id])
            }
        }
    }
    
    private func togglePlayPause() {
        let selectedRows = flattenedRows.filter { selected.contains($0.id) }
        guard !selectedRows.isEmpty else { return }
        
        var mainItems: [DownloadItem] = []
        var subItems: [(DownloadItem, SubFile, Int)] = []
        
        for row in selectedRows {
            switch row {
            case .main(let item): mainItems.append(item)
            case .sub(let parent, let file, let index): subItems.append((parent, file, index))
            }
        }
        
        if !mainItems.isEmpty {
            let shouldStop = mainItems.contains { $0.status == .downloading || $0.status == .queued }
            for item in mainItems {
                if shouldStop { engine.stop(item) } else { engine.resume(item) }
            }
        }
        
        if !subItems.isEmpty {
            let shouldStop = subItems.contains { !$0.1.isStopped }
            var parentsToUpdate: Set<UUID> = []
            
            for (parent, _, index) in subItems {
                if parent.type == .torrent || parent.type == .batch {
                    var updated = parent.subFiles
                    updated[index].isStopped = shouldStop
                    parent.subFiles = updated
                    engine.items = engine.items // Force UI update
                    parentsToUpdate.insert(parent.id)
                }
            }
            
            for pid in parentsToUpdate {
                if let p = engine.items.first(where: { $0.id == pid }) {
                    if p.status == .stopped || p.status == .failed {
                        if p.subFiles.contains(where: { !$0.isStopped }) {
                            engine.resume(p, resumeSubFiles: false)
                        } else {
                            engine.persist()
                        }
                    } else {
                        engine.updateTorrentSelection(for: p)
                    }
                }
            }
        }
    }
    
    private func handleArrow(_ dir: ArrowDirection, isShift: Bool) {
        let rows = flattenedRows
        guard !rows.isEmpty else { return }

        var currentIndex: Int? = nil
        
        if let cid = cursorID, let idx = rows.firstIndex(where: { $0.id == cid }) {
            currentIndex = idx
        } else if let sel = selected.first, selected.count == 1, let idx = rows.firstIndex(where: { $0.id == sel }) {
            currentIndex = idx
        }

        var nextIndex = currentIndex ?? 0

        switch dir {
        case .down:
            if let curr = currentIndex { nextIndex = min(curr + 1, rows.count - 1) }
        case .up:
            if let curr = currentIndex { nextIndex = max(curr - 1, 0) }
        case .right:
            guard !isShift, let curr = currentIndex else { return }
            if case .main(let item) = rows[curr], (item.type == .torrent || item.type == .batch) && !item.subFiles.isEmpty {
                if !expandedItems.contains(item.id) {
                    expandedItems.insert(item.id)
                    nextIndex = curr
                } else if curr < rows.count - 1 {
                    nextIndex = curr + 1
                }
            } else { return }
        case .left:
            guard !isShift, let curr = currentIndex else { return }
            switch rows[curr] {
            case .main(let item):
                if expandedItems.contains(item.id) {
                    expandedItems.remove(item.id)
                    nextIndex = curr
                } else { return }
            case .sub(let parent, _, _):
                if let pIdx = rows.firstIndex(where: { $0.id == parent.id }) {
                    nextIndex = pIdx
                } else { return }
            }
        }

        let targetID = rows[nextIndex].id
        cursorID = targetID

        if dir == .up || dir == .down || dir == .left || dir == .right {
            if isShift && (dir == .up || dir == .down) {
                if anchorID == nil { anchorID = currentIndex != nil ? rows[currentIndex!].id : targetID }
                if let aID = anchorID, let aIdx = rows.firstIndex(where: { $0.id == aID }) {
                    let range = min(aIdx, nextIndex)...max(aIdx, nextIndex)
                    selected = Set(rows[range].map { $0.id })
                }
            } else {
                anchorID = targetID
                selected = [targetID]
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
                .onChange(of: search) { _, new in
                    if new.contains("\t") { search = new.replacingOccurrences(of: "\t", with: "") }
                }
            
            searchActionButtons
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .glassEffect(.clear.tint(Color(hex: accentColorHex).opacity(0.20)).interactive())
        .clipShape(RoundedRectangle(cornerRadius: 12))
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
        .help("Start Dictation")
    }
    
    private func handleRowTap(rowItem: ListRowItem) {
        isListFocused = true
        cursorID = rowItem.id
        rightClickedID = nil
        
        let event = NSApp.currentEvent
        let flags = event?.modifierFlags ?? []
        let isDoubleClick = event?.clickCount == 2
        
        if isDoubleClick {
            triggerDefaultAction()
            return
        }
        
        let rows = flattenedRows
        if flags.contains(.command) {
            if selected.contains(rowItem.id) { selected.remove(rowItem.id) }
            else { selected.insert(rowItem.id) }
            anchorID = rowItem.id
        } else if flags.contains(.shift) {
            guard let aID = anchorID, let aIdx = rows.firstIndex(where: { $0.id == aID }),
                  let curIdx = rows.firstIndex(where: { $0.id == rowItem.id }) else {
                selected = [rowItem.id]
                anchorID = rowItem.id
                return
            }
            let range = min(aIdx, curIdx)...max(aIdx, curIdx)
            selected = Set(rows[range].map { $0.id })
        } else {
            selected = [rowItem.id]
            anchorID = rowItem.id
        }
    }

    @ViewBuilder
    func rowContextMenu(_ rowItem: ListRowItem) -> some View {
        switch rowItem {
        case .main(let item):
            let targetItems = selected.contains(item.id)
                ? engine.items.filter { selected.contains($0.id) }
                : [item]

            if targetItems.contains(where: { $0.status == .downloading || $0.status == .queued }) {
                Button("Stop") {
                    targetItems.forEach { engine.stop($0) }
                }
            }
            
            if targetItems.contains(where: { $0.status == .stopped || $0.status == .failed }) {
                Button("Resume") {
                    targetItems.forEach { engine.resume($0) }
                }
            }
            
            Divider()

            if targetItems.count == 1, let single = targetItems.first {
                if single.status == .downloading || single.status == .queued {
                    Button("Show Progress Window") {
                        NotificationCenter.default.post(name: .openProgressWindow, object: nil, userInfo: ["id": single.id])
                    }
                }
                
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
                
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([currentFileURL(for: single)]) }
                Button("Restart Download") { targetItems.forEach { engine.retry($0) } }

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
            
        case .sub(let parent, let staticFile, let index):
            let file = index < parent.subFiles.count ? parent.subFiles[index] : staticFile
            let isFinished = file.totalBytes > 0 && file.downloadedBytes >= file.totalBytes
            
            if isFinished {
                Button("Restart") {
                    let tempPath = parent.tempDirURL.appendingPathComponent(file.path)
                    let destDir = parent.type == .batch ? parent.destinationURL : parent.destinationURL.deletingLastPathComponent()
                    let destPath = destDir.appendingPathComponent(file.path)
                    
                    try? FileManager.default.removeItem(at: tempPath)
                    try? FileManager.default.removeItem(at: destPath)
                    
                    var updated = parent.subFiles
                    if index < updated.count {
                        updated[index].downloadedBytes = 0
                        updated[index].isStopped = false
                        parent.subFiles = updated
                        engine.items = engine.items // Force UI update
                    }
                    
                    if parent.status == .completed || parent.status == .stopped || parent.status == .failed {
                        parent.status = .stopped
                        engine.resume(parent, resumeSubFiles: false)
                    } else {
                        engine.updateTorrentSelection(for: parent)
                    }
                }
            } else if parent.type == .torrent || parent.type == .batch {
                let isEffectivelyPaused = parent.status == .stopped || parent.status == .failed || file.isStopped
                
                Button(isEffectivelyPaused ? "Resume File" : "Pause File") {
                    var updated = parent.subFiles
                    if index < updated.count {
                        updated[index].isStopped.toggle()
                        parent.subFiles = updated
                        engine.items = engine.items // Force UI update
                        
                        if parent.status == .stopped || parent.status == .failed {
                            if !parent.subFiles[index].isStopped {
                                engine.resume(parent, resumeSubFiles: false)
                            } else {
                                engine.persist()
                            }
                        } else {
                            engine.updateTorrentSelection(for: parent)
                        }
                    }
                }
            }
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
        HStack(spacing: 12) {
            Button(action: { sort(by: .name) }) {
                HStack(spacing: 4) {
                    Text("Name")
                    sortIcon(for: .name)
                }
                .frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: { sort(by: .status) }) {
                HStack(spacing: 4) {
                    Text("Status")
                    sortIcon(for: .status)
                }
                .frame(width: 100, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: { sort(by: .transfer) }) {
                HStack(spacing: 4) {
                    Text("Transfer")
                    sortIcon(for: .transfer)
                }
                .frame(width: 110, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: { sort(by: .type) }) {
                HStack(spacing: 4) {
                    Text("Type")
                    sortIcon(for: .type)
                }
                .frame(width: 65, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: { sort(by: .speed) }) {
                HStack(spacing: 4) {
                    Text("Speed")
                    sortIcon(for: .speed)
                }
                .frame(width: 70, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
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

// ── Parent Row ──────────────────────────────────
struct DownloadRow: View {
    let item: DownloadItem
    let isSelected: Bool
    @Binding var isExpanded: Bool

    @AppStorage("isCompactList") private var isCompactList = false
    @AppStorage("accentColorHex") private var accentColorHex = "#0A84FF"
    @AppStorage("progressBarColorHex") private var progressBarColorHex = "#34C759"
    @AppStorage("matchProgressBarToAccent") private var matchProgressBarToAccent = false
    
    var engine = DownloadEngine.shared

    var dragPayload: URL {
        return item.status == .completed ? item.destinationURL : item.url
    }
    
    var fileIcon: NSImage {
        let ext = (item.filename as NSString).pathExtension
        return SharedIconCache.shared.icon(for: ext)
    }

    var dynamicTextColor: Color {
        isSelected ? Color(hex: accentColorHex).accessibleText : .primary
    }
    
    var displaySubtitle: String {
        if item.type == .batch { return "\(item.subFiles.count) Sub-files" }
        let fullStr = item.url.absoluteString
        
        let isLong = fullStr.utf8.count > 150
        
        if item.type == .torrent || isLong {
            return isLong ? String(fullStr.prefix(150)) + "..." : fullStr
        }
        return item.url.host ?? fullStr
    }

    var body: some View {
        mainRow
            .background(isSelected ? Color(hex: accentColorHex) : Color.clear)
            .draggable(dragPayload)
    }
    
    var mainRow: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                if (item.type == .torrent || item.type == .batch) && (!item.subFiles.isEmpty || item.status == .downloading) {
                    Button(action: { isExpanded.toggle() }) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(isSelected ? dynamicTextColor : .secondary)
                            .frame(width: 12, height: 16)
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: 12, height: 16)
                }
                
                Image(nsImage: fileIcon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                    .padding(.leading, item.subFiles.isEmpty ? -20 : 0)
                
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.filename)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(isSelected ? dynamicTextColor : .primary)
                    Text(displaySubtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? dynamicTextColor.opacity(0.7) : .secondary)
                        .lineLimit(1)
                }
            }
            .frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)

            StatusPill(status: item.status, isSelected: isSelected, accentColorHex: accentColorHex)
                .frame(width: 100, alignment: .leading)

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
            .frame(width: 110, alignment: .leading)

            Text(item.type.rawValue)
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? dynamicTextColor.opacity(0.85) : .primary)
                .lineLimit(1)
                .frame(width: 65, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.status == .downloading ? item.formattedSpeed : "0B/s")
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? dynamicTextColor.opacity(0.85) : .secondary)
                    .lineLimit(1)
                
                if item.status == .downloading, let eta = item.formattedETA {
                    Text(eta)
                        .font(.system(size: 10))
                        .foregroundStyle(isSelected ? dynamicTextColor.opacity(0.7) : Color.secondary.opacity(0.7))
                        .lineLimit(1)
                }
            }
            .frame(width: 70, alignment: .leading)

        }
        .padding(.horizontal, 8)
        .padding(.vertical, isCompactList ? 4 : 8)
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

// ── SubFile Row ──────────────────────────────────
struct SubFileRow: View {
    let parent: DownloadItem
    let index: Int
    let isSelected: Bool
    var engine = DownloadEngine.shared

    @AppStorage("accentColorHex") private var accentColorHex = "#0A84FF"
    @AppStorage("matchBadgesToAccent") private var matchBadgesToAccent = false
    @AppStorage("completedColorHex")   private var completedColorHex   = "#34C759"
    @AppStorage("stoppedColorHex")     private var stoppedColorHex     = "#FF9500"
    
    @Environment(\.colorScheme) private var colorScheme

    var dynamicTextColor: Color {
        isSelected ? Color(hex: accentColorHex).accessibleText : .primary
    }
    
    var completedColor: Color {
        let baseColor = Color(hex: completedColorHex)
        let matchedColor = matchBadgesToAccent ? baseColor.matchingThemeVisualWeight(of: Color(hex: accentColorHex)) : baseColor
        return matchedColor.adaptedForScheme(colorScheme)
    }
    
    var pausedColor: Color {
        let baseColor = Color(hex: stoppedColorHex)
        let matchedColor = matchBadgesToAccent ? baseColor.matchingThemeVisualWeight(of: Color(hex: accentColorHex)) : baseColor
        return matchedColor.adaptedForScheme(colorScheme)
    }
    
    var file: SubFile {
        if index < parent.subFiles.count {
            return parent.subFiles[index]
        }
        return SubFile(id: UUID(), index: 0, path: "", filename: "", totalBytes: 0, downloadedBytes: 0, isStopped: false)
    }

    var isFinished: Bool {
        file.totalBytes > 0 && file.downloadedBytes >= file.totalBytes
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc")
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? dynamicTextColor.opacity(0.8) : .secondary)
                .frame(width: 16)
            
            Text(file.filename)
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? dynamicTextColor.opacity(0.9) : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            let isEffectivelyPaused = parent.status == .stopped || parent.status == .failed || file.isStopped
            
            Text(formatBytes(file.downloadedBytes) + (file.totalBytes > 0 ? " / " + formatBytes(file.totalBytes) : ""))
                .font(.system(size: 10))
                .foregroundStyle(isSelected ? dynamicTextColor.opacity(0.7) : (isEffectivelyPaused && !isFinished ? Color.secondary.opacity(0.5) : Color.secondary))
                .frame(width: 110, alignment: .trailing)
            
            if isFinished {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? dynamicTextColor : completedColor)
                    .frame(width: 44, alignment: .trailing)
            } else if parent.type == .torrent || parent.type == .batch {
                Button(action: {
                    var updated = parent.subFiles
                    if index < updated.count {
                        updated[index].isStopped.toggle()
                        parent.subFiles = updated
                        engine.items = engine.items
                        
                        if parent.status == .stopped || parent.status == .failed {
                            if !parent.subFiles[index].isStopped {
                                engine.resume(parent, resumeSubFiles: false)
                            } else {
                                engine.persist()
                            }
                        } else {
                            engine.updateTorrentSelection(for: parent)
                        }
                    }
                }) {
                    Image(systemName: isEffectivelyPaused ? "play.circle.fill" : "pause.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(isEffectivelyPaused ? (isSelected ? dynamicTextColor : pausedColor) : (isSelected ? dynamicTextColor : Color(hex: accentColorHex)))
                }
                .buttonStyle(.plain)
                .help(isEffectivelyPaused ? "Resume File" : "Pause File")
                .frame(width: 44, alignment: .trailing)
            } else {
                Spacer().frame(width: 44)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .padding(.leading, 32)
        .background(isSelected ? Color(hex: accentColorHex) : Color.clear)
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
