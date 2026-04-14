import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    
    // General
    @AppStorage("defaultDownloadPath")   private var defaultDownloadPath = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!.path
    @AppStorage("alwaysPinProgressWindows") private var alwaysPinProgressWindows = false
    @AppStorage("playSoundOnComplete")   private var playSoundOnComplete = true
    @AppStorage("fileCollisionBehavior") private var collisionBehavior = "rename"
    @AppStorage("removeBehavior")        private var removeBehavior    = "ask"
    
    // Network
    @AppStorage("maxConcurrentDownloads") private var maxConcurrent = 5
    @AppStorage("globalSpeedLimit")       private var globalSpeedLimit = 0
    @AppStorage("bypassModifierKey")      private var bypassModifierKey = "altKey"
    
    // Proxy
    @AppStorage("proxyEnabled")   private var proxyEnabled = false
    @AppStorage("proxyHost")      private var proxyHost = ""
    @AppStorage("proxyPort")      private var proxyPort = "8080"
    @AppStorage("proxyUsername")  private var proxyUsername = ""
    @AppStorage("proxyPassword")  private var proxyPassword = ""

    // Appearance
    @AppStorage("accentColorHex")           private var accentColorHex       = "#0A84FF"
    @AppStorage("progressBarColorHex")      private var progressBarColorHex  = "#34C759"
    @AppStorage("matchProgressBarToAccent") private var matchProgressBarToAccent = false
    @AppStorage("enableBackgroundTint")     private var enableBackgroundTint = false
    @AppStorage("matchBadgesToAccent")      private var matchBadgesToAccent = false
    @AppStorage("completedColorHex")        private var completedColorHex   = "#34C759"
    @AppStorage("failedColorHex")           private var failedColorHex      = "#FF3B30"
    @AppStorage("downloadingColorHex")      private var downloadingColorHex = "#0A84FF"
    @AppStorage("stoppedColorHex")          private var stoppedColorHex     = "#FF9500"

    @State private var selectedTab: SettingsTab = .general

    enum SettingsTab: String, CaseIterable {
        case general = "General"
        case network = "Network & Proxy"
        case appearance = "Appearance"
        
        var icon: String {
            switch self {
            case .general: return "gearshape.fill"
            case .network: return "network"
            case .appearance: return "paintpalette.fill"
            }
        }
        
        var iconColor: Color {
            switch self {
            case .general: return .gray
            case .network: return .blue
            case .appearance: return .purple
            }
        }
    }
    
    private var accentColor: Binding<Color> { Binding(get: { Color(hex: accentColorHex) }, set: { accentColorHex = $0.hex }) }
    private var progressBarColor: Binding<Color> { Binding(get: { Color(hex: progressBarColorHex) }, set: { progressBarColorHex = $0.hex }) }
    private var completedColor: Binding<Color> { Binding(get: { Color(hex: completedColorHex) }, set: { completedColorHex = $0.hex }) }
    private var failedColor: Binding<Color> { Binding(get: { Color(hex: failedColorHex) }, set: { failedColorHex = $0.hex }) }
    private var downloadingColor: Binding<Color> { Binding(get: { Color(hex: downloadingColorHex) }, set: { downloadingColorHex = $0.hex }) }
    private var stoppedColor: Binding<Color> { Binding(get: { Color(hex: stoppedColorHex) }, set: { stoppedColorHex = $0.hex }) }

    var body: some View {
        HStack(spacing: 0) {
            // MARK: - Sidebar
            VStack(alignment: .leading, spacing: 6) {
                Text("Preferences")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.top, 30)
                    .padding(.bottom, 12)

                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    SettingsTabRow(tab: tab, isSelected: selectedTab == tab, accentColorHex: accentColorHex) {
                        selectedTab = tab
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(width: 220)
            
            Divider()
            
            // MARK: - Main Content Area
            VStack(spacing: 0) {
                HStack {
                    Text(selectedTab.rawValue)
                        .font(.system(size: 22, weight: .semibold))
                    Spacer()
                }
                .padding(.top, 28)
                .padding(.horizontal, 32)
                .padding(.bottom, 16)
                
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 24) {
                        if selectedTab == .general { generalContent }
                        else if selectedTab == .network { networkContent }
                        else { appearanceContent }
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 32)
                }
                
                Divider()
                
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }
                        .buttonStyle(ActionButtonStyle(prominent: true, hex: accentColorHex))
                        .padding(.horizontal, 24)
                        .padding(.vertical, 16)
                        .keyboardShortcut(.cancelAction)
                }
                .background(Color(NSColor.windowBackgroundColor))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 760, height: 580)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(NSColor.separatorColor), lineWidth: 0.5)
        )
        .interactiveDismissDisabled()
    }
    
    // MARK: - Tab Contents
    
    var generalContent: some View {
        VStack(spacing: 24) {
            SettingsCard(title: "Behavior") {
                SettingsRow("Default Directory", addDivider: true) {
                    HStack(spacing: 8) {
                        Text(defaultDownloadPath)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 180, alignment: .trailing)
                        Button("Choose...") {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = false
                            panel.canChooseDirectories = true
                            if panel.runModal() == .OK, let url = panel.url {
                                defaultDownloadPath = url.path(percentEncoded: false)
                            }
                        }
                        .buttonStyle(ActionButtonStyle(prominent: false, hex: accentColorHex))
                    }
                } 
                SettingsRow("Always pin progress windows on top", addDivider: true) {
                    Toggle("", isOn: $alwaysPinProgressWindows).labelsHidden().toggleStyle(.switch)
                }
                SettingsRow("Play sound on completion", addDivider: false) {
                    Toggle("", isOn: $playSoundOnComplete).labelsHidden().toggleStyle(.switch)
                }
            }
            
            SettingsCard(title: "File Management") {
                SettingsRow("File Collision", addDivider: true) {
                    Picker("", selection: $collisionBehavior) {
                        Text("Rename (Create Duplicate)").tag("rename")
                        Text("Replace Existing File").tag("replace")
                    }.labelsHidden().frame(width: 200)
                }
                SettingsRow("When Removing", addDivider: false) {
                    Picker("", selection: $removeBehavior) {
                        Text("Ask Every Time").tag("ask")
                        Text("Move File to Trash").tag("trash")
                        Text("Remove from List Only").tag("keep")
                    }.labelsHidden().frame(width: 200)
                }
            }
        }
    }
    
    var networkContent: some View {
        VStack(spacing: 24) {
            SettingsCard(title: "Performance") {
                SettingsRow("Max Concurrent Downloads", addDivider: true) {
                    HStack(spacing: 8) {
                        Text("\(maxConcurrent)")
                            .monospacedDigit()
                            .frame(width: 24, alignment: .trailing)
                        Stepper("", value: $maxConcurrent, in: 1...20).labelsHidden()
                    }
                }
                SettingsRow("Global Speed Limit", addDivider: true) {
                    HStack(spacing: 6) {
                        TextField("0", value: $globalSpeedLimit, formatter: NumberFormatter())
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                            .multilineTextAlignment(.trailing)
                        Text("KB/s").foregroundStyle(.secondary)
                    }
                }
                SettingsRow("Browser Bypass Key", addDivider: false) {
                    Picker("", selection: $bypassModifierKey) {
                        Text("Option (Alt)").tag("altKey")
                        Text("Command (⌘)").tag("metaKey")
                        Text("Control (^)").tag("ctrlKey")
                        Text("Shift (⇧)").tag("shiftKey")
                    }.labelsHidden().frame(width: 140)
                }
            }
            
            SettingsCard(title: "Proxy Configuration") {
                SettingsRow("Enable Proxy", addDivider: proxyEnabled) {
                    Toggle("", isOn: $proxyEnabled).labelsHidden().toggleStyle(.switch)
                }
                
                if proxyEnabled {
                    SettingsRow("Host & Port", addDivider: true) {
                        HStack(spacing: 6) {
                            TextField("Host (e.g. 127.0.0.1)", text: $proxyHost)
                                .textFieldStyle(.roundedBorder).frame(width: 140)
                            Text(":")
                            TextField("Port", text: $proxyPort)
                                .textFieldStyle(.roundedBorder).frame(width: 60)
                        }
                    }
                    SettingsRow("Username (Optional)", addDivider: true) {
                        SecureField("Username", text: $proxyUsername)
                            .textFieldStyle(.roundedBorder).frame(width: 216)
                    }
                    SettingsRow("Password (Optional)", addDivider: true) {
                        SecureField("Password", text: $proxyPassword)
                            .textFieldStyle(.roundedBorder).frame(width: 216)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Supported protocols: HTTP, HTTPS, SOCKS5.")
                        Text("If using SOCKS5, prepend 'socks5://' to the host.")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
    
    var appearanceContent: some View {
        VStack(spacing: 24) {
            SettingsCard(title: "Theme Customization") {
                SettingsRow("App Accent Color", addDivider: true) {
                    ColorPicker("", selection: accentColor, supportsOpacity: false).labelsHidden()
                }
                SettingsRow("Match Progress Bar to Accent Color", addDivider: !matchProgressBarToAccent) {
                    Toggle("", isOn: $matchProgressBarToAccent).labelsHidden().toggleStyle(.switch)
                }
                if !matchProgressBarToAccent {
                    SettingsRow("Progress Bar Color", addDivider: true) {
                        ColorPicker("", selection: progressBarColor, supportsOpacity: false).labelsHidden()
                    }
                }
                SettingsRow("Slightly Tint App Background", addDivider: false) {
                    Toggle("", isOn: $enableBackgroundTint).labelsHidden().toggleStyle(.switch)
                }
            }
            
            SettingsCard(title: "Status Badges") {
                SettingsRow("Match Badge Styles to Accent Theme", addDivider: !matchBadgesToAccent) {
                    Toggle("", isOn: $matchBadgesToAccent).labelsHidden().toggleStyle(.switch)
                }
                if !matchBadgesToAccent {
                    SettingsRow("Downloading Status Color", addDivider: true) {
                        ColorPicker("", selection: downloadingColor, supportsOpacity: false).labelsHidden()
                    }
                    SettingsRow("Completed Status Color", addDivider: true) {
                        ColorPicker("", selection: completedColor, supportsOpacity: false).labelsHidden()
                    }
                    SettingsRow("Stopped Status Color", addDivider: true) {
                        ColorPicker("", selection: stoppedColor, supportsOpacity: false).labelsHidden()
                    }
                    SettingsRow("Failed Status Color", addDivider: false) {
                        ColorPicker("", selection: failedColor, supportsOpacity: false).labelsHidden()
                    }
                }
            }
            
            HStack {
                Spacer()
                Button("Reset Appearance Defaults") {
                    withAnimation {
                        accentColorHex = "#0A84FF"
                        progressBarColorHex = "#34C759"
                        matchProgressBarToAccent = false
                        enableBackgroundTint = false
                        matchBadgesToAccent = false
                        completedColorHex = "#34C759"
                        failedColorHex = "#FF3B30"
                        downloadingColorHex = "#0A84FF"
                        stoppedColorHex = "#FF9500"
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color(hex: accentColorHex))
                .font(.system(size: 13, weight: .medium))
                Spacer()
            }
        }
    }
}

// MARK: - Reusable Components

struct SettingsCard<Content: View>: View {
    let title: String
    let content: Content
    
    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            
            VStack(spacing: 0) {
                content
            }
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color(NSColor.separatorColor).opacity(0.5), lineWidth: 1)
            )
        }
    }
}

struct SettingsRow<Content: View>: View {
    let title: String
    let content: Content
    let addDivider: Bool
    
    init(_ title: String, addDivider: Bool = true, @ViewBuilder content: () -> Content) {
        self.title = title
        self.addDivider = addDivider
        self.content = content()
    }
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                Spacer()
                content
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            
            if addDivider {
                Divider()
                    .padding(.leading, 16)
            }
        }
    }
}

