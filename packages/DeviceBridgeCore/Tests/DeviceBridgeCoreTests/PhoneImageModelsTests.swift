import Foundation
import Testing
@testable import DeviceBridgeCore

@Suite("Phone image metadata and scope")
struct PhoneImageModelsTests {
    @Test("NUL records preserve Unicode, spaces and newlines without splitting a filename")
    func metadataRecords() throws {
        let data = Data("12\01720000000.5\0/sdcard/Pictures/截图 'a\nb'.PNG\0".utf8)
        let items = try AndroidImageParser.parse(data, source: .androidPictures)
        #expect(items.count == 1)
        #expect(items.first?.displayName == "截图 'a\nb'.PNG")
        #expect(items.first?.byteLength == 12)
    }

    @Test("empty success differs from malformed, truncated and out-of-scope data")
    func malformedRecords() throws {
        #expect(try AndroidImageParser.parse(Data(), source: .androidPictures).isEmpty)
        for value in ["2\0", "2\01\0/sdcard/Pictures/a.png", "-1\01\0/sdcard/Pictures/a.png\0",
                      "2\0nan\0/sdcard/Pictures/a.png\0", "2\01\0/sdcard/Pictures/../DCIM/a.png\0",
                      "2\01\0/sdcard/PicturesOther/a.png\0"] {
            #expect(throws: (any Error).self) { try AndroidImageParser.parse(Data(value.utf8), source: .androidPictures) }
        }
    }

    @Test("non-image files are excluded and too many records cannot masquerade as a complete catalog")
    func filteringAndLimit() throws {
        let record = "2\01\0/sdcard/Pictures/a.png\0"
        #expect(try AndroidImageParser.parse(Data("2\01\0/sdcard/Pictures/log.txt\0".utf8), source: .androidPictures).isEmpty)
        #expect(throws: PhoneImageError.limitExceeded) {
            try AndroidImageParser.parse(Data(String(repeating: record, count: 10_001).utf8), source: .androidPictures)
        }
    }
}
