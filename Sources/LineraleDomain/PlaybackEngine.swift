public import Foundation
import Combine

// MARK: - Audio runtime abstraction (injected; implemented in LineralePlayback)

/// Protocol the engine uses to talk to the concrete audio layer.
/// All methods are async so background fetches never block the main actor.
public protocol AudioRuntimeControlling: AnyObject, Sendable {
    func loadAndPlay(_ track: Track, startPositionMs: Int) async throws
    func preloadTrack(_ track: Track) async
    func pause() async
    func resume() async
    func seek(positionMs: Int) async
    func cancelPendingLoad() async
    func stop() async
    func setVolume(_ gain: Double) async
    func setPlaybackRate(_ rate: Double, preservePitch: Bool) async
    func applyPitch(semitones: Double, linked: Bool, reverb: Bool, reverbLevel: Double) async
    func hasLoadedSourceFor(_ trackId: String) async -> Bool
    var currentTrackId: String? { get async }
}

// MARK: - Engine delegate (analytics + media-session bridge)

public protocol PlaybackEngineDelegate: AnyObject, Sendable {
    func enginePlaybackStarted(track: Track, metrics: PlaybackMetrics?)
    func enginePlaybackCompleted(trackId: String, repeatOne: Bool)
    func enginePlaybackError(trackId: String, message: String)
    func engineSetPlaybackContext(_ context: String?)
    func engineSetPlaybackContextCover(_ cover: String?)
}

public struct PlaybackEngineConfig: Sendable {
    public let maxConsecutiveAutoSkips: Int
    public let autoplaySimilar: Bool
    public let radioAppendDelayMs: UInt64
    public let radioBatchSize: Int
    public init(
        maxConsecutiveAutoSkips: Int = 3,
        autoplaySimilar: Bool = true,
        radioAppendDelayMs: UInt64 = 400,
        radioBatchSize: Int = 20
    ) {
        self.maxConsecutiveAutoSkips = maxConsecutiveAutoSkips
        self.autoplaySimilar = autoplaySimilar
        self.radioAppendDelayMs = radioAppendDelayMs
        self.radioBatchSize = radioBatchSize
    }
}

/// The single source of truth for playback queue + transport state.
///
/// `@MainActor` mirrors the desktop app's single-threaded event loop (Zustand
/// store + playerEngine run on one JS thread). A background URLSession lives in
/// `AudioRuntime` (never main-isolated), so awaiting it here cannot deadlock.
@MainActor
public final class PlaybackEngine: ObservableObject {
    public let audio: AudioRuntimeControlling
    public let config: PlaybackEngineConfig
    public weak var delegate: PlaybackEngineDelegate?
    private let analytics: PlaybackAnalytics

    // Re-playable radio backend (mirrors `api.getRadio`).
    public var radioProvider: (@Sendable (String, RadioOptions) async throws -> [Track])?

    @Published public private(set) var state: PlaybackState

    // Mirrors private fields of desktop playerEngine
    private var sessionId: Int64 = 0
    private var masterPlaylist: [Track] = []
    private var originalUpcomingQueue: [Track] = []
    private var consecutiveAutoSkips = 0
    private var lastPreloadKey: String? = nil
    private var radioAppendTask: Task<Void, Never>?
    private var radioWaveId: String? = nil
    private var currentTrackIdForTelemetry: String?

    // MARK: - Init

    public init(
        audio: AudioRuntimeControlling,
        config: PlaybackEngineConfig = .init(),
        analytics: PlaybackAnalytics = .init(),
        initialState: PlaybackState = .init()
    ) {
        self.audio = audio
        self.config = config
        self.analytics = analytics
        self.state = initialState
        self.state.volume = initialState.volume
    }

    public func snapshot() -> PlaybackState { state }

    /// Synchronous optimistic update on the main actor, then fire-and-forget
    /// the actual load. Matches desktop `store.setCurrentTrack(...)` timing.
    private func mutate(_ changes: (inout PlaybackState) -> Void) {
        changes(&state)
    }

    // MARK: - Command dispatch

