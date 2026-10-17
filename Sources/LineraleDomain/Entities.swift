public import Foundation

// MARK: - Audio & Playback primitives

public enum RepeatMode: String, Codable, CaseIterable, Equatable, Sendable {
    case off
    case all
    case one
}

public enum PlayerStatus: String, Codable, Equatable, Sendable {
    case idle
    case loading
    case playing
    case paused
    case error
}

public enum PlaybackTransport: String, Codable, Sendable {
    case proxy
    case directInnertube = "direct_innertube"
}

public enum AudioQuality: String, Codable, Equatable, Sendable {
    case low, standard, high, lossless
}

public enum Codec: String, Codable, Equatable, Sendable {
    case opus
    case aac
}

public struct PlaybackContext: Codable, Sendable, Hashable {
    public let type: String
    public let id: String?
    public init(type: String, id: String? = nil) {
        self.type = type
        self.id = id
    }
}

// MARK: - Core entities (mirror @desktop/src/shared/types + contracts)

public struct Artist: Codable, Sendable, Hashable {
    public let id: String
    public let name: String
    public init(id: String = "", name: String) {
        self.id = id
        self.name = name
    }
}

public struct Album: Codable, Sendable, Hashable {
    public let id: String
    public let title: String
    public init(id: String = "", title: String) {
        self.id = id
        self.title = title
    }
}

public struct Track: Codable, Sendable, Hashable {
    public let id: String
    public let title: String
    public let artists: String
    public let durationMs: Int
    public let coverUrl: String?
    public let playCount: Int
    public let artistId: String?
    public let artistList: [Artist]?
    public let explicit: Bool?
    public let releaseDate: String?
    public let album: Album?

    public init(
        id: String,
        title: String,
        artists: String,
        durationMs: Int = 0,
        coverUrl: String? = nil,
        playCount: Int = 0,
        artistId: String? = nil,
        artistList: [Artist]? = nil,
        explicit: Bool? = nil,
        releaseDate: String? = nil,
        album: Album? = nil
    ) {
        self.id = id
        self.title = title
        self.artists = artists
        self.durationMs = durationMs
        self.coverUrl = coverUrl
        self.playCount = playCount
        self.artistId = artistId
        self.artistList = artistList
        self.explicit = explicit
        self.releaseDate = releaseDate
        self.album = album
    }
}

// MARK: - Radio options (mirrors RadioOptions)

public struct RadioOptions: Sendable {
    public let history: [String]
    public let k: Int
    public let waveId: String
    public init(history: [String] = [], k: Int = 20, waveId: String = "") {
        self.history = history
        self.k = k
        self.waveId = waveId
    }
}

// MARK: Playback session model (mirrors PlaybackSessionResponse)

public struct PlaybackSession: Codable, Sendable {
    public let sessionId: String?
    public let trackId: String?
    public let streamUrl: String?
    public let transport: PlaybackTransport?
    public let codec: Codec?
    public let bitrate: Int?
    public let mimeType: String?
    public let expiresAt: Date?
    /// direct_innertube plan fields
    public let endpoint: String?
    public let method: String?
    public let headers: [String: String]?
    public let body: [String: String]?

    public init(
        sessionId: String? = nil,
        trackId: String? = nil,
        streamUrl: String? = nil,
        transport: PlaybackTransport? = .proxy,
        codec: Codec? = nil,
        bitrate: Int? = nil,
        mimeType: String? = nil,
        expiresAt: Date? = nil,
        endpoint: String? = nil,
        method: String? = nil,
        headers: [String: String]? = nil,
        body: [String: String]? = nil
    ) {
        self.sessionId = sessionId
        self.trackId = trackId
        self.streamUrl = streamUrl
        self.transport = transport
        self.codec = codec
        self.bitrate = bitrate
        self.mimeType = mimeType
        self.expiresAt = expiresAt
        self.endpoint = endpoint
        self.method = method
        self.headers = headers
        self.body = body
    }
}

// MARK: - Resolved audio stream (mirrors ResolvedAudioStream)

public struct ResolvedAudioStream: Sendable {
    public let url: String
    public let mimeType: String
    public let codec: Codec
    public let bitrate: Int
    public let expiresAt: Date?
    public init(url: String, mimeType: String, codec: Codec, bitrate: Int, expiresAt: Date?) {
        self.url = url
        self.mimeType = mimeType
        self.codec = codec
        self.bitrate = bitrate
        self.expiresAt = expiresAt
    }
}

// MARK: - Library / Playlist records

public struct PlaylistSummary: Codable, Sendable, Hashable {
    public let id: String
    public let title: String
    public let trackCount: Int
    public let durationMs: Int
    public let coverUrl: String?
    public let updatedAt: Date
    public init(id: String, title: String, trackCount: Int, durationMs: Int, coverUrl: String?, updatedAt: Date) {
        self.id = id; self.title = title; self.trackCount = trackCount
        self.durationMs = durationMs; self.coverUrl = coverUrl; self.updatedAt = updatedAt
    }
}

