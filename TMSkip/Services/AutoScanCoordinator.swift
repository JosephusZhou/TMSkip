import CoreServices
import Foundation

// MARK: - 纯决策逻辑（可注入时钟，供单元测试）

/// Stateless decision core for automatic scanning. Every time-dependent rule
/// takes `now` as a parameter instead of reading the clock directly, so the
/// throttle / catch-up / merge behaviour is fully testable.
enum AutoScanLogic {
    /// Whether the interval timer is a trigger source for this mode.
    static func usesTimer(_ mode: ScanTriggerMode) -> Bool {
        mode == .intervalOnly || mode == .intervalAndFSEvents
    }

    /// Whether the FSEvents stream is a trigger source for this mode.
    static func usesFSEvents(_ mode: ScanTriggerMode) -> Bool {
        mode == .fsEventsOnly || mode == .intervalAndFSEvents
    }

    /// Minimum-interval throttle gate (PLAN §2.1 合流节流). High-frequency
    /// `node_modules` writes must not trigger back-to-back scans even after the
    /// FSEvents debounce window.
    static func allowsScan(now: Date, lastScanAt: Date?, minInterval: TimeInterval) -> Bool {
        guard let lastScanAt else { return true }
        return now.timeIntervalSince(lastScanAt) >= minInterval
    }

    /// The minimum gap enforced between any two automatic scans, regardless of
    /// trigger source. The hard 5-minute floor (PLAN §2.1) prevents hammering;
    /// the user-configured interval is the cadence the user actually expects, so
    /// it must also throttle FSEvents-driven scans — otherwise "每天" would
    /// still rescan every few minutes whenever the home directory is active.
    static func effectiveMinInterval(
        minRescanInterval: TimeInterval,
        scanInterval: TimeInterval
    ) -> TimeInterval {
        max(minRescanInterval, scanInterval)
    }

    /// Seconds remaining until the next interval deadline. `0` means "due now"
    /// — covering both the never-scanned launch case and an overdue catch-up.
    static func secondsUntilDeadline(now: Date, lastScanAt: Date?, interval: TimeInterval) -> TimeInterval {
        guard let lastScanAt else { return 0 }
        return max(0, interval - now.timeIntervalSince(lastScanAt))
    }

    /// Merge fresh candidates into the pending queue, de-duplicating by path.
    /// Existing entries win: they may already carry a computed size / state.
    static func mergePending(existing: [ScanCandidate], incoming: [ScanCandidate]) -> [ScanCandidate] {
        var merged = existing
        var known = Set(existing.map(\.path))
        known.reserveCapacity(known.count + incoming.count)
        for candidate in incoming where !known.contains(candidate.path) {
            merged.append(candidate)
            known.insert(candidate.path)
        }
        return merged
    }

    /// Hits that already carry the TM exclusion marker on disk.
    static func alreadyExcluded(from hits: [ScanEngine.Hit]) -> [ScanEngine.Hit] {
        hits.filter { $0.alreadyExcluded == true }
    }

    /// Hits that still need an exclusion (not excluded, or state unknown).
    static func fresh(from hits: [ScanEngine.Hit]) -> [ScanEngine.Hit] {
        hits.filter { $0.alreadyExcluded != true }
    }
}

// MARK: - FSEvents 薄壳

/// Thin wrapper around a C `FSEventStream`. The stream is scheduled on a
/// background dispatch queue; every callback hops back to the MainActor via
/// the `@Sendable` onChange closure (PLAN §11: callback is never touched on
/// the stream queue itself).
final class FSEventsWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "app.tmskip.fsevents", qos: .utility)
    private var onChange: (@Sendable () -> Void)?
    private(set) var isRunning = false

    func start(paths: [String], latency: CFTimeInterval, onChange: @escaping @Sendable () -> Void) {
        stop()
        self.onChange = onChange

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, _, _, _, _ in
                guard let info else { return }
                Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue().fire()
            },
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            UInt32(kFSEventStreamCreateFlagNone)
        ) else {
            self.onChange = nil
            return
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        isRunning = true
    }

    func stop() {
        guard let stream else {
            isRunning = false
            return
        }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        onChange = nil
        isRunning = false
    }

    private func fire() {
        onChange?()
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}

// MARK: - Coordinator

/// Merges the interval timer and the FSEvents stream into one throttled
/// automatic-scan entry point. Owned by `AppModel`; never touches the manual
/// `scanPhase` state machine.
@MainActor
final class AutoScanCoordinator {
    enum Trigger: Equatable {
        case startup
        case interval
        case fsEvents
    }

    private weak var model: AppModel?
    private let watcher = FSEventsWatcher()

    private var timerTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?

    /// Anchor for interval scheduling; persisted copy lives in AppSettings.
    private(set) var lastScanAt: Date?
    /// Set when an automatic trigger arrived while a manual scan was busy;
    /// one catch-up scan runs once the manual task finishes (PRD §6.2).
    private var dirtyAfterManual = false
    private var isScanning = false

