import Foundation

public enum ItemKind: String, Codable, CaseIterable, Sendable {
    case lyrics
    case text
    case scripture
    case announcement

    public var displayName: String {
        switch self {
        case .lyrics: return "Letra"
        case .text: return "Texto"
        case .scripture: return "Escritura"
        case .announcement: return "Aviso"
        }
    }
}

public struct Slide: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// Rótulo opcional da estrofe ("Verso 1", "Refrão").
    public var label: String
    public var text: String
    /// Notas para o operador / saída de palco. Nunca aparecem na saída principal.
    public var notes: String
    /// Tema específico do slide; `nil` herda do item ou da apresentação.
    public var themeID: UUID?

    public init(id: UUID = UUID(), label: String = "", text: String, notes: String = "", themeID: UUID? = nil) {
        self.id = id
        self.label = label
        self.text = text
        self.notes = notes
        self.themeID = themeID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        themeID = try c.decodeIfPresent(UUID.self, forKey: .themeID)
    }
}

public struct PresentationItem: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var kind: ItemKind
    public var title: String
    public var slides: [Slide]
    public var themeID: UUID?

    public init(id: UUID = UUID(), kind: ItemKind, title: String, slides: [Slide] = [], themeID: UUID? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.slides = slides
        self.themeID = themeID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = (try? c.decode(ItemKind.self, forKey: .kind)) ?? .text
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        slides = try c.decodeIfPresent([Slide].self, forKey: .slides) ?? []
        themeID = try c.decodeIfPresent(UUID.self, forKey: .themeID)
    }
}

/// Endereço estável de um slide (por identificadores, não por índices), para
/// que edições na apresentação não façam a prévia ou o ar "pular" de slide.
public struct SlideAddress: Codable, Hashable, Sendable {
    public var itemID: UUID
    public var slideID: UUID

    public init(itemID: UUID, slideID: UUID) {
        self.itemID = itemID
        self.slideID = slideID
    }
}

public struct Presentation: Codable, Hashable, Identifiable, Sendable {
    /// Versão do documento serializado, para migrações futuras.
    public static let documentVersion = 1

    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date
    public var items: [PresentationItem]
    public var defaultThemeID: UUID
    public var notes: String

    public init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        items: [PresentationItem] = [],
        defaultThemeID: UUID = Theme.standardLyrics.id,
        notes: String = ""
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.items = items
        self.defaultThemeID = defaultThemeID
        self.notes = notes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Sem título"
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        items = try c.decodeIfPresent([PresentationItem].self, forKey: .items) ?? []
        defaultThemeID = try c.decodeIfPresent(UUID.self, forKey: .defaultThemeID) ?? Theme.standardLyrics.id
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }

    // MARK: Consulta

    /// Todos os slides na ordem de exibição.
    public var orderedAddresses: [SlideAddress] {
        items.flatMap { item in item.slides.map { SlideAddress(itemID: item.id, slideID: $0.id) } }
    }

    public var slideCount: Int { items.reduce(0) { $0 + $1.slides.count } }

    public func item(id: UUID) -> PresentationItem? { items.first { $0.id == id } }

    public func slide(at address: SlideAddress) -> Slide? {
        item(id: address.itemID)?.slides.first { $0.id == address.slideID }
    }

    /// Posição global (0…slideCount-1) de um endereço, se existir.
    public func position(of address: SlideAddress) -> Int? {
        orderedAddresses.firstIndex(of: address)
    }

    /// Tema efetivo de um slide: slide → item → apresentação.
    public func themeID(for address: SlideAddress) -> UUID {
        let item = item(id: address.itemID)
        let slide = item?.slides.first { $0.id == address.slideID }
        return slide?.themeID ?? item?.themeID ?? defaultThemeID
    }

    // MARK: Edição

    public mutating func touch(_ date: Date = Date()) { updatedAt = date }

    @discardableResult
    public mutating func appendItem(_ item: PresentationItem) -> PresentationItem {
        items.append(item)
        return item
    }

    public mutating func removeItem(id: UUID) {
        items.removeAll { $0.id == id }
    }

    public mutating func moveItem(from source: Int, to destination: Int) {
        guard items.indices.contains(source) else { return }
        let item = items.remove(at: source)
        items.insert(item, at: min(max(destination, 0), items.count))
    }

    public mutating func updateItem(id: UUID, _ change: (inout PresentationItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    /// Duplica um slide logo após o original, com novo identificador.
    @discardableResult
    public mutating func duplicateSlide(at address: SlideAddress) -> SlideAddress? {
        guard let itemIndex = items.firstIndex(where: { $0.id == address.itemID }),
              let slideIndex = items[itemIndex].slides.firstIndex(where: { $0.id == address.slideID })
        else { return nil }
        var copy = items[itemIndex].slides[slideIndex]
        copy.id = UUID()
        items[itemIndex].slides.insert(copy, at: slideIndex + 1)
        return SlideAddress(itemID: address.itemID, slideID: copy.id)
    }

    /// Aplica um tema a vários slides de uma vez (`nil` volta a herdar).
    public mutating func applyTheme(_ themeID: UUID?, to addresses: Set<SlideAddress>) {
        for i in items.indices {
            for j in items[i].slides.indices
            where addresses.contains(SlideAddress(itemID: items[i].id, slideID: items[i].slides[j].id)) {
                items[i].slides[j].themeID = themeID
            }
        }
    }

    /// Cópia profunda com novos identificadores em todos os níveis.
    public func duplicated(name newName: String? = nil, at date: Date = Date()) -> Presentation {
        var copy = self
        copy.id = UUID()
        copy.name = newName ?? "\(name) (cópia)"
        copy.createdAt = date
        copy.updatedAt = date
        copy.items = items.map { item in
            var newItem = item
            newItem.id = UUID()
            newItem.slides = item.slides.map { slide in
                var s = slide
                s.id = UUID()
                return s
            }
            return newItem
        }
        return copy
    }
}

/// Metadados leves para listar a biblioteca sem carregar documentos inteiros.
public struct PresentationSummary: Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date
    public var slideCount: Int

    public init(id: UUID, name: String, createdAt: Date, updatedAt: Date, slideCount: Int) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.slideCount = slideCount
    }
}
