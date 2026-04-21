import Foundation

enum HLSBridge {
    typealias Closure = (Int32, Int32, Int64, Double, Double, Double) -> Void

    private static let lock = NSLock()
    private static var registry: [UUID: Closure] = [:]
    private static var currentID: UUID?

    static func register(id: UUID, closure: @escaping Closure) {
        lock.lock(); defer { lock.unlock() }
        registry[id] = closure
        currentID    = id
    }

    static func unregister(id: UUID) {
        lock.lock(); defer { lock.unlock() }
        registry.removeValue(forKey: id)
        if currentID == id { currentID = nil }
    }

    static func dispatch(done: Int32, total: Int32, bytes: Int64, speed: Double, dlSeconds: Double, totalSeconds: Double) {
        lock.lock()
        let closure = currentID.flatMap { registry[$0] }
        lock.unlock()
        closure?(done, total, bytes, speed, dlSeconds, totalSeconds)
    }
}
