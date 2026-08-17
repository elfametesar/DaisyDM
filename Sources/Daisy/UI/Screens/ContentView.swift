import SwiftUI
import AppKit
import UniformTypeIdentifiers

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

struct AddDownloadPayload: Identifiable {
    let id = UUID()
    let text: String
}

struct ContentView: View {
    var engine = DownloadEngine.shared
    @State private var selectedFilter: SidebarFilter = .all
    @State private var selectedItems: Set<UUID> = []
    @State private var showingSettings = false
    @AppStorage("showingDetailPanel") private var showingDetailPanel = true
    
    // UI Logic Triggers
    @State private var addDownloadPayload: AddDownloadPayload? = nil
    
    @State private var searchText = ""
    @State private var isDropTargeted = false
    @State private var itemsToRemove: RemovalContext? = nil
    
    @State private var showingDuplicateAlert = false
    @State private var duplicateAddRequest: DuplicateAddRequest? = nil
    
    @AppStorage("isCompactList") private var isCompactList = false
    @AppStorage("isCompactSidebar") private var isCompactSidebar = false
    @AppStorage("accentColorHex") private var accentColorHex = "#0A84FF"
    
    @AppStorage("askBeforeRemoving") private var askBeforeRemoving = true
    @AppStorage("defaultRemoveAction") private var defaultRemoveAction = "keep"
    
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
            .sheet(item: $addDownloadPayload) { payload in
                AddDownloadSheet(initialURLText: payload.text, onClose: {
                    addDownloadPayload = nil
                })
            }
            .sheet(isPresented: $showingSettings) { SettingsView() }
            .sheet(item: $itemsToRemove) { context in
                RemoveDialog(items: context.items) { trash, remember in
                    if remember {
                        askBeforeRemoving = false
                        defaultRemoveAction = trash ? "trash" : "keep"
                    }
                    engine.remove(context.items, trashFile: trash)
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
        NavigationSplitView(columnVisibility: .constant(.all)) {
            sidebarColumn
        } detail: {
            contentAndDetailColumn
        }
        .toolbar(removing: .sidebarToggle)
        .onReceive(NotificationCenter.default.publisher(for: .showAddDownload)) { _ in
            addDownloadPayload = AddDownloadPayload(text: "")
        }
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
        .onChange(of: engine.items.map { $0.id }) { oldIds, newIds in
            let oldSet = Set(oldIds)
            let newSet = Set(newIds)
            let addedIds = newSet.subtracting(oldSet)
            
            if !addedIds.isEmpty {
                selectedItems = addedIds
            } else {
                selectedItems.formIntersection(newSet)
            }
        }
        .onDrop(of: [.url, .fileURL, .plainText], isTargeted: $isDropTargeted) { providers in
            handleProviders(providers)
            return true
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
            .navigationSplitViewColumnWidth(
                min: isCompactSidebar ? 105 : 170,
                ideal: isCompactSidebar ? 105 : 190,
                max: isCompactSidebar ? 105 : 220
            )
    }

    @ViewBuilder
    private var contentAndDetailColumn: some View {
        HSplitView {
            contentColumn
                .frame(minWidth: showingDetailPanel ? 500 : 320, idealWidth: showingDetailPanel ? 680 : 700, maxWidth: .infinity)
                .layoutPriority(1)

            if showingDetailPanel {
                detailColumn
                    .frame(minWidth: 430, idealWidth: 450, maxWidth: .infinity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showingDetailPanel)
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
        .toolbar {
            ToolbarItemGroup {
                Button(action: { isCompactList.toggle() }) {
                    Label(isCompactList ? "Relaxed View" : "Compact View", systemImage: isCompactList ? "list.dash" : "list.bullet")
                }
                .help(isCompactList ? "Switch to Relaxed View" : "Switch to Compact View")

                Button(action: { isCompactSidebar.toggle() }) {
                    Label(isCompactSidebar ? "Expand Sidebar" : "Shrink Sidebar", systemImage: isCompactSidebar ? "sidebar.left" : "sidebar.leading")
                }
                .help(isCompactSidebar ? "Expand Sidebar" : "Shrink Sidebar to Icons")

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
                .menuStyle(.button)
                .tint(.primary)

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

            ToolbarItem(placement: .primaryAction) {
                Button(action: { showingDetailPanel.toggle() }) {
                    Label(showingDetailPanel ? "Hide Details" : "Show Details", systemImage: showingDetailPanel ? "sidebar.trailing" : "sidebar.right")
                }
                .help(showingDetailPanel ? "Hide Details" : "Show Details")
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

    private func handleProviders(_ providers: [NSItemProvider]) {
        let group = DispatchGroup()
        let lock = NSLock()
        var collectedPaths: [String] = []
        
        for provider in providers {
            group.enter()
            
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    var extractedURL: URL? = nil
                    if let data = item as? Data {
                        extractedURL = URL(dataRepresentation: data, relativeTo: nil)
                    } else if let url = item as? URL {
                        extractedURL = url
                    }
                    
                    if let url = extractedURL, url.pathExtension.lowercased() == "torrent" {
                        lock.lock()
                        collectedPaths.append(url.path(percentEncoded: false))
                        lock.unlock()
                    }
                    group.leave()
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url = url, (url.scheme?.hasPrefix("http") == true || url.scheme == "magnet") {
                        lock.lock()
                        collectedPaths.append(url.absoluteString)
                        lock.unlock()
                    }
                    group.leave()
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                _ = provider.loadObject(ofClass: String.self) { str, _ in
                    if let str = str {
                        let lines = str.components(separatedBy: .newlines)
                        for line in lines {
                            let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
                            if let textUrl = URL(string: clean), (textUrl.scheme?.hasPrefix("http") == true || textUrl.scheme == "magnet") {
                                lock.lock()
                                collectedPaths.append(clean)
                                lock.unlock()
                            }
                        }
                    }
                    group.leave()
                }
            } else {
                group.leave()
            }
        }
        
        group.notify(queue: .main) {
            if !collectedPaths.isEmpty {
                self.addDownloadPayload = AddDownloadPayload(text: collectedPaths.joined(separator: "\n"))
            }
        }
    }

    private func requestRemove(items: [DownloadItem]) {
        let snapshot = Array(items)
        guard !snapshot.isEmpty else { return }
        if askBeforeRemoving {
            itemsToRemove = RemovalContext(items: snapshot)
        } else {
            let trash = (defaultRemoveAction == "trash")
            engine.remove(snapshot, trashFile: trash)
        }
    }

    private func handlePaste() {
        let pb = NSPasteboard.general
        var collectedPaths: [String] = []
        
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            for url in urls {
                if url.isFileURL && url.pathExtension.lowercased() == "torrent" {
                    collectedPaths.append(url.path(percentEncoded: false))
                } else if url.scheme?.hasPrefix("http") == true || url.scheme == "magnet" {
                    collectedPaths.append(url.absoluteString)
                }
            }
        } else if let str = pb.string(forType: .string) {
            let words = str.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            for clean in words {
                if let url = URL(string: clean), (url.scheme?.hasPrefix("http") == true || url.scheme == "magnet") {
                    collectedPaths.append(clean)
                } else if clean.hasPrefix("magnet:?") {
                    collectedPaths.append(clean)
                } else if clean.hasPrefix("/") && clean.lowercased().hasSuffix(".torrent") {
                    collectedPaths.append(clean)
                }
            }
        }
        
        if !collectedPaths.isEmpty {
            self.addDownloadPayload = AddDownloadPayload(text: collectedPaths.joined(separator: "\n"))
        }
    }
}

struct EmptyDetailView: View {
    @AppStorage("enableBackgroundTint") private var enableBackgroundTint = false
    @AppStorage("accentColorHex") private var accentColorHex = "#0A84FF"
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sidebar.trailing").font(.system(size: 40)).foregroundStyle(.tertiary)
            Text("Select a download to inspect").font(.callout).foregroundStyle(.tertiary)
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
            Image(systemName: "square.stack.3d.up").font(.system(size: 40)).foregroundStyle(.tertiary)
            Text("\(count) items selected").font(.callout).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(enableBackgroundTint ? Color(hex: accentColorHex).opacity(0.04) : Color(NSColor.controlBackgroundColor))
    }
}
