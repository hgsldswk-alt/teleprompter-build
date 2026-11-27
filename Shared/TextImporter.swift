import Foundation
import CoreFoundation
import UIKit
import PDFKit

enum ImportError: LocalizedError {
    case unsupported, unreadable, empty, tooLarge, textTooLarge, damagedArchive
    var errorDescription: String? {
        switch self {
        case .unsupported: return L("不支持此文件格式。")
        case .unreadable: return L("无法读取文字，请检查文件编码或是否加密。")
        case .empty: return L("文件没有可提取的文字，扫描版 PDF 请先转成文字。")
        case .tooLarge: return L("文件过大，请拆分后导入（文件上限 20 MB）。")
        case .textTooLarge: return L("提取的文字过长，请拆分稿件后导入。")
        case .damagedArchive: return L("DOCX 文件损坏、已加密或格式不受支持。")
        }
    }
}

enum TextImporter {
    static let maxFileSize = 20 * 1024 * 1024
    static let maxXMLSize = 4 * 1024 * 1024

    static func read(url: URL) throws -> Script {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? 0) <= maxFileSize else { throw ImportError.tooLarge }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let body = try text(data: data, extension: url.pathExtension.lowercased())
        return Script(title: url.deletingPathExtension().lastPathComponent, body: body)
    }

    static func text(data: Data, extension ext: String) throws -> String {
        guard data.count <= maxFileSize else { throw ImportError.tooLarge }
        let result: String
        switch ext {
        case "txt", "md": result = try decodeText(data)
        case "rtf":
            guard let rich = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) else { throw ImportError.unreadable }
            result = rich.string
        case "docx": result = try docxText(data)
        case "pdf":
            guard let document = PDFDocument(data: data), !document.isLocked else { throw ImportError.unreadable }
            result = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n\n")
        default: throw ImportError.unsupported
        }
        guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ImportError.empty }
        guard result.utf8.count <= maxXMLSize else { throw ImportError.textTooLarge }
        return result
    }

    static func decodeText(_ data: Data) throws -> String {
        let bytes = [UInt8](data.prefix(3))
        if bytes.starts(with: [0xFF, 0xFE]), let text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) { return text }
        if bytes.starts(with: [0xFE, 0xFF]), let text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) { return text }
        if let text = String(data: data, encoding: .utf8) { return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text }
        let encoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let text = String(data: data, encoding: String.Encoding(rawValue: encoding)) { return text }
        throw ImportError.unreadable
    }

    static func documentXML(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        func number(_ offset: Int, _ length: Int) throws -> Int {
            guard offset >= 0, length <= 4, offset <= bytes.count - length else { throw ImportError.damagedArchive }
            return (0..<length).reduce(0) { $0 | Int(bytes[offset + $1]) << (8 * $1) }
        }
        guard bytes.count >= 22 else { throw ImportError.damagedArchive }
        var end: Int?
        for index in stride(from: bytes.count - 22, through: max(0, bytes.count - 65557), by: -1) {
            if try number(index, 4) == 0x06054B50,
               index + 22 + (try number(index + 20, 2)) == bytes.count { end = index; break }
        }
        guard let end, try number(end + 4, 2) == 0, try number(end + 6, 2) == 0,
              try number(end + 8, 2) == number(end + 10, 2) else { throw ImportError.damagedArchive }
        let entries = try number(end + 10, 2)
        var cursor = try number(end + 16, 4)
        let centralEnd = cursor + (try number(end + 12, 4))
        guard entries < 65535, centralEnd <= end else { throw ImportError.damagedArchive }
        for _ in 0..<entries {
            guard cursor + 46 <= centralEnd, try number(cursor, 4) == 0x02014B50 else { throw ImportError.damagedArchive }
            let flags = try number(cursor + 8, 2)
            let method = try number(cursor + 10, 2)
            let checksum = try number(cursor + 16, 4)
            let packedSize = try number(cursor + 20, 4)
            let size = try number(cursor + 24, 4)
            let nameLength = try number(cursor + 28, 2)
            let extraLength = try number(cursor + 30, 2)
            let commentLength = try number(cursor + 32, 2)
            let local = try number(cursor + 42, 4)
            guard cursor + 46 + nameLength + extraLength + commentLength <= centralEnd else { throw ImportError.damagedArchive }
            let name = String(bytes: bytes[(cursor + 46)..<(cursor + 46 + nameLength)], encoding: .utf8)
            cursor += 46 + nameLength + extraLength + commentLength
            guard name == "word/document.xml" else { continue }
            guard size <= maxXMLSize else { throw ImportError.textTooLarge }
            guard flags & 1 == 0, size > 0, packedSize <= maxFileSize,
                  try number(local, 4) == 0x04034B50,
                  try number(local + 8, 2) == method else { throw ImportError.damagedArchive }
            let start = local + 30 + (try number(local + 26, 2)) + (try number(local + 28, 2))
            guard start >= 0, start <= bytes.count - packedSize else { throw ImportError.damagedArchive }
            let packed = Data(bytes[start..<(start + packedSize)])
            let xml: Data
            switch method {
            case 0: xml = packed
            case 8:
                guard let decoded = ShareCode.rawDeflate(packed, encode: false, capacity: size + 1) else { throw ImportError.damagedArchive }
                xml = decoded
            default: throw ImportError.damagedArchive
            }
            guard xml.count == size, Int(crc32(xml)) == checksum else { throw ImportError.damagedArchive }
            return xml
        }
        throw ImportError.damagedArchive
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xEDB88320 : 0) }
        }
        return crc ^ 0xFFFFFFFF
    }

    static func docxText(_ data: Data) throws -> String {
        let reader = WordXMLReader()
        let parser = XMLParser(data: try documentXML(data))
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse() else { throw ImportError.damagedArchive }
        return reader.text.trimmingCharacters(in: .newlines)
    }
}

private final class WordXMLReader: NSObject, XMLParserDelegate {
    var text = ""
    private var byteCount = 0
    private var insideText = false
    private let namespace = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        guard namespaceURI == namespace || namespaceURI == "http://purl.oclc.org/ooxml/wordprocessingml/main" else { return }
        if elementName == "t" { insideText = true }
        if elementName == "tab" { text += "\t" }
        if elementName == "br" || elementName == "cr" { text += "\n" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard insideText else { return }
        byteCount += string.utf8.count
        guard byteCount <= TextImporter.maxXMLSize else { parser.abortParsing(); return }
        text += string
    }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { parser.abortParsing() }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { parser.abortParsing() }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        guard namespaceURI == namespace || namespaceURI == "http://purl.oclc.org/ooxml/wordprocessingml/main" else { return }
        if elementName == "t" { insideText = false }
        if elementName == "p" { text += "\n" }
    }
}
