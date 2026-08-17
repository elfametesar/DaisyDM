import SwiftUI
import AppKit

// MARK: - Window Accessor
struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            self.window = view.window
            if let window = view.window {
                disableTabBarContextMenus(in: window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window {
            disableTabBarContextMenus(in: window)
        }
    }

    private func disableTabBarContextMenus(in window: NSWindow) {
        func visit(_ view: NSView) {
            if let tabView = view as? NSTabView {
                tabView.menu = nil
            }
            for subview in view.subviews {
                visit(subview)
            }
        }

        if let contentView = window.contentView {
            visit(contentView)
        }
    }
}

// MARK: - Progress tab-bar context menu disabler
struct TabBarContextMenuDisabler: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.isHidden = true
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.attach(to: nsView)
    }

    final class Coordinator {
        private weak var view: NSView?
        private var monitor: Any?

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }

        func attach(to view: NSView) {
            self.view = view
            guard monitor == nil else {
                installMenuSuppression()
                return
            }

            monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
                guard let self,
                      let ownerView = self.view,
                      let window = ownerView.window,
                      event.window === window,
                      let root = window.contentView,
                      let tabView = self.findTabView(in: root) else {
                    return event
                }

                let point = root.convert(event.locationInWindow, from: nil)
                if tabView.bounds.contains(tabView.convert(point, from: root)) {
                    return nil
                }

                return event
            }

            installMenuSuppression()
        }

        private func installMenuSuppression() {
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      let window = self.view?.window,
                      let content = window.contentView else { return }

                self.walk(content) { view in
                    view.menu = nil
                }
            }
        }

        private func findTabView(in view: NSView) -> NSTabView? {
            if let tabView = view as? NSTabView {
                return tabView
            }
            for subview in view.subviews {
                if let tabView = findTabView(in: subview) {
                    return tabView
                }
            }
            return nil
        }

        private func walk(_ view: NSView, _ body: (NSView) -> Void) {
            body(view)
            for subview in view.subviews {
                walk(subview, body)
            }
        }
    }
}

// MARK: - Visual Effect View
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - Action Button Style
struct ActionButtonStyle: ButtonStyle {
    let prominent: Bool
    let hex: String
    @Environment(\.colorScheme) var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(prominent ? Color(hex: hex).accessibleText : Color.primary.opacity(0.85))
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(prominent ? Color(hex: hex) : Color.primary.opacity(colorScheme == .dark ? 0.18 : 0.10))
            )
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}

// MARK: - Detail Row (shared by dialogs and detail views)
struct DetailRowView: View {
    let label: String
    let value: String
    var labelWidth: CGFloat = 80

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: labelWidth, alignment: .trailing)

            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(3)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Copy Link Button
struct CopyLinkButton: View {
    let url: String
    @State private var isHovered = false
    @State private var isCopied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url, forType: .string)
            withAnimation { isCopied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation { isCopied = false }
            }
        } label: {
            Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isCopied ? .green : .secondary)
                .padding(5)
                .background(isHovered ? Color.primary.opacity(0.08) : Color.clear, in: Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Copy Source URL")
    }
}

// MARK: - Sort Column
enum SortColumn: String {
    case dateAdded, dateModified, name, status, transfer, type, speed
}

// MARK: - Window chrome helper (shared by all floating windows)
func applyFloatingWindowStyle(window: NSWindow?) {
    guard let win = window else { return }
    win.styleMask.insert(.fullSizeContentView)
    win.titleVisibility = .hidden
    win.titlebarAppearsTransparent = true
    win.isMovableByWindowBackground = true
    win.backgroundColor = .clear
    win.isOpaque = false
    win.standardWindowButton(.closeButton)?.isHidden = false
    win.standardWindowButton(.miniaturizeButton)?.isHidden = false
    win.standardWindowButton(.zoomButton)?.isHidden = false
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s = String(s.dropFirst()) }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard let value = UInt64(s, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xFF) / 255
        let g = CGFloat((value >>  8) & 0xFF) / 255
        let b = CGFloat( value        & 0xFF) / 255
        self.init(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }
}

class DockProgressView: NSView {
    var progress: Double = 0.0 {
        didSet { needsDisplay = true }
    }
    