    @discardableResult
    public func dispatch(_ command: PlayerCommand) -> Task<Void, Never> {
        switch command {
        case .play(let request):
            return Task { await playTrack(request.track, queue: request.queue, context: request.context, contextCover: request.contextCover, queueIndex: request.queueIndex, preserveQueue: request.preserveQueue) }
        case .pause:
            return Task { await pause() }
        case .resume:
            return Task { await resume() }
        case .seek(let positionMs):
            seek(positionMs: positionMs)
            return Task {}
        case .skipNext(let auto):
            return Task { await skipNext(isAutoEnd: auto) }
        case .skipPrevious:
            return Task { await skipPrevious() }
        case .setVolume(let v):
            setVolume(v)
            return Task {}
        case .setPlaybackRate(let r):
            Task { await setPlaybackRate(r) }
            return Task {}
        case .setPitch(let s):
            Task { await setPitchSemitones(s) }
            return Task {}
        case .togglePlayPause:
            return Task { await togglePlayPause() }
        }
    }

    // MARK: - Playback control

    public func playTrack(
        _ track: Track,
        queue: [Track]? = nil,
        context: String? = nil,
        contextCover: String? = nil,
        queueIndex: Int? = nil,
        preserveQueue: Bool = false
    ) async {
        let nextQueue = normalizeQueue(queue ?? [track], track)
        let nextIndex = queueIndex ?? max(0, nextQueue.firstIndex(where: { $0.id == track.id }) ?? 0)

        sessionId += 1
        let mySession = sessionId
        radioWaveId = newRadioWaveId()

        var finalQueue = nextQueue
        var finalIndex = nextIndex

        let isSelectingFromCurrentQueue =
            preserveQueue ||
            (queueIndex != nil &&
             state.queue.count > 0 &&
             state.queue.count == nextQueue.count &&
             state.queue[queueIndex!]?.id == track.id)

        if !isSelectingFromCurrentQueue { masterPlaylist = nextQueue }
        if !isSelectingFromCurrentQueue && state.shuffle && nextQueue.count > 1 {
            let played = Array(nextQueue[0..<nextIndex])
            let selected = nextQueue[nextIndex]
            let upcoming = Array(nextQueue[(nextIndex + 1)...])
            originalUpcomingQueue = upcoming
            finalQueue = played + [selected] + shuffle(upcoming)
            finalIndex = nextIndex
        } else if !isSelectingFromCurrentQueue {
            originalUpcomingQueue = []
        }

        let selectedTrack = finalQueue[finalIndex] ?? track

        mutate {
            if let context { $0.playbackContext = context }
            if let contextCover { $0.playbackContextCover = contextCover }
            $0.queue = finalQueue
            $0.currentTrack = selectedTrack
            $0.currentIndex = finalIndex
            $0.positionMs = 0
            $0.durationMs = selectedTrack.durationMs
            $0.status = .loading
            $0.error = nil
        }
        delegate?.engineSetPlaybackContext(context)
        delegate?.engineSetPlaybackContextCover(contextCover)
        delegate?.enginePlaybackStarted(track: selectedTrack, metrics: nil)
        telemetryStartTrack(selectedTrack, state.playbackContext)

        if finalIndex == finalQueue.count - 1 {
            scheduleAppendSimilarTracks(session: mySession, seedTrackId: selectedTrack.id)
        }

        do {
            try await audio.loadAndPlay(selectedTrack, startPositionMs: 0)
            mutate { $0.status = .playing }
        } catch {
            handlePlaybackError(trackId: selectedTrack.id, message: "\(error)")
        }
    }

    public func playShuffled(
        _ tracks: [Track],
        context: String? = nil,
        contextCover: String? = nil,
        startIndex: Int? = nil
    ) async {
        guard !tracks.isEmpty else { return }
        let seedIndex = startIndex.map { max(0, min($0, tracks.count - 1)) } ?? Int.random(in: 0..<tracks.count)
        let seedTrack = tracks[seedIndex]
        let remaining = Array(tracks[0..<seedIndex]) + Array(tracks[(seedIndex + 1)...])
        let finalQueue = [seedTrack] + shuffle(remaining)

        masterPlaylist = tracks
        originalUpcomingQueue = remaining

        sessionId += 1
        let mySession = sessionId

        mutate {
            $0.shuffle = true
            if let context { $0.playbackContext = context }
            if let contextCover { $0.playbackContextCover = contextCover }
            $0.queue = finalQueue
            $0.currentTrack = seedTrack
            $0.currentIndex = 0
            $0.positionMs = 0
            $0.durationMs = seedTrack.durationMs
            $0.status = .loading
            $0.error = nil
        }
        delegate?.engineSetPlaybackContext(context)
        delegate?.engineSetPlaybackContextCover(contextCover)
        telemetryStartTrack(seedTrack, state.playbackContext)

        do {
            try await audio.loadAndPlay(seedTrack, startPositionMs: 0)
            mutate { $0.status = .playing }
        } catch {
            handlePlaybackError(trackId: seedTrack.id, message: "\(error)")
        }
        if finalQueue.count == 1 { scheduleAppendSimilarTracks(session: mySession, seedTrackId: seedTrack.id) }
    }

