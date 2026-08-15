import SwiftUI
import AppKit
import Combine

enum MenuBarLayout: Int, CaseIterable, Identifiable {
    case onlyBar = 0
    case barSpeed = 1
    case barTransfer = 2
    case textSpeed = 3
    case minimal = 4
    case transferOnly = 5

    var id: Int { self.rawValue }
    var title: String {
        switch self {
        case .onlyBar:      return "Progress Bar"
        case .barSpeed:     return "Progress Bar + Speed"
        case .barTransfer:  return "Progress Bar + Download Stats"
        case .textSpeed:    return "Percentage + Speed"
        case .minimal:      return "Percentage"
        case .transferOnly: return "Download Stats"
        }
    }
}

class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var intrinsicContentSize: NSSize { .zero }
}

@MainActor
class TrayViewModel: ObservableObject {
    static let shared = TrayViewModel()
    @Published var trayedDownloads: [DownloadItem] = []
    @AppStorage("pinnedTrayItemId") var pinnedItemId: String = ""
    let openItemSubject = PassthroughSubject<UUID, Never>()

    @Published var layout: MenuBarLayout = {
        let val = UserDefaults.standard.integer(forKey: "trayLayout")
        return MenuBarLayout(rawValue: val) ?? .barSpeed
    }() {
        didSet {
            UserDefaults.standard.set(layout.rawValue, forKey: "trayLayout")
            TrayController.shared.updateMenuTicks()
        }
    }

    private var trayedItemIDs: Set<UUID> = []
    private var timer: Timer?

    private init() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.syncDownloads() }
        }
    }

    func addToTray(_ id: UUID) { trayedItemIDs.insert(id); syncDownloads() }

    func removeFromTray(_ id: UUID) {
        trayedItemIDs.remove(id)
        syncDownloads()
        if trayedItemIDs.isEmpty { TrayController.shared.closePopover() }
    }

    private func syncDownloads() {
        let currentItems = DownloadEngine.shared.items.filter { trayedItemIDs.contains($0.id) }
        let activeItems = currentItems.filter { $0.progress < 1.0 }
        if trayedDownloads.count != currentItems.count {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { trayedDownloads = currentItems }
        } else { trayedDownloads = currentItems }
        trayedItemIDs.formIntersection(Set(activeItems.map { $0.id }))
        if trayedItemIDs.isEmpty { TrayController.shared.closePopover() }
    }

    var featuredItem: DownloadItem? {
        if let pinned = trayedDownloads.first(where: { $0.id.uuidString == pinnedItemId }) { return pinned }
        return trayedDownloads.max(by: { $0.dateAdded < $1.dateAdded })
    }

    func pin(item: DownloadItem) { pinnedItemId = pinnedItemId == item.id.uuidString ? "" : item.id.uuidString }
}

@MainActor
class TrayController: NSObject, ObservableObject {
    static let shared = TrayController()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let rightClickMenu = NSMenu()
    private var cancellables = Set<AnyCancellable>()
    private var popoverMonitor: Any?
    private var mouseDownMonitor: Any?
    private var mouseUpMonitor: Any?
    @Published var isButtonPressed = false

    func setup() {
        setupRightClickMenu()
        popover.contentViewController = NSHostingController(rootView: TrayPopoverView(viewModel: TrayViewModel.shared))
        popover.behavior = .transient
        TrayViewModel.shared.$trayedDownloads
            .combineLatest(TrayViewModel.shared.$layout)
            .sink { [weak self] items, _ in
                self?.updateTrayVisibility(hasItems: !items.isEmpty)
                self?.updatePopoverSize(itemCount: items.count)
            }
            .store(in: &cancellables)
    }

    func closePopover() { popover.performClose(nil); stopPopoverMonitor() }

