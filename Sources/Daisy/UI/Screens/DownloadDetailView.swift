import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct DetailView: View {
    let item: DownloadItem
    let onRequestRemove: (DownloadItem) -> Void
    var engine = DownloadEngine.shared

    @AppStorage("accentColorHex") private var accentColorHex = "#0A84FF"
    @AppStorage("progressBarColorHex") private var progressBarColorHex = "#34C759"
    @AppStorage("matchProgressBarToAccent") private var matchProgressBarToAccent = false
    @AppStorage("enableBackgroundTint") private var enableBackgroundTint = false

    private let metricColumns = [
        GridItem(.adaptive(minimum: 140), spacing: 12)
    ]

    private func currentFileURL(for item: DownloadItem) -> URL {
        if item.status == .completed { return item.destinationURL }
        if item.type == .directLink { return item.destinationURL.appendingPathExtension("dysy") }
        return item.destinationURL
    }

    private func robustReveal(_ url: URL) {
        let target = url.standardizedFileURL
        // Force Finder to highlight the file directly, bypassing FileManager caching
        NSWorkspace.shared.activateFileViewerSelecting([target])
        
        // Fallback: If it genuinely doesn't exist yet, open the closest parent directory
        if !FileManager.default.fileExists(atPath: target.path) {
            var parent = target.deletingLastPathComponent()
            while !FileManager.default.fileExists(atPath: parent.path) && parent.path != "/" {
                parent = parent.deletingLastPathComponent()
            }
            NSWorkspace.shared.open(parent)
        }
    }

    private func robustOpen(_ url: URL) {
        var target = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: target.path) && target.path != "/" {
            target = target.deletingLastPathComponent()
        }
        NSWorkspace.shared.open(target)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                overviewCard(for: item)
                storageCard(for: item)
                
                if (item.headers != nil && !item.headers!.isEmpty) || (item.cookies != nil && !item.cookies!.isEmpty) || (item.userAgent != nil && !item.userAgent!.isEmpty) {
                    headersCard(for: item)
                }

                if let err = item.error, item.status == .failed {
                    errorCard(message: err)
                }

                if item.type == .torrent {
                    TorrentInfoCard(item: item)
                }
            }
            .padding(EdgeInsets(top: -20, leading: 24, bottom: 24, trailing: 24))
        }
        .background(enableBackgroundTint ? Color(hex: accentColorHex).opacity(0.04) : Color(NSColor.windowBackgroundColor))
        .navigationTitle(item.filename)
    }

    private func overviewCard(for item: DownloadItem) -> some View {
        inspectorCard {
            overviewHeader(for: item)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Progress")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(progressLabel(for: item))
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                if item.status == .queued {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    ProgressView(value: item.progress, total: 1.0)
                        .tint(progressColor)
                }
            }

            LazyVGrid(columns: metricColumns, spacing: 12) {
                metricTile(title: "Downloaded", value: item.transferLabel, systemImage: "arrow.down.circle")
                
                metricTile(title: "Download Speed", value: item.status == .downloading ? item.formattedSpeed : "0B/s", systemImage: "speedometer")
                
                metricTile(title: "Connections", value: "\(item.connectionCount) slots", systemImage: "antenna.radiowaves.left.and.right")
                
                if item.status == .downloading || item.status == .queued {
                    metricTile(title: "ETA", value: item.formattedETA ?? "–", systemImage: "clock")
                }
            }

            actionBar(for: item)
            activityFootnote(for: item)
        }
    }

    private func overviewHeader(for item: DownloadItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                sourceIcon(for: item)
                
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.filename)
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 6) {
                        Label(item.type.rawValue, systemImage: item.type == .torrent ? "arrow.2.circlepath" : "link")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: true, vertical: false)
                        
                        if !item.sourceHost.isEmpty {
                            Text("•")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            
                            Text(item.sourceHost)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                
                Spacer(minLength: 12)
                
                StatusPill(status: item.status, accentColorHex: accentColorHex)
                    .fixedSize(horizontal: true, vertical: true)
                    .layoutPriority(10)
            }
            
            HStack(alignment: .center, spacing: 8) {
                Text(item.url.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onTapGesture { NSWorkspace.shared.open(item.url) }
                
                CopyLinkButton(url: item.url.absoluteString)
                    .layoutPriority(2)
            }
        }
    }

    private func sourceIcon(for item: DownloadItem) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.06))
            if item.type == .torrent || item.type == .batch {
                Image(nsImage: SharedIconCache.shared.bundleIcon(size: 36)).resizable().scaledToFit().frame(width: 28, height: 28)
            } else {
                let ext = (item.filename as NSString).pathExtension
                if !ext.isEmpty, let utType = UTType(filenameExtension: ext) {
                    Image(nsImage: NSWorkspace.shared.icon(for: utType)).resizable().scaledToFit().frame(width: 28, height: 28)
                } else {
                    Image(nsImage: NSWorkspace.shared.icon(for: .data)).resizable().scaledToFit().frame(width: 28, height: 28)
                }
            }
        }.frame(width: 52, height: 52)
    }

    private func storageCard(for item: DownloadItem) -> some View {
        inspectorCard {
            Text("Storage").font(.headline)
            let fileURL = currentFileURL(for: item)
            pathRow(title: "Destination", systemImage: "folder", path: fileURL.deletingLastPathComponent().path(percentEncoded: false), url: fileURL.deletingLastPathComponent(), isReveal: false)
            pathRow(title: "Saved File", systemImage: "doc", path: fileURL.path(percentEncoded: false), url: fileURL, isReveal: true)
        }
    }
    
    private func headersCard(for item: DownloadItem) -> some View {
        inspectorCard {
            Text("Headers & Cookies").font(.headline)
            ScrollView {
                VStack(spacing: 12) {
                    if let headers = item.headers, !headers.isEmpty {
                        ForEach(headers.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                            headerValueRow(label: key.capitalized, systemImage: "text.alignleft", value: value)
                        }
                    } else {
                        if let ua = item.userAgent, !ua.isEmpty {
                            headerValueRow(label: "User-Agent", systemImage: "text.alignleft", value: ua)
                        }
                        if let ref = item.referer, !ref.isEmpty {
                            headerValueRow(label: "Referer", systemImage: "link", value: ref)
                        }
                    }
                }
                .padding(.trailing, 8)
                .padding(.bottom, 8)
            }
            .frame(maxHeight: 250)
            .clipped()
        }
    }

    private func headerValueRow(label: String, systemImage: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(label, systemImage: systemImage)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            ScrollView(.vertical, showsIndicators: true) {
                Text(value)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
            }
            .frame(maxHeight: 80)
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
        }
        .padding(14)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func errorCard(message: String) -> some View {
        inspectorCard {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last Error").font(.headline)
                    ScrollView {
                        Text(message).foregroundStyle(.secondary).lineLimit(nil).fixedSize(horizontal: false, vertical: true).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 100).clipped()
                }
            }
        }
    }

    @ViewBuilder
    private func actionBar(for item: DownloadItem) -> some View {
        HStack(spacing: 10) {
            if item.status == .downloading || item.status == .queued {
                Button(action: {
                    engine.stop(item)
                    TrayViewModel.shared.removeFromTray(item.id)
                }) {
                    Label("Pause", systemImage: "pause.fill")
                }
                .buttonStyle(ActionButtonStyle(prominent: true, hex: accentColorHex))
            } else if item.status == .stopped {
                Button(action: { engine.resume(item) }) { Label("Resume", systemImage: "play.fill") }.buttonStyle(ActionButtonStyle(prominent: true, hex: accentColorHex))
            
                Button(action: { engine.retry(item) }) { Label("Restart", systemImage: "arrow.clockwise") }.buttonStyle(ActionButtonStyle(prominent: false, hex: accentColorHex))
            } else if item.status == .completed {
                Button(action: { engine.retry(item) }) { Label("Restart", systemImage: "arrow.clockwise") }.buttonStyle(ActionButtonStyle(prominent: true, hex: accentColorHex))
            }
            if item.status == .failed {
                Button(action: { engine.retry(item) }) { Label("Retry", systemImage: "arrow.clockwise") }.buttonStyle(ActionButtonStyle(prominent: item.status == .failed ? true : false, hex: accentColorHex))
            } else if item.status == .completed {
                Button(action: { robustOpen(item.destinationURL) }) { Label("Open File", systemImage: "doc.text.magnifyingglass") }.buttonStyle(ActionButtonStyle(prominent: false, hex: accentColorHex))
            }
            Menu {
                Button { robustReveal(currentFileURL(for: item)) } label: { Label("Reveal in Finder", systemImage: "folder") }
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.url.absoluteString, forType: .string) } label: { Label("Copy Source URL", systemImage: "link") }
                Divider()
                Button(role: .destructive) { onRequestRemove(item) } label: { Label("Remove", systemImage: "trash") }
            } label: {
                HStack(spacing: 5) { Image(systemName: "ellipsis.circle"); Text("More"); Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)) }
            }.buttonStyle(ActionButtonStyle(prominent: false, hex: accentColorHex)).fixedSize()
            Spacer(minLength: 0)
        }
    }

    private func activityFootnote(for item: DownloadItem) -> some View {
        HStack(spacing: 10) {
            Label("Added \(formatDate(item.dateAdded))", systemImage: "calendar")
            if let completed = item.dateCompleted {
                Text("•")
                Label("Finished \(formatDate(completed))", systemImage: "checkmark.circle")
            }
        }.font(.caption).foregroundStyle(.secondary)
    }

    private func pathRow(title: String, systemImage: String, path: String, url: URL?, isReveal: Bool) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: systemImage).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Text(path).font(.callout).foregroundStyle(.primary).textSelection(.enabled).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let targetURL = url {
                Button {
                    if isReveal { robustReveal(targetURL) }
                    else { robustOpen(targetURL) }
                } label: {
                    Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).padding(6).background(Color.primary.opacity(0.06), in: Circle())
                }.buttonStyle(.plain).help(isReveal ? "Reveal in Finder" : "Open Folder")
            }
        }.padding(14).background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func metricTile(title: String, value: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Text(value).font(.headline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(14).background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func inspectorCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 18) { content() }.padding(20).background(Color(NSColor.controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous)).overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1) }.shadow(color: Color.black.opacity(0.12), radius: 5, x: 0, y: 2)
    }

    private func progressLabel(for item: DownloadItem) -> String {
        if item.totalBytes > 0 || item.status == .completed { return String(format: "%.1f%%", item.progress * 100) }
        return item.status == .queued ? "Starting…" : item.status.rawValue
    }
    
    var progressColor: Color {
        switch item.status {
        case .downloading, .completed, .failed, .stopped: return matchProgressBarToAccent ? Color(hex: accentColorHex) : Color(hex: progressBarColorHex)
        default: return .secondary
        }
    }

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        return f.string(from: date)
    }
}

