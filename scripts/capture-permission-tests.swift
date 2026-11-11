import Foundation

@main struct PermissionTests {
    @MainActor static func main() {
        var granted = false
        var prompts = 0
        let gate = SourceAuthorization(preflight: { granted }, request: { prompts += 1; return false })
        for _ in 0..<20 { _ = gate.status; _ = gate.canList }
        assert(prompts == 0, "Passive status checks must never request permission")
        assert(gate.status["canRequest"] as? Bool == true)
        assert(!gate.requestOnce())
        for _ in 0..<20 { assert(!gate.requestOnce()); _ = gate.status }
        assert(prompts == 1, "A denied permission must not produce repeated dialogs")
        assert(gate.status["canRequest"] as? Bool == false)
        granted = true
        assert(!gate.canList, "A stale positive preflight must not override a rejected capture session")
        assert(gate.status["needsRestart"] as? Bool == true)
        assert(gate.requestOnce(), "An explicit retry can accept updated OS authorization")
        assert(gate.canList)
        gate.setConfirmed(false)
        for _ in 0..<20 { assert(!gate.canList); _ = gate.status }
        assert(prompts == 1)
        print("Permission policy passed: passive checks never prompt, denied requests prompt at most once, and rejected sessions stay blocked.")
    }
}
