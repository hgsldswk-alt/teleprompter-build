import XCTest
import CoreFoundation

final class VoiceAlignerTests: XCTestCase {
    func testSequentialReadingAndOriginalOffsets() {
        let text = "你好，欢迎来到这里。今天我们一起练习自然表达。"
        let tokens = VoiceAligner.tokenize(text)
        let first = VoiceAligner.align(tokens: tokens, current: 0, recognized: "你好欢迎来到这里")
        XCTAssertEqual(first.tokenIndex, 8)
        XCTAssertEqual((text as NSString).substring(to: first.characterOffset), "你好，欢迎来到这里")
        let next = VoiceAligner.align(tokens: tokens, current: first.tokenIndex, recognized: "今天我们一起练习")
        XCTAssertGreaterThan(next.tokenIndex, first.tokenIndex)
    }

    func testStumbleAndRepeatDoNotRewind() {
        let tokens = VoiceAligner.tokenize("今天我们分享三个想法。接下来谈谈如何改善日常表达。")
        let initial = VoiceAligner.align(tokens: tokens, current: 0, recognized: "今天我们分享三个想法")
        let repeatResult = VoiceAligner.align(tokens: tokens, current: initial.tokenIndex, recognized: "今天我们分享三个想法")
        XCTAssertEqual(initial, repeatResult)
        let resumed = VoiceAligner.align(tokens: tokens, current: initial.tokenIndex, recognized: "接下来谈谈如何")
        XCTAssertGreaterThan(resumed.tokenIndex, initial.tokenIndex)
    }

    func testRepeatedLineDoesNotSkipAnIdenticalNextLine() {
        let tokens = VoiceAligner.tokenize("现在看着镜头说话。现在看着镜头说话。最后结束。")
        let first = VoiceAligner.align(tokens: tokens, current: 0, recognized: "现在看着镜头说话")
        XCTAssertEqual(first.tokenIndex, 8)
        XCTAssertEqual(VoiceAligner.align(tokens: tokens, current: first.tokenIndex, recognized: "现在看着镜头说话"), first)
    }

    func testSkipParagraphWithinWindow() {
        let tokens = VoiceAligner.tokenize("开场先说几句话。\n这里是我们决定跳过的段落。\n最后回到真正重要的观点。")
        let result = VoiceAligner.align(tokens: tokens, current: 6, recognized: "最后回到真正重要的观点")
        XCTAssertEqual(result.tokenIndex, tokens.count)
    }

    func testOneWrongCharacterStillAdvances() {
        let tokens = VoiceAligner.tokenize("今天我们学习如何看着镜头自然地说话")
        let result = VoiceAligner.align(tokens: tokens, current: 0, recognized: "今天我们学西如何看着镜头")
        XCTAssertGreaterThanOrEqual(result.tokenIndex, 12)
    }

    func testChineseEnglishAndWidthNormalization() {
        let tokens = VoiceAligner.tokenize("先打开 ＣＡＭＥＲＡ，再说 Hello WORLD，开始录制。")
        let first = VoiceAligner.align(tokens: tokens, current: 0, recognized: "先打开 camera")
        XCTAssertEqual(first.tokenIndex, 4)
        let second = VoiceAligner.align(tokens: tokens, current: first.tokenIndex, recognized: "再说 hello world")
        XCTAssertEqual(second.tokenIndex, 8)
    }

    func testTraditionalAndSimplifiedRecognizeEachOther() {
        let tokens = VoiceAligner.tokenize("歡迎使用語音跟隨，讓表達更自然。")
        let result = VoiceAligner.align(tokens: tokens, current: 0, recognized: "欢迎使用语音跟随")
        XCTAssertEqual(result.tokenIndex, 8)
    }

    func testTotallyWrongTextAndShortNoiseStayStill() {
        let tokens = VoiceAligner.tokenize("现在我们开始讲述今天准备的内容")
        XCTAssertEqual(VoiceAligner.align(tokens: tokens, current: 3, recognized: "音乐天气完全不同").tokenIndex, 3)
        XCTAssertEqual(VoiceAligner.align(tokens: tokens, current: 3, recognized: "嗯嗯").tokenIndex, 3)
        XCTAssertEqual(VoiceAligner.align(tokens: tokens, current: 3, recognized: "... ").tokenIndex, 3)
    }

