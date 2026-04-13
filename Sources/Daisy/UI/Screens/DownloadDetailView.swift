import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct DetailView: View {
    let item: DownloadItem
    var engine = DownloadEngine.shared

    let onRequestRemove: (DownloadItem) -> Void
    
    @AppStorage("accentColorHex") private var accentColorHex = "#0A84FF"
    @AppStorage("progressBarColorHex") private var progressBarColorHex = "#34C759"
    @AppStorage("matchProgressBarToAccent") private var matchProgressBarToAccent = false
    @AppStorage("enableBackgroundTint") private var enableBackgroundTint = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // ── Header ─────────────────────────────────────
                HStack(alignment: .top, spacing: 12) {
                    fileIcon
                        .resizable()
                        .frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.filename)
                            .font(.system(size: 14, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        
                        StatusPill(status: item.status, accentColorHex: accentColorHex)
                    }
                }
                .padding(16)

                Divider().padding(.horizontal, 16)

                // ── Source info ────────────────────────────────
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: item.type == .torrent ? "arrow.2.circlepath" : "link")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(item.type.rawValue)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        if !item.sourceHost.isEmpty {
                            Text("·").foregroundStyle(.tertiary)
                            Text(item.sourceHost)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text(item.url.absoluteString)
                        .font(.system(size: 11))
                        .foregroundStyle(Color(hex: accentColorHex))
                        .fixedSize(horizontal: false, vertical: true)
                        .onTapGesture { NSWorkspace.shared.open(item.url) }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider().padding(.horizontal, 16)

                // ── Progress ───────────────────────────────────
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Progress")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        if item.totalBytes > 0 || item.status == .completed {
                            Text(String(format: "%.1f%%", item.progress * 100))
                                .font(.system(size: 13, weight: .semibold))
                        } else {
                            Text("–")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                    }

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(progressBarColor.opacity(0.15))
                                .frame(height: 10)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(progressBarColor)
                                .frame(width: max(0, CGFloat(item.progress) * geo.size.width), height: 10)
                                .animation(.easeInOut(duration: 0.3), value: item.progress)
                        }
                    }
                    .frame(height: 10)

                    if let eta = item.formattedETA {
                        HStack {
                            Image(systemName: "clock").font(.system(size: 11)).foregroundStyle(.secondary)
                            Text("ETA: \(eta)").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)

                // ── Stat cards ─────────────────────────────────
                HStack(spacing: 12) {
                    StatCard(
                        icon: "arrow.down.circle",
                        label: "Downloaded",
                        value: item.totalBytes > 0
                            ? "\(item.formattedDownloaded) of\n\(item.formattedSize)"
                            : item.formattedDownloaded
                    )
                    StatCard(
                        icon: "speedometer",
                        label: "Download Speed",
                        value: item.status == .downloading ? item.formattedSpeed : "–"
                    )
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

                HStack(spacing: 12) {
                    StatCard(
                        icon: "clock",
                        label: "ETA",
                        value: item.formattedETA ?? "–"
                    )
                    StatCard(
                        icon: "antenna.radiowaves.left.and.right",
                        label: "Connections",
                        value: "\(item.connectionCount) slots"
                    )
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)

                // ── Transfer details ───────────────────────────
                Divider().padding(.horizontal, 16)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Transfer Details")
                        .font(.system(size: 13, weight: .semibold))
                    DetailRow(label: "Range Support", value: item.supportsRanges ? "Yes (resumable)" : "No")
                    if let mime = item.mimeType, !mime.isEmpty {
                        DetailRow(label: "MIME Type", value: mime)
                    }
                    let ext = (item.filename as NSString).pathExtension.uppercased()
                    if !ext.isEmpty {
                        DetailRow(label: "File Type", value: ext)
                    }
                    if item.speedLimit > 0 {
                        DetailRow(label: "Speed Limit", value: "\(item.speedLimit) KB/s")
                    }
                    if let err = item.error {
                        DetailRow(label: "Error", value: err, valueColor: .red)
                    }
                }
                .padding(16)

                // ── Torrent-specific details ───────────────────
                if item.type == .torrent {
                    Divider().padding(.horizontal, 16)
                    TorrentInfoSection(item: item)
                }

                Divider().padding(.horizontal, 16)

                // ── Action buttons ─────────────────────────────
                HStack(spacing: 8) {
                    HStack(spacing: 8) {
                        primaryButton
                        secondaryButtons
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                Divider().padding(.horizontal, 16)

                // ── Dates ──────────────────────────────────────
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Image(systemName: "calendar").font(.system(size: 11)).foregroundStyle(.secondary)
                            Text("Added \(formatDate(item.dateAdded))").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                    if let completed = item.dateCompleted {
                        Text("·").foregroundStyle(.tertiary).padding(.horizontal, 6)
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle").font(.system(size: 11)).foregroundStyle(progressBarColor)
                            Text("Finished \(formatDate(completed))").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider().padding(.horizontal, 16)

                // ── Storage ────────────────────────────────────
                VStack(alignment: .leading, spacing: 12) {
                    Text("Storage")
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.top, 4)
                    StorageCard(icon: "folder", label: "Destination",
                                path: item.destinationURL.deletingLastPathComponent().path(percentEncoded: false))
                    StorageCard(icon: "doc", label: "Saved File",
                                path: item.destinationURL.path(percentEncoded: false))
                }
                .padding(16)
            }
        }
        .background(enableBackgroundTint ? Color(hex: accentColorHex).opacity(0.04) : Color(NSColor.controlBackgroundColor))
        .frame(minWidth: 320)
        .ignoresSafeArea(edges: .top)
    }

    @ViewBuilder
    var primaryButton: some View {
        switch item.status {
        case .downloading:
            Button { engine.stop(item) } label: {
                Label("Stop", systemImage: "stop.fill")
                    .font(.system(size: 13, weight: .semibold)).frame(minWidth: 90)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(hex: accentColorHex))
            .foregroundStyle(Color(hex: accentColorHex).accessibleText)

        case .stopped:
            Button { engine.resume(item) } label: {
                    Label("Resume", systemImage: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color(hex: accentColorHex).accessibleText)
                        .frame(minWidth: 90)
                        .padding(.vertical, 3)
                        .padding(.horizontal, 12)
                        .background(Color(hex: accentColorHex))
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)

        case .failed:
            Button { engine.retry(item) } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color(hex: accentColorHex).accessibleText)
                        .frame(minWidth: 90)
                        .padding(.vertical, 3)
                        .padding(.horizontal, 12)
                        .background(Color(hex: accentColorHex))
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)

        case .completed:
            Button { NSWorkspace.shared.open(item.destinationURL) } label: {
                    Label("Open file", systemImage: "doc")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color(hex: accentColorHex).accessibleText)
                        .frame(minWidth: 90)
                        .padding(.vertical, 3)
                        .padding(.horizontal, 12)
                        .background(Color(hex: accentColorHex))
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)

        case .queued:
            Button {} label: {
                Label("Queued", systemImage: "clock")
                    .font(.system(size: 13, weight: .semibold)).frame(minWidth: 90)
            }
            .buttonStyle(.bordered).disabled(true)
        }
    }

    @ViewBuilder
    var secondaryButtons: some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([item.destinationURL])
        } label: {
            Label("Show in Finder", systemImage: "folder").font(.system(size: 13))
        }
        .buttonStyle(.bordered)
        .tint(nil)

        Menu {
            Button("Copy URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url.absoluteString, forType: .string)
            }
            if item.status == .completed {
                Menu("Open With") {
                    let appURLs = NSWorkspace.shared.urlsForApplications(toOpen: item.destinationURL)
                    ForEach(appURLs, id: \.self) { appURL in
                        Button(appURL.deletingPathExtension().lastPathComponent) {
                            NSWorkspace.shared.open([item.destinationURL], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
                        }
                    }
                }
            }
            if item.status == .failed || item.status == .stopped || item.status == .completed {
                Button("Restart Download") { engine.retry(item) }
            }
            Divider()
            Button("Remove", role: .destructive) { onRequestRemove(item) }
        } label: {
            HStack(spacing: 4) {
                Text("More").font(.system(size: 13))
                Image(systemName: "chevron.down").font(.system(size: 10))
            }
        }
        .menuStyle(.button)
        .tint(nil)
    }

    var fileIcon: Image {
        let ext = (item.filename as NSString).pathExtension
        if !ext.isEmpty, let utType = UTType(filenameExtension: ext) {
            return Image(nsImage: NSWorkspace.shared.icon(for: utType))
        }
        if item.type == .torrent {
            return Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: "torrent") ?? .data))
        }
        return Image(nsImage: NSWorkspace.shared.icon(for: .data))
    }

    var progressBarColor: Color {
        switch item.status {
        case .completed, .failed, .stopped, .downloading:
            return matchProgressBarToAccent ? Color(hex: accentColorHex) : Color(hex: progressBarColorHex)
        default: return .secondary
        }
    }

    static let sharedDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return df
    }()

    func formatDate(_ date: Date) -> String { Self.sharedDateFormatter.string(from: date) }
}

