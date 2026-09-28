import Foundation

/// Holds the result of the latest async semantic/lexical retrieval.
/// The hot path reads it as a plain dictionary get: token → boost (log-space).
public final class PrefetchBuffer: @unchecked Sendable {
    private var boosts: [String: Double] = [:]
    private let lock = NSLock()

    public init() {}

    public func publish(_ newBoosts: [String: Double]) {
        lock.lock()
        boosts = newBoosts
        lock.unlock()
    }

    @inline(__always)
    public func boost(_ token: String) -> Double {
        lock.lock()
        defer { lock.unlock() }
        return boosts[token] ?? 0
    }

    public var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return boosts.isEmpty
    }
}

/// Debounced background retrieval — creativity point 3 of DPHM.
///
/// Retrieval is triggered by word boundaries / pauses (debounced, async),
/// never by keystrokes. The bet: typing speed (~200 ms/word) is far slower
/// than background retrieval (~ms), so results are almost always published
/// *before* the next keystroke reads them — like CPU speculative prefetching.
///
/// `retrieveFn` can be swapped for an embedding+ANN search or an LLM-profile
/// lookup; failures never surface on the hot path.
public final class SpeculativePrefetcher: @unchecked Sendable {
    private let buffer: PrefetchBuffer
    private let retrieveFn: @Sendable (String) -> [String: Double]
    private let debounceInterval: TimeInterval
    private let queue = DispatchQueue(label: "dphm.prefetch", qos: .utility)
    private var pending: DispatchWorkItem?
    private let lock = NSLock()

    public init(buffer: PrefetchBuffer,
                debounceInterval: TimeInterval = 0.15,
                retrieveFn: @escaping @Sendable (String) -> [String: Double]) {
        self.buffer = buffer
        self.debounceInterval = debounceInterval
        self.retrieveFn = retrieveFn
    }

    /// Call on word boundaries / pauses. Cheap: cancels + reschedules a work
    /// item; the freshest context wins (debounce).
    public func notify(contextText: String) {
        let work = DispatchWorkItem { [buffer, retrieveFn] in
            buffer.publish(retrieveFn(contextText))
        }
        lock.lock()
        pending?.cancel()
        pending = work
        lock.unlock()
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    /// Test hook: wait until any pending retrieval has been published.
    public func flush() {
        queue.sync(flags: .barrier) {}
        Thread.sleep(forTimeInterval: debounceInterval + 0.05)
        queue.sync(flags: .barrier) {}
    }
}
