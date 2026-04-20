import SwiftUI

struct SidebarView: View {
    @Binding var selected: SidebarFilter
    var engine: DownloadEngine
    let onSettings: () -> Void

    @AppStorage("accentColorHex") private var accentColorHex = "#0A84FF"
    @AppStorage("enableBackgroundTint") private var enableBackgroundTint = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    Text("LIBRARY")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 10)
                        .padding(.top, 16)
                        .padding(.bottom, 4)
                    
                    ForEach(SidebarFilter.allCases) { filter in
                        SidebarRow(
                            filter: filter,
                            count: count(for: filter),
                            isSelected: selected == filter,
                            accentColorHex: accentColorHex
                        )
                        .onTapGesture {
                            selected = filter
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            .background(enableBackgroundTint ? Color(hex: accentColorHex).opacity(0.04) : Color.clear)

            Divider()

            HStack {
                Button(action: onSettings) {
                    Label("Settings", systemImage: "gearshape")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
                
                Spacer()
                
                if engine.globalDownloadSpeed > 512 {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 10, weight: .bold))
                        Text(formatBytes(Int64(engine.globalDownloadSpeed)) + "/s")
                            .font(.system(size: 11, design: .monospaced))
                    }
                    .foregroundStyle(Color(hex: accentColorHex))
                }
            }
            .padding(12)
            .background(.ultraThinMaterial)
            .background(enableBackgroundTint ? Color(hex: accentColorHex).opacity(0.04) : Color.clear)
        }
    }

    private func count(for filter: SidebarFilter) -> Int {
        engine.items.filter { filter.matches($0) }.count
    }
}

struct SidebarRow: View {
    let filter: SidebarFilter
    let count: Int
    let isSelected: Bool
    let accentColorHex: String

    var dynamicTextColor: Color {
        isSelected ? Color(hex: accentColorHex).accessibleText : .primary
    }

    var body: some View {
        HStack {
            Image(systemName: filter.icon)
                .frame(width: 18, alignment: .center)
            
            Text(filter.rawValue)
            
            Spacer()
            
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isSelected ? dynamicTextColor : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(isSelected ? dynamicTextColor.opacity(0.25) : Color.primary.opacity(0.08))
                    )
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(dynamicTextColor)
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isSelected ? Color(hex: accentColorHex) : Color.clear)
        )
        .contentShape(Rectangle())
    }
}
