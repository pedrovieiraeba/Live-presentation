import XCTest
@testable import PresentationCore

final class ShowControllerTests: XCTestCase {
    /// Dois itens: A (3 slides) e B (2 slides).
    private func makePresentation() -> Presentation {
        var p = Presentation(name: "Teste")
        p.appendItem(PresentationItem(kind: .lyrics, title: "A",
                                      slides: ["a1", "a2", "a3"].map { Slide(text: $0) }))
        p.appendItem(PresentationItem(kind: .text, title: "B",
                                      slides: ["b1", "b2"].map { Slide(text: $0) }, themeID: Theme.scripture.id))
        return p
    }

    private func text(_ frame: OutputFrame) -> String? {
        if case let .slide(text, _) = frame { return text }
        return nil
    }

    func testNothingIsLiveInitially() {
        let show = ShowController(presentation: makePresentation())
        XCTAssertEqual(show.output, .black)
        XCTAssertNil(show.state.live)
    }

    func testPreviewDoesNotAffectOutputUntilTake() {
        var show = ShowController(presentation: makePresentation())
        let addresses = show.presentation.orderedAddresses
        show.selectPreview(addresses[1])
        XCTAssertEqual(show.output, .black, "Prévia nunca deve ir ao ar sozinha")

        XCTAssertEqual(show.take(), .moved(addresses[1]))
        XCTAssertEqual(text(show.output), "a2")
        XCTAssertEqual(show.state.preview, addresses[2], "Prévia avança para o próximo após Take")
    }

    func testNextCrossesItemsAndStopsAtEnd() {
        var show = ShowController(presentation: makePresentation())
        let addresses = show.presentation.orderedAddresses

        XCTAssertEqual(show.next(), .moved(addresses[0]), "Sem nada no ar, Próximo começa do primeiro")
        for expected in addresses.dropFirst() {
            XCTAssertEqual(show.next(), .moved(expected))
        }
        XCTAssertEqual(text(show.output), "b2")
        XCTAssertEqual(show.next(), .atBoundary)
        XCTAssertEqual(text(show.output), "b2", "No fim, a saída permanece estável")
    }

    func testPreviousStopsAtStartAndDoesNothingWhenIdle() {
        var show = ShowController(presentation: makePresentation())
        XCTAssertEqual(show.previous(), .atBoundary)
        XCTAssertEqual(show.output, .black)
        show.next()
        XCTAssertEqual(show.previous(), .atBoundary)
        XCTAssertEqual(text(show.output), "a1")
    }

    func testThemeInheritanceInOutput() {
        var show = ShowController(presentation: makePresentation())
        let addresses = show.presentation.orderedAddresses
        show.goLive(addresses[0])
        XCTAssertEqual(show.output, .slide(text: "a1", themeID: Theme.standardLyrics.id))
        show.goLive(addresses[3])
        XCTAssertEqual(show.output, .slide(text: "b1", themeID: Theme.scripture.id))
    }

    func testClearTextBlackoutAndClearAll() {
        var show = ShowController(presentation: makePresentation())
        show.next()
        show.setTextHidden(true)
        XCTAssertEqual(show.output, .background(themeID: Theme.standardLyrics.id))
        show.setBlackout(true)
        XCTAssertEqual(show.output, .black)
        show.setBlackout(false)
        show.setTextHidden(false)
        XCTAssertEqual(text(show.output), "a1")
        show.next()
        XCTAssertEqual(text(show.output), "a2", "Navegar reexibe o texto")
        show.clearAll()
        XCTAssertEqual(show.output, .black)
        XCTAssertNil(show.state.live)
    }

    func testEditingLiveSlideDoesNotChangeOutputSilently() {
        var show = ShowController(presentation: makePresentation())
        let addresses = show.presentation.orderedAddresses
        show.goLive(addresses[0])

        var edited = show.presentation
        edited.updateItem(id: addresses[0].itemID) { $0.slides[0].text = "a1 editado" }
        show.replacePresentation(edited)

        XCTAssertEqual(text(show.output), "a1")
        XCTAssertTrue(show.liveIsStale)
        show.refreshLive()
        XCTAssertEqual(text(show.output), "a1 editado")
        XCTAssertFalse(show.liveIsStale)
    }

