import Foundation
import Compression

enum ShareCode {
    static let marker = "#提词器稿件#"
    static let maxTextLength = 200 * 1024
    static let maxJSONLength = 1024 * 1024
    private struct Payload: Codable { var v: Int; var title: String; var body: String; var style: SharedStyle? }
    private struct Basic: Decodable { var v: Int; var title: String; var body: String }
    private struct StyleOnly: Decodable { var style: SharedStyle? }

    static func encode(_ script: Script, style: SharedStyle? = nil) -> String? {
        guard let json = try? JSONEncoder().encode(Payload(v: 1, title: script.title, body: script.body, style: style)),
              let packed = pack(json) else { return nil }
        let base = packed.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let code = marker + base + "#"
        return code.utf8.count <= maxTextLength ? code : nil
    }

    static func decode(_ text: String) -> Script? { decodeWithStyle(text)?.script }

    static func decodeWithStyle(_ text: String) -> (script: Script, style: SharedStyle?)? {
        guard text.utf8.count <= maxTextLength + 8192,
              let start = [marker, "#TeleprompterScript#"].compactMap({ text.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) else { return nil }
        let rest = text[start.upperBound...]
        guard let end = rest.firstIndex(of: "#") else { return nil }
        let raw = rest[..<end].filter { !$0.isWhitespace }
        guard !raw.isEmpty, raw.utf8.count <= maxTextLength,
              raw.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }), raw.count % 4 != 1 else { return nil }
        var base = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base.count % 4 != 0 { base += "=" }
        guard let data = Data(base64Encoded: base), let json = unpack(data),
              let payload = try? JSONDecoder().decode(Basic.self, from: json), payload.v == 1,
              !payload.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let style = (try? JSONDecoder().decode(StyleOnly.self, from: json))?.style
        return (Script(title: payload.title, body: payload.body), style)
    }

    private static func adler(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for value in bytes { a = (a + UInt32(value)) % 65521; b = (b + a) % 65521 }
        return (b << 16) | a
    }

    static func pack(_ data: Data) -> Data? {
        guard !data.isEmpty, data.count <= maxJSONLength else { return nil }
        guard let raw = rawDeflate(data, encode: true, capacity: data.count + data.count / 8 + 1024) else { return nil }
        let checksum = adler([UInt8](data))
        var result = Data([0x78, 0x9c])
        result.append(raw)
        result.append(contentsOf: [UInt8((checksum >> 24) & 255), UInt8((checksum >> 16) & 255), UInt8((checksum >> 8) & 255), UInt8(checksum & 255)])
        return result
    }

    static func unpack(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 7, bytes.count <= maxTextLength, bytes[0] & 15 == 8,
              bytes[0] >> 4 <= 7, (Int(bytes[0]) * 256 + Int(bytes[1])) % 31 == 0,
              bytes[1] & 32 == 0,
              let unpacked = rawDeflate(Data(bytes[2..<(bytes.count - 4)]), encode: false, capacity: maxJSONLength + 1),
              unpacked.count <= maxJSONLength,
              adler([UInt8](unpacked)) == bytes.suffix(4).reduce(UInt32(0), { ($0 << 8) | UInt32($1) }) else { return nil }
        return unpacked
    }

    static func rawDeflate(_ data: Data, encode: Bool, capacity: Int) -> Data? {
        let input = [UInt8](data)
        guard !input.isEmpty, capacity > 0 else { return nil }
        var output = [UInt8](repeating: 0, count: capacity)
        let count = input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                if encode {
                    return compression_encode_buffer(destination.baseAddress!, capacity, source.baseAddress!, input.count, nil, COMPRESSION_ZLIB)
                }
                return compression_decode_buffer(destination.baseAddress!, capacity, source.baseAddress!, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard count > 0, count < capacity else { return nil }
        return Data(output.prefix(count))
    }
}

struct SharedStyle: Codable, Equatable {
    var fontSize: Double
    var lineSpacing: Double
    var heightRatio: Double
    var margin: Double
    var textColor: PromptColor
    var backgroundOpacity: Double
    var speed: Double
    var chineseRate: Double
    var englishRate: Double

    init(_ settings: PromptSettings) {
        fontSize = settings.fontSize
        lineSpacing = settings.lineSpacing
        heightRatio = settings.heightRatio
        margin = settings.margin
        textColor = settings.textColor
        backgroundOpacity = settings.backgroundOpacity
        speed = settings.speed
        chineseRate = settings.chineseRate
        englishRate = settings.englishRate
    }

    func applied(to settings: PromptSettings) -> PromptSettings {
        var value = settings
        value.fontSize = fontSize
        value.lineSpacing = lineSpacing
        value.heightRatio = heightRatio
        value.margin = margin
        value.textColor = textColor
        value.backgroundOpacity = backgroundOpacity
        value.speed = speed
        value.chineseRate = chineseRate
        value.englishRate = englishRate
        value.clamp()
        return value
    }
}
