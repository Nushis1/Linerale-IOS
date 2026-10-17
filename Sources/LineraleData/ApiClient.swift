public import Foundation
import CryptoKit
import LineraleDomain

/// Canonical HMAC signing result, mirroring `SignedHeaders` from
/// `desktop/src/shared/api/requestSigner.ts`.
public struct SignedHeaders: Sendable {
    public let signature: String
    public let timestamp: String
    public let nonce: String
    public init(signature: String, timestamp: String, nonce: String) {
        self.signature = signature
        self.timestamp = timestamp
        self.nonce = nonce
    }
}

/// Injectable request signer. The desktop app delegates signing to a native
/// Electron module backed by a compiled WASM blob (`electron/signer.ts`) that
/// is **not** importable on iOS; the default `HMACRequestSigner` reproduces the
/// documented header shape (`x-liner-signature` / `-timestamp` / `-nonce`) via
/// HMAC-SHA256. The exact canonical string must match the server's verifier —
/// if server-side auth rejects it, swap this dependency for a backend-held
/// signer at the composition root; no other call site changes.
public protocol RequestSigner: Sendable {
    init()
    func sign(method: String, path: String, body: String?, timestamp: Int64, nonce: String) async throws -> SignedHeaders
}

/// HMAC-SHA256 signer. Canonical request = `METHOD:path:timestamp:nonce:body`.
public final class HMACRequestSigner: RequestSigner, @unchecked Sendable {
    private let clock: @Sendable () -> Int64
    private let secret: Data

    public required init() {
        self.init(clock: { Int64(Date().timeIntervalSince1970) }, secret: Data())
    }

    public init(clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) },
                secret: Data = Data()) {
        self.clock = clock
        self.secret = secret
    }

    public func sign(method: String, path: String, body: String?, timestamp: Int64, nonce: String) async throws -> SignedHeaders {
        let cleanPath = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? path
        let method = method.uppercased().trimmingCharacters(in: .whitespaces)
        let nonce = nonce.isEmpty ? UUID().uuidString.replacingOccurrences(of: "-", with: "") : nonce
        let ts = timestamp > 0 ? timestamp : clock()
        let body = body ?? ""

        let canonical = "\(method):\(cleanPath):\(ts):\(nonce):\(body)"
        let signature = try hmacSHA256(message: canonical, key: secret)
        return SignedHeaders(signature: signature, timestamp: String(ts), nonce: nonce)
    }

    private func hmacSHA256(message: String, key: Data) throws -> String {
        guard let msgData = message.data(using: .utf8) else {
            throw ApiError(statusCode: 0, message: "HMAC message encoding failed", code: "SIGN_ERROR")
        }
        let symmetricKey = SymmetricKey(data: key)
        let mac = HMAC<SHA256>.authenticationCode(for: msgData, using: symmetricKey)
        return Data(mac).map { String(format: "%02x", $0) }.joined()
    }
}

/// Errors surfaced by the API layer.
public struct ApiError: Error, Sendable {
    public let statusCode: Int
    public let message: String
    public let code: String
    public init(statusCode: Int, message: String, code: String) {
        self.statusCode = statusCode
        self.message = message
        self.code = code
    }
}

/// Auth session handle (mirror of desktop `AuthSession`).
public struct AuthSession: Sendable {
    public let accessToken: String?
    public let user: ApiUser?
    public init(accessToken: String?, user: ApiUser?) {
        self.accessToken = accessToken
        self.user = user
    }
}

public struct ApiUser: Sendable {
    public let id: String
    public let username: String
    public init(id: String, username: String) {
        self.id = id
        self.username = username
    }
}

/// Header + auth provider matching the desktop `executeRequest` correlation flow.
public protocol ApiHeaderProvider: Sendable {
    func currentSession() -> AuthSession?
    func currentAccessToken() async -> String?
    func serverTimeOffsetMs() -> Int64
    func correlationHeaders(for requestID: String?) -> [String: String]
    func clientVersion() -> String
    func platform() -> String
}