    public func startRadioStation(_ track: Track) async {
        sessionId += 1
        let mySession = sessionId
        radioWaveId = newRadioWaveId()
        let waveId = radioWaveId!

        mutate {
            $0.playbackContext = "radio:\(track.id)"
            $0.playbackContextCover = track.coverUrl
            $0.queue = [track]
            $0.currentTrack = track
            $0.currentIndex = 0
            $0.positionMs = 0
            $0.durationMs = track.durationMs
            $0.status = .loading
            $0.error = nil
        }
        originalUpcomingQueue = []

        do {
            try await audio.loadAndPlay(track, startPositionMs: 0)
            let additions = try await fetchRadio(seedTrackId: track.id, waveId: waveId, history: [track.id], session: mySession)
            guard sessionId == mySession else { return }
            let latest = state
            let updatedQueue = [track] + additions.filter { $0.id != track.id }
            if latest.shuffle {
                originalUpcomingQueue = additions
                mutate { $0.queue = [track] + shuffle(additions) }
            } else {
                mutate { $0.queue = updatedQueue }
            }
            preloadNextTrack()
        } catch { log("radio fetch failed: \(error)") }
    }

    public func pause() async {
        let wasLoading = state.status == .loading
        if wasLoading { await audio.cancelPendingLoad() }
        mutate { $0.status = .paused }
        if !wasLoading { await audio.pause() }
    }

    public func resume() async {
        guard let track = state.currentTrack else { return }
        let hasSource = await audio.hasLoadedSourceFor(track.id)
        if !hasSource {
            do {
                try await audio.loadAndPlay(track, startPositionMs: state.positionMs)
                mutate { $0.status = .playing }
            }
            catch { handlePlaybackError(trackId: track.id, message: "\(error)") }
        } else {
            mutate { $0.status = .playing }
            await audio.resume()
        }
    }

    public func togglePlayPause() async {
        if state.status == .playing || state.status == .loading {
            await pause()
        } else {
            await resume()
        }
    }

    // MARK: - Skipping

    public func skipNext(isAutoEnd: Bool = false) async {
        let nextIndex = computeNextIndex(isAutoEnd: isAutoEnd)

        if nextIndex == nil {
            mutate {
                $0.status = .idle
                $0.positionMs = 0
                $0.durationMs = 0
                $0.currentTrack = nil
                $0.currentIndex = -1
                $0.error = nil
            }
            await audio.stop()
            telemetryStop()
            return
        }

        sessionId += 1
        let mySession = sessionId
        let nextTrack = state.queue[nextIndex!]

        // Optimistic synchronous UI update.
        mutate {
            $0.currentTrack = nextTrack
            $0.currentIndex = nextIndex!
            $0.positionMs = 0
            $0.durationMs = nextTrack.durationMs
            $0.status = .loading
            $0.error = nil
        }
        telemetryStartTrack(nextTrack, state.playbackContext)

        do {
            try await audio.loadAndPlay(nextTrack, startPositionMs: 0)
            mutate { $0.status = .playing }
        } catch {
            handlePlaybackError(trackId: nextTrack.id, message: "\(error)")
            return
        }

        if nextIndex! == state.queue.count - 1 {
            scheduleAppendSimilarTracks(session: mySession, seedTrackId: nextTrack.id)
        }
    }

