import AVFoundation
import Foundation
import LineraleData
import LineraleDomain

/// Concrete audio layer implementing `AudioRuntimeControlling`.
///
/// Mirrors `desktop/src/features/player/engine/playerRuntime.ts`:
///  - Cache-hit fast path: if `LocalAudioCache` has validated audio bytes, play
///    the local file with **zero** network.
///  - Cache-miss path: resolve a `PlaybackSession` via `APIClient`, fetch the
///    stream (or direct-innertube plan), cache the bytes for future hits, then
///    play.
///  - Preloads only the single next track (`preloadTrack`).
///
/// Effects (time-stretch via `AVQueuePlayer.rate`, pitch/reverb via
/// `AVAudioEngine` + `AVAudioUnitTimePitch` + `AVAudioUnitReverb`) mirror
/// `pitchShifter.ts` and the store subscription block in `playerRuntime.ts`.
@MainActor
public final class AudioRuntime: AudioRuntimeControlling {
    // MARK: - Dependencies (injected)

    private let api: APIClient
    private let cache: LocalAudioCache

    // MARK: - Audio primitives

    private let player: AVQueuePlayer
    private let audioEngine: AVAudioEngine
    private let playerNode: AVAudioPlayerNode
    private let timePitch: AVAudioUnitTimePitch
    private let reverb: AVAudioUnitReverb

    // MARK: - State

    private var _currentTrackId: String?
    private var loadTask: Task<Void, Never>?
    private var preloadTask: Task<Void, Never>?

    // MARK: - Delegate

    public weak var delegate: AudioRuntimeDelegate?