    func testDoesNotJumpOutsideWindow() {
        let tokens = VoiceAligner.tokenize(String(repeating: "开场内容", count: 80) + "最终独特结尾观点")
        XCTAssertEqual(VoiceAligner.align(tokens: tokens, current: 0, recognized: "最终独特结尾观点").tokenIndex, 0)
    }

    func testEnglishWordsAndForwardOnly() {
        let tokens = VoiceAligner.tokenize("Take a breath. Skip this paragraph entirely. Then look at the lens and speak naturally.")
        let result = VoiceAligner.align(tokens: tokens, current: 3, recognized: "look at the lens and speak naturally")
        XCTAssertEqual(result.tokenIndex, tokens.count)
        XCTAssertEqual(VoiceAligner.align(tokens: tokens, current: result.tokenIndex, recognized: "take a breath"), result)
    }

    func testEmojiAndUTF16Mapping() {
        let text = "🎬你好，世界 hello!"
        let tokens = VoiceAligner.tokenize(text)
        XCTAssertEqual(tokens[0].start, 2)
        XCTAssertEqual(tokens.last?.text, "hello")
        let result = VoiceAligner.align(tokens: tokens, current: 0, recognized: "你好世界 hello")
        XCTAssertEqual(result.characterOffset, (text as NSString).length - 1)
        XCTAssertEqual(VoiceAligner.tokenIndex(at: tokens[2].start, in: tokens), 2)
    }

    func testEmptyAndClampedPositions() {
        XCTAssertEqual(VoiceAligner.align(tokens: [], current: 0, recognized: "任何内容").characterOffset, 0)
        let tokens = VoiceAligner.tokenize("测试文字")
        XCTAssertEqual(VoiceAligner.align(tokens: tokens, current: 1000, recognized: "测试文字").tokenIndex, 4)
        XCTAssertEqual(VoiceAligner.align(tokens: tokens, current: -2, recognized: "完全不同的句子").tokenIndex, 0)
    }

    func testVeryShortScriptAndEnglishContractions() {
        let tokens = VoiceAligner.tokenize("你好！")
        XCTAssertEqual(VoiceAligner.align(tokens: tokens, current: 0, recognized: "你好").tokenIndex, 2)
        XCTAssertEqual(VoiceAligner.align(tokens: tokens, current: 0, recognized: "别的").tokenIndex, 0)
        XCTAssertEqual(VoiceAligner.tokenize("Don't stop; we're ready.").map(\.text), ["dont", "stop", "were", "ready"])
    }

    func testHomophonesIncludingLastCharacterAndShortScript() {
        let short = VoiceAligner.tokenize("提词器")
        XCTAssertEqual(VoiceAligner.align(tokens: short, current: 0, recognized: "题词器").tokenIndex, 3)
        let tokens = VoiceAligner.tokenize("欢迎使用提词器")
        XCTAssertEqual(VoiceAligner.align(tokens: tokens, current: 0, recognized: "欢迎使用题词气").tokenIndex, tokens.count)
        XCTAssertEqual(VoiceAligner.substitutionCost(short[0], VoiceAligner.tokenize("题")[0]), 0.25)
        XCTAssertEqual(VoiceAligner.substitutionCost(short[0], short[0]), 0)
    }

    func testArabicAndChineseNumeralsBothDirections() {
        for (script, heard) in [("2026", "二零二六"), ("2026年", "二零二六年"), ("二零二六年", "2026年"), ("今年有两万人参加", "今年有2万人参加")] {
            let tokens = VoiceAligner.tokenize(script)
            XCTAssertEqual(VoiceAligner.align(tokens: tokens, current: 0, recognized: heard).tokenIndex, tokens.count)
        }
        let first = VoiceAligner.tokenize("2")[0]
        let second = VoiceAligner.tokenize("两")[0]
        XCTAssertEqual(VoiceAligner.substitutionCost(first, second), 0.3)
        XCTAssertEqual(VoiceAligner.tokenize("２０２６年").count, 5)
    }

    func testFiftyThousandCharacterPerformance() {
        let tokenizeStart = CFAbsoluteTimeGetCurrent()
        let tokens = VoiceAligner.tokenize(String(repeating: "自然表达需要保持自己的节奏", count: 4000))
        XCTAssertLessThan(CFAbsoluteTimeGetCurrent() - tokenizeStart, 5)
        XCTAssertFalse(tokens[0].phoneticKey.isEmpty)
        XCTAssertGreaterThan(tokens.count, 50_000)
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<100 {
            _ = VoiceAligner.align(tokens: tokens, current: 20_000, recognized: "自然表达需要保持自己的节奏")
        }
        let average = (CFAbsoluteTimeGetCurrent() - start) / 100
        XCTAssertLessThan(average, 0.1)
        print("VoiceAligner average seconds: \(average)")
    }

