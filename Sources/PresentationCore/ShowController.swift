import Foundation

/// O que está efetivamente no ar. É uma cópia (snapshot) do slide no momento em
/// que foi enviado: editar ou apagar o slide na apresentação não altera a saída
/// silenciosamente — só uma nova ação do operador muda o que o público vê.
public struct LiveSnapshot: Codable, Hashable, Sendable {
    public var address: SlideAddress
    public var text: String
    public var label: String
    public var themeID: UUID

    public init(address: SlideAddress, text: String, label: String, themeID: UUID) {
        self.address = address
        self.text = text
        self.label = label
        self.themeID = themeID
    }
}

/// Estado do operador: o que está em preparação (prévia) e o que está no ar.
public struct ShowState: Codable, Hashable, Sendable {
    public var preview: SlideAddress?
    public var live: LiveSnapshot?
    /// Texto oculto, fundo do tema mantido.
    public var textHidden: Bool
    /// Saída totalmente preta, independentemente do restante.
    public var blackout: Bool

    public init(preview: SlideAddress? = nil, live: LiveSnapshot? = nil, textHidden: Bool = false, blackout: Bool = false) {
        self.preview = preview
        self.live = live
        self.textHidden = textHidden
        self.blackout = blackout
    }
}

/// O que a janela de saída deve desenhar. Não contém nada de interface.
public enum OutputFrame: Hashable, Sendable {
    case black
    case background(themeID: UUID)
    case slide(text: String, themeID: UUID)
}

public enum NavigationResult: Equatable, Sendable {
    case moved(SlideAddress)
    case atBoundary
    case nothingToShow
}

/// Máquina de estados pura da operação ao vivo. Não depende de UI nem de
/// relógio, o que a torna integralmente testável.
public struct ShowController: Sendable {
    public private(set) var presentation: Presentation
    public private(set) var state: ShowState
    /// Após "Enviar ao ar", a prévia avança para o slide seguinte.
    public var advancePreviewOnTake: Bool

    public init(presentation: Presentation, state: ShowState = ShowState(), advancePreviewOnTake: Bool = true) {
        self.presentation = presentation
        self.state = state
        self.advancePreviewOnTake = advancePreviewOnTake
        reconcilePreview()
    }

    /// Estado para retomar após encerramento inesperado: a prévia é restaurada,
    /// mas nada vai ao ar automaticamente.
    public static func recovered(presentation: Presentation, saved: ShowState?) -> ShowController {
        let state = ShowState(preview: saved?.preview, live: nil, textHidden: false, blackout: false)
        return ShowController(presentation: presentation, state: state)
    }

    // MARK: Saída

    public var output: OutputFrame {
        if state.blackout { return .black }
        guard let live = state.live else { return .black }
        if state.textHidden { return .background(themeID: live.themeID) }
        return .slide(text: live.text, themeID: live.themeID)
    }

    public var livePosition: Int? {
        state.live.flatMap { presentation.position(of: $0.address) }
    }

    public var previewPosition: Int? {
        state.preview.flatMap { presentation.position(of: $0) }
    }

    /// O slide no ar pertence à apresentação aberta (e ainda existe nela).
    public var liveBelongsToOpenPresentation: Bool {
        guard let live = state.live else { return false }
        return presentation.slide(at: live.address) != nil
    }

    /// Indica que o slide no ar foi editado ou removido depois de enviado.
    public var liveIsStale: Bool {
        guard let live = state.live else { return false }
        guard let current = presentation.slide(at: live.address) else { return true }
        return current.text != live.text || presentation.themeID(for: live.address) != live.themeID
    }

    // MARK: Prévia

    public mutating func selectPreview(_ address: SlideAddress?) {
        guard let address else { state.preview = nil; return }
        guard presentation.slide(at: address) != nil else { return }
        state.preview = address
    }