struct SettingsTabRow: View {
    let tab: SettingsView.SettingsTab
    let isSelected: Bool
    let accentColorHex: String
    let action: () -> Void
    
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.clear)
                        .frame(width: 26, height: 26)
                    
                    Image(systemName: tab.icon)
                        .font(.system(size: 13, weight: .semibold))
                        .tint(Color(hex: accentColorHex).accessibleText)
                }
                
                Text(tab.rawValue)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isSelected ? Color(hex: accentColorHex).accessibleText : Color.primary.opacity(0.85))
                
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color(hex: accentColorHex) : (isHovering ? Color.primary.opacity(0.06) : Color.clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Color Extensions
extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s = String(s.dropFirst()) }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        let value = UInt64(s, radix: 16) ?? 0x0A84FF
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >>  8) & 0xFF) / 255
        let b = Double( value        & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }

    var hex: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .blue
        let r = Int((c.redComponent   * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent  * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
    
    var accessibleText: Color {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return .white }
        let luminance = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        return luminance > 0.55 ? .black : .white
    }
    
    func matchingThemeVisualWeight(of accent: Color) -> Color {
        guard let base = NSColor(self).usingColorSpace(.sRGB), let theme = NSColor(accent).usingColorSpace(.sRGB) else { return self }
        var h1: CGFloat = 0, s1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var h2: CGFloat = 0, s2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        base.getHue(&h1, saturation: &s1, brightness: &b1, alpha: &a1)
        theme.getHue(&h2, saturation: &s2, brightness: &b2, alpha: &a2)
        return Color(nsColor: NSColor(calibratedHue: h1, saturation: s2 < 0.15 ? s1 : s2, brightness: b2 < 0.15 ? max(b1, 0.4) : b2, alpha: a1))
    }
    
    func adaptedForScheme(_ scheme: ColorScheme) -> Color {
        guard let base = NSColor(self).usingColorSpace(.sRGB) else { return self }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        base.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        if scheme == .dark { return Color(nsColor: NSColor(calibratedHue: h, saturation: min(s, 0.75), brightness: max(b, 0.65), alpha: a)) }
        else { return Color(nsColor: NSColor(calibratedHue: h, saturation: max(s, 0.5), brightness: min(b, 0.85), alpha: a)) }
    }
}
