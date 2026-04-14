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
    @State private var isSourceExpanded = false
    @State private var now = Date()
    @State private var window: NSWindow?

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    @AppStorage("accentColorHex") private var accentColorHex = "#0A84FF"
    @AppStorage("matchProgressBarToAccent") private var matchProgressBarToAccent = true
    @AppStorage("progressBarColorHex") private var progressBarColorHex = "#34C759"
    @AppStorage("alwaysPinProgressWindows") private var alwaysPinProgressWindows = false

    var elapsed: TimeInterval { now.timeIntervalSince(item.dateAdded) }

    var formattedElapsed: String {
        let s = Int(elapsed)
        if s < 60   { return "\(s)s" }
        if s < 3600 { return "\(s/60)m \(s%60)s" }
        return "\(s/3600)h \((s%3600)/60)m \(s%60)s"
    }
    
    var currentBarColor: Color {
        if item.status == .failed { return .red }
        let hexString = matchProgressBarToAccent ? accentColorHex : progressBarColorHex
        let baseColor = Color(hex: hexString)
        return item.status == .stopped ? baseColor.opacity(0.5) : baseColor
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            statusTab.tabItem     { Text("Status") }.tag(0)
            speedLimitTab.tabItem { Text("Speed Limit") }.tag(1)
        }
        .frame(width: 460, height: isSourceExpanded ? 450 : 370)
        .background(VisualEffectView(material: .popover, blendingMode: .behindWindow).ignoresSafeArea())
        .background(WindowAccessor(window: $window))
        .onAppear {
            if item.speedLimit > 0 {
                limitEnabled = true
                limitInput = "\(item.speedLimit)"
            }
            
            if alwaysPinProgressWindows {
                isPinned = true
                window?.level = .floating
            }
        }
        .onReceive(timer) { _ in now = Date() }
        .onChange(of: window) { _, newWindow in
            if let win = newWindow {
                win.isOpaque = false
                win.backgroundColor = .clear
                if alwaysPinProgressWindows {
                    win.level = .floating
                }
            }
        }
    }

    // MARK: - Status Tab

    var statusTab: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .top, spacing: 14) {
                let ext  = (item.filename as NSString).pathExtension
                let type = UTType(filenameExtension: ext) ?? .data
                Image(nsImage: NSWorkspace.shared.icon(for: type))
                    .resizable().frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.filename)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 6) {
                        StatusPill(status: item.status, accentColorHex: accentColorHex)
                        if item.supportsRanges {
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

            // Progress
            VStack(spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.primary.opacity(0.08))
                            .frame(height: 8)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(currentBarColor)
                            .frame(width: max(0, CGFloat(item.progress) * geo.size.width), height: 8)
                            .animation(.easeInOut(duration: 0.4), value: item.progress)
                    }
                }
                .frame(height: 8)

                HStack {
                    Text(item.transferLabel).font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    if item.totalBytes > 0 {
                        Text(String(format: "%.1f%%", item.progress * 100))
                            .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    }
                }
            }
            .padding(.horizontal, 16)

            Divider().padding(.vertical, 10)

            // Stats Row
            HStack(spacing: 8) {
                ActiveStatCell(label: "Speed",     value: item.status == .downloading ? item.formattedSpeed : "–")
                ActiveStatCell(label: "ETA",       value: item.formattedETA ?? "–")
                ActiveStatCell(label: "Elapsed",   value: formattedElapsed)
                ActiveStatCell(label: "Remaining", value: remainingSize)
            }
            .padding(.horizontal, 16)

            Divider().padding(.vertical, 10)

            // Source URL
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Source")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                    Spacer()
                    if item.url.absoluteString.count > 60 {
                        Button(action: {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                isSourceExpanded.toggle()
                            }
                        }) {
                            Image(systemName: isSourceExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 4)
                    }
                }
                
                if isSourceExpanded {
                    ScrollView(.vertical, showsIndicators: true) {
                        Text(item.url.absoluteString)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.trailing, 8)
                    }
                    .frame(height: 70)
                    .clipped() // Fixes the bleed over
                } else {
                    Text(item.url.absoluteString)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .frame(height: 28, alignment: .topLeading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)

            Spacer()
            Divider()

            // Actions
            HStack(spacing: 8) {
                if item.status == .downloading || item.status == .queued {
                    Button(action: { engine.stop(item) }) {
                        Label("Pause", systemImage: "pause.fill")
                    }
                    .buttonStyle(ActionButtonStyle(prominent: true, hex: accentColorHex))
                    
                    Button(action: { engine.stop(item); dismiss() }) {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(ActionButtonStyle(prominent: false, hex: accentColorHex))
                    
                } else if item.status == .stopped || item.status == .failed {
                    Button(action: { engine.resume(item) }) {
                        Label("Resume", systemImage: "play.fill")
                    }
                    .buttonStyle(ActionButtonStyle(prominent: true, hex: accentColorHex))
                    
                    Button(action: { engine.stop(item); dismiss() }) {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(ActionButtonStyle(prominent: false, hex: accentColorHex))
                    
                } else if item.status == .completed {
                    Button(action: { NSWorkspace.shared.open(item.destinationURL) }) {
                        Label("Open File", systemImage: "doc.text.magnifyingglass")
                    }
                    .buttonStyle(ActionButtonStyle(prominent: true, hex: accentColorHex))
                    
                    Button(action: { NSWorkspace.shared.activateFileViewerSelecting([item.destinationURL]) }) {
                        Label("Reveal in Finder", systemImage: "folder")
                    }
                    .buttonStyle(ActionButtonStyle(prominent: false, hex: accentColorHex))
                }
                
                Spacer()
                
                Button(action: { dismiss() }) {
                    Label(item.status == .completed ? "Close" : "Hide", systemImage: item.status == .completed ? "xmark" : "eye.slash")
                }
                .buttonStyle(ActionButtonStyle(prominent: false, hex: accentColorHex))
                .keyboardShortcut(.escape)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
    }

    // MARK: - Speed Limit Tab

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

    // MARK: - Subviews

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
        guard item.totalBytes > 0 else { return "–" }
        let rem = item.totalBytes - item.downloadedBytes
        guard rem > 0 else { return "–" }
        return formatBytes(rem)
    }

    func applyLimit(enabled: Bool, input: String) {
        if !enabled { engine.updateSpeedLimit(for: item, limitKB: 0) }
        else if let val = Int(input), val > 0 { engine.updateSpeedLimit(for: item, limitKB: val) }
    }
}

// MARK: - Stat Cell

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
        .frame(width: 81, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(NSColor.separatorColor).opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
    }
}