struct TorrentInfoSection: View {
    let item: DownloadItem

    var infoHash: String? {
        guard item.url.scheme == "magnet",
              let comps = URLComponents(url: item.url, resolvingAgainstBaseURL: false),
              let xt = comps.queryItems?.first(where: { $0.name == "xt" })?.value else { return nil }
        if let range = xt.range(of: "btih:", options: .caseInsensitive) {
            return String(xt[range.upperBound...]).uppercased()
        }
        return nil
    }

    var trackers: [String] {
        guard item.url.scheme == "magnet",
              let comps = URLComponents(url: item.url, resolvingAgainstBaseURL: false) else { return [] }
        return comps.queryItems?
            .filter { $0.name == "tr" }
            .compactMap { $0.value?.removingPercentEncoding }
            .compactMap { URL(string: $0)?.host }
            ?? []
    }

    var isMagnet: Bool { item.url.scheme == "magnet" }
    var isTorrentFile: Bool { item.url.isFileURL && item.url.pathExtension.lowercased() == "torrent" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Torrent")
                .font(.system(size: 15, weight: .semibold))

            HStack(spacing: 8) {
                Label(isMagnet ? "Magnet Link" : "Torrent File", systemImage: isMagnet ? "magnet" : "doc.zipper")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("P2P")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.12), in: Capsule())
            }

            if let hash = infoHash {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Info Hash")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(hash)
                        .font(.system(size: 9))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color(NSColor.separatorColor).opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("Connection slots: \(item.connectionCount)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if !trackers.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Trackers (\(trackers.count))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(trackers.prefix(6), id: \.self) { tracker in
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Color.green.opacity(0.6))
                                    .frame(width: 5, height: 5)
                                Text(tracker)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        if trackers.count > 6 {
                            Text("+ \(trackers.count - 6) more")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(NSColor.separatorColor).opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
                }
            }

            if item.status == .completed {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text("Seeding disabled (seed-time=0). File is complete and kept locally.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
    }
}

struct StatCard: View {
    let icon: String
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(NSColor.separatorColor).opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct DetailRow: View {
    let label: String
    let value: String
    var valueColor: Color = .primary
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(valueColor)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct StorageCard: View {
    let icon: String
    let label: String
    let path: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(path)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(NSColor.separatorColor).opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
    }
}
