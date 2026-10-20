import XCTest
@testable import CompositionCore
import PresentationCore

final class LayerLayoutTests: XCTestCase {
    private let canvas = CanvasSize(width: 1920, height: 1080)

    func testFitLetterboxesTallSource() {
        let layer = Layer(content: .image(assetID: UUID()), fitMode: .fit)
        let quad = LayerLayout.quad(for: layer, sourceSize: CanvasSize(width: 1000, height: 1000), canvas: canvas)!
        XCTAssertEqual(quad.destination, CanvasRect(x: 420, y: 0, width: 1080, height: 1080))
        XCTAssertEqual(quad.source, CanvasRect(x: 0, y: 0, width: 1, height: 1))
    }

    func testFillCoversCanvas() {
        let layer = Layer(content: .image(assetID: UUID()), fitMode: .fill)
        let quad = LayerLayout.quad(for: layer, sourceSize: CanvasSize(width: 1000, height: 1000), canvas: canvas)!
        XCTAssertEqual(quad.destination, CanvasRect(x: 0, y: -420, width: 1920, height: 1920))
    }

    func testStretchAndTransform() {
        let layer = Layer(content: .solid(.white),
                          transform: LayerTransform(centerX: 0.75, centerY: 0.25, scale: 0.5),
                          fitMode: .stretch)
        let quad = LayerLayout.quad(for: layer, sourceSize: CanvasSize(width: 1, height: 1), canvas: canvas)!
        XCTAssertEqual(quad.destination, CanvasRect(x: 960, y: 0, width: 960, height: 540))
    }

    func testCropChangesSourceRectAndAspect() {
        let layer = Layer(content: .image(assetID: UUID()),
                          crop: CropInsets(top: 0, left: 0.25, bottom: 0, right: 0.25), fitMode: .fit)
        // 1920×1080 recortado 50% na largura → 960×1080 → encaixa em 960×1080.
        let quad = LayerLayout.quad(for: layer, sourceSize: canvas, canvas: canvas)!
        XCTAssertEqual(quad.source, CanvasRect(x: 0.25, y: 0, width: 0.5, height: 1))
        XCTAssertEqual(quad.destination, CanvasRect(x: 480, y: 0, width: 960, height: 1080))
    }

    func testInvisibleOrDegenerateLayersProduceNothing() {
        var layer = Layer(content: .solid(.white))
        layer.isVisible = false
        XCTAssertNil(LayerLayout.quad(for: layer, sourceSize: canvas, canvas: canvas))
        layer.isVisible = true
        layer.opacity = 0
        XCTAssertNil(LayerLayout.quad(for: layer, sourceSize: canvas, canvas: canvas))
        layer.opacity = 1
        layer.crop = CropInsets(top: 0.6, left: 0, bottom: 0.6, right: 0)
        XCTAssertNil(LayerLayout.quad(for: layer, sourceSize: canvas, canvas: canvas))
        layer.crop = .none
        XCTAssertNil(LayerLayout.quad(for: layer, sourceSize: CanvasSize(width: 0, height: 0), canvas: canvas))
    }

    func testNormalizedDeviceRect() {
        let (x0, yTop, x1, yBottom) = LayerLayout.normalizedDeviceRect(
            CanvasRect(x: 0, y: 0, width: 960, height: 540), canvas: canvas)
        XCTAssertEqual(x0, -1); XCTAssertEqual(yTop, 1); XCTAssertEqual(x1, 0); XCTAssertEqual(yBottom, 0)
    }

    func testResolutionIndependence() {
        let layer = Layer(content: .image(assetID: UUID()), fitMode: .fit)
        let source = CanvasSize(width: 800, height: 600)
        let hd = LayerLayout.quad(for: layer, sourceSize: source, canvas: canvas)!.destination
        let uhd = LayerLayout.quad(for: layer, sourceSize: source,
                                   canvas: CanvasSize(width: 3840, height: 2160))!.destination
        XCTAssertEqual(uhd.width, hd.width * 2, accuracy: 0.0001)
        XCTAssertEqual(uhd.x, hd.x * 2, accuracy: 0.0001)
    }
}