    public init(
        api: APIClient,
        cache: LocalAudioCache,
        player: AVQueuePlayer = AVQueuePlayer(),
        audioEngine: AVAudioEngine = AVAudioEngine()
    ) {
        self.api = api
        self.cache = cache
        self.player = player
        self.audioEngine = audioEngine
        self.playerNode = AVAudioPlayerNode()
        self.timePitch = AVAudioUnitTimePitch()
        self.reverb = AVAudioUnitReverb()
        attachEngine()
        setupNotifications()
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.interruptSpokenAudioAndSiri, .allowBluetooth, .allowAirPlay])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            delegate?.runtimeError(trackId: nil, message: "AVAudioSession activate failed: \(error)")
        }
        #endif
    }

    private func attachEngine() {
        audioEngine.attach(playerNode)
        audioEngine.attach(timePitch)
        audioEngine.attach(reverb)
        audioEngine.connect(playerNode, to: timePitch, format: nil)
        audioEngine.connect(timePitch, to: reverb, format: nil)
        audioEngine.connect(reverb, to: audioEngine.mainMixerNode, format: nil)
        try? audioEngine.start()
    }

    private var playbackFinishedToken: NSObjectProtocol?
    private var playbackFailedToken: NSObjectProtocol?

    private func setupNotifications() {
        playbackFinishedToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handleItemFinished(note) }
        }
        playbackFailedToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayEndTime,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handleItemFailed(note) }
        }
    }

    private func handleItemFinished(_ note: Notification) {
        guard let item = note.object as? AVPlayerItem,
              player.currentItem === item else { return }
        delegate?.runtimePlaybackEnded(trackId: _currentTrackId)
    }

    private func handleItemFailed(_ note: Notification) {
        if let err = (note.userInfo?[AVPlayerItemFailedToPlayEndTimeErrorKey] as? Error) {
            delegate?.runtimeError(trackId: _currentTrackId, message: "AVPlayerItem failed: \(err)")
        }
    }

    // MARK: - AudioRuntimeControlling

    public var currentTrackId: String? {
        get async { _currentTrackId }
    }

    public func loadAndPlay(_ track: Track, startPositionMs: Int) async throws {
        let trackId = track.id
        _currentTrackId = trackId

        loadTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let url: URL
                if let cached = try? await cache.getAudio(for: trackId),
                   isStandaloneAudioFile(Data(cached.prefix(1024))) {
                    url = try writeTemp(cached, trackId: trackId, suffix: "cached")
                } else {
                    let session = try await api.createPlaybackSession(for: trackId)
                    let resolved = try await resolveFromSession(session)
                    try await cache.saveAudio(resolved.data, for: trackId, mimeType: resolved.mimeType)
                    url = try writeTemp(resolved.data, trackId: trackId, suffix: "fetched")
                }

                if Task.isCancelled { return }

                playLocalURL(url, startPositionMs: startPositionMs)
                delegate?.runtimePlaybackStarted(trackId: trackId, metrics: nil)
            } catch {
                if !Task.isCancelled {
                    delegate?.runtimeError(trackId: trackId, message: "loadAndPlay failed: \(error)")
                }
            }
        }
        loadTask = task
        await loadTask?.value
    }

    public func preloadTrack(_ track: Track) async {
        let trackId = track.id
        if (try? await cache.getAudio(for: trackId)) != nil { return }
        preloadTask?.cancel()
        preloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let session = try await api.createPlaybackSession(for: trackId)
                let resolved = try await resolveFromSession(session)
                try await cache.saveAudio(resolved.data, for: trackId, mimeType: resolved.mimeType)
            } catch {
                if !Task.isCancelled {
                    delegate?.runtimeError(trackId: trackId, message: "preload failed: \(error)")
                }
            }
        }
    }

    public func pause() async { player.pause() }
    public func resume() async { player.play() }

    public func seek(positionMs: Int) async {
        let cmTime = CMTime(value: CMTimeValue(positionMs), timescale: 1000)
        player.seek(to: cmTime)
    }

    public func cancelPendingLoad() async {
        loadTask?.cancel()
        loadTask = nil
    }

    public func stop() async {
        player.pause()
        player.removeAllItems()
        playerNode.stop()
    }

    public func setVolume(_ gain: Double) async {
        player.volume = max(0.0, min(1.0, gain))
    }

    public func setPlaybackRate(_ rate: Double, preservePitch: Bool) async {
        player.rate = max(0.0, rate)
        if preservePitch { timePitch.rate = 1.0 }
    }

    public func applyPitch(semitones: Double, linked: Bool, reverb: Bool, reverbLevel: Double) async {
        if linked {
            player.rate = 1.0
        } else {
            timePitch.pitch = semitones
        }
        if reverb {
            self.reverb.wetDryMix = max(0.0, min(100.0, reverbLevel * 100.0))
            self.reverb.isEnabled = true
        }
    }

    public func hasLoadedSourceFor(_ trackId: String) async -> Bool {
        (try? await cache.getAudio(for: trackId)) != nil
    }

    // MARK: - Helpers

    private func playLocalURL(_ url: URL, startPositionMs: Int) {
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 5
        player.removeAllItems()
        player.insert(item, after: nil)
        if startPositionMs > 0 {
            let cmTime = CMTime(value: CMTimeValue(startPositionMs), timescale: 1000)
            player.seek(to: cmTime) { [weak self] _ in
                Task { @MainActor in self?.player.play() }
            }
        } else {
            player.play()
        }
    }

    private func writeTemp(_ data: Data, trackId: String, suffix: String) throws -> URL {
        let tempDir = cache.container.appendingPathComponent("tmp", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let url = tempDir.appendingPathComponent("\(trackId).\(suffix).audio")
        try data.write(to: url, options: .atomic)
        return url
    }

    private func resolveFromSession(_ session: PlaybackSessionResponse) async throws -> (data: Data, mimeType: String) {
        if let streamUrl = session.streamUrl,
           let url = URL(string: streamUrl) {
            let (data, _) = try await api.session.data(from: url)
            return (data, session.mimeType ?? "audio/ogg")
        }

        if session.transport?.rawValue == PlaybackTransport.directInnertube.rawValue,
           session.endpoint != nil {
            let resolved = try await api.resolveDirectInnertubeStream(session: session)
            guard let streamURL = URL(string: resolved.url) else {
                throw AudioRuntimeError.badURL
            }
            let (data, _) = try await api.session.data(from: streamURL)
            return (data, resolved.mimeType)
        }

        throw AudioRuntimeError.unsupportedTransport
    }

    enum AudioRuntimeError: Error {
        case badURL
        case unsupportedTransport
    }

    deinit {
        if let token = playbackFinishedToken {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = playbackFailedToken {
            NotificationCenter.default.removeObserver(token)
        }
    }
}

/// Delegate consumed by `PlaybackEngine` for analytics + media-session bridge.
public protocol AudioRuntimeDelegate: AnyObject, Sendable {
    func runtimePlaybackStarted(trackId: String?, metrics: PlaybackMetrics?)
    func runtimePlaybackEnded(trackId: String?)
    func runtimeError(trackId: String?, message: String)
    func runtimeSetPlaybackContext(_ context: String?)
}
