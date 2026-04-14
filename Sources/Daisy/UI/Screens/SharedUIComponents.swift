import SwiftUI
import AppKit

// MARK: - Window Accessor
struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { self.window = view.window }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
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
