import Foundation

/// Async directory size estimation with bounded concurrency and cancellation.
/// Callers may enqueue one task per candidate; the actor hands out at most
/// `maxConcurrent` walk slots, so a large scan cannot hammer the disk with
/// hundreds of simultaneous directory traversals.
actor DirectorySizeService {
    private let maxConcurrent: Int
    private let timeoutNanoseconds: UInt64
    private var inFlight = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(maxConcurrent: Int = 3, timeoutSeconds: Double = 20) {
        self.maxConcurrent = max(1, maxConcurrent)
        self.timeoutNanoseconds = UInt64(timeoutSeconds * 1_000_000_000)
    }

    func size(of path: String) async -> (Int64?, SizeComputeState) {
        await acquireSlot()
        defer { releaseSlot() }
        guard !Task.isCancelled else { return (nil, .unavailable) }

        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)

        return await withTaskGroup(of: (Int64?, SizeComputeState).self) { group in
            group.addTask {
                await Self.walkDirectory(url: url)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: self.timeoutNanoseconds)
                return (nil, .timedOut)
            }
            // First finished wins; cancel the other.
            if let first = await group.next() {
                group.cancelAll()
                if first.1 == .timedOut {
                    // Prefer partial if compute already finished; otherwise timed out.
                    if let second = await group.next(), second.1 == .ready {
                        return second
                    }
                    return first
                }
                return first
            }
            return (nil, .unavailable)
        }
    }

    /// Suspends until a walk slot is free. `releaseSlot` transfers the slot
    /// directly to the next waiter, so `inFlight` only ever counts running
    /// walks; all bookkeeping stays in synchronous actor-isolated sections,
    /// which keeps it correct under actor reentrancy.
    private func acquireSlot() async {
        if inFlight < maxConcurrent {
            inFlight += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func releaseSlot() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            inFlight -= 1
        }
    }

    /// `nonisolated` so concurrent walks execute on the concurrent executor
    /// instead of serializing on (and blocking) the actor itself.
    private nonisolated static func walkDirectory(url: URL) async -> (Int64?, SizeComputeState) {
        var total: Int64 = 0
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return (nil, .unavailable)
        }

        while let item = enumerator.nextObject() as? URL {
            if Task.isCancelled { return (total, .timedOut) }
            do {
                let values = try item.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true { continue }
                if values.isRegularFile == true {
                    total += Int64(values.fileSize ?? 0)
                }
            } catch {
                continue
            }
        }
        return (total, .ready)
    }
}
