import SwiftUI
import AppKit

enum SidebarFilter: String, CaseIterable, Identifiable {
    case all       = "All Downloads"
    case active    = "Active"
    case stopped   = "Stopped"
    case completed = "Completed"
    case failed    = "Failed"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .all:       return "arrow.down.circle"
        case .active:    return "arrow.down.circle.fill"
        case .stopped:   return "stop.circle"
        case .completed: return "checkmark.circle"
        case .failed:    return "exclamationmark.triangle"
        }
    }

    func matches(_ item: DownloadItem) -> Bool {
        switch self {
        case .all:       return true
        case .active:    return item.status == .downloading || item.status == .queued
        case .stopped:   return item.status == .stopped
        case .completed: return item.status == .completed
        case .failed:    return item.status == .failed
        }
    }
}

struct RemovalContext: Identifiable {
    let id = UUID()
    let items: [DownloadItem]
}

struct DuplicateAddRequest {
    let urls: [URL]
    let destination: URL?
    let connections: Int
}

struct ContentView: View {
    var engine = DownloadEngine.shared
    @State private var selectedFilter: SidebarFilter = .all
    @State private var selectedItems: Set<UUID> = []
    @State private var showingSettings = false
    @State private var showingAddDownload = false
    @State private var searchText = ""
    @State private var isDropTargeted = false
    @State private var itemsToRemove: RemovalContext? = nil
    
    @State private var showingDuplicateAlert = false
    @State private var duplicateAddRequest: DuplicateAddRequest? = nil
    
    @AppStorage("isCompactList") private var isCompactList = false
    @AppStorage("accentColorHex") private var accentColorHex = "#0A84FF"
    
    // Shared sorting state for the Toolbar Menu
    @AppStorage("sortColumn") private var sortColumn: SortColumn = .dateAdded
    @AppStorage("sortAscending") private var sortAscending: Bool = false
    
    var customAccent: Color { Color(hex: accentColorHex) }

    @Environment(\.openWindow) private var openWindow

    var filtered: [DownloadItem] {
        engine.items
            .filter { selectedFilter.matches($0) }
            .filter { searchText.isEmpty || $0.filename.localizedCaseInsensitiveContains(searchText) }
    }

    var targetItems: [DownloadItem] {
        engine.items.filter { selectedItems.contains($0.id) }
    }

    var canShowProgressWindow: Bool {
        guard selectedItems.count == 1, let id = selectedItems.first,
              let item = engine.items.first(where: { $0.id == id }) else { return false }
        return item.status == .downloading || item.status == .queued
    }

    var body: some View {
        mainLayout
            .sheet(isPresented: $showingAddDownload) {
                AddDownloadSheet(onClose: { showingAddDownload = false })
            }
            .sheet(isPresented: $showingSettings) { SettingsView().interactiveDismissDisabled() }
            .sheet(item: $itemsToRemove) { context in
                RemoveDialog(items: context.items) { trash, remember in
                    if remember { UserDefaults.standard.set(trash ? "trash" : "keep", forKey: "removeBehavior") }
                    context.items.forEach { engine.remove($0, trashFile: trash) }
                    itemsToRemove = nil
                } onCancel: { itemsToRemove = nil }
                .interactiveDismissDisabled()
            }
            .alert(duplicateAddRequest?.urls.count ?? 1 > 1 ? "Duplicate Downloads" : "Duplicate Download", isPresented: $showingDuplicateAlert) {
                Button("Add Anyway") {
                    if let req = duplicateAddRequest {
                        engine.addDownload(urls: req.urls, destination: req.destination, connections: req.connections)
                    }
                }
                Button("Skip", role: .cancel) { }
            } message: {
                if let count = duplicateAddRequest?.urls.count, count > 1 {
                    Text("\(count) of these URLs are already in your list. Do you want to add them anyway?")
                } else {
                    Text("This URL is already in your download list. Do you want to add it again?")
                }
            }
            .background {
                Button("") { handlePaste() }.keyboardShortcut("v", modifiers: .command).opacity(0)
            }
            .tint(customAccent)
    }