    @discardableResult
    public mutating func movePreview(by offset: Int) -> NavigationResult {
        let addresses = presentation.orderedAddresses
        guard !addresses.isEmpty else { return .nothingToShow }
        guard let current = previewPosition else {
            state.preview = offset >= 0 ? addresses.first : addresses.last
            return .moved(state.preview!)
        }
        let target = current + offset
        guard addresses.indices.contains(target) else { return .atBoundary }
        state.preview = addresses[target]
        return .moved(addresses[target])
    }

    // MARK: Ar

    /// Envia a prévia ao ar.
    @discardableResult
    public mutating func take() -> NavigationResult {
        guard let preview = state.preview, presentation.slide(at: preview) != nil else { return .nothingToShow }
        goLive(preview)
        if advancePreviewOnTake, let pos = presentation.position(of: preview) {
            let addresses = presentation.orderedAddresses
            if addresses.indices.contains(pos + 1) { state.preview = addresses[pos + 1] }
        }
        return .moved(preview)
    }

    /// Envia um slide específico diretamente ao ar (ex.: duplo clique).
    @discardableResult
    public mutating func goLive(_ address: SlideAddress) -> NavigationResult {
        guard let slide = presentation.slide(at: address) else { return .nothingToShow }
        state.live = LiveSnapshot(address: address, text: slide.text, label: slide.label,
                                  themeID: presentation.themeID(for: address))
        state.textHidden = false
        state.blackout = false
        return .moved(address)
    }

    @discardableResult
    public mutating func next() -> NavigationResult { stepLive(by: 1) }

    @discardableResult
    public mutating func previous() -> NavigationResult { stepLive(by: -1) }

    private mutating func stepLive(by offset: Int) -> NavigationResult {
        let addresses = presentation.orderedAddresses
        guard !addresses.isEmpty else { return .nothingToShow }

        // Nada no ar: "Próximo" começa pela prévia (ou pelo primeiro slide).
        guard let live = state.live else {
            guard offset > 0 else { return .atBoundary }
            return goLive(state.preview ?? addresses[0])
        }
        // Slide no ar foi removido: não adivinhar; o operador decide.
        guard let current = presentation.position(of: live.address) else { return .nothingToShow }
        let target = current + offset
        guard addresses.indices.contains(target) else { return .atBoundary }
        let result = goLive(addresses[target])
        if advancePreviewOnTake, addresses.indices.contains(target + 1) {
            state.preview = addresses[target + 1]
        }
        return result
    }

    /// Reenvia o slide no ar com o conteúdo atual (após edição).
    @discardableResult
    public mutating func refreshLive() -> NavigationResult {
        guard let live = state.live else { return .nothingToShow }
        return goLive(live.address)
    }

    public mutating func setTextHidden(_ hidden: Bool) { state.textHidden = hidden }
    public mutating func setBlackout(_ on: Bool) { state.blackout = on }

    /// Limpa tudo: nada no ar.
    public mutating func clearAll() {
        state.live = nil
        state.textHidden = false
        state.blackout = false
    }

    // MARK: Troca e edição de apresentação

    /// Abre outra apresentação sem tocar no que está no ar: a troca de documento
    /// no painel do operador nunca muda a saída por conta própria.
    public mutating func open(_ newPresentation: Presentation, preview: SlideAddress? = nil) {
        presentation = newPresentation
        state.preview = nil
        selectPreview(preview ?? newPresentation.orderedAddresses.first)
    }

    /// Substitui a apresentação (após edição). O que está no ar continua sendo o
    /// snapshot; a prévia é reconciliada se o slide deixou de existir.
    public mutating func replacePresentation(_ newValue: Presentation) {
        let oldPosition = previewPosition
        presentation = newValue
        reconcilePreview(fallbackPosition: oldPosition)
    }

    private mutating func reconcilePreview(fallbackPosition: Int? = nil) {
        guard let preview = state.preview, presentation.slide(at: preview) == nil else { return }
        let addresses = presentation.orderedAddresses
        if let pos = fallbackPosition, !addresses.isEmpty {
            state.preview = addresses[min(pos, addresses.count - 1)]
        } else {
            state.preview = nil
        }
    }
}