    public func skipPrevious() async {
        guard !state.queue.isEmpty else { return }

        // >3s → restart; <3s → go to previous.
        if state.positionMs > 3000 {
            seek(positionMs: 0)
            return
        }

        let prevIndex: Int
        if state.currentIndex > 0 { prevIndex = state.currentIndex - 1 }
        else if state.repeatMode == .all { prevIndex = state.queue.count - 1 }
        else { prevIndex = 0 }

        sessionId += 1
        let mySession = sessionId
        let prevTrack = state.queue[prevIndex]

        mutate {
            $0.currentTrack = prevTrack
            $0.currentIndex = prevIndex
            $0.positionMs = 0
            $0.durationMs = prevTrack.durationMs
            $0.status = .loading
            $0.error = nil
        }
        telemetryStartTrack(prevTrack, state.playbackContext)

        do {
            try await audio.loadAndPlay(prevTrack, startPositionMs: 0)
            mutate { $0.status = .playing }
        } catch {
            handlePlaybackError(trackId: prevTrack.id, message: "\(error)")
        }

        if prevIndex == state.queue.count - 1 {
            scheduleAppendSimilarTracks(session: mySession, seedTrackId: prevTrack.id)
        }
    }

    // MARK: - Settings + mutators

    public func setVolume(_ volume: Double) {
        let clamped = max(0, min(1, volume))
        mutate { $0.volume = clamped }
        Task { await audio.setVolume(clamped) }
    }

    public func setPlaybackRate(_ rate: Double) async {
        let clamped = max(0.5, min(2.0, (rate * 100).rounded() / 100))
        let linked = state.isPitchLinked
        mutate { $0.playbackRate = clamped }
        let semitones = 12 * log2(clamped)
        mutate { $0.pitchSemitones = semitones }
        await audio.setPlaybackRate(clamped, preservePitch: !linked)
    }

    public func setPitchSemitones(_ semitones: Double) async {
        let clamped = max(-12, min(12, (semitones * 10).rounded() / 10))
        let linked = state.isPitchLinked
        mutate { $0.pitchSemitones = clamped }
        if linked {
            let rate = max(0.5, min(2.0, pow(2, clamped / 12)))
            mutate { $0.playbackRate = rate }
            await audio.setPlaybackRate(rate, preservePitch: !linked)
        } else {
            await audio.setPlaybackRate(state.playbackRate, preservePitch: true)
        }
    }

    public func setIsPitchLinked(_ linked: Bool) async {
        mutate { $0.isPitchLinked = linked }
        if linked {
            let rate = state.playbackRate
            mutate { $0.pitchSemitones = 12 * log2(rate) }
        }
        await applyPlaybackParams()
    }

    public func setKeepSpeedAcrossTracks(_ keep: Bool) { mutate { $0.keepSpeedAcrossTracks = keep } }
    public func setAutoplaySimilar(_ value: Bool) { mutate { $0.autoplaySimilar = value } }
    public func setAudioQuality(_ quality: AudioQuality) { mutate { $0.audioQuality = quality } }
    public func setRepeat(_ mode: RepeatMode) { mutate { $0.repeatMode = mode } }
    public func setFullscreen(_ value: Bool) { mutate { $0.isFullscreen = value } }

    public func resetSpeedAndPitch() async {
        mutate {
            $0.playbackRate = 1.0
            $0.pitchSemitones = 0.0
            $0.isReverbEnabled = false
            $0.reverbLevel = 0.35
        }
        await applyPlaybackParams()
    }

    public func setIsReverbEnabled(_ enabled: Bool) async {
        mutate { $0.isReverbEnabled = enabled }
        await applyPlaybackParams()
    }

    public func setReverbLevel(_ level: Double) async {
        mutate { $0.reverbLevel = max(0, min(1, level)) }
        await applyPlaybackParams()
    }

    private func applyPlaybackParams() async {
        await audio.applyPitch(
            semitones: state.pitchSemitones,
            linked: state.isPitchLinked,
            reverb: state.isReverbEnabled,
            reverbLevel: state.reverbLevel
        )
    }

    // MARK: - Seeking

    public func seek(positionMs: Int, autoPlay: Bool = false) {
        let duration = state.durationMs != 0 ? state.durationMs : (state.currentTrack?.durationMs ?? 0)
        let nextMs = max(0, min(duration != 0 ? duration : positionMs, positionMs))
        if nextMs < state.positionMs - 3000 { telemetryRecordSeekBackward() }

        mutate { $0.positionMs = nextMs }

        guard let track = state.currentTrack else { return }
        Task {
            let hasSource = await audio.hasLoadedSourceFor(track.id)
            if !hasSource {
                let ctid = await audio.currentTrackId
                if ctid == track.id && self.state.status == .loading {
                    await audio.seek(positionMs: nextMs)
                    return
                }
                if autoPlay || self.state.status == .playing {
                    do { try await audio.loadAndPlay(track, startPositionMs: nextMs) }
                    catch { self.handlePlaybackError(trackId: track.id, message: "\(error)") }
                }
                return
            }
            await audio.seek(positionMs: nextMs)
            if autoPlay && self.state.status != .playing {
                await self.resume()
            }
        }
    }

