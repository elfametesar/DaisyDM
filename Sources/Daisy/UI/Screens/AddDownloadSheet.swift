import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Subclassed NSTextView to intercept pastes
class PasteFilteringTextView: NSTextView {
    var pasteFilter: ((String) -> String)?

    override func paste(_ sender: Any?) {
        if let pasteFilter = pasteFilter, let boardStr = NSPasteboard.general.string(forType: .string) {
            let filtered = pasteFilter(boardStr)
            if !filtered.isEmpty {
                self.insertText(filtered, replacementRange: self.selectedRange())
            }
        } else {
            super.paste(sender)
        }
    }
}

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
    
    enum Field: Hashable {
        case urlInput
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
    
    private func submit() {
        guard isValid && !urlText.isEmpty else { return }
        let urls = parsedURLs
        if urls.count == 1 {
            let info: [String: Any] = [
                "url": urls[0],
                "filename": "",
                "cookies": "",
                "referer": "",
                "ua": "",
                "forceHLS": false
            ]
            NotificationCenter.default.post(name: .confirmDownload, object: nil, userInfo: info)
        } else {
            engine.addDownload(urls: urls, destination: destination, connections: connections, youtubeQuality: nil)
        }
        onClose()
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
                // MARK: - URL Input Section
                VStack(alignment: .leading, spacing: 6) {
                    Text("URL / File").font(.callout.weight(.medium))
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "link")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 13))
                            .padding(.top, 4)
                        
                        ZStack(alignment: .topLeading) {
                            if urlText.isEmpty {
                                Text("https://example.com/file1.zip\nPaste links, magnets, or drag .torrent files here")
                                    .foregroundStyle(.secondary.opacity(0.5))
                                    .font(.system(size: 13))
                                    .allowsHitTesting(false)
                            }
                            
                            SubmitTextEditor(text: $urlText, onSubmit: {
                                submit()
                            }, onPasteFilter: { clipboardText in
                                return extractValidURLStrings(from: clipboardText)
                            })
                            .frame(minHeight: 60, maxHeight: 120)
                            .focused($focusedField, equals: .urlInput)
                            .onChange(of: urlText) { _, newText in
                                isValid = !parsedURLs.isEmpty
                                triggerAutoResolveIfNeed(newText: urlText)
                            }
                            .disabled(isResolving)
                        }
                        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
                            for provider in providers {
                                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                                    if let url = url, url.pathExtension.lowercased() == "torrent" {
                                        DispatchQueue.main.async {
                                            let path = url.path(percentEncoded: false)
                                            if urlText.isEmpty { urlText = path }
                                            else { urlText += "\n" + path }
                                        }
                                    }
                                }
                            }
                            return true
                        }
                        
                        if !urlText.isEmpty {
                            Button { urlText = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 4)
                        }
                        
                        // Fixed Divider
                        Rectangle()
                            .fill(Color.primary.opacity(0.15))
                            .frame(width: 1)
                            .frame(maxHeight: .infinity)
                            .padding(.vertical, 4)
                            .padding(.horizontal, 2)
                        
                        Button {
                            if let s = NSPasteboard.general.string(forType: .string) {
                                let extracted = extractValidURLStrings(from: s)
                                if !extracted.isEmpty {
                                    urlText = extracted
                                }
                            }
                        } label: {
                            Image(systemName: "doc.on.clipboard").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Paste from clipboard")
                        .padding(.top, 4)
                    }
                    .padding(9)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(
                        isValid ? Color(hex: accentColorHex).opacity(0.4) : Color.primary.opacity(0.1), lineWidth: 1))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Save to").font(.callout.weight(.medium))
                    HStack {
                        Image(systemName: "folder").foregroundStyle(.secondary).font(.system(size: 13))
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
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1), lineWidth: 1))
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Connections").font(.callout.weight(.medium))
                        Spacer()
                        Text("\(connections)").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color(hex: accentColorHex))
                    }
                    Slider(value: Binding(get: { Double(connections) }, set: { connections = Int($0) }), in: 1...32, step: 1)
                        .tint(Color(hex: accentColorHex))
                }
            }
            .padding(20)

            Divider()

            HStack {
                Button(action: {
                    resolveTask?.cancel()
                    onClose()
                }) {
                    Label("Cancel", systemImage: "xmark.circle")
                }
                .buttonStyle(ActionButtonStyle(prominent: false, hex: accentColorHex))
                
                Spacer()
                
                Button(action: {
                    submit()
                }) {
                    Label("Add Download", systemImage: "plus.circle.fill")
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
            handleClipboardOnAppear()
        }
    }

    private func extractValidURLStrings(from text: String) -> String {
        return text.components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .filter { str in
                let url: URL? = {
                    if str.hasPrefix("/") { return URL(fileURLWithPath: str) }
                    if str.hasPrefix("file://") {
                        let clean = str.replacingOccurrences(of: "file://", with: "")
                        return URL(fileURLWithPath: clean.removingPercentEncoding ?? clean)
                    }
                    if let u = URL(string: str), u.scheme != nil { return u }
                    if let enc = str.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                       let u = URL(string: enc), u.scheme != nil { return u }
                    return nil
                }()
                
                guard let validURL = url else { return false }
                return validURL.scheme?.hasPrefix("http") == true ||
                       validURL.scheme == "magnet" ||
                       (validURL.isFileURL && validURL.pathExtension.lowercased() == "torrent")
            }
            .joined(separator: "\n")
    }

    private func handleClipboardOnAppear() {
        if !initialURLText.isEmpty {
            urlText = initialURLText
            isValid = true
            triggerAutoResolveIfNeed(newText: urlText)
        } else if let clip = NSPasteboard.general.string(forType: .string) {
            let extracted = extractValidURLStrings(from: clip)
            if !extracted.isEmpty {
                urlText = extracted
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
                    // Check if extraction succeeded and is not empty
                    if let direct = await fetchDirectLinks(for: url), !direct.isEmpty {
                        finalLinks.append(contentsOf: direct)
                    } else {
                        // Fallback to original URL if extraction fails
                        finalLinks.append(url.isFileURL ? url.path(percentEncoded: false) : url.absoluteString)
                    }
                } else {
                    finalLinks.append(url.isFileURL ? url.path(percentEncoded: false) : url.absoluteString)
                }
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

struct SubmitTextEditor: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void
    var onPasteFilter: ((String) -> String)?

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        
        // Swap out the default NSTextView with our custom one that filters pastes
        let customTextView = PasteFilteringTextView()
        customTextView.pasteFilter = onPasteFilter
        customTextView.delegate = context.coordinator
        customTextView.font = .systemFont(ofSize: 13)
        customTextView.drawsBackground = false
        customTextView.isRichText = false
        customTextView.allowsUndo = true
        customTextView.backgroundColor = .clear
        customTextView.textColor = .labelColor
        customTextView.insertionPointColor = .labelColor
        
        // Exact 0 point inset to align perfectly with ZStack hints
        customTextView.textContainerInset = NSSize(width: 0, height: 0)
        customTextView.textContainer?.lineFragmentPadding = 0
        
        customTextView.autoresizingMask = [.width]
        customTextView.isVerticallyResizable = true
        customTextView.isHorizontallyResizable = false
        customTextView.textContainer?.widthTracksTextView = true
        
        scrollView.documentView = customTextView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SubmitTextEditor
        init(_ parent: SubmitTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if let event = NSApp.currentEvent, event.modifierFlags.contains(.shift) {
                    textView.insertText("\n", replacementRange: textView.selectedRange())
                    return true
                } else {
                    parent.onSubmit()
                    return true
                }
            }
            return false
        }
    }
}
