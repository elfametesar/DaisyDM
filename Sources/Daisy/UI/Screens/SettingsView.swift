import SwiftUI

struct SettingsView: View {
    @AppStorage("fileCollisionBehavior") private var collisionBehavior = "rename"
    @AppStorage("removeBehavior") private var removeBehavior = "ask"
    @AppStorage("maxConcurrentDownloads") private var maxConcurrent = 5

    var body: some View {
        Form {
            Picker("File Collision:", selection: $collisionBehavior) {
                Text("Rename (Create Duplicate)").tag("rename")
                Text("Replace Existing File").tag("replace")
            }
            .pickerStyle(.radioGroup)
            
            Picker("When Removing:", selection: $removeBehavior) {
                Text("Ask Every Time").tag("ask")
                Text("Move File to Trash").tag("trash")
                Text("Remove from List Only").tag("keep")
            }
            .pickerStyle(.radioGroup)
            
            Stepper("Max Concurrent Downloads: \(maxConcurrent)", value: $maxConcurrent, in: 1...20)
        }
        .padding(20)
        .frame(width: 400, height: 200)
    }
}
