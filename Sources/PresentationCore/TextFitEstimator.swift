import Foundation

/// Estimativa de ocupação do texto na área segura.
public struct TextFitReport: Equatable, Sendable {
    public var estimatedLines: Int
    public var maxLines: Int
    public var longestLineFraction: Double

    public var overflows: Bool { estimatedLines > maxLines }
}

/// Interface para medir se um texto cabe na área segura de um tema. O app usa
/// medição tipográfica real (CoreText); a estimativa heurística abaixo serve
/// para testes e como reserva.
public protocol TextFitMeasuring: Sendable {
    func measure(_ text: String, theme: Theme, canvas: CanvasSize) -> TextFitReport
}

/// Heurística conservadora baseada em largura média de caractere. Não substitui
/// a medição real — serve para avisar cedo e para testes sem fontes instaladas.
public struct HeuristicTextFitEstimator: TextFitMeasuring {
    /// Largura média de um caractere como fração do tamanho da fonte.
    public var averageCharacterWidth: Double

    public init(averageCharacterWidth: Double = 0.55) {
        self.averageCharacterWidth = averageCharacterWidth
    }

    public func measure(_ text: String, theme: Theme, canvas: CanvasSize = Theme.referenceCanvas) -> TextFitReport {
        let scale = canvas.height / Theme.referenceCanvas.height
        let fontSize = theme.fontSize * scale
        let area = theme.safeArea(in: canvas)
        let charWidth = max(fontSize * averageCharacterWidth, 1)
        let charsPerLine = max(Int(area.width / charWidth), 1)
        let lineHeight = fontSize * 1.2 + theme.lineSpacing * scale
        let maxLines = max(Int(area.height / lineHeight), 0)

        var lines = 0
        var longest = 0
        for paragraph in text.components(separatedBy: "\n") {
            let wrapped = wrap(paragraph, width: charsPerLine)
            lines += max(wrapped.count, 1)
            longest = max(longest, wrapped.map(\.count).max() ?? 0)
        }
        return TextFitReport(estimatedLines: lines, maxLines: maxLines,
                             longestLineFraction: Double(longest) / Double(charsPerLine))
    }

    private func wrap(_ paragraph: String, width: Int) -> [String] {
        var lines: [String] = []
        var current = ""
        for word in paragraph.split(separator: " ", omittingEmptySubsequences: true) {
            var word = String(word)
            // Palavras maiores que a linha são quebradas à força.
            while word.count > width {
                if !current.isEmpty { lines.append(current); current = "" }
                lines.append(String(word.prefix(width)))
                word = String(word.dropFirst(width))
            }
            if current.isEmpty {
                current = word
            } else if current.count + 1 + word.count <= width {
                current += " " + word
            } else {
                lines.append(current)
                current = word
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }
}
