// MARK: - ConfirmDownloadView.swift
import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ConfirmDownloadRequest: Identifiable {
    let id = UUID()
    let url:      URL
    var filename: String
    let cookies:  String
    let referer:  String
    let ua:       String
}

struct ConfirmDownloadView: View {
    let request: ConfirmDownloadRequest
    let onConfirm: (ConfirmDownloadRequest, URL, Int) -> Void
    let onCancel:  () -> Void

    @State private var filename:    String
    @State private var destination: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
    @State private var connections: Int = 16
    @State private var showDetails  = false
    
    // Background fetch states
    @State private var isResolving  = false
    @State private var resolvedSize: Int64 = 0

    private let engine = DownloadEngine.shared

    init(request: ConfirmDownloadRequest,
         onConfirm: @escaping (ConfirmDownloadRequest, URL, Int) -> Void,
         onCancel:  @escaping () -> Void) {
        self.request   = request
        self.onConfirm = onConfirm
        self.onCancel  = onCancel
        _filename      = State(initialValue: request.filename.isEmpty ? suggestName(request.url) : request.filename)
    }

    private var fileIcon: NSImage {
        let ext  = (filename as NSString).pathExtension
        let type = UTType(filenameExtension: ext) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }

    private var fileExt: String {
        let ext = (filename as NSString).pathExtension.uppercased()
        return ext.isEmpty ? "FILE" : ext
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Banner ────────────────────────────────────────────────
            HStack(spacing: 14) {
                Image(nsImage: fileIcon)
                    .resizable()
                    .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 4) {
                    Text($filename.wrappedValue)
                        .font(.headline)
                    HStack(spacing: 6) {
                        Text(fileExt)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.blue, in: RoundedRectangle(cornerRadius: 4))
                        
                        Text(request.url.host ?? request.url.absoluteString)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            
                        if resolvedSize > 0 {
                            Text("•")
                                .foregroundStyle(.tertiary)
                            Text(formatBytes(resolvedSize))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                        } else if isResolving {
                            ProgressView().controlSize(.small).scaleEffect(0.6)
                        }
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider()

            // ── Fields ────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 14) {
                // Filename
                VStack(alignment: .leading, spacing: 5) {
                    Label("File Name", systemImage: "doc")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    TextField("filename", text: $filename)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                }

                // Destination
                VStack(alignment: .leading, spacing: 5) {
                    Label("Save To", systemImage: "folder")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Text(destination.path(percentEncoded: false))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 5)
                            .padding(.horizontal, 8)
                            .background(Color(NSColor.controlBackgroundColor),
                                        in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(NSColor.separatorColor), lineWidth: 1))
                        Button("…") {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles       = false
                            panel.canChooseDirectories = true
                            panel.prompt               = "Select"
                            if panel.runModal() == .OK, let u = panel.url { destination = u }
                        }
                        .frame(width: 28)
                    }
                }

                // Connections
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Label("Connections", systemImage: "arrow.down.to.line.alt")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(connections)")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.blue)
                            .monospacedDigit()
                    }
                    HStack(spacing: 8) {
                        Text("1").font(.caption2).foregroundStyle(.tertiary)
                        Slider(value: Binding(get: { Double(connections) },
                                              set: { connections = Int($0) }),
                               in: 1...32, step: 1)
                        .tint(.blue)
                        Text("32").font(.caption2).foregroundStyle(.tertiary)
                    }
                }

                DisclosureGroup(isExpanded: $showDetails) {
                    VStack(alignment: .leading, spacing: 6) {
                        ConfirmDetailRow(label: "URL",      value: request.url.absoluteString)
                        if !request.referer.isEmpty {
                            ConfirmDetailRow(label: "Referer",  value: request.referer)
                        }
                        if !request.cookies.isEmpty {
                            ConfirmDetailRow(label: "Cookies",
                                             value: String(request.cookies.prefix(120))
                                             + (request.cookies.count > 120 ? "…" : ""))
                        }
                        if !request.ua.isEmpty {
                            ConfirmDetailRow(label: "User-Agent", value: request.ua)
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Text("Details")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .disclosureGroupStyle(.automatic)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()

            // ── Buttons ───────────────────────────────────────────────
            HStack(spacing: 10) {
                Button("Cancel") { onCancel() }
                .keyboardShortcut(.escape)

                Spacer()

                Button("Download") {
                    var r = request
                    r.filename = filename.trimmingCharacters(in: .whitespacesAndNewlines)
                    if r.filename.isEmpty { r.filename = suggestName(request.url) }
                    onConfirm(r, destination, connections)
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 460)
        .task { await performBackgroundSniff() }
    }
    
    // ── 1-Byte Background GET to Sniff Filename/Size without downloading ──
    // ── 1-Byte Background GET to Sniff True Filename from Server ──
    private func performBackgroundSniff() async {
        guard request.url.scheme?.starts(with: "http") == true else { return }
        
        isResolving = true
        defer { isResolving = false }
        
        var req = URLRequest(url: request.url)
        req.httpMethod = "GET"
        
        // Request 1 byte to trigger real headers without downloading
        req.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        
        // Spoof standard browser to avoid Cloudflare/WAF 403s
        req.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8", forHTTPHeaderField: "Accept")
        req.setValue("document", forHTTPHeaderField: "Sec-Fetch-Dest")
        req.setValue("navigate", forHTTPHeaderField: "Sec-Fetch-Mode")
        req.setValue("none", forHTTPHeaderField: "Sec-Fetch-Site")
        
        if !request.cookies.isEmpty { req.setValue(request.cookies, forHTTPHeaderField: "Cookie") }
        if !request.ua.isEmpty { req.setValue(request.ua, forHTTPHeaderField: "User-Agent") }
        if !request.referer.isEmpty { req.setValue(request.referer, forHTTPHeaderField: "Referer") }
        
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            if let httpResp = response as? HTTPURLResponse {
                await MainActor.run {
                    var foundName: String? = nil
                    
                    // 1. Sniff Filename from Content-Disposition
                    if let disposition = httpResp.value(forHTTPHeaderField: "Content-Disposition") ?? httpResp.value(forHTTPHeaderField: "content-disposition") {
                        
                        // Try standard filename="..."
                        if let range = disposition.range(of: "filename=", options: .caseInsensitive) {
                            var fn = String(disposition[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                            if fn.hasPrefix("\"") {
                                fn = String(fn.dropFirst())
                                if let endQuote = fn.firstIndex(of: "\"") {
                                    fn = String(fn[..<endQuote])
                                }
                            } else {
                                if let endSemi = fn.firstIndex(of: ";") {
                                    fn = String(fn[..<endSemi])
                                }
                            }
                            if !fn.isEmpty { foundName = fn }
                        }
                        
                        // Try RFC 5987 (filename*=UTF-8''...) -> Overrides standard if present
                        if let rfcMatch = disposition.range(of: "filename\\*=[^']+'[^']*'([^;]+)", options: .regularExpression) {
                            let matchStr = String(disposition[rfcMatch])
                            if let split = matchStr.components(separatedBy: "''").last,
                               let decoded = split.removingPercentEncoding {
                                foundName = decoded
                            }
                        }
                    }
                    
                    // 2. Fallback to final resolved URL path if we still have a generic name
                    if foundName == nil {
                        let finalURL = httpResp.url ?? request.url
                        let lastComponent = finalURL.lastPathComponent.removingPercentEncoding ?? finalURL.lastPathComponent
                        if lastComponent.contains(".") && lastComponent != "/" {
                            foundName = lastComponent
                        }
                    }
                    
                    // Override the extension's generic name if we found a real one
                    if let fn = foundName, fn != "download", fn != "file" {
                        self.filename = fn
                    }
                    
                    // 3. Sniff True Size from Content-Range or Content-Length
                    if let cr = httpResp.value(forHTTPHeaderField: "Content-Range") ?? httpResp.value(forHTTPHeaderField: "content-range") {
                        if let totalStr = cr.components(separatedBy: "/").last, let total = Int64(totalStr.trimmingCharacters(in: .whitespaces)) {
                            self.resolvedSize = total
                        }
                    } else if let cl = httpResp.value(forHTTPHeaderField: "Content-Length"), let total = Int64(cl) {
                        self.resolvedSize = total
                    }
                }
            }
        } catch {
            // Silently ignore network sniff failures
        }
    }
}

private struct ConfirmDetailRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(label + ":")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(3)
                .truncationMode(.middle)
        }
    }
}

private func suggestName(_ url: URL) -> String {
    var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
    c?.query = nil
    let last = (c?.url ?? url).lastPathComponent
    let dec  = last.removingPercentEncoding ?? last
    return (!dec.isEmpty && dec != "/") ? dec : "download"
}