    private func startPopoverMonitor() {
        if popoverMonitor == nil {
            popoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                if self?.popover.isShown == true { self?.closePopover() }
            }
        }
    }

    private func stopPopoverMonitor() {
        if let m = popoverMonitor { NSEvent.removeMonitor(m); popoverMonitor = nil }
    }

    private func updatePopoverSize(itemCount: Int) {
        guard itemCount > 0 else { return }
        let exactHeight = CGFloat(min(itemCount, 4)) * 64 + 16
        guard popover.contentSize.height != exactHeight else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.allowsImplicitAnimation = true
            popover.contentSize = NSSize(width: 340, height: exactHeight)
        }
    }

    private func setupRightClickMenu() {
        for layout in MenuBarLayout.allCases {
            let item = NSMenuItem(title: layout.title, action: #selector(setLayout(_:)), keyEquivalent: "")
            item.tag = layout.rawValue
            item.target = self
            rightClickMenu.addItem(item)
        }
    }

    @objc private func setLayout(_ sender: NSMenuItem) {
        TrayViewModel.shared.layout = MenuBarLayout(rawValue: sender.tag) ?? .barSpeed
    }

    func updateMenuTicks() {
        let current = TrayViewModel.shared.layout.rawValue
        rightClickMenu.items.forEach { $0.state = $0.tag == current ? .on : .off }
    }

    static func pillWidth(for layout: MenuBarLayout, speed: String, transfer: String = "") -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .semibold)]
        switch layout {
        case .onlyBar: return 66
        case .barSpeed:
            let textW = ceil((speed as NSString).size(withAttributes: attrs).width)
            return 40 + 8 + textW + 20
        case .barTransfer:
            let textW = ceil((transfer as NSString).size(withAttributes: attrs).width)
            return 40 + 8 + textW + 20
        case .textSpeed:
            let boldAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .bold)]
            let regularAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .regular)]
            let pctW = ceil(("100%" as NSString).size(withAttributes: boldAttrs).width)
            let speedW = ceil((speed as NSString).size(withAttributes: regularAttrs).width)
            return pctW + 6 + speedW + 8
        case .minimal:
            let boldAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .bold)]
            return ceil(("100%" as NSString).size(withAttributes: boldAttrs).width) + 8
        case .transferOnly:
            let textW = ceil((transfer as NSString).size(withAttributes: attrs).width)
            return textW + 20
        }
    }

    func setDynamicLength(_ pillWidth: CGFloat) {
        guard let item = statusItem else { return }
        guard !TrayViewModel.shared.trayedDownloads.isEmpty else { item.length = 0; return }
        item.length = pillWidth
    }

    private func updateTrayVisibility(hasItems: Bool) {
        if hasItems && statusItem == nil {
            let featuredItem = TrayViewModel.shared.featuredItem
            let speed = featuredItem?.formattedSpeed ?? "0 KB/s"
            let transfer = featuredItem.map { $0.totalBytes > 0 ? "\($0.formattedDownloaded)/\($0.formattedSize)" : $0.formattedDownloaded } ?? "0 KB"
            let initialLength = TrayController.pillWidth(for: TrayViewModel.shared.layout, speed: speed, transfer: transfer)
            statusItem = NSStatusBar.system.statusItem(withLength: initialLength)
            guard let button = statusItem?.button else { return }
            button.action = #selector(handleMouseClick(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            (button.cell as? NSButtonCell)?.highlightsBy = []
            (button.cell as? NSButtonCell)?.showsStateBy = []

            let hv = PassThroughHostingView(rootView: TrayLabelView(viewModel: TrayViewModel.shared, controller: self))
            hv.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(hv)
            NSLayoutConstraint.activate([
                hv.topAnchor.constraint(equalTo: button.topAnchor),
                hv.bottomAnchor.constraint(equalTo: button.bottomAnchor),
                hv.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                hv.trailingAnchor.constraint(equalTo: button.trailingAnchor)
            ])

            mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self, weak button] event in
                guard let button, button.window != nil, button.window == event.window else { return event }
                let loc = button.convert(event.locationInWindow, from: nil)
                if button.bounds.contains(loc) { self?.isButtonPressed = true }
                return event
            }
            mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
                self?.isButtonPressed = false
                return event
            }
        } else if !hasItems, let item = statusItem {
            if let m = mouseDownMonitor { NSEvent.removeMonitor(m); mouseDownMonitor = nil }
            if let m = mouseUpMonitor { NSEvent.removeMonitor(m); mouseUpMonitor = nil }
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    @objc private func handleMouseClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            statusItem?.menu = rightClickMenu
            statusItem?.button?.performClick(nil)
            statusItem?.menu = nil
        } else {
            let items = TrayViewModel.shared.trayedDownloads
            if items.count == 1, let item = items.first { TrayViewModel.shared.openItemSubject.send(item.id) }
            else if popover.isShown { closePopover() }
            else {
                popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
                startPopoverMonitor()
                if let win = popover.contentViewController?.view.window {
                    win.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
    }
}

struct TrayLabelView: View {
    @ObservedObject var viewModel: TrayViewModel
    @ObservedObject var controller: TrayController
    @Environment(\.openWindow) private var openWindow
    private var isPressed: Bool { controller.isButtonPressed }

    var body: some View {
        HStack(spacing: 0) {
            if let item = viewModel.featuredItem {
                switch viewModel.layout {
                case .onlyBar: progressBarView(progress: item.progress)
                case .barSpeed: progressBarWithText(progress: item.progress, text: item.formattedSpeed)
                case .barTransfer: progressBarWithText(progress: item.progress, text: transferText(for: item))
                case .textSpeed: textSpeedView(progress: item.progress, speed: item.formattedSpeed)
                case .minimal: minimalView(progress: item.progress)
                case .transferOnly: transferOnlyView(transfer: transferText(for: item))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { updateLength() }
        .onChange(of: viewModel.layout) { _, _ in updateLength() }
        .onChange(of: viewModel.featuredItem?.formattedSpeed) { _, _ in updateLength() }
        .onChange(of: viewModel.featuredItem?.downloadedBytes) { _, _ in updateLength() }
        .onChange(of: viewModel.featuredItem?.totalBytes) { _, _ in updateLength() }
        .onReceive(viewModel.$trayedDownloads) { items in
            for item in items where item.progress >= 1.0 {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(value: item.id)
                viewModel.removeFromTray(item.id)
            }
        }
        .onReceive(viewModel.openItemSubject) { id in
            NSApp.activate(ignoringOtherApps: true)
            openWindow(value: id)
            viewModel.removeFromTray(id)
        }
    }

    private func transferText(for item: DownloadItem) -> String {
        item.totalBytes > 0 ? "\(item.formattedDownloaded)/\(item.formattedSize)" : item.formattedDownloaded
    }

    private func updateLength() {
        let item = viewModel.featuredItem
        let speed = item?.formattedSpeed ?? "0 KB/s"
        let transfer = item.map { transferText(for: $0) } ?? "0 KB"
        TrayController.shared.setDynamicLength(TrayController.pillWidth(for: viewModel.layout, speed: speed, transfer: transfer))
    }

    @ViewBuilder
    private func progressBarView(progress: Double) -> some View {
        ProgressView(value: progress, total: 1.0)
            .progressViewStyle(.linear)
            .frame(width: 46)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color.primary.opacity(isPressed ? 0.22 : 0.12)))
    }

    @ViewBuilder
    private func progressBarWithText(progress: Double, text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView(value: progress, total: 1.0)
                .progressViewStyle(.linear)
                .frame(width: 40)
            Text(text)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.primary)
                .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.primary.opacity(isPressed ? 0.22 : 0.12)))
    }

    @ViewBuilder
    private func textSpeedView(progress: Double, speed: String) -> some View {
        HStack(spacing: 6) {
            Text("\(Int(progress * 100))%").font(.system(size: 11, weight: .bold))
            Text(speed).font(.system(size: 11, weight: .regular))
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(isPressed ? 0.12 : 0)))
    }

    @ViewBuilder
    private func minimalView(progress: Double) -> some View {
        Text("\(Int(progress * 100))%")
            .font(.system(size: 11, weight: .bold))
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(isPressed ? 0.12 : 0)))
    }

    @ViewBuilder
    private func transferOnlyView(transfer: String) -> some View {
        Text(transfer)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.primary)
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.primary.opacity(isPressed ? 0.22 : 0.12)))
    }
}

