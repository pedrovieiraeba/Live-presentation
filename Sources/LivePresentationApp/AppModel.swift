import AppKit
import Diagnostics
import Persistence
import PresentationCore
import SwiftUI

enum SaveStatus: Equatable {
    case saved
    case pending
    case failed(String)
    /// Biblioteca em memória: nada será gravado em disco.
    case volatile
}

/// Estado central do app no lado do operador. Toda mutação passa por aqui, na
/// main actor; persistência roda no actor `LibraryStore`.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var summaries: [PresentationSummary] = []
    @Published private(set) var themes: [Theme] = Theme.builtIn
    @Published private(set) var show: ShowController?
    @Published var selectedItemID: UUID?
    @Published private(set) var saveStatus: SaveStatus = .saved
    @Published var alertMessage: String?
    @Published private(set) var isBootstrapped = false

    let output = OutputWindowController()
    let fitMeasurer: TextFitMeasuring = AppKitTextFitMeasurer()

    private var store: LibraryStore?
    private var autosaveTask: Task<Void, Never>?
    private var sessionTask: Task<Void, Never>?
    private let log = AppLogger(category: "app")

    init() {
        output.contentProvider = { [unowned self] in
            AnyView(OutputRootView().environmentObject(self))
        }
        output.onTargetLost = { [weak self] message in
            self?.alertMessage = message
        }
    }

    // MARK: Ciclo de vida

    func bootstrap() async {
        guard !isBootstrapped else { return }
        isBootstrapped = true
        log.info("Iniciando sessão \(DiagnosticsSession.id)")

        do {
            let url = try LibraryStore.defaultURL()
            store = try LibraryStore(path: url.path)
            log.info("Biblioteca em \(url.path)")
        } catch {
            log.error("Falha ao abrir a biblioteca: \(error)", code: "E-LIBRARY-OPEN")
            alertMessage = "Não foi possível abrir a biblioteca (\(error)). O app está usando uma biblioteca temporária: nada será salvo."
            store = try? LibraryStore(path: ":memory:")
            saveStatus = .volatile
        }
        guard let store else { return }

        do {
            themes = try await store.themes()
            summaries = try await store.summaries()
            if summaries.isEmpty {
                let sample = SampleContent.welcomePresentation()
                try await store.save(sample)
                summaries = try await store.summaries()
            }
        } catch {
            report(error, code: "E-LIBRARY-LOAD", "Falha ao carregar a biblioteca")
        }

        // Recuperação: reabre a apresentação e a prévia, nunca o ar.
        let session = await store.loadSession()
        let targetID = session?.activePresentationID.flatMap { id in summaries.first { $0.id == id }?.id }
            ?? summaries.first?.id
        if let targetID, let presentation = try? await store.presentation(id: targetID) {
            show = ShowController.recovered(presentation: presentation, saved: session?.showState)
            selectedItemID = presentation.items.first?.id
            if session != nil { log.notice("Sessão anterior restaurada (sem conteúdo no ar)") }
        }
        output.refreshScreens()
    }

    func prepareForTermination() async {
        output.close()
        await flushPendingWrites()
        log.info("Encerramento controlado")
    }

    // MARK: Biblioteca

    var openPresentationID: UUID? { show?.presentation.id }

    func openPresentation(id: UUID) async {
        guard id != openPresentationID, let store else { return }
        await flushPendingWrites()
        do {
            let presentation = try await store.presentation(id: id)
            if show == nil {
                show = ShowController(presentation: presentation)
            } else {
                show?.open(presentation)
            }
            selectedItemID = presentation.items.first?.id
            scheduleSessionSave()
        } catch {
            report(error, code: "E-PRESENTATION-OPEN", "Não foi possível abrir a apresentação")
        }
    }

    func createPresentation() async {
        guard let store else { return }
        var presentation = Presentation(name: "Nova apresentação")
        presentation.appendItem(PresentationItem(kind: .lyrics, title: "Nova música",
                                                 slides: [Slide(text: "Digite a letra no editor")]))
        do {
            try await store.save(presentation)
            summaries = try await store.summaries()
            await openPresentation(id: presentation.id)
        } catch {
            report(error, code: "E-PRESENTATION-CREATE", "Não foi possível criar a apresentação")
        }
    }

    func duplicatePresentation(id: UUID) async {
        guard let store else { return }
        await flushPendingWrites()
        do {
            let copy = try await store.duplicatePresentation(id: id)
            summaries = try await store.summaries()
            await openPresentation(id: copy.id)
        } catch {
            report(error, code: "E-PRESENTATION-DUPLICATE", "Não foi possível duplicar a apresentação")
        }
    }

    func deletePresentation(id: UUID) async {
        guard let store else { return }
        do {
            if id == openPresentationID {
                autosaveTask?.cancel()
                autosaveTask = nil
            }
            try await store.deletePresentation(id: id)
            summaries = try await store.summaries()
            if id == openPresentationID {
                if let next = summaries.first {
                    await openPresentation(id: next.id)
                } else if var current = show {
                    // Mantém o ar; apenas esvazia o painel.
                    current.open(Presentation(name: "Sem apresentação"))
                    show = current
                }
            }
        } catch {
            report(error, code: "E-PRESENTATION-DELETE", "Não foi possível apagar a apresentação")
        }
    }

    // MARK: Edição

    /// Aplica uma edição à apresentação aberta e agenda o salvamento automático.
    func edit(_ change: (inout Presentation) -> Void) {
        guard var current = show else { return }
        var presentation = current.presentation
        change(&presentation)
        presentation.touch()
        current.replacePresentation(presentation)
        show = current
        scheduleAutosave()
    }

    func addItem(kind: ItemKind) {
        let item = PresentationItem(
            kind: kind,
            title: kind.displayName,
            slides: [Slide(text: kind == .lyrics ? "[Verso 1]\nPrimeira linha" : "Novo texto")],
            themeID: kind == .scripture ? Theme.scripture.id : nil)
        edit { $0.appendItem(item) }
        selectedItemID = item.id
    }

    func updateItemSource(itemID: UUID, source: String, maxLinesPerSlide: Int?) {
        edit { presentation in
            presentation.updateItem(id: itemID) { item in
                item.slides = LyricsParser.slides(from: source, reusing: item.slides,
                                                  maxLinesPerSlide: maxLinesPerSlide)
            }
        }
    }

    func theme(id: UUID) -> Theme {
        themes.first { $0.id == id } ?? .standardLyrics
    }

    func saveTheme(_ theme: Theme) async {
        guard let store else { return }
        do {
            try await store.save(theme)
            themes = try await store.themes()
        } catch {
            report(error, code: "E-THEME-SAVE", "Não foi possível salvar o tema")
        }
    }

    func fitReport(for address: SlideAddress) -> TextFitReport? {
        guard let presentation = show?.presentation, let slide = presentation.slide(at: address) else { return nil }
        return fitMeasurer.measure(slide.text, theme: theme(id: presentation.themeID(for: address)),
                                   canvas: Theme.referenceCanvas)
    }

    // MARK: Operação ao vivo

    var showState: ShowState? { show?.state }
    var isSomethingLive: Bool { show?.state.live != nil }

    func selectPreview(_ address: SlideAddress) { mutateShow { $0.selectPreview(address) } }
    func goLive(_ address: SlideAddress) { mutateShow { $0.goLive(address) } }
    func take() { mutateShow { $0.take() } }
    func next() { mutateShow { $0.next() } }
    func previous() { mutateShow { $0.previous() } }
    func refreshLive() { mutateShow { $0.refreshLive() } }
    func clearAll() { mutateShow { $0.clearAll() } }
    func toggleTextHidden() { mutateShow { $0.setTextHidden(!$0.state.textHidden) } }
    func toggleBlackout() { mutateShow { $0.setBlackout(!$0.state.blackout) } }

    private func mutateShow(_ action: (inout ShowController) -> Void) {
        guard var current = show else { return }
        let before = current.state
        action(&current)
        show = current
        if before.live != current.state.live || before.blackout != current.state.blackout
            || before.textHidden != current.state.textHidden {
            log.info("Saída: \(describe(current.output))")
        }
        scheduleSessionSave()
    }

    private func describe(_ frame: OutputFrame) -> String {
        switch frame {
        case .black: return "preto"
        case .background: return "fundo sem texto"
        case let .slide(text, _): return "slide \"\(text.prefix(40))\""
        }
    }

    // MARK: Persistência

    private func scheduleAutosave() {
        guard saveStatus != .volatile else { return }
        saveStatus = .pending
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            await self?.saveOpenPresentation()
        }
    }

    private func saveOpenPresentation() async {
        guard let store, let presentation = show?.presentation else { return }
        do {
            try await store.save(presentation)
            summaries = try await store.summaries()
            if saveStatus != .volatile { saveStatus = .saved }
        } catch {
            saveStatus = .failed("\(error)")
            log.error("Falha ao salvar \(presentation.id): \(error)", code: "E-AUTOSAVE")
        }
    }

    private func scheduleSessionSave() {
        sessionTask?.cancel()
        sessionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await self?.saveSession()
        }
    }

    private func saveSession() async {
        guard let store else { return }
        let snapshot = SessionSnapshot(activePresentationID: show?.presentation.id,
                                       showState: show?.state,
                                       outputScreenName: output.target?.displayName)
        do {
            try await store.saveSession(snapshot)
        } catch {
            log.warning("Falha ao salvar estado da sessão: \(error)", code: "W-SESSION-SAVE")
        }
    }

    private func flushPendingWrites() async {
        if autosaveTask != nil {
            autosaveTask?.cancel()
            autosaveTask = nil
            if saveStatus == .pending { await saveOpenPresentation() }
        }
        sessionTask?.cancel()
        sessionTask = nil
        await saveSession()
    }

    private func report(_ error: Error, code: String, _ message: String) {
        log.error("\(message): \(error)", code: code)
        alertMessage = "\(message).\n\n\(error)"
    }
}
