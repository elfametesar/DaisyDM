import SwiftUI
import AppKit

struct AddDownloadSheet: View {
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
        urlText.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .compactMap { URL(string: $0) }
            .filter { $0.scheme?.hasPrefix("http") == true || $0.scheme == "magnet" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(hex: accentColorHex).opacity(0.15))
                        .frame(width: 40, height: 40)
                    if isResolving {
                        ProgressView()
                            .scaleEffect(0.8)
                            .tint(Color(hex: accentColorHex))
                    } else {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(Color(hex: accentColorHex))
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("New Download")
                        .font(.title3.weight(.semibold))
                    Text(isResolving ? "Extracting direct links..." : "Enter a direct link or paste multiple links for a batch")
                        .font(.callout)
                        .foregroundStyle(isResolving ? Color(hex: accentColorHex) : .secondary)
                }
            }
            .padding(20)

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("URL").font(.callout.weight(.medium)).foregroundStyle(.primary)
                    HStack(alignment: .top) {
                        Image(systemName: "link").foregroundStyle(.primary).font(.system(size: 13)).padding(.top, 4)

                        ZStack(alignment: .topLeading) {
                            if urlText.isEmpty {
                                Text("https://example.com/file1.zip\nPaste multiple links to extract the direct URLs")
                                    .foregroundStyle(.primary)
                                    .font(.system(size: 13))
                                    .padding(.top, 4)
                                    .allowsHitTesting(false)
                            }
                            TextEditor(text: $urlText)
                                .font(.system(size: 13))
                                .scrollContentBackground(.hidden)
                                .background(Color.clear)
                                .frame(minHeight: 60, maxHeight: 120)
                                .focused($focusedField, equals: .urlInput)
                                .onChange(of: urlText) { _, newText in
                                    if newText.contains("\t") {
                                        urlText = newText.replacingOccurrences(of: "\t", with: "")
                                        focusedField = .chooseFolder
                                    }
                                    isValid = !parsedURLs.isEmpty
                                    triggerAutoResolveIfNeed(newText: urlText)
                                }
                                .disabled(isResolving)
                        }

                        if !urlText.isEmpty {
                            Button { urlText = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.primary)
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 4)
                            .disabled(isResolving)
                        }
                        Divider().padding(.vertical, 4)
                        Button {
                            if let s = NSPasteboard.general.string(forType: .string), !s.isEmpty { urlText = s }
                        } label: {
                            Image(systemName: "doc.on.clipboard").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Paste from clipboard")
                        .padding(.top, 4)
                        .disabled(isResolving)
                    }
                    .padding(9)
                    .background(Color.white.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(
                        isValid ? Color(hex: accentColorHex).opacity(0.5) : Color.primary.opacity(0.08), lineWidth: 1))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Save to").font(.callout.weight(.medium)).foregroundStyle(.primary)
                    HStack {
                        Image(systemName: "folder").foregroundStyle(.primary).font(.system(size: 13))
                        Text(destination.path(percentEncoded: false))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Choose…") {
                            let p = NSOpenPanel()
                            p.canChooseFiles = false
                            p.canChooseDirectories = true
                            p.prompt = "Select"
                            if p.runModal() == .OK, let u = p.url { destination = u }
                        }
                        .buttonStyle(ActionButtonStyle(prominent: false, hex: accentColorHex))
                        .disabled(isResolving)
                        .focused($focusedField, equals: .chooseFolder)
                    }
                    .padding(9)
                    .background(Color.white.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08), lineWidth: 1))
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Connections").font(.callout.weight(.medium)).foregroundStyle(.primary)
                        Spacer()
                        Text("\(connections)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                    }
                    HStack(spacing: 10) {
                        Text("1").font(.caption).foregroundStyle(.primary)
                        Slider(value: Binding(
                            get: { Double(connections) },
                            set: { connections = Int($0) }
                        ), in: 1...32, step: 1)
                        .foregroundStyle(.primary)
                        .disabled(isResolving)
                        .focused($focusedField, equals: .connectionsSlider)
                        Text("32").font(.caption).foregroundStyle(.primary)
                    }
                    Text("More connections saturate high-bandwidth servers faster. P2P (Torrent) ignores this.")
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)

            Divider()

            HStack {
                Button(action: {
                    resolveTask?.cancel()
                    onClose()
                }) {
                    Text("Cancel")
                }
                .buttonStyle(ActionButtonStyle(prominent: false, hex: accentColorHex))
                .keyboardShortcut(.escape)
                .focused($focusedField, equals: .cancelBtn)

                Spacer()

                Button(action: {
                    let urls = parsedURLs
                    if urls.count == 1 {
                        if engine.items.contains(where: { $0.url.absoluteString == urls[0].absoluteString }) {
                            duplicateAddRequest = DuplicateAddRequest(urls: urls, destination: destination, connections: connections)
                            showingDuplicateAlert = true
                        } else {
                            engine.addDownload(urls: urls, destination: destination, connections: connections)
                            onClose()
                        }
                    } else if urls.count > 1 {
                        engine.addDownload(urls: urls, destination: destination, connections: connections)
                        onClose()
                    }
                }) {
                    Text("Add Download")
                }
                .buttonStyle(ActionButtonStyle(prominent: true, hex: accentColorHex))
                .disabled(!isValid || isResolving || urlText.isEmpty)
                .keyboardShortcut(.return)
                .focused($focusedField, equals: .addBtn)
            }
            .padding(16)
        }
        .frame(width: 480)
        .background(VisualEffectView(material: .popover, blendingMode: .behindWindow).ignoresSafeArea())
        .background(enableBackgroundTint ? Color(hex: accentColorHex).opacity(0.04) : Color.clear)
        .tint(Color(hex: accentColorHex))
        .alert("Duplicate Download", isPresented: $showingDuplicateAlert) {
            Button("Add Anyway") {
                if let req = duplicateAddRequest {
                    engine.addDownload(urls: req.urls, destination: req.destination, connections: req.connections)
                    onClose()
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This URL is already in your download list. Do you want to add it again?")
        }
        .onAppear {
            focusedField = .urlInput
            
            if let clip = NSPasteboard.general.string(forType: .string),
               !clip.trimmingCharacters(in: .whitespaces).isEmpty {
                let lines = clip.components(separatedBy: .whitespacesAndNewlines)
                    .compactMap { URL(string: $0.trimmingCharacters(in: .whitespaces)) }
                    .filter { $0.scheme?.hasPrefix("http") == true || $0.scheme == "magnet" }
                if !lines.isEmpty {
                    urlText = clip.trimmingCharacters(in: .whitespaces)
                    isValid = true
                    triggerAutoResolveIfNeed(newText: urlText)
                }
            }
        }
    }

    // MARK: - Auto Resolve HTML Regex Logic

    private func triggerAutoResolveIfNeed(newText: String) {
        let urls = parsedURLs
        let targetURLs = urls.filter { $0.host?.contains("fuckingfast.co") == true && !$0.path.starts(with: "/dl/") }

        guard !targetURLs.isEmpty && !isResolving else { return }
        isResolving = true

        resolveTask = Task {
            var finalLinks: [String] = []

            for url in urls {
                if Task.isCancelled { return }

                if targetURLs.contains(url) {
                    if let directLinks = await fetchDirectLinks(for: url) {
                        finalLinks.append(contentsOf: directLinks)
                    }
                } else {
                    finalLinks.append(url.absoluteString)
                }
            }

            if Task.isCancelled { return }

            await MainActor.run {
                let joinedLinks = finalLinks.joined(separator: "\n")
                if self.urlText.trimmingCharacters(in: .whitespacesAndNewlines) == newText.trimmingCharacters(in: .whitespacesAndNewlines) {
                    self.urlText = joinedLinks
                }
                self.isResolving = false
            }
        }
    }

    private func fetchDirectLinks(for url: URL) async -> [String]? {
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
                  let html = String(data: data, encoding: .utf8) else {
                return nil
            }

            let pattern = "window\\.open\\([\"'](https://fuckingfast\\.co/dl/[^\"']+)[\"']"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }

            let range = NSRange(location: 0, length: html.utf16.count)
            let matches = regex.matches(in: html, options: [], range: range)

            var extracted: [String] = []
            for match in matches {
                if match.numberOfRanges > 1, let swiftRange = Range(match.range(at: 1), in: html) {
                    extracted.append(String(html[swiftRange]))
                }
            }
            return extracted.isEmpty ? nil : extracted
        } catch {
            return nil
        }
    }
}