    private var mainLayout: some View {
        NavigationSplitView {
            sidebarColumn
        } content: {
            contentColumn
        } detail: {
            detailColumn
        }
        .onReceive(NotificationCenter.default.publisher(for: .showAddDownload)) { _ in showingAddDownload = true }
        .onReceive(NotificationCenter.default.publisher(for: .showSettings)) { _ in showingSettings = true }
        .onReceive(NotificationCenter.default.publisher(for: .openProgressWindow)) { notif in
            if let id = notif.userInfo?["id"] as? UUID { openWindow(value: id) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSelectedProgressWindow)) { _ in
            if canShowProgressWindow, let id = selectedItems.first { openWindow(value: id) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestAddDownload)) { notif in
            if let url = notif.userInfo?["url"] as? URL {
                processAddRequest(urls: [url], destination: notif.userInfo?["destination"] as? URL)
            }
        }
        .onChange(of: engine.items.count) { _, _ in
            let existingIds = Set(engine.items.map { $0.id })
            selectedItems.formIntersection(existingIds)
        }
        .dropDestination(for: URL.self) { urls, _ in handleDrop(urls: urls) } isTargeted: { targeted in
            isDropTargeted = targeted && activeDragHasValidExternalItems()
        }
        .dropDestination(for: String.self) { strings, _ in handleDrop(strings: strings) } isTargeted: { targeted in
            isDropTargeted = targeted && activeDragHasValidExternalItems()
        }
        .overlay {
            if isDropTargeted {
                customAccent.opacity(0.15).allowsHitTesting(false).border(customAccent, width: 3).ignoresSafeArea()
            }
        }
    }

