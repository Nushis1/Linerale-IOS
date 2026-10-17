import Foundation
import Testing
import LineraleDomain

/// Mock of `AudioRuntimeControlling` that records loads/stops without touching AV.
private final class MockAudioRuntime: AudioRuntimeControlling, @unchecked Sendable {
    private var _currentTrackId: String?
    private(set) var loaded: [String] = []
    private(set) var stopped = false
    private(set) var cancelled = false

    var currentTrackIdSnapshot: String? { _currentTrackId }
    var currentTrackId: String? {
        get async { _currentTrackId }
    }

    func loadAndPlay(_ track: Track, startPositionMs: Int) async throws {
        loaded.append(track.id)
        _currentTrackId = track.id
    }
    func preloadTrack(_ track: Track) async {}
    func pause() async {}
    func resume() async {}
    func seek(positionMs: Int) async {}
    func cancelPendingLoad() async { cancelled = true }
    func stop() async { stopped = true }
    func setVolume(_ gain: Double) async {}
    func setPlaybackRate(_ rate: Double, preservePitch: Bool) async {}
    func applyPitch(semitones: Double, linked: Bool, reverb: Bool, reverbLevel: Double) async {}
    func hasLoadedSourceFor(_ trackId: String) async -> Bool { true }
}

private func track(_ id: String, _ title: String = "") -> Track {
    Track(id: id, title: title.isEmpty ? id : title, artists: "Artist", durationMs: 180_000)
}

@MainActor
private func makeEngine(mock: MockAudioRuntime, config: PlaybackEngineConfig = .init()) -> PlaybackEngine {
    PlaybackEngine(audio: mock, analytics: PlaybackAnalytics(), config: config)
}

struct PlaybackEngineTests {

    @Test("repeat.one on auto-end restarts the same track (no advance, reload)")
    func repeatOneAutoEndRestartsCurrent() async throws {
        let mock = MockAudioRuntime()
        let engine = await MainActor.run { makeEngine(mock: mock) }
        await MainActor.run { engine.setRepeat(.one) }

        let items = [track("a"), track("b"), track("c")]
        await engine.playTrack(items[0], queue: items)
        let idx = await MainActor.run { engine.state.currentIndex }
        #expect(idx == 0)

        await engine.skipNext(isAutoEnd: true)

        let (tid, i, status) = await MainActor.run {
            (engine.state.currentTrack?.id, engine.state.currentIndex, engine.state.status)
        }
        #expect(tid == "a")
        #expect(i == 0)
        #expect(status == .playing)
        #expect(mock.loaded.count == 2)
        #expect(mock.loaded.last == "a")
    }

    @Test("repeat.off at the final track auto-end stops and clears the index")
    func repeatOffAutoEndAtLastStops() async throws {
        let mock = MockAudioRuntime()
        let engine = await MainActor.run { makeEngine(mock: mock) }
        await MainActor.run { engine.setRepeat(.off) }

        let items = [track("a"), track("b")]
        await engine.playTrack(items[1], queue: items, queueIndex: 1)
        let idx = await MainActor.run { engine.state.currentIndex }
        #expect(idx == 1)

        await engine.skipNext(isAutoEnd: true)

        let (status, i, current, stopped) = await MainActor.run {
            (engine.state.status, engine.state.currentIndex, engine.state.currentTrack, mock.stopped)
        }
        #expect(status == .idle)
        #expect(i == -1)
        #expect(current == nil)
        #expect(stopped)
    }

    @Test("repeat.all at the final track auto-end wraps to index 0")
    func repeatAllAutoEndWrapsToStart() async throws {
        let mock = MockAudioRuntime()
        let engine = await MainActor.run { makeEngine(mock: mock) }
        await MainActor.run { engine.setRepeat(.all) }

        let items = [track("a"), track("b")]
        await engine.playTrack(items[1], queue: items, queueIndex: 1)
        let idx = await MainActor.run { engine.state.currentIndex }
        #expect(idx == 1)

        await engine.skipNext(isAutoEnd: true)

        let (tid, i, status) = await MainActor.run {
            (engine.state.currentTrack?.id, engine.state.currentIndex, engine.state.status)
        }
        #expect(tid == "a")
        #expect(i == 0)
        #expect(status == .playing)
    }
}
