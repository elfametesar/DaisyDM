import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct FailedDownloadDialog: View {
    let item: DownloadItem
    var engine = DownloadEngine.shared
    @Environment(\.dismiss) var dismiss


    @AppStorage("accentColorHex")       private var accentColorHex       = "#0A84FF"
    @AppStorage("failedColorHex")       private var failedColorHex       = "#FF3B30"
    @AppStorage("matchBadgesToAccent")  private var matchBadgesToAccent  = false
    @State private var window: NSWindow?

    private var themeAccent: Color { Color(hex: accentColorHex) }
    private var errorColor: Color  { matchBadgesToAccent ? themeAccent : Color(hex: failedColorHex) }

    var body: some View {
        VStack(spacing: 0) {
            // Hero
            HStack(alignment: .top, spacing: 20) {
                ZStack(alignment: .bottomTrailing) {
                    let ext  = (item.filename as NSString).pathExtension
                    let type = UTType(filenameExtension: ext) ?? .data
                    Image(nsImage: NSWorkspace.shared.icon(for: type))
                        .resizable().scaledToFit().frame(width: 64, height: 64)

                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, errorColor)
                        .font(.system(size: 22))
                        .background(Circle().fill(Color(NSColor.windowBackgroundColor)).padding(2))
                        .offset(x: 4, y: 4)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Download Failed")
                        .font(.system(size: 18, weight: .bold))
                    Text(item.filename)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle)

                    Spacer().frame(height: 4)

                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(errorColor)
                            .font(.system(size: 14))
                            .padding(.top, 2)
                        Text(item.error ?? "An unknown network or file system error occurred.")
                            .font(.system(size: 12))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(errorColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(errorColor.opacity(0.2), lineWidth: 1))
                }
            }
            .padding(.top, 20)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)

            Divider()

            // Details
            VStack(spacing: 12) {
                DetailRowView(label: "Source",      value: item.url.absoluteString)
                DetailRowView(label: "Destination", value: item.destinationURL.path(percentEncoded: false))
                DetailRowView(label: "Size",        value: item.formattedSize)
            }
            .padding(24)
            .background(Color.primary.opacity(0.02))

            Divider()

            // Actions
            HStack {
                Spacer()
                Button("Retry") { engine.retry(item) }
                    .controlSize(.large)
                    .buttonStyle(ActionButtonStyle(prominent: false, hex: accentColorHex))
                Button("Done") { dismiss() }
                    .keyboardShortcut(.escape)
                    .buttonStyle(ActionButtonStyle(prominent: true, hex: accentColorHex))
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        }
        .frame(width: 520)
        .background(VisualEffectView(material: .popover, blendingMode: .behindWindow).ignoresSafeArea())
        .background(WindowAccessor(window: $window))
        .onChange(of: window) { _, newWindow in
            if let win = newWindow {
                win.isOpaque = false
                win.backgroundColor = .clear
            }
        }

    }
}
