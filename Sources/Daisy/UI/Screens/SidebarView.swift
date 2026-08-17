import SwiftUI

struct SidebarView: View {
    @Binding var selected: SidebarFilter
    var engine: DownloadEngine
    let onSettings: () -> Void

    @AppStorage("accentColorHex") private var accentColorHex = "#0A84FF"
    @AppStorage("enableBackgroundTint") private var enableBackgroundTint = false
    @AppStorage("isCompactSidebar") private var isCompactSidebar = false

    private var counts: [SidebarFilter: Int] {
        var result: [SidebarFilter: Int] = [:]
        for filter in SidebarFilter.allCases { result[filter] = 0 }
        for item in engine.items {
            for filter in SidebarFilter.allCases where filter.matches(item) {
                result[filter, default: 0] += 1
            }
        }
        return result
    }

    var body: some View {
        let counts = self.counts
        let tintBackground = enableBackgroundTint ? Color(hex: accentColorHex).opacity(0.04) : Color.clear

        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .center, spacing: isCompactSidebar ? 8 : 2) {
                    if !isCompactSidebar {
                        Text("LIBRARY")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 10)
                            .padding(.top, 16)
                            .padding(.bottom, 4)
                    }

                    ForEach(SidebarFilter.allCases) { filter in
                        SidebarRow(
                            filter: filter,
                            count: counts[filter, default: 0],
                            isSelected: selected == filter,
                            accentColorHex: accentColorHex,
                            isCompact: isCompactSidebar
                        )
                        .onTapGesture {
                            selected = filter
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, isCompactSidebar ? 0 : 8)
            }
            .background(tintBackground)

            Divider()

            Button(action: onSettings) {
                if isCompactSidebar {
                    VStack(spacing: 3) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 18, weight: .medium))
                        Text("Settings")
                            .font(.system(size: 9.5, weight: .medium))
                    }
                    .frame(maxWidth: .infinity, minHeight: 48)
                } else {
                    HStack {
                        Label("Settings", systemImage: "gearshape")
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
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .padding(.horizontal, 12)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Settings")
            .background(.ultraThinMaterial)
            .background(tintBackground)
        }
        .frame(minWidth: isCompactSidebar ? 184 : 0)
        .animation(.easeInOut(duration: 0.18), value: isCompactSidebar)
    }
}

struct SidebarRow: View {
    let filter: SidebarFilter
    let count: Int
    let isSelected: Bool
    let accentColorHex: String
    let isCompact: Bool

    @State private var isHovering = false

    private var dynamicTextColor: Color {
        isSelected ? Color(hex: accentColorHex).accessibleText : .primary
    }

    var body: some View {
        Group {
            if isCompact {
                VStack(spacing: 3) {
                    ZStack {
                        Circle()
                            .fill(
                                isSelected
                                    ? Color(hex: accentColorHex)
                                    : (isHovering ? Color.primary.opacity(0.06) : Color.clear)
                            )
                            .frame(width: 38, height: 38)

                        Image(systemName: filter.icon)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(dynamicTextColor)
                    }

                    Text(filter.rawValue)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(isSelected ? Color(hex: accentColorHex) : .secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity, minHeight: 58)
            } else {
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
                        .fill(isSelected ? Color(hex: accentColorHex) : (isHovering ? Color.primary.opacity(0.06) : Color.clear))
                )
                .contentShape(Rectangle())
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .help(isCompact ? "\(filter.rawValue)\(count > 0 ? " (\(count))" : "")" : "")
    }
}
