import CompositionCore
import Diagnostics
import Foundation
import Persistence
import PresentationCore
import SwiftUI

/// Cenas e camadas na interface. Edições são salvas automaticamente; a cena no
/// ar só muda com "Enviar cena ao ar" ou "Atualizar no ar".
@MainActor
final class SceneModel: ObservableObject {
    @Published private(set) var controller = SceneController(scenes: [.standard])
    @Published var selectedLayerID: UUID?

    /// Chamado sempre que a cena no ar muda.
    var onProgramChanged: ((CompositionScene?) -> Void)?
    var onError: ((String) -> Void)?

    private var store: LibraryStore?
    private var saveTask: Task<Void, Never>?
    private let log = AppLogger(category: "scenes")

    var scenes: [CompositionScene] { controller.scenes }
    var program: CompositionScene? { controller.program }
    var selectedScene: CompositionScene? { controller.selectedScene }

    func attach(store: LibraryStore, programSceneID: UUID?) async {
        self.store = store
        do {
            let scenes = try await store.scenes()
            controller = SceneController(scenes: scenes, programSceneID: programSceneID)
        } catch {
            onError?("Não foi possível carregar as cenas: \(error)")
        }
        onProgramChanged?(controller.program)
    }

    // MARK: Seleção e ar

    func select(sceneID: UUID?) {
        controller.selectedSceneID = sceneID
        selectedLayerID = nil
    }

    func take(sceneID: UUID) {
        guard controller.take(sceneID: sceneID) else { return }
        log.info("Cena no ar: \(controller.program?.name ?? "-")")
        onProgramChanged?(controller.program)
    }

    func refreshProgram() {
        guard controller.refreshProgram() else { return }
        log.info("Cena no ar atualizada: \(controller.program?.name ?? "-")")
        onProgramChanged?(controller.program)
    }

    // MARK: Edição de cenas

    func addScene() {
        let scene = CompositionScene(name: "Nova cena", layers: [
            Layer(content: .solid(RGBAColor(hex: "#101418")!), fitMode: .stretch),
            Layer(content: .presentation(drawsThemeBackground: false), fitMode: .fit),
        ])
        controller.add(scene)
        selectedLayerID = nil
        scheduleSave()
    }

    func duplicate(sceneID: UUID) {
        guard let scene = controller.scene(id: sceneID) else { return }
        controller.add(scene.duplicated())
        scheduleSave()
    }

    func remove(sceneID: UUID) {
        guard controller.remove(sceneID: sceneID) else {
            onError?("A última cena não pode ser apagada.")
            return
        }
        scheduleSave()
    }

    func moveScenes(fromOffsets source: IndexSet, toOffset destination: Int) {
        controller.move(fromOffsets: source, toOffset: destination)
        scheduleSave()
    }

    func edit(sceneID: UUID, _ change: (inout CompositionScene) -> Void) {
        controller.updateScene(id: sceneID, change)
        scheduleSave()
    }

    // MARK: Camadas da cena selecionada

    func addLayer(_ content: LayerContent, name: String? = nil) {
        guard let sceneID = controller.selectedSceneID else { return }
        let fit: FitMode
        switch content {
        case .solid: fit = .stretch
        case .presentation: fit = .fit
        case .image, .video, .ndi: fit = .fill
        }
        let layer = Layer(name: name, content: content, fitMode: fit)
        edit(sceneID: sceneID) { $0.layers.append(layer) }
        selectedLayerID = layer.id
    }

    func editLayer(_ layerID: UUID, _ change: (inout Layer) -> Void) {
        guard let sceneID = controller.selectedSceneID else { return }
        edit(sceneID: sceneID) { $0.updateLayer(id: layerID, change) }
    }

    func removeLayer(_ layerID: UUID) {
        guard let sceneID = controller.selectedSceneID else { return }
        edit(sceneID: sceneID) { $0.removeLayer(id: layerID) }
        if selectedLayerID == layerID { selectedLayerID = nil }
    }

    func moveLayer(_ layerID: UUID, by offset: Int) {
        guard let sceneID = controller.selectedSceneID else { return }
        edit(sceneID: sceneID) { $0.moveLayer(id: layerID, by: offset) }
    }

    // MARK: Persistência

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            await self?.save()
        }
    }

    func flush() async {
        if saveTask != nil {
            saveTask?.cancel()
            saveTask = nil
            await save()
        }
    }

    private func save() async {
        guard let store else { return }
        do {
            try await store.saveScenes(controller.scenes)
        } catch {
            log.error("Falha ao salvar cenas: \(error)", code: "E-SCENES-SAVE")
            onError?("Não foi possível salvar as cenas: \(error)")
        }
    }
}
