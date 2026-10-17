import AVFoundation
import Foundation
import LineraleData
import LineraleDomain
import LineralePlayback
import LineraleUI
import MediaPlayer
import SwiftUI
import UIKit

/// Bridges `AudioRuntime` events back into `PlaybackEngine`, and fan-out engine
/// state changes into the iOS Now Playing (lock screen / Control Center) surface.
@MainActor
final class PlaybackCoordinator: ObservableObject {
    let engine: PlaybackEngine
    private let runtime: AudioRuntime
    private let nowPlaying: NowPlayingManager

    init(api: APIClient, cache: LocalAudioCache) {
        self.runtime = AudioRuntime(api: api, cache: cache)
        self.engine = PlaybackEngine(
            audio: runtime,
            analytics: PlaybackAnalytics(),
            config: PlaybackEngineConfig(maxConsecutiveAutoSkips: 3, autoplaySimilar: true)
        )
        self.nowPlaying = NowPlayingManager()
        self.runtime.delegate = self
        self.engine.delegate = self
        self.nowPlaying.attach(to: engine)
    }
}

extension PlaybackCoordinator: AudioRuntimeDelegate {
    func runtimePlaybackStarted(trackId: String?, metrics: PlaybackMetrics?) {
        if let track = engine.state.currentTrack {
            nowPlaying.publish(track: track, status: engine.state.status,
                               position: engine.state.positionMs, duration: engine.state.durationMs)
        }
    }

    func runtimePlaybackEnded(trackId: String?) {
        // Auto-advance honoring repeat/shuffle (mirrors desktop track-end).
        Task { await engine.skipNext(isAutoEnd: true) }
    }

    func runtimeError(trackId: String?, message: String) {
        engine.handlePlaybackError(trackId: trackId ?? "", message: message)
    }

    func runtimeSetPlaybackContext(_ context: String?) {}
}

extension PlaybackCoordinator: PlaybackEngineDelegate {
    func enginePlaybackStarted(track: Track, metrics: PlaybackMetrics?) {
        if let track {
            nowPlaying.publish(track: track, status: engine.state.status,
                               position: engine.state.positionMs, duration: engine.state.durationMs)
        }
    }

    func enginePlaybackCompleted(trackId: String, repeatOne: Bool) {
        nowPlaying.publish(track: nil, status: .idle, position: 0, duration: 0)
    }

    func enginePlaybackError(trackId: String, message: String) {
        nowPlaying.publish(track: nil, status: .error, position: 0, duration: 0)
    }

    func engineSetPlaybackContext(_ context: String?) {}
    func engineSetPlaybackContextCover(_ cover: String?) {
        if let cover { nowPlaying.setCoverURL(cover) }
    }
}

// MARK: - Now Playing bridge (MediaPlayer; stable in iOS 27)

/// Wraps `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter`. The desktop app
/// exposes equivalent controls via `navigator.mediaSession`; on iOS the system
/// Now Playing surface is driven through `MediaPlayer`.
@MainActor
final class NowPlayingManager {
    private let infoCenter: MPNowPlayingInfoCenter
    private let commandCenter: MPRemoteCommandCenter
    private weak var engine: PlaybackEngine?

    init() {
        self.infoCenter = MPNowPlayingInfoCenter.default()
        self.commandCenter = MPRemoteCommandCenter.default()
        commandCenter.playCommand.addTarget { [weak self] in
            Task { await self?.engine?.resume() }
        }
        commandCenter.pauseCommand.addTarget { [weak self] in
            Task { await self?.engine?.pause() }
        }
        commandCenter.nextTrackCommand.addTarget { [weak self] in
            Task { await self?.engine?.dispatch(.skipNext(isAutoEnd: false)) }
        }
        commandCenter.previousTrackCommand.addTarget { [weak self] in
            Task { await self?.engine?.skipPrevious() }
        }
    }

    func attach(to engine: PlaybackEngine) {
        self.engine = engine
    }

    func publish(track: Track?, status: PlayerStatus, position: Int, duration: Int) {
        guard let track else {
            infoCenter.nowPlayingInfo = nil
            return
        }
        infoCenter.nowPlayingInfo = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artists,
            MPMediaItemPropertyPlaybackDuration: Double(duration) / 1000.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(position) / 1000.0,
            MPNowPlayingInfoPropertyPlaybackRate: status == .playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyPlaybackState: status == .playing ? 1 : 0,
        ] as [String: Any]
    }

    func setCoverURL(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let image = UIImage(data: data) {
                    var info = infoCenter.nowPlayingInfo ?? [:]
                    info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(image: image)
                    infoCenter.nowPlayingInfo = info
                }
            } catch { /* art load failed; ignore */ }
        }
    }
}

// MARK: - App entry point

@main
struct Linerale: App {
    @StateObject private var coordinator: PlaybackCoordinator

    init() {
        UserDefaults.standard.set(Int(LocalAudioCache.defaultLimitBytes),
                                  forKey: "LineraleAudioCacheLimitBytes")
        let cache: LocalAudioCache = {
            do { return try LocalAudioCache() } catch {
                fatalError("Failed to initialize audio cache: \(error)")
            }
        }()
        let api = APIClient(signer: HMACRequestSigner(),
                            headers: DefaultApiHeaderProvider(session: { nil }))
        _coordinator = StateObject(wrappedValue: PlaybackCoordinator(api: api, cache: cache))
    }

    var body: some Scene {
        WindowGroup {
            LineraleRootViewHost(engine: coordinator.engine)
        }
    }
}
