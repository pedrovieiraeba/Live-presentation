import Foundation

public enum MediaKind: String, Codable, CaseIterable, Sendable {
    case image
    case video

    public var displayName: String {
        switch self {
        case .image: return "Imagem"
        case .video: return "Vídeo"
        }
    }
}

/// Estado do arquivo referenciado. A biblioteca nunca copia mídia: guarda o
/// caminho (e, no macOS, um bookmark que acompanha arquivos movidos).
public enum MediaAvailability: String, Codable, Sendable {
    case available
    /// O arquivo não está no caminho registrado e não foi reencontrado.
    case missing
    /// O arquivo existe, mas não pôde ser lido/decodificado.
    case unsupported
}

public struct MediaAsset: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var path: String
    /// Bookmark do sistema (macOS) para reencontrar arquivos movidos.
    public var bookmark: Data?
    public var kind: MediaKind
    public var fileSize: Int64?
    public var duration: Double?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var codec: String?
    public var importedAt: Date
    public var availability: MediaAvailability
    public var lastError: String?
    public var tags: [String]

    public init(
        id: UUID = UUID(),
        name: String,
        path: String,
        bookmark: Data? = nil,
        kind: MediaKind,
        fileSize: Int64? = nil,
        duration: Double? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        codec: String? = nil,
        importedAt: Date = Date(),
        availability: MediaAvailability = .available,
        lastError: String? = nil,
        tags: [String] = []
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.bookmark = bookmark
        self.kind = kind
        self.fileSize = fileSize
        self.duration = duration
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.codec = codec
        self.importedAt = importedAt
        self.availability = availability
        self.lastError = lastError
        self.tags = tags
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        path = try c.decode(String.self, forKey: .path)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? URL(fileURLWithPath: path).lastPathComponent
        bookmark = try c.decodeIfPresent(Data.self, forKey: .bookmark)
        kind = (try? c.decode(MediaKind.self, forKey: .kind)) ?? .image
        fileSize = try c.decodeIfPresent(Int64.self, forKey: .fileSize)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration)
        pixelWidth = try c.decodeIfPresent(Int.self, forKey: .pixelWidth)
        pixelHeight = try c.decodeIfPresent(Int.self, forKey: .pixelHeight)
        codec = try c.decodeIfPresent(String.self, forKey: .codec)
        importedAt = try c.decodeIfPresent(Date.self, forKey: .importedAt) ?? Date()
        availability = (try? c.decode(MediaAvailability.self, forKey: .availability)) ?? .available
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
    }

    public var url: URL { URL(fileURLWithPath: path) }

    public var resolutionLabel: String? {
        guard let w = pixelWidth, let h = pixelHeight else { return nil }
        return "\(w)×\(h)"
    }

    public var durationLabel: String? {
        guard let duration, duration.isFinite, duration > 0 else { return nil }
        let total = Int(duration.rounded())
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Linha de metadados para a interface: "Vídeo · 1:23 · 1920×1080".
    public var summary: String {
        [kind.displayName, durationLabel, resolutionLabel].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Formatos aceitos na importação. A decisão final de compatibilidade é do
/// probe (decodificação real); a extensão é só o primeiro filtro.
public enum MediaFormats {
    public static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp"]
    public static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]

    public static func kind(for url: URL) -> MediaKind? {
        let ext = url.pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if videoExtensions.contains(ext) { return .video }
        return nil
    }
}