/// Default (non-secret) header provider. Replace with Keychain-backed auth in production.
/// The injected `session` closure is nonisolated/Sendable so it can be read
/// from the synchronous `currentSession()` hook used during request building.
public final class DefaultApiHeaderProvider: ApiHeaderProvider, @unchecked Sendable {
    private let _session: @Sendable () -> AuthSession?

    public init(session: @escaping @Sendable () -> AuthSession?) {
        self._session = session
    }

    public func currentSession() -> AuthSession? { _session() }
    public func currentAccessToken() async -> String? { _session()?.accessToken }
    public func serverTimeOffsetMs() -> Int64 { 0 }
    public func correlationHeaders(for requestID: String?) -> [String: String] {
        [
            "x-request-id": requestID ?? UUID().uuidString,
            "x-client-version": clientVersion(),
            "x-platform": platform(),
        ]
    }
    public func clientVersion() -> String { "1.0.4-ios" }
    public func platform() -> String { "ios" }
}

/// Type-erased JSON value, captured so an arbitrary `body` subtree can survive a
/// decode → mutate → re-encode round trip. `@unchecked Sendable` because it is
/// never mutated across actors after construction.
public struct AnyJSON: @unchecked Sendable {
    public let value: Any
    public init(_ value: Any) { self.value = value }

    public init(from decoder: Decoder) throws {
        let container = decoder.singleValueContainer()
        if try container.decodeNil() { self.value = NSNull() }
        else if let x = try? container.decode(Bool.self) { self.value = x }
        else if let x = try? container.decode(Int64.self) { self.value = x }
        else if let x = try? container.decode(Double.self) { self.value = x }
        else if let x = try? container.decode(String.self) { self.value = x }
        else if let x = try? container.decode([AnyJSON].self) { self.value = x.map(\.value) }
        else if let x = try? container.decode([String: AnyJSON].self) {
            self.value = Dictionary(uniqueKeysWith: x.map { ($0.key, $1.value) })
        } else {
            throw DecodingError.typeMismatch(
                AnyJSON.self,
                .init(codingPath: decoder.codingPath, debugDescription: "AnyJSON: unsupported type")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let x as Bool: try container.encode(x)
        case let x as Int: try container.encode(x)
        case let x as Int64: try container.encode(x)
        case let x as Double: try container.encode(x)
        case let x as String: try container.encode(x)
        case let x as NSNull: try container.encodeNil()
        case let x as [Any]: try container.encode(x.map(AnyJSON.init))
        case let x as [String: Any]: try container.encode(Dictionary(x.mapValues(AnyJSON.init)))
        case Optional.none: try container.encodeNil()
        default: throw EncodingError.invalidValue(value, .init(codingPath: encoder.codingPath, debugDescription: "AnyJSON: unsupported type"))
        }
    }
}

// MARK: - HTTP client

/// HTTP client wrapping signed, timeout-bounded requests against
/// `https://api.tryliner.fun` (desktop `DEFAULT_PRIMARY_API`), plus the
/// direct-innertube resolver used for cache-miss playback.
public final class APIClient: @unchecked Sendable {
    public let baseURL: String
    public let signer: RequestSigner
    public let headers: ApiHeaderProvider
    public let session: URLSession
    public let timeoutMs: Int

    public init(
        baseURL: String = "https://api.tryliner.fun",
        signer: RequestSigner,
        headers: ApiHeaderProvider,
        session: URLSession = .shared,
        timeoutMs: Int = 15000
    ) {
        self.baseURL = baseURL
        self.signer = signer
        self.headers = headers
        self.session = session
        self.timeoutMs = timeoutMs
    }

    // MARK: - Playback session

