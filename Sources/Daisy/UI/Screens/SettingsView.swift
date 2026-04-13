import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    
    @AppStorage("fileCollisionBehavior") private var collisionBehavior = "rename"
    @AppStorage("removeBehavior")        private var removeBehavior    = "ask"
    @AppStorage("maxConcurrentDownloads") private var maxConcurrent    = 5
    @AppStorage("bypassModifierKey")     private var bypassModifierKey = "altKey"
    
    @AppStorage("accentColorHex")        private var accentColorHex       = "#0A84FF"
    @AppStorage("progressBarColorHex")   private var progressBarColorHex  = "#34C759"
    @AppStorage("matchProgressBarToAccent") private var matchProgressBarToAccent = false
    @AppStorage("enableBackgroundTint")  private var enableBackgroundTint = false
    
    @AppStorage("matchBadgesToAccent")   private var matchBadgesToAccent = false
    @AppStorage("completedColorHex")     private var completedColorHex   = "#34C759"
    @AppStorage("failedColorHex")        private var failedColorHex      = "#FF3B30"
    @AppStorage("downloadingColorHex")   private var downloadingColorHex = "#0A84FF"
    @AppStorage("stoppedColorHex")       private var stoppedColorHex     = "#FF9500"

    @State private var selectedTab: SettingsTab = .general

    enum SettingsTab: String {
        case general = "General"
        case appearance = "Appearance"
        
        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .appearance: return "paintpalette"
            }
        }
    }

    private var accentColor: Binding<Color> {
        Binding(get: { Color(hex: accentColorHex) }, set: { accentColorHex = $0.hex })
    }
    private var progressBarColor: Binding<Color> {
        Binding(get: { Color(hex: progressBarColorHex) }, set: { progressBarColorHex = $0.hex })
    }
    private var completedColor: Binding<Color> {
        Binding(get: { Color(hex: completedColorHex) }, set: { completedColorHex = $0.hex })
    }
    private var failedColor: Binding<Color> {
        Binding(get: { Color(hex: failedColorHex) }, set: { failedColorHex = $0.hex })
    }
    private var downloadingColor: Binding<Color> {
        Binding(get: { Color(hex: downloadingColorHex) }, set: { downloadingColorHex = $0.hex })
    }
    private var stoppedColor: Binding<Color> {
        Binding(get: { Color(hex: stoppedColorHex) }, set: { stoppedColorHex = $0.hex })
    }

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar for tabs
            VStack(alignment: .leading, spacing: 4) {
                Text("Settings")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.top, 14)
                    .padding(.bottom, 4)

                ForEach([SettingsTab.general, SettingsTab.appearance], id: \.self) { tab in
                    SettingsTabRow(
                        tab: tab,
                        isSelected: selectedTab == tab,
                        accentColorHex: accentColorHex
                    ) {
                        selectedTab = tab
                    }
                }
                Spacer()
            }
            .padding(8)
            .frame(width: 160)
            .background(enableBackgroundTint ? Color(hex: accentColorHex).opacity(0.08) : Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // Main Content Area
            VStack(spacing: 0) {
                ScrollView {
                    if selectedTab == .general {
                        generalForm
                    } else {
                        appearanceForm
                    }
                }
                
                Divider()
                
                HStack {
                    Spacer()
                    Button("Done") {
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Color(hex: accentColorHex))
                    .foregroundStyle(Color(hex: accentColorHex).accessibleText)
                }
                .padding()
                .background(enableBackgroundTint ? Color(hex: accentColorHex).opacity(0.04) : Color(NSColor.windowBackgroundColor))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(enableBackgroundTint ? Color(hex: accentColorHex).opacity(0.06) : Color(NSColor.controlBackgroundColor))
        }
        .frame(width: 580, height: 420)
        .interactiveDismissDisabled()
    }
    
    var generalForm: some View {
        Form {
            Section("File Management") {
                Picker("File Collision:", selection: $collisionBehavior) {
                    Text("Rename (Create Duplicate)").tag("rename")
                    Text("Replace Existing File").tag("replace")
                }
                
                Picker("When Removing:", selection: $removeBehavior) {
                    Text("Ask Every Time").tag("ask")
                    Text("Move File to Trash").tag("trash")
                    Text("Remove from List Only").tag("keep")
                }
            }
            
            Section("Network & Browser") {
                Stepper(value: $maxConcurrent, in: 1...20) {
                    Text("Max Concurrent Downloads: \(maxConcurrent)")
                }
                
                Picker("Browser Bypass Key:", selection: $bypassModifierKey) {
                    Text("Option (Alt)").tag("altKey")
                    Text("Command (⌘)").tag("metaKey")
                    Text("Control (^)").tag("ctrlKey")
                    Text("Shift (⇧)").tag("shiftKey")
                }
                Text("Hold this key while clicking a download link in your browser to bypass Dispatch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden) // Removes native opaque background to reveal custom tint
    }
    
    var appearanceForm: some View {
        Form {
            Section("Theme Customization") {
                ColorPicker("Accent Color", selection: accentColor)
                
                Toggle("Match Progress Bar to Accent Color", isOn: $matchProgressBarToAccent)
                
                if !matchProgressBarToAccent {
                    ColorPicker("Progress Bar Color", selection: progressBarColor)
                }
                
                Toggle("Tint Background", isOn: $enableBackgroundTint)
            }
            
            Section("Status Badges") {
                Toggle("Match Badge Styles to Accent Theme", isOn: $matchBadgesToAccent)
                
                ColorPicker("Downloading", selection: downloadingColor)
                ColorPicker("Completed", selection: completedColor)
                ColorPicker("Stopped", selection: stoppedColor)
                ColorPicker("Failed", selection: failedColor)
                
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
                }
                .padding(.top, 8)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden) // Removes native opaque background to reveal custom tint
    }
}

// MARK: - Reusable Sidebar Row Component

struct SettingsTabRow: View {
    let tab: SettingsView.SettingsTab
    let isSelected: Bool
    let accentColorHex: String
    let action: () -> Void

    var dynamicTextColor: Color {
        isSelected ? Color(hex: accentColorHex).accessibleText : .primary
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: tab.icon)
                .frame(width: 16, alignment: .center)
            Text(tab.rawValue)
            Spacer()
        }
        .font(.system(size: 13))
        .foregroundStyle(dynamicTextColor)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color(hex: accentColorHex) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }
}