    /// PRD §6.4.1: same wave of filesystem changes is coalesced.
    let fsDebounce: TimeInterval = 30
    /// PLAN §2.1: hard floor between two automatic scans, whatever the source.
    let minRescanInterval: TimeInterval = 300
    /// Short delay before the first launch catch-up so startup stays responsive.
    let startupGrace: TimeInterval = 8

    init(model: AppModel) {
        self.model = model
        self.lastScanAt = model.settings.lastAutoScanAt
    }

    // MARK: Lifecycle (follows autoScanEnabled + triggerMode + FDA)

    /// (Re)build timer / stream from the current settings and FDA state.
    /// Safe to call on every relevant settings diff — it only restarts what
    /// actually needs restarting.
    func reconfigure() {
        guard let model else { return }
        let settings = model.settings
        let active = settings.autoScanEnabled && model.fdaService.isGranted

        guard active else {
            stopTimer()
            watcher.stop()
            return
        }

        if AutoScanLogic.usesTimer(settings.triggerMode) {
            startTimer(intervalMinutes: settings.scanInterval.rawValue)
        } else {
            stopTimer()
        }

        if AutoScanLogic.usesFSEvents(settings.triggerMode) {
            startWatcher()
        } else {
            watcher.stop()
        }
    }

    func stop() {
        stopTimer()
        watcher.stop()
    }

    private func stopTimer() {
        timerTask?.cancel()
        timerTask = nil
    }

    private func startTimer(intervalMinutes: Int) {
        let interval = TimeInterval(intervalMinutes) * 60
        // Don't restart if an equivalent timer loop is already running with the
        // same interval and nothing invalidated it.
        if let timerTask, !timerTask.isCancelled, currentInterval == interval { return }
        stopTimer()
        currentInterval = interval

        timerTask = Task { [weak self] in
            var isFirstIteration = true
            while !Task.isCancelled {
                guard let self else { return }
                let now = Date()
                var delay = AutoScanLogic.secondsUntilDeadline(
                    now: now,
                    lastScanAt: self.lastScanAt,
                    interval: interval
                )
                // First-iteration overdue / never-scanned launch catch-up:
                // logged as a startup scan, not an interval deadline hit.
                let isStartupCatchUp = isFirstIteration && delay <= 0
                if isStartupCatchUp {
                    // Never scanned / overdue: still give launch a brief grace.
                    delay = self.startupGrace
                }
                // 30s retry floor instead of 1s: when the scan is throttled or a
                // manual scan holds the slot, the loop would otherwise busy-spin.
                // The first iteration keeps its short (startupGrace) catch-up.
                let firstRun = isFirstIteration
                isFirstIteration = false
                let wait = UInt64(max(firstRun ? 1 : 30, delay) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: wait)
                if Task.isCancelled { return }
                self.requestScan(trigger: isStartupCatchUp ? .startup : .interval)
            }
        }
    }

    private var currentInterval: TimeInterval?

    private func startWatcher() {
        guard !watcher.isRunning else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        watcher.start(paths: [home], latency: fsDebounce) { [weak self] in
            // Stream callback runs on the watcher's queue — hop to MainActor.
            Task { @MainActor [weak self] in
                self?.requestScan(trigger: .fsEvents)
            }
        }
    }

    // MARK: Unified entry

    func requestScan(trigger: Trigger) {
        guard let model else { return }
        let settings = model.settings
        guard settings.autoScanEnabled, model.fdaService.isGranted else { return }

        // PRD §6.2 manual priority: never preempt a running manual scan/apply.
        if model.isManualScanBusy {
            dirtyAfterManual = true
            return
        }

        // The configured interval throttles *every* trigger source (timer,
        // FSEvents, catch-up). Without it, FSEvents would bypass a "每天"
        // interval and rescan every few minutes of file activity.
        let interval = TimeInterval(settings.scanInterval.rawValue) * 60
        let effectiveMin = AutoScanLogic.effectiveMinInterval(
            minRescanInterval: minRescanInterval,
            scanInterval: interval
        )
        guard AutoScanLogic.allowsScan(
            now: Date(),
            lastScanAt: lastScanAt,
            minInterval: effectiveMin
        ) else {
            return
        }

        performScan(trigger: trigger)
    }

    /// Called by AppModel whenever a manual scan/apply leaves its busy state.
    func noteManualScanFinished() {
        guard dirtyAfterManual else { return }
        dirtyAfterManual = false
        requestScan(trigger: .startup)
    }

    private func performScan(trigger: Trigger) {
        guard !isScanning, let model else { return }
        isScanning = true
        model.setAutoScanning(true)
        // Open the auto-scan log session; finished/cancelled is written by
        // AppModel.routeAutoScanResults (or the catch-up path).
        model.beginAutoScanLog(trigger: trigger)

        let startedAt = Date()
        lastScanAt = startedAt
        // Persist the anchor so a relaunch can catch up a missed interval.
        model.setLastAutoScanAt(startedAt)

        scanTask?.cancel()
        scanTask = Task { [weak self] in
            let hits = await model.runBackgroundScan()
            await MainActor.run {
                guard let self else { return }
                self.isScanning = false
                model.setAutoScanning(false)
                self.lastScanAt = model.settings.lastAutoScanAt ?? startedAt
                model.routeAutoScanResults(hits)
            }
        }
    }
}
