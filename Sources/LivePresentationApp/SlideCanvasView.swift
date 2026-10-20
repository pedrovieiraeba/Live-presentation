import AppKit
import PresentationCore
import SwiftUI

/// Desenha um slide na tela de referência (1920×1080) e escala para caber no
/// espaço disponível, com tarja preta. Serve às prévias e às miniaturas.
struct SlideCanvasView: View {
    var text: String?
    var theme: Theme?
    var showsSafeArea = false

    private let canvas = Theme.referenceCanvas

    var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / canvas.width, geo.size.height / canvas.height)
            ZStack {
                Color.black
                SlideContentView(text: text, theme: theme, showsSafeArea: showsSafeArea)
                    .scaleEffect(scale, anchor: .center)
                    .frame(width: canvas.width * scale, height: canvas.height * scale)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text ?? "Tela vazia")
    }
}

/// Conteúdo do slide em tamanho fixo de referência (1920×1080). Também é o que
/// o motor de composição recebe, renderizado em imagem (`SlideImageRenderer`).
struct SlideContentView: View {
    var text: String?
    var theme: Theme?
    var showsSafeArea = false
    var drawsBackground = true

    private let canvas = Theme.referenceCanvas

    var body: some View {
        content.frame(width: canvas.width, height: canvas.height)
    }

    @ViewBuilder
    private var content: some View {
        if let theme {
            let area = theme.safeArea(in: canvas)
            ZStack {
                if drawsBackground {
                    theme.backgroundColor.swiftUIColor
                } else {
                    Color.clear
                }
                if let text, !text.isEmpty {
                    Text(theme.uppercase ? text.uppercased() : text)
                        .font(theme.swiftUIFont)
                        .foregroundColor(theme.textColor.swiftUIColor)
                        .multilineTextAlignment(theme.horizontalAlignment.textAlignment)
                        .lineSpacing(theme.lineSpacing)
                        .shadow(color: .black.opacity(theme.textShadow ? 0.6 : 0), radius: 6, x: 0, y: 3)
                        .frame(width: area.width, height: area.height,
                               alignment: Alignment(horizontal: theme.horizontalAlignment.horizontal,
                                                    vertical: theme.verticalAlignment.vertical))
                        .position(x: area.x + area.width / 2, y: area.y + area.height / 2)
                }
                if showsSafeArea {
                    Rectangle()
                        .stroke(Color.yellow.opacity(0.7), style: StrokeStyle(lineWidth: 3, dash: [16, 10]))
                        .frame(width: area.width, height: area.height)
                        .position(x: area.x + area.width / 2, y: area.y + area.height / 2)
                }
            }
        } else if drawsBackground {
            Color.black
        } else {
            Color.clear
        }
    }
}

/// Renderiza o texto do slide (sem fundo) numa imagem do tamanho exato da
/// composição. O fundo do tema é desenhado pelo motor, abaixo do texto.
enum SlideImageRenderer {
    @MainActor
    static func render(text: String, theme: Theme, width: Int) -> CGImage? {
        let renderer = ImageRenderer(content: SlideContentView(text: text, theme: theme, drawsBackground: false))
        renderer.scale = CGFloat(width) / CGFloat(Theme.referenceCanvas.width)
        renderer.isOpaque = false
        return renderer.cgImage
    }
}

/// Raiz da janela de saída: apenas o quadro de saída, nada de interface.
struct OutputRootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        SlideCanvasView(text: frameText, theme: frameTheme)
            .ignoresSafeArea()
    }

    private var frameText: String? {
        if case let .slide(text, _) = model.show?.output { return text }
        return nil
    }

    private var frameTheme: Theme? {
        switch model.show?.output {
        case let .slide(_, themeID), let .background(themeID):
            return model.theme(id: themeID)
        case .black, .none:
            return nil
        }
    }
}

// MARK: Conversões de tema para SwiftUI

extension RGBAColor {
    var swiftUIColor: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(red: Double(ns.redComponent), green: Double(ns.greenComponent),
                  blue: Double(ns.blueComponent), alpha: Double(ns.alphaComponent))
    }
}

extension HorizontalTextAlignment {
    var textAlignment: TextAlignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    var horizontal: HorizontalAlignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

extension VerticalTextAlignment {
    var vertical: VerticalAlignment {
        switch self {
        case .top: return .top
        case .center: return .center
        case .bottom: return .bottom
        }
    }
}

extension FontWeightOption {
    var swiftUIWeight: Font.Weight {
        switch self {
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        }
    }

    var nsWeight: NSFont.Weight {
        switch self {
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        }
    }
}

extension Theme {
    var swiftUIFont: Font {
        if fontFamily.isEmpty {
            return .system(size: fontSize, weight: fontWeight.swiftUIWeight)
        }
        return Font.custom(fontFamily, size: fontSize).weight(fontWeight.swiftUIWeight)
    }

    var nsFont: NSFont {
        let base = NSFont.systemFont(ofSize: fontSize, weight: fontWeight.nsWeight)
        guard !fontFamily.isEmpty else { return base }
        // `fontFamily` é nome de família (NSFontManager), não nome PostScript.
        let managerWeight: Int
        switch fontWeight {
        case .regular: managerWeight = 5
        case .medium: managerWeight = 6
        case .semibold: managerWeight = 8
        case .bold: managerWeight = 9
        case .heavy: managerWeight = 11
        }
        return NSFontManager.shared.font(withFamily: fontFamily, traits: [], weight: managerWeight, size: fontSize)
            ?? NSFont(name: fontFamily, size: fontSize)
            ?? base
    }
}

/// Medição tipográfica real com o mesmo motor de texto do sistema.
struct AppKitTextFitMeasurer: TextFitMeasuring {
    func measure(_ text: String, theme: Theme, canvas: CanvasSize) -> TextFitReport {
        let area = theme.safeArea(in: Theme.referenceCanvas)
        let font = theme.nsFont
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = theme.lineSpacing
        let string = theme.uppercase ? text.uppercased() : text
        let attributed = NSAttributedString(string: string, attributes: [.font: font, .paragraphStyle: paragraph])
        let bounds = attributed.boundingRect(
            with: NSSize(width: area.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        let lineHeight = max(font.ascender - font.descender + font.leading + theme.lineSpacing, 1)
        let lines = max(Int((bounds.height / lineHeight).rounded(.up)), string.isEmpty ? 0 : 1)
        return TextFitReport(estimatedLines: lines,
                             maxLines: Int(area.height / lineHeight),
                             longestLineFraction: Double(min(bounds.width / area.width, 1)))
    }
}