public struct Playlist: Codable, Sendable, Hashable {
    public let id: String
    public let title: String
    public let isOwned: Bool
    public var tracks: [Track]
    public init(id: String, title: String, isOwned: Bool, tracks: [Track]) {
        self.id = id; self.title = title; self.isOwned = isOwned; self.tracks = tracks
    }
}

// MARK: - Playback state (mirrors playerStore playerState shape)

public struct PlaybackMetrics: Equatable, Sendable {
    public let ttfbMs: Int
    public let audioStartLatencyMs: Int
    public init(ttfbMs: Int, audioStartLatencyMs: Int) {
        self.ttfbMs = ttfbMs; self.audioStartLatencyMs = audioStartLatencyMs
    }
}

public struct PlaybackState: Equatable, Sendable {
    public var status: PlayerStatus
    public var queue: [Track]
    public var currentIndex: Int
    public var currentTrack: Track?
    public var positionMs: Int
    public var durationMs: Int
    public var repeatMode: RepeatMode
    public var shuffle: Bool
    public var volume: Double
    public var error: String?
    public var playbackContext: String?
    public var playbackContextCover: String?
    public var audioQuality: AudioQuality
    public var autoplaySimilar: Bool
    public var currentMetrics: PlaybackMetrics?
    public var playbackRate: Double
    public var pitchSemitones: Double
    public var isPitchLinked: Bool
    public var keepSpeedAcrossTracks: Bool
    public var isReverbEnabled: Bool
    public var reverbLevel: Double
    public var isFullscreen: Bool

    public init(
        status: PlayerStatus = .idle,
        queue: [Track] = [],
        currentIndex: Int = -1,
        currentTrack: Track? = nil,
        positionMs: Int = 0,
        durationMs: Int = 0,
        repeatMode: RepeatMode = .off,
        shuffle: Bool = false,
        volume: Double = 1.0,
        error: String? = nil,
        playbackContext: String? = nil,
        playbackContextCover: String? = nil,
        audioQuality: AudioQuality = .high,
        autoplaySimilar: Bool = true,
        currentMetrics: PlaybackMetrics? = nil,
        playbackRate: Double = 1.0,
        pitchSemitones: Double = 0.0,
        isPitchLinked: Bool = true,
        keepSpeedAcrossTracks: Bool = true,
        isReverbEnabled: Bool = false,
        reverbLevel: Double = 0.35,
        isFullscreen: Bool = false
    ) {
        self.status = status
        self.queue = queue
        self.currentIndex = currentIndex
        self.currentTrack = currentTrack
        self.positionMs = positionMs
        self.durationMs = durationMs
        self.repeatMode = repeatMode
        self.shuffle = shuffle
        self.volume = volume
        self.error = error
        self.playbackContext = playbackContext
        self.playbackContextCover = playbackContextCover
        self.audioQuality = audioQuality
        self.autoplaySimilar = autoplaySimilar
        self.currentMetrics = currentMetrics
        self.playbackRate = playbackRate
        self.pitchSemitones = pitchSemitones
        self.isPitchLinked = isPitchLinked
        self.keepSpeedAcrossTracks = keepSpeedAcrossTracks
        self.isReverbEnabled = isReverbEnabled
        self.reverbLevel = reverbLevel
        self.isFullscreen = isFullscreen
    }
}

// MARK: - Commands (mirrors PlayerCommand)

public enum PlayerCommand: Sendable {
    case play(PlayRequest)
    case pause
    case resume
    case seek(positionMs: Int)
    case skipNext(isAutoEnd: Bool)
    case skipPrevious
    case setVolume(Double)
    case setPlaybackRate(Double)
    case setPitch(Double)
    case togglePlayPause
}

public struct PlayRequest: Sendable {
    public let track: Track
    public let queue: [Track]?
    public let context: String?
    public let contextCover: String?
    public let queueIndex: Int?
    public let preserveQueue: Bool

    public init(
        track: Track,
        queue: [Track]? = nil,
        context: String? = nil,
        contextCover: String? = nil,
        queueIndex: Int? = nil,
        preserveQueue: Bool = false
    ) {
        self.track = track
        self.queue = queue
        self.context = context
        self.contextCover = contextCover
        self.queueIndex = queueIndex
        self.preserveQueue = preserveQueue
    }
}

// MARK: - Telemetry event (mirrors RecordPlaybackEventRequest)

public enum PlaybackEventType: String, Codable, Sendable {
    case started
    case paused
    case resumed
    case skippedNext
    case skippedPrevious
    case completed
    case error
}

public struct PlaybackEvent: Codable, Sendable {
    public let trackId: String
    public let type: PlaybackEventType
    public let playedDurationMs: Int
    public let positionMs: Int
    public let context: PlaybackContext?
    public init(
        trackId: String,
        type: PlaybackEventType,
        playedDurationMs: Int = 0,
        positionMs: Int = 0,
        context: PlaybackContext? = nil
    ) {
        self.trackId = trackId; self.type = type
        self.playedDurationMs = playedDurationMs; self.positionMs = positionMs
        self.context = context
    }
}
