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
    
    @State private var isResolving  = false
    @State private var resolvedSize: Int64 = 0

    private let engine = DownloadEngine.shared

    @AppStorage("accentColorHex") private var accentColorHex = "#0A84FF"
    @State private var window: NSWindow?

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
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: fileIcon)
                    .resizable()
                    .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 3) {
                    Text($filename.wrappedValue)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(.primary)
                    
                    HStack(spacing: 6) {
                        Text(fileExt)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color(hex: accentColorHex).accessibleText)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color(hex: accentColorHex), in: Capsule())
                        
                        Text(request.url.host ?? request.url.absoluteString)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            
                        if resolvedSize > 0 {
                            Text("•")
                                .foregroundStyle(.primary)
                            Text(formatBytes(resolvedSize))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        } else if isResolving {
                            ProgressView().controlSize(.small).scaleEffect(0.6)
                        }
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("File Name")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.primary)
                    TextField("filename", text: $filename)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .backgroundStyle(.white.opacity(0.50))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Save To")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.primary)
                    HStack {
                        ScrollView(.vertical, showsIndicators: false) {
                            Text(destination.path(percentEncoded: false))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 16)
                        
                        Button("Choose…") {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles       = false
                            panel.canChooseDirectories = true
                            panel.prompt               = "Select"
                            if panel.runModal() == .OK, let u = panel.url { destination = u }
                        }
                        .font(.system(size: 11))
                        .buttonStyle(ActionButtonStyle(prominent: false, hex: accentColorHex))
                    }
                    .padding(6)
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(NSColor.separatorColor).opacity(0.5), lineWidth: 1))
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Connections")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.primary)
                        Spacer()
                        Text("\(connections)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.primary)
                            .monospacedDigit()
                    }
                    HStack(spacing: 8) {
                        Text("1").font(.system(size: 10)).foregroundStyle(.primary)
                        Slider(value: Binding(get: { Double(connections) },
                                              set: { connections = Int($0) }),
                               in: 1...32, step: 1)
                        .tint(Color(hex: accentColorHex))
                        Text("32").font(.system(size: 10)).foregroundStyle(.primary)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Button(action: {
                        withAnimation(nil) {
                            showDetails.toggle()
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: showDetails ? "chevron.down" : "chevron.right")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 12)
                            Text("Advanced Details")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)

                    if showDetails {
                        VStack(alignment: .leading, spacing: 10) {
                            ScrollableDetailRow(label: "URL", value: request.url.absoluteString, labelWidth: 70)
                            
                            if !request.referer.isEmpty {
                                ScrollableDetailRow(label: "Referer", value: request.referer, labelWidth: 70)
                            }
                            if !request.cookies.isEmpty {
                                ScrollableDetailRow(label: "Cookies", value: request.cookies, labelWidth: 70)
                            }
                            if !request.ua.isEmpty {
                                ScrollableDetailRow(label: "User-Agent", value: request.ua, labelWidth: 70)
                            }
                        }
                        .padding(.top, 8)
                        .padding(.bottom, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)

            Spacer(minLength: 16)
            Divider()

            HStack(spacing: 10) {
                Button(action: onCancel) {
                    Label("Cancel", systemImage: "xmark")
                }
                .keyboardShortcut(.escape)
                .buttonStyle(ActionButtonStyle(prominent: false, hex: accentColorHex))

                Spacer()

                Button(action: {
                    var r = request
                    r.filename = filename.trimmingCharacters(in: .whitespacesAndNewlines)
                    if r.filename.isEmpty { r.filename = suggestName(request.url) }
                    onConfirm(r, destination, connections)
                }) {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                .keyboardShortcut(.return)
                .buttonStyle(ActionButtonStyle(prominent: true, hex: accentColorHex))
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .animation(nil, value: showDetails)
        .task { await performBackgroundSniff() }
        .background(VisualEffectView(material: .popover, blendingMode: .behindWindow).ignoresSafeArea())
        .background(WindowAccessor(window: $window))
        .onChange(of: window) { _, newWindow in
            if let win = newWindow {
                win.isOpaque = false
                win.backgroundColor = .clear
                win.animationBehavior = .none
            }
        }
    }
    
    private func performBackgroundSniff() async {
        guard request.url.scheme?.starts(with: "http") == true else { return }
        
        isResolving = true
        defer { isResolving = false }
        
        let isHLSUrl = request.url.absoluteString.lowercased().contains(".m3u8") || request.filename.lowercased().contains(".m3u8")
        
        var req = URLRequest(url: request.url)
        req.httpMethod = "GET"
        
        if !isHLSUrl {
            req.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        }
        
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
                
                let ct = (httpResp.value(forHTTPHeaderField: "Content-Type") ?? httpResp.value(forHTTPHeaderField: "content-type"))?.lowercased() ?? ""
                let isHLS = isHLSUrl || ct.contains("mpegurl") || ct.contains("m3u8") || ct.contains("apple.mpegurl")
                
                await MainActor.run {
                    var foundName: String? = nil
                    
                    if let disposition = httpResp.value(forHTTPHeaderField: "Content-Disposition") ?? httpResp.value(forHTTPHeaderField: "content-disposition") {
                        if let range = disposition.range(of: "filename=", options: .caseInsensitive) {
                            var fn = String(disposition[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                            if fn.hasPrefix("\"") {
                                fn = String(fn.dropFirst())
                                if let endQuote = fn.firstIndex(of: "\"") { fn = String(fn[..<endQuote]) }
                            } else {
                                if let endSemi = fn.firstIndex(of: ";") { fn = String(fn[..<endSemi]) }
                            }
                            if !fn.isEmpty { foundName = fn }
                        }
                    }
                    
                    if foundName == nil {
                        let finalURL = httpResp.url ?? request.url
                        let lastComponent = finalURL.lastPathComponent.removingPercentEncoding ?? finalURL.lastPathComponent
                        if lastComponent.contains(".") && lastComponent != "/" {
                            foundName = lastComponent
                        }
                    }
                    
                    if let fn = foundName, fn != "download", fn != "file" {
                        self.filename = fn
                    }
                    
                    if isHLS {
                        if self.filename.lowercased().hasSuffix(".m3u8") {
                            self.filename = String(self.filename.dropLast(5)) + ".mp4"
                        } else if !self.filename.lowercased().hasSuffix(".mp4") {
                            self.filename += ".mp4"
                        }
                        
                        // Drop size guessing completely for HLS
                        self.resolvedSize = 0
                    } else {
                        // Standard size resolution
                        if let cr = httpResp.value(forHTTPHeaderField: "Content-Range") ?? httpResp.value(forHTTPHeaderField: "content-range") {
                            if let totalStr = cr.components(separatedBy: "/").last, let total = Int64(totalStr.trimmingCharacters(in: .whitespaces)) {
                                self.resolvedSize = total
                            }
                        } else if let cl = httpResp.value(forHTTPHeaderField: "Content-Length") ?? httpResp.value(forHTTPHeaderField: "content-length"), let total = Int64(cl) {
                            self.resolvedSize = total
                        }
                    }
                }
            }
        } catch { }
    }
}

private func suggestName(_ url: URL) -> String {
    var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
    c?.query = nil
    let last = (c?.url ?? url).lastPathComponent
    let dec  = last.removingPercentEncoding ?? last
    return (!dec.isEmpty && dec != "/") ? dec : "download"
}
