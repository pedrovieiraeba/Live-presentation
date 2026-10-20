import CompositionEngine
import Diagnostics
import Foundation
import NDIService
import SwiftUI

/// Estado do NDI na interface: SDK disponível ou não, fontes descobertas e a
/// saída NDI. Nada aqui é simulado: sem o SDK, tudo fica indisponível e dito.
@MainActor
final class NDIModel: ObservableObject {
    enum RuntimeState: Equatable {
        case notLoaded
        case available(version: String, path: String)
        case unavailable(String)
    }

    @Published private(set) var runtimeState: RuntimeState = .notLoaded
    @Published private(set) var sources: [NDISourceInfo] = []
    @Published private(set) var outputEnabled = false
    @Published var outputName = "Live Presentation"
    @Published private(set) var maxActiveSources: Int

    var onError: ((String) -> Void)?
    /// Chamado quando o limite de fontes muda (o motor precisa reconciliar).
    var onLimitChanged: ((Int) -> Void)?

    private(set) var runtime: NDIRuntime?
    private var discovery: NDIDiscovery?
    private weak var engine: CompositionEngine?
    private var sender: NDIOutputSender?
    private let log = AppLogger(category: "ndi")
    private static let limitKey = "ndi.maxActiveSources"

    init() {
        let stored = UserDefaults.standard.integer(forKey: Self.limitKey)
        maxActiveSources = stored > 0 ? stored : 2
    }

    var isAvailable: Bool {
        if case .available = runtimeState { return true }
        return false
    }

    var statusDescription: String {
        switch runtimeState {
        case .notLoaded: return "carregando…"
        case .unavailable: return "SDK NDI não instalado"
        case .available:
            var parts = ["\(sources.count) fonte(s) na rede"]
            if outputEnabled { parts.append("saída “\(outputName)”") }
            return parts.joined(separator: " · ")
        }
    }

    /// Carrega o SDK (se instalado) e inicia a descoberta.
    func attach(engine: CompositionEngine?) {
        self.engine = engine
        switch DynamicNDIRuntime.load() {
        case .success(let runtime):
            self.runtime = runtime
            runtimeState = .available(version: runtime.version, path: runtime.libraryPath)
            startDiscovery(runtime)
        case .failure(let error):
            runtime = nil
            runtimeState = .unavailable(error.description)
            log.notice("NDI indisponível: \(error)")
        }
        engine?.setNDIRuntime(runtime, maxActiveSources: maxActiveSources)
    }

    private func startDiscovery(_ runtime: NDIRuntime) {
        do {
            let discovery = try NDIDiscovery(runtime: runtime) { [weak self] sources in
                Task { @MainActor in self?.sources = sources }
            }
            discovery.start()
            self.discovery = discovery
        } catch {
            log.error("Descoberta NDI falhou: \(error)", code: "E-NDI-FIND")
            onError?("A descoberta de fontes NDI falhou: \(error)")
        }
    }

    func setMaxActiveSources(_ value: Int) {
        let clamped = min(max(value, 0), 8)
        guard clamped != maxActiveSources else { return }
        maxActiveSources = clamped
        UserDefaults.standard.set(clamped, forKey: Self.limitKey)
        onLimitChanged?(clamped)
    }

    // MARK: Saída

    func setOutput(enabled: Bool, name: String? = nil) {
        if let name { outputName = name.trimmingCharacters(in: .whitespacesAndNewlines) }
        if outputName.isEmpty { outputName = "Live Presentation" }
        guard enabled else {
            engine?.setNDIOutput(nil)
            sender = nil
            if outputEnabled { log.notice("Saída NDI desligada") }
            outputEnabled = false
            return
        }
        guard let runtime else {
            outputEnabled = false
            onError?("A saída NDI precisa do SDK NDI instalado (veja o README).")
            return
        }
        guard let engine else {
            outputEnabled = false
            onError?("A saída NDI precisa do motor de composição (Metal).")
            return
        }
        // Recria o emissor se o nome mudou.
        if let sender, sender.name == outputName, outputEnabled { return }
        do {
            let newSender = try NDIOutputSender(runtime: runtime, name: outputName)
            engine.setNDIOutput(newSender)
            sender = newSender
            outputEnabled = true
        } catch {
            outputEnabled = false
            log.error("Saída NDI falhou: \(error)", code: "E-NDI-SEND")
            onError?("Não foi possível publicar a saída NDI: \(error)")
        }
    }

    func shutdown() {
        discovery?.stop()
        discovery = nil
        engine?.setNDIOutput(nil)
        sender?.drain()
        sender = nil
    }
}
