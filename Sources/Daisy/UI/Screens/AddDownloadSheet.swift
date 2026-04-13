// MARK: - AddDownloadSheet.swift
import SwiftUI
import AppKit

struct AddDownloadSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var urlText = ""
    @State private var destination = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
    @State private var connections = 16
    @State private var isValid = false
    @State private var showingDuplicateAlert = false
    @State private var duplicateAddRequest: DuplicateAddRequest? = nil
    @State private var engine = DownloadEngine.shared

    var parsedURLs: [URL] {
        urlText.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .compactMap { URL(string: $0) }
            .filter { $0.scheme?.hasPrefix("http") == true || $0.scheme == "magnet" || $0.isFileURL }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.blue.opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.blue)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("New Download")
                        .font(.title3.weight(.semibold))
                    Text("Enter a direct link or paste multiple links for a batch")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("URL").font(.callout.weight(.medium))
                    HStack(alignment: .top) {
                        Image(systemName: "link").foregroundStyle(.tertiary).font(.system(size: 13)).padding(.top, 4)
                        
                        ZStack(alignment: .topLeading) {
                            if urlText.isEmpty {
                                Text("https://example.com/file1.zip\nPaste multiple links to extract the direct URLs)")
                                    .foregroundStyle(.tertiary)
                                    .font(.system(size: 13))
                                    .padding(.top, 4)
                                    .allowsHitTesting(false)
                            }
                            TextEditor(text: $urlText)
                                .font(.system(size: 13))
                                .scrollContentBackground(.hidden)
                                .background(Color.clear)
                                .frame(minHeight: 60, maxHeight: 120)
                                .onChange(of: urlText) { _, newText in
                                    isValid = !parsedURLs.isEmpty
                                }
                        }
                        
                        if !urlText.isEmpty {
                            Button { urlText = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                            }.buttonStyle(.plain).padding(.top, 4)
                        }
                        Divider().padding(.vertical, 4)
                        Button {
                            if let s = NSPasteboard.general.string(forType: .string), !s.isEmpty { urlText = s }
                        } label: {
                            Image(systemName: "doc.on.clipboard").foregroundStyle(.secondary)
                        }.buttonStyle(.plain).help("Paste from clipboard").padding(.top, 4)
                    }
                    .padding(9)
                    .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(
                        isValid ? Color.blue.opacity(0.5) : Color(NSColor.separatorColor), lineWidth: 1))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Save to").font(.callout.weight(.medium))
                    HStack {
                        Image(systemName: "folder").foregroundStyle(.tertiary).font(.system(size: 13))
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
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(9)
                    .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(NSColor.separatorColor), lineWidth: 1))
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Connections").font(.callout.weight(.medium))
                        Spacer()
                        Text("\(connections)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.blue)
                    }
                    HStack(spacing: 10) {
                        Text("1").font(.caption).foregroundStyle(.tertiary)
                        Slider(value: Binding(
                            get: { Double(connections) },
                            set: { connections = Int($0) }
                        ), in: 1...32, step: 1).tint(.blue)
                        Text("32").font(.caption).foregroundStyle(.tertiary)
                    }
                    Text("More connections saturate high-bandwidth servers faster. P2P (Torrent) ignores this.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)

            Divider()

            HStack {
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.escape)
                
                Spacer()
                Button("Add Download") {
                    let urls = parsedURLs
                    if urls.count == 1 {
                        if engine.items.contains(where: { $0.url.absoluteString == urls[0].absoluteString }) {
                            duplicateAddRequest = DuplicateAddRequest(urls: urls, destination: destination, connections: connections)
                            showingDuplicateAlert = true
                        } else {
                            engine.addDownload(urls: urls, destination: destination, connections: connections)
                            dismiss()
                        }
                    } else if urls.count > 1 {
                        engine.addDownload(urls: urls, destination: destination, connections: connections)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValid || urlText.isEmpty)
                .keyboardShortcut(.return)
            }
            .padding(16)
        }
        .frame(width: 480)
        .interactiveDismissDisabled() // Enforces strong modal blocking
        .alert("Duplicate Download", isPresented: $showingDuplicateAlert) {
            Button("Add Anyway") {
                if let req = duplicateAddRequest {
                    engine.addDownload(urls: req.urls, destination: req.destination, connections: req.connections)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This URL is already in your download list. Do you want to add it again?")
        }
        .onAppear {
            if let clip = NSPasteboard.general.string(forType: .string),
               !clip.trimmingCharacters(in: .whitespaces).isEmpty {
                let lines = clip.components(separatedBy: .whitespacesAndNewlines).compactMap { URL(string: $0.trimmingCharacters(in: .whitespaces)) }.filter { $0.scheme?.hasPrefix("http") == true || $0.scheme == "magnet" }
                if !lines.isEmpty {
                    urlText = clip.trimmingCharacters(in: .whitespaces)
                    isValid = true
                }
            }
        }
    }
}
