import Testing
import LineraleData

struct AudioFormatTests {
    @Test("Standalone audio file headers are detected")
    func detectsAudioMagic() {
        #expect(isStandaloneAudioFile(Data([0x1a, 0x45, 0xdf, 0xa3, 0, 0, 0, 0, 0, 0, 0, 0])) == true) // webm/matroska
        #expect(isStandaloneAudioFile(Data([0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x6d, 0x34, 0x61])) == true) // mp4 'ftyp'
        #expect(isStandaloneAudioFile(Data([0x4f, 0x67, 0x67, 0x53, 0, 0, 0, 0, 0, 0, 0, 0])) == true) // OggS
        #expect(isStandaloneAudioFile(Data(repeating: 0x58, count: 12)) == false) // junk
    }

    @Test("Short payloads are rejected")
    func rejectsShortOrFragment() {
        #expect(isStandaloneAudioFile(Data()) == false)
        #expect(isStandaloneAudioFile(Data([0x00, 0x00, 0x00, 0x01])) == false) // 'styp' fragment – rejected
    }
}
