import Foundation
import PresentationCore

/// Um quadrilátero a desenhar: destino em pixels da tela de composição (origem
/// no canto superior esquerdo) e região da fonte em coordenadas normalizadas.
public struct RenderQuad: Equatable, Sendable {
    public var destination: CanvasRect
    public var source: CanvasRect
    public var opacity: Double

    public init(destination: CanvasRect, source: CanvasRect, opacity: Double) {
        self.destination = destination
        self.source = source
        self.opacity = opacity
    }
}

/// Geometria das camadas — pura e testável; o renderizador Metal só a executa.
public enum LayerLayout {
    public static func quad(for layer: Layer, sourceSize: CanvasSize, canvas: CanvasSize) -> RenderQuad? {
        guard layer.isVisible, layer.opacity > 0, sourceSize.width > 0, sourceSize.height > 0,
              canvas.width > 0, canvas.height > 0, layer.transform.scale > 0 else { return nil }

        let crop = clamped(layer.crop)
        let visibleW = 1 - crop.left - crop.right
        let visibleH = 1 - crop.top - crop.bottom
        guard visibleW > 0.001, visibleH > 0.001 else { return nil }

        let croppedW = sourceSize.width * visibleW
        let croppedH = sourceSize.height * visibleH

        var width: Double
        var height: Double
        switch layer.fitMode {
        case .fit:
            let s = min(canvas.width / croppedW, canvas.height / croppedH)
            width = croppedW * s; height = croppedH * s
        case .fill:
            let s = max(canvas.width / croppedW, canvas.height / croppedH)
            width = croppedW * s; height = croppedH * s
        case .stretch:
            width = canvas.width; height = canvas.height
        }
        width *= layer.transform.scale
        height *= layer.transform.scale

        let centerX = layer.transform.centerX * canvas.width
        let centerY = layer.transform.centerY * canvas.height
        return RenderQuad(
            destination: CanvasRect(x: centerX - width / 2, y: centerY - height / 2, width: width, height: height),
            source: CanvasRect(x: crop.left, y: crop.top, width: visibleW, height: visibleH),
            opacity: layer.opacity)
    }

    /// Converte o destino para coordenadas normalizadas de dispositivo do Metal
    /// (x0, yTopo, x1, yBase), com y para cima.
    public static func normalizedDeviceRect(_ rect: CanvasRect, canvas: CanvasSize) -> (Double, Double, Double, Double) {
        let x0 = rect.x / canvas.width * 2 - 1
        let x1 = (rect.x + rect.width) / canvas.width * 2 - 1
        let yTop = 1 - rect.y / canvas.height * 2
        let yBottom = 1 - (rect.y + rect.height) / canvas.height * 2
        return (x0, yTop, x1, yBottom)
    }

    /// Retângulo que encaixa `content` dentro de `container` mantendo proporção.
    public static func aspectFit(_ content: CanvasSize, in container: CanvasSize) -> CanvasRect {
        guard content.width > 0, content.height > 0 else { return CanvasRect(x: 0, y: 0, width: 0, height: 0) }
        let s = min(container.width / content.width, container.height / content.height)
        let w = content.width * s, h = content.height * s
        return CanvasRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
    }

    private static func clamped(_ c: CropInsets) -> CropInsets {
        func f(_ v: Double) -> Double { min(max(v, 0), 1) }
        return CropInsets(top: f(c.top), left: f(c.left), bottom: f(c.bottom), right: f(c.right))
    }
}
