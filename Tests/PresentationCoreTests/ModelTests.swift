import XCTest
@testable import PresentationCore

final class LyricsParserTests: XCTestCase {
    func testSplitsOnBlankLinesAndReadsLabels() {
        let source = """
        [Verso 1]
        Linha um
        Linha dois


        Linha três

        [Refrão]
          Linha quatro
        """
        let blocks = LyricsParser.blocks(from: source)
        XCTAssertEqual(blocks, [
            .init(label: "Verso 1", text: "Linha um\nLinha dois"),
            .init(label: "Verso 1", text: "Linha três"),
            .init(label: "Refrão", text: "Linha quatro"),
        ])
    }

    func testMaxLinesPerSlide() {
        let source = (1...5).map { "L\($0)" }.joined(separator: "\n")
        let blocks = LyricsParser.blocks(from: source, maxLinesPerSlide: 2)
        XCTAssertEqual(blocks.map(\.text), ["L1\nL2", "L3\nL4", "L5"])
    }

    func testHandlesWindowsLineEndingsAndEmptyInput() {
        XCTAssertEqual(LyricsParser.blocks(from: "a\r\nb\r\n\r\nc").map(\.text), ["a\nb", "c"])
        XCTAssertTrue(LyricsParser.blocks(from: "  \n\n ").isEmpty)
    }

    func testReparseKeepsSlideIdentityByPosition() {
        let original = LyricsParser.slides(from: "a\n\nb")
        var themed = original
        themed[0].themeID = Theme.scripture.id
        let edited = LyricsParser.slides(from: "a editado\n\nb\n\nc", reusing: themed)
        XCTAssertEqual(edited.count, 3)
        XCTAssertEqual(edited[0].id, original[0].id)
        XCTAssertEqual(edited[0].text, "a editado")
        XCTAssertEqual(edited[0].themeID, Theme.scripture.id, "Tema por slide sobrevive à reedição")
        XCTAssertEqual(edited[1].id, original[1].id)
    }

    func testRoundTrip() {
        let source = "[Verso]\nx\ny\n\nz\n\n[Refrão]\nw"
        let slides = LyricsParser.slides(from: source)
        XCTAssertEqual(LyricsParser.source(from: slides), source)
    }
}

final class PresentationModelTests: XCTestCase {
    func testDuplicateCreatesNewIdentifiersEverywhere() {
        let original = SampleContent.welcomePresentation()
        let copy = original.duplicated()
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertEqual(copy.name, "\(original.name) (cópia)")
        XCTAssertEqual(copy.slideCount, original.slideCount)
        let originalIDs = Set(original.orderedAddresses.flatMap { [$0.itemID, $0.slideID] })
        let copyIDs = Set(copy.orderedAddresses.flatMap { [$0.itemID, $0.slideID] })
        XCTAssertTrue(originalIDs.isDisjoint(with: copyIDs))
    }

    func testDuplicateSlideAndApplyTheme() {
        var p = Presentation(name: "x")
        p.appendItem(PresentationItem(kind: .text, title: "t", slides: [Slide(text: "1"), Slide(text: "2")]))
        let first = p.orderedAddresses[0]
        let dup = p.duplicateSlide(at: first)!
        XCTAssertEqual(p.orderedAddresses.map { p.slide(at: $0)!.text }, ["1", "1", "2"])
        XCTAssertEqual(p.position(of: dup), 1)

        p.applyTheme(Theme.lowerThird.id, to: [first, dup])
        XCTAssertEqual(p.themeID(for: first), Theme.lowerThird.id)
        XCTAssertEqual(p.themeID(for: p.orderedAddresses[2]), p.defaultThemeID)
    }

    func testMoveItem() {
        var p = Presentation(name: "x")
        let a = p.appendItem(PresentationItem(kind: .text, title: "a"))
        let b = p.appendItem(PresentationItem(kind: .text, title: "b"))
        p.moveItem(from: 0, to: 5)
        XCTAssertEqual(p.items.map(\.id), [b.id, a.id])
        p.moveItem(from: 9, to: 0)
        XCTAssertEqual(p.items.map(\.id), [b.id, a.id])
    }

    func testDecodingToleratesMissingOptionalFields() throws {
        let id = UUID()
        let itemID = UUID()
        let slideID = UUID()
        let json = """
        {"id":"\(id)","name":"Antiga","items":[{"id":"\(itemID)","kind":"desconhecido",
         "slides":[{"id":"\(slideID)","text":"oi"}]}]}
        """
        let p = try JSONDecoder().decode(Presentation.self, from: Data(json.utf8))
        XCTAssertEqual(p.items.first?.kind, .text, "Tipo desconhecido cai para texto")
        XCTAssertEqual(p.slide(at: SlideAddress(itemID: itemID, slideID: slideID))?.text, "oi")
        XCTAssertEqual(p.defaultThemeID, Theme.standardLyrics.id)
    }
}

final class ThemeTests: XCTestCase {
    func testHexColorParsing() {
        XCTAssertEqual(RGBAColor(hex: "#FFF"), .white)
        XCTAssertEqual(RGBAColor(hex: "000000"), .black)
        XCTAssertEqual(RGBAColor(hex: "#FF000080")?.alpha ?? 0, 128.0 / 255, accuracy: 0.0001)
        XCTAssertNil(RGBAColor(hex: "#12"))
        XCTAssertNil(RGBAColor(hex: "zzzzzz"))
        XCTAssertEqual(RGBAColor(hex: "#14161A")?.hexString, "#14161A")
    }

    func testSafeArea() {
        let area = Theme.standardLyrics.safeArea(in: CanvasSize(width: 1920, height: 1080))
        XCTAssertEqual(area, CanvasRect(x: 192, y: 108, width: 1536, height: 864))
    }

    func testBuiltInThemeIDsAreUnique() {
        XCTAssertEqual(Set(Theme.builtIn.map(\.id)).count, Theme.builtIn.count)
    }
}

final class TextFitEstimatorTests: XCTestCase {
    func testShortTextFits() {
        let report = HeuristicTextFitEstimator().measure("Santo, Santo, Santo", theme: .standardLyrics,
                                                          canvas: Theme.referenceCanvas)
        XCTAssertEqual(report.estimatedLines, 1)
        XCTAssertFalse(report.overflows)
    }

    func testLongTextOverflows() {
        let text = Array(repeating: "Uma linha bastante longa de letra de música", count: 12).joined(separator: "\n")
        let report = HeuristicTextFitEstimator().measure(text, theme: .standardLyrics,
                                                          canvas: Theme.referenceCanvas)
        XCTAssertTrue(report.overflows)
    }

    func testResultIsResolutionIndependent() {
        let text = "Grande é o Senhor e mui digno de louvor"
        let estimator = HeuristicTextFitEstimator()
        let hd = estimator.measure(text, theme: .standardLyrics, canvas: CanvasSize(width: 1920, height: 1080))
        let uhd = estimator.measure(text, theme: .standardLyrics, canvas: CanvasSize(width: 3840, height: 2160))
        XCTAssertEqual(hd.estimatedLines, uhd.estimatedLines)
        XCTAssertEqual(hd.maxLines, uhd.maxLines)
    }
}
