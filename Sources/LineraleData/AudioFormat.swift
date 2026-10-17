public import Foundation

/// True when the leading bytes of `head` start a complete, standalone audio
/// file that `AVAudioFile` / AVFoundation can open directly.
///
/// Ported from `desktop/src/shared/storage/audioFormat.ts`: rejects fragmented
/// MP4 media segments (the bare `"styp"` box) and non-audio payloads *before*
/// they are cached, so the on-device cache only stores playable media.
public func isStandaloneAudioFile(_ head: Data) -> Bool {
    if head.count < 12 { return false }

    let bytes = [UInt8](head)
    let ascii = { (from: Int, to: Int) -> String in
        String(decoding: bytes[from..<to], as: UTF8.self)
    }

    if bytes[0] == 0x1a, bytes[1] == 0x45, bytes[2] == 0xdf, bytes[3] == 0xa3 {
        return true
    }

    if ascii(4, 8) == "ftyp" { return true }

    let magic = ascii(0, 4)
    if magic == "OggS" || magic == "fLaC" || magic == "RIFF" { return true }

    if ascii(0, 3) == "ID3" { return true }
    if bytes[0] == 0xff, (bytes[1] & 0xe0) == 0xe0 { return true }

    return false
}