    public func seekAndPlay(positionMs: Int) { seek(positionMs: positionMs, autoPlay: true) }

    // MARK: - Queue mutators

    public func addToQueue(_ track: Track) {
        mutate {
            $0.queue.append(track)
            if !self.masterPlaylist.isEmpty { self.masterPlaylist.append(track) }
            if self.state.shuffle { self.originalUpcomingQueue.append(track) }
        }
        preloadNextTrack()
    }

    public func playNext(_ track: Track) {
        let ci = state.currentIndex
        guard state.queue.indices.contains(ci) else {
            Task { await playTrack(track, queue: [track]) }
            return
        }
        mutate {
            $0.queue = Array($0.queue[0...ci]) + [track] + Array($0.queue[(ci + 1)...])
            if !self.masterPlaylist.isEmpty {
                if let ct = $0.currentTrack, let mi = self.masterPlaylist.firstIndex(where: { $0.id == ct.id }) {
                    self.masterPlaylist.insert(track, at: mi + 1)
                } else { self.masterPlaylist.append(track) }
            }
            if self.state.shuffle { self.originalUpcomingQueue.insert(track, at: 0) }
        }
        preloadNextTrack()
    }

    public func clearQueue() {
        mutate {
            if let ct = $0.currentTrack { $0.queue = [ct]; $0.currentIndex = 0 }
            else {
                $0.queue = []
                $0.currentIndex = -1
                $0.currentTrack = nil
            }
            $0.playbackContext = nil
            $0.playbackContextCover = nil
        }
        masterPlaylist = []
        originalUpcomingQueue = []
    }

    public func reorderQueue(from: Int, to: Int) {
        var queue = state.queue
        guard queue.indices.contains(from), queue.indices.contains(to), from != to else { return }
        let moved = queue.remove(at: from)
        queue.insert(moved, at: to)

        var newCurrent = state.currentIndex
        if state.currentIndex == from { newCurrent = to }
        else if from < state.currentIndex && to >= state.currentIndex { newCurrent -= 1 }
        else if from > state.currentIndex && to <= state.currentIndex { newCurrent += 1 }

        mutate {
            $0.queue = queue
            if newCurrent != $0.currentIndex { $0.currentIndex = newCurrent }
        }
        preloadNextTrack()
    }

    public func snapshotQueue() -> [Track] { state.queue }

     // MARK: - Error recovery (mirrors handlePlaybackError)

    public func handlePlaybackError(trackId: String, message: String) {
        guard state.currentTrack?.id == trackId else { return } // stale error
        consecutiveAutoSkips += 1

        if consecutiveAutoSkips > config.maxConsecutiveAutoSkips {
            mutate {
                $0.status = .idle
                $0.positionMs = 0
                $0.durationMs = 0
                $0.currentTrack = nil
                $0.currentIndex = -1
                $0.error = nil
            }
            Task { await audio.stop() }
            telemetryStop()
            delegate?.enginePlaybackError(trackId: trackId, message: message)
            consecutiveAutoSkips = 0
            return
        }

        delegate?.enginePlaybackError(trackId: trackId, message: message)
        Task { await skipNext(isAutoEnd: false) }
    }

    // MARK: - Telemetry (mirrors PlaybackTelemetryTracker)

    private func telemetryStartTrack(_ track: Track, _ context: String?) {
        currentTrackIdForTelemetry = track.id
        analytics.report(.init(trackId: track.id, type: .started, positionMs: 0, context: nil))
    }

    private func telemetryStop() {
        guard let id = currentTrackIdForTelemetry else { return }
        analytics.report(.init(trackId: id, type: .paused, positionMs: 0, context: nil))
        currentTrackIdForTelemetry = nil
    }

    private func telemetryRecordSeekBackward() {
        analytics.report(.init(trackId: currentTrackIdForTelemetry ?? "", type: .skippedPrevious, positionMs: 0, context: nil))
    }

    // MARK: - Helpers (ported from desktop playerEngine)

