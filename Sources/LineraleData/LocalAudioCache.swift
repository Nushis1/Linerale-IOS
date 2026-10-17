public import Foundation

/// On-disk LRU audio cache mirroring `desktop/src/shared/storage/audioCache.ts`.
///
/// - 3 GB default limit, 250 MB floor (clamped in `setLimitBytes`).
/// - Records live as raw audio files in `applicationSupport/LineraleAudio/`.
/// - A JSON manifest (`manifest.json`) tracks `trackId -> record` for LRU
///   eviction and total-byte accounting (mirrors `linerDb.ts` metadata tables).
/// - `putAudio` validates the payload with `isStandaloneAudioFile` before
///   storing, so only playable audio is cached.
public final class LocalAudioCache: @unchecked Sendable {
    /// Public, configurable limits mirrored from `audioCache.ts`.
    public static let defaultLimitBytes: Int64 = 3 * 1024 * 1024 * 1024
    public static let minLimitBytes: Int64 = 250 * 1024 * 1024

    public let fileManager: FileManager
    public let container: URL
    private let manifestURL: URL
    private let cacheLimitKey = "LineraleAudioCacheLimitBytes"

    private let stateLock = NSLock()
    private var manifest: Manifest

    /// Stored limit; written to UserDefaults by `setLimitBytes` for persistence.
    public private(set) var limitBytes: Int64

    public init(
        fileManager: FileManager = .default,
        applicationSupport: URL? = nil
    ) throws {
        self.fileManager = fileManager
        if let applicationSupport {
            self.container = applicationSupport
        } else {
            self.container = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("LineraleAudio", isDirectory: true)
        }
        try fileManager.createDirectory(at: container, withIntermediateDirectories: true, attributes: nil)
        self.manifestURL = container.appendingPathComponent("manifest.json", isDirectory: false)
        self.manifest = try Self.loadManifest(from: manifestURL, fileManager: fileManager)
        let stored = UserDefaults.standard.integer(forKey: cacheLimitKey)
        self.limitBytes = stored > 0 ? Int64(stored) : defaultLimitBytes
    }

    // MARK: - Manifest

    private struct Manifest: Codable {
        var records: [String: Record]
    }

    private struct Record: Codable, Sendable {
        let trackId: String
        let fileName: String
        let mimeType: String
        let byteSize: Int64
        let createdAt: Date
        var lastAccessedAt: Date
        let expiresAt: Date?
    }

    private static func loadManifest(from url: URL, fileManager: FileManager) throws -> Manifest {
        if fileManager.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(Manifest.self, from: data)
        }
        return Manifest(records: [:])
    }

    private func saveManifest() throws {
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
    }

    // MARK: - Public API (mirrors audioCache.ts / linerDb.ts surface)

    public func setLimitBytes(_ bytes: Int64) async {
        let clamped: Int64
        if bytes == 0 {
            clamped = 0
        } else if bytes < Self.minLimitBytes {
            clamped = Self.minLimitBytes
        } else {
            clamped = bytes
        }
        stateLock.withLock {
            UserDefaults.standard.set(clamped, forKey: cacheLimitKey)
            self.limitBytes = clamped
        }
        await enforceCacheLimit()
    }

    /// Evict oldest records until usage is under the configured limit.
    /// Returns the total bytes evicted.
    @discardableResult
    public func enforceCacheLimit(_ customLimit: Int64? = nil) async -> Int64 {
        let limit = customLimit ?? stateLock.withLock { limitBytes }
        if limit <= 0 { return 0 }

        let totalBytes = await getTotalAudioBytes()
        guard totalBytes > limit else { return 0 }

        let targetBytes = Int64(Double(limit) * 0.9)
        let bytesToEvict = totalBytes - targetBytes
        var evictedBytes: Int64 = 0

        let oldest = await getOldestAudioRecords()
        for record in oldest where evictedBytes < bytesToEvict {
            let size = await deleteAudio(record.trackId)
            evictedBytes += size
        }
        return evictedBytes
    }

    public func hasAudio(for trackId: String) async -> Bool {
        stateLock.withLock { manifest.records[trackId] != nil }
    }

    public func getAudio(for trackId: String) async throws -> Data? {
        return try await withCheckedThrowingContinuation { continuation in
            stateLock.lock()
            defer { stateLock.unlock() }
            guard let record = manifest.records[trackId] else {
                continuation.resume(returning: nil)
                return
            }
            manifest.records[trackId]?.lastAccessedAt = Date()
            do { try saveManifest() } catch { continuation.resume(throwing: $0); return }
            let fileURL = container.appendingPathComponent(record.fileName, isDirectory: false)
            do {
                let data = try Data(contentsOf: fileURL)
                continuation.resume(returning: data)
            } catch { continuation.resume(throwing: $0) }
        }
    }

    public func saveAudio(_ data: Data, for trackId: String, mimeType: String = "audio/ogg") async throws {
        guard isStandaloneAudioFile(Data(data.prefix(1024))) else {
            throw AudioCacheError.notPlayable
        }
        let fileName = "\(trackId).\(fileExtension(for: mimeType))"
        let fileURL = container.appendingPathComponent(fileName, isDirectory: false)
        try data.write(to: fileURL, options: .atomic)

        stateLock.lock()
        defer { stateLock.unlock() }
        manifest.records[trackId] = Record(
            trackId: trackId,
            fileName: fileName,
            mimeType: mimeType,
            byteSize: Int64(data.count),
            createdAt: Date(),
            lastAccessedAt: Date(),
            expiresAt: nil
        )
        try? saveManifest()
    }

    @discardableResult
    public func deleteAudio(for trackId: String) async -> Int64 {
        return await withCheckedContinuation { continuation in
            stateLock.lock()
            defer { stateLock.unlock() }
            guard let record = manifest.records.removeValue(forKey: trackId) else {
                continuation.resume(returning: 0)
                return
            }
            let fileURL = container.appendingPathComponent(record.fileName, isDirectory: false)
            let size = record.byteSize
            try? fileManager.removeItem(at: fileURL)
            try? saveManifest()
            continuation.resume(returning: size)
        }
    }

    /// Records used internally for LRU eviction ordering.
    func getOldestAudioRecords() async -> [Record] {
        stateLock.withLock {
            manifest.records.values.sorted { $0.lastAccessedAt < $1.lastAccessedAt }
        }
    }

    public func getTotalAudioBytes() async -> Int64 {
        stateLock.withLock { manifest.records.values.reduce(0) { $0 + $1.byteSize } }
    }

    enum AudioCacheError: Error {
        case notPlayable
        case corrupted
    }

    private func fileExtension(for mimeType: String) -> String {
        switch mimeType {
        case "audio/mp4", "audio/m4a": return "m4a"
        case "audio/ogg", "audio/opus": return "opus"
        case "audio/webm": return "webm"
        case "audio/flac": return "flac"
        case "audio/mpeg": return "mp3"
        default: return "bin"
        }
    }
}