    @ViewBuilder
    private var sidebarColumn: some View {
        SidebarView(selected: $selectedFilter, engine: engine, onSettings: { showingSettings = true })
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 220)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                }
            }
    }

    @ViewBuilder
    private var contentColumn: some View {
        VStack(spacing: 0) {
            DownloadListView(
                items: filtered,
                selected: $selectedItems,
                search: $searchText
            ) { items in requestRemove(items: items) }
        }
        .navigationSplitViewColumnWidth(min: 500, ideal: 680)
        .toolbar {
            ToolbarItemGroup {
                Button(action: { isCompactList.toggle() }) { Label(isCompactList ? "Relaxed View" : "Compact View", systemImage: isCompactList ? "list.dash" : "list.bullet") }
                .help(isCompactList ? "Switch to Relaxed View" : "Switch to Compact View")
                
                Menu {
                    Picker("Sort By", selection: $sortColumn) {
                        Text("Date Modified").tag(SortColumn.dateModified)
                        Text("Date Added").tag(SortColumn.dateAdded)
                        Divider()
                        Text("Name").tag(SortColumn.name)
                        Text("Status").tag(SortColumn.status)
                        Text("Transfer").tag(SortColumn.transfer)
                        Text("Type").tag(SortColumn.type)
                        Text("Speed").tag(SortColumn.speed)
                    }
                    Divider()
                    Toggle("Sort Ascending", isOn: $sortAscending)
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .help("Sort Downloads")

                Button { NotificationCenter.default.post(name: .showAddDownload, object: nil) } label: { Label("New Download", systemImage: "plus") }
                    .help("New Download (⌘N)")

                let canResume = targetItems.contains(where: { $0.status == .stopped || $0.status == .failed })
                Button(action: { targetItems.forEach { engine.resume($0) } }) { Label("Resume", systemImage: "play.fill") }
                .disabled(!canResume).help("Resume Selected")

                let canStop = targetItems.isEmpty ? engine.items.contains(where: { $0.status == .downloading || $0.status == .queued }) : targetItems.contains(where: { $0.status == .downloading || $0.status == .queued })
                Button(action: { targetItems.isEmpty ? engine.stopAll() : targetItems.forEach { engine.stop($0) } }) { Label(targetItems.isEmpty ? "Stop All" : "Stop", systemImage: "stop.fill") }
                .disabled(!canStop).help(targetItems.isEmpty ? "Stop All" : "Stop Selected")

                Button(action: { targetItems.forEach { engine.retry($0) } }) { Label("Restart", systemImage: "arrow.clockwise") }
                .disabled(targetItems.isEmpty).help("Restart Selected")

                Button(action: { requestRemove(items: targetItems) }) { Label("Remove", systemImage: "trash") }
                .disabled(targetItems.isEmpty).help("Remove Selected")

                if canShowProgressWindow {
                    Button(action: { if let id = selectedItems.first { openWindow(value: id) } }) { Label("Progress", systemImage: "macwindow") }
                    .help("Show Progress Window")
                }
            }
        }
    }
    
    @ViewBuilder
    private var detailColumn: some View {
        Group {
            if selectedItems.count == 1,
               let firstId = selectedItems.first,
               let item = engine.items.first(where: { $0.id == firstId }) {
                DetailView(item: item) { item in requestRemove(items: [item]) }
                    .id(item.id)
                    .toolbar(removing: .title)
                    .toolbarBackground(.hidden, for: .windowToolbar)
            } else if selectedItems.count > 1 {
                MultipleSelectionView(count: selectedItems.count)
            } else {
                EmptyDetailView()
            }
        }
        .navigationSplitViewColumnWidth(min: 430, ideal: 450)
    }

    private func processAddRequest(urls: [URL], destination: URL? = nil, connections: Int = 16) {
        if urls.count == 1 {
            let u = urls[0]
            if engine.items.contains(where: { $0.url.absoluteString == u.absoluteString }) {
                duplicateAddRequest = DuplicateAddRequest(urls: [u], destination: destination, connections: connections)
                showingDuplicateAlert = true
            } else {
                engine.addDownload(urls: [u], destination: destination, connections: connections)
            }
        } else if urls.count > 1 {
            engine.addDownload(urls: urls, destination: destination, connections: connections)
        }
    }
    
    private func activeDragHasValidExternalItems() -> Bool {
        let pb = NSPasteboard(name: .drag)
        
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            for url in urls {
                let isInternal = engine.items.contains { $0.url == url || $0.destinationURL == url }
                let isValid = (url.isFileURL && url.pathExtension.lowercased() == "torrent") || url.scheme?.hasPrefix("http") == true || url.scheme == "magnet"
                if !isInternal && isValid { return true }
            }
        }
        
        if let strings = pb.readObjects(forClasses: [NSString.self], options: nil) as? [String] {
            for str in strings {
                if let url = URL(string: str.trimmingCharacters(in: .whitespaces)) {
                    let isInternal = engine.items.contains { $0.url == url || $0.destinationURL == url }
                    let isValid = url.scheme?.hasPrefix("http") == true || url.scheme == "magnet"
                    if !isInternal && isValid { return true }
                }
            }
        }
        return false
    }

    private func handleDrop(urls: [URL]) -> Bool {
        var handled = false
        var validURLs = [URL]()
        for url in urls {
            let isInternal = engine.items.contains { $0.url == url || $0.destinationURL == url }
            if isInternal { continue }
            
            let isTorrent = url.isFileURL && url.pathExtension.lowercased() == "torrent"
            if isTorrent || url.scheme?.hasPrefix("http") == true || url.scheme == "magnet" {
                validURLs.append(url)
                handled = true
            }
        }
        if !validURLs.isEmpty { processAddRequest(urls: validURLs) }
        return handled
    }
    
    private func handleDrop(strings: [String]) -> Bool {
        var handled = false
        var validURLs = [URL]()
        for str in strings {
            if let url = URL(string: str.trimmingCharacters(in: .whitespaces)) {
                let isInternal = engine.items.contains { $0.url == url || $0.destinationURL == url }
                if isInternal { continue }
                
                if url.scheme?.hasPrefix("http") == true || url.scheme == "magnet" {
                    validURLs.append(url)
                    handled = true
                }
            }
        }
        if !validURLs.isEmpty { processAddRequest(urls: validURLs) }
        return handled
    }

    private func requestRemove(items: [DownloadItem]) {
        let behavior = UserDefaults.standard.string(forKey: "removeBehavior") ?? "ask"
        if behavior == "trash" { items.forEach { engine.remove($0, trashFile: true) } }
        else if behavior == "keep" { items.forEach { engine.remove($0, trashFile: false) } }
        else { itemsToRemove = RemovalContext(items: items) }
    }

    private func handlePaste() {
        if let string = NSPasteboard.general.string(forType: .string) {
            let lines = string.components(separatedBy: .newlines).compactMap { URL(string: $0.trimmingCharacters(in: .whitespaces)) }.filter { $0.scheme?.hasPrefix("http") == true || $0.scheme == "magnet" }
            if !lines.isEmpty {
                NotificationCenter.default.post(name: .showAddDownload, object: nil)
            }
        }
    }
}

// MARK: - Helper Views

struct EmptyDetailView: View {
    @AppStorage("enableBackgroundTint") private var enableBackgroundTint = false
    @AppStorage("accentColorHex") private var accentColorHex = "#0A84FF"

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sidebar.trailing")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("Select a download to inspect")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(enableBackgroundTint ? Color(hex: accentColorHex).opacity(0.04) : Color(NSColor.controlBackgroundColor))
    }
}

struct MultipleSelectionView: View {
    let count: Int
    @AppStorage("enableBackgroundTint") private var enableBackgroundTint = false
    @AppStorage("accentColorHex") private var accentColorHex = "#0A84FF"

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("\(count) items selected")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(enableBackgroundTint ? Color(hex: accentColorHex).opacity(0.04) : Color(NSColor.controlBackgroundColor))
    }
}
