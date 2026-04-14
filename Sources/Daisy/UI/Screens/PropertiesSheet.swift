import SwiftUI
import AppKit

struct PropertiesSheet: View {
    let item: DownloadItem
    @Environment(\.dismiss) private var dismiss
    var engine = DownloadEngine.shared

    @State private var urlText: String = ""
    @State private var urlIsValid: Bool = true

    @AppStorage("accentColorHex")       private var accentColorHex      = "#0A84FF"
    @AppStorage("enableBackgroundTint") private var enableBackgroundTint = false

    private var fileSize: String {
        if item.totalBytes > 0    { return formatBytes(item.totalBytes) }
        if item.downloadedBytes > 0 { return formatBytes(item.downloadedBytes) + " (partial)" }
        return "Unknown"
    }

    private var diskUsage: String {
        let url = item.destinationURL
        guard FileManager.default.fileExists(atPath: url.path),
              let vals = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]) else { return "–" }
        return formatBytes(Int64(vals.totalFileAllocatedSize ?? 0))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: item.type == .torrent
                      ? "arrow.2.circlepath"
                      : (item.type == .batch ? "square.stack.3d.down.right" : "link"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(item.filename)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    PropertiesSection("File") {
                        PropRow("Filename",    item.filename)
                        PropRow("Destination", item.destinationURL.path)
                        PropRow("File Size",   fileSize)
                        PropRow("On Disk",     diskUsage)
                        PropRow("Type",        item.type.rawValue)
                        if let mime = item.mimeType { PropRow("MIME Type", mime) }
                    }

                    PropertiesSection("Transfer") {
                        PropRow("Status",       item.status.rawValue)
                        PropRow("Downloaded",   formatBytes(item.downloadedBytes))
                        PropRow("Progress",     item.totalBytes > 0
                                ? String(format: "%.1f%%", item.progress * 100) : "–")
                        PropRow("Connections",  "\(item.connectionCount)")
                        PropRow("Range Support", item.supportsRanges ? "Yes" : "No")
                        if item.speedLimit > 0 {
                            PropRow("Speed Limit", "\(item.speedLimit) KB/s")
                        }
                        if let err = item.error { PropRow("Error", err) }
                    }

                    PropertiesSection("Source") {
                        if item.type == .batch {
                            PropRow("Batch URLs", "\(item.batchURLs?.count ?? 0) URLs", expandable: false)
                        } else {
                            // Editable URL row
                            HStack(alignment: .top, spacing: 12) {
                                Text("URL")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 120, alignment: .trailing)
                                VStack(alignment: .leading, spacing: 4) {
                                    TextField("", text: $urlText)
                                        .textFieldStyle(.plain)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundColor(urlIsValid ? .primary : .red)
                                        .onChange(of: urlText) { _, new in
                                            urlIsValid = URL(string: new) != nil && !new.isEmpty
                                        }
                                    if !urlIsValid {
                                        Text("Invalid URL")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.red)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(urlText, forType: .string)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 5)

                            PropRow("Host",   URL(string: urlText)?.host ?? item.url.host ?? "–")
                            PropRow("Scheme", URL(string: urlText)?.scheme?.uppercased() ?? item.url.scheme?.uppercased() ?? "–")
                        }
                        if let ua = item.userAgent, !ua.isEmpty { PropRow("User-Agent", ua, expandable: true) }
                        if let ck = item.cookies,  !ck.isEmpty  { PropRow("Cookies",    ck, expandable: true) }
                    }

                    PropertiesSection("Dates") {
                        PropRow("Added", formatDate(item.dateAdded))
                        if let done = item.dateCompleted {
                            PropRow("Completed", formatDate(done))
                            PropRow("Duration",  formatDuration(done.timeIntervalSince(item.dateAdded)))
                        }
                    }

                    if !item.subFiles.isEmpty {
                        PropertiesSection("\(item.type == .batch ? "Batch" : "Torrent") Files (\(item.subFiles.count))") {
                            ForEach(item.subFiles) { f in
                                PropRow(f.filename, f.totalBytes > 0 ? formatBytes(f.totalBytes) : "Unknown Size")
                            }
                        }
                    }
                }
                .padding(.bottom, 16)
            }

            Divider()

            HStack {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([item.destinationURL])
                }
                .buttonStyle(.bordered)
                Spacer()
                Button("Done") {
                    applyURLChangeIfNeeded()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
                .disabled(!urlIsValid)
                .tint(Color(hex: accentColorHex))
                .foregroundStyle(Color(hex: accentColorHex).accessibleText)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 560, height: 520)
        .background(enableBackgroundTint
                    ? Color(hex: accentColorHex).opacity(0.04)
                    : Color(NSColor.windowBackgroundColor))
        .onAppear { urlText = item.url.absoluteString }
    }

    private func applyURLChangeIfNeeded() {
        guard item.type != .batch,
              urlIsValid,
              let newURL = URL(string: urlText),
              newURL != item.url else { return }

        let shouldResume = item.status != .completed
        if item.status == .downloading || item.status == .queued { engine.stop(item) }

        try? FileManager.default.removeItem(at: item.tempDirURL)
        try? FileManager.default.removeItem(at: item.destinationURL)

        let newFilename: String = {
            var c = URLComponents(url: newURL, resolvingAgainstBaseURL: false)
            c?.query = nil
            let last = (c?.url ?? newURL).lastPathComponent
            let dec  = last.removingPercentEncoding ?? last
            return (!dec.isEmpty && dec != "/") ? dec : "download"
        }()
        let destDir = item.destinationURL.deletingLastPathComponent()

        item.url             = newURL
        item.filename        = newFilename
        item.destinationURL  = destDir.appendingPathComponent(newFilename)
        item.sourceHost      = newURL.host ?? ""
        item.error           = nil
        item.downloadedBytes = 0
        item.totalBytes      = 0
        item.isPrepared      = false
        item.supportsRanges  = false
        item.status          = .stopped

        engine.persist()

        if shouldResume {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { engine.resume(item) }
        }
    }

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f.string(from: date)
    }

    private func formatDuration(_ t: TimeInterval) -> String {
        let s = Int(t)
        if s < 60   { return "\(s)s" }
        if s < 3600 { return "\(s/60)m \(s%60)s" }
        return "\(s/3600)h \((s%3600)/60)m \(s%60)s"
    }
}

// MARK: - Prop Row

struct PropRow: View {
    let label: String
    let value: String
    var copiable: Bool   = false
    var expandable: Bool = false
    var lineLimit: Int   = 3

    @State private var copied   = false
    @State private var expanded = false

    init(_ label: String, _ value: String,
         copiable: Bool = false, expandable: Bool = false, lineLimit: Int = 3) {
        self.label     = label
        self.value     = value
        self.copiable  = copiable
        self.expandable = expandable
        self.lineLimit  = lineLimit
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .trailing)

            VStack(alignment: .leading, spacing: 3) {
                Text(value)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .lineLimit(expandable && !expanded ? 1 : nil)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if expandable {
                    Button(expanded ? "Show less" : "Show more") { expanded.toggle() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if copiable {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(copied ? .green : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 5)
    }
}

// MARK: - Properties Section

struct PropertiesSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title   = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 6)
            content
        }
    }
}
