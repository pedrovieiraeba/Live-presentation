import Foundation

/// Cenas em edição × cena no ar, com a mesma regra do `ShowController`: o que
/// está no ar é uma cópia; editar a cena não muda a saída sem ação explícita.
public struct SceneController: Sendable {
    public private(set) var scenes: [CompositionScene]
    public var selectedSceneID: UUID?
    public private(set) var program: CompositionScene?

    public init(scenes: [CompositionScene], programSceneID: UUID? = nil) {
        self.scenes = scenes.isEmpty ? [.standard] : scenes
        self.selectedSceneID = self.scenes.first?.id
        if let programSceneID, let scene = self.scenes.first(where: { $0.id == programSceneID }) {
            program = scene
        } else {
            program = self.scenes.first
        }
    }

    public var selectedScene: CompositionScene? {
        selectedSceneID.flatMap { id in scenes.first { $0.id == id } }
    }

    public func scene(id: UUID) -> CompositionScene? { scenes.first { $0.id == id } }

    /// A cena no ar foi alterada (ou removida) depois de enviada.
    public var programIsStale: Bool {
        guard let program else { return false }
        return scene(id: program.id) != program
    }

    @discardableResult
    public mutating func take(sceneID: UUID) -> Bool {
        guard let scene = scene(id: sceneID) else { return false }
        program = scene
        return true
    }

    @discardableResult
    public mutating func refreshProgram() -> Bool {
        guard let program, let current = scene(id: program.id) else { return false }
        self.program = current
        return true
    }

    public mutating func update(_ scene: CompositionScene) {
        guard let index = scenes.firstIndex(where: { $0.id == scene.id }) else { return }
        scenes[index] = scene
    }

    public mutating func updateScene(id: UUID, _ change: (inout CompositionScene) -> Void) {
        guard let index = scenes.firstIndex(where: { $0.id == id }) else { return }
        change(&scenes[index])
    }

    @discardableResult
    public mutating func add(_ scene: CompositionScene) -> CompositionScene {
        scenes.append(scene)
        selectedSceneID = scene.id
        return scene
    }

    /// Remove uma cena. Se ela estiver no ar, a saída continua até outra ação.
    /// A última cena não pode ser removida.
    @discardableResult
    public mutating func remove(sceneID: UUID) -> Bool {
        guard scenes.count > 1, let index = scenes.firstIndex(where: { $0.id == sceneID }) else { return false }
        scenes.remove(at: index)
        if selectedSceneID == sceneID { selectedSceneID = scenes[min(index, scenes.count - 1)].id }
        return true
    }

    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.sorted().map { scenes[$0] }
        var remaining = scenes.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let adjusted = destination - source.filter { $0 < destination }.count
        remaining.insert(contentsOf: moving, at: min(max(adjusted, 0), remaining.count))
        scenes = remaining
    }
}