    /// Mirror of `desktop/src/shared/api/api.ts:createPlaybackSession`.
    public func createPlaybackSession(
        for trackID: String,
        preferredCodec: Codec? = nil,
        transport: PlaybackTransport? = nil
    ) async throws -> PlaybackSessionResponse {
        let path = "/v1/tracks/\(trackID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? trackID)/playback"
        var requestBody: [String: String] = [:]
        if let transport { requestBody["transport"] = transport.rawValue }
        if let preferredCodec { requestBody["preferredCodec"] = preferredCodec.rawValue }
        let body = try JSONEncoder().encode(requestBody).flatMap { String(data: $0, encoding: .utf8) }
        let signed = try await signer.sign(method: "POST", path: path, body: body, timestamp: 0, nonce: UUID().uuidString)
        let req = try buildRequest(path: path, method: "POST", body: body, signed: signed)
        return try await performRequest(req, type: PlaybackSessionResponse.self)
    }

    // MARK: - Direct Innertube resolution

    /// Mirrors `resolveDirectInnertubeStream` in `playerRuntime.ts:19`: fetches
    /// the plan endpoint directly, injects a local visitor id, strips the
    /// datacenter-bound poToken, and selects the best audio format.
    public func resolveDirectInnertubeStream(
        session: PlaybackSessionResponse,
        visitorData: String = ""
    ) async throws -> ResolvedAudioStream {
        guard let endpoint = session.endpoint,
              let endpointURL = URL(string: endpoint) else {
            throw ApiError(statusCode: 0, message: "No direct_innertube endpoint", code: "NO_ENDPOINT")
        }
        let method = (session.method ?? "POST").uppercased()
        var requestHeaders = session.headers ?? [:]

        if !visitorData.isEmpty {
            requestHeaders["x-goog-visitor-id"] = visitorData
        }

        // Deserialize the captured body (arbitrary JSON) to mutate it.
        var mutableBody: [String: Any] = [:]
        if let body = session.body {
            if let dict = body.value as? [String: Any] { mutableBody = dict }
        }

        if var client = mutableBody["context"] as? [String: Any],
           var innerClient = client["client"] as? [String: Any] {
            if !visitorData.isEmpty { innerClient["visitorData"] = visitorData }
            innerClient["serviceIntegrityDimensions"] = nil
            client["client"] = innerClient
            mutableBody["context"] = client
        }

        let bodyData = try JSONSerialization.data(withJSONObject: mutableBody, options: [])
        var request = URLRequest(url: endpointURL)
        request.httpMethod = method
        request.timeoutInterval = TimeInterval(timeoutMs) / 1000.0
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in requestHeaders { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = bodyData

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ApiError(statusCode: 0, message: "No response", code: "NETWORK_ERROR")
        }
        guard (200...299).contains(http.statusCode) else {
            throw ApiError(statusCode: http.statusCode, message: "Innertube player returned HTTP \(http.statusCode)", code: "INNERTUBE_ERROR")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let playability = (json?["playabilityStatus"] as? [String: Any])?["status"] as? String
        if let playability, playability != "OK" {
            let reason = (json?["playabilityStatus"] as? [String: Any])?["reason"] as? String
                          ?? "Track not playable via direct Innertube"
            throw ApiError(statusCode: 403, message: reason, code: "PLAYABILITY_BLOCKED")
        }

        let formats = (json?["streamingData"] as? [String: Any])?["adaptiveFormats"] as? [[String: Any]] ?? []
        let audioFormats = formats.filter { fmt in
            let mimeType = fmt["mimeType"] as? String ?? ""
            return mimeType.contains("audio"), (fmt["url"] as? String) != nil
        }
        guard !audioFormats.isEmpty else {
            throw ApiError(statusCode: 0, message: "No direct audio formats returned by Innertube", code: "NO_FORMATS")
        }

        let opus = audioFormats.first { fmt in
            let mimeType = fmt["mimeType"] as? String ?? ""
            return mimeType.contains("webm") || mimeType.contains("opus")
        }
        let best = opus ?? audioFormats.max { a, b in
            let ab = a["bitrate"] as? Int ?? a["averageBitrate"] as? Int ?? 0
            let bb = b["bitrate"] as? Int ?? b["averageBitrate"] as? Int ?? 0
            return ab < bb
        }!

        let mimeTypeRaw = best["mimeType"] as? String ?? "audio/webm"
        let mimeType = mimeTypeRaw.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? "audio/webm"
        let codec: Codec = mimeType.contains("opus") ? .opus : .aac
        let bitrate = best["bitrate"] as? Int ?? best["averageBitrate"] as? Int ?? 160000
        let url = best["url"] as! String

        var expiresAt: Date?
        if let u = URL(string: url),
           let components = URLComponents(url: u, resolvingAgainstBaseURL: false),
           let expire = components.queryItems?.first(where: { $0.name == "expire" })?.value,
           let expMs = TimeInterval(expire) {
            expiresAt = Date(timeIntervalSince1970: expMs)
        }

        return ResolvedAudioStream(url: url, mimeType: mimeType, codec: codec, bitrate: bitrate, expiresAt: expiresAt)
    }

    // MARK: - Request building (private)

    private func buildRequest(
        path: String,
        method: String,
        body: String?,
        signed: SignedHeaders
    ) throws -> URLRequest {
        let url = URL(string: baseURL + path)!
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = TimeInterval(timeoutMs) / 1000.0

        var headerFields: [String: String] = [:]
        if body != nil { headerFields["Content-Type"] = "application/json" }
        headerFields["x-liner-signature"] = signed.signature
        headerFields["x-liner-timestamp"] = signed.timestamp
        headerFields["x-liner-nonce"] = signed.nonce

        // Auth + correlation headers from the injected provider (synchronous session).
        if let session = headers.currentSession() {
            if let token = session.accessToken { headerFields["Authorization"] = "Bearer \(token)" }
            if let user = session.user {
                headerFields["x-user-id"] = user.id
                headerFields["x-user-name"] = user.username
            }
        }
        headerFields.merge(headers.correlationHeaders(nil)) { current, _ in current }

        for (field, value) in headerFields { request.setValue(value, forHTTPHeaderField: field) }
        if let body, let bodyData = body.data(using: .utf8) { request.httpBody = bodyData }
        return request
    }

    private func performRequest<T: Decodable>(_ request: URLRequest, type: T.Type) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ApiError(statusCode: 0, message: "No response", code: "NETWORK_ERROR")
        }
        guard (200...299).contains(http.statusCode) else {
            throw ApiError(statusCode: http.statusCode, message: "HTTP \(http.statusCode)", code: "HTTP_ERROR")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }
}

// MARK: - Wire shape (mirrors `desktop/src/shared/contracts/playback.ts`)

/// `body` is captured as `AnyJSON` because the Innertube plan body contains
/// nested objects (`context.client.*`) that a flat `[String: String]` cannot hold.
public struct PlaybackSessionResponse: Codable, Sendable {
    public let sessionId: String?
    public let trackId: String?
    public let streamUrl: String?
    public let codec: Codec?
    public let bitrate: Int?
    public let mimeType: String?
    public let expiresAt: Date?
    public let transport: PlaybackTransport?
    public let playbackId: String?
    public let videoId: String?
    public let endpoint: String?
    public let method: String?
    public let headers: [String: String]?
    public let body: AnyJSON?

    public init(
        sessionId: String? = nil,
        trackId: String? = nil,
        streamUrl: String? = nil,
        codec: Codec? = nil,
        bitrate: Int? = nil,
        mimeType: String? = nil,
        expiresAt: Date? = nil,
        transport: PlaybackTransport? = nil,
        playbackId: String? = nil,
        videoId: String? = nil,
        endpoint: String? = nil,
        method: String? = nil,
        headers: [String: String]? = nil,
        body: AnyJSON? = nil
    ) {
        self.sessionId = sessionId
        self.trackId = trackId
        self.streamUrl = streamUrl
        self.codec = codec
        self.bitrate = bitrate
        self.mimeType = mimeType
        self.expiresAt = expiresAt
        self.transport = transport
        self.playbackId = playbackId
        self.videoId = videoId
        self.endpoint = endpoint
        self.method = method
        self.headers = headers
        self.body = body
    }

    enum CodingKeys: String, CodingKey {
        case sessionId, trackId, streamUrl, codec, bitrate, mimeType, expiresAt
        case transport, playbackId, videoId, endpoint, method, headers, body
    }
}
