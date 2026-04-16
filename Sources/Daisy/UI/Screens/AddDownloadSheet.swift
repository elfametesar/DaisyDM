import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AddDownloadSheet: View {
    var initialURLText: String = ""
    var onClose: () -> Void = {}

    @State private var urlText = ""
    @State private var destination = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
    @State private var connections = 16
    @State private var isValid = false
    @State private var showingDuplicateAlert = false
    @State private var duplicateAddRequest: DuplicateAddRequest? = nil
    @State private var isResolving = false
    @State private var resolveTask: Task<Void, Never>? = nil
    @State private var engine = DownloadEngine.shared

    @AppStorage("accentColorHex") private var accentColorHex = "#0A84FF"
    @AppStorage("enableBackgroundTint") private var enableBackgroundTint = false

    enum Field: Hashable {
        case urlInput
        case chooseFolder
        case connectionsSlider
        case cancelBtn
        case addBtn
    }
    @FocusState private var focusedField: Field?

    var parsedURLs: [URL] {
        urlText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .compactMap { str -> URL? in
                if str.hasPrefix("/") { return URL(fileURLWithPath: str) }
                if str.hasPrefix("file://") {
                    let clean = str.replacingOccurrences(of: "file://", with: "")
                    return URL(fileURLWithPath: clean.removingPercentEncoding ?? clean)
                }
                if let url = URL(string: str), url.scheme != nil { return url }
                if let enc = str.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                   let url = URL(string: enc), url.scheme != nil { return url }
                return nil
            }
            .filter {
                $0.scheme?.hasPrefix("http") == true ||
                $0.scheme == "magnet" ||
                ($0.isFileURL && $0.pathExtension.lowercased() == "torrent")
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(hex: accentColorHex).opacity(0.15))
                        .frame(width: 40, height: 40)
                    if isResolving {
                        ProgressView().scaleEffect(0.8).tint(Color(hex: accentColorHex))
                    } else {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(Color(hex: accentColorHex))
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("New Download").font(.title3.weight(.semibold))
                    Text(isResolving ? "Extracting direct links..." : "Enter a direct link, torrent file, or batch list")
                        .font(.callout)
                        .foregroundStyle(isResolving ? Color(hex: accentColorHex) : .secondary)
                }
            }
            .padding(20)

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("URL / File").font(.callout.weight(.medium))
                    HStack(alignment: .top) {
                        Image(systemName: "link").foregroundStyle(.primary).font(.system(size: 13)).padding(.top, 4)
                        ZStack(alignment: .topLeading) {
                            if urlText.isEmpty {
                                Text("https://example.com/file1.zip\nPaste links, magnets, or drag .torrent files here")
                                    .foregroundStyle(.primary).font(.system(size: 13)).padding(.top, 4).allowsHitTesting(false)
                            }
                            TextEditor(text: $urlText)
                                .font(.system(size: 13))
                                .scrollContentBackground(.hidden)
                                .background(Color.clear)
                                .frame(minHeight: 60, maxHeight: 120)
                                .focused($focusedField, equals: .urlInput)
                                .onChange(of: urlText) { _, newText in
                                    isValid = !parsedURLs.isEmpty
                                    triggerAutoResolveIfNeed(newText: urlText)
                                }
                                .disabled(isResolving)
                        }
                    }
                    .padding(9)
                    .background(Color.white.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(
                        isValid ? Color(hex: accentColorHex).opacity(0.5) : Color.primary.opacity(0.08), lineWidth: 1))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Save to").font(.callout.weight(.medium))
                    HStack {
                        Image(systemName: "folder").foregroundStyle(.primary).font(.system(size: 13))
                        Text(destination.path(percentEncoded: false))
                            .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Choose…") {
                            let p = NSOpenPanel()
                            p.canChooseFiles = false; p.canChooseDirectories = true
                            if p.runModal() == .OK, let u = p.url { destination = u }
                        }
                        .buttonStyle(ActionButtonStyle(prominent: false, hex: accentColorHex))
                    }
                    .padding(9)
                    .background(Color.white.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Connections").font(.callout.weight(.medium))
                        Spacer()
                        Text("\(connections)").font(.system(size: 13, weight: .semibold))
                    }
                    Slider(value: Binding(get: { Double(connections) }, set: { connections = Int($0) }), in: 1...32, step: 1)
                }
            }
            .padding(20)

            Divider()

            HStack {
                Button("Cancel") { resolveTask?.cancel(); onClose() }
                    .buttonStyle(ActionButtonStyle(prominent: false, hex: accentColorHex))
                Spacer()
                Button("Add Download") {
                    let urls = parsedURLs
                    engine.addDownload(urls: urls, destination: destination, connections: connections)
                    onClose()
                }
                .buttonStyle(ActionButtonStyle(prominent: true, hex: accentColorHex))
                .disabled(!isValid || urlText.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 480)
        .background(VisualEffectView(material: .popover, blendingMode: .behindWindow).ignoresSafeArea())
        .onAppear {
            focusedField = .urlInput
            
            var startingText = ""
            
            // Prioritize Drag & Drop context
            if !initialURLText.isEmpty {
                startingText = initialURLText
            }
            // Fallback to Clipboard
            else if let clip = NSPasteboard.general.string(forType: .string), !clip.trimmingCharacters(in: .whitespaces).isEmpty {
                let lines = clip.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .compactMap { str -> URL? in
                        if str.hasPrefix("/") { return URL(fileURLWithPath: str) }
                        if str.hasPrefix("file://") {
                            let clean = str.replacingOccurrences(of: "file://", with: "")
                            return URL(fileURLWithPath: clean.removingPercentEncoding ?? clean)
                        }
                        if let url = URL(string: str), url.scheme != nil { return url }
                        if let enc = str.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                           let url = URL(string: enc), url.scheme != nil { return url }
                        return nil
                    }
                    .filter {
                        $0.scheme?.hasPrefix("http") == true ||
                        $0.scheme == "magnet" ||
                        ($0.isFileURL && $0.pathExtension.lowercased() == "torrent")
                    }
                if !lines.isEmpty { startingText = clip.trimmingCharacters(in: .whitespaces) }
            }
            
            if !startingText.isEmpty {
                urlText = startingText
                isValid = true
                triggerAutoResolveIfNeed(newText: urlText)
            }
        }
    }

    private func triggerAutoResolveIfNeed(newText: String) {
        let urls = parsedURLs
        let targetURLs = urls.filter { $0.host?.contains("fuckingfast.co") == true && !$0.path.starts(with: "/dl/") }
        guard !targetURLs.isEmpty && !isResolving else { return }
        isResolving = true
        resolveTask = Task {
            var finalLinks = [String]()
            for url in urls {
                if Task.isCancelled { return }
                if targetURLs.contains(url) {
                    if let direct = await fetchDirectLinks(for: url) { finalLinks.append(contentsOf: direct) }
                } else { finalLinks.append(url.isFileURL ? url.path(percentEncoded: false) : url.absoluteString) }
            }
            if Task.isCancelled { return }
            await MainActor.run {
                self.urlText = finalLinks.joined(separator: "\n")
                self.isResolving = false
            }
        }
    }

    private func fetchDirectLinks(for url: URL) async -> [String]? {
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Safari/537.36", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200, let html = String(data: data, encoding: .utf8) else { return nil }
            let pattern = "window\\.open\\([\"'](https://fuckingfast\\.co/dl/[^\"']+)[\"']"
            let regex = try? NSRegularExpression(pattern: pattern)
            let matches = regex?.matches(in: html, range: NSRange(location: 0, length: html.utf16.count))
            return matches?.compactMap { m in
                if m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: html) { return String(html[r]) }
                return nil
            }
        } catch { return nil }
    }
}
