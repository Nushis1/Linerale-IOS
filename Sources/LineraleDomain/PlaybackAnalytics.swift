public import Foundation

/// Lightweight, in-process analytics sink that mirrors the desktop
/// `PlaybackTelemetryTracker` + `telemetry.trackPlaybackHealth` pattern.
/// Events are buffered to disk (Codable JSON manifest) and drained on flush,
/// so a transient network client can report them without blocking playback.
@MainActor
public final class PlaybackAnalytics: Sendable {
    public struct Config: Sendable {
        public let flushThreshold: Int
        public let endpoint: String
        public init(flushThreshold: Int = 50, endpoint: String = "/v1/me/playback/events") {
            self.flushThreshold = flushThreshold
            self.endpoint = endpoint
        }
    }

    private let config: Config
    private var buffer: [PlaybackEvent] = []
    private let storageURL: URL

    public init(config: Config = .init(), storageURL: URL? = nil) {
        self.config = config
        if let storageURL { self.storageURL = storageURL }
        else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            let base: URL
            if #available(macOS 13.0, *) {
                base = appSupport ?? .temporaryDirectory
            } else {
                base = appSupport ?? URL(fileURLWithPath: NSTemporaryDirectory())
            }
            let dir = base.appendingPathComponent("LineraleAnalytics", isDirectory: true)
            self.storageURL = dir
        }
        loadBuffer()
    }

    public func report(_ event: PlaybackEvent) {
        buffer.append(event)
        if buffer.count >= config.flushThreshold { flush() }
    }

    public func flush() {
        guard !buffer.isEmpty else { return }
        let batch = buffer
        buffer.removeAll()
        // Disk write is best-effort; never throws to caller (matches desktop
        // `void api.recordPlaybackEvent(...).catch {}`).
        do {
            try persist(batch)
        } catch {
            #if DEBUG
            print("[Linerale.Analytics] persist failed: \(error)")
            #endif
        }
    }

    private func persist(_ events: [PlaybackEvent]) throws {
        // Real app: POST to backend. Here we append to the manifest file.
        var existing: [PlaybackEvent] = []
        if let data = try? Data(contentsOf: storageURL),
           let decoded = try? JSONDecoder().decode([PlaybackEvent].self, from: data) {
            existing = decoded
        }
        let merged = existing + events
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(merged)
        try data.write(to: storageURL, options: .atomic)
    }

    private func loadBuffer() {
        guard let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode([PlaybackEvent].self, from: data) else { return }
        #if DEBUG
        print("[Linerale.Analytics] recovered \(decoded.count) events from disk")
        #endif
        buffer = decoded
    }

    public func reset() { buffer.removeAll() }
}
