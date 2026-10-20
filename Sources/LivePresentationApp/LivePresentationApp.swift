import AppKit
import SwiftUI

@main
struct LivePresentationApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Live Presentation", id: "operator") {
            OperatorView()
                .environmentObject(model)
                .frame(minWidth: 1100, minHeight: 680)
                .task {
                    appDelegate.model = model
                    await model.bootstrap()
                }
        }
        .commands { OperatorCommands(model: model) }

        Window("Diagnóstico", id: "diagnostics") {
            DiagnosticsView()
                .environmentObject(model)
                .frame(minWidth: 640, minHeight: 420)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Necessário quando o app é executado via SwiftPM (sem bundle .app).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }

        if model.isSomethingLive {
            let alert = NSAlert()
            alert.messageText = "Há conteúdo no ar"
            alert.informativeText = "Encerrar o aplicativo apaga a saída de apresentação imediatamente."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Cancelar")
            alert.addButton(withTitle: "Encerrar mesmo assim")
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }

        Task { @MainActor in
            await model.prepareForTermination()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct OperatorCommands: Commands {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Nova apresentação") { Task { await model.createPresentation() } }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        CommandMenu("Operação") {
            Button("Enviar prévia ao ar") { model.take() }
                .keyboardShortcut(.return, modifiers: .command)
            Button("Próximo slide") { model.next() }
                .keyboardShortcut(.pageDown, modifiers: [])
            Button("Slide anterior") { model.previous() }
                .keyboardShortcut(.pageUp, modifiers: [])
            Divider()
            Button(model.showState?.textHidden == true ? "Mostrar texto" : "Ocultar texto") {
                model.toggleTextHidden()
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            Button(model.showState?.blackout == true ? "Sair da tela preta" : "Tela preta") {
                model.toggleBlackout()
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])
            Button("Limpar tudo") { model.clearAll() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Divider()
            Button("Abrir saída em janela") { model.output.show(.window) }
            Button("Fechar saída") { model.output.close() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }

        CommandGroup(after: .windowArrangement) {
            Button("Diagnóstico") { openWindow(id: "diagnostics") }
                .keyboardShortcut("d", modifiers: [.command, .option])
        }
    }
}
