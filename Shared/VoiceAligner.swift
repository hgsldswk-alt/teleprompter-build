import Foundation

enum VoiceAligner {
    struct Token: Equatable {
        let text: String
        let start: Int
        let end: Int
        let isHan: Bool
        var phoneticKey: String = ""
        var isNumber: Bool = false
    }

    struct Position: Equatable {
        let tokenIndex: Int
        let characterOffset: Int
    }

    static func tokenize(_ text: String) -> [Token] {
        var result: [Token] = []
        var word = ""
        var wordStart = 0
        var wordEnd = 0
        var offset = 0
        var normalizedCharacters: [Character: String] = [:]
        var phonetics: [String: String] = [:]
        let digits = Set("\u{96F6}\u{3007}\u{4E00}\u{4E8C}\u{4E09}\u{56DB}\u{4E94}\u{516D}\u{4E03}\u{516B}\u{4E5D}\u{5341}\u{767E}\u{5343}\u{4E07}\u{4E24}0123456789")
        func flushWord() {
            if !word.isEmpty {
                result.append(Token(text: word, start: wordStart, end: wordEnd, isHan: false))
                word = ""
            }
        }
        for character in text {
            let original = String(character)
            let end = offset + original.utf16.count
            let normalized: String
            if let cached = normalizedCharacters[character] { normalized = cached }
            else {
                let folded = original.folding(options: [.widthInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                normalized = folded.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? folded
                normalizedCharacters[character] = normalized
            }
            for scalar in normalized.unicodeScalars {
                if digits.contains(Character(String(scalar))) || Script.isHan(scalar.value) {
                    flushWord()
                    let value = String(scalar)
                    let han = Script.isHan(scalar.value)
                    let key: String
                    if let cached = phonetics[value] { key = cached }
                    else {
                        key = value.applyingTransform(.toLatin, reverse: false)?
                            .applyingTransform(.stripDiacritics, reverse: false) ?? value
                        phonetics[value] = key
                    }
                    result.append(Token(text: value, start: offset, end: end, isHan: han,
                                        phoneticKey: key, isNumber: digits.contains(Character(value))))
                } else if CharacterSet.alphanumerics.contains(scalar) {
                    if word.isEmpty { wordStart = offset }
                    word.unicodeScalars.append(scalar)
                    wordEnd = end
                } else if (scalar.value == 0x27 || scalar.value == 0x2019), !word.isEmpty {
                    continue
                } else {
                    flushWord()
                }
            }
            offset = end
        }
        flushWord()
        return result
    }

    static func substitutionCost(_ lhs: Token, _ rhs: Token) -> Double {
        if lhs.text == rhs.text { return 0 }
        if lhs.isNumber && rhs.isNumber {
            guard let left = digitValue(lhs.text), let right = digitValue(rhs.text) else { return 1 }
            return left == right ? 0.3 : 1
        }
        if lhs.isHan && rhs.isHan && !lhs.phoneticKey.isEmpty && lhs.phoneticKey == rhs.phoneticKey { return 0.25 }
        return 1
    }

    private static func digitValue(_ text: String) -> UInt32? {
        guard let value = text.unicodeScalars.first?.value else { return nil }
        switch value {
        case 0x30...0x39: return value - 0x30
        case 0x96F6, 0x3007: return 0
        case 0x4E00: return 1
        case 0x4E8C, 0x4E24: return 2
        case 0x4E09: return 3
        case 0x56DB: return 4
        case 0x4E94: return 5
        case 0x516D: return 6
        case 0x4E03: return 7
        case 0x516B: return 8
        case 0x4E5D: return 9
        default: return nil
        }
    }

    static func tokenIndex(at offset: Int, in tokens: [Token]) -> Int {
        var low = 0
        var high = tokens.count
        while low < high {
            let middle = (low + high) / 2
            if tokens[middle].end <= offset { low = middle + 1 } else { high = middle }
        }
        return low
    }

    static func align(tokens: [Token], current: Int, recognized: String, window: Int? = nil) -> Position {
        let position = min(max(0, current), tokens.count)
        let unchanged = Position(tokenIndex: position, characterOffset: position > 0 ? tokens[position - 1].end : 0)
        guard position < tokens.count else { return unchanged }
        let heard = Array(tokenize(recognized).suffix(24))
        if tokens.count - position <= 2, !heard.isEmpty {
            let remaining = Array(tokens[position...])
            for k in stride(from: min(heard.count, remaining.count), through: 1, by: -1)
            where zip(remaining.prefix(k), heard.suffix(k)).allSatisfy({ substitutionCost($0.0, $0.1) <= 0.3 }) {
                let end = position + k
                return Position(tokenIndex: end, characterOffset: tokens[end - 1].end)
            }
            return unchanged
        }
        guard heard.count >= 3 else { return unchanged }
        if position >= heard.count {
            let justRead = tokens[(position - heard.count)..<position]
            if zip(justRead, heard).allSatisfy({ substitutionCost($0.0, $0.1) <= 0.3 }) { return unchanged }
        }
        let size = window ?? (tokens[position].isHan || tokens[position].isNumber ? 200 : 60)
        let upper = min(tokens.count, position + max(0, size))
        guard upper > position else { return unchanged }
        let script = Array(tokens[position..<upper])
        var bestScore = 0.0
        var bestEnd = 0
        let lengths = Array(Set([heard.count, min(12, heard.count), min(6, heard.count)])).sorted(by: >)
        for length in lengths {
            let phrase = Array(heard.suffix(length))
            var previous = [Double](repeating: 0, count: script.count + 1)
            for row in 1...phrase.count {
                var next = [Double](repeating: 0, count: script.count + 1)
                next[0] = Double(row)
                for column in 1...script.count {
                    let cost = substitutionCost(phrase[row - 1], script[column - 1])
                    next[column] = min(previous[column] + 1, next[column - 1] + 1, previous[column - 1] + cost)
                }
                previous = next
            }
            for end in 1...script.count {
                guard let last = phrase.last, substitutionCost(last, script[end - 1]) <= 0.3 else { continue }
                let similarity = 1 - Double(previous[end]) / Double(length)
                let threshold = phrase.allSatisfy(\.isNumber) ? 0.7 : 0.75
                guard similarity + 0.000001 >= threshold, Double(length) - previous[end] + 0.000001 >= Double(min(3, length)) * 0.7 else { continue }
                let score = similarity + Double(length) * 0.003 - Double(end) * 0.0001
                if score > bestScore {
                    bestScore = score
                    bestEnd = end
                }
            }
        }
        guard bestEnd > 0 else { return unchanged }
        let index = position + bestEnd
        return Position(tokenIndex: index, characterOffset: tokens[index - 1].end)
    }
}
