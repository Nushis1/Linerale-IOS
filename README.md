# Linerale (iOS)

Linerale is a Swift 6 / iOS 27 music player for iOS, built on a multi-module Swift
Package Manager workspace. It resolves audio from direct Innertube streams, caches it
locally with an LRU policy, and plays it back through AVFoundation with a stateful
queue engine.

## Requirements

| Tool   | Minimum      |
| ------ | ------------ |
| Xcode  | 27.2         |
| Swift  | 6.4          |
| iOS    | 27.0 (GA)    |

## Project layout

| Path                         | Contents                                                                                           |
| ---------------------------- | -------------------------------------------------------------------------------------------------- |
| `Package.swift`              | SPM manifest: `LineraleDomain` -> `LineraleData` -> `LineralePlayback` -> `LineraleUI` (iOS 27).  |
| `Sources/LineraleDomain/`    | Entities (`Track`, `PlayerStatus`, `RepeatMode`, `PlaybackTransport`) and the `PlaybackEngine` state machine. |
| `Sources/LineraleData/`      | `APIClient` (HMAC-signed streaming requests), `LocalAudioCache` LRU cache, and `AudioFormat` helpers. |
| `Sources/LineralePlayback/`  | `AudioRuntime`: cache-hit fast path (zero-network `AVPlayer`) and cache-miss path through `AVQueuePlayer`. |
| `Sources/LineraleUI/`        | `LineraleRootView` / `LineraleRootViewHost`: minimal SwiftUI shell with a persistent player bar.   |
| `App/`                       | `LineraleApp.swift` (`@main`), `PlaybackCoordinator`, `NowPlayingManager` (MediaRemote), and the generated Xcode project (`xcodegen`). |
| `Tests/`                     | Swift Testing suites for `LineraleDomain` (repeat/shuffle/next) and `LineraleData` (audio detection). |
| `codemagic.yaml`             | CI: `swift test` -> xcodegen -> archive -> IPA export.                                             |

## Build and run

Uses SPM directly:

```bash
swift build
```

Or via the generated Xcode project:

```bash
cd App
xcodegen generate
open Linerale.xcodeproj
```

## Test

```bash
swift test
# or, in Xcode: xcodebuild test -scheme Linerale -destination 'platform=iOS Simulator,name=iPhone 17'
```

## Continuous integration

`codemagic.yaml` runs on every push to `main`, pinned to **Xcode 27.x** and **Swift 6.4**:

1. `swift test` (LineraleDomain + LineraleData suites)
2. `xcodegen` -> `Linerale.xcodeproj`
3. `xcodebuild` archive -> IPA export (see `scripts/exportOptions.plist`)

## Notes

- `PlaybackTransport.directInnertube` is the default and only supported transport; it
  matches the server wire form `"direct_innertube"`.
- `PlaybackEngine` replicates the desktop reference semantics: cache-hit fast path,
  single-next preload, single-next preload, `repeat = one` honored only on auto-end,
  and `MAX_CONSECUTIVE_AUTO_SKIPS = 3` recovery.
- `APIClient` uses an injectable `RequestSigner`; the shipped `HMACRequestSigner`
  default has an empty secret placeholder that must be tuned server-side.
- Audio effects (pitch/reverb via `AVAudioEngine`) are wired but not yet driven off
  player output.