// MARK: - Color ↔ Hex, Legibility & HSB Math

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
        guard let base = NSColor(self).usingColorSpace(.sRGB),
              let theme = NSColor(accent).usingColorSpace(.sRGB) else { return self }
        
        var h1: CGFloat = 0, s1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var h2: CGFloat = 0, s2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        
        base.getHue(&h1, saturation: &s1, brightness: &b1, alpha: &a1)
        theme.getHue(&h2, saturation: &s2, brightness: &b2, alpha: &a2)
        
        let finalSaturation = s2 < 0.15 ? s1 : s2
        let finalBrightness = b2 < 0.15 ? max(b1, 0.4) : b2
        
        return Color(nsColor: NSColor(calibratedHue: h1, saturation: finalSaturation, brightness: finalBrightness, alpha: a1))
    }
    
    func adaptedForScheme(_ scheme: ColorScheme) -> Color {
        guard let base = NSColor(self).usingColorSpace(.sRGB) else { return self }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        base.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        
        if scheme == .dark {
            let bright = max(b, 0.65)
            let sat = min(s, 0.75)
            return Color(nsColor: NSColor(calibratedHue: h, saturation: sat, brightness: bright, alpha: a))
        } else {
            let bright = min(b, 0.85)
            let sat = max(s, 0.5)
            return Color(nsColor: NSColor(calibratedHue: h, saturation: sat, brightness: bright, alpha: a))
        }
    }
}