struct TrayPopoverView: View {
    @ObservedObject var viewModel: TrayViewModel
    @AppStorage("accentColorHex") private var accentColorHex = "#0A84FF"

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                ForEach(viewModel.trayedDownloads) { item in
                    let isLast = item.id == viewModel.trayedDownloads.last?.id
                    let isFeatured = (viewModel.pinnedItemId == item.id.uuidString) || (viewModel.trayedDownloads.count == 1)
                    TrayItemRow(item: item, isFeatured: isFeatured, accentColor: Color(hex: accentColorHex), isLast: isLast, viewModel: viewModel)
                        .frame(height: 64)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    if !isLast { Divider().opacity(0.3).padding(.horizontal, 16) }
                }
            }
            .padding(.vertical, 8)
        }
        .frame(width: 340)
    }
}

struct TrayItemRow: View {
    let item: DownloadItem
    let isFeatured: Bool
    let accentColor: Color
    let isLast: Bool
    @ObservedObject var viewModel: TrayViewModel
    @Environment(\.openWindow) private var openWindow
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button { viewModel.pin(item: item) } label: {
                ZStack {
                    Circle().fill(isFeatured ? accentColor : Color.primary.opacity(0.1))
                    Image(systemName: "pin.fill").font(.system(size: 10, weight: .bold)).foregroundColor(isFeatured ? .white : .secondary.opacity(0.4))
                }
            }
            .buttonStyle(.plain)
            .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 0) {
                    Text(item.filename).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(item.formattedSpeed).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Spacer().frame(width: 14)
                    Button {
                        if item.status == .downloading { DownloadEngine.shared.stop(item) }
                        else { DownloadEngine.shared.resume(item) }
                    } label: {
                        Image(systemName: item.status == .downloading ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 16)).foregroundStyle(.secondary.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
                }

                HStack(alignment: .center, spacing: 0) {
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.35)).frame(maxWidth: .infinity, maxHeight: 6)
                        GeometryReader { geo in
                            Capsule().fill(item.status == .failed ? Color.red : accentColor).frame(width: geo.size.width * CGFloat(item.progress), height: 6)
                        }
                    }
                    .frame(height: 6)
                    Spacer().frame(width: 14)
                    Button {
                        DownloadEngine.shared.stop(item)
                        viewModel.removeFromTray(item.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundStyle(.secondary.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 64)
        .contentShape(Rectangle())
        .background(isHovering ? Color.primary.opacity(0.06) : Color.clear)
        .onHover { isHovering = $0 }
        .onTapGesture {
            openWindow(value: item.id)
            viewModel.removeFromTray(item.id)
        }
        .overlay(alignment: .bottom) {
            if !isLast { Divider().padding(.horizontal, 16) }
        }
    }
}