import XCTest

final class ShareCodeTests: XCTestCase {
    func testPythonZlibFixture() {
        let code = "#提词器稿件#eJw9yjEOwjAMBdCrfHmuKrFmY2RmZTGJEVHT2HLdoghxdyaY33vTQek0UdRoQokuq6mHFGzZqwVNdNcyKNEZ25P9D6i_-HBdwTi41YKsReZbv5rwgs6xO7c2wL1gETEM3R366jDOMtPnC9H-LF4#"
        XCTAssertEqual(ShareCode.decode(code)?.title, "Imported script")
    }
    func testRoundTripWithChineseAndLongText() throws {
        let script = Script(title: "我的稿件", body: String(repeating: "你好，world。\n", count: 5000))
        let encoded = try XCTUnwrap(ShareCode.encode(script))
        XCTAssertLessThanOrEqual(encoded.utf8.count, 200 * 1024)
        let decoded = try XCTUnwrap(ShareCode.decode(encoded))
        XCTAssertEqual(decoded.title, script.title)
        XCTAssertEqual(decoded.body, script.body)
        XCTAssertNotEqual(decoded.id, script.id)
    }
    func testSurroundingMessageNewlinesAndEnglishMarker() throws {
        let script = Script(title: "Hello", body: "A small script for a friend")
        let encoded = try XCTUnwrap(ShareCode.encode(script)).replacingOccurrences(of: ShareCode.marker, with: "#TeleprompterScript#")
        let wrapped = "Here is the script\n" + encoded.replacingOccurrences(of: "#TeleprompterScript#", with: "#TeleprompterScript#\n") + "\nThanks!"
        XCTAssertEqual(ShareCode.decode(wrapped)?.body, script.body)
    }
    func testCorruptUnsupportedVersionAndOversizedCode() throws {
        XCTAssertNil(ShareCode.decode("#提词器稿件#@@@#"))
        XCTAssertNil(ShareCode.decode("#提词器稿件#A#"))
        XCTAssertNil(ShareCode.decode("#提词器稿件#" + String(repeating: "A", count: 205_000) + "#"))
        let data = Data(#"{"v":2,"title":"X","body":"Y"}"#.utf8)
        let packed = try XCTUnwrap(ShareCode.pack(data))
        let base = packed.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        XCTAssertNil(ShareCode.decode(ShareCode.marker + base + "#"))
    }
    func testZlibChecksumAndDecompressionLimit() throws {
        var packed = try XCTUnwrap(ShareCode.pack(Data("A test payload".utf8)))
        packed[packed.count - 1] ^= 1
        XCTAssertNil(ShareCode.unpack(packed))
        XCTAssertNil(ShareCode.pack(Data(repeating: 65, count: ShareCode.maxJSONLength + 1)))
    }

    func testStyleTravelsWithScriptAndOldCodesStillImport() throws {
        var settings = PromptSettings()
        settings.fontSize = 48
        settings.speed = 1.25
        settings.mirrorHorizontal = true
        let script = Script(title: "Style", body: "Hello there")
        let message = "Copy this: " + (try XCTUnwrap(ShareCode.encode(script, style: SharedStyle(settings)))) + " thanks"
        let decoded = try XCTUnwrap(ShareCode.decodeWithStyle(message))
        XCTAssertEqual(decoded.script.body, "Hello there")
        let applied = try XCTUnwrap(decoded.style).applied(to: PromptSettings())
        XCTAssertEqual(applied.fontSize, 48)
        XCTAssertEqual(applied.speed, 1.25)
        XCTAssertFalse(applied.mirrorHorizontal, "Mirroring stays personal")
        let plain = try XCTUnwrap(ShareCode.encode(script))
        XCTAssertNil(try XCTUnwrap(ShareCode.decodeWithStyle(plain)).style)
    }
}
