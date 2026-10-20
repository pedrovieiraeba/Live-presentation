import AppKit
import Diagnostics
import SwiftUI

/// Uma tela física disponível para a saída.
struct OutputScreen: Hashable, Identifiable {
    let id: CGDirectDisplayID
    let name: String
    let frame: CGRect
    /// Tela principal (com a barra de menus). Nunca é usada em tela cheia, para
    /// que o operador não perca acesso aos controles.
    let isPrimary: Bool

    var resolutionLabel: String { "\(Int(frame.width))×\(Int(frame.height)) pt" }
}

enum OutputTarget: Hashable {
    /// Janela comum, redimensionável (monitor único, ensaio, captura).
    case window
    /// Tela cheia, sem bordas, numa tela secundária.
    case screen(OutputScreen)

    var displayName: String {
        switch self {
        case .window: return "Janela"
        case .screen(let screen): return screen.name
        }
    }
}

/// Gerencia a janela de saída limpa: sem controles, sem cursor, sem foco.
@MainActor
final class OutputWindowController: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var screens: [OutputScreen] = []
    @Published private(set) var target: OutputTarget?

    var contentProvider: (() -> AnyView)?
    var onTargetLost: ((String) -> Void)?

    private var window: NSWindow?
    private var screenObserver: NSObjectProtocol?
    private let log = AppLogger(category: "output")

    override init() {
        super.init()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        refreshScreens()
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    var isOpen: Bool { window != nil }

    func refreshScreens() {
        screens = NSScreen.screens.enumerated().compactMap { index, screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return nil }
            return OutputScreen(id: CGDirectDisplayID(number.uint32Value), name: screen.localizedName,
                                frame: screen.frame, isPrimary: index == 0)
        }
    }

    func show(_ newTarget: OutputTarget) {
        if case .screen(let screen) = newTarget, screen.isPrimary {
            log.warning("Tentativa de saída em tela cheia na tela principal recusada", code: "W-OUTPUT-PRIMARY")
            onTargetLost?("A saída em tela cheia não pode ocupar a tela principal (a dos controles). Use uma tela secundária ou o modo janela.")
            return
        }
        closeWindow()
        guard let content = contentProvider?() else { return }

        let newWindow: NSWindow
        switch newTarget {
        case .window:
            newWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
                                 styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                 backing: .buffered, defer: false)
            newWindow.title = "Saída"
            newWindow.contentAspectRatio = NSSize(width: 16, height: 9)
            newWindow.center()
        case .screen(let screen):
            guard let nsScreen = nsScreen(for: screen.id) else {
                onTargetLost?("A tela \(screen.name) não está mais disponível.")
                return
            }
            newWindow = NSWindow(contentRect: nsScreen.frame, styleMask: [.borderless],
                                 backing: .buffered, defer: false)
            newWindow.setFrame(nsScreen.frame, display: true)
            newWindow.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
            newWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            newWindow.ignoresMouseEvents = true
            newWindow.hasShadow = false
        }

        newWindow.isReleasedWhenClosed = false
        newWindow.backgroundColor = .black
        newWindow.delegate = self
        newWindow.contentView = NSHostingView(rootView: content)
        // Não rouba o foco do operador.
        newWindow.orderFrontRegardless()

        window = newWindow
        target = newTarget
        log.notice("Saída aberta em: \(newTarget.displayName)")
    }

    func close() {
        guard window != nil else { return }
        closeWindow()
        log.notice("Saída fechada")
    }

    private func closeWindow() {
        window?.delegate = nil
        window?.orderOut(nil)
        window?.close()
        window = nil
        target = nil
    }

    private func nsScreen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
    }

    /// Tela removida ou reconfigurada: comportamento explícito, nunca silencioso.
    private func screensChanged() {
        refreshScreens()
        guard case .screen(let current) = target else { return }
        if let updated = screens.first(where: { $0.id == current.id }), !updated.isPrimary {
            if updated.frame != current.frame {
                log.notice("Tela \(updated.name) mudou de resolução; reposicionando a saída")
                show(.screen(updated))
            }
        } else {
            log.warning("Tela de saída \(current.name) desconectada; saída movida para janela", code: "W-OUTPUT-LOST")
            show(.window)
            onTargetLost?("A tela de saída \(current.name) foi desconectada. A saída foi aberta em uma janela.")
        }
    }

    // MARK: NSWindowDelegate

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard (notification.object as? NSWindow) === window else { return }
            window = nil
            target = nil
            log.notice("Janela de saída fechada pelo operador")
        }
    }
}