struct TorrentInfoCard: View {
    let item: DownloadItem
    @State private var isExpanded = false
    @AppStorage("accentColorHex") private var accentColorHex = "#0A84FF"
    @AppStorage("matchBadgesToAccent") private var matchBadgesToAccent = false
    @AppStorage("completedColorHex")   private var completedColorHex   = "#34C759"
    @Environment(\.colorScheme) private var colorScheme
    var completedColor: Color {
        let baseColor = Color(hex: completedColorHex)
        let matchedColor = matchBadgesToAccent ? baseColor.matchingThemeVisualWeight(of: Color(hex: accentColorHex)) : baseColor
        return matchedColor.adaptedForScheme(colorScheme)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Torrent Metadata").font(.headline)
            if !item.subFiles.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Files (\(item.subFiles.count))").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        Spacer()
                        if item.subFiles.count > 8 {
                            Button(action: { withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { isExpanded.toggle() } }) { Image(systemName: isExpanded ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary) }.buttonStyle(.plain)
                        }
                    }
                    VStack(spacing: 0) {
                        if isExpanded {
                            ScrollView { LazyVStack(spacing: 0) { fileRows(item.subFiles) }.padding(.trailing, 8) }.frame(maxHeight: 250).clipped()
                        } else {
                            fileRows(Array(item.subFiles.prefix(8)))
                            if item.subFiles.count > 8 { Text("+ \(item.subFiles.count - 8) more files").font(.caption).foregroundStyle(.tertiary).padding(.top, 8) }
                        }
                    }.padding(14).background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }.padding(20).background(Color(NSColor.controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous)).overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1) }.shadow(color: Color.black.opacity(0.12), radius: 5, x: 0, y: 2)
    }
    @ViewBuilder
    private func fileRows(_ files: [SubFile]) -> some View {
        ForEach(files) { f in
            HStack {
                Text(f.filename).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                Spacer()
                let isFinished = f.totalBytes > 0 && f.downloadedBytes >= f.totalBytes
                let isEffectivelyPaused = f.isStopped || item.status == .stopped || item.status == .failed
                Text("\(formatBytes(f.downloadedBytes)) / \(formatBytes(f.totalBytes))").font(.system(size: 11)).foregroundStyle(isEffectivelyPaused && !isFinished ? Color.secondary.opacity(0.5) : Color.secondary)
                if isFinished { Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(completedColor).padding(.leading, 4) }
            }.padding(.vertical, 8)
            if f.id != files.last?.id { Divider().opacity(0.5) }
        }
    }
}
