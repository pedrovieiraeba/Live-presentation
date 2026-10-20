import Foundation

/// Fonte NDI anunciada na rede.
public struct NDISourceInfo: Hashable, Codable, Sendable, Identifiable {
    /// Nome completo NDI, ex.: "MACBOOK (OBS)".
    public var name: String
    public var address: String?

    public var id: String { name }

    public init(name: String, address: String? = nil) {
        self.name = name
        self.address = address
    }
}

/// FourCC de vídeo NDI (little-endian).
public enum NDIFourCC {
    public static func code(_ s: String) -> UInt32 {
        let bytes = Array(s.utf8.prefix(4))
        guard bytes.count == 4 else { return 0 }
        return UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
    }

    public static let bgra = code("BGRA")
    public static let bgrx = code("BGRX")
    public static let uyvy = code("UYVY")

    public static func name(_ code: UInt32) -> String {
        let bytes = [0, 8, 16, 24].map { UInt8((code >> UInt32($0)) & 0xFF) }
        return String(bytes: bytes, encoding: .ascii) ?? String(code)
    }
}

/// Quadro de vídeo recebido. A memória pertence ao SDK e é devolvida
/// (exatamente uma vez) quando o objeto é liberado.
public final class NDIVideoFrame: @unchecked Sendable {
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let fourCC: UInt32
    public let frameRate: Double?
    public let data: UnsafeRawPointer
    private let release: () -> Void

    public init(width: Int, height: Int, bytesPerRow: Int, fourCC: UInt32, frameRate: Double?,
                data: UnsafeRawPointer, release: @escaping () -> Void) {
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.fourCC = fourCC
        self.frameRate = frameRate
        self.data = data
        self.release = release
    }

    deinit { release() }

    /// Formatos que o motor sabe exibir diretamente.
    public var isBGRA: Bool { fourCC == NDIFourCC.bgra || fourCC == NDIFourCC.bgrx }
    /// BGRX: canal alfa sem significado — tratar como opaco.
    public var ignoresAlpha: Bool { fourCC == NDIFourCC.bgrx }
}

public enum NDICaptureEvent {
    case video(NDIVideoFrame)
    case nothing
    case statusChange
    case error
}

// MARK: Abstrações (permitem testes sem o SDK real)

public protocol NDIRuntime: AnyObject, Sendable {
    var version: String { get }
    func makeFinder() throws -> NDIFinder
    func makeReceiver(sourceName: String, receiverName: String) throws -> NDIReceiver
    func makeSender(name: String) throws -> NDISender
}

public protocol NDIFinder: AnyObject {
    func currentSources() -> [NDISourceInfo]
}

public protocol NDIReceiver: AnyObject {
    /// Bloqueia até `timeoutMs` esperando um quadro.
    func capture(timeoutMs: UInt32) -> NDICaptureEvent
}

public protocol NDISender: AnyObject {
    /// Envia um quadro BGRA. Síncrono: a memória pode ser reutilizada ao retornar.
    func sendBGRA(_ data: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int,
                  frameRateN: Int32, frameRateD: Int32)
    func connectionCount() -> Int
}

public enum NDIError: Error, Equatable, CustomStringConvertible {
    case libraryNotFound(searched: [String])
    case libraryLoadFailed(String)
    case unsupportedCPU
    case creationFailed(String)

    public var description: String {
        switch self {
        case .libraryNotFound(let paths):
            return "SDK NDI não instalado (procurado em: \(paths.joined(separator: ", ")))"
        case .libraryLoadFailed(let reason):
            return "Falha ao carregar a biblioteca NDI: \(reason)"
        case .unsupportedCPU:
            return "O NDI não pôde ser inicializado neste processador"
        case .creationFailed(let what):
            return "Falha ao criar \(what) NDI"
        }
    }
}
