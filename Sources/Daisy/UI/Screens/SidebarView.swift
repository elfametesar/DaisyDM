import SwiftUI

struct SidebarView: View {
    @Binding var selected: SidebarFilter
    var engine: DownloadEngine
    let onSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selected) {
                Section("Library") {
                    ForEach(SidebarFilter.allCases) { filter in
                        SidebarRow(filter: filter, count: count(for: filter))
                            .tag(filter)
                    }
                }
            }
            .listStyle(.sidebar)

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
                    .foregroundStyle(.blue)
                }
            }
            .padding(12)
            .background(.ultraThinMaterial)
        }
    }

    private func count(for filter: SidebarFilter) -> Int {
        engine.items.filter { filter.matches($0) }.count
    }
}

struct SidebarRow: View {
    let filter: SidebarFilter
    let count: Int

    var body: some View {
        HStack {
            Label(filter.rawValue, systemImage: filter.icon)
            Spacer()
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.1), in: Capsule())
            }
        }
    }
}
