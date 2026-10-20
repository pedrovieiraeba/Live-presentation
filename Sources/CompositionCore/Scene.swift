import Foundation
import PresentationCore

public enum FitMode: String, Codable, CaseIterable, Sendable {
    /// Cabe inteiro, com sobras (letterbox).
    case fit
    /// Preenche a tela, cortando o excedente.
    case fill
    /// Deforma para ocupar a tela exatamente.
    case stretch

    public var displayName: String {
        switch self {
        case .fit: return "Ajustar"
        case .fill: return "Preencher"
        case .stretch: return "Esticar"
        }
    }
}

/// O que uma camada desenha.
public enum LayerContent: Codable, Hashable, Sendable {
    case solid(RGBAColor)
    case image(assetID: UUID)
    case video(assetID: UUID, loop: Bool, muted: Bool)
    /// O slide no ar (texto do `ShowController`), opcionalmente com o fundo do tema.
    case presentation(drawsThemeBackground: Bool)

    public var mediaAssetID: UUID? {
        switch self {
        case .image(let id), .video(let id, _, _): return id
        case .solid, .presentation: return nil
        }
    }

    public var displayName: String {
        switch self {
        case .solid: return "Cor sólida"
        case .image: return "Imagem"
        case .video: return "Vídeo"
        case .presentation: return "Apresentação"
        }
    }
}

/// Posição e escala relativas à tela: centro em frações (0…1) e escala sobre o
/// tamanho dado pelo modo de ajuste.
public struct LayerTransform: Codable, Hashable, Sendable {
    public var centerX: Double
    public var centerY: Double
    public var scale: Double

    public init(centerX: Double = 0.5, centerY: Double = 0.5, scale: Double = 1) {
        self.centerX = centerX
        self.centerY = centerY
        self.scale = scale
    }

    public static let identity = LayerTransform()
}

/// Recorte da fonte em frações de cada lado (0.1 = 10%).
public struct CropInsets: Codable, Hashable, Sendable {
    public var top: Double
    public var left: Double
    public var bottom: Double
    public var right: Double

    public init(top: Double = 0, left: Double = 0, bottom: Double = 0, right: Double = 0) {
        self.top = top; self.left = left; self.bottom = bottom; self.right = right
    }

    public static let none = CropInsets()
}

public struct Layer: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var content: LayerContent
    public var isVisible: Bool
    public var opacity: Double
    public var transform: LayerTransform
    public var crop: CropInsets
    public var fitMode: FitMode

    public init(id: UUID = UUID(), name: String? = nil, content: LayerContent, isVisible: Bool = true,
                opacity: Double = 1, transform: LayerTransform = .identity, crop: CropInsets = .none,
                fitMode: FitMode = .fill) {
        self.id = id
        self.name = name ?? content.displayName
        self.content = content
        self.isVisible = isVisible
        self.opacity = min(max(opacity, 0), 1)
        self.transform = transform
        self.crop = crop
        self.fitMode = fitMode
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        // Conteúdo de versão futura/desconhecida: camada vira transparente e oculta.
        if let content = try? c.decode(LayerContent.self, forKey: .content) {
            self.content = content
            isVisible = try c.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true
        } else {
            content = .solid(RGBAColor(red: 0, green: 0, blue: 0, alpha: 0))
            isVisible = false
        }
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? content.displayName
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        transform = try c.decodeIfPresent(LayerTransform.self, forKey: .transform) ?? .identity
        crop = try c.decodeIfPresent(CropInsets.self, forKey: .crop) ?? .none
        fitMode = try c.decodeIfPresent(FitMode.self, forKey: .fitMode) ?? .fill
    }
}

/// Cena: camadas ordenadas de baixo (índice 0) para cima.
public struct CompositionScene: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var layers: [Layer]

    public init(id: UUID = UUID(), name: String, layers: [Layer] = []) {
        self.id = id
        self.name = name
        self.layers = layers
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Cena"
        layers = try c.decodeIfPresent([Layer].self, forKey: .layers) ?? []
    }

    /// Cena padrão: apenas o slide com o fundo do tema — equivale à Fase 1.
    public static let defaultID = UUID(uuidString: "5CE7E000-0000-4000-8000-000000000001")!
    public static let standard = CompositionScene(
        id: defaultID, name: "Apresentação",
        layers: [Layer(id: UUID(uuidString: "5CE7E000-0000-4000-8000-0000000000A1")!,
                       content: .presentation(drawsThemeBackground: true), fitMode: .fit)])

    public var mediaAssetIDs: Set<UUID> { Set(layers.compactMap(\.content.mediaAssetID)) }

    public func layer(id: UUID) -> Layer? { layers.first { $0.id == id } }

    public mutating func updateLayer(id: UUID, _ change: (inout Layer) -> Void) {
        guard let index = layers.firstIndex(where: { $0.id == id }) else { return }
        change(&layers[index])
        layers[index].opacity = min(max(layers[index].opacity, 0), 1)
    }

    public mutating func removeLayer(id: UUID) { layers.removeAll { $0.id == id } }

    /// Move uma camada para cima (+1, mais à frente) ou para baixo (-1).
    public mutating func moveLayer(id: UUID, by offset: Int) {
        guard let index = layers.firstIndex(where: { $0.id == id }) else { return }
        let target = min(max(index + offset, 0), layers.count - 1)
        guard target != index else { return }
        let layer = layers.remove(at: index)
        layers.insert(layer, at: target)
    }

    public func duplicated(name newName: String? = nil) -> CompositionScene {
        CompositionScene(id: UUID(), name: newName ?? "\(name) (cópia)",
              layers: layers.map { var l = $0; l.id = UUID(); return l })
    }
}

/// Resolução e taxa de quadros da composição, independentes da janela de saída.
public struct CompositionProfile: Codable, Hashable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable {
        case operational
        case experimental
    }

    public var id: String
    public var name: String
    public var width: Int
    public var height: Int
    public var framesPerSecond: Int
    public var status: Status

    public var canvas: CanvasSize { CanvasSize(width: Double(width), height: Double(height)) }

    public static let hd1080p30 = CompositionProfile(id: "1080p30", name: "1080p · 30 fps",
                                                     width: 1920, height: 1080, framesPerSecond: 30,
                                                     status: .operational)
    /// Experimental até teste documentado na configuração-alvo (spec §5).
    public static let uhd2160p30 = CompositionProfile(id: "2160p30", name: "4K · 30 fps (experimental)",
                                                      width: 3840, height: 2160, framesPerSecond: 30,
                                                      status: .experimental)

    public static let builtIn: [CompositionProfile] = [.hd1080p30, .uhd2160p30]

    public static func profile(id: String?) -> CompositionProfile {
        builtIn.first { $0.id == id } ?? .hd1080p30
    }
}
