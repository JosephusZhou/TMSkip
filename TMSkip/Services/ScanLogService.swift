import Foundation

/// 扫描与应用操作的结构化 JSONL 日志。
///
/// 位置：`~/Library/Application Support/TMSkip/scan-log.jsonl`（与
/// `ignore-records.json` 同目录，Application Support 是 macOS 持久业务数据的
/// 规范位置；不用 Caches，系统可随时清理会丢历史）。
///
/// 设计要点：
/// - **JSON Lines**：每行一个 JSON 对象、追加写，单行原子，手动/自动扫描并发
///   也不会写坏文件；可 grep、可被脚本/未来 UI 直接解析。
/// - **事件模型**：`scan.started` / `scan.finished` / `scan.cancelled` /
///   `apply.finished`，同一扫描会话用 `scanId` 关联。崩溃时只会留下 started
///   而没有 finished，恰好暴露"有一次扫描被中断"，审计不丢信息。
/// - **静默降级**：写入失败一律 `try?`，绝不影响扫描主流程（与 IgnoreStore 同风格）。
/// - **轮转**：单文件超过 `maxBytes` 时轮转为 `scan-log.1.jsonl`，保留最近
///   5 份（当前 + 4 份轮转），防止无限增长。
@MainActor
final class ScanLogService {
    enum Event: String, Codable {
        case scanStarted = "scan.started"
        case scanFinished = "scan.finished"
        case scanCancelled = "scan.cancelled"
        case applyFinished = "apply.finished"
    }

    enum Kind: String, Codable {
        case manual
        case auto
    }

    enum Trigger: String, Codable {
        /// 用户在手动扫描页点「开始扫描」。
        case userInitiated
        /// 定时器到点。
        case interval
        /// FSEvents 文件活动（30s 防抖后）。
        case fsEvents
        /// 启动超间隔补跑 / 手动扫描结束后补一轮。
        case startup
    }

    enum ApplySource: String, Codable {
        case manualScan
        case autoScan
    }

    struct Entry: Codable {
        var event: Event
        var scanId: UUID
        var kind: Kind?
        var trigger: Trigger?
        var timestamp: Date
        var appVersion: String

        // scan.finished
        var durationMs: Int?
        var foundCount: Int?
        var alreadyExcludedCount: Int?
        var pendingCount: Int?

        // apply.finished
        var source: ApplySource?
        var appliedCount: Int?
        var failedCount: Int?
        var permissionBlocked: Bool?
        var appBundleBlockedCount: Int?

        // scan.cancelled
        var reason: String?
    }

    /// 每份日志文件的大小上限（默认 5 MB），超出即轮转。
    let maxBytes: Int
    /// 保留的总份数：当前文件 + (maxKeptFiles - 1) 份轮转文件。
    static let maxKeptFiles = 5

    private let directory: URL
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var fileHandle: FileHandle?
    private var startedAtByScanId: [UUID: Date] = [:]

    init(directory: URL? = nil, maxBytes: Int = 5 * 1024 * 1024) {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.directory = directory ?? appSupport.appendingPathComponent("TMSkip", isDirectory: true)
        self.maxBytes = maxBytes
        fileURL = self.directory.appendingPathComponent("scan-log.jsonl")
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    // MARK: - 事件入口

    /// 记录一次扫描开始，返回本次会话的 `scanId`（finished/cancelled 用它关联）。
    @discardableResult
    func begin(kind: Kind, trigger: Trigger, scanId: UUID = UUID()) -> UUID {
        startedAtByScanId[scanId] = Date()
        log(Entry(
            event: .scanStarted,
            scanId: scanId,
            kind: kind,
            trigger: trigger,
            timestamp: Date(),
            appVersion: Self.appVersion
        ))
        return scanId
    }

    /// 记录扫描正常结束。`durationMs` 由开始时间自动推算。
    func finish(
        scanId: UUID,
        foundCount: Int,
        alreadyExcludedCount: Int,
        pendingCount: Int
    ) {
        let durationMs = startedAtByScanId.removeValue(forKey: scanId)
            .map { Int(Date().timeIntervalSince($0) * 1000) }
        log(Entry(
            event: .scanFinished,
            scanId: scanId,
            timestamp: Date(),
            appVersion: Self.appVersion,
            durationMs: durationMs,
            foundCount: foundCount,
            alreadyExcludedCount: alreadyExcludedCount,
            pendingCount: pendingCount
        ))
    }

    /// 记录扫描被取消（用户取消 / 扫描中断）。
    func cancel(scanId: UUID, reason: String) {
        startedAtByScanId.removeValue(forKey: scanId)
        log(Entry(
            event: .scanCancelled,
            scanId: scanId,
            timestamp: Date(),
            appVersion: Self.appVersion,
            reason: reason
        ))
    }

    /// 记录一次排除标记写入的结果（手动应用 / autoApply 共用）。
    func logApply(
        scanId: UUID?,
        source: ApplySource,
        appliedCount: Int,
        failedCount: Int,
        permissionBlocked: Bool,
        appBundleBlockedCount: Int
    ) {
        log(Entry(
            event: .applyFinished,
            scanId: scanId ?? UUID(),
            timestamp: Date(),
            appVersion: Self.appVersion,
            source: source,
            appliedCount: appliedCount,
            failedCount: failedCount,
            permissionBlocked: permissionBlocked,
            appBundleBlockedCount: appBundleBlockedCount
        ))
    }

    // MARK: - 写入与轮转

    private func log(_ entry: Entry) {
        guard let data = try? encoder.encode(entry),
              let line = String(data: data, encoding: .utf8) else { return }
        rotateIfNeeded()
        guard let handle = ensureHandle() else { return }
        handle.seekToEndOfFile()
        handle.write(Data((line + "\n").utf8))
    }

    private func ensureHandle() -> FileHandle? {
        if let fileHandle { return fileHandle }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: fileURL)
        handle?.seekToEndOfFile()
        fileHandle = handle
        return handle
    }

    /// 当前文件达到上限时：删除最老轮转 → 依次后移 → 当前文件降为 .1。
    private func rotateIfNeeded() {
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
        guard size >= maxBytes else { return }

        closeHandle()
        let rotatedCount = Self.maxKeptFiles - 1
        let dir = directory
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("scan-log.\(rotatedCount).jsonl"))
        for i in stride(from: rotatedCount - 1, through: 1, by: -1) {
            let src = dir.appendingPathComponent("scan-log.\(i).jsonl")
            let dst = dir.appendingPathComponent("scan-log.\(i + 1).jsonl")
            try? FileManager.default.moveItem(at: src, to: dst)
        }
        try? FileManager.default.moveItem(
            at: fileURL,
            to: dir.appendingPathComponent("scan-log.1.jsonl")
        )
    }

    private func closeHandle() {
        try? fileHandle?.close()
        fileHandle = nil
    }

    deinit {
        try? fileHandle?.close()
    }
}
