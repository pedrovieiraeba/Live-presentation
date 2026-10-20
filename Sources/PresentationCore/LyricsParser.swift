import Foundation

/// Converte texto corrido em slides e de volta.
///
/// Formato de edição:
/// ```
/// [Verso 1]
/// Primeira linha
/// Segunda linha
///
/// [Refrão]
/// ...
/// ```
/// - Linhas em branco separam slides.
/// - Uma linha `[Rótulo]` no início de um bloco define o rótulo daquele bloco
///   e é herdada pelos blocos seguintes até o próximo rótulo, para que uma
///   estrofe longa dividida em vários slides mantenha o nome.
/// - `maxLinesPerSlide` divide blocos longos sem cortar palavras.
public enum LyricsParser {
    public struct Block: Equatable, Sendable {
        public var label: String
        public var text: String
        public init(label: String, text: String) { self.label = label; self.text = text }
    }

    public static func blocks(from source: String, maxLinesPerSlide: Int? = nil) -> [Block] {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var result: [Block] = []
        var currentLabel = ""
        var currentLines: [String] = []

        func flush() {
            guard !currentLines.isEmpty else { return }
            if let max = maxLinesPerSlide, max > 0, currentLines.count > max {
                var start = 0
                while start < currentLines.count {
                    let end = min(start + max, currentLines.count)
                    result.append(Block(label: currentLabel, text: currentLines[start..<end].joined(separator: "\n")))
                    start = end
                }
            } else {
                result.append(Block(label: currentLabel, text: currentLines.joined(separator: "\n")))
            }
            currentLines.removeAll()
        }

        for rawLine in normalized.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
            } else if let label = labelLine(line) {
                flush()
                currentLabel = label
            } else {
                currentLines.append(line)
            }
        }
        flush()
        return result
    }

    /// Gera slides reaproveitando, por posição, os IDs (e temas/notas) de slides
    /// existentes. Assim, reeditar uma letra não invalida a prévia nem o ar.
    public static func slides(from source: String, reusing existing: [Slide] = [], maxLinesPerSlide: Int? = nil) -> [Slide] {
        blocks(from: source, maxLinesPerSlide: maxLinesPerSlide).enumerated().map { index, block in
            if existing.indices.contains(index) {
                var slide = existing[index]
                slide.label = block.label
                slide.text = block.text
                return slide
            }
            return Slide(label: block.label, text: block.text)
        }
    }

    /// Texto editável a partir de slides (inverso de `slides(from:)`).
    public static func source(from slides: [Slide]) -> String {
        var parts: [String] = []
        var previousLabel = ""
        for slide in slides {
            var block = ""
            if !slide.label.isEmpty && slide.label != previousLabel {
                block += "[\(slide.label)]\n"
            }
            block += slide.text
            parts.append(block)
            previousLabel = slide.label
        }
        return parts.joined(separator: "\n\n")
    }

    private static func labelLine(_ line: String) -> String? {
        guard line.hasPrefix("["), line.hasSuffix("]"), line.count > 2 else { return nil }
        let inner = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
        return inner.isEmpty ? nil : inner
    }
}
