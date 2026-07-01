import Foundation

/// Runs a *blocking* audio start (an AVAudioEngine / CoreAudio setup call that can wedge
/// if the audio system, e.g. `coreaudiod`, is stuck) on a background queue with a
/// timeout, so the caller (the main thread) never blocks and the UI can't freeze.
///
/// The returned bool says whether the start finished within `timeout`. Whoever finishes
/// first, the work or the timeout, wins; the continuation resumes exactly once. A start
/// that completes *after* the timeout is treated as abandoned and `undo` tears it back
/// down (so a late-succeeding start doesn't leave a recording running with no owner).
func startWithTimeout(on queue: DispatchQueue,
                      timeout: TimeInterval,
                      work: @escaping @Sendable () -> Bool,
                      undo: @escaping @Sendable () -> Void) async -> Bool {
    await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
        let gate = StartGate(continuation)
        queue.async {
            let started = work()
            // If the timeout already fired, this start was abandoned: undo it.
            if !gate.finish(started), started { undo() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            gate.finish(false)
        }
    }
}

/// Guards a one-shot resume of a continuation shared between the work and timeout paths.
private final class StartGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    /// Resume with `value`; returns true only for the call that actually resumed (so the
    /// loser can tell it lost the race).
    @discardableResult
    func finish(_ value: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let continuation else { return false }
        self.continuation = nil
        continuation.resume(returning: value)
        return true
    }
}
