public import SwiftUI
import LineraleDomain

/// Minimal UI shell: a library list stub with a persistent player mini-bar
/// bound to `PlaybackEngine.state`. Extended by LineraleUI screens once the
/// data-layer fetchers are wired.
@MainActor
struct LineraleRootView: View {
    @ObservedObject var engine: PlaybackEngine

    init(engine: PlaybackEngine) {
        self.engine = engine
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("Library")
                    .font(.title2).bold()
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer()
                playerBar
            }
            .toolbar {
                Button(engine.state.status == .playing ? "Pause" : "Play") {
                    Task { await engine.togglePlayPause() }
                }
            }
        }
        .ignoresSafeArea(.keyboard)
    }

    @ViewBuilder
    private var playerBar: some View {
        if let track = engine.state.currentTrack {
            HStack {
                Text(track.title)
                Spacer()
                Text(track.artists)
                Button(engine.state.status == .playing ? "Pause" : "Play") {
                    Task { await engine.togglePlayPause() }
                }
            }
            .padding(.horizontal)
            .frame(height: 64)
            .background(.ultraThinMaterial)
        }
    }
}

/// Public entry so the App host can construct the root view with the engine.
@MainActor
public struct LineraleRootViewHost: View {
    private let engine: PlaybackEngine

    public init(engine: PlaybackEngine) {
        self.engine = engine
    }

    public var body: some View {
        LineraleRootView(engine: engine)
    }
}
