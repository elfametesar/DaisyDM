import SwiftUI

struct RemoveDialog: View {
    let items: [DownloadItem]
    let onConfirm: (Bool, Bool) -> Void
    let onCancel: () -> Void

    @State private var trashFile = false
    @State private var remember  = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(items.count > 1 ? "Remove \(items.count) Downloads?" : "Remove Download?")
                .font(.headline)

            Text("Are you sure you want to remove \(items.count > 1 ? "these items" : "this item") from your list?")
                .font(.callout)

            VStack(alignment: .leading, spacing: 10) {
                Toggle("Move downloaded file(s) to Trash", isOn: $trashFile)
                Toggle("Remember my choice", isOn: $remember)
            }
            .padding(.vertical, 4)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.escape)
                Button("Remove") { onConfirm(trashFile, remember) }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