    func testDeletingLiveItemKeepsOutputAndBlocksBlindNavigation() {
        var show = ShowController(presentation: makePresentation())
        let addresses = show.presentation.orderedAddresses
        show.goLive(addresses[3])

        var edited = show.presentation
        edited.removeItem(id: addresses[3].itemID)
        show.replacePresentation(edited)

        XCTAssertEqual(text(show.output), "b1", "Saída permanece até ação do operador")
        XCTAssertTrue(show.liveIsStale)
        XCTAssertEqual(show.next(), .nothingToShow)
    }

    func testPreviewReconciledWhenItsSlideIsRemoved() {
        var show = ShowController(presentation: makePresentation())
        let addresses = show.presentation.orderedAddresses
        show.selectPreview(addresses[4])

        var edited = show.presentation
        edited.removeItem(id: addresses[4].itemID)
        show.replacePresentation(edited)

        XCTAssertEqual(show.state.preview, edited.orderedAddresses.last)
    }

    func testRecoveryNeverPutsContentOnAir() {
        var show = ShowController(presentation: makePresentation())
        let addresses = show.presentation.orderedAddresses
        show.selectPreview(addresses[2])
        show.take()
        let saved = show.state
        XCTAssertNotNil(saved.live)

        let recovered = ShowController.recovered(presentation: show.presentation, saved: saved)
        XCTAssertNil(recovered.state.live)
        XCTAssertEqual(recovered.output, .black)
        XCTAssertEqual(recovered.state.preview, saved.preview)
    }

    func testSelectPreviewIgnoresUnknownAddress() {
        var show = ShowController(presentation: makePresentation())
        show.selectPreview(SlideAddress(itemID: UUID(), slideID: UUID()))
        XCTAssertNil(show.state.preview)
    }

    func testMovePreview() {
        var show = ShowController(presentation: makePresentation())
        let addresses = show.presentation.orderedAddresses
        XCTAssertEqual(show.movePreview(by: 1), .moved(addresses[0]))
        XCTAssertEqual(show.movePreview(by: 1), .moved(addresses[1]))
        XCTAssertEqual(show.movePreview(by: -1), .moved(addresses[0]))
        XCTAssertEqual(show.movePreview(by: -1), .atBoundary)
        XCTAssertEqual(show.output, .black)
    }

    func testEmptyPresentation() {
        var show = ShowController(presentation: Presentation(name: "Vazia"))
        XCTAssertEqual(show.next(), .nothingToShow)
        XCTAssertEqual(show.take(), .nothingToShow)
        XCTAssertEqual(show.movePreview(by: 1), .nothingToShow)
    }
}

final class ShowControllerSwitchingTests: XCTestCase {
    func testOpeningAnotherPresentationKeepsOutput() {
        var first = Presentation(name: "1")
        first.appendItem(PresentationItem(kind: .text, title: "x", slides: [Slide(text: "um"), Slide(text: "dois")]))
        var second = Presentation(name: "2")
        second.appendItem(PresentationItem(kind: .text, title: "y", slides: [Slide(text: "outro")]))

        var show = ShowController(presentation: first)
        show.next()
        XCTAssertTrue(show.liveBelongsToOpenPresentation)

        show.open(second)
        XCTAssertEqual(show.output, .slide(text: "um", themeID: first.defaultThemeID))
        XCTAssertFalse(show.liveBelongsToOpenPresentation)
        XCTAssertEqual(show.state.preview, second.orderedAddresses.first)
        XCTAssertEqual(show.next(), .nothingToShow, "Próximo não salta para a outra apresentação às cegas")

        XCTAssertEqual(show.take(), .moved(second.orderedAddresses[0]))
        XCTAssertEqual(show.output, .slide(text: "outro", themeID: second.defaultThemeID))
    }
}