final class SceneControllerTests: XCTestCase {
    func testDefaultsToStandardSceneOnAir() {
        let controller = SceneController(scenes: [])
        XCTAssertEqual(controller.program, .standard)
        XCTAssertFalse(controller.programIsStale)
    }

    func testEditingProgramSceneDoesNotChangeOutputUntilRefresh() {
        let background = CompositionScene(name: "Fundo", layers: [Layer(content: .solid(.black))])
        var controller = SceneController(scenes: [.standard, background])
        XCTAssertTrue(controller.take(sceneID: background.id))

        controller.updateScene(id: background.id) { $0.layers[0].opacity = 0.5 }
        XCTAssertEqual(controller.program?.layers[0].opacity, 1)
        XCTAssertTrue(controller.programIsStale)

        controller.refreshProgram()
        XCTAssertEqual(controller.program?.layers[0].opacity, 0.5)
        XCTAssertFalse(controller.programIsStale)
    }

    func testRemovingProgramSceneKeepsOutputAndLastSceneIsProtected() {
        let other = CompositionScene(name: "Outra")
        var controller = SceneController(scenes: [.standard, other], programSceneID: other.id)
        XCTAssertTrue(controller.remove(sceneID: other.id))
        XCTAssertEqual(controller.program?.id, other.id)
        XCTAssertTrue(controller.programIsStale)
        XCTAssertFalse(controller.remove(sceneID: CompositionScene.standard.id))
    }

    func testMoveScenes() {
        let a = CompositionScene(name: "A"), b = CompositionScene(name: "B"), c = CompositionScene(name: "C")
        var controller = SceneController(scenes: [a, b, c])
        controller.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        XCTAssertEqual(controller.scenes.map(\.name), ["B", "C", "A"])
    }

    func testLayerOrderingAndDuplicate() {
        var scene = CompositionScene(name: "S", layers: [
            Layer(name: "fundo", content: .solid(.black)),
            Layer(name: "texto", content: .presentation(drawsThemeBackground: false)),
        ])
        let bottom = scene.layers[0].id
        scene.moveLayer(id: bottom, by: 1)
        XCTAssertEqual(scene.layers.map(\.name), ["texto", "fundo"])
        scene.moveLayer(id: bottom, by: 5)
        XCTAssertEqual(scene.layers.map(\.name), ["texto", "fundo"])

        let copy = scene.duplicated()
        XCTAssertNotEqual(copy.id, scene.id)
        XCTAssertTrue(Set(copy.layers.map(\.id)).isDisjoint(with: Set(scene.layers.map(\.id))))
    }

    func testUnknownLayerContentDecodesAsHiddenLayer() throws {
        let id = UUID()
        let json = #"{"id":"\#(id)","name":"Futuro","content":{"ndi":{"source":"CAM 1"}}}"#
        let layer = try JSONDecoder().decode(Layer.self, from: Data(json.utf8))
        XCTAssertFalse(layer.isVisible)
        XCTAssertEqual(layer.name, "Futuro")
    }

    func testLayerContentRoundTrip() throws {
        let scene = CompositionScene(name: "S", layers: [
            Layer(content: .video(assetID: UUID(), loop: true, muted: true), opacity: 0.8),
            Layer(content: .presentation(drawsThemeBackground: false)),
        ])
        let data = try JSONEncoder().encode(scene)
        XCTAssertEqual(try JSONDecoder().decode(CompositionScene.self, from: data), scene)
    }

    func testProfiles() {
        XCTAssertEqual(CompositionProfile.profile(id: nil), .hd1080p30)
        XCTAssertEqual(CompositionProfile.profile(id: "2160p30").status, .experimental)
        XCTAssertEqual(CompositionProfile.hd1080p30.status, .operational)
    }
}
