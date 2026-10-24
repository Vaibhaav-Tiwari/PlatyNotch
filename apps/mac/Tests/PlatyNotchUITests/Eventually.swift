import Foundation

/// Polls `condition` on the main actor until it holds or `timeout` passes (C11: no fixed
/// sleeps that a slow CI machine can outrun). Returns whether it held.
@MainActor
func eventually(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

/// Waits until everything already queued on the main dispatch queue has run (FIFO).
func drainMainQueue() async {
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        DispatchQueue.main.async { c.resume() }
    }
}