    func testDifferentDigitsDoNotJumpOrSuppressCorrectContinuation() {
        let tokens = VoiceAligner.tokenize("123456789012")
        XCTAssertEqual(VoiceAligner.align(tokens: tokens, current: 0, recognized: "999999").tokenIndex, 0)
        XCTAssertEqual(VoiceAligner.align(tokens: tokens, current: 6, recognized: "789").tokenIndex, 9)
        XCTAssertEqual(VoiceAligner.align(tokens: tokens, current: 3, recognized: "456").tokenIndex, 6)
        XCTAssertEqual(VoiceAligner.align(tokens: tokens, current: 6, recognized: "456").tokenIndex, 6)
    }

    func testDigitValuesAndPlaceValueCharacters() {
        for (arabic, chinese) in [("0", "零"), ("0", "〇"), ("1", "一"), ("2", "二"), ("2", "两"),
                                  ("3", "三"), ("4", "四"), ("5", "五"), ("6", "六"), ("7", "七"), ("8", "八"), ("9", "九")] {
            let a = VoiceAligner.tokenize(arabic)[0]
            let b = VoiceAligner.tokenize(chinese)[0]
            XCTAssertEqual(VoiceAligner.substitutionCost(a, b), 0.3)
            XCTAssertEqual(VoiceAligner.substitutionCost(b, a), 0.3)
        }
        for value in ["十", "百", "千", "万", "九"] {
            XCTAssertEqual(VoiceAligner.substitutionCost(VoiceAligner.tokenize("1")[0], VoiceAligner.tokenize(value)[0]), 1)
        }
    }

    func testLastOneOrTwoTokensCanFinishALongerScript() {
        let chinese = VoiceAligner.tokenize("今天我们自然表达谢谢")
        XCTAssertEqual(VoiceAligner.align(tokens: chinese, current: chinese.count - 2, recognized: "谢谢").tokenIndex, chinese.count)
        XCTAssertEqual(VoiceAligner.align(tokens: chinese, current: chinese.count - 1, recognized: "谢").tokenIndex, chinese.count)
        let english = VoiceAligner.tokenize("Take a breath and speak naturally today")
        let first = VoiceAligner.align(tokens: english, current: english.count - 2, recognized: "naturally")
        XCTAssertEqual(first.tokenIndex, english.count - 1)
        XCTAssertEqual(VoiceAligner.align(tokens: english, current: first.tokenIndex, recognized: "today").tokenIndex, english.count)
        XCTAssertEqual(VoiceAligner.align(tokens: english, current: english.count - 2, recognized: "naturally today").tokenIndex, english.count)
    }

    func testCumulativeResultFinishesTheLastWord() {
        let tokens = VoiceAligner.tokenize("Take a breath and speak naturally today")
        let first = VoiceAligner.align(tokens: tokens, current: tokens.count - 2, recognized: "naturally")
        XCTAssertEqual(first.tokenIndex, tokens.count - 1)
        XCTAssertEqual(VoiceAligner.align(tokens: tokens, current: first.tokenIndex, recognized: "naturally today").tokenIndex, tokens.count)
        XCTAssertEqual(VoiceAligner.align(tokens: tokens, current: tokens.count - 2, recognized: "and speak naturally").tokenIndex, tokens.count - 1)
    }

    func testShortTailCannotSkipTheImmediateUnreadToken() {
        let tokens = VoiceAligner.tokenize("Take a breath and speak naturally today")
        XCTAssertEqual(VoiceAligner.align(tokens: tokens, current: tokens.count - 2, recognized: "today").tokenIndex, tokens.count - 2)
        XCTAssertEqual(VoiceAligner.align(tokens: tokens, current: tokens.count - 1, recognized: "tomorrow").tokenIndex, tokens.count - 1)
        XCTAssertEqual(VoiceAligner.align(tokens: tokens, current: tokens.count - 3, recognized: "naturally today").tokenIndex, tokens.count - 3)
    }
}
