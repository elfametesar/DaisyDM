import SwiftUI

struct RemoveDialog: View {
    let items: [DownloadItem]
    let onConfirm: (Bool, Bool) -> Void
    let onCancel: () -> Void

    @AppStorage("accentColorHex") private var accentColorHex = "#0A84FF"
    
    @State private var trashFile: Bool
    @State private var remember = false

    init(items: [DownloadItem], onConfirm: @escaping (Bool, Bool) -> Void, onCancel: @escaping () -> Void) {
        self.items = items
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        
        // Guarantees the toggle matches the settings the exact millisecond the view is created
        let defaultAction = UserDefaults.standard.string(forKey: "defaultRemoveAction") ?? "keep"
        _trashFile = State(initialValue: defaultAction == "trash")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            
            // ── Header ──
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(hex: accentColorHex).opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: "trash.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Color(hex: accentColorHex))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(items.count > 1 ? "Remove \(items.count) Downloads?" : "Remove Download?")
                        .font(.title3.weight(.semibold))
                    Text("Are you sure you want to remove \(items.count > 1 ? "these items" : "this item") from your list?")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)

            Divider()

            // ── Content ──
            VStack(alignment: .leading, spacing: 14) {
                Toggle("Move downloaded file(s) to Trash", isOn: $trashFile)
                    .toggleStyle(.checkbox)
                    .font(.callout)
                
                Toggle("Never ask for confirmation again", isOn: $remember)
                    .toggleStyle(.checkbox)
                    .font(.callout)
            }
            .padding(20)

            Divider()

            // ── Actions ──
            HStack {
                Spacer()
                
                Button(action: onCancel) {
                    Label("Cancel", systemImage: "xmark")
                }
                .buttonStyle(ActionButtonStyle(prominent: false, hex: accentColorHex))
                .keyboardShortcut(.cancelAction) // Fixes the Escape key issue natively
                
                Button(action: { onConfirm(trashFile, remember) }) {
                    Label("Remove", systemImage: "trash")
                }
                .buttonStyle(ActionButtonStyle(prominent: true, hex: accentColorHex))
                .keyboardShortcut(.defaultAction) // Enter key triggers this automatically
            }
            .padding(16)
        }
        .frame(width: 440)
        .background(Color(NSColor.windowBackgroundColor))
    }
}
