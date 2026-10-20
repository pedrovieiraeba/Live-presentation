import Foundation

/// Expande arquivos e pastas selecionados em arquivos de mídia suportados.
public enum MediaScanner {
    public static func collectFiles(from urls: [URL], fileManager: FileManager = .default,
                                    maxFiles: Int = 10_000) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []

        func add(_ url: URL) {
            let standardized = url.standardizedFileURL
            guard MediaFormats.kind(for: standardized) != nil,
                  seen.insert(standardized.path).inserted else { return }
            result.append(standardized)
        }

        for url in urls {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                guard let enumerator = fileManager.enumerator(
                    at: url, includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                for case let file as URL in enumerator {
                    if result.count >= maxFiles { break }
                    add(file)
                }
            } else {
                add(url)
            }
            if result.count >= maxFiles { break }
        }
        return result.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    public static func fileSize(of url: URL, fileManager: FileManager = .default) -> Int64? {
        (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }
}

/// Encontra candidatos para mídia ausente: mesmo nome de arquivo e, quando o
/// tamanho é conhecido, mesmo tamanho. Nunca escolhe entre candidatos ambíguos.
public enum RelinkMatcher {
    public struct Candidate: Equatable, Sendable {
        public var url: URL
        public var size: Int64?
        public init(url: URL, size: Int64?) { self.url = url; self.size = size }
    }

    public static func match(missing: [MediaAsset], candidates: [Candidate]) -> [UUID: URL] {
        let byName = Dictionary(grouping: candidates) { $0.url.lastPathComponent.lowercased() }
        var result: [UUID: URL] = [:]
        for asset in missing {
            let name = URL(fileURLWithPath: asset.path).lastPathComponent.lowercased()
            guard let options = byName[name] else { continue }
            let filtered = asset.fileSize.map { size in options.filter { $0.size == nil || $0.size == size } } ?? options
            if filtered.count == 1 { result[asset.id] = filtered[0].url }
        }
        return result
    }
}