    private func normalizeQueue(_ queue: [Track], _ selected: Track) -> [Track] {
        queue.isEmpty ? [selected] : queue.map {
            Track(
                id: $0.id, title: $0.title, artists: $0.artists,
                durationMs: $0.durationMs,
                coverUrl: $0.coverUrl ?? selected.coverUrl,
                playCount: $0.playCount, artistId: $0.artistId,
                artistList: $0.artistList, explicit: $0.explicit,
                releaseDate: $0.releaseDate, album: $0.album
            )
        }
    }

    private func computeNextIndex(isAutoEnd: Bool) -> Int? {
        let size = state.queue.count
        guard size > 0, state.currentIndex >= 0 else { return nil }
        if isAutoEnd && state.repeatMode == .one { return state.currentIndex }
        if state.currentIndex + 1 < size { return state.currentIndex + 1 }
        if state.repeatMode == .all || state.repeatMode == .one { return 0 }
        return nil
    }

    private func scheduleAppendSimilarTracks(session: Int64, seedTrackId: String) {
        radioAppendTask?.cancel()
        guard config.autoplaySimilar else { return }
        let currentSession = sessionId
        guard session == currentSession else { return }
        let delayNs = UInt64(config.radioAppendDelayMs) * 1_000_000
        radioAppendTask = Task {
            try? await Task.sleep(nanoseconds: delayNs)
            await appendSimilarTracksForSeed(session: session, seedTrackId: seedTrackId)
        }
    }

    private func appendSimilarTracksForSeed(session: Int64, seedTrackId: String) async {
        guard state.autoplaySimilar else { return }
        guard sessionId == session else { return }
        let waveId = self.radioWaveId ?? newRadioWaveId()
        self.radioWaveId = waveId
        let historyIds = state.queue.map { $0.id }

        guard let provider = radioProvider else { return }
        do {
            let additions = try await provider(seedTrackId, RadioOptions(history: historyIds, k: config.radioBatchSize, waveId: waveId))
            let state2 = self.state
            guard sessionId == session, state2.autoplaySimilar else { return }
            let queuedIds = Set(state2.queue.map { $0.id })
            let fresh = additions.filter { !queuedIds.contains($0.id) }
            guard !fresh.isEmpty else { return }
            mutate { $0.queue = state2.queue + fresh }
            preloadNextTrack()
        } catch { log("similar tracks fetch failed: \(error)") }
    }

    private func fetchRadio(seedTrackId: String, waveId: String, history: [String], session: Int64) async throws -> [Track] {
        guard let provider = radioProvider else { return [] }
        guard sessionId == session else { return [] }
        return try await provider(seedTrackId, RadioOptions(history: history, k: config.radioBatchSize, waveId: waveId))
    }

    /// Preload strictly ONE next track (mirrors desktop preloadNextTrack).
    private func preloadNextTrack() {
        let store = state
        var nextTrack: Track?
        if store.currentIndex >= 0 && store.currentIndex < store.queue.count - 1 {
            nextTrack = store.queue[store.currentIndex + 1]
        } else if store.repeatMode == .all && !store.queue.isEmpty {
            nextTrack = store.queue[0]
        }
        guard let track = nextTrack else {
            lastPreloadKey = nil
            return
        }

        let currentId = store.currentTrack?.id ?? "none"
        let key = "\(currentId)->\(track.id)"
        if lastPreloadKey == key { return }
        lastPreloadKey = key

        delegate?.engineSetPlaybackContextCover(track.coverUrl)
        Task { await audio.preloadTrack(track) }
    }

    private func shuffle<T>(_ array: [T]) -> [T] {
        var result = array
        for i in stride(from: result.count - 1, through: 1, by: -1) {
            result.swapAt(i, Int.random(in: 0...i))
        }
        return result
    }

    private func restoreOriginalRelativeOrder<T: Identifiable>(_ upcoming: [T], against reference: [T]) -> [T] {
        guard !reference.isEmpty else { return upcoming }
        let originalPos: [T.ID: Int] = Dictionary(uniqueKeysWithValues: reference.enumerated().map { ($0.element.id, $0.offset) })
        return upcoming.sorted { originalPos[$0.id] ?? .max < originalPos[$1.id] ?? .max }
    }

    private func newRadioWaveId() -> String { "wave-\(UUID().uuidString)" }

    private func log(_ message: String) {
        #if DEBUG
        print("[Linerale.Playback] \(message)")
        #endif
    }
}
