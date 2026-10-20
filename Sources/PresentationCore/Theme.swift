import Foundation

/// Cor RGBA em espaço sRGB, componentes de 0 a 1.
public struct RGBAColor: Codable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = Self.clamp(red)
        self.green = Self.clamp(green)
        self.blue = Self.clamp(blue)
        self.alpha = Self.clamp(alpha)
    }

    /// Aceita `#RGB`, `#RRGGBB` e `#RRGGBBAA` (com ou sem `#`).
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        if s.count == 6 { s += "FF" }
        guard s.count == 8, let value = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((value >> 24) & 0xFF) / 255,
                  green: Double((value >> 16) & 0xFF) / 255,
                  blue: Double((value >> 8) & 0xFF) / 255,
                  alpha: Double(value & 0xFF) / 255)
    }

    public var hexString: String {
        func byte(_ v: Double) -> Int { Int((v * 255).rounded()) }
        let rgb = String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
        return alpha >= 1 ? rgb : rgb + String(format: "%02X", byte(alpha))
    }

    public static let white = RGBAColor(red: 1, green: 1, blue: 1)
    public static let black = RGBAColor(red: 0, green: 0, blue: 0)

    private static func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }
}

public enum HorizontalTextAlignment: String, Codable, CaseIterable, Sendable {
    case leading, center, trailing
}

public enum VerticalTextAlignment: String, Codable, CaseIterable, Sendable {
    case top, center, bottom
}

public enum FontWeightOption: String, Codable, CaseIterable, Sendable {
    case regular, medium, semibold, bold, heavy
}

/// Margens de área segura como frações da tela (0.05 = 5%).
public struct SafeMargins: Codable, Hashable, Sendable {
    public var top: Double
    public var leading: Double
    public var bottom: Double
    public var trailing: Double

    public init(top: Double, leading: Double, bottom: Double, trailing: Double) {
        self.top = top; self.leading = leading; self.bottom = bottom; self.trailing = trailing
    }

    public init(all value: Double) { self.init(top: value, leading: value, bottom: value, trailing: value) }

    /// Margem "title safe" tradicional de 10% por lado.
    public static let titleSafe = SafeMargins(all: 0.10)
}

/// Tema visual reutilizável. Medidas tipográficas são definidas sobre a tela de
/// referência (`Theme.referenceCanvas`, 1920×1080) e escaladas na saída.
public struct Theme: Codable, Hashable, Identifiable, Sendable {
    public static let referenceCanvas = CanvasSize(width: 1920, height: 1080)

    public var id: UUID
    public var name: String
    /// Nome da família tipográfica; vazio usa a fonte do sistema.
    public var fontFamily: String
    public var fontSize: Double
    public var fontWeight: FontWeightOption
    public var textColor: RGBAColor
    public var backgroundColor: RGBAColor
    public var horizontalAlignment: HorizontalTextAlignment
    public var verticalAlignment: VerticalTextAlignment
    /// Espaço adicional entre linhas, em pontos da tela de referência.
    public var lineSpacing: Double
    public var margins: SafeMargins
    public var textShadow: Bool
    public var uppercase: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        fontFamily: String = "",
        fontSize: Double = 72,
        fontWeight: FontWeightOption = .semibold,
        textColor: RGBAColor = .white,
        backgroundColor: RGBAColor = .black,
        horizontalAlignment: HorizontalTextAlignment = .center,
        verticalAlignment: VerticalTextAlignment = .center,
        lineSpacing: Double = 8,
        margins: SafeMargins = .titleSafe,
        textShadow: Bool = true,
        uppercase: Bool = false
    ) {
        self.id = id
        self.name = name
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.fontWeight = fontWeight
        self.textColor = textColor
        self.backgroundColor = backgroundColor
        self.horizontalAlignment = horizontalAlignment
        self.verticalAlignment = verticalAlignment
        self.lineSpacing = lineSpacing
        self.margins = margins
        self.textShadow = textShadow
        self.uppercase = uppercase
    }

    /// Área segura em pontos, para uma tela de tamanho `canvas`.
    public func safeArea(in canvas: CanvasSize) -> CanvasRect {
        CanvasRect(
            x: canvas.width * margins.leading,
            y: canvas.height * margins.top,
            width: canvas.width * (1 - margins.leading - margins.trailing),
            height: canvas.height * (1 - margins.top - margins.bottom)
        )
    }
}

extension Theme {
    /// IDs fixos para que os temas de fábrica sejam estáveis entre execuções.
    public static let standardLyrics = Theme(
        id: UUID(uuidString: "6F1B7C1E-0000-4000-8000-000000000001")!,
        name: "Letras — padrão",
        fontSize: 72
    )

    public static let scripture = Theme(
        id: UUID(uuidString: "6F1B7C1E-0000-4000-8000-000000000002")!,
        name: "Escritura",
        fontFamily: "Georgia",
        fontSize: 60,
        fontWeight: .regular,
        backgroundColor: RGBAColor(hex: "#14161A")!,
        horizontalAlignment: .leading,
        lineSpacing: 12
    )

    public static let lowerThird = Theme(
        id: UUID(uuidString: "6F1B7C1E-0000-4000-8000-000000000003")!,
        name: "Terço inferior",
        fontSize: 54,
        backgroundColor: RGBAColor(red: 0, green: 0, blue: 0, alpha: 0),
        verticalAlignment: .bottom,
        margins: SafeMargins(top: 0.10, leading: 0.08, bottom: 0.08, trailing: 0.08)
    )

    public static let builtIn: [Theme] = [.standardLyrics, .scripture, .lowerThird]
}

public struct CanvasSize: Codable, Hashable, Sendable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) { self.width = width; self.height = height }
    public var aspectRatio: Double { width / height }
}

public struct CanvasRect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}
