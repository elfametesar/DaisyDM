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
                VStack(spacing: isCompactSidebar ? 14 : 4) {
                    if !isCompactSidebar {
                        Text("LIBRARY")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
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
                .padding(.top, isCompactSidebar ? 14 : 0)
            }
            .background(tintBackground)

            Divider()

            HStack {
                Button(action: onSettings) {
                    if isCompactSidebar {
                        Image(systemName: "gearshape")
                            .font(.system(size: 18, weight: .medium))
                            .frame(width: 24, height: 24)
                    } else {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
                .help(isCompactSidebar ? "Settings" : "")

                if !isCompactSidebar {
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
                } else if engine.globalDownloadSpeed > 512 {
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color(hex: accentColorHex))
                        .help(formatBytes(Int64(engine.globalDownloadSpeed)) + "/s")
                }
            }
            .frame(maxWidth: .infinity, alignment: isCompactSidebar ? .center : .leading)
            .padding(10)
            .background(.ultraThinMaterial)
            .background(tintBackground)
        }
        .frame(width: isCompactSidebar ? 196 : nil, minWidth: isCompactSidebar ? 196 : 0, maxWidth: isCompactSidebar ? 196 : .infinity)
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

    var dynamicTextColor: Color {
        isSelected ? Color(hex: accentColorHex).accessibleText : .primary
    }

    var body: some View {
        Group {
            if isCompact {
                VStack(spacing: 4) {
                    Image(systemName: filter.icon)
                        .font(.system(size: 19, weight: .medium))
                        .frame(width: 38, height: 38)
                        .background(
                            Circle()
                                .fill(isSelected ? Color(hex: accentColorHex) : (isHovering ? Color.primary.opacity(0.06) : Color.clear))
                        )

                    Text(filter.rawValue)
                        .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(dynamicTextColor)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity)
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
