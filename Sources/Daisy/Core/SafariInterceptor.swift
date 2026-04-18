import Foundation
import CoreServices
import AppKit

class SafariInterceptor {
    static let shared = SafariInterceptor()
    
    private var stream: FSEventStreamRef?
    private let downloadsPath = (NSSearchPathForDirectoriesInDomains(.downloadsDirectory, .userDomainMask, true).first! as NSString).resolvingSymlinksInPath
    
    private var recentlyIntercepted = [String: Date]()
    private let interceptCooldown: TimeInterval = 30
    private let queue = DispatchQueue(label: "com.daisy.safariInterceptor", qos: .background)
    
    // Synced from extension via LocalServer /setenabled
    var isEnabled: Bool = true
    
    // Paths we've tombstoned — we recreate a blocking file so Safari can't resume
    private var tombstonedPaths = Set<String>()
    
    func start() {
        let pathsToWatch = [downloadsPath] as CFArray
        
        var context = FSEventStreamContext(
            version: 0,
            info: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        
        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            eventCallback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            flags
        )
        
        if let stream = stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
            print("✅ Safari Interceptor started watching: \(downloadsPath)")
        }
    }
    
    func stop() {
        if let stream = stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            self.stream = nil
        }
        // Clean up any tombstone files we left
        for path in tombstonedPaths {
            try? FileManager.default.removeItem(atPath: path)
        }
        tombstonedPaths.removeAll()
    }
    
    func handleEvent(at path: String) {
        guard isEnabled else { return }
        guard path.hasSuffix(".download") else { return }
        
        // If this is a path we tombstoned, keep nuking it
        if tombstonedPaths.contains(path) {
            nukeSafariDownload(at: path, tombstone: false)
            return
        }
        
        usleep(250_000)
        
        guard let whereFroms = getWhereFroms(filePath: path),
              let sourceURLString = whereFroms.first,
              let url = URL(string: sourceURLString) else {
            return
        }
        
        let now = Date()
        if let lastTime = recentlyIntercepted[sourceURLString], now.timeIntervalSince(lastTime) < interceptCooldown {
            print("⏭ Re-appeared after intercept, nuking: \(path)")
            nukeSafariDownload(at: path, tombstone: false)
            return
        }
        recentlyIntercepted[sourceURLString] = now
        
        print("🎯 Intercepted Safari Download: \(url)")
        
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            
            let filename = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            
            NotificationCenter.default.post(
                name: .confirmDownload,
                object: nil,
                userInfo: [
                    "url": url,
                    "filename": filename
                ]
            )
            
            // Nuke with tombstone to prevent Safari from recreating the bundle
            self.nukeSafariDownload(at: path, tombstone: true)
        }
    }
    
    /// Deletes the .download bundle. If tombstone=true, leaves a regular file
    /// at the same path so Safari's download manager can't recreate the directory.
    private func nukeSafariDownload(at path: String, tombstone: Bool) {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: path)
        
        // Delete existing bundle
        if fm.fileExists(atPath: path) {
            do {
                try fm.removeItem(at: url)
                print("🗑 Deleted: \(path)")
            } catch {
                print("⚠️ Delete failed: \(error)")
                return
            }
        }
        
        guard tombstone else { return }
        
        // Write a zero-byte regular file at the .download path.
        // Safari expects a directory (bundle) here — finding a plain file
        // will cause it to error out and stop the download rather than resume.
        do {
            try Data().write(to: url)
            tombstonedPaths.insert(path)
            print("🪦 Tombstone placed at: \(path)")
            
            // Remove tombstone after 60s — by then Safari has given up
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
                self.tombstonedPaths.remove(path)
                try? fm.removeItem(at: url)
                print("🧹 Tombstone removed: \(path)")
            }
        } catch {
            print("⚠️ Tombstone write failed: \(error)")
        }
    }
    
    private func getWhereFroms(filePath: String) -> [String]? {
        let name = "com.apple.metadata:kMDItemWhereFroms"
        return filePath.withCString { pathPtr in
            let size = getxattr(pathPtr, name, nil, 0, 0, 0)
            guard size > 0 else { return nil }
            
            var buffer = [UInt8](repeating: 0, count: size)
            let readSize = getxattr(pathPtr, name, &buffer, size, 0, 0)
            guard readSize == size else { return nil }
            
            let data = Data(buffer)
            return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String]
        }
    }
}

private let eventCallback: FSEventStreamCallback = { (
    streamRef: ConstFSEventStreamRef,
    clientCallBackInfo: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    eventIds: UnsafePointer<FSEventStreamEventId>
) in
    guard let info = clientCallBackInfo else { return }
    let interceptor = Unmanaged<SafariInterceptor>.fromOpaque(info).takeUnretainedValue()
    let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as! [String]
    
    for i in 0..<numEvents {
        let path = paths[i]
        let flags = eventFlags[i]
        
        let isModified = (flags & UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemModified)) != 0
        
        if isModified {
            interceptor.handleEvent(at: path)
        }
    }
}