    private func getBarColor() -> NSColor {
        let defaults = UserDefaults.standard
        let match = defaults.bool(forKey: "matchProgressBarToAccent")
        let hexString = match ? (defaults.string(forKey: "accentColorHex") ?? "#0A84FF") : (defaults.string(forKey: "progressBarColorHex") ?? "#34C759")
        return NSColor(hex: hexString) ?? .systemGreen
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if let appIcon = NSImage(named: NSImage.applicationIconName) { appIcon.draw(in: bounds) }
        
        let inset: CGFloat = bounds.width * 0.12
        let cornerRadius: CGFloat = bounds.width * 0.18
        let barThick: CGFloat = 6.0
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let startY = rect.maxY - (rect.height * 0.45)
        let straightLen = startY - (rect.minY + cornerRadius)
        let arcLen = 0.5 * .pi * cornerRadius
        let bottomLen = rect.width - (2 * cornerRadius)
        let totalLen = (straightLen * 2) + (arcLen * 2) + bottomLen
        
        let bgPath = NSBezierPath()
        bgPath.move(to: NSPoint(x: rect.minX, y: startY))
        bgPath.line(to: NSPoint(x: rect.minX, y: rect.minY + cornerRadius))
        bgPath.appendArc(withCenter: NSPoint(x: rect.minX + cornerRadius, y: rect.minY + cornerRadius), radius: cornerRadius, startAngle: 180, endAngle: 270)
        bgPath.line(to: NSPoint(x: rect.maxX - cornerRadius, y: rect.minY))
        bgPath.appendArc(withCenter: NSPoint(x: rect.maxX - cornerRadius, y: rect.minY + cornerRadius), radius: cornerRadius, startAngle: 270, endAngle: 360)
        bgPath.line(to: NSPoint(x: rect.maxX, y: startY))
        bgPath.lineWidth = barThick; bgPath.lineCapStyle = .round
        NSColor.black.withAlphaComponent(0.4).setStroke(); bgPath.stroke()
        
        if progress > 0 {
            let targetLen = totalLen * CGFloat(min(1.0, progress))
            var currentLen: CGFloat = 0
            let fgPath = NSBezierPath()
            fgPath.move(to: NSPoint(x: rect.minX, y: startY))
            
            if targetLen > currentLen {
                let segLen = straightLen
                if targetLen < currentLen + segLen {
                    let p = (targetLen - currentLen) / segLen
                    fgPath.line(to: NSPoint(x: rect.minX, y: startY - (straightLen * p)))
                    currentLen = targetLen
                } else { fgPath.line(to: NSPoint(x: rect.minX, y: rect.minY + cornerRadius)); currentLen += segLen }
            }
            if targetLen > currentLen {
                let segLen = arcLen
                let center = NSPoint(x: rect.minX + cornerRadius, y: rect.minY + cornerRadius)
                if targetLen < currentLen + segLen {
                    let p = (targetLen - currentLen) / segLen
                    fgPath.appendArc(withCenter: center, radius: cornerRadius, startAngle: 180, endAngle: 180 + (90 * p))
                    currentLen = targetLen
                } else { fgPath.appendArc(withCenter: center, radius: cornerRadius, startAngle: 180, endAngle: 270); currentLen += segLen }
            }
            if targetLen > currentLen {
                let segLen = bottomLen
                if targetLen < currentLen + segLen {
                    let p = (targetLen - currentLen) / segLen
                    fgPath.line(to: NSPoint(x: rect.minX + cornerRadius + (bottomLen * p), y: rect.minY))
                    currentLen = targetLen
                } else { fgPath.line(to: NSPoint(x: rect.maxX - cornerRadius, y: rect.minY)); currentLen += segLen }
            }
            if targetLen > currentLen {
                let segLen = arcLen
                let center = NSPoint(x: rect.maxX - cornerRadius, y: rect.minY + cornerRadius)
                if targetLen < currentLen + segLen {
                    let p = (targetLen - currentLen) / segLen
                    fgPath.appendArc(withCenter: center, radius: cornerRadius, startAngle: 270, endAngle: 270 + (90 * p))
                    currentLen = targetLen
                } else { fgPath.appendArc(withCenter: center, radius: cornerRadius, startAngle: 270, endAngle: 360); currentLen += segLen }
            }
            if targetLen > currentLen {
                let segLen = straightLen
                if targetLen < currentLen + segLen {
                    let p = (targetLen - currentLen) / segLen
                    fgPath.line(to: NSPoint(x: rect.maxX, y: rect.minY + cornerRadius + (straightLen * p)))
                    currentLen = targetLen
                } else { fgPath.line(to: NSPoint(x: rect.maxX, y: startY)); currentLen += segLen }
            }
            fgPath.lineWidth = barThick; fgPath.lineCapStyle = .round
            getBarColor().setStroke(); fgPath.stroke()
        }
    }
}
