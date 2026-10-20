import CompositionCore
import MetalKit
import PresentationCore
import SwiftUI

/// Exibe a última composição do motor, em proporção correta, com tarja preta.
/// Usado na janela de saída e no monitor "No ar" do operador.
public struct MetalOutputView: NSViewRepresentable {
    let engine: CompositionEngine
    let framesPerSecond: Int

    public init(engine: CompositionEngine, framesPerSecond: Int = 30) {
        self.engine = engine
        self.framesPerSecond = framesPerSecond
    }

    public func makeCoordinator() -> Coordinator { Coordinator(engine: engine) }

    public func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: engine.device)
        view.colorPixelFormat = CompositionEngine.pixelFormat
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.preferredFramesPerSecond = framesPerSecond
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.delegate = context.coordinator
        return view
    }

    public func updateNSView(_ view: MTKView, context: Context) {
        view.preferredFramesPerSecond = framesPerSecond
    }

    public final class Coordinator: NSObject, MTKViewDelegate {
        let engine: CompositionEngine

        init(engine: CompositionEngine) { self.engine = engine }

        public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        public func draw(in view: MTKView) {
            guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
                  let commandBuffer = engine.commandQueue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
            if let texture = engine.latestTexture {
                let container = CanvasSize(width: Double(view.drawableSize.width),
                                           height: Double(view.drawableSize.height))
                let content = CanvasSize(width: Double(texture.width), height: Double(texture.height))
                let quad = RenderQuad(destination: LayerLayout.aspectFit(content, in: container),
                                      source: CanvasRect(x: 0, y: 0, width: 1, height: 1), opacity: 1)
                engine.renderer.draw(encoder, texture: texture, quad: quad, canvas: container,
                                     tint: QuadRenderer.tint(opacity: 1))
            }
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}
