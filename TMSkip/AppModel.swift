import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    // MARK: - Stores
    let settingsStore = SettingsStore()
    let ignoreStore = IgnoreStore()
    let fdaService = FullDiskAccessService()
    private let sizeService = DirectorySizeService()

    // MARK: - Background services (PLAN-AutoScan)
    let notificationService = NotificationService()
    let loginItemService = LoginItemService()
    let windowRouter = WindowRouter()
    let scanLog = ScanLogService()
    private(set) var autoCoordinator: AutoScanCoordinator?

    /// 当前扫描会话 id（手动/自动共用，互斥保证不会重叠），用于日志关联。
    private var currentScanId: UUID?

    // MARK: - Navigation / shell
    @Published var selectedSidebar: SidebarItem = .manualScan
    @Published var showOnboarding: Bool = false
    @Published var pendingReview: Bool = false

    // MARK: - Manual scan session
    @Published var scanPhase: ScanPhase = .idle
    @Published var scanProgress = ScanProgress()
    @Published var candidates: [ScanCandidate] = []
    @Published var lastOutcome = ScanOutcome()
    @Published var applyCurrentPath: String = ""
    @Published var statusMessage: String?

    // MARK: - Automatic scan state
    /// New candidates found by automatic scans, awaiting user promotion.
    @Published private(set) var autoPendingCandidates: [ScanCandidate] = []
    /// Whether a background automatic scan is currently walking the disk.
    @Published private(set) var isAutoScanning: Bool = false
    /// Last login-item sync failure (shown next to the launch-at-login toggle).
    @Published var loginItemError: String?

    private var scanTask: Task<Void, Never>?
    private var applyTask: Task<Void, Never>?
    private var sizeTasks: [UUID: Task<Void, Never>] = [:]
    private var ruleSyncTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var settingsSnapshot: SettingsSnapshot?
    private var didBootstrap = false

    private let onboardKey = "tmskip.onboarding.done"

    init() {
        fdaService.refresh()
        let onboardDone = UserDefaults.standard.bool(forKey: onboardKey)
        showOnboarding = !onboardDone || !fdaService.isGranted

        // UN delegate must exist before launch finishes (click callbacks are
        // dropped otherwise), so install it here in @main App.init.
        notificationService.install()

        // Keep settings object changes bubbling for views that observe AppModel only.
        settingsStore.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        ignoreStore.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        fdaService.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Field-level settings diff → reconfigure only the affected service.
        settingsStore.$settings
            .dropFirst()
            .sink { [weak self] newValue in self?.handleSettingsChange(newValue) }
            .store(in: &cancellables)

        // Notification tap → open the manual-scan page and promote the queue.
        notificationService.onOpenPending = { [weak self] in
            guard let self else { return }
            self.openMainWindow(to: .manualScan)
            self.promoteAutoPending()
        }
        notificationService.onAuthorizationDenied = { [weak self] in
            self?.flash("通知未授权，仍保留菜单栏点标与 App 内待处理")
        }

        // Dock-icon / system reopen event → restore the main window in-process.
        // `WindowRouter` holds the not-yet-bound fallback, so this also works
        // when the scene has not appeared yet (e.g. login-item launch).
        NotificationCenter.default
            .publisher(for: .tmskipRequestOpenMainWindow)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.openMainWindow() }
            .store(in: &cancellables)

        autoCoordinator = AutoScanCoordinator(model: self)
        bootstrapBackgroundServices()
    }

    /// Snapshot of the scan-related settings fields that drive reconfiguration.
    private struct SettingsSnapshot: Equatable {
        var autoScanEnabled: Bool
        var scanInterval: ScanInterval
        var triggerMode: ScanTriggerMode
        var launchAtLogin: Bool
        var applyPolicy: ApplyPolicy
        var notificationsEnabled: Bool
        var autoRuleSync: Bool

        init(_ s: AppSettings) {
            autoScanEnabled = s.autoScanEnabled
            scanInterval = s.scanInterval
            triggerMode = s.triggerMode
            launchAtLogin = s.launchAtLogin
            applyPolicy = s.applyPolicy
            notificationsEnabled = s.notificationsEnabled
            autoRuleSync = s.autoRuleSync
        }
    }

    /// Initial bring-up of all background services after `init`.
    private func bootstrapBackgroundServices() {
        syncLoginItem(notifyOnError: false)
        autoCoordinator?.reconfigure()
        scheduleRuleAutoSync()
        settingsSnapshot = SettingsSnapshot(settings)
        didBootstrap = true
    }

    /// Diff the new settings against the last snapshot and reconfigure only
    /// the service whose field actually changed (PLAN §7).
    private func handleSettingsChange(_ newSettings: AppSettings) {
        let old = settingsSnapshot ?? SettingsSnapshot(newSettings)
        let next = SettingsSnapshot(newSettings)
        settingsSnapshot = next
        guard didBootstrap else { return }

        if old.autoScanEnabled != next.autoScanEnabled
            || old.scanInterval != next.scanInterval
            || old.triggerMode != next.triggerMode {
            autoCoordinator?.reconfigure()
        }
        if old.launchAtLogin != next.launchAtLogin {
            syncLoginItem(notifyOnError: true)
        }
        if old.autoRuleSync != next.autoRuleSync {
            scheduleRuleAutoSync()
        }
        // applyPolicy / notificationsEnabled are read at routing/notify time,
        // so they need no service reconfiguration.
    }

    private func syncLoginItem(notifyOnError: Bool) {
        do {
            try loginItemService.setEnabled(settings.launchAtLogin)
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
            if notifyOnError { flash("登录项设置失败：\(error.localizedDescription)") }
        }
    }

    var settings: AppSettings { settingsStore.settings }
    var homeDisplayPath: String {
        settings.roots.first?.path ?? "~"
    }

    // MARK: - Onboarding / FDA

    func openFullDiskAccessSettings() {
        fdaService.openSystemSettings()
    }

    func recheckFullDiskAccess() {
        fdaService.refresh()
        if fdaService.isGranted {
            flash("权限检测通过")
            autoCoordinator?.reconfigure()
        } else {
            flash("仍未检测到完全磁盘访问，请确认已勾选 TMSkip")
            autoCoordinator?.reconfigure()
        }
    }

    func finishOnboarding() {
        guard fdaService.isGranted else {
            flash("请先完成全盘访问授权")
            return
        }
        UserDefaults.standard.set(true, forKey: onboardKey)
        showOnboarding = false
        // FDA is now granted — automatic scanning may start for the first time.
        autoCoordinator?.reconfigure()
    }

    func showOnboardingAgain() {
        showOnboarding = true
    }

    // MARK: - Window

    func openMainWindow(to item: SidebarItem? = nil) {
        dismissMenuBarPanel()
        windowRouter.openMainWindow { [weak self] in
            if let item { self?.selectedSidebar = item }
        }
    }

    /// 收起菜单栏弹出面板。SwiftUI 的 `.menuBarExtraStyle(.window)` 面板
    /// （底层为 NSPopover / panel 级窗口）在点击其中按钮后不会像 `.menu`
    /// 样式那样自动关闭，打开主窗口前需显式收起。
    /// 只关闭可见且层级高于 normal 的窗口，主窗口（.normal）不受影响。
    private func dismissMenuBarPanel() {
        for window in NSApp.windows {
            guard window.isVisible,
                  window.level.rawValue > NSWindow.Level.normal.rawValue
            else { continue }
            if let popover = window as? NSPopover {
                popover.performClose(nil)
            } else {
                window.orderOut(nil)
            }
        }
    }

    // MARK: - Scan

    func startManualScan() {
        guard fdaService.isGranted else {
            showOnboarding = true
            flash("请先授予全盘访问权限")
            return
        }
        cancelManualScan()
        candidates = []
        scanProgress = ScanProgress()
        scanPhase = .running
        pendingReview = false
        currentScanId = scanLog.begin(kind: .manual, trigger: .userInitiated)

        let config = makeScanConfiguration()
        let engine = ScanEngine()

        let model = self
        scanTask = Task.detached(priority: .userInitiated) {
            let hits = engine.scan(
                config: config,
                progress: { progress in
                    Task { @MainActor in
                        model.scanProgress = progress
                    }
                },
                isCancelled: { Task.isCancelled }
            )

            await MainActor.run {
                guard !Task.isCancelled else { return }
                model.candidates = hits.map(Self.makeCandidate)
                // Surface historical exclusions in Ignore List for management.
                let already = model.candidates.filter { $0.exclusionState == .alreadyExcluded }
                if !already.isEmpty {
                    model.ignoreStore.upsertExcluded(
                        paths: already.map { ($0.path, $0.ruleName, $0.byteSize) },
                        source: .unknown
                    )
                }
                let needCount = model.candidates.filter(\.needsExclude).count
                let alreadyCount = already.count
                model.scanProgress.found = hits.count
                model.scanProgress.fraction = 1
                model.scanPhase = .result
                model.pendingReview = needCount > 0
                // 手动扫描结束日志（currentScanId 保留给后续 apply 关联）。
                if let scanId = model.currentScanId {
                    model.scanLog.finish(
                        scanId: scanId,
                        foundCount: hits.count,
                        alreadyExcludedCount: alreadyCount,
                        pendingCount: needCount
                    )
                }
                if hits.isEmpty {
                    model.flash("扫描完成：未发现可排除项")
                } else if needCount == 0 {
                    model.flash("扫描完成：\(alreadyCount) 项此前已排除（含 tmexclude 等），无需重复应用")
                } else {
                    model.flash("扫描完成：\(needCount) 项待排除，\(alreadyCount) 项已排除")
                }
                model.enqueueSizeComputation(for: model.candidates.map(\.id))
                // Manual scan finished: a deferred automatic scan may now run.
                model.autoCoordinator?.noteManualScanFinished()
            }
        }
    }

    /// Shared scan configuration for manual and automatic scans, so skip paths
    /// and enabled rules apply identically to both (PRD §6.4 验收).
    private func makeScanConfiguration() -> ScanEngine.Configuration {
        ScanEngine.Configuration(
            roots: settings.roots.map(\.path),
            skipPaths: settings.skipPaths,
            rules: activeRulePackage.rules
        )
    }

    /// Background scan used by AutoScanCoordinator: reuses ScanEngine but
    /// discards progress callbacks and never touches the manual `scanPhase`.
    func runBackgroundScan() async -> [ScanEngine.Hit] {
        let config = makeScanConfiguration()
        let engine = ScanEngine()
        return await Task.detached(priority: .utility) {
            engine.scan(config: config, progress: { _ in }, isCancelled: { Task.isCancelled })
        }.value
    }

    /// Map an engine hit to a UI candidate (shared by manual and auto flows).
    static func makeCandidate(from hit: ScanEngine.Hit) -> ScanCandidate {
        let state: ExistingExclusionState
        switch hit.alreadyExcluded {
        case .some(true): state = .alreadyExcluded
        case .some(false): state = .notExcluded
        case .none: state = .unknown
        }
        // Already excluded (tmexclude/asimov/manual) → show but don't auto-select.
        return ScanCandidate(
            path: hit.displayPath,
            ruleName: hit.ruleName,
            byteSize: nil,
            sizeState: .pending,
            exclusionState: state,
            isSelected: state != .alreadyExcluded
        )
    }

    /// PRD §6.2: a manual scan/apply owns the one scan slot while busy.
    var isManualScanBusy: Bool {
        scanPhase == .running || scanPhase == .applying
    }

    func cancelManualScan() {
        scanTask?.cancel()
        scanTask = nil
        sizeTasks.values.forEach { $0.cancel() }
        sizeTasks.removeAll()
        if scanPhase == .running {
            if let scanId = currentScanId {
                scanLog.cancel(scanId: scanId, reason: "userCancel")
                currentScanId = nil
            }
            scanPhase = .idle
            flash("已取消扫描")
        }
        autoCoordinator?.noteManualScanFinished()
    }

    func discardResults() {
        sizeTasks.values.forEach { $0.cancel() }
        sizeTasks.removeAll()
        candidates = []
        scanPhase = .idle
        // Badge persists if the automatic queue still holds unreviewed items.
        pendingReview = !autoPendingCandidates.isEmpty
        flash("已丢弃扫描结果")
    }

    func toggleCandidate(id: UUID, selected: Bool) {
        guard let idx = candidates.firstIndex(where: { $0.id == id }) else { return }
        candidates[idx].isSelected = selected
    }

    func setAllCandidatesSelected(_ selected: Bool) {
        // Only toggle items that still need exclusion (already-excluded stay unselected).
        for i in candidates.indices where candidates[i].needsExclude {
            candidates[i].isSelected = selected
        }
    }

    var selectedCandidates: [ScanCandidate] {
        candidates.filter(\.isSelected)
    }

    var selectedBytes: Int64 {
        selectedCandidates.compactMap(\.byteSize).reduce(0, +)
    }

    var allCandidateBytes: Int64 {
        candidates.compactMap(\.byteSize).reduce(0, +)
    }

    var newExcludeCandidates: [ScanCandidate] {
        candidates.filter { $0.exclusionState != .alreadyExcluded }
    }

    var alreadyExcludedCandidates: [ScanCandidate] {
        candidates.filter { $0.exclusionState == .alreadyExcluded }
    }

    var newExcludeBytes: Int64 {
        newExcludeCandidates.compactMap(\.byteSize).reduce(0, +)
    }

    var alreadyExcludedBytes: Int64 {
        alreadyExcludedCandidates.compactMap(\.byteSize).reduce(0, +)
    }

    func applySelected() {
        let selected = selectedCandidates.filter(\.needsExclude)
        let skippedAlready = selectedCandidates.filter { $0.exclusionState == .alreadyExcluded }.count
        guard !selected.isEmpty else {
            if skippedAlready > 0 {
                flash("所选路径均已排除，无需重复应用")
            } else {
                flash("请至少选择一项未排除路径")
            }
            return
        }
        // Never write inside other applications' bundles (guarded by the system
        // App Management permission); report them instead of failing silently.
        let bundleBlocked = selected.filter { Self.pathTouchesAppBundle($0.path) }
        let toApply = selected.filter { !Self.pathTouchesAppBundle($0.path) }
        guard !toApply.isEmpty else {
            flash("所选路径均位于其他应用包内，已按规则跳过，未写入任何标记")
            return
        }
        applyTask?.cancel()
        scanPhase = .applying

        applyTask = Task { [weak self] in
            guard let self else { return }
            // no-re-include: this path only ever writes setExcluded(true).
            let outcome = await self.applyExclusions(
                items: selected,
                source: .manualScan,
                updateVisibleCandidates: true
            )
            self.lastOutcome = outcome
            self.pendingReview = !self.autoPendingCandidates.isEmpty
            self.scanPhase = .done
            self.scanLog.logApply(
                scanId: self.currentScanId,
                source: .manualScan,
                appliedCount: outcome.excludedCount,
                failedCount: outcome.failedCount,
                permissionBlocked: outcome.permissionBlocked,
                appBundleBlockedCount: outcome.appBundleBlockedPaths.count
            )
            if outcome.failedPaths.isEmpty {
                self.flash(bundleBlocked.isEmpty
                    ? "已写入 Time Machine 排除标记"
                    : "已写入排除标记；\(bundleBlocked.count) 项位于其他应用包内已跳过")
            } else if outcome.permissionBlocked {
                self.flash("完成：成功 \(outcome.excludedCount)，\(outcome.failedPaths.count) 项被系统权限拦截（详见完成页）")
            } else {
                self.flash("完成：成功 \(outcome.excludedCount)，失败 \(outcome.failedPaths.count)")
            }
            // Manual apply finished: a deferred automatic scan may now run.
            self.autoCoordinator?.noteManualScanFinished()
        }
    }

    /// Shared exclusion writer for manual and automatic flows. It only ever
    /// writes `setExcluded(true)` — this is the concrete no-re-include guarantee
    /// (PLAN §2.3): automatic scans never clear an existing exclusion.
    /// - Parameters:
    ///   - updateVisibleCandidates: refresh states of rows shown on the manual
    ///     result page; automatic items are usually not in `candidates`.
    @discardableResult
    func applyExclusions(
        items: [ScanCandidate],
        source: IgnoreSource,
        updateVisibleCandidates: Bool
    ) async -> ScanOutcome {
        let targets = items.filter(\.needsExclude)
        let bundleBlocked = targets.filter { Self.pathTouchesAppBundle($0.path) }
        let toApply = targets.filter { !Self.pathTouchesAppBundle($0.path) }

        var ok: [(path: String, ruleName: String?, bytes: Int64?)] = []
        var failedPaths: [String] = []
        var permissionBlocked = false

        for item in toApply {
            if Task.isCancelled { break }
            applyCurrentPath = item.path
            let absolute = (item.path as NSString).expandingTildeInPath
            do {
                try TimeMachineExclusionService.setExcluded(true, at: absolute)
                ok.append((item.path, item.ruleName, item.byteSize))
            } catch {
                let permission = Self.isPermissionDeniedError(error)
                permissionBlocked = permissionBlocked || permission
                failedPaths.append(item.path)
            }
            // Small yield so UI can refresh path line
            try? await Task.sleep(nanoseconds: 30_000_000)
        }

        ignoreStore.upsertExcluded(paths: ok, source: source)

        if updateVisibleCandidates {
            let okPaths = Set(ok.map(\.path))
            for i in candidates.indices where okPaths.contains(candidates[i].path) {
                candidates[i].exclusionState = .alreadyExcluded
                candidates[i].isSelected = false
            }
        }

        return ScanOutcome(
            excludedCount: ok.count,
            excludedBytes: ok.compactMap(\.bytes).reduce(0, +),
            failedCount: failedPaths.count,
            failedPaths: failedPaths,
            permissionBlocked: permissionBlocked,
            appBundleBlockedPaths: bundleBlocked.map(\.path)
        )
    }

    /// True when the path is (or lives inside) an application bundle. Writes
    /// there are guarded by the system App Management permission, so we avoid
    /// them entirely: other apps' bundles are not regenerable directories.
    static func pathTouchesAppBundle(_ path: String) -> Bool {
        let expanded = (path as NSString).expandingTildeInPath
        return expanded.split(separator: "/").contains { $0.lowercased().hasSuffix(".app") }
    }

    private static func isPermissionDeniedError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain,
           ns.code == NSFileWriteNoPermissionError || ns.code == NSFileReadNoPermissionError {
            return true
        }
        // EROFS (read-only volume) is deliberately excluded: it is an I/O
        // condition, not a privacy-permission block, and should get the
        // generic failure hint instead of the App Management deep link.
        if ns.domain == NSPOSIXErrorDomain,
           ns.code == Int(EPERM) || ns.code == Int(EACCES) {
            return true
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain != ns.domain || underlying.code != ns.code {
            return isPermissionDeniedError(underlying)
        }
        return false
    }

    /// Deep link to System Settings → Privacy & Security → App Management.
    func openAppManagementSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AppBundles",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles",
        ]
        for raw in candidates {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    private func enqueueSizeComputation(for ids: [UUID]) {
        for id in ids {
            sizeTasks[id]?.cancel()
            sizeTasks[id] = Task { [weak self] in
                guard let self else { return }
                guard let idx = self.candidates.firstIndex(where: { $0.id == id }) else { return }
                self.candidates[idx].sizeState = .computing
                let path = self.candidates[idx].path
                let result = await sizeService.size(of: path)
                guard !Task.isCancelled else { return }
                guard let i = self.candidates.firstIndex(where: { $0.id == id }) else { return }
                self.candidates[i].byteSize = result.0
                self.candidates[i].sizeState = result.1
            }
        }
    }

    // MARK: - Automatic scan routing / pending queue

    func setLastAutoScanAt(_ date: Date) {
        settingsStore.update { $0.lastAutoScanAt = date }
    }

    /// Coordinators mutate the published flag through this method (the setter
    /// is otherwise private to AppModel).
    func setAutoScanning(_ scanning: Bool) {
        isAutoScanning = scanning
    }

    /// Route an automatic scan's hits per PRD §5.3:
    /// already-excluded → silent IgnoreStore upsert; fresh candidates follow
    /// the configured apply policy.
    func routeAutoScanResults(_ hits: [ScanEngine.Hit]) {
        let already = AutoScanLogic.alreadyExcluded(from: hits)
        if !already.isEmpty {
            ignoreStore.upsertExcluded(
                paths: already.map { ($0.displayPath, $0.ruleName, nil) },
                source: .autoScan
            )
        }

        let fresh = AutoScanLogic.fresh(from: hits).map(Self.makeCandidate(from:))
        // 自动扫描结束日志：即使没有新候选也要记录（0 结果也是结果）。
        if let scanId = currentScanId {
            scanLog.finish(
                scanId: scanId,
                foundCount: hits.count,
                alreadyExcludedCount: already.count,
                pendingCount: fresh.count
            )
        }
        guard !fresh.isEmpty else { return }

        switch settings.applyPolicy {
        case .notifyConfirm:
            let previousPaths = Set(autoPendingCandidates.map(\.path))
            autoPendingCandidates = AutoScanLogic.mergePending(
                existing: autoPendingCandidates,
                incoming: fresh
            )
            pendingReview = true
            // PRD §16.2 防打扰: only notify when this wave actually adds new
            // paths; unchanged pending items must not re-spam the banner.
            let addedNew = fresh.contains { !previousPaths.contains($0.path) }
            if addedNew {
                notificationService.notifyPending(
                    count: autoPendingCandidates.count,
                    enabled: settings.notificationsEnabled
                )
            }
        case .autoApply:
            Task { [weak self] in
                await self?.autoApply(fresh)
            }
        }
    }

    /// autoApply: write exclusions immediately (reusing bundle filtering and
    /// error classification), record them, then send a weak notification.
    private func autoApply(_ items: [ScanCandidate]) async {
        let outcome = await applyExclusions(
            items: items,
            source: .autoScan,
            updateVisibleCandidates: false
        )
        scanLog.logApply(
            scanId: currentScanId,
            source: .autoScan,
            appliedCount: outcome.excludedCount,
            failedCount: outcome.failedCount,
            permissionBlocked: outcome.permissionBlocked,
            appBundleBlockedCount: outcome.appBundleBlockedPaths.count
        )
        if outcome.excludedCount > 0 {
            notificationService.notifyAutoApplied(
                count: outcome.excludedCount,
                enabled: settings.notificationsEnabled
            )
        }
    }

    /// 自动扫描会话开始（由 AutoScanCoordinator 在 performScan 时调用）。
    func beginAutoScanLog(trigger: AutoScanCoordinator.Trigger) {
        let logTrigger: ScanLogService.Trigger
        switch trigger {
        case .interval: logTrigger = .interval
        case .fsEvents: logTrigger = .fsEvents
        case .startup: logTrigger = .startup
        }
        currentScanId = scanLog.begin(kind: .auto, trigger: logTrigger)
    }

    /// Promote the automatic pending queue into the manual result page
    /// (notification tap / menu badge / manual-scan page appears).
    func promoteAutoPending() {
        guard !autoPendingCandidates.isEmpty else { return }
        // Never hijack a running manual session.
        if scanPhase == .running || scanPhase == .applying { return }

        let incoming = autoPendingCandidates
        autoPendingCandidates = []
        notificationService.clearPendingBanner()

        if scanPhase == .result {
            candidates = AutoScanLogic.mergePending(existing: candidates, incoming: incoming)
        } else {
            candidates = incoming
            scanPhase = .result
        }
        pendingReview = candidates.contains { $0.needsExclude }
        enqueueSizeComputation(for: incoming.map(\.id))
    }

    /// Called when the manual-scan page appears: surface the pending queue
    /// automatically when no manual result is occupying the page.
    func manualScanDidAppear() {
        if scanPhase == .idle || scanPhase == .done {
            promoteAutoPending()
        }
    }

    // MARK: - Ignore list actions

    func unignoreSelected() {
        let selected = ignoreStore.records.filter(\.isSelected)
        guard !selected.isEmpty else { return }
        let outcome = Self.planUnignore(
            of: selected,
            fileExists: FileManager.default.fileExists(atPath:),
            setExcluded: { try TimeMachineExclusionService.setExcluded($0, at: $1) }
        )
        // Bundle-blocked records stay in the list; just clear their checkbox so
        // retrying doesn't re-trigger the same warning.
        ignoreStore.setAllSelection(false, in: Array(outcome.bundleBlockedIDs))
        ignoreStore.remove(ids: outcome.clearedIDs.union(outcome.staleIDs))
        let total = outcome.clearedIDs.count + outcome.staleIDs.count
        var message: String
        if outcome.staleIDs.isEmpty {
            message = "已撤销 \(total) 项忽略"
        } else {
            message = "已撤销 \(total) 项忽略（\(outcome.staleIDs.count) 项路径已不存在，直接清理记录）"
        }
        if !outcome.bundleBlockedIDs.isEmpty {
            message += "；\(outcome.bundleBlockedIDs.count) 项位于其他应用包内已跳过"
        }
        if !outcome.failedPaths.isEmpty {
            message += "；\(outcome.failedPaths.count) 项撤销失败"
        }
        flash(message)
    }

    struct UnignoreOutcome: Equatable {
        var clearedIDs: Set<UUID> = []
        /// Path no longer exists: the flag lives on the file's own xattrs, so
        /// there is nothing to clear — the stale record is dropped as-is.
        var staleIDs: Set<UUID> = []
        var bundleBlockedIDs: Set<UUID> = []
        var failedPaths: [String] = []
    }

    /// Decision core of `unignoreSelected`, with filesystem I/O injected for tests.
    static func planUnignore(
        of records: [IgnoreRecord],
        fileExists: (String) -> Bool,
        setExcluded: (_ excluded: Bool, _ path: String) throws -> Void
    ) -> UnignoreOutcome {
        var outcome = UnignoreOutcome()
        for rec in records {
            if pathTouchesAppBundle(rec.path) {
                outcome.bundleBlockedIDs.insert(rec.id)
                continue
            }
            let absolute = TimeMachineExclusionService.expand(rec.path)
            guard fileExists(absolute) else {
                outcome.staleIDs.insert(rec.id)
                continue
            }
            do {
                try setExcluded(false, absolute)
                outcome.clearedIDs.insert(rec.id)
            } catch {
                outcome.failedPaths.append(rec.path)
            }
        }
        return outcome
    }

    func reignoreSelected() {
        let selected = ignoreStore.records.filter { $0.isSelected && $0.status == .anomaly }
        guard !selected.isEmpty else { return }
        let outcome = Self.planReignore(
            of: selected,
            fileExists: FileManager.default.fileExists(atPath:),
            setExcluded: { try TimeMachineExclusionService.setExcluded($0, at: $1) }
        )
        ignoreStore.setAllSelection(false, in: Array(outcome.reappliedIDs))
        ignoreStore.setAllSelection(false, in: Array(outcome.bundleBlockedIDs))
        // 重新读取系统排除标记，自动刷新列表状态
        ignoreStore.refreshStatuses()
        var message = "已重新忽略 \(outcome.reappliedIDs.count) 项路径"
        if !outcome.bundleBlockedIDs.isEmpty {
            message += "；\(outcome.bundleBlockedIDs.count) 项位于其他应用包内已跳过"
        }
        if !outcome.failedPaths.isEmpty {
            message += "；\(outcome.failedPaths.count) 项排除失败"
        }
        flash(message)
    }

    struct ReignoreOutcome: Equatable {
        var reappliedIDs: Set<UUID> = []
        var bundleBlockedIDs: Set<UUID> = []
        var failedPaths: [String] = []
    }

    /// Decision core of `reignoreSelected`, with filesystem I/O injected for tests.
    /// Only `.anomaly` records are touched; missing paths are skipped and let the
    /// status refresh surface them as `.missing`.
    static func planReignore(
        of records: [IgnoreRecord],
        fileExists: (String) -> Bool,
        setExcluded: (_ excluded: Bool, _ path: String) throws -> Void
    ) -> ReignoreOutcome {
        var outcome = ReignoreOutcome()
        for rec in records where rec.status == .anomaly {
            if pathTouchesAppBundle(rec.path) {
                outcome.bundleBlockedIDs.insert(rec.id)
                continue
            }
            let absolute = TimeMachineExclusionService.expand(rec.path)
            guard fileExists(absolute) else { continue }
            do {
                try setExcluded(true, absolute)
                outcome.reappliedIDs.insert(rec.id)
            } catch {
                outcome.failedPaths.append(rec.path)
            }
        }
        return outcome
    }

    func refreshIgnoreStatuses() {
        ignoreStore.refreshStatuses()
        flash("已刷新系统排除状态")
    }

    /// Manually exclude an arbitrary directory (one not matched by any rule).
    /// Writes the TM exclusion flag, records it as `.manualAdd`, and kicks off
    /// async size estimation. Returns nil on success, or an error message to
    /// show in the presenting dialog.
    @discardableResult
    func addManualIgnorePath(_ raw: String) -> String? {
        let normalized = AppSettings.abbreviateHome(AppSettings.normalizeSkipPath(raw))
        guard !normalized.isEmpty else { return "请输入路径" }
        guard normalized != "~", normalized != "/" else {
            return "不能排除整个主目录或根目录"
        }
        if ignoreStore.contains(path: normalized) {
            return "该路径已在忽略列表中"
        }
        guard !Self.pathTouchesAppBundle(normalized) else {
            return "位于应用包（.app）内的目录无法排除"
        }
        let expanded = TimeMachineExclusionService.expand(normalized)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) else {
            return "路径不存在：\(normalized)"
        }
        do {
            try TimeMachineExclusionService.setExcluded(true, at: expanded)
        } catch {
            return "写入排除标记失败：\(error.localizedDescription)"
        }

        ignoreStore.upsertExcluded(paths: [(normalized, nil, nil)], source: .manualAdd)
        flash("已添加 \(normalized)")

        // Async size backfill for the newly inserted record.
        if let id = ignoreStore.records.first(where: { $0.path == normalized })?.id {
            Task { [weak self] in
                guard let self else { return }
                let result = await self.sizeService.size(of: expanded)
                guard !Task.isCancelled else { return }
                self.ignoreStore.updateByteSize(id: id, bytes: result.0)
            }
        }
        return nil
    }

    // MARK: - Settings helpers

    func addSkipPath(_ raw: String) {
        let normalized = AppSettings.abbreviateHome(AppSettings.normalizeSkipPath(raw))
        guard !normalized.isEmpty else { return }
        // Skipping the whole tree would make every scan return nothing.
        guard normalized != "~", normalized != "/" else {
            flash("不能跳过整个主目录或根目录")
            return
        }
        settingsStore.update { settings in
            if !settings.skipPaths.contains(normalized) {
                settings.skipPaths.append(normalized)
            }
        }
    }

    func removeSkipPath(_ path: String) {
        settingsStore.update { settings in
            settings.skipPaths.removeAll { $0 == path }
        }
    }

    func setRuleEnabled(id: String, enabled: Bool) {
        settingsStore.update { settings in
            if let idx = settings.rulePackage.rules.firstIndex(where: { $0.id == id }) {
                settings.rulePackage.rules[idx].isEnabled = enabled
            }
        }
    }

    @Published var isCheckingRules: Bool = false
    @Published var lastRuleUpdateReport: RuleUpdateReport?

    /// Package currently used for scans (never empty; falls back to bundled).
    var activeRulePackage: RulePackage {
        let pkg = settings.rulePackage
        return pkg.rules.isEmpty ? .bundledSnapshot : pkg
    }

    /// - Parameter silent: background daily sync (PRD §6.4.4): no spinner/report
    ///   flash, failures are fully silent (bundled/remote fallback still holds),
    ///   and the active package only changes when the content actually differs.
    func checkRuleUpdates(silent: Bool = false) {
        guard !isCheckingRules else { return }
        if !silent { isCheckingRules = true }
        Task { [weak self] in
            guard let self else { return }
            defer { if !silent { Task { @MainActor in self.isCheckingRules = false } } }
            do {
                let result = try await RulePackageService.shared.fetchLatestFromAsimov()
                await MainActor.run {
                    let previous = self.settings.rulePackage
                    let merged = result.package.mergingEnabledStates(from: previous)
                    let contentChanged = merged.version != previous.version
                        || merged.rules.count != previous.rules.count
                    self.settingsStore.update { settings in
                        settings.remoteRuleCache = merged
                        settings.lastRuleCheckAt = Date()
                        settings.lastRuleCheckSucceeded = true
                        if !silent || contentChanged {
                            settings.rulePackage = merged
                            settings.lastRuleCheckMessage = "已从 Asimov 同步 \(merged.rules.count) 条规则"
                        }
                    }
                    guard !silent else { return }
                    let report = RuleUpdateReport(
                        kind: .success,
                        message: "已更新到 \(merged.version)（\(merged.rules.count) 条）",
                        checkedAt: Date()
                    )
                    self.lastRuleUpdateReport = report
                    self.flash(report.message)
                }
            } catch {
                await MainActor.run {
                    guard !silent else { return }
                    let active = self.activeRulePackage
                    let msg: String
                    let kind: RuleUpdateReport.Kind
                    if active.origin == .remoteCache {
                        msg = "更新失败，继续使用远程缓存（\(active.version)）"
                        kind = .failedUsingActive
                    } else {
                        msg = "更新失败，继续使用内置兜底（\(active.version)）"
                        kind = .failedUsingActive
                    }
                    self.settingsStore.update { settings in
                        settings.lastRuleCheckAt = Date()
                        settings.lastRuleCheckSucceeded = false
                        settings.lastRuleCheckMessage = "\(error.localizedDescription) · \(msg)"
                        // Keep existing rulePackage untouched (fallback behavior).
                    }
                    let report = RuleUpdateReport(kind: kind, message: msg, checkedAt: Date())
                    self.lastRuleUpdateReport = report
                    self.flash(msg)
                }
            }
        }
    }

    /// Daily background rule sync, gated by `autoRuleSync` (PLAN §8):
    /// a few seconds after launch, then once every 24h.
    private func scheduleRuleAutoSync() {
        ruleSyncTask?.cancel()
        ruleSyncTask = nil
        guard settings.autoRuleSync else { return }
        ruleSyncTask = Task { [weak self] in
            // Startup delay so launch / onboarding stays responsive.
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            let day: UInt64 = 24 * 60 * 60 * 1_000_000_000
            while !Task.isCancelled {
                guard let self else { return }
                self.checkRuleUpdates(silent: true)
                try? await Task.sleep(nanoseconds: day)
            }
        }
    }

    /// Explicitly restore L0 bundled snapshot (user action).
    func restoreBundledRules() {
        let previous = settings.rulePackage
        let bundled = RulePackage.bundledSnapshot.mergingEnabledStates(from: previous)
        settingsStore.update { settings in
            settings.rulePackage = bundled
            // keep remoteRuleCache so user can re-apply later if desired
            settings.lastRuleCheckMessage = "已恢复内置兜底规则"
        }
        let report = RuleUpdateReport(
            kind: .restoredBundled,
            message: "已恢复内置兜底（\(bundled.rules.count) 条）",
            checkedAt: Date()
        )
        lastRuleUpdateReport = report
        flash(report.message)
    }

    /// If we have a remote cache distinct from active, re-activate it.
    func activateRemoteRuleCache() {
        guard var cache = settings.remoteRuleCache, !cache.rules.isEmpty else {
            flash("没有可用的远程规则缓存")
            return
        }
        cache = cache.mergingEnabledStates(from: settings.rulePackage)
        settingsStore.update { settings in
            settings.rulePackage = cache
        }
        flash("已切换到远程缓存规则（\(cache.version)）")
    }

    // MARK: - Status

    private func flash(_ message: String) {
        statusMessage = message
        Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if statusMessage == message {
                statusMessage = nil
            }
        }
    }
}
