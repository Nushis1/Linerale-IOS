# Linerale

<img alt="Linerale" src="https://img.shields.io/badge/Linerale-iOS%2027-1E78FF?style=for-the-badge&labelColor=0D1117" />
<a href="https://developer.apple.com/swift/"><img alt="Swift 6.4" src="https://img.shields.io/badge/Swift-6.4-F05032?logo=swift" /></a>
<a href="https://developer.apple.com/ios/"><img alt="iOS 27" src="https://img.shields.io/badge/iOS-27.0-000000?logo=apple" /></a>
<a href="https://developer.apple.com/xcode/"><img alt="Xcode 27.2" src="https://img.shields.io/badge/Xcode-27.2-147EFB?logo=xcode" /></a>
<img alt="License" src="https://img.shields.io/badge/License-MIT-0D1117" />

Linerale is a native iOS 27 music player written in Swift 6.4. It is the iOS
companion to the [Liner](https://github.com/tryliner/desktop/) desktop client: it
resolves audio from direct Inneartube streams, caches it locally with an LRU
policy, and plays it back through **AVFoundation** with a stateful, observable
queue engine — all built on a multi-module Swift Package Manager workspace.

## Features

- **Direct Inneartube** resolution — `PlaybackTransport.directInnertube` matches the
  desktop/server wire form (`"direct_innertube"`).
- **Fast-path playback** — a cache hit streams from local disk through `AVPlayer`
  with **zero network**; a miss streams, caches, and resumes.
- **Stateful queue engine** — single-next preload, `repeat` (`one` / `off` / `all`),
  shuffle, skip recovery (`MAX_CONSECUTIVE_AUTO_SKIPS = 3`), and desktop-faithful
  auto-end semantics (`repeat = one` honored only on auto-end).
- **LRU audio cache** — 3 GB default limit with a 250 MB floor, atomic
  temp-and-replace writes.
- **HMAC-signed API** — injectable `RequestSigner` with a canonical
  `METHOD:path:timestamp:nonce:body` scheme and a CryptoKit default.
- **Now Playing** — `MPNowPlayingInfoCenter` / `MPRemoteCommandCenter` bridge so
  lock-screen and headset controls drive the engine.
- **Observable state** — `@MainActor ObservableObject` engine powers the SwiftUI UI.

## Project layout

| Path                       | Module / purpose                                                                 |
| -------------------------- | -------------------------------------------------------------------------------- |
| `Package.swift`            | SPM manifest — `LineraleDomain` → `LineraleData` → `LineralePlayback` → `LineraleUI`. |
| `Sources/LineraleDomain/`  | Entities (`Track`, `PlayerStatus`, `RepeatMode`, `PlaybackTransport`) and the `PlaybackEngine` state machine. |
| `Sources/LineraleData/`    | `APIClient` (HMAC-signed requests), `LocalAudioCache` (LRU), and `AudioFormat` helpers. |
| `Sources/LineralePlayback/`| `AudioRuntime`: cache-hit fast path (`AVPlayer`), cache-miss path (`AVQueuePlayer`), and an `AVAudioEngine` graph for pitch/reverb. |
| `Sources/LineraleUI/`      | `LineraleRootView` / `LineraleRootViewHost`: minimal SwiftUI shell with a persistent player bar. |
| `App/`                     | `LineraleApp.swift` (`@main`), `PlaybackCoordinator`, `NowPlayingManager` (MediaRemote), and the xcodegen spec + generated Xcode project. |
| `Tests/`                   | Swift Testing suites for `LineraleDomain` (repeat/shuffle/next) and `LineraleData` (audio detection), plus playback/UI placeholders. |
| `codemagic.yaml`           | CI: `swift test` → xcodegen → archive → IPA export.                              |

## Requirements

| Tool   | Minimum   |
| ------ | --------- |
| Xcode  | 27.2      |
| Swift  | 6.4       |
| iOS    | 27.0 (GA) |

## Build and run

**SPM directly:**

```bash
swift build
```

**Generated Xcode project:**

```bash
cd App
xcodegen generate
open Linerale.xcodeproj
```

## Test

```bash
swift test
# or:
xcodebuild test -scheme Linerale -destination 'platform=iOS Simulator,name=iPhone 17'
```

## Continuous integration

`codemagic.yaml` runs on every push to `main`, pinned to **Xcode 27.x** and **Swift 6.4**:

1. `swift test` (LineraleDomain + LineraleData suites)
2. `xcodegen` → `Linerale.xcodeproj`
3. `xcodebuild` archive → IPA export (see `scripts/exportOptions.plist`)

## Notes

- `PlaybackEngine` replicates the desktop reference semantics: cache-hit fast path,
  single-next preload, `repeat = one` honored only on auto-end, and
  `MAX_CONSECUTIVE_AUTO_SKIPS = 3` recovery.
- `APIClient` uses an injectable `RequestSigner`; the shipped `HMACRequestSigner`
  default holds an empty secret placeholder that must be tuned server-side.
- Audio effects (pitch/reverb via `AVAudioEngine`) are wired but not yet driven off
  player output.

## Attribution

This project is the iOS companion to **[Liner](https://github.com/tryliner/desktop/)**
and mirrors its queue and caching semantics. See
[`tryliner/desktop`](https://github.com/tryliner/desktop/) for the reference
implementation.

## License

Copyright (c) 2026 Linerale contributors.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
