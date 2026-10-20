import CompositionCore
import Metal
import PresentationCore
import simd

/// Shaders compilados em tempo de execução a partir do código-fonte: evita
/// depender do suporte do SwiftPM a arquivos `.metal`.
private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct QuadUniforms {
    float4 dest;   // x0, yTopo, x1, yBase (NDC)
    float4 src;    // u0, v0, u1, v1
    float4 tint;   // pré-multiplicado, inclui opacidade
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut quad_vertex(uint vid [[vertex_id]], constant QuadUniforms &u [[buffer(0)]]) {
    float2 corners[4] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1) };
    float2 c = corners[vid];
    VertexOut out;
    out.position = float4(mix(u.dest.x, u.dest.z, c.x), mix(u.dest.y, u.dest.w, c.y), 0, 1);
    out.uv = float2(mix(u.src.x, u.src.z, c.x), mix(u.src.y, u.src.w, c.y));
    return out;
}

fragment float4 quad_fragment(VertexOut in [[stage_in]],
                              texture2d<float> tex [[texture(0)]],
                              sampler s [[sampler(0)]],
                              constant QuadUniforms &u [[buffer(0)]]) {
    return tex.sample(s, in.uv) * u.tint;
}
"""

struct QuadUniforms {
    var dest: SIMD4<Float>
    var src: SIMD4<Float>
    var tint: SIMD4<Float>
}

enum CompositionEngineError: Error, CustomStringConvertible {
    case noMetalDevice
    case setupFailed(String)

    var description: String {
        switch self {
        case .noMetalDevice: return "Metal indisponível neste Mac"
        case .setupFailed(let reason): return "Falha ao preparar o Metal: \(reason)"
        }
    }
}

/// Desenha quadriláteros texturizados com mistura alfa pré-multiplicada.
final class QuadRenderer {
    let device: MTLDevice
    let pipeline: MTLRenderPipelineState
    let sampler: MTLSamplerState
    /// Textura 1×1 branca, tingida para camadas de cor sólida.
    let whiteTexture: MTLTexture

    init(device: MTLDevice, pixelFormat: MTLPixelFormat) throws {
        self.device = device
        let library = try device.makeLibrary(source: shaderSource, options: nil)
        guard let vertex = library.makeFunction(name: "quad_vertex"),
              let fragment = library.makeFunction(name: "quad_fragment") else {
            throw CompositionEngineError.setupFailed("funções de shader ausentes")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = pixelFormat
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw CompositionEngineError.setupFailed("sampler")
        }
        self.sampler = sampler

        let whiteDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        whiteDescriptor.usage = .shaderRead
        guard let white = device.makeTexture(descriptor: whiteDescriptor) else {
            throw CompositionEngineError.setupFailed("textura branca")
        }
        var pixel: [UInt8] = [255, 255, 255, 255]
        white.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &pixel, bytesPerRow: 4)
        whiteTexture = white
    }

    func draw(_ encoder: MTLRenderCommandEncoder, texture: MTLTexture, quad: RenderQuad,
              canvas: CanvasSize, tint: SIMD4<Float>) {
        let (x0, yTop, x1, yBottom) = LayerLayout.normalizedDeviceRect(quad.destination, canvas: canvas)
        let s = quad.source
        var uniforms = QuadUniforms(
            dest: SIMD4(Float(x0), Float(yTop), Float(x1), Float(yBottom)),
            src: SIMD4(Float(s.x), Float(s.y), Float(s.x + s.width), Float(s.y + s.height)),
            tint: tint)
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<QuadUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<QuadUniforms>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    /// Tint pré-multiplicado para uma cor RGBA com opacidade adicional.
    static func tint(_ color: RGBAColor, opacity: Double) -> SIMD4<Float> {
        let a = Float(color.alpha * opacity)
        return SIMD4(Float(color.red) * a, Float(color.green) * a, Float(color.blue) * a, a)
    }

    static func tint(opacity: Double) -> SIMD4<Float> {
        let o = Float(opacity)
        return SIMD4(o, o, o, o)
    }
}
