import Foundation
import CoreGraphics

/// Separate passive status reads from the single explicit request allowed per
/// process. A rejected ScreenCaptureKit session stays blocked until an explicit
/// action/relaunch, even if Core Graphics returns a stale positive status.
final class SourceAuthorization {
    static let shared = SourceAuthorization()
    private let lock = NSLock()
    private var requested = false
    private var rejected = false
    private let preflight: () -> Bool
    private let requestAccess: () -> Bool
    init(preflight: @escaping () -> Bool = CGPreflightScreenCaptureAccess,
         request: @escaping () -> Bool = CGRequestScreenCaptureAccess) {
        self.preflight = preflight; self.requestAccess = request
    }
    var canList: Bool { lock.lock(); defer { lock.unlock() }; return !rejected && preflight() }
    func setConfirmed(_ value: Bool) { lock.lock(); rejected = !value; lock.unlock() }
    var status: [String: Any] {
        lock.lock(); defer { lock.unlock() }
        let granted = preflight()
        return ["screen":granted && !rejected, "canRequest":!requested && !granted && !rejected,
                "needsRestart":rejected && granted]
    }
    @MainActor func requestOnce() -> Bool {
        _ = CGMainDisplayID()
        lock.lock()
        if preflight() { rejected = false; lock.unlock(); return true }
        guard !requested else { lock.unlock(); return false }
        requested = true
        lock.unlock()
        let granted = requestAccess()
        lock.lock(); rejected = !granted; lock.unlock()
        return granted
    }
}
