import XCTest
import CoreFoundation

final class TextImporterTests: XCTestCase {
    func testUTF8AndBOM() throws {
        let text = "你好 hello\n第二行"
        XCTAssertEqual(try TextImporter.decodeText(Data(text.utf8)), text)
        XCTAssertEqual(try TextImporter.decodeText(Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)), text)
    }
    func testUTF16LittleAndBigEndian() throws {
        let text = "你好 hello"
        XCTAssertEqual(try TextImporter.decodeText(Data([0xFF, 0xFE]) + XCTUnwrap(text.data(using: .utf16LittleEndian))), text)
        XCTAssertEqual(try TextImporter.decodeText(Data([0xFE, 0xFF]) + XCTUnwrap(text.data(using: .utf16BigEndian))), text)
    }
    func testGBKAndGB18030() throws {
        XCTAssertEqual(try TextImporter.decodeText(Data([0xD6, 0xD0, 0xCE, 0xC4])), "中文")
        let encoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        let text = "中文和𠀀"
        let data = try XCTUnwrap(text.data(using: String.Encoding(rawValue: encoding)))
        XCTAssertEqual(try TextImporter.decodeText(data), text)
    }
    func testMarkdownRemainsUnchangedAndRTFExtractsText() throws {
        let markdown = "# 标题\n**正文**"
        XCTAssertEqual(try TextImporter.text(data: Data(markdown.utf8), extension: "md"), markdown)
        let rtf = Data(#"{\rtf1\ansi Hello \b world\b0\par Next line}"#.utf8)
        let result = try TextImporter.text(data: rtf, extension: "rtf")
        XCTAssertTrue(result.contains("Hello world"))
        XCTAssertTrue(result.contains("Next line"))
    }
    func testStoredAndRawDeflateDOCX() throws {
        for compressed in [false, true] {
            let zip = try makeDOCX(compressed: compressed)
            XCTAssertEqual(try TextImporter.docxText(zip), "Hello & 你好\nSecond paragraph")
        }
    }
    func testCorruptZipAndChecksumRejected() throws {
        XCTAssertThrowsError(try TextImporter.docxText(Data("Not a zip".utf8)))
        var zip = try makeDOCX(compressed: false)
        zip[50] ^= 1
        XCTAssertThrowsError(try TextImporter.docxText(zip))
    }
    func testEmptyUnsupportedAndOversizedFiles() {
        XCTAssertThrowsError(try TextImporter.text(data: Data(), extension: "txt"))
        XCTAssertThrowsError(try TextImporter.text(data: Data("hello".utf8), extension: "png"))
        XCTAssertThrowsError(try TextImporter.text(data: Data(repeating: 65, count: TextImporter.maxFileSize + 1), extension: "txt"))
    }

    private func makeDOCX(compressed: Bool) throws -> Data {
        let xml = Data(#"<?xml version="1.0" encoding="UTF-8"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>Hello &amp; 你好</w:t></w:r></w:p><w:p><w:r><w:t>Second paragraph</w:t></w:r></w:p></w:body></w:document>"#.utf8)
        let name = Data("word/document.xml".utf8)
        let payload = compressed ? try XCTUnwrap(ShareCode.rawDeflate(xml, encode: true, capacity: xml.count + 1024)) : xml
        let method = compressed ? 8 : 0
        let crc = Int(TextImporter.crc32(xml))
        var local = Data()
        func add(_ value: Int, bytes: Int, to data: inout Data) {
            for index in 0..<bytes { data.append(UInt8((value >> (index * 8)) & 255)) }
        }
        add(0x04034B50, bytes: 4, to: &local)
        for value in [20, 0, method, 0, 0] { add(value, bytes: 2, to: &local) }
        for value in [crc, payload.count, xml.count] { add(value, bytes: 4, to: &local) }
        add(name.count, bytes: 2, to: &local); add(0, bytes: 2, to: &local)
        local.append(name); local.append(payload)
        var central = Data()
        add(0x02014B50, bytes: 4, to: &central)
        for value in [20, 20, 0, method, 0, 0] { add(value, bytes: 2, to: &central) }
        for value in [crc, payload.count, xml.count] { add(value, bytes: 4, to: &central) }
        for value in [name.count, 0, 0, 0, 0] { add(value, bytes: 2, to: &central) }
        add(0, bytes: 4, to: &central); add(0, bytes: 4, to: &central)
        central.append(name)
        var end = Data()
        add(0x06054B50, bytes: 4, to: &end)
        for value in [0, 0, 1, 1] { add(value, bytes: 2, to: &end) }
        add(central.count, bytes: 4, to: &end); add(local.count, bytes: 4, to: &end)
        add(0, bytes: 2, to: &end)
        return local + central + end
    }
}
