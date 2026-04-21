import Foundation

func formatBytes(_ bytes: Int64) -> String {
    guard bytes > 0 else { return "0 B" }
    let units = ["B", "KB", "MB", "GB", "TB"]
    var v = Double(bytes), u = 0
    while v >= 1024, u < units.count - 1 { v /= 1024; u += 1 }
    return String(format: v >= 100 ? "%.0f %@" : "%.1f %@", v, units[u])
}

func formatDuration(_ seconds: Double) -> String {
    guard seconds > 0 else { return "00:00" }
    let totalSeconds = Int(seconds.rounded())
    let hours = totalSeconds / 3600
    let minutes = (totalSeconds % 3600) / 60
    let secs = totalSeconds % 60
    
    if hours > 0 {
        return String(format: "%02d:%02d:%02d", hours, minutes, secs)
    } else {
        return String(format: "%02d:%02d", minutes, secs)
    }
}
