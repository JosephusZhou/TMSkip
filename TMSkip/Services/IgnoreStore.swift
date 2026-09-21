import Foundation

@MainActor
final class IgnoreStore: ObservableObject {
    @Published private(set) var records: [IgnoreRecord] = []

    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("TMSkip", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("ignore-records.json")
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? decoder.decode([IgnoreRecord].self, from: data) else {
            records = []
            return
        }
        records = decoded
    }

    private func persist() {
        // Strip UI-only selection
        let payload = records.map { rec -> IgnoreRecord in
            var r = rec
            r.isSelected = false
            return r
        }
        guard let data = try? encoder.encode(payload) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func upsertExcluded(paths: [(path: String, ruleName: String?, bytes: Int64?)], source: IgnoreSource) {
        let now = Date()
        for item in paths {
            if let idx = records.firstIndex(where: { $0.path == item.path }) {
                records[idx].status = .excluded
                records[idx].source = source
                records[idx].ruleName = item.ruleName ?? records[idx].ruleName
                records[idx].byteSize = item.bytes ?? records[idx].byteSize
                records[idx].updatedAt = now
                records[idx].lastVerifiedAt = now
            } else {
                records.insert(
                    IgnoreRecord(
                        path: item.path,
                        source: source,
                        status: .excluded,
                        ruleName: item.ruleName,
                        byteSize: item.bytes,
                        createdAt: now,
                        updatedAt: now,
                        lastVerifiedAt: now
                    ),
                    at: 0
                )
            }
        }
        persist()
    }

    func remove(ids: Set<UUID>) {
        records.removeAll { ids.contains($0.id) }
        persist()
    }

    /// True when a record already exists for this exact (tilde-form) path.
    func contains(path: String) -> Bool {
        records.contains { $0.path == path }
    }

    /// Backfill a record's size after async computation. No-op if missing.
    func updateByteSize(id: UUID, bytes: Int64?) {
        guard let idx = records.firstIndex(where: { $0.id == id }) else { return }
        records[idx].byteSize = bytes
        persist()
    }

    func updateSelection(id: UUID, selected: Bool) {
        guard let idx = records.firstIndex(where: { $0.id == id }) else { return }
        records[idx].isSelected = selected
    }

    func setAllSelection(_ selected: Bool, in ids: [UUID]) {
        let set = Set(ids)
        for i in records.indices where set.contains(records[i].id) {
            records[i].isSelected = selected
        }
    }

    func refreshStatuses() {
        for i in records.indices {
            let expanded = (records[i].path as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if !FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) {
                records[i].status = .missing
            } else if let excluded = TimeMachineExclusionService.isExcluded(at: records[i].path) {
                records[i].status = excluded ? .excluded : .anomaly
            } else {
                records[i].status = .anomaly
            }
            records[i].lastVerifiedAt = Date()
        }
        persist()
    }

    var totalExcludedBytes: Int64 {
        records.filter { $0.status == .excluded }.compactMap(\.byteSize).reduce(0, +)
    }
}
